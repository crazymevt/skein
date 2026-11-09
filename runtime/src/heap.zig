//! Heap allocation (DESIGN §18.1, D-043). Each thread bump-allocates in its own
//! thread-local allocation buffer (TLAB): a run of a 1 MiB chunk that the heap hands
//! out under a lock. Objects of 32 KiB and more go to the large object space, one OS
//! mapping each. Nothing is collected yet: the garbage collector arrives in M1.3, and
//! until then memory goes back to the OS only when the heap is torn down.

const std = @import("std");
const platform = @import("platform");
const object = @import("object.zig");
const Value = @import("value.zig").Value;

pub const chunk_size: usize = 1 << 20;
pub const large_object_bytes: usize = 32 * 1024;

/// Every chunk and large object starts with this link, so the heap can find them all.
const Region = struct {
    next: ?*Region,
    memory: []align(platform.page_size_min) u8,
};

/// Where objects start inside a region: after its link, 16-byte aligned.
const region_overhead: usize = std.mem.alignForward(usize, @sizeOf(Region), 16);

pub const Heap = struct {
    mutex: platform.Mutex = .{},
    chunks: ?*Region = null,
    large: ?*Region = null,
    /// Bytes reserved from the OS.
    reserved_bytes: usize = 0,

    /// Return every chunk and large object to the OS. Nothing may use the heap after.
    pub fn deinit(heap: *Heap) void {
        inline for (.{ &heap.chunks, &heap.large }) |list| {
            var r = list.*;
            while (r) |region| {
                r = region.next;
                platform.release(region.memory);
            }
            list.* = null;
        }
        heap.reserved_bytes = 0;
    }

    /// Map a region with room for `bytes` of objects and link it into `list`.
    fn newRegion(heap: *Heap, bytes: usize, list: *?*Region) ![*]u8 {
        const len = std.mem.alignForward(usize, bytes + region_overhead, platform.pageSize());
        const memory = try platform.reserve(len);
        errdefer platform.release(memory);
        try platform.commit(memory);
        const region: *Region = @ptrCast(memory.ptr);
        heap.mutex.lock();
        defer heap.mutex.unlock();
        region.* = .{ .next = list.*, .memory = memory };
        list.* = region;
        heap.reserved_bytes += len;
        return memory.ptr + region_overhead;
    }

    fn newChunk(heap: *Heap) ![]u8 {
        const start = try heap.newRegion(chunk_size - region_overhead, &heap.chunks);
        return start[0 .. chunk_size - region_overhead];
    }

    /// Count the chunks and large objects, for tests and statistics.
    pub fn regionCounts(heap: *Heap) struct { chunks: usize, large: usize } {
        heap.mutex.lock();
        defer heap.mutex.unlock();
        var counts: @TypeOf(heap.regionCounts()) = .{ .chunks = 0, .large = 0 };
        var r = heap.chunks;
        while (r) |region| : (r = region.next) counts.chunks += 1;
        r = heap.large;
        while (r) |region| : (r = region.next) counts.large += 1;
        return counts;
    }
};

/// A thread's allocation buffer. Use one per thread; it is not thread-safe itself.
pub const Tlab = struct {
    heap: *Heap,
    cursor: usize = 0,
    limit: usize = 0,

    pub fn init(heap: *Heap) Tlab {
        return .{ .heap = heap };
    }

    /// Allocate an object of `type_id` with `len` zeroed payload words.
    pub fn alloc(t: *Tlab, type_id: object.TypeId, len: usize) !*object.Header {
        if (len > object.max_len) return error.OutOfMemory;
        const bytes = (1 + len) * 8;
        const address = if (bytes >= large_object_bytes)
            @intFromPtr(try t.heap.newRegion(bytes, &t.heap.large))
        else blk: {
            if (t.limit - t.cursor < bytes) {
                const chunk = try t.heap.newChunk();
                t.cursor = @intFromPtr(chunk.ptr);
                t.limit = t.cursor + chunk.len;
            }
            const address = t.cursor;
            t.cursor += bytes;
            break :blk address;
        };
        // Fresh pages read as zero, and nothing is freed yet, so the payload is zero.
        const h: *object.Header = @ptrFromInt(address);
        h.* = object.Header.init(type_id, @intCast(len));
        return h;
    }

    /// A boxed f64.
    pub fn boxF64(t: *Tlab, x: f64) !Value {
        const h = try t.alloc(.f64, 1);
        h.payload()[0] = @bitCast(x);
        return Value.fromObject(h);
    }
};

