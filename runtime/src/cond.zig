//! Conditions, restarts and non-local exits (DESIGN §10, M1.5, D-047), matching Phase 0
//! (host/src/runtime/conditions.lisp).
//!
//! Each thread has a chain of frames, innermost first. Compiled code keeps them in its
//! own C stack frames (`sk_frame` in include/skein.h; `Frame` mirrors its fields up to the
//! jmp_buf) and pushes and pops them through the functions below:
//!
//! - a block frame is the target of return-from*;
//! - an unwind-protect frame runs its cleanup when an unwind passes through it;
//! - a handler frame is a cluster of handlers (handler-bind*);
//! - a restart frame is a cluster of restarts (restart-bind*);
//! - a dynamic frame holds the vars a binding binds (dynamic.zig).
//!
//! An unwind walks the chain from the top, stopping at each unwind-protect on the way to
//! run its cleanup (which then continues the unwind), and lands with longjmp
//! (unwind.c). `signal` walks the chain calling matching handlers, as CL does: while a
//! handler runs, its cluster and every cluster above it are disabled ("skips").

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const hash = @import("hash.zig");
const Value = @import("value.zig").Value;

pub const Kind = enum(u32) { block = 1, unwind = 2, handlers = 3, restarts = 4, scope = 5, barrier = 6, dynamic = 7, transaction = 8 };

/// `sk_frame` up to its jmp_buf, which only C touches.
pub const Frame = extern struct {
    prev: ?*Frame,
    skips: ?*anyopaque,
    serial: u64,
    kind: u32,
    count: u32,
    value: Value,
    a: ?[*]Value,
    b: ?[*]const Value,
    c: ?[*]const Value,
    target: ?*Frame,
    /// The top of the shadow stack when the frame was pushed, which an unwind to it
    /// restores.
    shadow: ?*Shadow,
};

/// A Skein function's entry on the shadow stack, which backtraces read (M2.6, D-081):
/// programs built with --eval push one per call of a compiled function, and the
/// evaluator one per call of an interpreted function. It lives in the caller's C frame.
pub const Shadow = extern struct {
    prev: ?*Shadow,
    name: [*:0]const u8,
    loc: [*:0]const u8,
};

/// While a handler runs, the frames from `from` (the top of the chain when the condition
/// was signaled) down to its cluster are skipped: the search resumes at `to`.
const Skip = struct { from: ?*Frame, to: ?*Frame, next: ?*Skip };

threadlocal var top_tls: ?*Frame = null;
threadlocal var skips_tls: ?*Skip = null;
threadlocal var shadow_tls: ?*Shadow = null;

// The chain and the skips are reached through functions that aren't inlined: code here
// calls handlers and restarts, which can switch fibers, and a fiber can continue on
// another thread (M2.3, D-075), where a kept thread-local address would be wrong.
noinline fn getTop() ?*Frame {
    return top_tls;
}
noinline fn setTop(f: ?*Frame) void {
    top_tls = f;
}
noinline fn getSkips() ?*Skip {
    return skips_tls;
}
noinline fn setSkips(s: ?*Skip) void {
    skips_tls = s;
}
noinline fn getShadow() ?*Shadow {
    return shadow_tls;
}
noinline fn setShadow(s: ?*Shadow) void {
    shadow_tls = s;
}
threadlocal var next_serial: u64 = 0;

/// Each thread numbers frames in a range of its own, so serials stay unique when fibers
/// move between threads (M2.2).
var thread_ranges = std.atomic.Value(u64).init(0);

noinline fn nextSerial() u64 {
    if (next_serial == 0) next_serial = (thread_ranges.fetchAdd(1, .monotonic) + 1) << 40;
    next_serial += 1;
    return next_serial;
}

/// The running fiber's chain of frames and skipped handler clusters, which a fiber switch
/// saves and restores (M2.2, D-074).
pub const FiberState = struct { top: ?*Frame = null, skips: ?*anyopaque = null, shadow: ?*Shadow = null };

pub fn saveFiberState() FiberState {
    return .{ .top = getTop(), .skips = getSkips(), .shadow = getShadow() };
}

