//! Value structs, records, typed arrays and defsoa natively (DESIGN §9, M1.8 step 5,
//! D-055), matching Phase 0's structs.lisp and arrays.lisp.
//!
//! A struct value is boxed: its def, then its fields. Arrays of primitive types pack their
//! elements at their natural width (an f32 array is 4 bytes an element). An array of value
//! structs keeps one primitive array per leaf field (nested value structs flattened), so
//! its elements are stored inline; reading one builds the struct.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const num = @import("num.zig");
const equal = @import("equal.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;

fn readable(v: Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    print.write(v, &out, true);
    return out.items;
}

fn slot(v: Value, i: usize) Value {
    return coll.get(v, i);
}

fn setSlot(v: Value, i: usize, x: Value) void {
    const h = v.toObject();
    gc.store(h, &h.valueSlots()[i], x);
}

var identity_counter = std.atomic.Value(u32).init(0);

fn identity() Value {
    return Value.fromFixnum(hash.mix32(identity_counter.fetchAdd(1, .monotonic) +% 0x9E37));
}

// ---------------------------------------------------------------------------------------
// Element kinds

pub const Kind = enum(u8) {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    fixnum,
    char,

    pub fn size(k: Kind) usize {
        return switch (k) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32, .char => 4,
            else => 8,
        };
    }

    pub fn fromName(text: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, text);
    }
};

/// The kind a type symbol names, if it is a primitive type.
pub fn kindOf(type_sym: Value) ?Kind {
    if (!names.isSymbol(type_sym) or names.nsOf(type_sym) != null) return null;
    return Kind.fromName(names.nameOf(type_sym));
}

fn typeError(comptime what: []const u8, v: Value, k: Kind) noreturn {
    rt.raise(.type_error, what ++ ": {s} is not a {s}", .{ readable(v), @tagName(k) });
}

/// Check that `v` fits kind `k` (as Phase 0's typed CL slots and arrays require).
fn checkKind(comptime what: []const u8, v: Value, k: Kind) void {
    const ok = switch (k) {
        .f32 => v.isF32(),
        .f64 => v.isObjectOf(.f64),
        .char => v.isChar(),
        .fixnum => v.isFixnum(),
        else => blk: {
            if (!v.isFixnum()) break :blk v.isObjectOf(.bignum) and k == .u64 and num.toF64(v) >= 0 and num.toF64(v) < 0x1p64;
            const n = v.toFixnum();
            break :blk switch (k) {
                .i8 => n >= -128 and n <= 127,
                .i16 => n >= -32768 and n <= 32767,
                .i32 => n >= -2147483648 and n <= 2147483647,
                .i64 => true,
                .u8 => n >= 0 and n <= 255,
                .u16 => n >= 0 and n <= 65535,
                .u32 => n >= 0 and n <= 4294967295,
                .u64 => n >= 0,
                else => unreachable,
            };
        },
    };
    if (!ok) typeError(what, v, k);
}

// ---------------------------------------------------------------------------------------
// Primitive arrays: raw words [count, kind, hash], then the elements.

const p_header = 3;

fn primCount(a: Value) usize {
    return @intCast(a.toObject().payload()[0]);
}

fn primKind(a: Value) Kind {
    return @enumFromInt(@as(u8, @intCast(a.toObject().payload()[1])));
}

fn primData(a: Value) [*]u8 {
    return @ptrCast(a.toObject().payload()[p_header..].ptr);
}

pub fn makePrim(k: Kind, n: usize) Value {
    const words = p_header + (n * k.size() + 7) / 8;
    const h = rt.alloc(.prim_array, words);
    const p = h.payload();
    p[0] = n;
    p[1] = @intFromEnum(k);
    p[2] = @intCast(identity().toFixnum());
    return Value.fromObject(h);
}

fn primGet(a: Value, i: usize) Value {
    const d = primData(a);
    return switch (primKind(a)) {
        .i8 => Value.fromFixnum(@as(*const i8, @ptrCast(d + i)).*),
        .u8 => Value.fromFixnum(d[i]),
        .i16 => Value.fromFixnum(std.mem.bytesToValue(i16, d[i * 2 ..][0..2])),
        .u16 => Value.fromFixnum(std.mem.bytesToValue(u16, d[i * 2 ..][0..2])),
        .i32 => Value.fromFixnum(std.mem.bytesToValue(i32, d[i * 4 ..][0..4])),
        .u32 => Value.fromFixnum(std.mem.bytesToValue(u32, d[i * 4 ..][0..4])),
        .i64, .fixnum => num.fromI128(std.mem.bytesToValue(i64, d[i * 8 ..][0..8])),
        .u64 => num.fromI128(std.mem.bytesToValue(u64, d[i * 8 ..][0..8])),
        .f32 => Value.fromF32(std.mem.bytesToValue(f32, d[i * 4 ..][0..4])),
        .f64 => num.boxF64(std.mem.bytesToValue(f64, d[i * 8 ..][0..8])),
        .char => Value.fromChar(@intCast(std.mem.bytesToValue(u32, d[i * 4 ..][0..4]))),
    };
}

