//! The evaluator's closure compiler (M2.5, D-078, D-079). skein.compiler.eval lowers a
//! top-level form's Core IR into vectors (`[:op ...]`) with every name resolved: locals to
//! slots of their function's frame, or to a closure's captured values; vars to the
//! program's real vars; a ^:mutable local that a closure uses to a box. This file turns
//! that into a tree of nodes, each a function pointer and its operands, and runs it.
//!
//! - An interpreted function is a runtime closure (captured value 0 is its Lambda, the
//!   rest its captured values), so compiled code calls it like any function. Its frame,
//!   the locals of one call, is an array on the C stack, which the collector scans.
//! - Multiple values follow the C backend's rules (D-053): a node compiled for a position
//!   whose values matter (`mv`) leaves them in the registers, others don't care.
//! - recur sets the frame's flag and returns; the loop or function it targets, always the
//!   innermost, runs its body again. block* and unwind-protect need setjmp, so their
//!   frames are pushed by C helpers (unwind.c).
//! - Constants live in rooted cells, which the collector updates when objects move. Vars
//!   are permanent. Compiled code is never freed: evaluating is for development.

const std = @import("std");
const rt = @import("../rt.zig");
const gc = @import("../gc.zig");
const coll = @import("../coll.zig");
const cond = @import("../cond.zig");
const func = @import("../func.zig");
const names = @import("../names.zig");
const string = @import("../string.zig");
const dynamic = @import("../dynamic.zig");
const platform = @import("platform");
const Value = @import("../value.zig").Value;

const alloc = std.heap.c_allocator;

extern fn sk_mv_set(count: u32, values: [*]const Value) Value;
extern fn sk_mv_buffer() [*]Value;
extern fn sk_mv_count_get() i32;
extern fn sk_mv_clear() void;
extern fn sk_safepoint() void;
extern fn sk_arity_error(self: Value, argc: u32, defined_at: [*:0]const u8) Value;
extern fn sk_rest_list(argc: u32, argv: [*]const Value, from: u32) Value;
extern fn sk_unbound(name: [*:0]const u8, location: [*:0]const u8) Value;
extern fn sk_dynamic_get(v: Value, name: [*:0]const u8, location: [*:0]const u8) Value;
extern fn sk_with_bindings(n: u32, vars: ?[*]const Value, symbols: Value, values: Value, f: Value) Value;
extern fn sk_return_from(token: Value, v: Value) noreturn;
extern fn sk_throw_condition(c: Value) noreturn;
extern fn sk_closure_set(f: Value, i: usize, v: Value) void;

const Thunk = *const fn (ctx: *anyopaque) callconv(.c) Value;
extern fn sk_eval_block(body: Thunk, ctx: *anyopaque, token: *Value) Value;
extern fn sk_eval_unwind_protect(body: Thunk, cleanup: Thunk, ctx: *anyopaque) Value;

// ---------------------------------------------------------------------------------------
// Running

const Frame = struct {
    slots: [*]Value,
    /// The closure being called (its captured values, and the self of a named fn).
    self: Value,
    /// A recur to the innermost loop or function is pending.
    recur: bool = false,
};

const Node = struct {
    run: *const fn (n: *const Node, f: *Frame) Value,
};

fn poll() void {
    if (@atomicLoad(u8, &gc.sk_gc_pending, .monotonic) != 0) sk_safepoint();
}

/// A box: the cell of a ^:mutable local that a closure uses.
fn box(v: Value) Value {
    return coll.tupleN(1, v);
}

fn unbox(b: Value) Value {
    return coll.get(b, 0);
}

fn setBox(b: Value, v: Value) void {
    coll.set(b, 0, v);
}

// ---------------------------------------------------------------------------------------
// Constants: rooted cells, allocated in chunks that are never freed

const chunk_len = 1024;
var const_lock: platform.Mutex = .{};
var const_chunk: ?[]Value = null;
var const_used: usize = 0;

fn constant(v: Value) *Value {
    const_lock.lock();
    defer const_lock.unlock();
    if (const_chunk == null or const_used == chunk_len) {
        const chunk = alloc.alloc(Value, chunk_len) catch rt.fatal("out of memory (eval)", .{});
        @memset(chunk, Value.nil);
        gc.addRoots(chunk);
        const_chunk = chunk;
        const_used = 0;
    }
    const cell = &const_chunk.?[const_used];
    const_used += 1;
    cell.* = v;
    return cell;
}

// ---------------------------------------------------------------------------------------
// Reading lowered code

fn fail(comptime what: []const u8) noreturn {
    rt.fatal("internal error: the evaluator got malformed code (" ++ what ++ ")", .{});
}

fn at(v: Value, i: usize) Value {
    return coll.vectorNth(v, i) orelse fail("a vector is too short");
}