pub fn restoreFiberState(s: FiberState) void {
    setTop(s.top);
    setSkips(@ptrCast(@alignCast(s.skips)));
    setShadow(s.shadow);
}

pub fn pushShadow(s: *Shadow, name: [*:0]const u8, loc: [*:0]const u8) void {
    s.* = .{ .prev = getShadow(), .name = name, .loc = loc };
    setShadow(s);
}

pub fn popShadow(s: *Shadow) void {
    setShadow(s.prev);
}

/// [[name location]...] for the Skein functions on this fiber's stack, innermost first.
pub fn backtrace() Value {
    var out = coll.vectorOf(&.{});
    var s = getShadow();
    while (s) |x| : (s = x.prev) {
        out = coll.vectorConj(out, coll.vectorOf(&.{ string.make(std.mem.span(x.name)), string.make(std.mem.span(x.loc)) }));
    }
    return out;
}

extern fn sk_jump(f: *Frame) noreturn;
extern fn sk_warn_condition(c: Value) void;

fn skipsOf(f: *Frame) ?*Skip {
    return @ptrCast(@alignCast(f.skips));
}

fn push(f: *Frame, kind: Kind) void {
    const serial = nextSerial();
    f.* = .{
        .prev = getTop(),
        .skips = getSkips(),
        .serial = serial,
        .kind = @intFromEnum(kind),
        .count = 0,
        .value = Value.nil,
        .a = null,
        .b = null,
        .c = null,
        .target = null,
        .shadow = getShadow(),
    };
    setTop(f);
}

pub fn pushFrame(f: *Frame, kind: Kind) void {
    push(f, kind);
}

/// Push a handler cluster; `types` (condition types, or symbols naming them) are
/// resolved to types in place.
pub fn pushHandlers(f: *Frame, types: []Value, fns: [*]const Value) void {
    for (types) |*t| t.* = findType(t.*, null);
    push(f, .handlers);
    f.count = @intCast(types.len);
    f.a = types.ptr;
    f.b = fns;
}

/// Push a restart cluster: names (symbols), functions (nil for a restart that returns to
/// this frame) and reports (strings or nil).
pub fn pushRestarts(f: *Frame, restart_names: []Value, fns: [*]const Value, reports: [*]const Value) void {
    for (restart_names) |n| {
        if (!names.isSymbol(n)) raise(.@"error", "{s} does not name a restart", .{readable(n)});
    }
    push(f, .restarts);
    f.count = @intCast(restart_names.len);
    f.a = restart_names.ptr;
    f.b = fns;
    f.c = reports;
}

pub fn popFrame(f: *Frame) void {
    setTop(f.prev);
}

pub fn topFrame() ?*Frame {
    return getTop();
}

/// Unwind to `target` (which must be on the chain), delivering `v`, running the cleanups
/// of the unwind-protects on the way. A barrier (where C called Skein) stops the unwind:
/// it is jumped to like an unwind-protect, but doesn't continue.
pub fn unwindTo(target: *Frame, v: Value) noreturn {
    while (getTop()) |f| {
        if (f == target) {
            f.value = v;
            setSkips(skipsOf(f));
            setShadow(f.shadow);
            sk_jump(f);
        }
        setTop(f.prev);
        if (f.kind == @intFromEnum(Kind.unwind) or f.kind == @intFromEnum(Kind.barrier)) {
            f.target = target;
            f.value = v;
            setSkips(skipsOf(f));
            setShadow(f.shadow);
            sk_jump(f);
        }
    }
    rt.fatal("internal error: an unwind lost its target frame", .{});
}

/// return-from* through a captured block token: the block's serial.
pub fn returnFrom(token: Value, v: Value) noreturn {
    const serial: u64 = @intCast(token.toFixnum());
    var f = getTop();
    while (f) |fr| : (f = fr.prev) {
        if (fr.serial == serial and fr.kind == @intFromEnum(Kind.block)) unwindTo(fr, v);
    }
    raise(.@"error", "return-from* to a block that has already returned", .{});
}

// ---------------------------------------------------------------------------------------
// Condition types

