//! The object system natively (DESIGN §8, M1.8 step 4, D-054), matching Phase 0's
//! objects.lisp (which builds on CLOS): classes with C3 precedence lists, instances
//! whose slots are immutable unless they are cells, and generic functions with multiple
//! dispatch, eql specializers and standard method combination.
//!
//! Every value has a class: defclass classes, built-in classes (integer, string, seq,
//! ...), and one class per condition type. A generic function is a closure over its state
//! object; calling it computes the classes of the required arguments, finds the effective
//! method in a cache (unless the generic function has eql specializers) and runs it.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const stm = @import("stm.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const func = @import("func.zig");
const print = @import("print.zig");
const num = @import("num.zig");
const equal = @import("equal.zig");
const cond = @import("cond.zig");
const seqs = @import("seq.zig");
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

fn kw(text: []const u8) Value {
    return names.keyword(null, text);
}

fn isKw(v: Value, text: []const u8) bool {
    return names.isKeyword(v) and names.nsOf(v) == null and std.mem.eql(u8, names.nameOf(v), text);
}

// ---------------------------------------------------------------------------------------
// Classes

const c_name = 0;
const c_supers = 1;
const c_direct = 2;
const c_slots = 3;
const c_cpl = 4;
const c_kind = 5;
const c_type = 6;
/// Changes when a redefinition changes the slot layout (names, order or cell kinds):
/// instances made with an older one are brought up to date when next used (DESIGN §8.4).
const c_version = 7;

const kind_defclass = 0;
const kind_builtin = 1;
const kind_condition = 2;

pub fn isClass(v: Value) bool {
    return v.isObjectOf(.class);
}

pub fn className(c: Value) []const u8 {
    return string.bytes(slot(c, c_name));
}

var lock: platform.Mutex = .{};
pub var classes: std.StringHashMapUnmanaged(Value) = .empty;
pub var generics: std.StringHashMapUnmanaged(Value) = .empty;
const table_alloc = std.heap.page_allocator;

fn lookup(table: *std.StringHashMapUnmanaged(Value), key: []const u8) ?Value {
    lock.lock();
    defer lock.unlock();
    return table.get(key);
}

fn register(table: *std.StringHashMapUnmanaged(Value), key: []const u8, v: Value) void {
    lock.lock();
    defer lock.unlock();
    const k = table_alloc.dupe(u8, key) catch @panic("out of memory");
    table.put(table_alloc, k, v) catch @panic("out of memory");
}

fn newClass(name: []const u8, kind: i64) Value {
    const name_string = string.make(name);
    const empty = coll.vectorOf(&.{});
    const h = gc.allocPermanent(.class, 8);
    const c = Value.fromObject(h);
    setSlot(c, c_name, name_string);
    setSlot(c, c_supers, empty);
    setSlot(c, c_direct, empty);
    setSlot(c, c_slots, empty);
    setSlot(c, c_cpl, empty);
    setSlot(c, c_kind, Value.fromFixnum(kind));
    setSlot(c, c_type, Value.nil);
    setSlot(c, c_version, Value.fromFixnum(0));
    return c;
}

/// C3 linearization (DESIGN §8.1): the class, then a merge of its supers' precedence lists
/// and the supers themselves.
fn c3(c: Value, supers: Value) Value {
    var lists_buf: [64]Value = undefined;
    var heads: [64]usize = undefined;
    const n = coll.vectorCount(supers);
    if (n + 1 > lists_buf.len) rt.raise(.unsupported_operation_error, "a class with more than 63 superclasses", .{});
    for (0..n) |i| {
        lists_buf[i] = slot(coll.vectorNth(supers, i).?, c_cpl);
        heads[i] = 0;
    }
    lists_buf[n] = supers;
    heads[n] = 0;
    const lists = lists_buf[0 .. n + 1];
    var result = coll.vectorOf(&.{c});
    while (true) {
        var any = false;
        for (lists, 0..) |l, i| {
            if (heads[i] < coll.vectorCount(l)) any = true;
        }
        if (!any) return result;
        // The first head that appears in no list's tail.
        var candidate: ?Value = null;
        outer: for (lists, 0..) |l, i| {
            if (heads[i] >= coll.vectorCount(l)) continue;
            const head = coll.vectorNth(l, heads[i]).?;
            for (lists, 0..) |m, j| {
                var k = heads[j] + 1;
                while (k < coll.vectorCount(m)) : (k += 1) {
                    if (coll.vectorNth(m, k).? == head) continue :outer;
                }
            }
            candidate = head;
            break;
        }
        const chosen = candidate orelse
            rt.raise(.@"error", "the superclasses of {s} have no consistent order (C3)", .{className(c)});
        result = coll.vectorConj(result, chosen);
        for (lists, 0..) |l, i| {
            if (heads[i] < coll.vectorCount(l) and coll.vectorNth(l, heads[i]).? == chosen) heads[i] += 1;
        }
    }
}

// Built-in classes (DESIGN §8.3)

const Builtin = enum {
    any,
    object,
    nil_class,
    number,
    integer,
    float,
    f32,
    f64,
    char,
    string,
    keyword,
    symbol,
    vector,
    hash_map,
    hash_set,
    seq,
    list,
    @"fn",
    atom,
    ref,
    condition,
    @"error",
    warning,

    fn parents(b: Builtin) []const Builtin {
        return switch (b) {
            .any => &.{},
            .integer, .float => &.{.number},
            .f32, .f64 => &.{.float},
            .list => &.{.seq},
            .@"error", .warning => &.{.condition},
            else => &.{.any},
        };
    }

    fn name(b: Builtin) []const u8 {
        return switch (b) {
            .nil_class => "nil-class",
            .hash_map => "hash-map",
            .hash_set => "hash-set",
            else => @tagName(b),
        };
    }
};

pub var builtins: [std.enums.values(Builtin).len]Value = @splat(Value.nil);

/// Make the built-in classes and generic functions. sk_init calls this.
pub fn ensureBuiltins() void {
    if (builtins[0] != Value.nil) return;
    inline for (comptime std.enums.values(Builtin)) |b| {
        const c = newClass(b.name(), kind_builtin);
        var supers = coll.vectorOf(&.{});
        for (b.parents()) |p| supers = coll.vectorConj(supers, builtins[@intFromEnum(p)]);
        setSlot(c, c_supers, supers);
        setSlot(c, c_cpl, if (b == .any) coll.vectorOf(&.{c}) else c3(c, supers));
        builtins[@intFromEnum(b)] = c;
    }
    makeCoreGenerics();
}

fn builtin(b: Builtin) Value {
    return builtins[@intFromEnum(b)];
}

fn builtinNamed(text: []const u8) ?Value {
    inline for (comptime std.enums.values(Builtin)) |b| {
        if (std.mem.eql(u8, b.name(), text)) return builtin(b);
    }
    return null;
}

