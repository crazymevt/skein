//! Persistent collections (DESIGN §6.2, D-046): lists, vectors (Clojure's
//! PersistentVector), maps (array maps up to 8 entries, then a HAMT like Clojure's
//! PersistentHashMap), sets, their transients, and atoms. A port of Phase 0's
//! host/src/runtime/{vector,map,seq,coll-types,atoms}.lisp, keeping the same structure so
//! that maps and sets iterate in the same order.
//!
//! Every store into an existing object goes through the write barrier (`set`), because
//! an allocation in between may have promoted it to the old generation.

const std = @import("std");
const object = @import("object.zig");
const gc = @import("gc.zig");
const rt = @import("rt.zig");
const equal = @import("equal.zig");
const sorted = @import("sorted.zig");
const Value = @import("value.zig").Value;
const TypeId = object.TypeId;

pub const branch = 32;
pub const array_map_limit = 8;
/// The key that marks a HAMT pair holding a child node.
const subnode = Value.unbound;

// ---------------------------------------------------------------------------------------
// Object helpers

pub fn make(t: TypeId, vals: []const Value) Value {
    const h = rt.alloc(t, vals.len);
    @memcpy(h.valueSlots(), vals);
    return Value.fromObject(h);
}

pub fn slots(v: Value) []Value {
    return v.toObject().valueSlots();
}

pub fn get(v: Value, i: usize) Value {
    return v.toObject().valueSlots()[i];
}

pub fn set(v: Value, i: usize, x: Value) void {
    const h = v.toObject();
    gc.store(h, &h.valueSlots()[i], x);
}

pub fn fx(n: usize) Value {
    return Value.fromFixnum(@intCast(n));
}

pub fn ux(v: Value) usize {
    return @intCast(v.toFixnum());
}

/// A tuple of `n` values, all `fill`.
pub fn tupleN(n: usize, fill: Value) Value {
    const h = rt.alloc(.tuple, n);
    for (h.valueSlots()[0..n]) |*s| s.* = fill;
    return Value.fromObject(h);
}

pub fn tupleOf(vals: []const Value) Value {
    return make(.tuple, vals);
}

/// The values of a tuple. A tuple of 0 values still has its one (unused) payload word,
/// so this uses the length the caller recorded where it matters; tuples made here keep
/// `len` exact for n >= 1, and an empty tuple is the permanent `empty_tuple`.
pub fn tupleLen(t: Value) usize {
    if (t == empty_tuple) return 0;
    return t.toObject().len;
}

fn copyTuple(t: Value, n: usize) Value {
    if (n == 0) return empty_tuple;
    const copy = tupleN(n, Value.nil);
    const m = @min(n, tupleLen(t));
    @memcpy(slots(copy)[0..m], slots(t)[0..m]);
    return copy;
}

pub fn indexError(i: Value, count: usize) noreturn {
    const print = @import("print.zig");
    var buf: std.ArrayList(u8) = .empty;
    print.write(i, &buf, true);
    rt.raise(.index_error, "index {s} is out of bounds for a vector of {d}", .{ buf.items, count });
}

pub fn unsupported(comptime fmt: []const u8, args: anytype) noreturn {
    rt.raise(.unsupported_operation_error, fmt, args);
}

// ---------------------------------------------------------------------------------------
// Permanent constants, made on first use

pub var empty_tuple: Value = Value.nil;
pub var empty_list: Value = Value.nil;
pub var empty_vector: Value = Value.nil;
pub var empty_node: Value = Value.nil;
pub var empty_map: Value = Value.nil;
pub var empty_set: Value = Value.nil;
var constants_ready = false;
var constants_lock: @import("platform").Mutex = .{};

fn permanent(t: TypeId, vals: []const Value) Value {
    const h = gc.allocPermanent(t, vals.len);
    @memcpy(h.valueSlots()[0..vals.len], vals);
    return Value.fromObject(h);
}

pub fn ensureConstants() void {
    if (@atomicLoad(bool, &constants_ready, .acquire)) return;
    constants_lock.lock();
    defer constants_lock.unlock();
    if (constants_ready) return;
    empty_tuple = permanent(.tuple, &.{Value.nil});
    var nils: [33]Value = @splat(Value.nil);
    empty_node = permanent(.tuple, &nils);
    empty_list = permanent(.empty_list, &.{Value.nil});
    empty_vector = permanent(.vector, &.{ fx(0), fx(5), empty_node, empty_tuple, Value.nil });
    empty_map = permanent(.array_map, &.{ empty_tuple, Value.nil });
    empty_set = permanent(.hash_set, &.{ empty_map, Value.nil });
    @atomicStore(bool, &constants_ready, true, .release);
}