fn primSet(a: Value, i: usize, v: Value) void {
    const k = primKind(a);
    checkKind("aset!", v, k);
    const d = primData(a);
    switch (k) {
        .i8 => d[i] = @bitCast(@as(i8, @intCast(v.toFixnum()))),
        .u8 => d[i] = @intCast(v.toFixnum()),
        .i16 => d[i * 2 ..][0..2].* = std.mem.toBytes(@as(i16, @intCast(v.toFixnum()))),
        .u16 => d[i * 2 ..][0..2].* = std.mem.toBytes(@as(u16, @intCast(v.toFixnum()))),
        .i32 => d[i * 4 ..][0..4].* = std.mem.toBytes(@as(i32, @intCast(v.toFixnum()))),
        .u32 => d[i * 4 ..][0..4].* = std.mem.toBytes(@as(u32, @intCast(v.toFixnum()))),
        .i64, .fixnum => d[i * 8 ..][0..8].* = std.mem.toBytes(@as(i64, v.toFixnum())),
        .u64 => d[i * 8 ..][0..8].* = std.mem.toBytes(@as(u64, if (v.isFixnum()) @intCast(v.toFixnum()) else @intFromFloat(num.toF64(v)))),
        .f32 => d[i * 4 ..][0..4].* = std.mem.toBytes(v.toF32()),
        .f64 => d[i * 8 ..][0..8].* = std.mem.toBytes(num.unboxF64(v)),
        .char => d[i * 4 ..][0..4].* = std.mem.toBytes(@as(u32, v.toChar())),
    }
}

fn zeroOf(k: Kind) Value {
    return switch (k) {
        .f32 => Value.fromF32(0),
        .f64 => num.boxF64(0),
        .char => Value.fromChar(0),
        else => Value.fromFixnum(0),
    };
}

// ---------------------------------------------------------------------------------------
// Struct definitions: [name, value?, fields, constructor, predicate]

const d_name = 0;
const d_value = 1;
const d_fields = 2;

var lock: platform.Mutex = .{};
pub var defs: std.StringHashMapUnmanaged(Value) = .empty;
const table_alloc = std.heap.page_allocator;

fn lookup(name: []const u8) ?Value {
    lock.lock();
    defer lock.unlock();
    return defs.get(name);
}

fn register(name: []const u8, def: Value) void {
    lock.lock();
    defer lock.unlock();
    const k = table_alloc.dupe(u8, name) catch @panic("out of memory");
    defs.put(table_alloc, k, def) catch @panic("out of memory");
}

pub fn isDef(v: Value) bool {
    return v.isObjectOf(.struct_def);
}

pub fn defName(def: Value) []const u8 {
    return string.bytes(slot(def, d_name));
}

fn isValueDef(def: Value) bool {
    return slot(def, d_value) == Value.true;
}

fn fieldCount(def: Value) usize {
    return coll.vectorCount(slot(def, d_fields));
}

fn field(def: Value, i: usize) Value {
    return coll.vectorNth(slot(def, d_fields), i).?;
}

fn fieldName(def: Value, i: usize) []const u8 {
    return string.bytes(coll.vectorNth(field(def, i), 0).?);
}

fn fieldKind(def: Value, i: usize) Value {
    return coll.vectorNth(field(def, i), 2).?;
}

fn fieldIndex(def: Value, name: []const u8) ?usize {
    for (0..fieldCount(def)) |i| if (std.mem.eql(u8, fieldName(def, i), name)) return i;
    return null;
}

/// A struct def by qualified name, or by a unique unqualified one.
pub fn findDef(x: Value) ?Value {
    if (isDef(x)) return x;
    if (constructorDef(x)) |d| return d;
    if (!names.isSymbol(x)) return null;
    var buf: [512]u8 = undefined;
    if (names.nsOf(x)) |ns| {
        return lookup(std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(x) }) catch return null);
    }
    lock.lock();
    defer lock.unlock();
    var found: ?Value = null;
    var it = defs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const s = std.mem.lastIndexOfScalar(u8, key, '/') orelse continue;
        if (std.mem.eql(u8, key[s + 1 ..], names.nameOf(x))) found = entry.value_ptr.*;
    }
    return found;
}