/// The class of a condition type: its own class, under the classes of its parents.
fn conditionClass(t: Value) Value {
    if (t == cond.builtinType(.condition)) return builtin(.condition);
    if (t == cond.builtinType(.@"error")) return builtin(.@"error");
    if (t == cond.builtinType(.warning)) return builtin(.warning);
    const name = cond.typeName(t);
    if (lookup(&classes, name)) |c| return c;
    const c = newClass(name, kind_condition);
    setSlot(c, c_type, t);
    var supers = coll.vectorOf(&.{});
    const parents = coll.get(t, 1);
    for (0..coll.vectorCount(parents)) |i| supers = coll.vectorConj(supers, conditionClass(coll.vectorNth(parents, i).?));
    if (coll.vectorCount(supers) == 0) supers = coll.vectorOf(&.{builtin(.condition)});
    setSlot(c, c_supers, supers);
    setSlot(c, c_cpl, c3(c, supers));
    register(&classes, name, c);
    return c;
}

/// The class of any value.
pub fn classOf(v: Value) Value {
    if (v == Value.nil) return builtin(.nil_class);
    if (v.isFixnum()) return builtin(.integer);
    if (v.isF32()) return builtin(.f32);
    if (v.isChar()) return builtin(.char);
    if (string.isString(v)) return builtin(.string);
    if (!v.isObject()) return builtin(.any);
    return switch (v.toObject().type_id) {
        .bignum => builtin(.integer),
        .f64 => builtin(.f64),
        .keyword => builtin(.keyword),
        .symbol => builtin(.symbol),
        .vector => builtin(.vector),
        .array_map, .hash_map => builtin(.hash_map),
        .hash_set => builtin(.hash_set),
        .list, .empty_list => builtin(.list),
        .cons, .lazy_seq, .vseq, .sseq, .tseq => builtin(.seq),
        .function => builtin(.@"fn"),
        .atom => builtin(.atom),
        .ref => builtin(.ref),
        .condition => conditionClass(cond.conditionType(v)),
        .instance => slot(v, 0),
        .@"struct" => structClass(@import("structs.zig").structDef(v)),
        else => builtin(.any),
    };
}

fn cplContains(cpl: Value, c: Value) bool {
    for (0..coll.vectorCount(cpl)) |i| if (coll.vectorNth(cpl, i).? == c) return true;
    return false;
}

/// True if `v` is an instance of class `c` or of a class below it.
pub fn isInstance(c: Value, v: Value) bool {
    return cplContains(slot(classOf(v), c_cpl), c);
}

/// The class that `x` names: a class, a condition type, or a symbol (a built-in class
/// name, or a class or condition type by its qualified name, or by a unique unqualified
/// one).
/// The class of a struct type (DESIGN §9.1: methods can specialize on value structs).
fn structClass(def: Value) Value {
    const structs = @import("structs.zig");
    const name = structs.defName(def);
    if (lookup(&classes, name)) |c| {
        if (slot(c, c_type) == def) return c;
    }
    const c = newClass(name, 3);
    setSlot(c, c_type, def);
    setSlot(c, c_supers, coll.vectorOf(&.{builtin(.any)}));
    setSlot(c, c_cpl, coll.vectorOf(&.{ c, builtin(.any) }));
    register(&classes, name, c);
    return c;
}

/// True if the symbol names a class, struct or condition type (for make-array).
pub fn knownClassName(x: Value) bool {
    if (!names.isSymbol(x)) return false;
    if (names.nsOf(x) == null and builtinNamed(names.nameOf(x)) != null) return true;
    var buf: [512]u8 = undefined;
    if (names.nsOf(x)) |ns| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(x) }) catch return false;
        return lookup(&classes, full) != null or cond.typeByName(full) != null;
    }
    return false;
}

pub fn findClass(x: Value) Value {
    if (isClass(x)) return x;
    if (cond.isType(x)) return conditionClass(x);
    const structs = @import("structs.zig");
    if (structs.findDef(x)) |def| {
        if (!names.isSymbol(x) or lookupDefclass(x) == null) return structClass(def);
    }
    if (!names.isSymbol(x)) rt.raise(.@"error", "{s} is not a class", .{readable(x)});
    if (names.nsOf(x) == null) {
        if (builtinNamed(names.nameOf(x))) |b| return b;
    }
    var buf: [512]u8 = undefined;
    if (names.nsOf(x)) |ns| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(x) }) catch "";
        if (lookup(&classes, full)) |c| return c;
    } else {
        // A unique unqualified name, as for condition types.
        var found: ?Value = null;
        {
            lock.lock();
            defer lock.unlock();
            var it = classes.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const s = std.mem.lastIndexOfScalar(u8, key, '/') orelse continue;
                if (std.mem.eql(u8, key[s + 1 ..], names.nameOf(x))) found = entry.value_ptr.*;
            }
        }
        if (found) |c| return c;
    }
    // A condition type, by its qualified name or in skein.core.
    if (names.nsOf(x)) |ns| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(x) }) catch "";
        if (cond.typeByName(full)) |t| return conditionClass(t);
    } else {
        const full = std.fmt.bufPrint(&buf, "skein.core/{s}", .{names.nameOf(x)}) catch "";
        if (cond.typeByName(full)) |t| return conditionClass(t);
    }
    rt.raise(.@"error", "{s} is not a class", .{readable(x)});
}

/// The defclass class a symbol names by its qualified name, or null.
fn lookupDefclass(x: Value) ?Value {
    var buf: [512]u8 = undefined;
    const full = if (names.nsOf(x)) |ns|
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(x) }) catch return null
    else
        return null;
    const c = lookup(&classes, full) orelse return null;
    return if (slot(c, c_kind).toFixnum() == kind_defclass) c else null;
}

fn cellKind(x: Value) Value {
    if (x == Value.nil) return Value.nil;
    if (isKw(x, "atom") or isKw(x, "unsynchronized") or isKw(x, "ref")) return x;
    rt.raise(.@"error", ":cell must be :atom, :ref or :unsynchronized, not {s}", .{readable(x)});
}

/// defclass: create or redefine the class `name` (a qualified symbol) with superclasses
/// `supers` (classes) and `direct` slots ([symbol cell init-fn type] vectors).
pub fn defineClass(name: Value, supers_in: Value, direct: Value) Value {
    var buf: [512]u8 = undefined;
    const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ names.nsOf(name) orelse "user", names.nameOf(name) }) catch
        rt.raise(.@"error", "the class name {s} is too long", .{names.nameOf(name)});
    for (0..coll.vectorCount(supers_in)) |i| {
        const s = coll.vectorNth(supers_in, i).?;
        if (!isClass(s) or (slot(s, c_kind).toFixnum() != kind_defclass and s != builtin(.object)))
            rt.raise(.@"error", "{s} cannot be a superclass of {s}; only classes defined with defclass can", .{ readable(s), qualified });
    }
    for (0..coll.vectorCount(direct)) |i| _ = cellKind(coll.vectorNth(coll.vectorNth(direct, i).?, 1).?);
    const supers = if (coll.vectorCount(supers_in) == 0) coll.vectorOf(&.{builtin(.object)}) else supers_in;
    const existing = lookup(&classes, qualified);
    const c = existing orelse blk: {
        const fresh = newClass(qualified, kind_defclass);
        register(&classes, qualified, fresh);
        break :blk fresh;
    };
    setSlot(c, c_supers, supers);
    setSlot(c, c_direct, direct);
    recompute(c);
    if (existing != null) {
        // Its subclasses inherit the change (DESIGN §8.4), and dispatch caches may hold
        // effective methods computed from the old precedence lists.
        var all = allClasses();
        defer all.deinit(std.heap.c_allocator);
        for (all.items) |k| {
            if (k != c and inPrecedenceList(k, c)) recompute(k);
        }
        clearDispatchCaches();
    }
    return c;
}