fn count(v: Value) usize {
    if (!coll.isVector(v)) fail("expected a vector");
    return coll.vectorCount(v);
}

fn int(v: Value) u32 {
    if (!v.isFixnum()) fail("expected an integer");
    return @intCast(v.toFixnum());
}

fn kw(comptime name: []const u8) Value {
    return names.keyword(null, name);
}

fn field(m: Value, comptime name: []const u8) Value {
    return coll.mapGet(m, kw(name)) orelse Value.nil;
}

fn cString(s: Value) [*:0]const u8 {
    if (!string.isString(s)) fail("expected a string");
    const copy = alloc.dupeSentinel(u8, string.bytes(s), 0) catch rt.fatal("out of memory (eval)", .{});
    return copy.ptr;
}

fn create(comptime T: type) *T {
    return alloc.create(T) catch rt.fatal("out of memory (eval)", .{});
}

// ---------------------------------------------------------------------------------------
// Compiling

/// What compiling one top-level form needs: whether each block's values matter, for the
/// return-froms that leave it (they may be in nested functions).
const Context = struct {
    blocks: std.AutoHashMapUnmanaged(u32, bool) = .empty,
};

fn compileAll(ctx: *Context, v: Value, mv_last: bool) []*const Node {
    const n = count(v);
    const out = alloc.alloc(*const Node, n) catch rt.fatal("out of memory (eval)", .{});
    for (0..n) |i| out[i] = compile(ctx, at(v, i), mv_last and i == n - 1);
    return out;
}

/// The node for lowered code `v`, for a position whose values matter if `mv`.
fn compile(ctx: *Context, v: Value, mv: bool) *const Node {
    const op = at(v, 0);
    if (op == kw("const")) return single(Const.make(at(v, 1)), mv);
    if (op == kw("slot")) return single(Slot.make(int(at(v, 1)), false), mv);
    if (op == kw("slot-box")) return single(Slot.make(int(at(v, 1)), true), mv);
    if (op == kw("capt")) return single(Capt.make(int(at(v, 1)), false), mv);
    if (op == kw("capt-box")) return single(Capt.make(int(at(v, 1)), true), mv);
    if (op == kw("self")) return single(&self_node, mv);
    if (op == kw("var")) return single(VarRef.make(v, false), mv);
    if (op == kw("dvar")) return single(VarRef.make(v, true), mv);
    if (op == kw("if")) return If.make(ctx, v, mv);
    if (op == kw("do")) return Do.make(ctx, v, mv);
    if (op == kw("def")) return single(Def.make(ctx, v), mv);
    if (op == kw("fn")) return single(Fn.make(ctx, at(v, 1)), mv);
    if (op == kw("let")) return Let.make(ctx, v, mv, false);
    if (op == kw("loop")) return Let.make(ctx, v, mv, true);
    if (op == kw("letfn")) return Letfn.make(ctx, v, mv);
    if (op == kw("recur")) return Recur.make(ctx, v);
    if (op == kw("set-slot")) return single(SetLocal.make(ctx, v, false), mv);
    if (op == kw("set-capt")) return single(SetLocal.make(ctx, v, true), mv);
    if (op == kw("call")) return Call.make(ctx, v, mv);
    if (op == kw("values")) return Values.make(ctx, v, mv);
    if (op == kw("let-values")) return LetValues.make(ctx, v, mv);
    if (op == kw("unwind-protect")) return UnwindProtect.make(ctx, v, mv);
    if (op == kw("block")) return Block.make(ctx, v, mv);
    if (op == kw("return-from")) return ReturnFrom.make(ctx, v);
    if (op == kw("throw")) return Throw.make(ctx, v);
    if (op == kw("handler-bind")) return HandlerBind.make(ctx, v, mv);
    if (op == kw("restart-bind")) return RestartBind.make(ctx, v, mv);
    if (op == kw("with-bindings")) return WithBindings.make(ctx, v, mv);
    if (op == kw("set-dynamic")) return single(SetDynamic.make(ctx, v), mv);
    if (op == kw("var-bound")) return single(VarBound.make(v), mv);
    fail("an unknown operation");
}

/// In a position whose values matter, a node that has one value says so.
fn single(n: *const Node, mv: bool) *const Node {
    if (!mv) return n;
    const s = create(Single);
    s.* = .{ .base = .{ .run = Single.run }, .inner = n };
    return &s.base;
}

const Single = struct {
    base: Node,
    inner: *const Node,
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Single = @fieldParentPtr("base", n);
        const v = s.inner.run(s.inner, f);
        sk_mv_clear();
        return v;
    }
};