/// The built-in condition types. Each is skein.core/<name, with - for _>.
pub const Builtin = enum {
    condition,
    @"error",
    warning,
    arithmetic_error,
    type_error,
    index_error,
    arity_error,
    unbound_var_error,
    not_callable_error,
    unsupported_operation_error,
    transient_error,
    namespace_error,
    // Concurrency (DESIGN §13, M1.8 step 6): cancelled is not an error.
    cancelled,
    timeout,
    task_cancelled_error,
    // A fiber ran out of stack (M2.2, D-024).
    stack_overflow,
    // (ex-info message data): an error carrying a map (M2.11, D-093). Its slots are data
    // and cause.
    ex_info,

    fn parent(b: Builtin) ?Builtin {
        return switch (b) {
            .condition => null,
            .@"error", .warning, .cancelled => .condition,
            else => .@"error",
        };
    }

    /// "skein.core/arithmetic-error"
    pub fn qualifiedName(b: Builtin) []const u8 {
        return builtin_names[@intFromEnum(b)];
    }
};

const builtin_names = blk: {
    var result: [std.enums.values(Builtin).len][]const u8 = undefined;
    for (std.enums.values(Builtin), 0..) |b, i| {
        var buf: [@tagName(b).len]u8 = undefined;
        for (@tagName(b), 0..) |ch, j| buf[j] = if (ch == '_') '-' else ch;
        const final = buf;
        result[i] = "skein.core/" ++ final;
    }
    break :blk result;
};

pub var builtin_types: [std.enums.values(Builtin).len]Value = @splat(Value.nil);

var types_lock: platform.Mutex = .{};
pub var registry: std.StringHashMapUnmanaged(Value) = .empty;
const table_alloc = std.heap.page_allocator;

// A type's slots.
const t_name = 0; // the qualified name, a string
const t_parents = 1; // a vector of types
const t_slots = 2; // a vector of [symbol initform-fn]
const t_report = 3; // a function of the condition, or nil
const t_defined = 4; // true if defcondition made it

fn typeSlot(t: Value, i: usize) Value {
    return coll.get(t, i);
}

fn setTypeSlot(t: Value, i: usize, v: Value) void {
    const h = t.toObject();
    gc.store(h, &h.valueSlots()[i], v);
}

pub fn typeName(t: Value) []const u8 {
    return string.bytes(typeSlot(t, t_name));
}

fn newType(qualified: []const u8, parents: Value, slots: Value, report: Value, defined: bool) Value {
    const name_string = string.make(qualified);
    const h = gc.allocPermanent(.condition_type, 5);
    const t = Value.fromObject(h);
    setTypeSlot(t, t_name, name_string);
    setTypeSlot(t, t_parents, parents);
    setTypeSlot(t, t_slots, slots);
    setTypeSlot(t, t_report, report);
    setTypeSlot(t, t_defined, Value.fromBool(defined));
    return t;
}

fn register(qualified: []const u8, t: Value) void {
    types_lock.lock();
    defer types_lock.unlock();
    const key = table_alloc.dupe(u8, qualified) catch @panic("out of memory");
    registry.put(table_alloc, key, t) catch @panic("out of memory");
}

/// The condition type with this qualified name, or null.
pub fn typeByName(qualified: []const u8) ?Value {
    ensureBuiltins();
    return lookup(qualified);
}

fn lookup(qualified: []const u8) ?Value {
    types_lock.lock();
    defer types_lock.unlock();
    return registry.get(qualified);
}

/// Make the built-in types. sk_init calls this on the main thread before any code runs.
pub fn ensureBuiltins() void {
    if (builtin_types[0] != Value.nil) return;
    inline for (comptime std.enums.values(Builtin)) |b| {
        const parents = if (b.parent()) |p|
            coll.vectorOf(&.{builtin_types[@intFromEnum(p)]})
        else
            coll.vectorOf(&.{});
        const slots = if (b == .ex_info) coll.vectorOf(&.{
            coll.vectorOf(&.{ names.symbol(null, "data"), Value.nil }),
            coll.vectorOf(&.{ names.symbol(null, "cause"), Value.nil }),
        }) else coll.vectorOf(&.{});
        const t = newType(Builtin.qualifiedName(b), parents, slots, Value.nil, false);
        register(Builtin.qualifiedName(b), t);
        builtin_types[@intFromEnum(b)] = t;
    }
}

