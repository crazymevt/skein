//! The FFI natively (DESIGN §14, M1.10, D-065): skein.ffi's functions, matching Phase 0
//! (host/src/ffi/ffi.lisp, D-038).
//!
//! - A C pointer is a `foreign_ptr` object holding its address; NULL is nil. `ffi/own`
//!   and ^:owned results make an `owned_ptr`, which the GC frees when it dies.
//! - Structs, unions and enums are `ctype` objects, registered by qualified name. Their
//!   layouts follow C's rules for the primitive types: each field at a multiple of its
//!   alignment, the size rounded up to the largest alignment.
//! - Foreign types arrive as data: a primitive symbol (i32, ptr, c-string ...), a ctype,
//!   a qualified symbol naming one (the C backend qualifies them), or a list (ptr T),
//!   (fn ...) or (array T n).
//! - Libraries load when deflibrary runs; C functions are looked up by name in them, then
//!   in the rest of the process (`symbol`, for the C backend's calls, step 2).

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const num = @import("num.zig");
const print = @import("print.zig");
const seq = @import("seq.zig");
const string = @import("string.zig");
const structs = @import("structs.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

/// Signal an ffi-error (natively an error whose message is Phase 0's).
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    rt.raise(.@"error", fmt, args);
}

fn kw(v: Value, text: []const u8) bool {
    return names.isKeyword(v) and names.nsOf(v) == null and std.mem.eql(u8, names.nameOf(v), text);
}

// ---------------------------------------------------------------------------------------
// Pointers

pub fn makePointer(address: usize) Value {
    if (address == 0) return Value.nil;
    const h = rt.alloc(.foreign_ptr, 1);
    h.payload()[0] = address;
    return Value.fromObject(h);
}

fn freeOwned(h: *object.Header) void {
    const address = h.payload()[0];
    if (address != 0) std.c.free(@ptrFromInt(address));
}

/// The owned pointer for `address`, freed when it is garbage (DESIGN §14.2); nil for 0.
pub fn makeOwned(address: usize) Value {
    if (address == 0) return Value.nil;
    const h = rt.alloc(.owned_ptr, 1);
    h.payload()[0] = address;
    gc.addFinalizer(h, freeOwned);
    return Value.fromObject(h);
}

/// #<ptr 0x...>, as natively printed (Phase 0 prints SBCL's own form).
pub fn write(v: Value, out: *std.ArrayList(u8)) void {
    var buf: [64]u8 = undefined;
    switch (v.toObject().type_id) {
        .foreign_ptr, .owned_ptr => print.put(out, std.fmt.bufPrint(&buf, "#<ptr 0x{x}>", .{v.toObject().payload()[0]}) catch "#<ptr>"),
        .ctype => {
            print.put(out, "#<ctype ");
            print.put(out, ctypeName(v));
            print.put(out, ">");
        },
        else => print.put(out, "#<object>"),
    }
}

pub fn isPointer(x: Value) bool {
    return x.isObjectOf(.foreign_ptr) or x.isObjectOf(.owned_ptr);
}

/// The address a ptr argument passes: nil is NULL; a pointer its address; a primitive
/// array, view or byte view the address of its first element (the caller keeps it
/// referenced from the stack, which pins it).
pub fn toAddress(x: Value) usize {
    if (x == Value.nil) return 0;
    if (x.isObjectOf(.foreign_ptr)) return x.toObject().payload()[0];
    if (x.isObjectOf(.owned_ptr)) {
        const a = x.toObject().payload()[0];
        if (a == 0) fail("the pointer was already freed", .{});
        return a;
    }
    if (structs.arrayAddress(x)) |a| return a;
    fail("expected a pointer, nil or an array of a primitive type, not {s}", .{readable(x)});
}

// ---------------------------------------------------------------------------------------
// Types

const Prim = enum { i8, i16, i32, i64, u8, u16, u32, u64, f32, f64, bool, void, @"c-string", ptr };

fn primSize(p: Prim) usize {
    return switch (p) {
        .i8, .u8, .bool => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .void => 0,
        else => 8,
    };
}

fn primOf(t: Value) ?Prim {
    if (!names.isSymbol(t) or names.nsOf(t) != null) return null;
    return std.meta.stringToEnum(Prim, names.nameOf(t));
}

// A ctype: [name, kind, size, align, fields-or-values, base].
const t_name = 0;
const t_kind = 1;
const t_size = 2;
const t_align = 3;
const t_fields = 4;
const t_base = 5;
const kind_struct = 0;
const kind_union = 1;
const kind_enum = 2;

var registry_lock: platform.Mutex = .{};
var registry: std.StringHashMapUnmanaged(Value) = .empty;