/// %define-struct: the def of `name` (a qualified symbol), a value struct if `value_p`,
/// with fields [[symbol type]...]. A def with the same layout is reused.
pub fn defineStruct(name: Value, value_p: bool, fields_in: Value) Value {
    var buf: [512]u8 = undefined;
    const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ names.nsOf(name) orelse "user", names.nameOf(name) }) catch
        rt.raise(.@"error", "the struct name {s} is too long", .{names.nameOf(name)});
    var fields = coll.vectorOf(&.{});
    for (0..coll.vectorCount(fields_in)) |i| {
        const spec = coll.vectorNth(fields_in, i).?;
        const fname = names.nameOf(coll.vectorNth(spec, 0).?);
        const ftype = coll.vectorNth(spec, 1) orelse Value.nil;
        var kind = Value.nil;
        if (ftype == Value.nil) {
            if (value_p) rt.raise(.@"error", "the fields of value struct {s} need types", .{qualified});
        } else if (kindOf(ftype)) |k| {
            kind = Value.fromFixnum(@intFromEnum(k));
        } else if (value_p) {
            const nested = findDef(ftype) orelse Value.nil;
            if (nested == Value.nil or !isValueDef(nested))
                rt.raise(.@"error", "a field of value struct {s} must have a primitive type or another value struct, not {s}", .{ qualified, readable(ftype) });
            kind = nested;
        }
        fields = coll.vectorConj(fields, coll.vectorOf(&.{ string.make(fname), ftype, kind }));
    }
    if (lookup(qualified)) |old| {
        if (sameLayout(old, value_p, fields)) return old;
        // A reload changed it (DESIGN §15, D-091): what was made with the old layout keeps
        // it.
        if (value_p or isValueDef(old)) {
            var msg: [700]u8 = undefined;
            const text = std.fmt.bufPrint(&msg, "WARNING: value struct {s} changed its layout: code compiled against the old one, and values and arrays made with it, keep the old layout until they are reloaded or made again\n", .{qualified}) catch "WARNING: a value struct changed its layout\n";
            platform.writeStderr(text);
        }
    }
    const n = string.make(qualified);
    const h = gc.allocPermanent(.struct_def, 5);
    const def = Value.fromObject(h);
    setSlot(def, d_name, n);
    setSlot(def, d_value, Value.fromBool(value_p));
    setSlot(def, d_fields, fields);
    setSlot(def, 3, func.closure(constructorCode, "constructor", &.{def}));
    setSlot(def, 4, func.closure(predicateCode, "predicate", &.{def}));
    register(qualified, def);
    return def;
}

fn sameLayout(old: Value, value_p: bool, fields: Value) bool {
    if (isValueDef(old) != value_p or fieldCount(old) != coll.vectorCount(fields)) return false;
    for (0..fieldCount(old)) |i| {
        const f = coll.vectorNth(fields, i).?;
        if (!std.mem.eql(u8, fieldName(old, i), string.bytes(coll.vectorNth(f, 0).?))) return false;
        if (!equal.equiv(coll.vectorNth(field(old, i), 1).?, coll.vectorNth(f, 1).?)) return false;
    }
    return true;
}

pub fn constructor(def: Value) Value {
    return slot(def, 3);
}

pub fn predicate(def: Value) Value {
    return slot(def, 4);
}

/// The def a struct constructor function makes, or null.
fn constructorDef(f: Value) ?Value {
    if (!f.isObjectOf(.function) or func.codeOf(f) != constructorCode) return null;
    return func.capturedOf(f, 0);
}

fn checkField(def: Value, i: usize, v: Value) void {
    const kind = fieldKind(def, i);
    if (kind == Value.nil) return;
    if (kind.isFixnum()) {
        checkKind("a struct field", v, @enumFromInt(@as(u8, @intCast(kind.toFixnum()))));
    } else if (!(v.isObjectOf(.@"struct") and slot(v, 0) == kind)) {
        rt.raise(.type_error, "a struct field: {s} is not a {s}", .{ readable(v), defName(kind) });
    }
}

fn makeStruct(def: Value, values: []const Value) Value {
    for (values, 0..) |v, i| checkField(def, i, v);
    const h = rt.alloc(.@"struct", 1 + values.len);
    const s = h.valueSlots();
    s[0] = def;
    @memcpy(s[1 .. 1 + values.len], values);
    return Value.fromObject(h);
}