pub fn builtinType(b: Builtin) Value {
    ensureBuiltins();
    return builtin_types[@intFromEnum(b)];
}

pub fn isType(v: Value) bool {
    return v.isObjectOf(.condition_type);
}

/// True if condition `c` is of type `t` or a type descended from it.
pub fn isA(c: Value, t: Value) bool {
    return typeIsA(conditionType(c), t);
}

fn typeIsA(t: Value, ancestor: Value) bool {
    if (t == ancestor) return true;
    const parents = typeSlot(t, t_parents);
    for (0..coll.vectorCount(parents)) |i| {
        if (typeIsA(coll.vectorNth(parents, i).?, ancestor)) return true;
    }
    return false;
}

/// The condition type `x` names: a type, or a symbol. A qualified symbol names a type by
/// its full name; an unqualified one is looked up in `ns` (if known), then skein.core, then
/// among every type with that unqualified name, which must be unique. The C backend
/// qualifies the symbols in a program's code when it compiles them (D-047).
pub fn findType(x: Value, ns: ?[]const u8) Value {
    ensureBuiltins();
    if (isType(x)) return x;
    if (!names.isSymbol(x)) raise(.@"error", "{s} is not a condition type", .{readable(x)});
    const name = names.nameOf(x);
    var buf: [512]u8 = undefined;
    if (names.nsOf(x)) |q| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ q, name }) catch "";
        if (lookup(full)) |t| return t;
        raise(.@"error", "{s} is not a condition type", .{readable(x)});
    }
    if (ns) |n| {
        if (lookup(std.fmt.bufPrint(&buf, "{s}/{s}", .{ n, name }) catch "")) |t| return t;
    }
    if (lookup(std.fmt.bufPrint(&buf, "skein.core/{s}", .{name}) catch "")) |t| return t;
    var found: ?Value = null;
    var ambiguous = false;
    {
        types_lock.lock();
        defer types_lock.unlock();
        var it = registry.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const slash = std.mem.lastIndexOfScalar(u8, key, '/') orelse continue;
            if (std.mem.eql(u8, key[slash + 1 ..], name)) {
                if (found != null) ambiguous = true;
                found = entry.value_ptr.*;
            }
        }
    }
    if (ambiguous) raise(.@"error", "condition type {s} is ambiguous; qualify it with its namespace", .{name});
    return found orelse raise(.@"error", "{s} is not a condition type", .{readable(x)});
}

/// defcondition: create or redefine the type `name` (a qualified symbol).
pub fn defineType(name: Value, parents: Value, slots: Value, report: Value) Value {
    if (!names.isSymbol(name)) raise(.@"error", "{s} is not a condition type name", .{readable(name)});
    var buf: [512]u8 = undefined;
    const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ names.nsOf(name) orelse "user", names.nameOf(name) }) catch
        raise(.@"error", "the condition type name {s} is too long", .{names.nameOf(name)});
    const parent_vector = if (coll.isVector(parents)) parents else coll.vectorOf(&.{});
    for (0..coll.vectorCount(parent_vector)) |i| {
        if (!isType(coll.vectorNth(parent_vector, i).?))
            raise(.@"error", "{s} is not a condition type", .{readable(coll.vectorNth(parent_vector, i).?)});
    }
    if (lookup(qualified)) |t| {
        setTypeSlot(t, t_parents, parent_vector);
        setTypeSlot(t, t_slots, slots);
        setTypeSlot(t, t_report, report);
        setTypeSlot(t, t_defined, Value.true);
        return t;
    }
    const t = newType(qualified, parent_vector, slots, report, true);
    register(qualified, t);
    return t;
}

/// The qualified name of a type as a symbol: skein.core/error.
pub fn typeNameSymbol(t: Value) Value {
    const full = typeName(t);
    const slash = std.mem.lastIndexOfScalar(u8, full, '/').?;
    return names.symbol(full[0..slash], full[slash + 1 ..]);
}

