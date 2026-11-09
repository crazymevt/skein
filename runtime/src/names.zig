//! Symbols, keywords, namespaces and vars (DESIGN §4.3, §6.1, D-046). Symbols and
//! keywords are interned: the same name always gives the same object, so they compare by
//! identity. All four kinds are permanent objects: never moved or freed.

const std = @import("std");
const platform = @import("platform");
const gc = @import("gc.zig");
const hash = @import("hash.zig");
const string = @import("string.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;

const table_alloc = std.heap.page_allocator;

var lock: platform.Mutex = .{};
var symbols: std.StringHashMapUnmanaged(Value) = .empty;
var keywords: std.StringHashMapUnmanaged(Value) = .empty;
var namespaces: std.StringHashMapUnmanaged(Value) = .empty;

fn permanentString(text: []const u8) Value {
    const words = 2 + (text.len + 7) / 8;
    const h = gc.allocPermanent(.string, words);
    h.type_id = .string;
    h.payload()[0] = text.len;
    var chars: usize = 0;
    for (text) |b| {
        if (b & 0xC0 != 0x80) chars += 1;
    }
    h.payload()[1] = chars;
    const dest: [*]u8 = @ptrCast(h.payload()[2..].ptr);
    @memcpy(dest[0..text.len], text);
    return Value.fromObject(h);
}

/// "ns/name", or "name" when there is no namespace; owned by the table allocator.
fn qualified(ns: ?[]const u8, name: []const u8) []u8 {
    const text = if (ns) |n|
        std.fmt.allocPrint(table_alloc, "{s}/{s}", .{ n, name })
    else
        table_alloc.dupe(u8, name);
    return text catch @panic("out of memory");
}

fn intern(table: *std.StringHashMapUnmanaged(Value), t: object.TypeId, ns: ?[]const u8, name: []const u8, salt: u32) Value {
    lock.lock();
    defer lock.unlock();
    // Look up with the key on the stack; allocate it only for a new name.
    var buf: [256]u8 = undefined;
    const probe = if (ns) |n|
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ n, name }) catch null
    else if (name.len <= buf.len) name else null;
    if (probe) |p| {
        if (table.get(p)) |v| return v;
    }
    const key = qualified(ns, name);
    if (table.get(key)) |v| {
        table_alloc.free(key);
        return v;
    }
    const h = gc.allocPermanent(t, 3);
    const slots = h.valueSlots();
    slots[0] = Value.fromFixnum(salt +% hash.hashString(key));
    slots[1] = if (ns) |n| permanentString(n) else Value.nil;
    slots[2] = permanentString(name);
    const v = Value.fromObject(h);
    table.put(table_alloc, key, v) catch @panic("out of memory");
    return v;
}

pub fn symbol(ns: ?[]const u8, name: []const u8) Value {
    return intern(&symbols, .symbol, ns, name, 0);
}

pub fn keyword(ns: ?[]const u8, name: []const u8) Value {
    return intern(&keywords, .keyword, ns, name, hash.keyword_salt);
}

pub fn isSymbol(v: Value) bool {
    return v.isObjectOf(.symbol);
}

pub fn isKeyword(v: Value) bool {
    return v.isObjectOf(.keyword);
}

/// The stored hash of a symbol or keyword.
pub fn nameHash(v: Value) u32 {
    return @intCast(v.toObject().valueSlots()[0].toFixnum());
}

/// The namespace part of a symbol or keyword, or null.
pub fn nsOf(v: Value) ?[]const u8 {
    const n = v.toObject().valueSlots()[1];
    return if (n == Value.nil) null else string.bytes(n);
}

pub fn nameOf(v: Value) []const u8 {
    return string.bytes(v.toObject().valueSlots()[2]);
}

/// The namespace object called `name`, made if needed.
pub fn namespace(name: []const u8) Value {
    lock.lock();
    defer lock.unlock();
    if (namespaces.get(name)) |v| return v;
    const h = gc.allocPermanent(.namespace, 1);
    h.valueSlots()[0] = permanentString(name);
    const v = Value.fromObject(h);
    const key = table_alloc.dupe(u8, name) catch @panic("out of memory");
    namespaces.put(table_alloc, key, v) catch @panic("out of memory");
    return v;
}

/// A new var `ns/name`, unbound. (Vars are made once per name by compiled programs.)
pub fn makeVar(ns: []const u8, name: []const u8) Value {
    const n = namespace(ns);
    const h = gc.allocPermanent(.@"var", 3);
    const slots = h.valueSlots();
    slots[0] = Value.unbound;
    slots[1] = n;
    slots[2] = permanentString(name);
    return Value.fromObject(h);
}

pub fn varValue(v: Value) Value {
    return v.toObject().valueSlots()[0];
}

pub fn setVar(v: Value, x: Value) void {
    const h = v.toObject();
    gc.store(h, &h.valueSlots()[0], x);
}

pub fn varNamespaceName(v: Value) []const u8 {
    return string.bytes(v.toObject().valueSlots()[1].toObject().valueSlots()[0]);
}

pub fn varName(v: Value) []const u8 {
    return string.bytes(v.toObject().valueSlots()[2]);
}

test "symbols and keywords are interned" {
    const a = symbol(null, "foo");
    try std.testing.expectEqual(a, symbol(null, "foo"));
    try std.testing.expect(a != symbol("ns", "foo"));
    try std.testing.expect(a != keyword(null, "foo"));
    try std.testing.expectEqualStrings("foo", nameOf(a));
    try std.testing.expectEqualStrings("ns", nsOf(keyword("ns", "k")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), nsOf(a));
    gc.collect(.major);
    try std.testing.expectEqualStrings("foo", nameOf(symbol(null, "foo")));
}