/// Compute class `c`'s precedence list and slots from its supers and direct slots; a
/// changed layout gets a new version.
fn recompute(c: Value) void {
    setSlot(c, c_cpl, c3(c, slot(c, c_supers)));
    const old = slot(c, c_slots);
    const new = effectiveSlots(c);
    setSlot(c, c_slots, new);
    if (!sameLayout(old, new)) setSlot(c, c_version, Value.fromFixnum(slot(c, c_version).toFixnum() + 1));
}

/// Whether two slot lists have the same names, in the same order, with the same cells.
fn sameLayout(a: Value, b: Value) bool {
    if (coll.vectorCount(a) != coll.vectorCount(b)) return false;
    for (0..coll.vectorCount(a)) |i| {
        const x = coll.vectorNth(a, i).?;
        const y = coll.vectorNth(b, i).?;
        if (coll.vectorNth(x, 0).? != coll.vectorNth(y, 0).?) return false;
        if (coll.vectorNth(x, 1).? != coll.vectorNth(y, 1).?) return false;
    }
    return true;
}

fn inPrecedenceList(k: Value, c: Value) bool {
    if (slot(k, c_kind).toFixnum() != kind_defclass) return false;
    const cpl = slot(k, c_cpl);
    for (0..coll.vectorCount(cpl)) |i| if (coll.vectorNth(cpl, i).? == c) return true;
    return false;
}

/// Every class by name (permanent objects), each after its superclasses: a class's
/// precedence list is longer than any of its superclasses', and recompute reads the
/// superclasses' precedence lists.
fn allClasses() std.ArrayList(Value) {
    lock.lock();
    defer lock.unlock();
    var out: std.ArrayList(Value) = .empty;
    var it = classes.valueIterator();
    while (it.next()) |v| out.append(std.heap.c_allocator, v.*) catch @panic("out of memory");
    std.mem.sort(Value, out.items, {}, struct {
        fn less(_: void, a: Value, b: Value) bool {
            return coll.vectorCount(slot(a, c_cpl)) < coll.vectorCount(slot(b, c_cpl));
        }
    }.less);
    return out;
}

/// The slots of a class, in Phase 0's order: walking the precedence list from its most
/// general class, each class's new slots in order. A slot's options come from the most
/// specific class that defines it.
fn effectiveSlots(c: Value) Value {
    const cpl = slot(c, c_cpl);
    var result = coll.vectorOf(&.{});
    var i = coll.vectorCount(cpl);
    while (i > 0) {
        i -= 1;
        const k = coll.vectorNth(cpl, i).?;
        const direct = slot(k, c_direct);
        for (0..coll.vectorCount(direct)) |j| {
            const name = names.nameOf(coll.vectorNth(coll.vectorNth(direct, j).?, 0).?);
            if (slotIndex(result, name) != null) continue;
            const spec = mostSpecificSlot(cpl, name);
            result = coll.vectorConj(result, coll.vectorOf(&.{
                kw(name),                   cellKind(coll.vectorNth(spec, 1).?),
                coll.vectorNth(spec, 2).?, coll.vectorNth(spec, 3).?,
            }));
        }
    }
    return result;
}

/// The direct slot `name` of the first class in `cpl` that defines it.
fn mostSpecificSlot(cpl: Value, name: []const u8) Value {
    for (0..coll.vectorCount(cpl)) |m| {
        const d = slot(coll.vectorNth(cpl, m).?, c_direct);
        for (0..coll.vectorCount(d)) |n| {
            const s = coll.vectorNth(d, n).?;
            if (std.mem.eql(u8, names.nameOf(coll.vectorNth(s, 0).?), name)) return s;
        }
    }
    unreachable;
}