/// Call f(ctx, slot symbol, initform) for every slot of `t`: its own, then its parents'.
fn eachSlot(t: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value, Value) void) void {
    const slots = typeSlot(t, t_slots);
    if (coll.isVector(slots)) {
        for (0..coll.vectorCount(slots)) |i| {
            const spec = coll.vectorNth(slots, i).?;
            f(ctx, coll.vectorNth(spec, 0).?, coll.vectorNth(spec, 1) orelse Value.nil);
        }
    }
    const parents = typeSlot(t, t_parents);
    for (0..coll.vectorCount(parents)) |i| eachSlot(coll.vectorNth(parents, i).?, ctx, f);
}

fn hasSlot(t: Value, name: []const u8) bool {
    const Find = struct {
        name: []const u8,
        found: bool = false,
        fn slot(c: *@This(), sym: Value, _: Value) void {
            if (std.mem.eql(u8, names.nameOf(sym), c.name)) c.found = true;
        }
    };
    var ctx: Find = .{ .name = name };
    eachSlot(t, &ctx, Find.slot);
    return ctx.found;
}

// ---------------------------------------------------------------------------------------
// Conditions: [type, message (string or nil), slots (map of plain slot symbol to value)]

pub fn isCondition(v: Value) bool {
    return v.isObjectOf(.condition);
}

pub fn conditionType(c: Value) Value {
    return coll.get(c, 0);
}

fn make(t: Value, text: Value, slots: Value) Value {
    const h = rt.alloc(.condition, 3);
    const s = h.valueSlots();
    s[0] = t;
    s[1] = text;
    s[2] = slots;
    return Value.fromObject(h);
}

/// A condition of a built-in type with a message.
pub fn makeBuiltin(b: Builtin, text: []const u8) Value {
    const m = string.make(text);
    return make(builtinType(b), m, coll.mapOf(&.{}));
}

/// make-condition: a condition of type `spec` from keyword initargs.
pub fn makeCondition(spec: Value, initargs: []const Value) Value {
    const t = findType(spec, null);
    var i: usize = 0;
    while (i < initargs.len) : (i += 2) {
        const k = initargs[i];
        if (!names.isKeyword(k)) raise(.@"error", "condition initargs must be keywords, not {s}", .{readable(k)});
        if (!hasSlot(t, names.nameOf(k))) raise(.@"error", "{s} has no slot {s}", .{ typeName(t), names.nameOf(k) });
    }
    const Fill = struct {
        initargs: []const Value,
        slots: Value,
        fn slot(c: *@This(), sym: Value, initform: Value) void {
            const plain = names.symbol(null, names.nameOf(sym));
            if (coll.mapGet(c.slots, plain) != null) return; // a child's slot shadows
            var value = Value.nil;
            var j: usize = 0;
            while (j + 1 < c.initargs.len) : (j += 2) {
                if (std.mem.eql(u8, names.nameOf(c.initargs[j]), names.nameOf(sym))) {
                    value = c.initargs[j + 1];
                    break;
                }
            }
            // As in Phase 0, a nil initarg counts as missing.
            if (value == Value.nil and initform != Value.nil) value = func.call(initform, 0, &.{});
            c.slots = coll.mapAssoc(c.slots, plain, value);
        }
    };
    var ctx: Fill = .{ .initargs = initargs, .slots = coll.mapOf(&.{}) };
    eachSlot(t, &ctx, Fill.slot);
    return make(t, Value.nil, ctx.slots);
}

/// (ex-info message data cause?): an ex-info error.
pub fn exInfo(message: Value, data: Value, cause: Value) Value {
    if (!string.isString(message)) raise(.type_error, "ex-info needs a message string, not {s}", .{readable(message)});
    if (!coll.isMap(data)) raise(.type_error, "ex-info needs a map of data, not {s}", .{readable(data)});
    if (cause != Value.nil and !isCondition(cause)) raise(.type_error, "ex-info's cause must be a condition, not {s}", .{readable(cause)});
    const slots = coll.mapOf(&.{ names.symbol(null, "data"), data, names.symbol(null, "cause"), cause });
    return make(builtinType(.ex_info), message, slots);
}