// ---------------------------------------------------------------------------------------
// Edit tokens (transients belong to the thread that made them)

fn makeEdit() Value {
    return make(.edit_token, &.{fx(@import("fiber.zig").ownerId())});
}

fn checkEdit(edit: Value, comptime what: []const u8) void {
    if (edit == Value.nil) rt.raise(.transient_error, what ++ " used after persistent!", .{});
    if (ux(get(edit, 0)) != @import("fiber.zig").ownerId())
        rt.raise(.transient_error, what ++ " used by a thread that does not own it", .{});
}

// ---------------------------------------------------------------------------------------
// Lists

pub fn isList(v: Value) bool {
    return v.isObjectOf(.list) or v.isObjectOf(.empty_list);
}

pub fn cons(x: Value, coll: Value) Value {
    ensureConstants();
    const rest = if (coll == Value.nil) empty_list else coll;
    const n: usize = if (rest.isObjectOf(.list)) ux(get(rest, 2)) + 1 else 1;
    return make(.list, &.{ x, rest, fx(n), Value.nil });
}

/// A list of `items`, in order.
pub fn listOf(items: []const Value) Value {
    ensureConstants();
    var result = empty_list;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = cons(items[i], result);
    }
    return result;
}

// ---------------------------------------------------------------------------------------
// Vectors

pub fn isVector(v: Value) bool {
    return v.isObjectOf(.vector);
}

fn tailoff(count: usize) usize {
    return if (count < branch) 0 else ((count - 1) >> 5) << 5;
}

fn newNode(edit: Value) Value {
    const n = tupleN(33, Value.nil);
    slots(n)[32] = edit;
    return n;
}

fn editableNode(node: Value, edit: Value) Value {
    if (edit != Value.nil and get(node, 32) == edit) return node;
    const copy = copyTuple(node, 33);
    set(copy, 32, edit);
    return copy;
}

fn leafArray(count: usize, shift: usize, root: Value, tail: Value, i: usize) Value {
    if (i >= tailoff(count)) return tail;
    var node = root;
    var level = shift;
    while (level > 0) : (level -= 5) node = get(node, (i >> @intCast(level)) & 31);
    return node;
}

fn newPath(edit: Value, level: usize, node: Value) Value {
    if (level == 0) return node;
    const ret = newNode(edit);
    set(ret, 0, newPath(edit, level - 5, node));
    return ret;
}

fn pushTail(edit: Value, count: usize, level: usize, parent: Value, tail_node: Value) Value {
    const ret = editableNode(parent, edit);
    const subidx = ((count - 1) >> @intCast(level)) & 31;
    const child_value = if (level == 5) tail_node else blk: {
        const child = get(parent, subidx);
        break :blk if (child != Value.nil)
            pushTail(edit, count, level - 5, child, tail_node)
        else
            newPath(edit, level - 5, tail_node);
    };
    set(ret, subidx, child_value);
    return ret;
}

fn doAssoc(edit: Value, level: usize, node: Value, i: usize, val: Value) Value {
    const ret = editableNode(node, edit);
    if (level == 0) {
        set(ret, i & 31, val);
    } else {
        const subidx = (i >> @intCast(level)) & 31;
        set(ret, subidx, doAssoc(edit, level - 5, get(node, subidx), i, val));
    }
    return ret;
}

fn popTail(edit: Value, count: usize, level: usize, node: Value) Value {
    const subidx = ((count - 2) >> @intCast(level)) & 31;
    if (level > 5) {
        const child = popTail(edit, count, level - 5, get(node, subidx));
        if (child == Value.nil and subidx == 0) return Value.nil;
        const ret = editableNode(node, edit);
        set(ret, subidx, child);
        return ret;
    }
    if (subidx == 0) return Value.nil;
    const ret = editableNode(node, edit);
    set(ret, subidx, Value.nil);
    return ret;
}

fn makeVector(count: usize, shift: usize, root: Value, tail: Value) Value {
    return make(.vector, &.{ fx(count), fx(shift), root, tail, Value.nil });
}

pub fn vectorCount(v: Value) usize {
    return ux(get(v, 0));
}