fn slotIndex(slots: Value, name: []const u8) ?usize {
    for (0..coll.vectorCount(slots)) |i| {
        if (std.mem.eql(u8, names.nameOf(coll.vectorNth(coll.vectorNth(slots, i).?, 0).?), name)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Instances: [class, slots, owner, hash, version, values]. The slots and their values
// (a tuple) are those of the class's layout `version`; after a redefinition that changed
// it, `upToDate` brings the instance up to date before it's used (DESIGN §8.4).

const i_class = 0;
const i_slots = 1;
const i_owner = 2;
const i_hash = 3;
const i_version = 4;
const i_values = 5;

var instance_counter = std.atomic.Value(u32).init(0);

pub fn isObjectInstance(v: Value) bool {
    return v.isObjectOf(.instance);
}

fn slotCell(slots: Value, i: usize) Value {
    return coll.vectorNth(coll.vectorNth(slots, i).?, 1).?;
}

fn allocInstance(c: Value, slots: Value) Value {
    const values = coll.tupleN(coll.vectorCount(slots), Value.nil);
    const h = rt.alloc(.instance, i_values + 1);
    const s = h.valueSlots();
    s[i_class] = c;
    s[i_slots] = slots;
    s[i_owner] = Value.fromFixnum(@intCast(@import("fiber.zig").ownerId()));
    s[i_hash] = Value.fromFixnum(hash.mix32(instance_counter.fetchAdd(1, .monotonic) +% 1));
    s[i_version] = slot(c, c_version);
    s[i_values] = values;
    return Value.fromObject(h);
}

/// Slot value `i` of an up-to-date instance.
fn value(obj: Value, i: usize) Value {
    return coll.get(slot(obj, i_values), i);
}

fn setValue(obj: Value, i: usize, v: Value) void {
    coll.set(slot(obj, i_values), i, v);
}

/// `obj`, brought up to its class's current layout if a redefinition changed it, as
/// Phase 0 (CLOS) does: added slots get their :init, discarded ones are dropped, a slot
/// that changed between immutable and :atom is wrapped or unwrapped, then the generic
/// function update-instance-for-redefined-class gets the instance, the added and
/// discarded slots' keywords, and a map of the discarded slots' values.
fn upToDate(obj: Value) Value {
    const c = slot(obj, i_class);
    if (slot(obj, i_version) == slot(c, c_version)) return obj;
    const old_slots = slot(obj, i_slots);
    const old_values = slot(obj, i_values);
    const new_slots = slot(c, c_slots);
    const n = coll.vectorCount(new_slots);
    const values = coll.tupleN(n, Value.nil);
    var added = coll.vectorOf(&.{});
    for (0..n) |i| {
        const spec = coll.vectorNth(new_slots, i).?;
        const key = coll.vectorNth(spec, 0).?;
        const cell = coll.vectorNth(spec, 1).?;
        if (slotIndex(old_slots, names.nameOf(key))) |j| {
            const v = coll.get(old_values, j);
            const old_cell = slotCell(old_slots, j);
            // A cell of the same kind is kept (so are its watchers and transactions);
            // otherwise the value is unwrapped and wrapped in the new kind.
            const same = (isKw(old_cell, "atom") and isKw(cell, "atom")) or
                (isKw(old_cell, "ref") and isKw(cell, "ref"));
            coll.set(values, i, if (same) v else stored(cell, unwrapped(old_cell, v)));
        } else {
            const init = coll.vectorNth(spec, 2).?;
            coll.set(values, i, stored(cell, if (init == Value.nil) Value.nil else func.call(init, 0, &.{})));
            added = coll.vectorConj(added, key);
        }
    }
    var discarded = coll.vectorOf(&.{});
    var discarded_values = coll.mapOf(&.{});
    for (0..coll.vectorCount(old_slots)) |j| {
        const key = coll.vectorNth(coll.vectorNth(old_slots, j).?, 0).?;
        if (slotIndex(new_slots, names.nameOf(key)) == null) {
            discarded = coll.vectorConj(discarded, key);
            discarded_values = coll.mapAssoc(discarded_values, key, coll.get(old_values, j));
        }
    }
    // Up to date before the generic function sees it.
    setSlot(obj, i_slots, new_slots);
    setSlot(obj, i_values, values);
    setSlot(obj, i_version, slot(c, c_version));
    const args = [_]Value{ obj, added, discarded, discarded_values };
    _ = func.call(core_generics[@intFromEnum(CoreGeneric.@"update-instance-for-redefined-class")], 4, &args);
    return obj;
}

/// What a slot of cell kind `cell` holds for the value v: an atom or a ref, or v itself.
fn stored(cell: Value, v: Value) Value {
    if (isKw(cell, "atom")) return coll.makeAtom(v);
    if (isKw(cell, "ref")) return stm.makeRef(v);
    return v;
}

/// The value of what a slot of cell kind `cell` holds (a ref's committed value).
fn unwrapped(cell: Value, held: Value) Value {
    if (isKw(cell, "atom")) return coll.atomGet(held);
    if (isKw(cell, "ref")) return stm.committed(held);
    return held;
}

fn checkInitargs(c: Value, slots: Value, kvs: []const Value) void {
    if (kvs.len % 2 != 0) rt.raise(.@"error", "make and with need keys and values in pairs", .{});
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) {
        const k = kvs[i];
        if (!names.isKeyword(k) or slotIndex(slots, names.nameOf(k)) == null) slotNotFound(c, k);
    }
}

fn slotNotFound(c: Value, k: Value) noreturn {
    rt.raise(.@"error", "{s} has no slot {s}", .{ className(c), readable(k) });
}

fn given(kvs: []const Value, name: []const u8) ?Value {
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (std.mem.eql(u8, names.nameOf(kvs[i]), name)) return kvs[i + 1];
    }
    return null;
}

/// make: an instance of class `designator` from keyword/value pairs, then initialize.
pub fn make(designator: Value, kvs: []const Value) Value {
    const c = findClass(designator);
    if (slot(c, c_kind).toFixnum() != kind_defclass) rt.raise(.@"error", "{s} is not a class defined with defclass", .{readable(designator)});
    const slots = slot(c, c_slots);
    checkInitargs(c, slots, kvs);
    const obj = allocInstance(c, slots);
    for (0..coll.vectorCount(slots)) |i| {
        const spec = coll.vectorNth(slots, i).?;
        const name = names.nameOf(coll.vectorNth(spec, 0).?);
        const v = given(kvs, name) orelse blk: {
            const init = coll.vectorNth(spec, 2).?;
            break :blk if (init == Value.nil) Value.nil else func.call(init, 0, &.{});
        };
        setValue(obj, i, stored(coll.vectorNth(spec, 1).?, v));
    }
    const args = [_]Value{obj};
    _ = func.call(core_generics[@intFromEnum(CoreGeneric.initialize)], 1, &args);
    return obj;
}

/// with: a copy of `obj` with the slots in `kvs` changed. Cells are shared unless kvs
/// has :fresh-cells true; a changed cell slot gets a fresh cell.
pub fn with(obj: Value, kvs_in: []const Value) Value {
    if (obj.isObjectOf(.@"struct")) return @import("structs.zig").with(obj, kvs_in);
    if (!isObjectInstance(obj)) rt.raise(.@"error", "with needs an instance or struct, not {s}", .{readable(obj)});
    var buf: [128]Value = undefined;
    var n: usize = 0;
    var fresh = false;
    var i: usize = 0;
    while (i < kvs_in.len) : (i += 2) {
        if (i + 1 < kvs_in.len and isKw(kvs_in[i], "fresh-cells")) {
            fresh = kvs_in[i + 1] != Value.nil and kvs_in[i + 1] != Value.false;
            continue;
        }
        if (n + 2 > buf.len) rt.raise(.unsupported_operation_error, "with of more than 64 slots", .{});
        buf[n] = kvs_in[i];
        buf[n + 1] = if (i + 1 < kvs_in.len) kvs_in[i + 1] else Value.nil;
        n += 2;
    }
    if (kvs_in.len % 2 != 0) rt.raise(.@"error", "make and with need keys and values in pairs", .{});
    const kvs = buf[0..n];
    _ = upToDate(obj);
    const c = slot(obj, i_class);
    const slots = slot(obj, i_slots);
    checkInitargs(c, slots, kvs);
    const copy = allocInstance(c, slots);
    for (0..coll.vectorCount(slots)) |k| {
        const spec = coll.vectorNth(slots, k).?;
        const cell = coll.vectorNth(spec, 1).?;
        const old = value(obj, k);
        const v = if (given(kvs, names.nameOf(coll.vectorNth(spec, 0).?))) |g|
            stored(cell, g)
        else if (fresh and (isKw(cell, "atom") or isKw(cell, "ref")))
            stored(cell, cellValue(cell, old))
        else
            old;
        setValue(copy, k, v);
    }
    return copy;
}

/// A slot's value by keyword, or null: an :atom cell gives its current value (D-041).
pub fn get(obj: Value, key: Value) ?Value {
    if (!names.isKeyword(key)) return null;
    const slots = slot(upToDate(obj), i_slots);
    const i = slotIndex(slots, names.nameOf(key)) orelse return null;
    return cellValue(slotCell(slots, i), value(obj, i));
}

/// A slot's current value: an :atom cell's value, a :ref cell's (a transaction's view in
/// one), or what an immutable or :unsynchronized slot holds.
fn cellValue(cell: Value, held: Value) Value {
    if (isKw(cell, "atom")) return coll.atomGet(held);
    if (isKw(cell, "ref")) return stm.deref(held);
    return held;
}

pub fn keys(obj: Value) Value {
    const slots = slot(upToDate(obj), i_slots);
    var buf: [128]Value = undefined;
    const n = @min(coll.vectorCount(slots), buf.len);
    for (0..n) |i| buf[i] = coll.vectorNth(coll.vectorNth(slots, i).?, 0).?;
    return coll.listOf(buf[0..n]);
}

fn instanceSlot(obj: Value, key: Value, comptime what: []const u8) usize {
    if (!isObjectInstance(obj)) rt.raise(.@"error", what ++ " needs an instance, not {s}", .{readable(obj)});
    if (names.isKeyword(key)) {
        if (slotIndex(slot(upToDate(obj), i_slots), names.nameOf(key))) |i| return i;
    }
    slotNotFound(slot(obj, i_class), key);
}

fn immutable(obj: Value, key: Value) noreturn {
    rt.raise(.@"error", "slot {s} of {s} is immutable; use with to make a changed copy", .{ readable(key), className(slot(obj, i_class)) });
}

fn checkOwner(obj: Value, key: Value) void {
    if (slot(obj, i_owner).toFixnum() != @as(i64, @intCast(@import("fiber.zig").ownerId())))
        rt.raise(.@"error", "slot {s} of {s} is :unsynchronized and owned by another thread", .{ readable(key), className(slot(obj, i_class)) });
}

/// set-slot!: set a cell slot; returns the value.
pub fn setSlotValue(obj: Value, key: Value, v: Value) Value {
    const i = instanceSlot(obj, key, "set-slot!");
    const cell = slotCell(slot(obj, i_slots), i);
    if (cell == Value.nil) immutable(obj, key);
    if (isKw(cell, "atom")) return coll.atomReset(value(obj, i), v);
    if (isKw(cell, "ref")) return stm.setSlotRef(value(obj, i), v, "set-slot!");
    checkOwner(obj, key);
    setValue(obj, i, v);
    return v;
}

/// update-slot!: set a cell slot to (f current args...); an :atom cell retries like swap!.
pub fn updateSlot(obj: Value, key: Value, f: Value, args: []const Value) Value {
    const i = instanceSlot(obj, key, "update-slot!");
    const cell = slotCell(slot(obj, i_slots), i);
    if (cell == Value.nil) immutable(obj, key);
    var buf: [16]Value = undefined;
    if (args.len + 1 > buf.len) rt.raise(.unsupported_operation_error, "update-slot! with that many arguments is not supported natively yet", .{});
    @memcpy(buf[1 .. 1 + args.len], args);
    if (isKw(cell, "atom")) {
        const at = value(obj, i);
        while (true) {
            const old = coll.atomGet(at);
            buf[0] = old;
            const new = func.call(f, @intCast(1 + args.len), &buf);
            if (coll.atomCompareAndSet(at, old, new)) return new;
        }
    }
    if (isKw(cell, "ref")) return stm.updateSlotRef(value(obj, i), f, args);
    checkOwner(obj, key);
    buf[0] = value(obj, i);
    const new = func.call(f, @intCast(1 + args.len), &buf);
    setValue(obj, i, new);
    return new;
}

/// cell: the atom or ref behind an :atom or :ref cell slot.
pub fn cellOf(obj: Value, key: Value) Value {
    const i = instanceSlot(obj, key, "cell");
    const cell = slotCell(slot(obj, i_slots), i);
    if (cell == Value.nil)
        rt.raise(.@"error", "slot {s} of {s} has no cell; it is immutable", .{ readable(key), className(slot(obj, i_class)) });
    if (!isKw(cell, "atom") and !isKw(cell, "ref"))
        rt.raise(.@"error", "slot {s} of {s} is :unsynchronized; it holds its value directly, with no cell object", .{ readable(key), className(slot(obj, i_class)) });
    return value(obj, i);
}

/// set! on (:slot obj): an :unsynchronized, :atom or :ref (in a transaction) cell slot.
pub fn setBang(obj: Value, key: Value, v: Value) Value {
    if (!isObjectInstance(obj)) rt.raise(.@"error", "set! of {s} needs an instance, not {s}", .{ readable(key), readable(obj) });
    return setSlotValue(obj, key, v);
}

/// An instance's identity hash.
pub fn identityHash(obj: Value) u32 {
    return @intCast(slot(obj, i_hash).toFixnum());
}

/// Print an instance as Phase 0 does: #<ns/class {:slot value, ...}>.
pub fn writeInstance(obj: Value, out: *std.ArrayList(u8)) void {
    print.put(out, "#<");
    print.put(out, className(slot(obj, i_class)));
    print.put(out, " {");
    const slots = slot(upToDate(obj), i_slots);
    for (0..coll.vectorCount(slots)) |i| {
        if (i > 0) print.put(out, ", ");
        print.write(coll.vectorNth(coll.vectorNth(slots, i).?, 0).?, out, true);
        print.put(out, " ");
        print.write(get(obj, coll.vectorNth(coll.vectorNth(slots, i).?, 0).?).?, out, true);
    }
    print.put(out, "}>");
}

// ---------------------------------------------------------------------------------------
// Generic functions

const g_name = 0;
const g_required = 1;
const g_rest = 2;
const g_methods = 3;
const g_cache = 4;
const g_eql = 5;

fn gfName(g: Value) []const u8 {
    return string.bytes(slot(g, g_name));
}

/// The state behind a generic function value, or null if it is not one.
pub fn genericOf(f: Value) ?Value {
    if (!f.isObjectOf(.function) or func.codeOf(f) != dispatchCode) return null;
    return func.capturedOf(f, 0);
}

fn newGeneric(name: []const u8, required: usize, rest: bool) Value {
    const n = string.make(name);
    const h = gc.allocPermanent(.generic, 6);
    const g = Value.fromObject(h);
    setSlot(g, g_name, n);
    setSlot(g, g_required, Value.fromFixnum(@intCast(required)));
    setSlot(g, g_rest, Value.fromBool(rest));
    setSlot(g, g_methods, coll.vectorOf(&.{}));
    setSlot(g, g_cache, Value.nil);
    setSlot(g, g_eql, Value.false);
    lock.lock();
    all_generics.append(table_alloc, g) catch @panic("out of memory");
    lock.unlock();
    // Permanent: the generics table isn't scanned by the collector, so a young closure
    // there would be left stale by a collection.
    return func.permanentClosure(dispatchCode, "generic", &.{g});
}

/// Every generic function's state (permanent objects), whose caches a class
/// redefinition clears.
var all_generics: std.ArrayList(Value) = .empty;

fn clearDispatchCaches() void {
    lock.lock();
    defer lock.unlock();
    for (all_generics.items) |g| setSlot(g, g_cache, Value.nil);
}

/// The generic function named `name` with this many required parameters, made if
/// needed (an existing one with other parameters is replaced).
fn ensureGeneric(name: []const u8, required: usize, rest: bool) Value {
    if (lookup(&generics, name)) |f| {
        const g = genericOf(f).?;
        if (slot(g, g_required).toFixnum() == @as(i64, @intCast(required)) and (slot(g, g_rest) == Value.true) == rest) return f;
    }
    const f = newGeneric(name, required, rest);
    register(&generics, name, f);
    return f;
}

/// defgeneric: `name` (a symbol) in namespace `ns` with parameters `params`.
pub fn defineGeneric(name: Value, ns: []const u8, params: Value) Value {
    var required: usize = 0;
    var rest = false;
    for (0..coll.vectorCount(params)) |i| {
        if (std.mem.eql(u8, names.nameOf(coll.vectorNth(params, i).?), "&")) {
            rest = true;
            break;
        }
        required += 1;
    }
    var buf: [512]u8 = undefined;
    const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ns, names.nameOf(name) }) catch
        rt.raise(.@"error", "the generic function name {s} is too long", .{names.nameOf(name)});
    return ensureGeneric(qualified, required, rest);
}

