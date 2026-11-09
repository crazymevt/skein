//! Process-wide runtime services: allocation (through the garbage collector) and errors.
//! The runtime's errors are conditions (M1.5, cond.zig) that programs can handle; only
//! errors the program can't survive, such as running out of memory, are fatal.

const std = @import("std");
const platform = @import("platform");
const object = @import("object.zig");
const gc = @import("gc.zig");

/// Allocate an object of `type_id` with `len` zeroed payload words. It may trigger a
/// collection, which can move unpinned young objects (but not ones the stack refers to).
pub fn alloc(type_id: object.TypeId, len: usize) *object.Header {
    return gc.alloc(type_id, len);
}

pub const Builtin = @import("cond.zig").Builtin;

/// Signal an error of the built-in condition type `kind` with a formatted message. If no
/// handler unwinds, the program reports it and exits with status 1.
pub fn raise(kind: Builtin, comptime fmt: []const u8, args: anytype) noreturn {
    @import("cond.zig").raise(kind, fmt, args);
}

/// Print "error: <message>" to standard error and exit with status 1, for errors the
/// program can't survive (no memory, a broken heap).
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch blk: {
        const tail = "...\n";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf[0..];
    };
    platform.writeStderr(msg);
    std.process.exit(1);
}

/// Scratch memory for short-lived work (printing, building messages). Freed by the caller.
/// malloc: the page allocator would make a system call for every buffer.
pub const scratch = std.heap.c_allocator;