fn construct(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const def = func.capturedOf(self, 0);
    const n = fieldCount(def);
    if (argc == n) return makeStruct(def, argv[0..n]);
    if (argc == 2 * n and n > 0 and names.isKeyword(argv[0])) {
        var buf: [64]Value = undefined;
        if (n > buf.len) rt.raise(.unsupported_operation_error, "a struct with more than 64 fields", .{});
        for (0..n) |i| {
            buf[i] = for (0..n) |j| {
                const k = argv[2 * j];
                if (names.isKeyword(k) and std.mem.eql(u8, names.nameOf(k), fieldName(def, i))) break argv[2 * j + 1];
            } else rt.raise(.@"error", "{s} needs a value for :{s}", .{ defName(def), fieldName(def, i) });
        }
        return makeStruct(def, buf[0..n]);
    }
    rt.raise(.arity_error, "{s} takes {d} field value{s}, or each field as :name value", .{ defName(def), n, if (n == 1) "" else "s" });
}

const constructorCode: func.Code = construct;

fn isA(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    const def = func.capturedOf(self, 0);
    return Value.fromBool(argv[0].isObjectOf(.@"struct") and slot(argv[0], 0) == def);
}

const predicateCode: func.Code = isA;

fn access(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const def = func.capturedOf(self, 0);
    const i: usize = @intCast(func.capturedOf(self, 1).toFixnum());
    if (argc != 1) rt.raise(.arity_error, "wrong number of arguments ({d}) passed to {s}-{s}", .{ argc, defName(def), fieldName(def, i) });
    const x = argv[0];
    if (!(x.isObjectOf(.@"struct") and slot(x, 0) == def))
        rt.raise(.type_error, "{s}-{s} needs a {s}, not {s}", .{ defName(def), fieldName(def, i), defName(def), readable(x) });
    return slot(x, 1 + i);
}

/// The accessor of field `i` of `def`.
pub fn accessor(def: Value, i: usize) Value {
    return func.closure(access, "accessor", &.{ def, Value.fromFixnum(@intCast(i)) });
}

pub fn isStruct(v: Value) bool {
    return v.isObjectOf(.@"struct");
}

pub fn structDef(v: Value) Value {
    return slot(v, 0);
}

/// A struct's field by keyword, or null.
pub fn get(x: Value, key: Value) ?Value {
    if (!names.isKeyword(key)) return null;
    const i = fieldIndex(slot(x, 0), names.nameOf(key)) orelse return null;
    return slot(x, 1 + i);
}

pub fn keys(x: Value) Value {
    const def = slot(x, 0);
    var buf: [64]Value = undefined;
    const n = @min(fieldCount(def), buf.len);
    for (0..n) |i| buf[i] = names.keyword(null, fieldName(def, i));
    return coll.listOf(buf[0..n]);
}

pub fn equiv(a: Value, b: Value) bool {
    if (!b.isObjectOf(.@"struct") or slot(a, 0) != slot(b, 0)) return false;
    for (0..fieldCount(slot(a, 0))) |i| if (!equal.equiv(slot(a, 1 + i), slot(b, 1 + i))) return false;
    return true;
}

/// As Phase 0: the name's hash, then 31h + the hash of each field, mixed.
pub fn hashOf(x: Value) u32 {
    const def = slot(x, 0);
    var h: u32 = hash.hashString(defName(def));
    for (0..fieldCount(def)) |i| h = h *% 31 +% equal.hashOf(slot(x, 1 + i));
    return hash.mix32(h);
}

/// with on a struct: a copy with the fields in kvs changed.
pub fn with(x: Value, kvs: []const Value) Value {
    const def = slot(x, 0);
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) {
        const k = kvs[i];
        if (!names.isKeyword(k) or fieldIndex(def, names.nameOf(k)) == null)
            rt.raise(.@"error", "{s} has no field {s}", .{ defName(def), readable(k) });
    }
    var buf: [64]Value = undefined;
    const n = fieldCount(def);
    for (0..n) |f| {
        buf[f] = slot(x, 1 + f);
        var j: usize = 0;
        while (j + 1 < kvs.len) : (j += 2) {
            if (std.mem.eql(u8, names.nameOf(kvs[j]), fieldName(def, f))) buf[f] = kvs[j + 1];
        }
    }
    return makeStruct(def, buf[0..n]);
}

fn writeFields(out: *std.ArrayList(u8), def: Value, values: anytype, readably: bool) void {
    print.put(out, "{");
    for (0..fieldCount(def)) |i| {
        if (i > 0) print.put(out, ", ");
        print.put(out, ":");
        print.put(out, fieldName(def, i));
        print.put(out, " ");
        print.write(values.get(i), out, readably);
    }
    print.put(out, "}");
}

pub fn writeStruct(x: Value, out: *std.ArrayList(u8), readably: bool) void {
    print.put(out, "#<");
    print.put(out, defName(slot(x, 0)));
    print.put(out, " ");
    const V = struct {
        x: Value,
        fn get(c: @This(), i: usize) Value {
            return slot(c.x, 1 + i);
        }
    };
    writeFields(out, slot(x, 0), V{ .x = x }, readably);
    print.put(out, ">");
}

