//! The Skein runtime (DESIGN §17, §18), Phase 1. Compiled Skein code (from the C backend,
//! M1.2) links against it.
//!
//! M1.5 added conditions, restarts and non-local exits (cond.zig, unwind.c).
//!
//! M1.3 replaced M1.1's bump-only heap with the garbage collector (gc.zig).
//!
//! M1.1 provided the foundations: tagged values, the object header, per-thread bump
//! allocation and the platform layer. M1.2 adds what the first compiled programs need:
//! strings, bignums and the number tower, printing, functions, and the C ABI in api.zig
//! (declared in include/skein.h). The garbage collector, core data structures and
//! conditions follow in M1.3–M1.5.

const std = @import("std");

pub const platform = @import("platform");
pub const value = @import("value.zig");
pub const object = @import("object.zig");
pub const gc = @import("gc.zig");
pub const rt = @import("rt.zig");
pub const num = @import("num.zig");
pub const string = @import("string.zig");
pub const func = @import("func.zig");
pub const print = @import("print.zig");
pub const api = @import("api.zig");
pub const hash = @import("hash.zig");
pub const names = @import("names.zig");
pub const coll = @import("coll.zig");
pub const equal = @import("equal.zig");
pub const core = @import("core.zig");
pub const cond = @import("cond.zig");
pub const seq = @import("seq.zig");

pub const Value = value.Value;

// Zig compiles only what is referenced; reference every C entry point so the static
// library exports them all.
comptime {
    for (std.meta.declarations(api)) |name| _ = &@field(api, name);
    for (std.meta.declarations(cond)) |name| _ = &@field(cond, name);
}

test {
    std.testing.refAllDecls(@This());
    _ = value;
    _ = object;
    _ = gc;
    _ = @import("gc_test.zig");
    _ = num;
    _ = string;
    _ = func;
    _ = print;
    _ = api;
    _ = hash;
    _ = names;
    _ = coll;
    _ = equal;
    _ = @import("coll_test.zig");
    _ = core;
    _ = cond;
    _ = seq;
    _ = @import("cond_test.zig");
    _ = @import("platform_test.zig");
}