/// The value of slot `name` of condition `c`, or null if it has none.
pub fn slotValue(c: Value, name: []const u8) ?Value {
    if (!isCondition(c)) return null;
    return coll.mapGet(coll.get(c, 2), names.symbol(null, name));
}

/// %condition-slot: the slot or an error.
pub fn slot(c: Value, name: Value) Value {
    const n = if (names.isSymbol(name) or names.isKeyword(name)) names.nameOf(name) else
        raise(.@"error", "{s} is not a slot name", .{readable(name)});
    return slotValue(c, n) orelse raise(.@"error", "{s} has no slot {s}", .{ readable(c), n });
}

fn isDefined(t: Value) bool {
    return typeSlot(t, t_defined) == Value.true;
}

/// Append the condition's message (condition-message) to `out`.
pub fn writeReport(c: Value, out: *std.ArrayList(u8)) void {
    const t = conditionType(c);
    if (isDefined(t)) {
        const report = typeSlot(t, t_report);
        if (report != Value.nil) {
            const args = [_]Value{c};
            return print.write(func.call(report, 1, &args), out, false);
        }
        // "type {:slot value ...}", every slot in order.
        const Pairs = struct {
            c: Value,
            map: Value,
            any: bool = false,
            fn slot(ctx: *@This(), sym: Value, _: Value) void {
                const k = names.keyword(null, names.nameOf(sym));
                if (coll.mapGet(ctx.map, k) != null) return;
                ctx.any = true;
                ctx.map = coll.mapAssoc(ctx.map, k, slotValue(ctx.c, names.nameOf(sym)) orelse Value.nil);
            }
        };
        var ctx: Pairs = .{ .c = c, .map = coll.mapOf(&.{}) };
        eachSlot(t, &ctx, Pairs.slot);
        print.put(out, typeName(t));
        if (ctx.any) {
            print.put(out, " ");
            print.write(ctx.map, out, true);
        }
        return;
    }
    const text = coll.get(c, 1);
    if (text != Value.nil) print.put(out, string.bytes(text)) else print.put(out, typeName(t));
}

pub fn messageOf(c: Value) Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    writeReport(c, &out);
    return string.make(out.items);
}

fn readable(v: Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    print.write(v, &out, true);
    return out.items;
}

// ---------------------------------------------------------------------------------------
// Signaling

/// Call every applicable handler, innermost first. Returns if none unwinds.
pub fn signal(c: Value) void {
    if (!isCondition(c)) raise(.@"error", "signal needs a condition, not {s}", .{readable(c)});
    const t = conditionType(c);
    var f = getTop();
    outer: while (f) |fr| {
        var s = getSkips();
        while (s) |sk| : (s = sk.next) {
            if (sk.from == fr) {
                f = sk.to;
                continue :outer;
            }
        }
        if (fr.kind == @intFromEnum(Kind.handlers)) {
            for (0..fr.count) |i| {
                if (typeIsA(t, fr.a.?[i])) {
                    var skip: Skip = .{ .from = getTop(), .to = fr.prev, .next = getSkips() };
                    setSkips(&skip);
                    const args = [_]Value{c};
                    _ = func.call(fr.b.?[i], 1, &args);
                    setSkips(skip.next);
                }
            }
        }
        f = fr.prev;
    }
}

/// error and throw-condition: signal `c`; if no handler unwinds, report it and exit.
pub fn signalError(c: Value) noreturn {
    signal(c);
    unhandled(c);
}

pub fn warn(c: Value) void {
    sk_warn_condition(c);
}

/// Called by unwind.c when no handler muffled a warning.
pub fn reportWarning(c: Value) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    print.put(&out, "WARNING: ");
    writeReport(c, &out);
    print.put(&out, "\n");
    platform.writeStderr(out.items);
}

/// [the debugger]: a function that `unhandled` calls first, in the failing fiber, if a
/// program installed one (skein.dev, M2.6, D-081). It returns only if it doesn't handle
/// the error.
var debugger: [1]Value = .{Value.nil};
var debugger_ready = false;

pub fn installDebugger(f: Value) void {
    if (!debugger_ready) {
        gc.addRoots(&debugger);
        debugger_ready = true;
    }
    debugger[0] = f;
}