// ---------------------------------------------------------------------------------------
// Arrays of value structs: [def, count, columns, hash], a column per leaf field.

fn leafCount(def: Value) usize {
    var n: usize = 0;
    for (0..fieldCount(def)) |i| {
        const k = fieldKind(def, i);
        n += if (k.isFixnum()) 1 else leafCount(k);
    }
    return n;
}

fn addColumns(def: Value, n: usize, columns: *Value) void {
    for (0..fieldCount(def)) |i| {
        const k = fieldKind(def, i);
        if (k.isFixnum()) {
            columns.* = coll.vectorConj(columns.*, makePrim(@enumFromInt(@as(u8, @intCast(k.toFixnum()))), n));
        } else addColumns(k, n, columns);
    }
}

fn makeStructArray(def: Value, n: usize) Value {
    var columns = coll.vectorOf(&.{});
    addColumns(def, n, &columns);
    const h = rt.alloc(.struct_array, 4);
    const s = h.valueSlots();
    s[0] = def;
    s[1] = Value.fromFixnum(@intCast(n));
    s[2] = columns;
    s[3] = identity();
    return Value.fromObject(h);
}

fn column(a: Value, c: usize) Value {
    return coll.vectorNth(slot(a, 2), c).?;
}

/// The struct of `def` stored in the columns of `a` from `start`, at index i; also the
/// next column.
fn buildStruct(def: Value, a: Value, start: usize, i: usize, next: *usize) Value {
    var buf: [64]Value = undefined;
    var c = start;
    const n = fieldCount(def);
    for (0..n) |f| {
        const k = fieldKind(def, f);
        if (k.isFixnum()) {
            buf[f] = primGet(column(a, c), i);
            c += 1;
        } else buf[f] = buildStruct(k, a, c, i, &c);
    }
    next.* = c;
    return makeStruct(def, buf[0..n]);
}

fn storeStruct(def: Value, a: Value, start: usize, i: usize, v: Value, next: *usize) void {
    if (!(v.isObjectOf(.@"struct") and slot(v, 0) == def))
        rt.raise(.unsupported_operation_error, "expected a {s}, not {s}", .{ defName(def), readable(v) });
    var c = start;
    for (0..fieldCount(def)) |f| {
        const k = fieldKind(def, f);
        if (k.isFixnum()) {
            primSet(column(a, c), i, slot(v, 1 + f));
            c += 1;
        } else storeStruct(k, a, c, i, slot(v, 1 + f), &c);
    }
    next.* = c;
}

/// Field `name` of def: its index and first column.
fn fieldColumn(def: Value, name: []const u8) struct { usize, usize } {
    var c: usize = 0;
    for (0..fieldCount(def)) |f| {
        if (std.mem.eql(u8, fieldName(def, f), name)) return .{ f, c };
        const k = fieldKind(def, f);
        c += if (k.isFixnum()) 1 else leafCount(k);
    }
    rt.raise(.unsupported_operation_error, "{s} has no field {s}", .{ defName(def), name });
}

fn structArrayField(a: Value, i: usize, name: []const u8) Value {
    const def = slot(a, 0);
    checkIndex(a, i);
    const f, const c = fieldColumn(def, name);
    const k = fieldKind(def, f);
    if (k.isFixnum()) return primGet(column(a, c), i);
    var next: usize = 0;
    return buildStruct(k, a, c, i, &next);
}

fn setStructArrayField(a: Value, i: usize, name: []const u8, v: Value) void {
    const def = slot(a, 0);
    checkIndex(a, i);
    const f, const c = fieldColumn(def, name);
    const k = fieldKind(def, f);
    if (k.isFixnum()) return primSet(column(a, c), i, v);
    var next: usize = 0;
    storeStruct(k, a, c, i, v, &next);
}

// ---------------------------------------------------------------------------------------
// Arrays in general

pub fn isArray(v: Value) bool {
    if (!v.isObject()) return false;
    return switch (v.toObject().type_id) {
        .prim_array, .any_array, .struct_array, .array_view => true,
        else => false,
    };
}

pub fn count(a: Value) usize {
    return switch (a.toObject().type_id) {
        .prim_array => primCount(a),
        .any_array, .array_view => @intCast(slot(a, if (a.isObjectOf(.any_array)) 0 else 2).toFixnum()),
        .struct_array => @intCast(slot(a, 1).toFixnum()),
        .byte_view => primCount(slot(a, 0)) * primKind(slot(a, 0)).size(),
        else => unreachable,
    };
}

