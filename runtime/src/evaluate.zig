//! Evaluating code in a running native program (M2.5, D-078).
//!
//! A program built with `--eval` (dev profile) includes the reader, the expander and the
//! evaluator. At start-up it registers its namespaces and vars here; skein.compiler.env
//! builds its model of the program from this registry the first time it's used, with each
//! model var pointing at the program's real var. skein.compiler.eval then installs the
//! functions behind eval, load-file, reload and macroexpand. In any other build those
//! functions are errors: nothing installs them.

const std = @import("std");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const func = @import("func.zig");
const names = @import("names.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

// ---------------------------------------------------------------------------------------
// The registry: what the program's start-up code registers, before anything runs.

/// A namespace's description, a map that's a constant of the program: `info` points at
/// its global, which the collector keeps up to date.
var namespaces: std.ArrayList(*const Value) = .empty;

const VarEntry = struct { ns: [*:0]const u8, name: [*:0]const u8, v: Value, flags: u32 };
/// Var objects are permanent, so the entries hold them without being roots.
var vars: std.ArrayList(VarEntry) = .empty;

pub const flag_macro = 1;
pub const flag_private = 2;
pub const flag_dynamic = 4;

/// Register a namespace: `info` is the address of a constant map {:name :file
/// :requires :syntax-requires :aliases :refers}.
export fn sk_eval_register_ns(info: *const Value) void {
    namespaces.append(alloc, info) catch rt.fatal("out of memory (eval registry)", .{});
}

/// Register a var of the program: `v` is its var object, or nil for a var the program
/// never compiled code for; `flags` are flag_macro, flag_private and flag_dynamic.
export fn sk_eval_register_var(ns: [*:0]const u8, name: [*:0]const u8, v: Value, flags: u32) void {
    vars.append(alloc, .{ .ns = ns, .name = name, .v = v, .flags = flags }) catch
        rt.fatal("out of memory (eval registry)", .{});
}

/// [namespace-infos vars] for skein.compiler.env, each var [ns name var-or-nil macro?
/// private? dynamic?]; nil if the program registered nothing (not an --eval build).
fn registry() Value {
    if (namespaces.items.len == 0 and vars.items.len == 0) return Value.nil;
    var infos = coll.vectorOf(&.{});
    for (namespaces.items) |p| infos = coll.vectorConj(infos, p.*);
    var vs = coll.vectorOf(&.{});
    for (vars.items) |e| {
        vs = coll.vectorConj(vs, coll.vectorOf(&.{
            string.make(std.mem.span(e.ns)),
            string.make(std.mem.span(e.name)),
            e.v,
            Value.fromBool(e.flags & flag_macro != 0),
            Value.fromBool(e.flags & flag_private != 0),
            Value.fromBool(e.flags & flag_dynamic != 0),
        }));
    }
    return coll.vectorOf(&.{ infos, vs });
}

// ---------------------------------------------------------------------------------------
// The functions behind eval, load-file, reload and macroexpand

/// [hooks]: a map from a function's name to the function that does its work.
var hooks: [1]Value = .{Value.nil};
var hooks_ready = false;

fn install(m: Value) Value {
    if (!hooks_ready) {
        gc.addRoots(&hooks);
        hooks_ready = true;
    }
    hooks[0] = m;
    return Value.nil;
}

fn callHook(comptime name: []const u8, args: []const Value) Value {
    const f = if (hooks[0] == Value.nil) null else coll.mapGet(hooks[0], string.make(name));
    if (f == null or f.? == Value.nil)
        rt.raise(.@"error", name ++ " needs a native build made with --eval (dev profile)", .{});
    return func.call(f.?, @intCast(args.len), args.ptr);
}

// ---------------------------------------------------------------------------------------
// The program's real vars, for the model (env.skn) and the evaluator

fn checkVar(v: Value, comptime what: []const u8) void {
    if (!v.isObjectOf(.@"var"))
        rt.raise(.type_error, what ++ " needs a var", .{});
}

const Args = []const Value;
const Entry = @import("compiler.zig").Entry;

fn hookEntry(comptime name: []const u8) Entry {
    return .{ .name = name, .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return callHook(name, a);
        }
    }.f };
}

pub const entries = [_]Entry{
    hookEntry("eval"),
    hookEntry("load-file"),
    hookEntry("reload"),
    hookEntry("macroexpand-1"),
    hookEntry("macroexpand"),
    hookEntry("macroexpand-all"),
    .{ .name = "%install-evaluator!", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return install(a[0]);
        }
    }.f },
    .{ .name = "%eval-registry", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return registry();
        }
    }.f },
    // (%runtime-var-value var not-found): the value of a real var, or not-found if it's
    // unbound.
    .{ .name = "%runtime-var-value", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkVar(a[0], "%runtime-var-value");
            const v = names.varValue(a[0]);
            return if (v == Value.unbound) a[1] else v;
        }
    }.f },
    .{ .name = "%set-runtime-var-value!", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            checkVar(a[0], "%set-runtime-var-value!");
            names.setVar(a[0], a[1]);
            return a[1];
        }
    }.f },
};