/// The f64 in a boxed f64 value.
pub fn unboxF64(v: Value) f64 {
    std.debug.assert(v.isObjectOf(.f64));
    return @bitCast(v.toObject().payload()[0]);
}

// ---------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "objects are aligned, zeroed and laid out one after another" {
    var heap: Heap = .{};
    defer heap.deinit();
    var t = Tlab.init(&heap);
    const a = try t.alloc(.f64, 1);
    const b = try t.alloc(.f64, 3);
    try testing.expect(@intFromPtr(a) % 8 == 0 and @intFromPtr(b) % 8 == 0);
    try testing.expectEqual(@intFromPtr(a) + 16, @intFromPtr(b));
    for (b.payload()) |w| try testing.expectEqual(@as(u64, 0), w);
    try testing.expectEqual(@as(u24, 3), b.len);
}

test "boxed f64s round trip" {
    var heap: Heap = .{};
    defer heap.deinit();
    var t = Tlab.init(&heap);
    const xs = [_]f64{ 0.0, -0.0, 3.141592653589793, std.math.inf(f64), std.math.floatMax(f64) };
    for (xs) |x| {
        const v = try t.boxF64(x);
        try testing.expect(v.isObjectOf(.f64));
        try testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(unboxF64(v))));
    }
}

test "allocation moves to new chunks, and large objects get their own space" {
    var heap: Heap = .{};
    defer heap.deinit();
    var t = Tlab.init(&heap);
    // 3 MiB of small objects needs at least three chunks.
    for (0..3 * chunk_size / 64) |_| _ = try t.alloc(.f64, 7);
    const big = try t.alloc(.f64, large_object_bytes / 8);
    big.payload()[big.len - 1] = 99;
    const counts = heap.regionCounts();
    try testing.expect(counts.chunks >= 3);
    try testing.expectEqual(@as(usize, 1), counts.large);
    try testing.expect(heap.reserved_bytes >= 3 * chunk_size + large_object_bytes);
}

test "random allocations never overlap (checked against a model)" {
    var heap: Heap = .{};
    defer heap.deinit();
    var t = Tlab.init(&heap);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const Span = struct { start: usize, end: usize };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(testing.allocator);
    for (0..20_000) |i| {
        // Mostly small, sometimes large.
        const len = if (random.uintLessThan(u32, 100) == 0)
            random.intRangeAtMost(usize, 4096, 20_000)
        else
            random.intRangeAtMost(usize, 0, 64);
        const h = try t.alloc(.f64, len);
        // Fill the payload with a pattern to check later.
        for (h.payload()) |*w| w.* = i;
        try spans.append(testing.allocator, .{ .start = @intFromPtr(h), .end = @intFromPtr(h) + h.size() });
    }
    std.mem.sort(Span, spans.items, {}, struct {
        fn lessThan(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.lessThan);
    for (spans.items[1..], spans.items[0 .. spans.items.len - 1]) |b, a|
        try testing.expect(a.end <= b.start);
}

test "threads allocate in their own buffers" {
    var heap: Heap = .{};
    defer heap.deinit();
    const per_thread = 50_000;
    const Worker = struct {
        fn run(h: *Heap, id: usize, out: *std.atomic.Value(bool)) void {
            var t = Tlab.init(h);
            var first: ?*object.Header = null;
            var objects: [per_thread]*object.Header = undefined;
            for (&objects, 0..) |*slot, i| {
                const o = t.alloc(.f64, 2) catch return;
                o.payload()[0] = id;
                o.payload()[1] = i;
                slot.* = o;
                if (first == null) first = o;
            }
            // Every object still holds what this thread wrote.
            for (objects, 0..) |o, i| {
                if (o.payload()[0] != id or o.payload()[1] != i) return;
            }
            out.store(true, .release);
        }
    };
    var ok: [8]std.atomic.Value(bool) = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, i| {
        ok[i] = .init(false);
        th.* = try std.Thread.spawn(.{}, Worker.run, .{ &heap, i, &ok[i] });
    }
    for (threads) |th| th.join();
    for (&ok) |*o| try testing.expect(o.load(.acquire));
    try testing.expect(heap.regionCounts().chunks >= 8);
}