fn checkIndex(a: Value, i: usize) void {
    const n = count(a);
    if (i >= n) rt.raise(.index_error, "index {d} is out of bounds for an array of {d}", .{ i, n });
}

fn index(v: Value, a: Value) usize {
    if (!v.isFixnum() or v.toFixnum() < 0) rt.raise(.index_error, "index {s} is out of bounds for an array of {d}", .{ readable(v), count(a) });
    return @intCast(v.toFixnum());
}

pub fn aget(a: Value, iv: Value) Value {
    if (!isArray(a)) rt.raise(.unsupported_operation_error, "aget needs an array, not {s}", .{readable(a)});
    const i = index(iv, a);
    checkIndex(a, i);
    return switch (a.toObject().type_id) {
        .prim_array => primGet(a, i),
        .any_array => slot(a, 2 + i),
        .array_view => primGet(slot(a, 0), @as(usize, @intCast(slot(a, 1).toFixnum())) + i),
        .struct_array => blk: {
            var next: usize = 0;
            break :blk buildStruct(slot(a, 0), a, 0, i, &next);
        },
        else => unreachable,
    };
}

pub fn aset(a: Value, iv: Value, v: Value) Value {
    if (!isArray(a)) rt.raise(.unsupported_operation_error, "aset! needs an array, not {s}", .{readable(a)});
    const i = index(iv, a);
    checkIndex(a, i);
    switch (a.toObject().type_id) {
        .prim_array => primSet(a, i, v),
        .any_array => setSlot(a, 2 + i, v),
        .array_view => primSet(slot(a, 0), @as(usize, @intCast(slot(a, 1).toFixnum())) + i, v),
        .struct_array => {
            var next: usize = 0;
            storeStruct(slot(a, 0), a, 0, i, v, &next);
        },
        else => unreachable,
    }
    return v;
}

/// %make-array: n zeroed elements of the type `type_sym` names.
pub fn makeArray(type_sym: Value, nv: Value) Value {
    if (!nv.isFixnum() or nv.toFixnum() < 0) rt.raise(.@"error", "make-array needs a non-negative length, not {s}", .{readable(nv)});
    const n: usize = @intCast(nv.toFixnum());
    if (kindOf(type_sym)) |k| return makePrim(k, n);
    if (names.isSymbol(type_sym) and names.nsOf(type_sym) == null) {
        const any_names = [_][]const u8{ "any", "bool", "keyword", "symbol", "string" };
        for (any_names) |name| if (std.mem.eql(u8, names.nameOf(type_sym), name)) return makeAny(n);
    }
    if (findDef(type_sym)) |def| {
        if (isValueDef(def)) return makeStructArray(def, n);
        return makeAny(n);
    }
    // Any other known type (a class, say) is stored boxed.
    if (@import("objects.zig").knownClassName(type_sym)) return makeAny(n);
    rt.raise(.@"error", "unknown array element type {s}", .{readable(type_sym)});
}

fn makeAny(n: usize) Value {
    const h = rt.alloc(.any_array, 2 + n);
    const s = h.valueSlots();
    s[0] = Value.fromFixnum(@intCast(n));
    s[1] = identity();
    for (0..n) |i| s[2 + i] = Value.nil;
    return Value.fromObject(h);
}

/// view: a zero-copy slice of a primitive array.
pub fn view(a: Value, start_v: Value, end_v: ?Value) Value {
    const base_ok = a.isObjectOf(.prim_array) or a.isObjectOf(.array_view);
    if (!base_ok) rt.raise(.unsupported_operation_error, "view needs an array of a primitive type, not {s}", .{readable(a)});
    const n = count(a);
    const end = end_v orelse Value.fromFixnum(@intCast(n));
    if (!start_v.isFixnum() or !end.isFixnum() or start_v.toFixnum() < 0 or start_v.toFixnum() > end.toFixnum() or end.toFixnum() > n)
        rt.raise(.index_error, "view {s} to {s} is out of bounds for an array of {d}", .{ readable(start_v), readable(end), n });
    const base = if (a.isObjectOf(.array_view)) slot(a, 0) else a;
    const offset = if (a.isObjectOf(.array_view)) slot(a, 1).toFixnum() else 0;
    const h = rt.alloc(.array_view, 4);
    const s = h.valueSlots();
    s[0] = base;
    s[1] = Value.fromFixnum(offset + start_v.toFixnum());
    s[2] = Value.fromFixnum(end.toFixnum() - start_v.toFixnum());
    s[3] = identity();
    return Value.fromObject(h);
}