fn register(qualified: []const u8, t: Value) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    const key = if (registry.getKey(qualified)) |k| k else alloc.dupe(u8, qualified) catch rt.fatal("out of memory", .{});
    registry.put(alloc, key, t) catch rt.fatal("out of memory", .{});
}

fn lookup(qualified: []const u8) ?Value {
    registry_lock.lock();
    defer registry_lock.unlock();
    return registry.get(qualified);
}

fn get(v: Value, i: usize) Value {
    return coll.get(v, i);
}

fn kindOf(t: Value) i64 {
    return get(t, t_kind).toFixnum();
}

fn listHead(t: Value) ?[]const u8 {
    if (!(t.isObjectOf(.list))) return null;
    const h = seq.first(t);
    return if (names.isSymbol(h)) names.nameOf(h) else null;
}

fn listArg(t: Value, i: usize) Value {
    var s = seq.next(t);
    var n = i;
    while (n > 0) : (n -= 1) s = seq.next(s);
    return seq.first(s);
}

fn qualifiedName(sym: Value, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ names.nsOf(sym).?, names.nameOf(sym) }) catch "";
}

/// A type with structs, unions and enums looked up: a primitive symbol, a ctype, or a
/// (ptr ...), (fn ...) or (array T n) list.
fn resolve(t: Value) Value {
    if (t.isObjectOf(.ctype) or primOf(t) != null) return t;
    if (names.isSymbol(t)) {
        if (names.nsOf(t) != null) {
            var buf: [512]u8 = undefined;
            if (lookup(qualifiedName(t, &buf))) |c| return c;
        }
        fail("unknown foreign type {s}", .{readable(t)});
    }
    if (listHead(t)) |h| {
        if (std.mem.eql(u8, h, "ptr") or std.mem.eql(u8, h, "fn") or std.mem.eql(u8, h, "array")) return t;
    }
    fail("unsupported foreign type {s}", .{readable(t)});
}

const Layout = struct { size: usize, alignment: usize };

/// The size and alignment of a (resolved) type stored in memory or a struct.
fn layout(t: Value) Layout {
    if (primOf(t)) |p| {
        const n = primSize(p);
        return .{ .size = n, .alignment = @max(n, 1) };
    }
    if (t.isObjectOf(.ctype)) {
        if (kindOf(t) == kind_enum) return layout(resolve(get(t, t_base)));
        return .{ .size = coll.ux(get(t, t_size)), .alignment = coll.ux(get(t, t_align)) };
    }
    const h = listHead(t).?;
    if (std.mem.eql(u8, h, "array")) {
        const e = layout(resolve(listArg(t, 0)));
        const n = listArg(t, 1);
        if (!n.isFixnum() or n.toFixnum() < 0) fail("an array type needs a length, not {s}", .{readable(n)});
        return .{ .size = e.size * @as(usize, @intCast(n.toFixnum())), .alignment = e.alignment };
    }
    return .{ .size = 8, .alignment = 8 }; // ptr, fn
}

fn isInline(t: Value) bool {
    if (t.isObjectOf(.ctype)) return kindOf(t) != kind_enum;
    if (listHead(t)) |h| return std.mem.eql(u8, h, "array");
    return false;
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) / a * a;
}

fn symbolName(v: Value, comptime what: []const u8) []const u8 {
    if (!names.isSymbol(v)) fail(what ++ " must be a symbol, not {s}", .{readable(v)});
    return names.nameOf(v);
}

/// %define-struct: the struct or union `name` (a qualified symbol) with `fields`, a
/// vector of [field-symbol type].
fn defineStruct(name: Value, kind: Value, fields: Value) Value {
    var buf: [512]u8 = undefined;
    const qualified = qualifiedName(name, &buf);
    const union_p = kw(kind, "union");
    var out = coll.vectorOf(&.{});
    var offset: usize = 0;
    var size: usize = 0;
    var max_align: usize = 1;
    var s = seq.seq(fields);
    while (s != Value.nil) : (s = seq.seqNext(s)) {
        const f = seq.seqFirst(s);
        const fname = string.make(symbolName(coll.vectorNth(f, 0).?, "a field name"));
        const ftype = resolve(coll.vectorNth(f, 1) orelse Value.nil);
        if (primOf(ftype)) |p| if (p == .void) fail("a field can't have type void", .{});
        const l = layout(ftype);
        max_align = @max(max_align, l.alignment);
        const at = if (union_p) 0 else alignUp(offset, l.alignment);
        out = coll.vectorConj(out, coll.vectorOf(&.{ fname, ftype, coll.fx(at) }));
        if (union_p) size = @max(size, l.size) else offset = at + l.size;
    }
    if (!union_p) size = offset;
    // A permanent object is old: storing young values into it needs the write barrier.
    const h = gc.allocPermanent(.ctype, 6);
    const t = Value.fromObject(h);
    coll.set(t, t_name, string.make(qualified));
    coll.set(t, t_kind, coll.fx(if (union_p) kind_union else kind_struct));
    coll.set(t, t_size, coll.fx(alignUp(size, max_align)));
    coll.set(t, t_align, coll.fx(max_align));
    coll.set(t, t_fields, out);
    coll.set(t, t_base, Value.nil);
    register(qualified, t);
    return t;
}