/// Element `i`, or null if out of range.
pub fn vectorNth(v: Value, i: usize) ?Value {
    const count = vectorCount(v);
    if (i >= count) return null;
    return get(leafArray(count, ux(get(v, 1)), get(v, 2), get(v, 3), i), i & 31);
}

pub fn vectorConj(v: Value, x: Value) Value {
    const count = vectorCount(v);
    const shift = ux(get(v, 1));
    const root = get(v, 2);
    const tail = get(v, 3);
    if (count - tailoff(count) < branch) {
        const n = tupleLen(tail);
        const new_tail = copyTuple(tail, n + 1);
        set(new_tail, n, x);
        return makeVector(count + 1, shift, root, new_tail);
    }
    const tail_node = newNode(Value.nil);
    @memcpy(slots(tail_node)[0..32], slots(tail)[0..32]);
    const one = tupleOf(&.{x});
    if ((count >> 5) > (@as(usize, 1) << @intCast(shift))) {
        const new_root = newNode(Value.nil);
        set(new_root, 0, root);
        set(new_root, 1, newPath(Value.nil, shift, tail_node));
        return makeVector(count + 1, shift + 5, new_root, one);
    }
    return makeVector(count + 1, shift, pushTail(Value.nil, count, shift, root, tail_node), one);
}

pub fn vectorAssoc(v: Value, i: usize, x: Value) Value {
    const count = vectorCount(v);
    if (i > count) indexError(fx(i), count);
    if (i == count) return vectorConj(v, x);
    const shift = ux(get(v, 1));
    if (i >= tailoff(count)) {
        const tail = get(v, 3);
        const new_tail = copyTuple(tail, tupleLen(tail));
        set(new_tail, i & 31, x);
        return makeVector(count, shift, get(v, 2), new_tail);
    }
    return makeVector(count, shift, doAssoc(Value.nil, shift, get(v, 2), i, x), get(v, 3));
}

pub fn vectorPop(v: Value) Value {
    ensureConstants();
    const count = vectorCount(v);
    const shift = ux(get(v, 1));
    const root = get(v, 2);
    if (count == 0) unsupported("cannot pop an empty vector", .{});
    if (count == 1) return empty_vector;
    if (count - tailoff(count) > 1) {
        const tail = get(v, 3);
        return makeVector(count - 1, shift, root, copyTuple(tail, tupleLen(tail) - 1));
    }
    const new_tail = copyTuple(leafArray(count, shift, root, get(v, 3), count - 2), 32);
    var new_root = popTail(Value.nil, count, shift, root);
    if (new_root == Value.nil) new_root = empty_node;
    var new_shift = shift;
    if (shift > 5 and get(new_root, 1) == Value.nil) {
        new_root = get(new_root, 0);
        new_shift -= 5;
    }
    return makeVector(count - 1, new_shift, new_root, new_tail);
}

/// A vector of `items`.
pub fn vectorOf(items: []const Value) Value {
    ensureConstants();
    var t = vectorTransient(empty_vector);
    for (items) |x| t = tvectorConj(t, x);
    return tvectorPersistent(t);
}

pub fn vectorTransient(v: Value) Value {
    const edit = makeEdit();
    const tail = tupleN(32, Value.nil);
    const src = get(v, 3);
    @memcpy(slots(tail)[0..tupleLen(src)], slots(src)[0..tupleLen(src)]);
    return make(.transient_vector, &.{ get(v, 0), get(v, 1), editableNode(get(v, 2), edit), tail, edit });
}

pub fn tvectorConj(t: Value, x: Value) Value {
    const edit = get(t, 4);
    checkEdit(edit, "transient vector");
    const count = ux(get(t, 0));
    if (count - tailoff(count) < branch) {
        set(get(t, 3), count & 31, x);
    } else {
        const tail_node = newNode(edit);
        @memcpy(slots(tail_node)[0..32], slots(get(t, 3))[0..32]);
        const new_tail = tupleN(32, Value.nil);
        set(new_tail, 0, x);
        set(t, 3, new_tail);
        const shift = ux(get(t, 1));
        if ((count >> 5) > (@as(usize, 1) << @intCast(shift))) {
            const new_root = newNode(edit);
            set(new_root, 0, get(t, 2));
            set(new_root, 1, newPath(edit, shift, tail_node));
            set(t, 2, new_root);
            set(t, 1, fx(shift + 5));
        } else {
            set(t, 2, pushTail(edit, count, shift, get(t, 2), tail_node));
        }
    }
    set(t, 0, fx(count + 1));
    return t;
}