pub fn asBytes(a: Value) Value {
    if (!a.isObjectOf(.prim_array) or primKind(a) == .char or primKind(a) == .fixnum)
        rt.raise(.unsupported_operation_error, "as-bytes needs an array of a numeric type, not {s}", .{readable(a)});
    const h = rt.alloc(.byte_view, 1);
    h.valueSlots()[0] = a;
    return Value.fromObject(h);
}

/// update!: (update! array i f args...) or (update! structs i :field f args...).
pub fn update(c: Value, iv: Value, args: []const Value) Value {
    var buf: [16]Value = undefined;
    if (c.isObjectOf(.struct_array)) {
        if (args.len < 2) rt.raise(.arity_error, "update! on an array of structs needs a field and a function", .{});
        const key = args[0];
        if (!names.isKeyword(key)) rt.raise(.unsupported_operation_error, "update! on an array of structs needs a field keyword, not {s}", .{readable(key)});
        const i = index(iv, c);
        const more = args[2..];
        if (more.len + 1 > buf.len) rt.raise(.unsupported_operation_error, "update! with that many arguments", .{});
        buf[0] = structArrayField(c, i, names.nameOf(key));
        @memcpy(buf[1 .. 1 + more.len], more);
        const v = func.call(args[1], @intCast(1 + more.len), &buf);
        setStructArrayField(c, i, names.nameOf(key), v);
        return v;
    }
    if (isArray(c)) {
        if (args.len < 1) rt.raise(.arity_error, "update! needs a function", .{});
        const more = args[1..];
        if (more.len + 1 > buf.len) rt.raise(.unsupported_operation_error, "update! with that many arguments", .{});
        buf[0] = aget(c, iv);
        @memcpy(buf[1 .. 1 + more.len], more);
        const v = func.call(args[0], @intCast(1 + more.len), &buf);
        return aset(c, iv, v);
    }
    rt.raise(.unsupported_operation_error, "update! needs an array, not {s}", .{readable(c)});
}

fn elementName(a: Value) []const u8 {
    return switch (a.toObject().type_id) {
        .prim_array => @tagName(primKind(a)),
        .array_view => @tagName(primKind(slot(a, 0))),
        .struct_array => defName(slot(a, 0)),
        else => "any",
    };
}

pub fn writeArray(a: Value, out: *std.ArrayList(u8), readably: bool) void {
    if (a.isObjectOf(.byte_view)) {
        var buf: [32]u8 = undefined;
        print.put(out, std.fmt.bufPrint(&buf, "#<bytes {d}>", .{count(a)}) catch "#<bytes>");
        return;
    }
    print.put(out, "#<array ");
    print.put(out, elementName(a));
    print.put(out, " [");
    for (0..count(a)) |i| {
        if (i > 0) print.put(out, " ");
        print.write(aget(a, Value.fromFixnum(@intCast(i))), out, readably);
    }
    print.put(out, "]>");
}

pub fn identityHash(a: Value) u32 {
    return @truncate(@as(u64, @bitCast(switch (a.toObject().type_id) {
        .prim_array => @as(i64, @intCast(a.toObject().payload()[2])),
        .any_array => slot(a, 1).toFixnum(),
        .struct_array, .array_view => slot(a, 3).toFixnum(),
        else => 0,
    })));
}

// ---------------------------------------------------------------------------------------
// defsoa: the element def name.element, make-name and a function per field.

pub fn defineSoa(name: Value, fields: Value) Value {
    var buf: [512]u8 = undefined;
    const element_name = std.fmt.bufPrint(&buf, "{s}.element", .{names.nameOf(name)}) catch
        rt.raise(.@"error", "the defsoa name is too long", .{});
    const def = defineStruct(names.symbol(names.nsOf(name), element_name), true, fields);
    return def;
}

fn soaMake(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    if (argc != 1) rt.raise(.arity_error, "wrong number of arguments ({d}) passed to make-{s}", .{ argc, defName(func.capturedOf(self, 0)) });
    if (!argv[0].isFixnum() or argv[0].toFixnum() < 0) rt.raise(.@"error", "make-array needs a non-negative length, not {s}", .{readable(argv[0])});
    return makeStructArray(func.capturedOf(self, 0), @intCast(argv[0].toFixnum()));
}

/// make-name of a defsoa collection.
pub fn soaMaker(def: Value) Value {
    return func.closure(soaMake, "make-soa", &.{def});
}

fn soaField(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const def = func.capturedOf(self, 0);
    const name = string.bytes(func.capturedOf(self, 1));
    if (argc != 2) rt.raise(.arity_error, "wrong number of arguments ({d}) passed to {s}", .{ argc, name });
    const c = argv[0];
    if (!(c.isObjectOf(.struct_array) and slot(c, 0) == def)) {
        // The defsoa's own name: ns/name.element without ns/ and .element.
        const full = defName(def);
        const start = if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| i + 1 else 0;
        const short = full[start .. full.len - ".element".len];
        rt.raise(.unsupported_operation_error, "{s} needs a {s} collection, not {s}", .{ name, short, readable(c) });
    }
    return structArrayField(c, index(argv[1], c), name);
}

