//! Sorted maps and sets (DESIGN §6.2, M2.11, D-093): persistent AVL trees ordered by a
//! comparator, `compare` unless one is given. A comparator is a function of two values
//! that returns a negative, zero or positive number, or, as Clojure allows, a predicate
//! such as `>`: true means the first comes before the second.
//!
//! coll.zig's map and set functions (mapGet, mapAssoc, setConj, ...) send sorted ones
//! here, so get, assoc, conj, =, hashing and printing treat them as maps and sets. Their
//! seq is a tseq: a stack of the tree's nodes, so walking one takes O(1) amortized a step
//! and starts in O(log n), from either end or from a key (subseq, rsubseq).

const std = @import("std");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const num = @import("num.zig");
const equal = @import("equal.zig");
const print = @import("print.zig");
const Value = @import("value.zig").Value;

// sorted_map: [count, root (node or nil), comparator (nil: compare), hash or nil]
// sorted_set: [sorted map of each element to itself, hash or nil]
// tree_node: [key, value, left, right, height]
// tseq: [stack (a list of nodes, the next first), flags]
const m_count = 0;
const m_root = 1;
const m_cmp = 2;
const n_key = 0;
const n_val = 1;
const n_left = 2;
const n_right = 3;
const n_height = 4;
const descending: i64 = 1;
const keys_only: i64 = 2;

fn get(v: Value, i: usize) Value {
    return coll.get(v, i);
}

pub fn isSortedMap(v: Value) bool {
    return v.isObjectOf(.sorted_map);
}

pub fn isSortedSet(v: Value) bool {
    return v.isObjectOf(.sorted_set);
}

pub fn isSorted(v: Value) bool {
    return isSortedMap(v) or isSortedSet(v);
}

/// The sorted map behind a sorted map or set.
fn mapOf(v: Value) Value {
    return if (isSortedSet(v)) get(v, 0) else v;
}

pub fn makeMap(comparator: Value) Value {
    return coll.make(.sorted_map, &.{ Value.fromFixnum(0), Value.nil, comparator, Value.nil });
}

fn withRoot(m: Value, n: usize, root: Value) Value {
    return coll.make(.sorted_map, &.{ coll.fx(n), root, get(m, m_cmp), Value.nil });
}

pub fn makeSet(comparator: Value) Value {
    return coll.make(.sorted_set, &.{ makeMap(comparator), Value.nil });
}

fn setWith(m: Value) Value {
    return coll.make(.sorted_set, &.{ m, Value.nil });
}

pub fn comparatorOf(v: Value) Value {
    return get(mapOf(v), m_cmp);
}

// ---------------------------------------------------------------------------------------
// Comparing

fn truthy(v: Value) bool {
    return v != Value.nil and v != Value.false;
}