pub fn tvectorAssoc(t: Value, i: usize, x: Value) Value {
    const edit = get(t, 4);
    checkEdit(edit, "transient vector");
    const count = ux(get(t, 0));
    if (i > count) indexError(fx(i), count);
    if (i == count) return tvectorConj(t, x);
    if (i >= tailoff(count)) {
        set(get(t, 3), i & 31, x);
    } else {
        set(t, 2, doAssoc(edit, ux(get(t, 1)), get(t, 2), i, x));
    }
    return t;
}

pub fn tvectorPop(t: Value) Value {
    ensureConstants();
    const edit = get(t, 4);
    checkEdit(edit, "transient vector");
    const count = ux(get(t, 0));
    const shift = ux(get(t, 1));
    if (count == 0) unsupported("cannot pop an empty vector", .{});
    if (count == 1 or count - tailoff(count) > 1) {
        set(get(t, 3), (count - 1) & 31, Value.nil);
    } else {
        const leaf = editableNode(leafArray(count, shift, get(t, 2), get(t, 3), count - 2), edit);
        var new_root = popTail(edit, count, shift, get(t, 2));
        if (new_root == Value.nil) new_root = newNode(edit);
        var new_shift = shift;
        if (shift > 5 and get(new_root, 1) == Value.nil) {
            new_root = editableNode(get(new_root, 0), edit);
            new_shift -= 5;
        }
        set(t, 2, new_root);
        set(t, 1, fx(new_shift));
        set(t, 3, copyTuple(leaf, 32));
    }
    set(t, 0, fx(count - 1));
    return t;
}

pub fn tvectorNth(t: Value, i: usize) ?Value {
    checkEdit(get(t, 4), "transient vector");
    const count = ux(get(t, 0));
    if (i >= count) return null;
    return get(leafArray(count, ux(get(t, 1)), get(t, 2), get(t, 3), i), i & 31);
}

pub fn tvectorPersistent(t: Value) Value {
    ensureConstants();
    checkEdit(get(t, 4), "transient vector");
    set(t, 4, Value.nil);
    const count = ux(get(t, 0));
    if (count == 0) return empty_vector;
    return makeVector(count, ux(get(t, 1)), get(t, 2), copyTuple(get(t, 3), count - tailoff(count)));
}

// ---------------------------------------------------------------------------------------
// HAMT nodes

fn mask(hash: u32, shift: usize) u5 {
    return @truncate(hash >> @intCast(shift));
}

fn bitpos(hash: u32, shift: usize) u32 {
    return @as(u32, 1) << mask(hash, shift);
}

fn bnodeIndex(bitmap: u32, bit: u32) usize {
    return @popCount(bitmap & (bit - 1));
}

fn pairs(node: Value) Value {
    return get(node, 2);
}

fn cloneAndSet(array: Value, i: usize, x: Value) Value {
    const copy = copyTuple(array, tupleLen(array));
    set(copy, i, x);
    return copy;
}

fn cloneAndSet2(array: Value, i: usize, x: Value, j: usize, y: Value) Value {
    const copy = cloneAndSet(array, i, x);
    set(copy, j, y);
    return copy;
}

/// `array` without the pair at pair index `i`.
fn removePair(array: Value, i: usize) Value {
    const n = tupleLen(array);
    if (n == 2) return empty_tuple;
    const copy = tupleN(n - 2, Value.nil);
    const src = slots(array);
    @memcpy(slots(copy)[0 .. 2 * i], src[0 .. 2 * i]);
    @memcpy(slots(copy)[2 * i ..], src[2 * i + 2 .. n]);
    return copy;
}

fn insertPair(array: Value, i: usize, key: Value, val: Value) Value {
    const n = tupleLen(array);
    const copy = tupleN(n + 2, Value.nil);
    const src = slots(array);
    @memcpy(slots(copy)[0 .. 2 * i], src[0 .. 2 * i]);
    set(copy, 2 * i, key);
    set(copy, 2 * i + 1, val);
    @memcpy(slots(copy)[2 * i + 2 ..], src[2 * i .. n]);
    return copy;
}

fn appendPair(array: Value, key: Value, val: Value) Value {
    const n = tupleLen(array);
    const copy = copyTuple(array, n + 2);
    set(copy, n, key);
    set(copy, n + 1, val);
    return copy;
}

fn owned(node_edit: Value, edit: Value) bool {
    return edit != Value.nil and node_edit == edit;
}

