//! The Skein runtime (DESIGN §17, §18), Phase 1. Compiled Skein code (from the C backend,
//! M1.2) links against it.
//!
//! M1.1 provides the foundations: tagged values, the object header, per-thread bump
//! allocation and the platform layer. The garbage collector, core data structures and
//! conditions follow in M1.3–M1.5.

const std = @import("std");

pub const platform = @import("platform");
pub const value = @import("value.zig");
pub const object = @import("object.zig");
pub const heap = @import("heap.zig");

pub const Value = value.Value;

test {
    std.testing.refAllDecls(@This());
    _ = value;
    _ = object;
    _ = heap;
    _ = @import("platform_test.zig");
}