/// %define-enum: the enum `name` with integer type `base` and `values`, a vector of
/// keyword, integer, keyword, integer ...
fn defineEnum(name: Value, base: Value, values: Value) Value {
    var buf: [512]u8 = undefined;
    const qualified = qualifiedName(name, &buf);
    var map = coll.mapOf(&.{});
    var s = seq.seq(values);
    while (s != Value.nil) : (s = seq.seqNext(seq.seqNext(s))) {
        map = coll.mapAssoc(map, seq.seqFirst(s), seq.first(seq.seqNext(s)));
    }
    // A permanent object is old: storing young values into it needs the write barrier.
    const h = gc.allocPermanent(.ctype, 6);
    const t = Value.fromObject(h);
    coll.set(t, t_name, string.make(qualified));
    coll.set(t, t_kind, coll.fx(kind_enum));
    coll.set(t, t_size, Value.nil);
    coll.set(t, t_align, Value.nil);
    coll.set(t, t_fields, map);
    coll.set(t, t_base, base);
    register(qualified, t);
    return t;
}

fn ctypeName(t: Value) []const u8 {
    return string.bytes(get(t, t_name));
}

/// The integer value of `x` for the enum `t`: a keyword, a collection of keywords (ORed
/// together, for flags), an integer, or nil (0).
pub fn enumValue(t: Value, x: Value) Value {
    if (num.isInteger(x)) return x;
    if (x == Value.nil) return coll.fx(0);
    if (names.isKeyword(x)) {
        return coll.mapGet(get(t, t_fields), x) orelse fail("{s} has no value {s}", .{ ctypeName(t), readable(x) });
    }
    var acc: i64 = 0;
    var s = seq.seq(x);
    while (s != Value.nil) : (s = seq.seqNext(s)) acc |= toI64(enumValue(t, seq.seqFirst(s)));
    return num.fromI128(acc);
}

fn toI64(v: Value) i64 {
    if (v.isFixnum()) return v.toFixnum();
    if (num.isInteger(v)) {
        // Wider than a fixnum: keep the low 64 bits, as C's conversions do.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(rt.scratch);
        print.write(v, &buf, false);
        const wide = std.fmt.parseInt(i128, buf.items, 10) catch 0;
        return @truncate(wide);
    }
    fail("expected an integer, not {s}", .{readable(v)});
}

// ---------------------------------------------------------------------------------------
// Values in memory

fn cString(address: usize) Value {
    if (address == 0) return Value.nil;
    const p: [*:0]const u8 = @ptrFromInt(address);
    const bytes = std.mem.span(p);
    if (!std.unicode.utf8ValidateSlice(bytes)) fail("the C string is not valid UTF-8", .{});
    return string.make(bytes);
}

/// A NUL-terminated copy of the string `s` in C memory (malloc), which C may keep.
pub fn cStringCopy(s: Value) usize {
    if (s == Value.nil) return 0;
    if (!string.isString(s)) fail("expected a string, not {s}", .{readable(s)});
    const b = string.bytes(s);
    const p: [*]u8 = @ptrCast(std.c.malloc(b.len + 1) orelse rt.fatal("out of memory", .{}));
    @memcpy(p[0..b.len], b);
    p[b.len] = 0;
    return @intFromPtr(p);
}