fn makeBnode(edit: Value, bitmap: u32, array: Value) Value {
    return make(.bitmap_node, &.{ edit, fx(bitmap), array });
}

fn bnodeSet(node: Value, edit: Value, array: Value, bitmap: u32) Value {
    if (owned(get(node, 0), edit)) {
        set(node, 2, array);
        set(node, 1, fx(bitmap));
        return node;
    }
    return makeBnode(edit, bitmap, array);
}

fn cnodeSet(node: Value, edit: Value, array: Value) Value {
    if (owned(get(node, 0), edit)) {
        set(node, 2, array);
        return node;
    }
    return make(.collision_node, &.{ edit, get(node, 1), array });
}

fn createNode(edit: Value, shift: usize, key1: Value, val1: Value, hash2: u32, key2: Value, val2: Value) Value {
    const hash1 = equal.hashOf(key1);
    if (hash1 == hash2)
        return make(.collision_node, &.{ edit, fx(hash1), tupleOf(&.{ key1, val1, key2, val2 }) });
    var added = false;
    const n = nodeAssoc(makeBnode(edit, 0, empty_tuple), edit, shift, hash1, key1, val1, &added);
    return nodeAssoc(n, edit, shift, hash2, key2, val2, &added);
}

fn nodeAssoc(node: Value, edit: Value, shift: usize, hash: u32, key: Value, val: Value, added: *bool) Value {
    if (node.isObjectOf(.bitmap_node)) {
        const bit = bitpos(hash, shift);
        const bitmap: u32 = @intCast(ux(get(node, 1)));
        const idx = bnodeIndex(bitmap, bit);
        const array = pairs(node);
        if (bitmap & bit == 0) {
            added.* = true;
            return bnodeSet(node, edit, insertPair(array, idx, key, val), bitmap | bit);
        }
        const k = get(array, 2 * idx);
        const v = get(array, 2 * idx + 1);
        if (k == subnode) {
            const n = nodeAssoc(v, edit, shift + 5, hash, key, val, added);
            if (n == v) return node;
            return bnodeSet(node, edit, cloneAndSet(array, 2 * idx + 1, n), bitmap);
        }
        if (equal.equiv(key, k)) {
            if (val == v) return node;
            return bnodeSet(node, edit, cloneAndSet(array, 2 * idx + 1, val), bitmap);
        }
        added.* = true;
        const child = createNode(edit, shift + 5, k, v, hash, key, val);
        return bnodeSet(node, edit, cloneAndSet2(array, 2 * idx, subnode, 2 * idx + 1, child), bitmap);
    }
    // A collision node.
    const node_hash: u32 = @intCast(ux(get(node, 1)));
    if (hash == node_hash) {
        const array = pairs(node);
        var i: usize = 0;
        while (i < tupleLen(array)) : (i += 2) {
            if (equal.equiv(key, get(array, i))) {
                if (get(array, i + 1) == val) return node;
                return cnodeSet(node, edit, cloneAndSet(array, i + 1, val));
            }
        }
        added.* = true;
        return cnodeSet(node, edit, appendPair(array, key, val));
    }
    // A different hash: nest this collision node under a bitmap node.
    const parent = makeBnode(edit, bitpos(node_hash, shift), tupleOf(&.{ subnode, node }));
    return nodeAssoc(parent, edit, shift, hash, key, val, added);
}

/// `node` without `key`, or nil if that would leave it empty.
fn nodeWithout(node: Value, edit: Value, shift: usize, hash: u32, key: Value) Value {
    if (node.isObjectOf(.bitmap_node)) {
        const bit = bitpos(hash, shift);
        const bitmap: u32 = @intCast(ux(get(node, 1)));
        if (bitmap & bit == 0) return node;
        const idx = bnodeIndex(bitmap, bit);
        const array = pairs(node);
        const k = get(array, 2 * idx);
        const v = get(array, 2 * idx + 1);
        if (k == subnode) {
            const n = nodeWithout(v, edit, shift + 5, hash, key);
            if (n == v) return node;
            if (n != Value.nil) return bnodeSet(node, edit, cloneAndSet(array, 2 * idx + 1, n), bitmap);
            if (bitmap == bit) return Value.nil;
            return bnodeSet(node, edit, removePair(array, idx), bitmap ^ bit);
        }
        if (equal.equiv(key, k)) {
            if (bitmap == bit) return Value.nil;
            return bnodeSet(node, edit, removePair(array, idx), bitmap ^ bit);
        }
        return node;
    }
    const array = pairs(node);
    var i: usize = 0;
    while (i < tupleLen(array)) : (i += 2) {
        if (equal.equiv(key, get(array, i))) {
            if (tupleLen(array) == 2) return Value.nil;
            return cnodeSet(node, edit, removePair(array, i / 2));
        }
    }
    return node;
}

