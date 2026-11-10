//! SKEIN_GC_VERIFY=1 (M2.1, D-073): the runtime's own tables and globals of values,
//! which the collector checks after each collection in that mode, besides the roots and
//! the heap. Values stored where the collector doesn't look, without a root or the write
//! barrier, show up here as pointers to objects that are gone.

const gc = @import("gc.zig");
const coll = @import("coll.zig");
const cond = @import("cond.zig");
const core = @import("core.zig");
const ffi = @import("ffi.zig");
const names = @import("names.zig");
const objects = @import("objects.zig");
const structs = @import("structs.zig");
const Value = @import("value.zig").Value;

const Visit = *const fn (Value, []const u8) void;

/// Have the collector check these tables in verify mode (sk_init).
pub fn install() void {
    gc.verify_tables = check;
}

fn table(t: anytype, where: []const u8, visit: Visit) void {
    var it = t.iterator();
    while (it.next()) |entry| visit(entry.value_ptr.*, where);
}

fn values(vs: []const Value, where: []const u8, visit: Visit) void {
    for (vs) |v| visit(v, where);
}

fn check(visit: Visit) void {
    table(&names.symbols, "the symbol table", visit);
    table(&names.keywords, "the keyword table", visit);
    table(&names.namespaces, "the namespace table", visit);
    table(&cond.registry, "the condition type table", visit);
    table(&ffi.registry, "the C type table", visit);
    table(&structs.defs, "the struct table", visit);
    table(&objects.classes, "the class table", visit);
    table(&objects.generics, "the generic function table", visit);
    values(&cond.builtin_types, "the built-in condition types", visit);
    values(&objects.builtins, "the built-in classes", visit);
    values(&objects.core_generics, "skein.core's generic functions", visit);
    values(&core.objects, "the core function objects", visit);
    values(&.{ coll.empty_tuple, coll.empty_list, coll.empty_vector, coll.empty_node, coll.empty_map, coll.empty_set }, "the empty collections", visit);
}