/// Read the value of (resolved) type `t` at `address`.
fn readAt(address: usize, t: Value) Value {
    if (t.isObjectOf(.ctype)) {
        if (kindOf(t) == kind_enum) return readAt(address, resolve(get(t, t_base)));
        fail("{s} is a {s}; pass it by pointer, as (ptr ...)", .{ ctypeName(t), if (kindOf(t) == kind_union) "union" else "struct" });
    }
    if (primOf(t)) |p| {
        const a = address;
        return switch (p) {
            .i8 => num.fromI128(@as(*const i8, @ptrFromInt(a)).*),
            .i16 => num.fromI128(@as(*align(1) const i16, @ptrFromInt(a)).*),
            .i32 => num.fromI128(@as(*align(1) const i32, @ptrFromInt(a)).*),
            .i64 => num.fromI128(@as(*align(1) const i64, @ptrFromInt(a)).*),
            .u8 => num.fromI128(@as(*const u8, @ptrFromInt(a)).*),
            .u16 => num.fromI128(@as(*align(1) const u16, @ptrFromInt(a)).*),
            .u32 => num.fromI128(@as(*align(1) const u32, @ptrFromInt(a)).*),
            .u64 => num.fromI128(@as(*align(1) const u64, @ptrFromInt(a)).*),
            .f32 => Value.fromF32(@as(*align(1) const f32, @ptrFromInt(a)).*),
            .f64 => num.boxF64(@as(*align(1) const f64, @ptrFromInt(a)).*),
            .bool => Value.fromBool(@as(*const u8, @ptrFromInt(a)).* != 0),
            .void => Value.nil,
            .@"c-string" => cString(@as(*align(1) const usize, @ptrFromInt(a)).*),
            .ptr => makePointer(@as(*align(1) const usize, @ptrFromInt(a)).*),
        };
    }
    if (listHead(t)) |h| if (std.mem.eql(u8, h, "array")) fail("unsupported foreign type {s}", .{readable(t)});
    return makePointer(@as(*align(1) const usize, @ptrFromInt(address)).*);
}

fn toF64(v: Value, comptime what: []const u8) f64 {
    if (num.kind(v) == .other) fail("expected a number for " ++ what ++ ", not {s}", .{readable(v)});
    return num.toF64(v);
}

/// Write `v` as (resolved) type `t` at `address`.
fn writeAt(address: usize, t: Value, v: Value) void {
    if (t.isObjectOf(.ctype)) {
        if (kindOf(t) == kind_enum) return writeAt(address, resolve(get(t, t_base)), enumValue(t, v));
        fail("{s} is a {s}; pass it by pointer, as (ptr ...)", .{ ctypeName(t), if (kindOf(t) == kind_union) "union" else "struct" });
    }
    const a = address;
    if (primOf(t)) |p| switch (p) {
        .i8, .u8 => @as(*u8, @ptrFromInt(a)).* = @truncate(@as(u64, @bitCast(toI64(v)))),
        .i16, .u16 => @as(*align(1) u16, @ptrFromInt(a)).* = @truncate(@as(u64, @bitCast(toI64(v)))),
        .i32, .u32 => @as(*align(1) u32, @ptrFromInt(a)).* = @truncate(@as(u64, @bitCast(toI64(v)))),
        .i64, .u64 => @as(*align(1) u64, @ptrFromInt(a)).* = @bitCast(toI64(v)),
        .f32 => @as(*align(1) f32, @ptrFromInt(a)).* = @floatCast(toF64(v, "f32")),
        .f64 => @as(*align(1) f64, @ptrFromInt(a)).* = toF64(v, "f64"),
        .bool => @as(*u8, @ptrFromInt(a)).* = if (v.isTruthy()) 1 else 0,
        .void => fail("can't store a value of type void", .{}),
        .@"c-string" => @as(*align(1) usize, @ptrFromInt(a)).* = cStringCopy(v),
        .ptr => @as(*align(1) usize, @ptrFromInt(a)).* = toAddress(v),
    } else {
        if (listHead(t)) |h| if (std.mem.eql(u8, h, "array")) fail("unsupported foreign type {s}", .{readable(t)});
        @as(*align(1) usize, @ptrFromInt(a)).* = toAddress(v);
    }
}

fn typeSize(t_in: Value) usize {
    return layout(resolve(t_in)).size;
}

fn allocMemory(t: Value, n: Value) Value {
    if (!n.isFixnum() or n.toFixnum() < 0) fail("alloc needs a count, not {s}", .{readable(n)});
    const bytes = typeSize(t) * @as(usize, @intCast(n.toFixnum()));
    const p = std.c.calloc(@max(bytes, 1), 1) orelse rt.fatal("out of memory", .{});
    return makePointer(@intFromPtr(p));
}

fn freeMemory(p: Value) Value {
    if (p == Value.nil) return Value.nil;
    if (p.isObjectOf(.owned_ptr)) {
        const slot = &p.toObject().payload()[0];
        const a = slot.*;
        slot.* = 0;
        if (a != 0) std.c.free(@ptrFromInt(a));
        return Value.nil;
    }
    std.c.free(@ptrFromInt(toAddress(p)));
    return Value.nil;
}