pub fn compareWith(cmp: Value, a: Value, b: Value) i32 {
    if (cmp == Value.nil) return equal.compare(a, b);
    const r = func.call(cmp, 2, &.{ a, b });
    if (num.isNumber(r)) {
        return switch (num.compare("a comparator", r, Value.fromFixnum(0)) orelse .gt) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    if (r == Value.nil or r == Value.true or r == Value.false) {
        if (truthy(r)) return -1;
        return if (truthy(func.call(cmp, 2, &.{ b, a }))) 1 else 0;
    }
    var out: std.ArrayList(u8) = .empty;
    print.write(r, &out, true);
    rt.raise(.type_error, "a comparator must return a number or a boolean, not {s}", .{out.items});
}

// ---------------------------------------------------------------------------------------
// The tree

fn height(n: Value) i64 {
    return if (n == Value.nil) 0 else get(n, n_height).toFixnum();
}

fn node(k: Value, v: Value, l: Value, r: Value) Value {
    return coll.make(.tree_node, &.{ k, v, l, r, Value.fromFixnum(@max(height(l), height(r)) + 1) });
}

/// A node of k and v over l and r, rotated so the heights differ by at most one (they
/// differ by at most two before).
fn balance(k: Value, v: Value, l: Value, r: Value) Value {
    const hl = height(l);
    const hr = height(r);
    if (hl > hr + 1) {
        const ll = get(l, n_left);
        const lr = get(l, n_right);
        if (height(ll) >= height(lr))
            return node(get(l, n_key), get(l, n_val), ll, node(k, v, lr, r));
        return node(get(lr, n_key), get(lr, n_val), node(get(l, n_key), get(l, n_val), ll, get(lr, n_left)), node(k, v, get(lr, n_right), r));
    }
    if (hr > hl + 1) {
        const rl = get(r, n_left);
        const rr = get(r, n_right);
        if (height(rr) >= height(rl))
            return node(get(r, n_key), get(r, n_val), node(k, v, l, rl), rr);
        return node(get(rl, n_key), get(rl, n_val), node(k, v, l, get(rl, n_left)), node(get(r, n_key), get(r, n_val), get(rl, n_right), rr));
    }
    return node(k, v, l, r);
}

fn insert(cmp: Value, n: Value, k: Value, v: Value, added: *bool) Value {
    if (n == Value.nil) {
        added.* = true;
        return node(k, v, Value.nil, Value.nil);
    }
    const c = compareWith(cmp, k, get(n, n_key));
    const l = get(n, n_left);
    const r = get(n, n_right);
    if (c < 0) {
        const l2 = insert(cmp, l, k, v, added);
        return if (l2 == l) n else balance(get(n, n_key), get(n, n_val), l2, r);
    }
    if (c > 0) {
        const r2 = insert(cmp, r, k, v, added);
        return if (r2 == r) n else balance(get(n, n_key), get(n, n_val), l, r2);
    }
    // The key it has stays (as Clojure's).
    if (get(n, n_val) == v) return n;
    return coll.make(.tree_node, &.{ get(n, n_key), v, l, r, get(n, n_height) });
}

fn minNode(n: Value) Value {
    var x = n;
    while (get(x, n_left) != Value.nil) x = get(x, n_left);
    return x;
}

fn withoutMin(n: Value) Value {
    const l = get(n, n_left);
    if (l == Value.nil) return get(n, n_right);
    return balance(get(n, n_key), get(n, n_val), withoutMin(l), get(n, n_right));
}

fn remove(cmp: Value, n: Value, k: Value, removed: *bool) Value {
    if (n == Value.nil) return n;
    const c = compareWith(cmp, k, get(n, n_key));
    const l = get(n, n_left);
    const r = get(n, n_right);
    if (c < 0) {
        const l2 = remove(cmp, l, k, removed);
        return if (l2 == l) n else balance(get(n, n_key), get(n, n_val), l2, r);
    }
    if (c > 0) {
        const r2 = remove(cmp, r, k, removed);
        return if (r2 == r) n else balance(get(n, n_key), get(n, n_val), l, r2);
    }
    removed.* = true;
    if (l == Value.nil) return r;
    if (r == Value.nil) return l;
    const m = minNode(r);
    return balance(get(m, n_key), get(m, n_val), l, withoutMin(r));
}

fn find(m: Value, k: Value) ?Value {
    const cmp = get(m, m_cmp);
    var n = get(m, m_root);
    while (n != Value.nil) {
        const c = compareWith(cmp, k, get(n, n_key));
        if (c == 0) return n;
        n = get(n, if (c < 0) n_left else n_right);
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Maps (what coll.zig's map functions call for a sorted map)

pub fn count(m: Value) usize {
    return coll.ux(get(m, m_count));
}

pub fn lookup(m: Value, k: Value) ?Value {
    const n = find(m, k) orelse return null;
    return get(n, n_val);
}

pub fn assoc(m: Value, k: Value, v: Value) Value {
    var added = false;
    const root = get(m, m_root);
    const new = insert(get(m, m_cmp), root, k, v, &added);
    if (new == root) return m;
    return withRoot(m, count(m) + @intFromBool(added), new);
}

pub fn dissoc(m: Value, k: Value) Value {
    var removed = false;
    const root = get(m, m_root);
    const new = remove(get(m, m_cmp), root, k, &removed);
    if (!removed) return m;
    return withRoot(m, count(m) - 1, new);
}

fn eachNode(n: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value, Value) bool) bool {
    if (n == Value.nil) return true;
    if (!eachNode(get(n, n_left), ctx, f)) return false;
    if (!f(ctx, get(n, n_key), get(n, n_val))) return false;
    return eachNode(get(n, n_right), ctx, f);
}

/// Call f(ctx, key, value) for each entry in order, until it returns false.
pub fn each(m: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), Value, Value) bool) void {
    _ = eachNode(get(m, m_root), ctx, f);
}

// Sets

pub fn setConj(s: Value, x: Value) Value {
    const m = get(s, 0);
    const new = assoc(m, x, x);
    return if (new == m) s else setWith(new);
}

pub fn setDisj(s: Value, x: Value) Value {
    const m = get(s, 0);
    const new = dissoc(m, x);
    return if (new == m) s else setWith(new);
}

/// An empty sorted map or set with the comparator of v.
pub fn empty(v: Value) Value {
    return if (isSortedSet(v)) makeSet(comparatorOf(v)) else makeMap(comparatorOf(v));
}

// ---------------------------------------------------------------------------------------
// Seqs

fn flagsOf(v: Value, desc: bool) i64 {
    return (if (desc) descending else 0) | (if (isSortedSet(v)) keys_only else 0);
}

/// Push n and the spine below it toward the first element (left, or right descending).
fn pushSpine(stack: Value, n: Value, desc: bool) Value {
    var s = stack;
    var x = n;
    while (x != Value.nil) {
        s = coll.cons(x, s);
        x = get(x, if (desc) n_right else n_left);
    }
    return s;
}

fn makeSeq(stack: Value, flags: i64) Value {
    if (!stack.isObjectOf(.list)) return Value.nil;
    return coll.make(.tseq, &.{ stack, Value.fromFixnum(flags) });
}

/// The seq of a sorted map's entries or a sorted set's elements, in order or reversed;
/// nil if it's empty.
pub fn seq(v: Value, desc: bool) Value {
    const root = get(mapOf(v), m_root);
    return makeSeq(pushSpine(coll.empty_list, root, desc), flagsOf(v, desc));
}

/// The seq from the first entry whose key is at or after k (at or before it descending).
pub fn seqFrom(v: Value, k: Value, desc: bool) Value {
    const m = mapOf(v);
    const cmp = get(m, m_cmp);
    var stack = coll.empty_list;
    var n = get(m, m_root);
    while (n != Value.nil) {
        const c = compareWith(cmp, k, get(n, n_key));
        if (c == 0) {
            stack = coll.cons(n, stack);
            break;
        }
        if ((c < 0) != desc) {
            stack = coll.cons(n, stack);
            n = get(n, if (desc) n_right else n_left);
        } else n = get(n, if (desc) n_left else n_right);
    }
    return makeSeq(stack, flagsOf(v, desc));
}

pub fn seqFirst(s: Value) Value {
    const n = coll.get(get(s, 0), 0);
    if (get(s, 1).toFixnum() & keys_only != 0) return get(n, n_key);
    return coll.vectorOf(&.{ get(n, n_key), get(n, n_val) });
}

pub fn seqNext(s: Value) Value {
    const stack = get(s, 0);
    const flags = get(s, 1).toFixnum();
    const desc = flags & descending != 0;
    const n = coll.get(stack, 0);
    const below = get(n, if (desc) n_left else n_right);
    return makeSeq(pushSpine(coll.get(stack, 1), below, desc), flags);
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn checkTree(n: Value, lo: ?i64, hi: ?i64) !i64 {
    if (n == Value.nil) return 0;
    const k = get(n, n_key).toFixnum();
    if (lo) |l| try testing.expect(k > l);
    if (hi) |h| try testing.expect(k < h);
    const hl = try checkTree(get(n, n_left), lo, k);
    const hr = try checkTree(get(n, n_right), k, hi);
    try testing.expect(@abs(hl - hr) <= 1);
    try testing.expectEqual(@max(hl, hr) + 1, height(n));
    return height(n);
}

test "sorted maps match a model under random assoc and dissoc" {
    const gc = @import("gc.zig");
    coll.ensureConstants();
    var prng = std.Random.DefaultPrng.init(0x50f7ed);
    const random = prng.random();
    var model: std.AutoHashMap(i64, i64) = .init(testing.allocator);
    defer model.deinit();
    var m = makeMap(Value.nil);
    var saved = m;
    var saved_count: usize = 0;
    for (0..20_000) |step| {
        const k = random.intRangeLessThan(i64, 0, 700);
        if (random.uintLessThan(u8, 3) < 2) {
            const v = random.int(i32);
            m = assoc(m, Value.fromFixnum(k), Value.fromFixnum(v));
            try model.put(k, v);
        } else {
            m = dissoc(m, Value.fromFixnum(k));
            _ = model.remove(k);
        }
        if (step == 10_000) {
            saved = m;
            saved_count = model.count();
        }
        if (step % 4000 == 0) gc.collect(if (step % 8000 == 0) .major else .minor);
        if (step % 1000 == 0) _ = try checkTree(get(m, m_root), null, null);
    }
    _ = try checkTree(get(m, m_root), null, null);
    try testing.expectEqual(model.count(), count(m));
    try testing.expectEqual(saved_count, count(saved));
    // The seq walks the keys in order, and the model's values match.
    const keys = try testing.allocator.alloc(i64, model.count());
    defer testing.allocator.free(keys);
    var it = model.keyIterator();
    var at: usize = 0;
    while (it.next()) |k| : (at += 1) keys[at] = k.*;
    std.mem.sort(i64, keys, {}, std.sort.asc(i64));
    var s = seq(m, false);
    for (keys) |k| {
        const entry = seqFirst(s);
        try testing.expectEqual(k, coll.vectorNth(entry, 0).?.toFixnum());
        try testing.expectEqual(model.get(k).?, coll.vectorNth(entry, 1).?.toFixnum());
        s = seqNext(s);
    }
    try testing.expectEqual(Value.nil, s);
    // Descending, and from a key in both directions.
    s = seq(m, true);
    var i = keys.len;
    while (i > 0) : (s = seqNext(s)) {
        i -= 1;
        try testing.expectEqual(keys[i], coll.vectorNth(seqFirst(s), 0).?.toFixnum());
    }
    for ([_]i64{ -1, 0, 350, 351, 699, 700 }) |from| {
        var first_up: ?i64 = null;
        for (keys) |k| if (k >= from) {
            first_up = k;
            break;
        };
        const up = seqFrom(m, Value.fromFixnum(from), false);
        if (first_up) |k| try testing.expectEqual(k, coll.vectorNth(seqFirst(up), 0).?.toFixnum()) else try testing.expectEqual(Value.nil, up);
        var first_down: ?i64 = null;
        var j = keys.len;
        while (j > 0) {
            j -= 1;
            if (keys[j] <= from) {
                first_down = keys[j];
                break;
            }
        }
        const down = seqFrom(m, Value.fromFixnum(from), true);
        if (first_down) |k| try testing.expectEqual(k, coll.vectorNth(seqFirst(down), 0).?.toFixnum()) else try testing.expectEqual(Value.nil, down);
    }
}