/// (= value) in a method's parameters.
pub fn eqlSpecializer(v: Value) Value {
    const h = rt.alloc(.eql_specializer, 1);
    h.valueSlots()[0] = v;
    return Value.fromObject(h);
}

/// defmethod: add a method to the generic function in `target` (a var, created there if
/// it holds none, or a generic function itself). `specs` has a class, an eql specializer
/// or nil per required parameter; `f` takes call-next-method, next-method? and the
/// arguments.
pub fn defineMethod(target: Value, qualifier: Value, specs: Value, rest_v: Value, f: Value) Value {
    const required = coll.vectorCount(specs);
    const rest = rest_v != Value.nil and rest_v != Value.false;
    const gfn = if (genericOf(target) != null) target else blk: {
        const current = names.varValue(target);
        if (genericOf(current) != null) break :blk current;
        var buf: [512]u8 = undefined;
        const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ names.varNamespaceName(target), names.varName(target) }) catch "";
        const made = ensureGeneric(qualified, required, rest);
        names.setVar(target, made);
        break :blk made;
    };
    const g = genericOf(gfn).?;
    if (slot(g, g_required).toFixnum() != @as(i64, @intCast(required)) or (slot(g, g_rest) == Value.true) != rest)
        rt.raise(.@"error", "the parameters of this method do not match the generic function {s} ({d} required{s})", .{
            gfName(g), slot(g, g_required).toFixnum(), if (slot(g, g_rest) == Value.true) ", with a rest parameter" else "",
        });
    // Resolve specializers: classes stay, eql specializers stay, nil means any.
    var resolved = coll.vectorOf(&.{});
    var has_eql = slot(g, g_eql) == Value.true;
    for (0..required) |i| {
        const s = coll.vectorNth(specs, i).?;
        if (s.isObjectOf(.eql_specializer)) has_eql = true;
        resolved = coll.vectorConj(resolved, if (s == Value.nil or s.isObjectOf(.eql_specializer)) s else findClass(s));
    }
    const h = rt.alloc(.method, 3);
    h.valueSlots()[0] = qualifier;
    h.valueSlots()[1] = resolved;
    h.valueSlots()[2] = f;
    const m = Value.fromObject(h);
    // A method with the same qualifier and specializers replaces the old one.
    const methods = slot(g, g_methods);
    var kept = coll.vectorOf(&.{});
    for (0..coll.vectorCount(methods)) |i| {
        const old = coll.vectorNth(methods, i).?;
        if (!(sameQualifier(slot(old, 0), qualifier) and sameSpecializers(slot(old, 1), resolved))) kept = coll.vectorConj(kept, old);
    }
    setSlot(g, g_methods, coll.vectorConj(kept, m));
    setSlot(g, g_cache, Value.nil);
    setSlot(g, g_eql, Value.fromBool(has_eql));
    return gfn;
}