fn memGet(p: Value, t_in: Value, index: Value) Value {
    const t = resolve(t_in);
    const i = toI64(index);
    const at: usize = @bitCast(@as(i64, @bitCast(toAddress(p))) + i * @as(i64, @intCast(layout(t).size)));
    return readAt(at, t);
}

fn memPut(p: Value, t_in: Value, v: Value, index: Value) Value {
    const t = resolve(t_in);
    const i = toI64(index);
    const at: usize = @bitCast(@as(i64, @bitCast(toAddress(p))) + i * @as(i64, @intCast(layout(t).size)));
    writeAt(at, t, v);
    return v;
}

const Field = struct { offset: usize, type: Value };

fn findField(t_in: Value, key: Value) Field {
    const t = resolve(t_in);
    if (!t.isObjectOf(.ctype) or kindOf(t) == kind_enum) fail("{s} is not a struct or union", .{readable(t_in)});
    if (!names.isKeyword(key)) fail("struct fields are named by keywords, not {s}", .{readable(key)});
    const fields = get(t, t_fields);
    for (0..coll.vectorCount(fields)) |i| {
        const f = coll.vectorNth(fields, i).?;
        if (std.mem.eql(u8, string.bytes(coll.vectorNth(f, 0).?), names.nameOf(key)))
            return .{ .offset = coll.ux(coll.vectorNth(f, 2).?), .type = coll.vectorNth(f, 1).? };
    }
    fail("{s} has no field {s}", .{ ctypeName(t), readable(key) });
}

fn fieldGet(p: Value, t: Value, key: Value) Value {
    const f = findField(t, key);
    const at = toAddress(p) + f.offset;
    // A nested struct, union or array: its address, to read further.
    if (isInline(f.type)) return makePointer(at);
    return readAt(at, f.type);
}

fn fieldPut(p: Value, t: Value, key: Value, v: Value) Value {
    const f = findField(t, key);
    if (isInline(f.type)) fail("the field {s} holds a struct, union or array; write to its parts through the pointer that (field ...) returns", .{readable(key)});
    writeAt(toAddress(p) + f.offset, f.type, v);
    return v;
}

// ---------------------------------------------------------------------------------------
// Handles (DESIGN §14.2): stable integer tokens for Skein objects that C holds.

var handles_lock: platform.Mutex = .{};
var handle_roots: [1]Value = .{Value.nil};
var handles_ready = false;
var next_handle: i64 = 0;

fn ensureHandles() void {
    if (!handles_ready) {
        handle_roots[0] = coll.mapOf(&.{});
        gc.addRoots(&handle_roots);
        handles_ready = true;
    }
}

fn makeHandle(x: Value) Value {
    handles_lock.lock();
    defer handles_lock.unlock();
    ensureHandles();
    next_handle += 1;
    const h = coll.fx(@intCast(next_handle));
    handle_roots[0] = coll.mapAssoc(handle_roots[0], h, x);
    return h;
}

fn handleValue(h: Value) Value {
    handles_lock.lock();
    defer handles_lock.unlock();
    ensureHandles();
    return coll.mapGet(handle_roots[0], h) orelse fail("{s} is not a live handle", .{readable(h)});
}

fn freeHandle(h: Value) Value {
    handles_lock.lock();
    defer handles_lock.unlock();
    ensureHandles();
    handle_roots[0] = coll.mapDissoc(handle_roots[0], h);
    return Value.nil;
}

// ---------------------------------------------------------------------------------------
// Libraries and symbols

var libraries_lock: platform.Mutex = .{};
var libraries: std.ArrayListUnmanaged(*anyopaque) = .empty;

fn tryLoad(path: []const u8, why: []u8) bool {
    const z = alloc.dupeSentinel(u8, path, 0) catch rt.fatal("out of memory", .{});
    defer alloc.free(z);
    const h = platform.loadLibrary(z, why) orelse return false;
    libraries_lock.lock();
    defer libraries_lock.unlock();
    libraries.append(alloc, h) catch rt.fatal("out of memory", .{});
    return true;
}

/// Try `name` next to the executable (and where a package keeps libraries, D-069), in
/// SKEIN_LIBRARY_PATH's directories, the usual package-manager directories for this OS,
/// then the system's search.
fn loadOne(name: []const u8, why: []u8) bool {
    var buf: [1024]u8 = undefined;
    var exe_buf: [1024]u8 = undefined;
    if (std.process.executableDirPath(@import("io.zig").stdIo(), &exe_buf)) |n| {
        for (platform.executable_library_directories) |sub| {
            const path = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ exe_buf[0..n], sub, name }) catch continue;
            if (tryLoad(path, why)) return true;
        }
    } else |_| {}
    if (std.c.getenv("SKEIN_LIBRARY_PATH")) |env| {
        var it = std.mem.splitScalar(u8, std.mem.span(env), platform.path_list_separator);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const sep: []const u8 = if (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\') "" else "/";
            const path = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, sep, name }) catch continue;
            if (tryLoad(path, why)) return true;
        }
    }
    for (platform.library_directories) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ dir, name }) catch continue;
        if (tryLoad(path, why)) return true;
    }
    return tryLoad(name, why);
}