/// What `skein run` prints for an unhandled error: the message and the restarts that are
/// active. The program then exits with status 1. An installed debugger runs first.
fn unhandled(c: Value) noreturn {
    if (debugger[0] != Value.nil) {
        const args = [_]Value{c};
        _ = func.call(debugger[0], 1, &args);
    }
    reportAndExit(c);
}

/// Print an unhandled error as `skein run` does (the message and the restarts active here)
/// and exit with status 1, without the debugger: also a nursery's :crash policy (D-088).
pub fn reportAndExit(c: Value) noreturn {
    var out: std.ArrayList(u8) = .empty;
    print.put(&out, "error: ");
    writeReport(c, &out);
    var first = true;
    var f = getTop();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(Kind.restarts)) continue;
        for (0..fr.count) |i| {
            if (fr.b.?[i] == Value.nil) continue; // the runtime's own (muffle-warning)
            if (first) print.put(&out, "\navailable restarts:");
            first = false;
            print.put(&out, "\n  ");
            print.write(plainName(fr.a.?[i]), &out, true);
            print.put(&out, ": ");
            writeRestartReport(fr, i, &out);
        }
    }
    print.put(&out, "\n");
    platform.writeStderr(out.items);
    std.process.exit(1);
}

/// Signal an error of built-in type `b` with a formatted message (the runtime's own
/// errors: division by zero, a bad index, ...).
pub fn raise(b: Builtin, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const tail = "...";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf[0..];
    };
    signalError(makeBuiltin(b, text));
}

/// The arguments of error, signal and warn as a condition: a condition as it is, a
/// message string joined with its arguments as println does, or a type and initargs.
pub fn toCondition(x: Value, args: []const Value, kind: Builtin) Value {
    if (isCondition(x)) return x;
    if (string.isString(x)) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(rt.scratch);
        print.put(&out, string.bytes(x));
        for (args) |a| {
            print.put(&out, " ");
            print.write(a, &out, false);
        }
        return makeBuiltin(kind, out.items);
    }
    return makeCondition(x, args);
}

// ---------------------------------------------------------------------------------------
// Restarts: [name (plain symbol), report (string), frame serial, index]

fn plainName(sym: Value) Value {
    if (names.nsOf(sym) == null) return sym;
    return names.symbol(null, names.nameOf(sym));
}

fn writeRestartReport(f: *Frame, i: usize, out: *std.ArrayList(u8)) void {
    const report = f.c.?[i];
    if (report == Value.nil) print.put(out, names.nameOf(f.a.?[i])) else print.write(report, out, false);
}

fn restartObject(f: *Frame, i: usize) Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    writeRestartReport(f, i, &out);
    const report = string.make(out.items);
    const name = plainName(f.a.?[i]);
    const h = rt.alloc(.restart, 4);
    const s = h.valueSlots();
    s[0] = name;
    s[1] = report;
    s[2] = Value.fromFixnum(@intCast(f.serial));
    s[3] = Value.fromFixnum(@intCast(i));
    return Value.fromObject(h);
}

pub fn isRestart(v: Value) bool {
    return v.isObjectOf(.restart);
}

pub fn restartName(r: Value) Value {
    if (!isRestart(r)) raise(.type_error, "restart-name needs a restart, not {s}", .{readable(r)});
    return coll.get(r, 0);
}

pub fn restartReport(r: Value) Value {
    if (!isRestart(r)) raise(.type_error, "restart-report needs a restart, not {s}", .{readable(r)});
    return coll.get(r, 1);
}

const Found = struct { frame: *Frame, index: usize };

/// The active restart that `x` (a restart or a symbol) stands for.
fn activeRestart(x: Value) ?Found {
    if (isRestart(x)) {
        const serial: u64 = @intCast(coll.get(x, 2).toFixnum());
        const i: usize = @intCast(coll.get(x, 3).toFixnum());
        var f = getTop();
        while (f) |fr| : (f = fr.prev) {
            if (fr.serial == serial)
                return if (fr.kind == @intFromEnum(Kind.restarts) and i < fr.count) .{ .frame = fr, .index = i } else null;
        }
        return null;
    }
    if (!names.isSymbol(x)) raise(.@"error", "{s} does not name a restart", .{readable(x)});
    // Restarts match by their plain name (D-041); the innermost wins.
    const name = names.nameOf(x);
    var f = getTop();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(Kind.restarts)) continue;
        for (0..fr.count) |i| {
            if (std.mem.eql(u8, names.nameOf(fr.a.?[i]), name)) return .{ .frame = fr, .index = i };
        }
    }
    return null;
}