const Const = struct {
    base: Node,
    k: *Value,
    fn make(v: Value) *const Node {
        const c = create(Const);
        c.* = .{ .base = .{ .run = run }, .k = constant(v) };
        return &c.base;
    }
    fn run(n: *const Node, _: *Frame) Value {
        const c: *const Const = @fieldParentPtr("base", n);
        return c.k.*;
    }
};

const Slot = struct {
    base: Node,
    i: u32,
    fn make(i: u32, boxed: bool) *const Node {
        const s = create(Slot);
        s.* = .{ .base = .{ .run = if (boxed) runBoxed else run }, .i = i };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Slot = @fieldParentPtr("base", n);
        return f.slots[s.i];
    }
    fn runBoxed(n: *const Node, f: *Frame) Value {
        const s: *const Slot = @fieldParentPtr("base", n);
        return unbox(f.slots[s.i]);
    }
};

const Capt = struct {
    base: Node,
    i: u32,
    fn make(i: u32, boxed: bool) *const Node {
        const s = create(Capt);
        s.* = .{ .base = .{ .run = if (boxed) runBoxed else run }, .i = i };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Capt = @fieldParentPtr("base", n);
        return func.capturedOf(f.self, s.i + 1);
    }
    fn runBoxed(n: *const Node, f: *Frame) Value {
        const s: *const Capt = @fieldParentPtr("base", n);
        return unbox(func.capturedOf(f.self, s.i + 1));
    }
};

var self_node: Node = .{ .run = struct {
    fn run(_: *const Node, f: *Frame) Value {
        return f.self;
    }
}.run };

/// [:var rt "ns/name" "file:line:col"], or :dvar for a ^:dynamic var.
const VarRef = struct {
    base: Node,
    v: Value,
    name: [*:0]const u8,
    loc: [*:0]const u8,
    fn make(lowered: Value, is_dynamic: bool) *const Node {
        const r = create(VarRef);
        r.* = .{ .base = .{ .run = if (is_dynamic) runDynamic else run }, .v = at(lowered, 1), .name = cString(at(lowered, 2)), .loc = cString(at(lowered, 3)) };
        return &r.base;
    }
    fn run(n: *const Node, _: *Frame) Value {
        const r: *const VarRef = @fieldParentPtr("base", n);
        const x = names.varValue(r.v);
        return if (x != Value.unbound) x else sk_unbound(r.name, r.loc);
    }
    fn runDynamic(n: *const Node, _: *Frame) Value {
        const r: *const VarRef = @fieldParentPtr("base", n);
        return sk_dynamic_get(r.v, r.name, r.loc);
    }
};