/// deflibrary: load the library that `spec` names for this OS (a map from :macos, :linux
/// and :windows to a file name or a vector of names to try). Returns the name that loaded.
fn loadLibrary(spec: Value) Value {
    const key = names.keyword(null, platform.os_name);
    const v = (if (coll.isMap(spec)) coll.mapGet(spec, key) else null) orelse
        fail("no library given for {s} in {s}", .{ platform.os_name, readable(spec) });
    var why: [512]u8 = @splat(0);
    var tried: std.ArrayList(u8) = .empty;
    defer tried.deinit(rt.scratch);
    var s = if (string.isString(v)) coll.listOf(&.{v}) else seq.seq(v);
    while (s != Value.nil) : (s = seq.seqNext(s)) {
        const name = seq.seqFirst(s);
        if (!string.isString(name)) fail("a library name must be a string, not {s}", .{readable(name)});
        if (loadOne(string.bytes(name), &why)) return name;
        if (tried.items.len > 0) print.put(&tried, " or ");
        print.put(&tried, string.bytes(name));
    }
    fail("could not load {s}: {s}", .{ tried.items, std.mem.sliceTo(&why, 0) });
}

/// The address of the C function or variable `name`: in the libraries loaded by
/// deflibrary, in load order, then anywhere in the process; 0 if there is none.
pub fn symbol(name: [:0]const u8) usize {
    libraries_lock.lock();
    const libs = libraries.items;
    for (libs) |h| {
        if (platform.librarySymbol(h, name)) |p| {
            libraries_lock.unlock();
            return @intFromPtr(p);
        }
    }
    libraries_lock.unlock();
    return if (platform.processSymbol(name)) |p| @intFromPtr(p) else 0;
}

/// For the C backend's calls (step 2): the address of `name`, or an error naming it.
export fn sk_ffi_symbol(name: [*:0]const u8) usize {
    const a = symbol(std.mem.span(name));
    if (a == 0) fail("the C function {s} was not found; load its library with ffi/deflibrary", .{std.mem.span(name)});
    return a;
}

// ---------------------------------------------------------------------------------------
// For the C backend's compiled calls (defcfun, M1.10 step 2): converting arguments and
// results, blocking calls and the slow-call warning. Declared in include/skein.h.

export fn sk_ffi_to_int(v: Value) i64 {
    return toI64(v);
}

export fn sk_ffi_to_f64(v: Value) f64 {
    return toF64(v, "a float argument");
}

export fn sk_ffi_to_address(v: Value) usize {
    return toAddress(v);
}

/// A C string argument: a NUL-terminated copy of the string, or NULL for nil. The call
/// frees it afterwards (sk_ffi_free_cstring).
export fn sk_ffi_to_cstring(v: Value) usize {
    return cStringCopy(v);
}

export fn sk_ffi_free_cstring(p: usize) void {
    if (p != 0) std.c.free(@ptrFromInt(p));
}

/// An enum argument: the value of `v` for the enum registered as `qualified`.
export fn sk_ffi_enum(qualified: [*:0]const u8, v: Value) i64 {
    const t = lookup(std.mem.span(qualified)) orelse fail("unknown foreign type {s}", .{std.mem.span(qualified)});
    return toI64(enumValue(t, v));
}

export fn sk_ffi_from_i64(n: i64) Value {
    return num.fromI128(n);
}

export fn sk_ffi_from_u64(n: u64) Value {
    return num.fromI128(n);
}

export fn sk_ffi_pointer(address: usize) Value {
    return makePointer(address);
}

export fn sk_ffi_owned(address: usize) Value {
    return makeOwned(address);
}

export fn sk_ffi_from_cstring(p: usize) Value {
    return cString(p);
}

const Blocking = struct { f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque };

fn runBlocking(arg: ?*anyopaque) void {
    const b: *Blocking = @ptrCast(@alignCast(arg));
    b.f(b.arg);
}

/// A ^:blocking call: run `f(arg)` (the C call, which must not touch the heap) while
/// collections may go ahead without this thread (DESIGN §14.3).
export fn sk_ffi_blocking(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    var b: Blocking = .{ .f = f, .arg = arg };
    gc.blocking(runBlocking, &b);
}

