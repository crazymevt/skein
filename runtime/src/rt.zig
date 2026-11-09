//! Process-wide runtime state: the heap, each thread's allocation buffer, and fatal
//! errors. Until conditions arrive (M1.5), an error in compiled code prints a message
//! and ends the program.

const std = @import("std");
const platform = @import("platform");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");

var heap: heap_mod.Heap = .{};
threadlocal var tlab: ?heap_mod.Tlab = null;

/// Allocate an object of `type_id` with `len` zeroed payload words, in this thread's
/// buffer. Running out of memory is fatal.
pub fn alloc(type_id: object.TypeId, len: usize) *object.Header {
    if (tlab == null) tlab = heap_mod.Tlab.init(&heap);
    return tlab.?.alloc(type_id, len) catch fatal("out of memory", .{});
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