fn sameQualifier(a: Value, b: Value) bool {
    if (a == Value.nil or b == Value.nil) return a == b;
    return std.mem.eql(u8, names.nameOf(a), names.nameOf(b));
}

fn sameSpecializers(a: Value, b: Value) bool {
    for (0..coll.vectorCount(a)) |i| {
        const x = coll.vectorNth(a, i).?;
        const y = coll.vectorNth(b, i).?;
        if (x.isObjectOf(.eql_specializer) and y.isObjectOf(.eql_specializer)) {
            if (!eql(slot(x, 0), slot(y, 0))) return false;
        } else if (x != y) return false;
    }
    return true;
}

/// CL's eql: identity, or numbers of the same kind and value, or equal chars.
fn eql(a: Value, b: Value) bool {
    if (a == b) return true;
    if (num.isNumber(a) and num.isNumber(b)) return num.kind(a) == num.kind(b) and num.numbersEqual(a, b);
    return false;
}

fn applies(spec: Value, arg: Value, arg_class: Value) bool {
    if (spec == Value.nil) return true;
    if (spec.isObjectOf(.eql_specializer)) return eql(slot(spec, 0), arg);
    return cplContains(slot(arg_class, c_cpl), spec);
}

/// Position of a specializer in an argument's precedence list (eql most specific, any
/// least).
fn rank(spec: Value, arg_class: Value) usize {
    if (spec.isObjectOf(.eql_specializer)) return 0;
    if (spec == Value.nil) return std.math.maxInt(usize);
    const cpl = slot(arg_class, c_cpl);
    for (0..coll.vectorCount(cpl)) |i| if (coll.vectorNth(cpl, i).? == spec) return i + 1;
    return std.math.maxInt(usize);
}

/// True if method a is more specific than method b for these argument classes.
fn moreSpecific(a: Value, b: Value, arg_classes: []const Value) bool {
    const sa = slot(a, 1);
    const sb = slot(b, 1);
    for (arg_classes, 0..) |c, i| {
        const ra = rank(coll.vectorNth(sa, i).?, c);
        const rb = rank(coll.vectorNth(sb, i).?, c);
        if (ra != rb) return ra < rb;
    }
    return false;
}

const Effective = struct {
    arounds: Value,
    befores: Value,
    primaries: Value,
    afters: Value,
};

/// The effective method for these arguments: [arounds befores primaries afters], each
/// most specific first (afters run in reverse).
fn effectiveMethod(g: Value, args: []const Value, arg_classes: []const Value) Value {
    var buf: [256]Value = undefined;
    var n: usize = 0;
    const methods = slot(g, g_methods);
    for (0..coll.vectorCount(methods)) |i| {
        const m = coll.vectorNth(methods, i).?;
        const specs = slot(m, 1);
        var ok = true;
        for (args, 0..) |a, j| {
            if (!applies(coll.vectorNth(specs, j).?, a, arg_classes[j])) {
                ok = false;
                break;
            }
        }
        if (ok and n < buf.len) {
            buf[n] = m;
            n += 1;
        }
    }
    // Insertion sort, most specific first; stable for equal specificity.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const x = buf[i];
        var j = i;
        while (j > 0 and moreSpecific(x, buf[j - 1], arg_classes)) : (j -= 1) buf[j] = buf[j - 1];
        buf[j] = x;
    }
    var groups: [4]Value = .{ coll.vectorOf(&.{}), coll.vectorOf(&.{}), coll.vectorOf(&.{}), coll.vectorOf(&.{}) };
    for (buf[0..n]) |m| {
        const q = slot(m, 0);
        const k: usize = if (q == Value.nil) 2 else if (isKw(q, "around")) 0 else if (isKw(q, "before")) 1 else 3;
        groups[k] = coll.vectorConj(groups[k], m);
    }
    return coll.vectorOf(&groups);
}

fn noMethod(g: Value, args: []const Value) noreturn {
    rt.raise(.@"error", "no method of {s} applies to {s}", .{ gfName(g), readable(coll.listOf(args)) });
}