/// The function (field coll i) of field `i` of a defsoa collection.
pub fn soaFieldFn(def: Value, i: usize) Value {
    return func.closure(soaField, "soa-field", &.{ def, coll.vectorNth(field(def, i), 0).? });
}

// ---------------------------------------------------------------------------------------
// The C interface: the C backend defines a struct's vars itself (D-055).

export fn sk_define_struct(name: Value, value_p: Value, fields: Value) Value {
    return defineStruct(name, value_p != Value.nil and value_p != Value.false, fields);
}

export fn sk_struct_constructor(def: Value) Value {
    return constructor(def);
}

export fn sk_struct_predicate(def: Value) Value {
    return predicate(def);
}

export fn sk_struct_accessor(def: Value, i: u32) Value {
    return accessor(def, i);
}

export fn sk_define_soa(name: Value, fields: Value) Value {
    return defineSoa(name, fields);
}

export fn sk_soa_maker(def: Value) Value {
    return soaMaker(def);
}

export fn sk_soa_field(def: Value, i: u32) Value {
    return soaFieldFn(def, i);
}

// Typed code (D-056): checks where values enter typed C code, and its errors.

export fn sk_to_f64(v: Value, location: [*:0]const u8) f64 {
    if (!v.isObjectOf(.f64)) rt.raise(.type_error, "{s} is not a f64 at {s}", .{ readable(v), std.mem.span(location) });
    return num.unboxF64(v);
}

export fn sk_to_f32(v: Value, location: [*:0]const u8) f32 {
    if (!v.isF32()) rt.raise(.type_error, "{s} is not a f32 at {s}", .{ readable(v), std.mem.span(location) });
    return v.toF32();
}

export fn sk_to_fixnum(v: Value, location: [*:0]const u8) i64 {
    if (!v.isFixnum()) rt.raise(.type_error, "{s} is not a fixnum at {s}", .{ readable(v), std.mem.span(location) });
    return v.toFixnum();
}

export fn sk_check_array(a: Value, kind: u32, location: [*:0]const u8) Value {
    if (!(a.isObjectOf(.prim_array) and @intFromEnum(primKind(a)) == kind))
        rt.raise(.type_error, "{s} is not an (array {s}) at {s}", .{ readable(a), @tagName(@as(Kind, @enumFromInt(@as(u8, @intCast(kind))))), std.mem.span(location) });
    return a;
}

export fn sk_integer_from_i64(n: i64) Value {
    return num.fromI128(n);
}

export fn sk_fixnum_range_error(n: i64, location: [*:0]const u8) noreturn {
    rt.raise(.type_error, "{d} is not a fixnum at {s}", .{ n, std.mem.span(location) });
}

export fn sk_array_index_error(i: i64, n: i64) noreturn {
    rt.raise(.index_error, "index {d} is out of bounds for an array of {d}", .{ i, n });
}

export fn sk_integer_overflow() noreturn {
    rt.raise(.arithmetic_error, "integer overflow in typed arithmetic", .{});
}

export fn sk_division_by_zero() noreturn {
    rt.raise(.arithmetic_error, "division by zero", .{});
}

/// The bytes of a u8 array or a view of one, or of a byte view (skein.io, M2.11); null
/// for anything else. Valid until the next allocation (the GC may move the array).
pub fn bytesOf(a: Value) ?[]u8 {
    if (!a.isObject()) return null;
    const ok = switch (a.toObject().type_id) {
        .prim_array => primKind(a) == .u8,
        .array_view => primKind(slot(a, 0)) == .u8,
        .byte_view => true,
        else => false,
    };
    if (!ok) return null;
    const p: [*]u8 = @ptrFromInt(arrayAddress(a).?);
    return p[0..count(a)];
}

/// The address of the first element of a primitive array, a view of one or a byte view,
/// for passing it to C (M1.10); null for anything else. The caller keeps the array
/// referenced from its stack, which pins it.
pub fn arrayAddress(a: Value) ?usize {
    if (!a.isObject()) return null;
    return switch (a.toObject().type_id) {
        .prim_array => @intFromPtr(primData(a)),
        .array_view => @intFromPtr(primData(slot(a, 0))) +
            @as(usize, @intCast(slot(a, 1).toFixnum())) * primKind(slot(a, 0)).size(),
        .byte_view => @intFromPtr(primData(slot(a, 0))),
        else => null,
    };
}