const If = struct {
    base: Node,
    t: *const Node,
    then: *const Node,
    els: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(If);
        s.* = .{ .base = .{ .run = run }, .t = compile(ctx, at(v, 1), false), .then = compile(ctx, at(v, 2), mv), .els = compile(ctx, at(v, 3), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const If = @fieldParentPtr("base", n);
        const branch = if (s.t.run(s.t, f).isTruthy()) s.then else s.els;
        return branch.run(branch, f);
    }
};

const Do = struct {
    base: Node,
    forms: []*const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(Do);
        s.* = .{ .base = .{ .run = run }, .forms = compileAll(ctx, at(v, 1), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Do = @fieldParentPtr("base", n);
        var v = Value.nil;
        for (s.forms) |x| {
            v = x.run(x, f);
            if (f.recur) return Value.nil;
        }
        return v;
    }
};

/// [:def rt init-or-nil dynamic?]: set the var (marking it ^:dynamic first) and return it.
const Def = struct {
    base: Node,
    v: Value,
    init: ?*const Node,
    is_dynamic: bool,
    fn make(ctx: *Context, lowered: Value) *const Node {
        const s = create(Def);
        const init = at(lowered, 2);
        s.* = .{ .base = .{ .run = run }, .v = at(lowered, 1), .init = if (init == Value.nil) null else compile(ctx, init, false), .is_dynamic = at(lowered, 3).isTruthy() };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Def = @fieldParentPtr("base", n);
        if (s.is_dynamic) names.setDynamic(s.v);
        if (s.init) |i| names.setVar(s.v, i.run(i, f));
        return s.v;
    }
};

// ---------------------------------------------------------------------------------------
// Functions

const Arity = struct {
    params: u32,
    rest: bool,
    slots: u32,
    /// The slots of parameters that live in boxes.
    boxes: []u32,
    body: *const Node,
};

const Lambda = struct {
    name: [*:0]const u8,
    loc: [*:0]const u8,
    arities: []Arity,
};

const Ref = union(enum) { slot: u32, capt: u32, self };

fn compileLambda(ctx: *Context, m: Value) *Lambda {
    const lam = create(Lambda);
    const arities = field(m, "arities");
    const out = alloc.alloc(Arity, count(arities)) catch rt.fatal("out of memory (eval)", .{});
    for (out, 0..) |*a, i| {
        const am = at(arities, i);
        const boxes = field(am, "boxes");
        const bs = alloc.alloc(u32, count(boxes)) catch rt.fatal("out of memory (eval)", .{});
        for (bs, 0..) |*b, j| b.* = int(at(boxes, j));
        a.* = .{
            .params = int(field(am, "params")),
            .rest = field(am, "rest").isTruthy(),
            .slots = int(field(am, "slots")),
            .boxes = bs,
            // A function's values are those of its body.
            .body = compile(ctx, field(am, "body"), true),
        };
        if (a.slots > max_slots) rt.raise(.unsupported_operation_error, "a function with more than {d} locals can't be evaluated", .{max_slots});
    }
    lam.* = .{ .name = cString(field(m, "name")), .loc = cString(field(m, "loc")), .arities = out };
    return lam;
}

fn compileRefs(v: Value) []Ref {
    const out = alloc.alloc(Ref, count(v)) catch rt.fatal("out of memory (eval)", .{});
    for (out, 0..) |*r, i| {
        const x = at(v, i);
        const op = at(x, 0);
        r.* = if (op == kw("slot")) .{ .slot = int(at(x, 1)) } else if (op == kw("capt")) .{ .capt = int(at(x, 1)) } else if (op == kw("self")) .self else fail("a capture");
    }
    return out;
}

fn readRef(r: Ref, f: *Frame) Value {
    return switch (r) {
        .slot => |i| f.slots[i],
        .capt => |i| func.capturedOf(f.self, i + 1),
        .self => f.self,
    };
}

const max_captures = 256;
const max_slots = 1024;
const max_args = 256;

/// A closure of `lam` with the captured values `refs` reads in `f`.
fn makeClosure(lam: *const Lambda, refs: []const Ref, f: *Frame) Value {
    var buf: [max_captures + 1]Value = undefined;
    if (refs.len > max_captures) rt.raise(.unsupported_operation_error, "a function that captures more than {d} locals can't be evaluated", .{max_captures});
    buf[0] = Value.fromFixnum(@intCast(@intFromPtr(lam)));
    for (refs, 0..) |r, i| buf[i + 1] = readRef(r, f);
    return func.closure(lambdaEntry, lam.name, buf[0 .. refs.len + 1]);
}

/// [:fn {:name :loc :captures [ref...] :arities [...]}]
const Fn = struct {
    base: Node,
    lam: *const Lambda,
    refs: []Ref,
    fn make(ctx: *Context, m: Value) *const Node {
        const s = create(Fn);
        s.* = .{ .base = .{ .run = run }, .lam = compileLambda(ctx, m), .refs = compileRefs(field(m, "captures")) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Fn = @fieldParentPtr("base", n);
        return makeClosure(s.lam, s.refs, f);
    }
};

fn chooseArity(lam: *const Lambda, argc: u32) ?*const Arity {
    for (lam.arities) |*a| if (!a.rest and a.params == argc) return a;
    for (lam.arities) |*a| if (a.rest and argc >= a.params) return a;
    return null;
}

/// The code of every interpreted function.
fn lambdaEntry(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const lam: *const Lambda = @ptrFromInt(@as(usize, @intCast(func.capturedOf(self, 0).toFixnum())));
    const a = chooseArity(lam, argc) orelse return sk_arity_error(self, argc, lam.loc);
    // The frame, on this stack, in the smallest size that holds the arity's locals; each
    // size has its own function, so a call reserves only that much stack.
    if (a.slots <= 8) return @call(.never_inline, withSlots(8), .{ a, self, argc, argv });
    if (a.slots <= 32) return @call(.never_inline, withSlots(32), .{ a, self, argc, argv });
    if (a.slots <= 128) return @call(.never_inline, withSlots(128), .{ a, self, argc, argv });
    return @call(.never_inline, withSlots(max_slots), .{ a, self, argc, argv });
}

fn withSlots(comptime size: usize) fn (*const Arity, Value, u32, [*]const Value) Value {
    return struct {
        fn call(a: *const Arity, self: Value, argc: u32, argv: [*]const Value) Value {
            var slots: [size]Value = @splat(Value.nil);
            return callArity(a, self, argc, argv, &slots);
        }
    }.call;
}

fn callArity(a: *const Arity, self: Value, argc: u32, argv: [*]const Value, slots: [*]Value) Value {
    var f: Frame = .{ .slots = slots, .self = self };
    for (0..a.params) |i| slots[i] = argv[i];
    if (a.rest) slots[a.params] = sk_rest_list(argc, argv, a.params);
    for (a.boxes) |i| slots[i] = box(slots[i]);
    while (true) {
        poll();
        const v = a.body.run(a.body, &f);
        if (!f.recur) return v;
        f.recur = false;
    }
}

// ---------------------------------------------------------------------------------------
// Binding forms

const Binding = struct { slot: u32, boxed: bool, init: *const Node };

fn compileBindings(ctx: *Context, v: Value) []Binding {
    const out = alloc.alloc(Binding, count(v)) catch rt.fatal("out of memory (eval)", .{});
    for (out, 0..) |*b, i| {
        const x = at(v, i);
        b.* = .{ .slot = int(at(x, 0)), .boxed = at(x, 1).isTruthy(), .init = compile(ctx, at(x, 2), false) };
    }
    return out;
}

/// [:let [[slot boxed? init]...] body] and [:loop ...], which recur runs again.
const Let = struct {
    base: Node,
    bindings: []Binding,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool, is_loop: bool) *const Node {
        const s = create(Let);
        s.* = .{ .base = .{ .run = if (is_loop) runLoop else run }, .bindings = compileBindings(ctx, at(v, 1)), .body = compile(ctx, at(v, 2), mv) };
        return &s.base;
    }
    fn bind(s: *const Let, f: *Frame) void {
        for (s.bindings) |b| {
            const x = b.init.run(b.init, f);
            f.slots[b.slot] = if (b.boxed) box(x) else x;
        }
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Let = @fieldParentPtr("base", n);
        s.bind(f);
        return s.body.run(s.body, f);
    }
    fn runLoop(n: *const Node, f: *Frame) Value {
        const s: *const Let = @fieldParentPtr("base", n);
        s.bind(f);
        while (true) {
            poll();
            const v = s.body.run(s.body, f);
            if (!f.recur) return v;
            f.recur = false;
        }
    }
};

/// [:recur [[slot boxed?]...] [args]]: rebind the target's locals, then say so.
const Recur = struct {
    base: Node,
    targets: []u32,
    boxed: []bool,
    args: []*const Node,
    fn make(ctx: *Context, v: Value) *const Node {
        const s = create(Recur);
        const ts = at(v, 1);
        const targets = alloc.alloc(u32, count(ts)) catch rt.fatal("out of memory (eval)", .{});
        const boxed = alloc.alloc(bool, count(ts)) catch rt.fatal("out of memory (eval)", .{});
        for (targets, boxed, 0..) |*t, *b, i| {
            t.* = int(at(at(ts, i), 0));
            b.* = at(at(ts, i), 1).isTruthy();
        }
        const args = compileAll(ctx, at(v, 2), false);
        if (args.len > max_args) rt.raise(.unsupported_operation_error, "a recur with more than {d} values can't be evaluated", .{max_args});
        s.* = .{ .base = .{ .run = if (args.len <= 8) runN(8) else runN(max_args) }, .targets = targets, .boxed = boxed, .args = args };
        return &s.base;
    }
    fn runN(comptime size: usize) *const fn (*const Node, *Frame) Value {
        return struct {
            fn run(n: *const Node, f: *Frame) Value {
                const s: *const Recur = @fieldParentPtr("base", n);
                var buf: [size]Value = undefined;
                for (s.args, 0..) |a, i| buf[i] = a.run(a, f);
                for (s.targets, s.boxed, 0..) |t, b, i| f.slots[t] = if (b) box(buf[i]) else buf[i];
                f.recur = true;
                return Value.nil;
            }
        }.run;
    }
};

/// [:letfn [[slot fn]...] [[fn-slot capture target-slot]...] body]: make the closures
/// with nil for the letfn locals they capture, then fill those in.
const Letfn = struct {
    base: Node,
    slots: []u32,
    fns: []*const Node,
    fixups: [][3]u32,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(Letfn);
        const bs = at(v, 1);
        const slots = alloc.alloc(u32, count(bs)) catch rt.fatal("out of memory (eval)", .{});
        const fns = alloc.alloc(*const Node, count(bs)) catch rt.fatal("out of memory (eval)", .{});
        for (slots, fns, 0..) |*sl, *fnode, i| {
            sl.* = int(at(at(bs, i), 0));
            fnode.* = Fn.make(ctx, at(at(bs, i), 1));
        }
        const fx = at(v, 2);
        const fixups = alloc.alloc([3]u32, count(fx)) catch rt.fatal("out of memory (eval)", .{});
        for (fixups, 0..) |*x, i| {
            const t = at(fx, i);
            x.* = .{ int(at(t, 0)), int(at(t, 1)), int(at(t, 2)) };
        }
        s.* = .{ .base = .{ .run = run }, .slots = slots, .fns = fns, .fixups = fixups, .body = compile(ctx, at(v, 3), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Letfn = @fieldParentPtr("base", n);
        for (s.slots) |sl| f.slots[sl] = Value.nil;
        for (s.slots, s.fns) |sl, fnode| f.slots[sl] = fnode.run(fnode, f);
        for (s.fixups) |x| sk_closure_set(f.slots[x[0]], x[1] + 1, f.slots[x[2]]);
        return s.body.run(s.body, f);
    }
};

/// [:set-slot slot boxed? value] or [:set-capt capture value] (a boxed local).
const SetLocal = struct {
    base: Node,
    i: u32,
    value: *const Node,
    fn make(ctx: *Context, v: Value, captured: bool) *const Node {
        const s = create(SetLocal);
        if (captured) {
            s.* = .{ .base = .{ .run = runCapt }, .i = int(at(v, 1)), .value = compile(ctx, at(v, 2), false) };
        } else {
            const boxed = at(v, 2).isTruthy();
            s.* = .{ .base = .{ .run = if (boxed) runBoxed else run }, .i = int(at(v, 1)), .value = compile(ctx, at(v, 3), false) };
        }
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const SetLocal = @fieldParentPtr("base", n);
        const x = s.value.run(s.value, f);
        f.slots[s.i] = x;
        return x;
    }
    fn runBoxed(n: *const Node, f: *Frame) Value {
        const s: *const SetLocal = @fieldParentPtr("base", n);
        const x = s.value.run(s.value, f);
        setBox(f.slots[s.i], x);
        return x;
    }
    fn runCapt(n: *const Node, f: *Frame) Value {
        const s: *const SetLocal = @fieldParentPtr("base", n);
        const x = s.value.run(s.value, f);
        setBox(func.capturedOf(f.self, s.i + 1), x);
        return x;
    }
};

/// [:let-values [[[[slot boxed?]...] init]...] body]
const LetValues = struct {
    const Group = struct { slots: []u32, boxed: []bool, init: *const Node };
    base: Node,
    groups: []Group,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(LetValues);
        const bs = at(v, 1);
        const groups = alloc.alloc(Group, count(bs)) catch rt.fatal("out of memory (eval)", .{});
        for (groups, 0..) |*g, i| {
            const locals = at(at(bs, i), 0);
            const slots = alloc.alloc(u32, count(locals)) catch rt.fatal("out of memory (eval)", .{});
            const boxed = alloc.alloc(bool, count(locals)) catch rt.fatal("out of memory (eval)", .{});
            for (slots, boxed, 0..) |*sl, *b, j| {
                sl.* = int(at(at(locals, j), 0));
                b.* = at(at(locals, j), 1).isTruthy();
            }
            g.* = .{ .slots = slots, .boxed = boxed, .init = compile(ctx, at(at(bs, i), 1), true) };
        }
        s.* = .{ .base = .{ .run = run }, .groups = groups, .body = compile(ctx, at(v, 2), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const LetValues = @fieldParentPtr("base", n);
        for (s.groups) |g| {
            sk_mv_clear();
            const first = g.init.run(g.init, f);
            const c = sk_mv_count_get();
            const values = sk_mv_buffer();
            for (g.slots, g.boxed, 0..) |sl, b, i| {
                const x = if (c < 0) (if (i == 0) first else Value.nil) else if (i < c) values[i] else Value.nil;
                f.slots[sl] = if (b) box(x) else x;
            }
            sk_mv_clear();
        }
        return s.body.run(s.body, f);
    }
};

// ---------------------------------------------------------------------------------------
// Calls and values

/// [:call f [args]]
const Call = struct {
    base: Node,
    f: *const Node,
    args: []*const Node,
    mv: bool,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(Call);
        const args = compileAll(ctx, at(v, 2), false);
        if (args.len > max_args) rt.raise(.unsupported_operation_error, "a call with more than {d} arguments can't be evaluated", .{max_args});
        // Each argument buffer size has its own function, so a call reserves only that much
        // stack.
        const runner = if (args.len <= 4) runN(4) else if (args.len <= 16) runN(16) else runN(max_args);
        s.* = .{ .base = .{ .run = runner }, .f = compile(ctx, at(v, 1), false), .args = args, .mv = mv };
        return &s.base;
    }
    fn runN(comptime size: usize) *const fn (*const Node, *Frame) Value {
        return struct {
            fn run(n: *const Node, f: *Frame) Value {
                const s: *const Call = @fieldParentPtr("base", n);
                const fv = s.f.run(s.f, f);
                var buf: [size]Value = undefined;
                for (s.args, 0..) |a, i| buf[i] = a.run(a, f);
                // A compiled or interpreted callee sets the values it returns; the runtime's
                // functions don't, so start from one value.
                if (s.mv) sk_mv_clear();
                return func.call(fv, @intCast(s.args.len), &buf);
            }
        }.run;
    }
};

/// [:values [args]]
const Values = struct {
    base: Node,
    args: []*const Node,
    mv: bool,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(Values);
        s.* = .{ .base = .{ .run = run }, .args = compileAll(ctx, at(v, 1), false), .mv = mv };
        if (s.args.len > 64) rt.raise(.unsupported_operation_error, "values of more than 64 values", .{});
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Values = @fieldParentPtr("base", n);
        var buf: [64]Value = undefined;
        for (s.args, 0..) |a, i| buf[i] = a.run(a, f);
        if (s.mv) return sk_mv_set(@intCast(s.args.len), &buf);
        return if (s.args.len > 0) buf[0] else Value.nil;
    }
};

// ---------------------------------------------------------------------------------------
// Non-local exits and conditions

const BodyContext = struct { node: *const Node, other: ?*const Node = null, f: *Frame };

fn runBody(p: *anyopaque) callconv(.c) Value {
    const c: *BodyContext = @ptrCast(@alignCast(p));
    return c.node.run(c.node, c.f);
}

fn runOther(p: *anyopaque) callconv(.c) Value {
    const c: *BodyContext = @ptrCast(@alignCast(p));
    return c.other.?.run(c.other.?, c.f);
}

/// [:block id slot body]: the slot holds the block's token, which return-from names.
const Block = struct {
    base: Node,
    slot: u32,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(Block);
        ctx.blocks.put(alloc, int(at(v, 1)), mv) catch rt.fatal("out of memory (eval)", .{});
        s.* = .{ .base = .{ .run = run }, .slot = int(at(v, 2)), .body = compile(ctx, at(v, 3), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Block = @fieldParentPtr("base", n);
        var c: BodyContext = .{ .node = s.body, .f = f };
        return sk_eval_block(runBody, &c, &f.slots[s.slot]);
    }
};

/// [:return-from id token-ref value]: its value is computed as its block's would be.
const ReturnFrom = struct {
    base: Node,
    token: Ref,
    value: *const Node,
    fn make(ctx: *Context, v: Value) *const Node {
        const s = create(ReturnFrom);
        const mv = ctx.blocks.get(int(at(v, 1))) orelse false;
        const refs = compileRefs(coll.vectorOf(&.{at(v, 2)}));
        s.* = .{ .base = .{ .run = run }, .token = refs[0], .value = compile(ctx, at(v, 3), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const ReturnFrom = @fieldParentPtr("base", n);
        const x = s.value.run(s.value, f);
        sk_return_from(readRef(s.token, f), x);
    }
};

/// [:unwind-protect body cleanup]
const UnwindProtect = struct {
    base: Node,
    body: *const Node,
    cleanup: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(UnwindProtect);
        s.* = .{ .base = .{ .run = run }, .body = compile(ctx, at(v, 1), mv), .cleanup = compile(ctx, at(v, 2), false) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const UnwindProtect = @fieldParentPtr("base", n);
        var c: BodyContext = .{ .node = s.body, .other = s.cleanup, .f = f };
        return sk_eval_unwind_protect(runBody, runOther, &c);
    }
};

const Throw = struct {
    base: Node,
    c: *const Node,
    fn make(ctx: *Context, v: Value) *const Node {
        const s = create(Throw);
        s.* = .{ .base = .{ .run = run }, .c = compile(ctx, at(v, 1), false) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const Throw = @fieldParentPtr("base", n);
        sk_throw_condition(s.c.run(s.c, f));
    }
};

const max_cluster = 64;

/// [:handler-bind [[type handler]...] body]
const HandlerBind = struct {
    base: Node,
    types: []*const Node,
    handlers: []*const Node,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(HandlerBind);
        const bs = at(v, 1);
        const n = count(bs);
        if (n > max_cluster) rt.raise(.unsupported_operation_error, "handler-bind* with more than {d} handlers", .{max_cluster});
        const types = alloc.alloc(*const Node, n) catch rt.fatal("out of memory (eval)", .{});
        const handlers = alloc.alloc(*const Node, n) catch rt.fatal("out of memory (eval)", .{});
        for (types, handlers, 0..) |*t, *h, i| {
            t.* = compile(ctx, at(at(bs, i), 0), false);
            h.* = compile(ctx, at(at(bs, i), 1), false);
        }
        s.* = .{ .base = .{ .run = run }, .types = types, .handlers = handlers, .body = compile(ctx, at(v, 2), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const HandlerBind = @fieldParentPtr("base", n);
        var ts: [max_cluster]Value = undefined;
        var hs: [max_cluster]Value = undefined;
        for (s.types, s.handlers, 0..) |t, h, i| {
            ts[i] = t.run(t, f);
            hs[i] = h.run(h, f);
        }
        if (s.types.len == 0) return s.body.run(s.body, f);
        var frame: cond.Frame = undefined;
        cond.pushHandlers(&frame, ts[0..s.types.len], &hs);
        const x = s.body.run(s.body, f);
        cond.popFrame(&frame);
        return x;
    }
};

/// [:restart-bind [[name fn report]...] body], each name a constant symbol.
const RestartBind = struct {
    base: Node,
    restart_names: []*Value,
    fns: []*const Node,
    reports: []*const Node,
    body: *const Node,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(RestartBind);
        const bs = at(v, 1);
        const n = count(bs);
        if (n > max_cluster) rt.raise(.unsupported_operation_error, "restart-bind* with more than {d} restarts", .{max_cluster});
        const ns = alloc.alloc(*Value, n) catch rt.fatal("out of memory (eval)", .{});
        const fns = alloc.alloc(*const Node, n) catch rt.fatal("out of memory (eval)", .{});
        const reports = alloc.alloc(*const Node, n) catch rt.fatal("out of memory (eval)", .{});
        for (ns, fns, reports, 0..) |*nm, *fnode, *r, i| {
            const b = at(bs, i);
            nm.* = constant(at(b, 0));
            fnode.* = compile(ctx, at(b, 1), false);
            r.* = compile(ctx, at(b, 2), false);
        }
        s.* = .{ .base = .{ .run = run }, .restart_names = ns, .fns = fns, .reports = reports, .body = compile(ctx, at(v, 2), mv) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const RestartBind = @fieldParentPtr("base", n);
        var ns: [max_cluster]Value = undefined;
        var fs: [max_cluster]Value = undefined;
        var rs: [max_cluster]Value = undefined;
        for (s.restart_names, s.fns, s.reports, 0..) |nm, fnode, r, i| {
            ns[i] = nm.*;
            fs[i] = fnode.run(fnode, f);
            rs[i] = r.run(r, f);
        }
        if (s.fns.len == 0) return s.body.run(s.body, f);
        var frame: cond.Frame = undefined;
        cond.pushRestarts(&frame, ns[0..s.fns.len], &fs, &rs);
        const x = s.body.run(s.body, f);
        cond.popFrame(&frame);
        return x;
    }
};

// ---------------------------------------------------------------------------------------
// Dynamic vars (D-076, D-077)

/// [:with-bindings [rt...] symbols values fn]
const WithBindings = struct {
    base: Node,
    vars: []Value,
    symbols: *Value,
    values: *const Node,
    f: *const Node,
    mv: bool,
    fn make(ctx: *Context, v: Value, mv: bool) *const Node {
        const s = create(WithBindings);
        const vs = at(v, 1);
        const vars = alloc.alloc(Value, count(vs)) catch rt.fatal("out of memory (eval)", .{});
        for (vars, 0..) |*x, i| x.* = at(vs, i);
        s.* = .{ .base = .{ .run = run }, .vars = vars, .symbols = constant(at(v, 2)), .values = compile(ctx, at(v, 3), false), .f = compile(ctx, at(v, 4), false), .mv = mv };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const WithBindings = @fieldParentPtr("base", n);
        const values = s.values.run(s.values, f);
        const body = s.f.run(s.f, f);
        if (s.mv) sk_mv_clear();
        return sk_with_bindings(@intCast(s.vars.len), s.vars.ptr, s.symbols.*, values, body);
    }
};

/// [:set-dynamic rt value]
const SetDynamic = struct {
    base: Node,
    v: Value,
    value: *const Node,
    fn make(ctx: *Context, v: Value) *const Node {
        const s = create(SetDynamic);
        s.* = .{ .base = .{ .run = run }, .v = at(v, 1), .value = compile(ctx, at(v, 2), false) };
        return &s.base;
    }
    fn run(n: *const Node, f: *Frame) Value {
        const s: *const SetDynamic = @fieldParentPtr("base", n);
        return dynamic.set(s.v, s.value.run(s.value, f));
    }
};

/// [:var-bound rt]: whether the var has a value (defonce).
const VarBound = struct {
    base: Node,
    v: Value,
    fn make(v: Value) *const Node {
        const s = create(VarBound);
        s.* = .{ .base = .{ .run = run }, .v = at(v, 1) };
        return &s.base;
    }
    fn run(n: *const Node, _: *Frame) Value {
        const s: *const VarBound = @fieldParentPtr("base", n);
        return Value.fromBool(names.varValue(s.v) != Value.unbound);
    }
};

// ---------------------------------------------------------------------------------------
// Entry point

/// Compile `code`, a top-level form as skein.compiler.eval lowers it (a function of no
/// arguments), and call it.
pub fn evaluate(code: Value) Value {
    var ctx: Context = .{};
    const lam = compileLambda(&ctx, code);
    ctx.blocks.deinit(alloc);
    var f: Frame = .{ .slots = undefined, .self = Value.nil };
    const thunk = makeClosure(lam, &.{}, &f);
    return func.call(thunk, 0, &.{});
}
