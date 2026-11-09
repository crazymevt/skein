//! Process-wide runtime services: allocation (through the garbage collector) and fatal
//! errors. Until conditions arrive (M1.5), an error in compiled code prints a message
//! and ends the program.

const std = @import("std");
const platform = @import("platform");
const object = @import("object.zig");
const gc = @import("gc.zig");

/// Allocate an object of `type_id` with `len` zeroed payload words. It may trigger a
/// collection, which can move unpinned young objects (but not ones the stack refers to).
pub fn alloc(type_id: object.TypeId, len: usize) *object.Header {
    return gc.alloc(type_id, len);
}

/// Print "error: <message>" to standard error and exit with status 1.
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

/// Scratch memory for short-lived work (printing big numbers). Freed by the caller.
pub const scratch = std.heap.page_allocator;