/// The code of every generic function: dispatch on the required arguments' classes.
fn dispatch(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const g = func.capturedOf(self, 0);
    const required: usize = @intCast(slot(g, g_required).toFixnum());
    const rest = slot(g, g_rest) == Value.true;
    if (argc < required or (!rest and argc > required))
        rt.raise(.arity_error, "wrong number of arguments ({d}) passed to {s}", .{ argc, gfName(g) });
    var classes_buf: [32]Value = undefined;
    if (required > classes_buf.len) rt.raise(.unsupported_operation_error, "a generic function with more than 32 required parameters", .{});
    for (0..required) |i| classes_buf[i] = classOf(argv[i]);
    const arg_classes = classes_buf[0..required];
    const em = blk: {
        if (slot(g, g_eql) == Value.true) break :blk effectiveMethod(g, argv[0..required], arg_classes);
        const key = coll.vectorOf(arg_classes);
        const cache = slot(g, g_cache);
        if (cache != Value.nil) {
            if (coll.mapGet(cache, key)) |hit| break :blk hit;
        }
        const computed = effectiveMethod(g, argv[0..required], arg_classes);
        setSlot(g, g_cache, coll.mapAssoc(if (cache == Value.nil) coll.mapOf(&.{}) else cache, key, computed));
        break :blk computed;
    };
    const args = coll.vectorOf(argv[0..argc]);
    if (coll.vectorCount(coll.vectorNth(em, 2).?) == 0 and coll.vectorCount(coll.vectorNth(em, 0).?) == 0)
        noMethod(g, argv[0..argc]);
    return run(g, em, 0, 0, args);
}

const dispatchCode: func.Code = dispatch;

/// Stages of the effective method: 0 the around methods, 1 the primary methods.
fn run(g: Value, em: Value, stage: u8, index: usize, args: Value) Value {
    if (stage == 0) {
        const arounds = coll.vectorNth(em, 0).?;
        if (index < coll.vectorCount(arounds)) return callMethod(g, em, coll.vectorNth(arounds, index).?, 0, index + 1, args);
        // The inner method: befores, the primaries, afters in reverse.
        const befores = coll.vectorNth(em, 1).?;
        for (0..coll.vectorCount(befores)) |i| _ = callMethod(g, em, coll.vectorNth(befores, i).?, 2, 0, args);
        const primaries = coll.vectorNth(em, 2).?;
        if (coll.vectorCount(primaries) == 0) noMethod(g, vectorItems(args));
        const result = callMethod(g, em, coll.vectorNth(primaries, 0).?, 1, 1, args);
        const afters = coll.vectorNth(em, 3).?;
        var i = coll.vectorCount(afters);
        while (i > 0) {
            i -= 1;
            _ = callMethod(g, em, coll.vectorNth(afters, i).?, 2, 0, args);
        }
        return result;
    }
    const primaries = coll.vectorNth(em, 2).?;
    if (index >= coll.vectorCount(primaries))
        rt.raise(.@"error", "no next method of {s} for {s}", .{ gfName(g), readable(coll.listOf(vectorItems(args))) });
    return callMethod(g, em, coll.vectorNth(primaries, index).?, 1, index + 1, args);
}

fn vectorItems(v: Value) []const Value {
    // Arguments are short; read them into a thread-local scratch array.
    const S = struct {
        threadlocal var buf: [64]Value = undefined;
    };
    const n = @min(coll.vectorCount(v), S.buf.len);
    for (0..n) |i| S.buf[i] = coll.vectorNth(v, i).?;
    return S.buf[0..n];
}

/// Call method m with call-next-method and next-method? for what follows it: in `stage`
/// (0 arounds, 1 primaries, 2 none) from `next`.
fn callMethod(g: Value, em: Value, m: Value, stage: u8, next: usize, args: Value) Value {
    const captured = [_]Value{ g, em, Value.fromFixnum(stage), Value.fromFixnum(@intCast(next)), args };
    const cnm = func.closure(callNextCode, "call-next-method", &captured);
    const nmp = func.closure(nextMethodPCode, "next-method?", &captured);
    var buf: [66]Value = undefined;
    const n = coll.vectorCount(args);
    if (n + 2 > buf.len) rt.raise(.unsupported_operation_error, "a method called with more than 64 arguments", .{});
    buf[0] = cnm;
    buf[1] = nmp;
    for (0..n) |i| buf[2 + i] = coll.vectorNth(args, i).?;
    return func.call(slot(m, 2), @intCast(n + 2), &buf);
}

fn callNext(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    const g = func.capturedOf(self, 0);
    const em = func.capturedOf(self, 1);
    const stage: u8 = @intCast(func.capturedOf(self, 2).toFixnum());
    const next: usize = @intCast(func.capturedOf(self, 3).toFixnum());
    const args = if (argc > 0) coll.vectorOf(argv[0..argc]) else func.capturedOf(self, 4);
    if (stage == 2) rt.raise(.@"error", "no next method of {s}: :before and :after methods have none", .{gfName(g)});
    return run(g, em, stage, next, args);
}

const callNextCode: func.Code = callNext;

fn nextMethodP(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    const em = func.capturedOf(self, 1);
    const stage = func.capturedOf(self, 2).toFixnum();
    const next: usize = @intCast(func.capturedOf(self, 3).toFixnum());
    return Value.fromBool(switch (stage) {
        0 => next < coll.vectorCount(coll.vectorNth(em, 0).?) or coll.vectorCount(coll.vectorNth(em, 2).?) > 0,
        1 => next < coll.vectorCount(coll.vectorNth(em, 2).?),
        else => false,
    });
}

const nextMethodPCode: func.Code = nextMethodP;

pub fn genericName(f: Value) []const u8 {
    return gfName(genericOf(f).?);
}

/// generic-methods: a list of [[qualifiers] [specializers]], an eql specializer as (= v).
pub fn genericMethods(f: Value) Value {
    const g = genericOf(f) orelse rt.raise(.@"error", "{s} is not a generic function", .{readable(f)});
    const methods = slot(g, g_methods);
    var buf: [256]Value = undefined;
    const n = @min(coll.vectorCount(methods), buf.len);
    for (0..n) |i| {
        const m = coll.vectorNth(methods, i).?;
        const q = slot(m, 0);
        const specs = slot(m, 1);
        var shown = coll.vectorOf(&.{});
        for (0..coll.vectorCount(specs)) |j| {
            const s = coll.vectorNth(specs, j).?;
            shown = coll.vectorConj(shown, if (s == Value.nil)
                builtin(.any)
            else if (s.isObjectOf(.eql_specializer))
                coll.listOf(&.{ names.symbol(null, "="), slot(s, 0) })
            else
                s);
        }
        buf[i] = coll.vectorOf(&.{ if (q == Value.nil) coll.vectorOf(&.{}) else coll.vectorOf(&.{q}), shown });
    }
    return coll.listOf(buf[0..n]);
}

// The generic functions of skein.core.

pub const CoreGeneric = enum { equiv, @"hash-of", initialize, @"update-instance-for-redefined-class" };

pub var core_generics: [4]Value = @splat(Value.nil);

pub fn coreGeneric(name: []const u8) ?Value {
    ensureBuiltins();
    inline for (comptime std.enums.values(CoreGeneric)) |c| {
        if (std.mem.eql(u8, @tagName(c), name)) return core_generics[@intFromEnum(c)];
    }
    return null;
}

fn equivDefault(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    const a = argv[2];
    const b = argv[3];
    return Value.fromBool(if (isObjectInstance(a)) a == b else equal.equiv(a, b));
}

fn hashDefault(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    const x = argv[2];
    return Value.fromFixnum(if (isObjectInstance(x)) identityHash(x) else equal.hashOf(x));
}

fn nothing(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    _ = argv;
    return Value.nil;
}