fn nodeFind(root: Value, hash: u32, key: Value) ?Value {
    var node = root;
    var shift: usize = 0;
    while (true) {
        const array = pairs(node);
        if (node.isObjectOf(.bitmap_node)) {
            const bit = bitpos(hash, shift);
            const bitmap: u32 = @intCast(ux(get(node, 1)));
            if (bitmap & bit == 0) return null;
            const idx = bnodeIndex(bitmap, bit);
            const k = get(array, 2 * idx);
            const v = get(array, 2 * idx + 1);
            if (k == subnode) {
                node = v;
                shift += 5;
            } else return if (equal.equiv(key, k)) v else null;
        } else {
            var i: usize = 0;
            while (i < tupleLen(array)) : (i += 2) {
                if (equal.equiv(key, get(array, i))) return get(array, i + 1);
            }
            return null;
        }
    }
}

/// Call `f(ctx, key, value)` for each entry under `node`, in order; stop if it returns false.
fn nodeEach(node: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value, Value) bool) bool {
    const array = pairs(node);
    var i: usize = 0;
    while (i < tupleLen(array)) : (i += 2) {
        const k = get(array, i);
        const v = get(array, i + 1);
        if (k == subnode) {
            if (!nodeEach(v, ctx, f)) return false;
        } else if (!f(ctx, k, v)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------
// Persistent maps

pub fn isMap(v: Value) bool {
    return v.isObjectOf(.array_map) or v.isObjectOf(.hash_map) or v.isObjectOf(.sorted_map);
}

pub fn mapCount(m: Value) usize {
    if (m.isObjectOf(.sorted_map)) return sorted.count(m);
    return if (m.isObjectOf(.array_map)) tupleLen(get(m, 0)) / 2 else ux(get(m, 0));
}

fn arrayMapIndex(array: Value, n: usize, key: Value) ?usize {
    var i: usize = 0;
    while (i < n) : (i += 2) if (equal.equiv(key, get(array, i))) return i;
    return null;
}

pub fn mapGet(m: Value, key: Value) ?Value {
    if (m.isObjectOf(.sorted_map)) return sorted.lookup(m, key);
    if (m.isObjectOf(.array_map)) {
        const array = get(m, 0);
        const i = arrayMapIndex(array, tupleLen(array), key) orelse return null;
        return get(array, i + 1);
    }
    const root = get(m, 1);
    if (root == Value.nil) return null;
    return nodeFind(root, equal.hashOf(key), key);
}

fn makeHashMap(count: usize, root: Value) Value {
    return make(.hash_map, &.{ fx(count), root, Value.nil });
}

pub fn mapAssoc(m: Value, key: Value, val: Value) Value {
    if (m.isObjectOf(.sorted_map)) return sorted.assoc(m, key, val);
    if (m.isObjectOf(.array_map)) {
        const array = get(m, 0);
        const n = tupleLen(array);
        if (arrayMapIndex(array, n, key)) |i| {
            if (get(array, i + 1) == val) return m;
            return make(.array_map, &.{ cloneAndSet(array, i + 1, val), Value.nil });
        }
        if (n < 2 * array_map_limit) return make(.array_map, &.{ appendPair(array, key, val), Value.nil });
        var t = mapTransient(m);
        t = tmapAssoc(t, key, val);
        return tmapPersistent(t);
    }
    var added = false;
    const old_root = get(m, 1);
    const start = if (old_root == Value.nil) makeBnode(Value.nil, 0, empty_tuple) else old_root;
    const root = nodeAssoc(start, Value.nil, 0, equal.hashOf(key), key, val, &added);
    if (root == old_root) return m;
    return makeHashMap(mapCount(m) + @intFromBool(added), root);
}

pub fn mapDissoc(m: Value, key: Value) Value {
    if (m.isObjectOf(.sorted_map)) return sorted.dissoc(m, key);
    ensureConstants();
    if (m.isObjectOf(.array_map)) {
        const array = get(m, 0);
        const i = arrayMapIndex(array, tupleLen(array), key) orelse return m;
        return make(.array_map, &.{ removePair(array, i / 2), Value.nil });
    }
    const root = get(m, 1);
    if (root == Value.nil) return m;
    const new = nodeWithout(root, Value.nil, 0, equal.hashOf(key), key);
    if (new == root) return m;
    if (new == Value.nil) return empty_map;
    return makeHashMap(mapCount(m) - 1, new);
}

/// Call `f(ctx, key, value)` for each entry, in order; stop if it returns false.
pub fn mapEach(m: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value, Value) bool) void {
    if (m.isObjectOf(.sorted_map)) return sorted.each(m, ctx, f);
    if (m.isObjectOf(.array_map)) {
        const array = get(m, 0);
        var i: usize = 0;
        while (i < tupleLen(array)) : (i += 2) if (!f(ctx, get(array, i), get(array, i + 1))) return;
        return;
    }
    const root = get(m, 1);
    if (root != Value.nil) _ = nodeEach(root, ctx, f);
}

// Transient maps

pub fn mapTransient(m: Value) Value {
    if (m.isObjectOf(.sorted_map)) rt.raise(.unsupported_operation_error, "a sorted map has no transient", .{});
    const edit = makeEdit();
    if (m.isObjectOf(.array_map)) {
        const array = tupleN(2 * array_map_limit, Value.nil);
        const src = get(m, 0);
        @memcpy(slots(array)[0..tupleLen(src)], slots(src)[0..tupleLen(src)]);
        return make(.transient_map, &.{ fx(tupleLen(src) / 2), Value.nil, edit, array });
    }
    return make(.transient_map, &.{ get(m, 0), get(m, 1), edit, Value.nil });
}

fn tmapArrayIndex(t: Value, key: Value) ?usize {
    return arrayMapIndex(get(t, 3), 2 * ux(get(t, 0)), key);
}

pub fn tmapAssoc(t: Value, key: Value, val: Value) Value {
    const edit = get(t, 2);
    checkEdit(edit, "transient map");
    const array = get(t, 3);
    if (array != Value.nil) {
        if (tmapArrayIndex(t, key)) |i| {
            set(array, i + 1, val);
            return t;
        }
        const count = ux(get(t, 0));
        if (count < array_map_limit) {
            set(array, 2 * count, key);
            set(array, 2 * count + 1, val);
            set(t, 0, fx(count + 1));
            return t;
        }
        // Full: move the entries into a HAMT, then add this one there.
        set(t, 3, Value.nil);
        set(t, 0, fx(0));
        var i: usize = 0;
        while (i < 2 * count) : (i += 2) _ = tmapAssoc(t, get(array, i), get(array, i + 1));
    }
    var added = false;
    const old_root = get(t, 1);
    const start = if (old_root == Value.nil) makeBnode(edit, 0, empty_tuple) else old_root;
    set(t, 1, nodeAssoc(start, edit, 0, equal.hashOf(key), key, val, &added));
    if (added) set(t, 0, fx(ux(get(t, 0)) + 1));
    return t;
}

pub fn tmapDissoc(t: Value, key: Value) Value {
    const edit = get(t, 2);
    checkEdit(edit, "transient map");
    const array = get(t, 3);
    if (array != Value.nil) {
        if (tmapArrayIndex(t, key)) |i| {
            const end = 2 * ux(get(t, 0));
            var k = i;
            while (k + 2 < end) : (k += 1) set(array, k, get(array, k + 2));
            set(array, end - 2, Value.nil);
            set(array, end - 1, Value.nil);
            set(t, 0, fx(ux(get(t, 0)) - 1));
        }
        return t;
    }
    const root = get(t, 1);
    const hash = equal.hashOf(key);
    if (root != Value.nil and nodeFind(root, hash, key) != null) {
        set(t, 1, nodeWithout(root, edit, 0, hash, key));
        set(t, 0, fx(ux(get(t, 0)) - 1));
    }
    return t;
}

pub fn tmapGet(t: Value, key: Value) ?Value {
    checkEdit(get(t, 2), "transient map");
    if (get(t, 3) != Value.nil) {
        const i = tmapArrayIndex(t, key) orelse return null;
        return get(get(t, 3), i + 1);
    }
    const root = get(t, 1);
    if (root == Value.nil) return null;
    return nodeFind(root, equal.hashOf(key), key);
}

pub fn tmapPersistent(t: Value) Value {
    ensureConstants();
    checkEdit(get(t, 2), "transient map");
    set(t, 2, Value.nil);
    const count = ux(get(t, 0));
    const root = get(t, 1);
    if (count == 0) return empty_map;
    if (get(t, 3) != Value.nil) return make(.array_map, &.{ copyTuple(get(t, 3), 2 * count), Value.nil });
    if (count <= array_map_limit) {
        // Back to an array map, in the HAMT's order.
        const array = tupleN(2 * count, Value.nil);
        var fill: Fill = .{ .array = array };
        _ = nodeEach(root, &fill, Fill.add);
        return make(.array_map, &.{ array, Value.nil });
    }
    return makeHashMap(count, root);
}

const Fill = struct {
    array: Value,
    i: usize = 0,

    fn add(c: *Fill, k: Value, v: Value) bool {
        set(c.array, c.i, k);
        set(c.array, c.i + 1, v);
        c.i += 2;
        return true;
    }
};

/// A map of the key/value pairs in `kvs`; later keys win.
pub fn mapOf(kvs: []const Value) Value {
    ensureConstants();
    var t = mapTransient(empty_map);
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) t = tmapAssoc(t, kvs[i], kvs[i + 1]);
    return tmapPersistent(t);
}

// ---------------------------------------------------------------------------------------
// Sets: maps from each element to itself

pub fn isSet(v: Value) bool {
    return v.isObjectOf(.hash_set) or v.isObjectOf(.sorted_set);
}

pub fn setOf(items: []const Value) Value {
    ensureConstants();
    var t = mapTransient(empty_map);
    for (items) |x| t = tmapAssoc(t, x, x);
    return make(.hash_set, &.{ tmapPersistent(t), Value.nil });
}

pub fn setContains(s: Value, x: Value) bool {
    return mapGet(get(s, 0), x) != null;
}

pub fn setConj(s: Value, x: Value) Value {
    if (s.isObjectOf(.sorted_set)) return sorted.setConj(s, x);
    if (setContains(s, x)) return s;
    return make(.hash_set, &.{ mapAssoc(get(s, 0), x, x), Value.nil });
}

pub fn setDisj(s: Value, x: Value) Value {
    if (s.isObjectOf(.sorted_set)) return sorted.setDisj(s, x);
    const m = get(s, 0);
    const new = mapDissoc(m, x);
    if (new == m) return s;
    return make(.hash_set, &.{ new, Value.nil });
}

pub fn setCount(s: Value) usize {
    return mapCount(get(s, 0));
}

pub fn setTransient(s: Value) Value {
    if (s.isObjectOf(.sorted_set)) rt.raise(.unsupported_operation_error, "a sorted set has no transient", .{});
    return make(.transient_set, &.{mapTransient(get(s, 0))});
}

pub fn tsetConj(t: Value, x: Value) Value {
    _ = tmapAssoc(get(t, 0), x, x);
    return t;
}

pub fn tsetDisj(t: Value, x: Value) Value {
    _ = tmapDissoc(get(t, 0), x);
    return t;
}

pub fn tsetPersistent(t: Value) Value {
    return make(.hash_set, &.{ tmapPersistent(get(t, 0)), Value.nil });
}

// ---------------------------------------------------------------------------------------
// Atoms

var atom_counter = std.atomic.Value(u32).init(0);

pub fn makeAtom(v: Value) Value {
    const n = atom_counter.fetchAdd(1, .monotonic) +% 1;
    // [value, hash, watches, validator] (watch.zig).
    return make(.atom, &.{ v, fx(@import("hash.zig").mix32(n)), Value.nil, Value.nil });
}

pub fn atomGet(a: Value) Value {
    const slot: *Value = &slots(a)[0];
    return @atomicLoad(Value, slot, .acquire);
}

pub fn atomReset(a: Value, v: Value) Value {
    const h = a.toObject();
    const slot: *Value = &h.valueSlots()[0];
    @atomicStore(Value, slot, v, .release);
    gc.barrier(h, v);
    return v;
}

/// Set the atom to `new` if it holds `old` (identical); returns whether it did.
pub fn atomCompareAndSet(a: Value, old: Value, new: Value) bool {
    const h = a.toObject();
    const slot: *Value = &h.valueSlots()[0];
    if (@cmpxchgStrong(Value, slot, old, new, .acq_rel, .acquire) != null) return false;
    // Only the barrier: storing again could undo another thread's newer value.
    gc.barrier(h, new);
    return true;
}