pub fn invokeRestart(x: Value, args: []const Value) Value {
    const found = activeRestart(x) orelse
        raise(.@"error", "no restart {s} is active", .{readable(if (isRestart(x)) coll.get(x, 0) else x)});
    const f = found.frame.b.?[found.index];
    if (f == Value.nil) unwindTo(found.frame, Value.nil);
    return func.call(f, @intCast(args.len), args.ptr);
}

pub fn findRestart(x: Value) Value {
    const found = activeRestart(x) orelse return Value.nil;
    return restartObject(found.frame, found.index);
}

/// The active restarts, innermost first, as a list.
pub fn computeRestarts() Value {
    var buf: [256]Value = undefined;
    var n: usize = 0;
    var f = getTop();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(Kind.restarts)) continue;
        for (0..fr.count) |i| {
            if (n == buf.len) break;
            buf[n] = restartObject(fr, i);
            n += 1;
        }
    }
    return coll.listOf(buf[0..n]);
}

/// A hash for conditions, types and restarts that survives the objects moving.
pub fn hashOf(v: Value) u32 {
    return switch (v.toObject().type_id) {
        .condition => hash.hashString(typeName(conditionType(v))),
        .condition_type => hash.hashString(typeName(v)),
        else => @truncate(@as(u64, @bitCast(coll.get(v, 2).toFixnum()))),
    };
}

/// Print a condition, type or restart as Phase 0 does.
pub fn write(v: Value, out: *std.ArrayList(u8)) void {
    switch (v.toObject().type_id) {
        .condition => {
            print.put(out, "#<");
            print.put(out, typeName(conditionType(v)));
            print.put(out, " ");
            writeReport(v, out);
            print.put(out, ">");
        },
        .condition_type => {
            print.put(out, "#<condition-type ");
            print.put(out, typeName(v));
            print.put(out, ">");
        },
        else => {
            print.put(out, "#<restart ");
            print.write(coll.get(v, 0), out, true);
            print.put(out, ">");
        },
    }
}

// ---------------------------------------------------------------------------------------
// The C interface

export fn sk_shadow_push(s: *Shadow, name: [*:0]const u8, loc: [*:0]const u8) void {
    pushShadow(s, name, loc);
}

export fn sk_shadow_pop(s: *Shadow) void {
    popShadow(s);
}

export fn sk_frame_push(f: *Frame, kind: u32) void {
    push(f, @enumFromInt(kind));
}

export fn sk_frame_push_handlers(f: *Frame, count: u32, types: [*]Value, fns: [*]const Value) void {
    pushHandlers(f, types[0..count], fns);
}

export fn sk_frame_push_restarts(f: *Frame, count: u32, restart_names: [*]Value, fns: [*]const Value, reports: [*]const Value) void {
    pushRestarts(f, restart_names[0..count], fns, reports);
}

export fn sk_frame_pop(f: *Frame) void {
    popFrame(f);
}

export fn sk_unwind_to(f: *Frame, v: Value) noreturn {
    unwindTo(f, v);
}

export fn sk_return_from(token: Value, v: Value) noreturn {
    returnFrom(token, v);
}

export fn sk_continue_unwind(f: *Frame) noreturn {
    unwindTo(f.target.?, f.value);
}

export fn sk_throw_condition(c: Value) noreturn {
    if (!isCondition(c)) raise(.@"error", "throw-condition needs a condition, not {s}", .{readable(c)});
    signalError(c);
}

export fn sk_muffle_warning_name() Value {
    return names.symbol(null, "muffle-warning");
}

export fn sk_signal_condition(c: Value) void {
    signal(c);
}

export fn sk_report_warning(c: Value) void {
    reportWarning(c);
}