export fn sk_ffi_now() u64 {
    return platform.monotonicNanos();
}

/// After a call not marked ^:blocking: if it took more than 10 ms, warn, once per
/// function (`warned` is the function's flag), as Phase 0 does.
export fn sk_ffi_check_slow(start: u64, warned: *c_int, c_name: [*:0]const u8) void {
    if (platform.monotonicNanos() - start <= 10 * std.time.ns_per_ms) return;
    if (@atomicRmw(c_int, warned, .Xchg, 1, .acq_rel) != 0) return;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "the C function {s} took more than 10 ms; mark it ^:blocking if it waits", .{std.mem.span(c_name)}) catch "a C function took more than 10 ms";
    const cond = @import("cond.zig");
    cond.warn(cond.makeBuiltin(.warning, text));
}

extern fn sk_try_call_stopping_exits(f: Value, argc: u32, argv: [*]const Value, ntypes: u32, types: [*]Value) Value;

fn warnCode(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    @import("cond.zig").warn(argv[0]);
    return Value.nil;
}

/// For the C backend's callbacks (defcallback, M1.10 step 3, D-068): call `body` with a
/// pointer to `frame`, the C call's arguments and result, which body converts. Neither an
/// error nor any other non-local exit can unwind through C: one is caught or stopped
/// here, and C gets the zero the frame holds. That warns, naming the callback `name` and
/// `zero` (none if it's empty), as in Phase 0. The warning is signaled inside a barrier
/// too, so a handler outside that tries to exit is stopped silently.
export fn sk_ffi_callback(body: Value, frame: usize, name: [*:0]const u8, zero: [*:0]const u8) void {
    const entry = gc.enterFromC();
    defer gc.leaveToC(entry);
    const cond = @import("cond.zig");
    var types = [_]Value{cond.builtinType(.@"error")};
    const args = [_]Value{makePointer(frame)};
    const r = sk_try_call_stopping_exits(body, 1, &args, 1, &types);
    const returned = r != Value.nil and coll.vectorNth(r, 0).?.toFixnum() == -1;
    if (returned) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    print.put(&out, "callback ");
    print.put(&out, std.mem.span(name));
    if (r == Value.nil) {
        print.put(&out, " tried to exit through C");
    } else {
        print.put(&out, " signaled ");
        cond.writeReport(coll.vectorNth(r, 1).?, &out);
    }
    if (zero[0] != 0) {
        print.put(&out, "; returning ");
        print.put(&out, std.mem.span(zero));
    }
    const warning = [_]Value{cond.makeBuiltin(.warning, out.items)};
    _ = sk_try_call_stopping_exits(@import("func.zig").make(warnCode, "warn"), 1, &warning, 0, &types);
}

/// [kind base name] for a C type (the C backend's %ctype-info): kind is :struct, :union
/// or :enum, base an enum's integer type, name the qualified name. nil for anything else.
fn ctypeInfo(t: Value) Value {
    if (!t.isObjectOf(.ctype)) return Value.nil;
    const k = kindOf(t);
    const kind = names.keyword(null, if (k == kind_struct) "struct" else if (k == kind_union) "union" else "enum");
    return coll.vectorOf(&.{ kind, get(t, t_base), get(t, t_name) });
}

// ---------------------------------------------------------------------------------------
// skein.ffi functions (core.zig's table includes these, named skein.ffi/<name>)

const Args = []const Value;

pub const Entry = struct {
    name: []const u8,
    min: u32,
    max: ?u32,
    impl: *const fn (Args) Value,
};

fn opt(a: Args, i: usize, default: Value) Value {
    return if (a.len > i) a[i] else default;
}