fn makeCoreGenerics() void {
    const defs = [_]struct { CoreGeneric, usize, func.Code }{
        .{ .equiv, 2, equivDefault },
        .{ .@"hash-of", 1, hashDefault },
        .{ .initialize, 1, nothing },
        .{ .@"update-instance-for-redefined-class", 4, nothing },
    };
    for (defs) |d| {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "skein.core/{s}", .{@tagName(d[0])}) catch unreachable;
        const f = ensureGeneric(name, d[1], false);
        var specs = coll.vectorOf(&.{});
        for (0..d[1]) |_| specs = coll.vectorConj(specs, Value.nil);
        _ = defineMethod(f, Value.nil, specs, Value.false, func.make(d[2], "default-method"));
        core_generics[@intFromEnum(d[0])] = f;
    }
}

/// True if a method of the core generic `which` more specific than its default applies
/// to `args` (whose first is an instance): then = and hash-of use it (DESIGN §7).
fn specialized(which: CoreGeneric, args: []const Value) bool {
    const g = genericOf(core_generics[@intFromEnum(which)]).?;
    var classes_buf: [4]Value = undefined;
    for (args, 0..) |a, i| classes_buf[i] = classOf(a);
    const methods = slot(g, g_methods);
    for (0..coll.vectorCount(methods)) |i| {
        const m = coll.vectorNth(methods, i).?;
        const specs = slot(m, 1);
        if (coll.vectorNth(specs, 0).? == Value.nil) continue;
        var ok = true;
        for (args, 0..) |a, j| {
            if (!applies(coll.vectorNth(specs, j).?, a, classes_buf[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// = of an instance: identity unless equiv is specialized for it.
pub fn instanceEquiv(a: Value, b: Value) bool {
    const args = [_]Value{ a, b };
    if (!specialized(.equiv, &args)) return a == b;
    const r = func.call(core_generics[@intFromEnum(CoreGeneric.equiv)], 2, &args);
    return r != Value.nil and r != Value.false;
}

/// hash-of an instance: its identity hash unless hash-of is specialized for it.
pub fn instanceHash(x: Value) u32 {
    const args = [_]Value{x};
    if (!specialized(.@"hash-of", &args)) return identityHash(x);
    const r = func.call(core_generics[@intFromEnum(CoreGeneric.@"hash-of")], 1, &args);
    return if (r.isFixnum()) @truncate(@as(u64, @bitCast(r.toFixnum()))) else equal.hashOf(r);
}

/// The class's name as a symbol: ns/name, or name for a built-in class.
pub fn classNameSymbol(c: Value) Value {
    const full = className(c);
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |s| return names.symbol(full[0..s], full[s + 1 ..]);
    return names.symbol(null, full);
}

pub fn classSlots(c: Value) Value {
    const slots = slot(c, c_slots);
    var result = coll.vectorOf(&.{});
    for (0..coll.vectorCount(slots)) |i| result = coll.vectorConj(result, coll.vectorNth(coll.vectorNth(slots, i).?, 0).?);
    return result;
}

pub fn precedenceList(c: Value) Value {
    const cpl = slot(c, c_cpl);
    var buf: [128]Value = undefined;
    const n = @min(coll.vectorCount(cpl), buf.len);
    for (0..n) |i| buf[i] = coll.vectorNth(cpl, i).?;
    return coll.listOf(buf[0..n]);
}

// ---------------------------------------------------------------------------------------
// The C interface

/// %define-method with a resolved target: a var or a generic function (D-054).
export fn sk_define_method(target: Value, qualifier: Value, specs: Value, rest: Value, f: Value) Value {
    return defineMethod(target, qualifier, specs, rest, f);
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testSetup() void {
    coll.ensureConstants();
    cond.ensureBuiltins();
    ensureBuiltins();
}

fn slotSpec(name: []const u8) Value {
    return coll.vectorOf(&.{ names.symbol(null, name), Value.nil, Value.nil, Value.nil });
}

test "C3 orders a diamond, and slots follow the most general class first" {
    testSetup();
    const top = defineClass(names.symbol("t", "top"), coll.vectorOf(&.{}), coll.vectorOf(&.{slotSpec("a")}));
    const left = defineClass(names.symbol("t", "left"), coll.vectorOf(&.{top}), coll.vectorOf(&.{slotSpec("b")}));
    const right = defineClass(names.symbol("t", "right"), coll.vectorOf(&.{top}), coll.vectorOf(&.{slotSpec("c")}));
    const bottom = defineClass(names.symbol("t", "bottom"), coll.vectorOf(&.{ left, right }), coll.vectorOf(&.{ slotSpec("d"), slotSpec("a") }));
    const cpl = slot(bottom, c_cpl);
    const expected = [_]Value{ bottom, left, right, top, builtin(.object), builtin(.any) };
    try testing.expectEqual(expected.len, coll.vectorCount(cpl));
    for (expected, 0..) |c, i| try testing.expectEqual(c, coll.vectorNth(cpl, i).?);
    const slots = classSlots(bottom);
    const order = [_][]const u8{ "a", "c", "b", "d" };
    for (order, 0..) |n, i| try testing.expectEqualStrings(n, names.nameOf(coll.vectorNth(slots, i).?));
    try testing.expect(isInstance(top, make(bottom, &.{})));
    try testing.expect(!isInstance(left, make(right, &.{})));
}

test "every value has a class" {
    testSetup();
    try testing.expectEqual(builtin(.integer), classOf(Value.fromFixnum(1)));
    try testing.expect(isInstance(builtin(.number), Value.fromF32(1.5)));
    try testing.expect(isInstance(builtin(.seq), coll.listOf(&.{Value.nil})));
    try testing.expect(isInstance(builtin(.@"error"), cond.makeBuiltin(.arithmetic_error, "x")));
    try testing.expect(!isInstance(builtin(.warning), cond.makeBuiltin(.arithmetic_error, "x")));
}

/// Define the test's generic functions in a frame of their own, so no stale stack word
/// keeps them in place.
noinline fn defineTestGenerics() void {
    for (0..40) |i| {
        var buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "g{d}", .{i}) catch unreachable;
        _ = defineGeneric(names.symbol(null, n), "t.gen", coll.vectorOf(&.{ names.symbol(null, "a"), names.symbol(null, "b") }));
    }
}

noinline fn scrubStack() void {
    var junk: [16384]usize = undefined;
    @memset(&junk, 0);
    std.mem.doNotOptimizeAway(&junk);
}

test "generic functions survive collections" {
    // Regression (M1.12): the generics table held young closures, which a minor
    // collection moved, so defining the same generic again read a stale pointer.
    testSetup();
    defineTestGenerics();
    scrubStack();
    for (0..4) |_| {
        gc.collect(.minor);
        for (0..20000) |i| _ = string.make(if (i % 2 == 0) "xxxxxxxxxxxxxxxxxxxxxxxx" else "yy");
    }
    gc.collect(.major);
    for (0..40) |i| {
        var buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "g{d}", .{i}) catch unreachable;
        const f = defineGeneric(names.symbol(null, n), "t.gen", coll.vectorOf(&.{ names.symbol(null, "a"), names.symbol(null, "b") }));
        try testing.expect(genericOf(f) != null);
        try testing.expectEqualStrings(n, gfName(genericOf(f).?)[6..]);
    }
}