pub const entries = [_]Entry{
    .{ .name = "%ctype-info", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return ctypeInfo(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/%load-library", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return loadLibrary(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/load-library", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return loadLibrary(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/%define-struct", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return defineStruct(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "skein.ffi/%define-enum", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return defineEnum(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "skein.ffi/%type", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return a[0];
        }
    }.f },
    .{ .name = "skein.ffi/%alloc", .min = 1, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return allocMemory(a[0], opt(a, 1, coll.fx(1)));
        }
    }.f },
    .{ .name = "skein.ffi/free", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return freeMemory(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/own", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return makeOwned(toAddress(a[0]));
        }
    }.f },
    .{ .name = "skein.ffi/null", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return Value.nil;
        }
    }.f },
    .{ .name = "skein.ffi/null?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(toAddress(a[0]) == 0);
        }
    }.f },
    .{ .name = "skein.ffi/ptr?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(isPointer(a[0]));
        }
    }.f },
    .{ .name = "skein.ffi/address", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return num.fromI128(toAddress(a[0]));
        }
    }.f },
    .{ .name = "skein.ffi/ptr+", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return makePointer(@bitCast(@as(i64, @bitCast(toAddress(a[0]))) + toI64(a[1])));
        }
    }.f },
    .{ .name = "skein.ffi/%sizeof", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return coll.fx(typeSize(a[0]));
        }
    }.f },
    .{ .name = "skein.ffi/%get", .min = 2, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return memGet(a[0], a[1], opt(a, 2, coll.fx(0)));
        }
    }.f },
    .{ .name = "skein.ffi/%put!", .min = 3, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return memPut(a[0], a[1], a[2], opt(a, 3, coll.fx(0)));
        }
    }.f },
    .{ .name = "skein.ffi/%field", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return fieldGet(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "skein.ffi/%put-field!", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return fieldPut(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "skein.ffi/c-string", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return if (a[0] == Value.nil) Value.nil else cString(toAddress(a[0]));
        }
    }.f },
    .{ .name = "skein.ffi/enum-value", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            const t = resolve(a[0]);
            if (!t.isObjectOf(.ctype) or kindOf(t) != kind_enum) fail("{s} is not an enum", .{readable(a[0])});
            return enumValue(t, a[1]);
        }
    }.f },
    .{ .name = "skein.ffi/handle", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return makeHandle(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/handle-value", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return handleValue(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/free-handle", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return freeHandle(a[0]);
        }
    }.f },
    .{ .name = "skein.ffi/%call-pinned", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            // The array stays pinned: this frame refers to it while fn runs.
            const p = makePointer(toAddress(a[0]));
            const args = [_]Value{p};
            const v = @import("func.zig").call(a[1], 1, &args);
            std.mem.doNotOptimizeAway(a[0]);
            return v;
        }
    }.f },
};

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testField(n: []const u8, t: Value) Value {
    return coll.vectorOf(&.{ names.symbol(null, n), t });
}

/// Define the test's types in a frame of their own, so no stale stack word keeps their
/// young parts in place.
noinline fn defineTestTypes() void {
    const sym = names.symbol;
    _ = defineStruct(sym("t", "point"), names.keyword(null, "struct"), coll.vectorOf(&.{
        testField("x", sym(null, "i32")), testField("y", sym(null, "i32")),
    }));
    _ = defineStruct(sym("t", "mixed"), names.keyword(null, "struct"), coll.vectorOf(&.{
        testField("a", sym(null, "u8")),  testField("b", sym(null, "f64")),
        testField("c", sym(null, "u16")), testField("p", sym("t", "point")),
    }));
    _ = defineStruct(sym("t", "u"), names.keyword(null, "union"), coll.vectorOf(&.{
        testField("i", sym(null, "i64")), testField("f", sym(null, "f32")),
    }));
}

noinline fn scrubStack() void {
    var junk: [16384]usize = undefined;
    @memset(&junk, 0);
    std.mem.doNotOptimizeAway(&junk);
}

test "struct layouts follow C, and survive collections" {
    coll.ensureConstants();
    defineTestTypes();
    scrubStack();
    // Regression (M1.10): the name and fields are young objects stored into a permanent
    // ctype, which needs the write barrier to survive a minor collection. Collect, then
    // allocate enough to reuse the nursery, so a stale pointer would read garbage.
    for (0..4) |_| {
        gc.collect(.minor);
        for (0..20000) |i| _ = string.make(if (i % 2 == 0) "xxxxxxxxxxxxxxxxxxxxxxxx" else "yy");
    }
    gc.collect(.major);
    const point = lookup("t/point").?;
    const mixed = lookup("t/mixed").?;
    const u = lookup("t/u").?;
    try testing.expectEqual(@as(usize, 8), typeSize(point));
    try testing.expectEqual(@as(usize, 32), typeSize(mixed));
    try testing.expectEqual(@as(usize, 8), typeSize(u));
    try testing.expectEqualStrings("t/mixed", ctypeName(mixed));
    try testing.expectEqual(@as(usize, 20), findField(mixed, names.keyword(null, "p")).offset);
    try testing.expectEqual(@as(usize, 16), findField(mixed, names.keyword(null, "c")).offset);
    try testing.expectEqualStrings("t/point", ctypeName(point));
}

test "C functions are found in the C and math libraries" {
    // Regression (M1.10): on Linux, libm's functions weren't found natively (D-067).
    try testing.expect(symbol("strlen") != 0);
    try testing.expect(symbol("exp") != 0);
    try testing.expect(symbol("cbrt") != 0);
    try testing.expectEqual(@as(usize, 0), symbol("skein_no_such_function_42"));
}
