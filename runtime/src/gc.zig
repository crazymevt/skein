//! The garbage collector (DESIGN §18.1, D-045): a mostly-copying generational collector.
//!
//! The heap is one reserved arena split into 256 KiB segments, each with a metadata
//! record, so any address maps to its segment in constant time.
//!
//! - **Nursery.** Each thread bump-allocates in its own nursery segment, setting a bit
//!   per object in the segment's start bitmap. A minor collection scans every thread's
//!   stack (and spilled registers) conservatively: anything that might be a pointer into
//!   a young object, even into its middle, pins that object where it is. Everything else
//!   reachable from the precise roots (registered globals, the remembered set, pinned
//!   objects) is copied into the old generation. A segment that held pinned objects is
//!   promoted whole, keeping only those objects; the other segments are freed.
//! - **Old generation.** Objects live in size-class blocks (one class per segment),
//!   promoted segments, or large-object runs, and never move. A major collection marks
//!   from the roots and stacks and sweeps.
//! - **Large objects** (32 KiB and up) get their own run of segments. They start young
//!   and are promoted in place by the minor collection that first finds them reachable.
//! - **Write barrier.** Storing a young object into an old one records the old object in
//!   the remembered set, whose objects are roots for the next minor collection.
//! - **Threads** stop at safepoints: when allocating a new buffer, when compiled code
//!   polls `sk_gc_pending`, or around blocking calls (`blocking`).

const std = @import("std");
const platform = @import("platform");
const object = @import("object.zig");
const Header = object.Header;
const Value = @import("value.zig").Value;

pub const segment_size: usize = 256 * 1024;
pub const segment_words: usize = segment_size / 8;
const arena_size: usize = 16 << 30;
const max_segments: usize = arena_size / segment_size;
/// Objects of this many words (header included) and more are large.
pub const large_words: usize = 4096 + 1;
/// Minor collections happen after this many nursery segments (or the equivalent in
/// large objects) have been handed out.
const default_nursery_segments: usize = 32;
/// The old generation's size that triggers the first major collection.
const min_major_bytes: usize = 32 << 20;

const meta_alloc = std.heap.page_allocator;

// ---------------------------------------------------------------------------------------
// Size classes for the old generation, in words (header included)

const size_classes = blk: {
    var classes: [64]u16 = undefined;
    var n: usize = 0;
    for (2..9) |w| {
        classes[n] = w;
        n += 1;
    }
    var base: usize = 8;
    while (base < 4096) : (base *= 2) {
        for (1..5) |k| {
            classes[n] = base + base * k / 4;
            n += 1;
        }
    }
    break :blk classes[0..n].*;
};

fn classFor(words: usize) u8 {
    for (size_classes, 0..) |w, i| if (w >= words) return @intCast(i);
    unreachable;
}

// ---------------------------------------------------------------------------------------
// Segments

const Kind = enum(u8) { free, nursery, small, pinned, large_head, large_tail };

const Bitmap = [segment_words / 64]u64;

const Segment = struct {
    kind: Kind = .free,
    /// A large run that hasn't survived a minor collection yet.
    young: bool = false,
    /// Minor collection: a nursery segment holding pinned objects.
    has_pins: bool = false,
    /// Minor collection: a young large object found reachable.
    reached: bool = false,
    class: u8 = 0,
    /// Large head: segments in the run. Large tail: index of the head.
    run: u32 = 0,
    /// Object starts, for nursery and promoted segments.
    bits: ?*Bitmap = null,
    // Small blocks: cells handed out by bumping, capacity, and a free list threaded
    // through payload word 0 of free cells (0 = empty).
    bump: u32 = 0,
    cells: u32 = 0,
    free_list: usize = 0,
};

/// One thread that allocates from the heap.
pub const Mutator = struct {
    cursor: usize = 0,
    limit: usize = 0,
    stack_high: usize,
    /// While parked: the lowest stack address that may hold heap pointers.
    saved_sp: usize = 0,
    state: enum { running, parked, native } = .running,
    next: ?*Mutator = null,
};

pub const Stats = struct {
    minor_collections: u64 = 0,
    major_collections: u64 = 0,
    pause_ns_total: u64 = 0,
    pause_ns_max: u64 = 0,
    bytes_promoted: u64 = 0,
    old_bytes: usize = 0,
    committed_segments: usize = 0,
};

const State = struct {
    base: usize = 0,
    segments: []Segment = &.{},
    free_map: []u64 = &.{},
    high_water: usize = 0,
    spare_bitmaps: std.ArrayList(*Bitmap) = .empty,

    /// Nursery segments handed out since the last minor collection.
    nursery: std.ArrayList(u32) = .empty,
    nursery_budget: usize = 0,
    nursery_limit: usize = default_nursery_segments,
    young_large: std.ArrayList(u32) = .empty,

    /// Per size class: its blocks, and where allocation looks first.
    blocks: [size_classes.len]std.ArrayList(u32) = @splat(.empty),
    block_cursor: [size_classes.len]usize = @splat(0),

    next_major: usize = min_major_bytes,
    stats: Stats = .{},

    roots: std.ArrayList([]Value) = .empty,
    /// Objects that live forever (interned symbols and keywords, vars): old, never
    /// moved, and always marked.
    permanent: std.ArrayList(*Header) = .empty,
    remembered: std.ArrayList(*Header) = .empty,

    mutators: ?*Mutator = null,
    /// Objects with a finalizer, which runs when a collection finds the object dead.
    finalizable: std.ArrayList(Finalizable) = .empty,
    // Collection work lists.
    worklist: std.ArrayList(*Header) = .empty,
    pinned: std.ArrayList(*Header) = .empty,
};

/// An object and the function to run when it dies (with the world stopped: it must not
/// touch the heap; it may read the dead object's payload).
pub const Finalizable = struct { h: *Header, f: *const fn (*Header) void };

var state: State = .{};
/// Guards the mutator list, segment allocation and stopping the world. Held for the
/// whole of a collection.
var world: platform.Mutex = .{};
var world_cond: platform.Condition = .{};
var barrier_lock: platform.Mutex = .{};
var initialized = false;

/// Set while a collection is wanted; threads poll it at safepoints. Compiled code reads
/// it as `sk_gc_pending`.
pub export var sk_gc_pending: u8 = 0;

/// How many collections have finished. Objects move only during collections, so a table
/// keyed by object addresses is valid while this stays the same (compiler.zig).
pub var epoch = std.atomic.Value(u64).init(0);

/// SKEIN_GC_VERIFY=1 (D-073): every collection is major, the nursery is one segment, and
/// after each collection every root, permanent object, live heap object and runtime
/// table (`verify_tables`) is checked for pointers to objects that are gone.
var verify_mode = false;

/// Checks the runtime's own tables and globals with the function it's given (verify.zig).
pub var verify_tables: ?*const fn (*const fn (Value, []const u8) void) void = null;

threadlocal var current: ?*Mutator = null;

fn fatal(comptime msg: []const u8) noreturn {
    platform.writeStderr("error: " ++ msg ++ "\n");
    std.process.exit(1);
}

fn listAppend(comptime T: type, list: *std.ArrayList(T), item: T) void {
    list.append(meta_alloc, item) catch fatal("out of memory (GC metadata)");
}

fn ensureInit() void {
    if (initialized) return;
    const memory = platform.reserve(arena_size) catch fatal("cannot reserve the heap arena");
    state.base = @intFromPtr(memory.ptr);
    // The arena's start must be segment-aligned for address arithmetic; reservations
    // are page-aligned, so round up and waste the first partial segment.
    state.base = std.mem.alignForward(usize, state.base, segment_size);
    state.segments = meta_alloc.alloc(Segment, max_segments - 1) catch fatal("out of memory");
    @memset(state.segments, .{});
    state.free_map = meta_alloc.alloc(u64, (max_segments + 63) / 64) catch fatal("out of memory");
    @memset(state.free_map, 0);
    if (std.c.getenv("SKEIN_GC_VERIFY")) |text| {
        if (!std.mem.eql(u8, std.mem.span(text), "0")) {
            verify_mode = true;
            state.nursery_limit = 1;
        }
    }
    if (std.c.getenv("SKEIN_NURSERY_SEGMENTS")) |text| {
        state.nursery_limit = std.fmt.parseInt(usize, std.mem.span(text), 10) catch state.nursery_limit;
    }
    initialized = true;
}

fn segmentStart(i: usize) usize {
    return state.base + i * segment_size;
}

fn segmentSlice(i: usize, n: usize) []align(platform.page_size_min) u8 {
    const start: [*]align(platform.page_size_min) u8 = @ptrFromInt(segmentStart(i));
    return start[0 .. n * segment_size];
}

fn isFreeSeg(i: usize) bool {
    return i >= state.high_water or (state.free_map[i / 64] >> @intCast(i % 64)) & 1 == 1;
}

/// Take `n` contiguous free segments, committed and zeroed. Caller holds `world`.
fn acquireSegments(n: usize, kind: Kind) u32 {
    var start: usize = 0;
    var run: usize = 0;
    var found: ?usize = null;
    var i: usize = 0;
    while (i < state.high_water) : (i += 1) {
        if (isFreeSeg(i)) {
            if (run == 0) start = i;
            run += 1;
            if (run == n) {
                found = start;
                break;
            }
        } else run = 0;
    }
    const first = found orelse blk: {
        const s = if (run > 0) start else state.high_water;
        if (s + n > state.segments.len) fatal("out of memory (the heap arena is full)");
        state.high_water = s + n;
        break :blk s;
    };
    for (first..first + n) |j| state.free_map[j / 64] &= ~(@as(u64, 1) << @intCast(j % 64));
    platform.commit(segmentSlice(first, n)) catch fatal("out of memory");
    state.stats.committed_segments += n;
    state.segments[first] = .{ .kind = kind };
    if (kind == .large_head) {
        state.segments[first].run = @intCast(n);
        for (first + 1..first + n) |j| state.segments[j] = .{ .kind = .large_tail, .run = @intCast(first) };
    }
    return @intCast(first);
}

fn releaseSegments(first: usize, n: usize) void {
    platform.decommit(segmentSlice(first, n));
    state.stats.committed_segments -= n;
    for (first..first + n) |j| {
        if (state.segments[j].bits) |b| listAppend(*Bitmap, &state.spare_bitmaps, b);
        state.segments[j] = .{};
        state.free_map[j / 64] |= @as(u64, 1) << @intCast(j % 64);
    }
}

fn newBitmap() *Bitmap {
    const b = state.spare_bitmaps.pop() orelse
        (meta_alloc.create(Bitmap) catch fatal("out of memory"));
    @memset(b, 0);
    return b;
}

fn segmentIndex(address: usize) ?usize {
    if (address < state.base) return null;
    const i = (address - state.base) / segment_size;
    return if (i < state.high_water) i else null;
}

fn segmentOf(h: *Header) *Segment {
    return &state.segments[segmentIndex(@intFromPtr(h)).?];
}

fn setStart(bits: *Bitmap, word: usize) void {
    bits[word / 64] |= @as(u64, 1) << @intCast(word % 64);
}

/// The object that `address` points into (anywhere inside it), or null.
pub fn findObject(address: usize) ?*Header {
    const i = segmentIndex(address) orelse return null;
    const seg = &state.segments[i];
    const start = segmentStart(i);
    switch (seg.kind) {
        .free => return null,
        .nursery, .pinned => {
            const bits = seg.bits orelse return null;
            var word = (address - start) / 8;
            // The nearest object start at or before `word`.
            var k = word / 64;
            var mask: u64 = if (word % 64 == 63) ~@as(u64, 0) else (@as(u64, 1) << @intCast(word % 64 + 1)) - 1;
            while (true) {
                const set = bits[k] & mask;
                if (set != 0) {
                    word = k * 64 + 63 - @clz(set);
                    break;
                }
                if (k == 0) return null;
                k -= 1;
                mask = ~@as(u64, 0);
            }
            const h: *Header = @ptrFromInt(start + word * 8);
            return if (address < @intFromPtr(h) + h.size()) h else null;
        },
        .small => {
            const cell_bytes = @as(usize, size_classes[seg.class]) * 8;
            const cell = (address - start) / cell_bytes;
            if (cell >= seg.bump) return null;
            const h: *Header = @ptrFromInt(start + cell * cell_bytes);
            if (h.type_id == .invalid) return null; // a free cell
            return if (address < @intFromPtr(h) + h.size()) h else null;
        },
        .large_head, .large_tail => {
            const head = if (seg.kind == .large_head) i else seg.run;
            const h: *Header = @ptrFromInt(segmentStart(head));
            return if (address < @intFromPtr(h) + h.size()) h else null;
        },
    }
}

fn isYoung(h: *Header) bool {
    const seg = segmentOf(h);
    return seg.kind == .nursery or ((seg.kind == .large_head) and seg.young);
}

// ---------------------------------------------------------------------------------------
// Threads

/// Register the calling thread as a mutator (done automatically on first allocation).
/// A thread must call `detachThread` before it exits.
pub fn attachThread() *Mutator {
    if (current) |m| return m;
    world.lock();
    defer world.unlock();
    ensureInit();
    // Don't join a collection in progress: wait until it's done.
    while (sk_gc_pending != 0) world_cond.wait(&world);
    const m = meta_alloc.create(Mutator) catch fatal("out of memory");
    m.* = .{ .stack_high = platform.currentStackBounds().high, .next = state.mutators };
    state.mutators = m;
    current = m;
    return m;
}

/// A number identifying the calling thread while it is attached (it owns transients).
pub fn currentThreadId() usize {
    return @intFromPtr(attachThread()) >> 3;
}

/// Unregister the calling thread. Its objects stay alive if something references them.
pub fn detachThread() void {
    const m = current orelse return;
    world.lock();
    defer world.unlock();
    // No waiting for a pending collection here: this thread won't touch the heap again,
    // so it simply leaves, and the collector (waiting for threads to stop) is told.
    defer world_cond.broadcast();
    var link = &state.mutators;
    while (link.*) |node| : (link = &node.next) {
        if (node == m) {
            link.* = node.next;
            break;
        }
    }
    meta_alloc.destroy(m);
    current = null;
}

extern fn sk_spill_registers_and_call(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;

const ParkRequest = struct { m: *Mutator, kind: ?CollectionKind };

/// Stop at a safepoint if a collection is pending.
pub fn safepoint() void {
    if (@atomicLoad(u8, &sk_gc_pending, .acquire) == 0) return;
    const m = current orelse return;
    var req: ParkRequest = .{ .m = m, .kind = null };
    sk_spill_registers_and_call(parkOrCollect, &req);
}

pub const CollectionKind = enum { minor, major };

/// Collect now (stopping the world). A major collection also does a minor one.
pub fn collect(kind: CollectionKind) void {
    const m = attachThread();
    var req: ParkRequest = .{ .m = m, .kind = kind };
    sk_spill_registers_and_call(parkOrCollect, &req);
}

/// Called with the registers spilled: park until the pending collection is done, or
/// (if `kind` is set and none is pending) run one.
fn parkOrCollect(arg: ?*anyopaque) callconv(.c) void {
    const req: *ParkRequest = @ptrCast(@alignCast(arg));
    var marker: usize = 0;
    std.mem.doNotOptimizeAway(&marker);
    const m = req.m;
    world.lock();
    defer world.unlock();
    m.saved_sp = @intFromPtr(&marker);
    if (sk_gc_pending != 0 or req.kind == null) {
        // Someone else is collecting: wait for them.
        m.state = .parked;
        world_cond.broadcast();
        while (sk_gc_pending != 0) world_cond.wait(&world);
        m.state = .running;
        return;
    }
    @atomicStore(u8, &sk_gc_pending, 1, .release);
    m.state = .parked;
    // Wait until every other thread is parked or in a blocking call.
    while (!allStopped(m)) world_cond.wait(&world);
    const started = platform.monotonicNanos();
    if (req.kind.? == .major or verify_mode) major() else minor();
    if (verify_mode) verify();
    const pause = platform.monotonicNanos() - started;
    state.stats.pause_ns_total += pause;
    state.stats.pause_ns_max = @max(state.stats.pause_ns_max, pause);
    _ = epoch.fetchAdd(1, .release);
    @atomicStore(u8, &sk_gc_pending, 0, .release);
    m.state = .running;
    world_cond.broadcast();
}

fn allStopped(self: *Mutator) bool {
    var it = state.mutators;
    while (it) |m| : (it = m.next) {
        if (m != self and m.state == .running) return false;
    }
    return true;
}

const BlockingCall = struct {
    m: *Mutator,
    f: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
};

/// Run `f(arg)` as a blocking call: collections can happen meanwhile, so `f` must not
/// touch the heap. The registers are spilled first, so heap pointers that only the
/// caller holds stay visible to the collector.
pub fn blocking(f: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
    const m = attachThread();
    var call: BlockingCall = .{ .m = m, .f = f, .arg = arg };
    sk_spill_registers_and_call(blockingInner, &call);
}

fn blockingInner(arg: ?*anyopaque) callconv(.c) void {
    const call: *BlockingCall = @ptrCast(@alignCast(arg));
    var marker: usize = 0;
    std.mem.doNotOptimizeAway(&marker);
    world.lock();
    call.m.saved_sp = @intFromPtr(&marker);
    call.m.state = .native;
    world_cond.broadcast();
    world.unlock();
    call.f(call.arg);
    world.lock();
    while (sk_gc_pending != 0) world_cond.wait(&world);
    call.m.state = .running;
    world.unlock();
}

/// How a thread was when C called Skein (a callback, M1.10): what `leaveToC` restores.
pub const Entry = enum { running, native, attached };

/// Make the calling thread a running mutator for a callback from C. It may already be
/// running (C called from Skein without ^:blocking), in a blocking call (collections go
/// on without it, so it waits for any to finish), or a thread the runtime doesn't know.
pub fn enterFromC() Entry {
    const m = current orelse {
        _ = attachThread();
        return .attached;
    };
    if (m.state != .native) return .running;
    world.lock();
    defer world.unlock();
    while (sk_gc_pending != 0) world_cond.wait(&world);
    m.state = .running;
    return .native;
}

/// Undo `enterFromC` when the callback returns to C. A blocking call's thread goes back
/// to it: its stack above the saved position is still what the collector must scan. A
/// thread that wasn't the runtime's is detached, since it may exit while in C.
pub fn leaveToC(e: Entry) void {
    switch (e) {
        .running => {},
        .attached => detachThread(),
        .native => {
            world.lock();
            defer world.unlock();
            current.?.state = .native;
            world_cond.broadcast();
        },
    }
}

// ---------------------------------------------------------------------------------------
// Roots and the write barrier

/// Make the values in `slots` roots: they keep their objects alive, and the collector
/// updates them when objects move. The slots must stay valid.
pub fn addRoots(slots: []Value) void {
    world.lock();
    defer world.unlock();
    ensureInit();
    listAppend([]Value, &state.roots, slots);
}

/// Run `f` on `h` when a collection finds `h` dead (owned C pointers, M1.10, D-065). `f`
/// runs with the world stopped and must not touch the heap.
pub fn addFinalizer(h: *Header, f: *const fn (*Header) void) void {
    world.lock();
    defer world.unlock();
    listAppend(Finalizable, &state.finalizable, .{ .h = h, .f = f });
}

/// After a minor collection's tracing: follow young finalizable objects that moved, and
/// finalize those that died. Old ones survive a minor collection.
fn finalizeMinor() void {
    var i: usize = 0;
    while (i < state.finalizable.items.len) {
        const e = &state.finalizable.items[i];
        const h = e.h;
        if (!isYoung(h)) {
            i += 1;
            continue;
        }
        const seg = segmentOf(h);
        const alive = switch (seg.kind) {
            .nursery => h.gc.forwarded or h.gc.pinned,
            .large_head => seg.reached,
            else => true,
        };
        if (!alive) {
            e.f(h);
            _ = state.finalizable.swapRemove(i);
            continue;
        }
        if (h.gc.forwarded) e.h = @ptrFromInt(h.payload()[0]);
        i += 1;
    }
}

/// After a major collection's marking: finalize the objects left unmarked.
fn finalizeMajor() void {
    var i: usize = 0;
    while (i < state.finalizable.items.len) {
        const e = state.finalizable.items[i];
        if (e.h.gc.marked) {
            i += 1;
        } else {
            e.f(e.h);
            _ = state.finalizable.swapRemove(i);
        }
    }
}

/// Remove roots added with `addRoots`.
pub fn removeRoots(slots: []Value) void {
    world.lock();
    defer world.unlock();
    for (state.roots.items, 0..) |r, i| {
        if (r.ptr == slots.ptr) {
            _ = state.roots.swapRemove(i);
            return;
        }
    }
}

/// Store `v` into the value slot `slot` of the object `obj`, recording old-to-young
/// pointers for the next minor collection.
pub fn store(obj: *Header, slot: *Value, v: Value) void {
    slot.* = v;
    barrier(obj, v);
}

/// The write barrier alone, for a slot that was already set (atomically) to `v`.
pub fn barrier(obj: *Header, v: Value) void {
    if (obj.gc.old and !obj.gc.remembered and v.isObject() and isYoung(v.toObject())) {
        barrier_lock.lock();
        defer barrier_lock.unlock();
        if (!obj.gc.remembered) {
            obj.gc.remembered = true;
            listAppend(*Header, &state.remembered, obj);
        }
    }
}

// ---------------------------------------------------------------------------------------
// Allocation

/// Allocate an object of `type_id` with `len` zeroed payload words.
pub fn alloc(type_id: object.TypeId, len: usize) *Header {
    if (len > object.max_len) fatal("out of memory (object too large)");
    // At least one payload word, for the forwarding address.
    const payload = @max(len, 1);
    const words = 1 + payload;
    const m = current orelse attachThread();
    const address = if (words >= large_words)
        allocLarge(m, words)
    else blk: {
        if (m.limit - m.cursor < words * 8) refill(m, words);
        const a = m.cursor;
        m.cursor += words * 8;
        const i = (a - state.base) / segment_size;
        setStart(state.segments[i].bits.?, (a - segmentStart(i)) / 8);
        break :blk a;
    };
    const h: *Header = @ptrFromInt(address);
    h.* = Header.init(type_id, @intCast(payload));
    return h;
}

/// Give `m` a fresh nursery segment, collecting first if the nursery is used up.
fn refill(m: *Mutator, words: usize) void {
    _ = words;
    safepoint();
    if (state.nursery_budget >= state.nursery_limit) {
        collect(if (state.stats.old_bytes >= state.next_major) .major else .minor);
    }
    world.lock();
    defer world.unlock();
    const i = acquireSegments(1, .nursery);
    state.segments[i].bits = newBitmap();
    listAppend(u32, &state.nursery, i);
    state.nursery_budget += 1;
    m.cursor = segmentStart(i);
    m.limit = m.cursor + segment_size;
}

fn allocLarge(m: *Mutator, words: usize) usize {
    _ = m;
    safepoint();
    const n = (words * 8 + segment_size - 1) / segment_size;
    if (state.nursery_budget + n > state.nursery_limit) {
        collect(if (state.stats.old_bytes >= state.next_major) .major else .minor);
    }
    world.lock();
    defer world.unlock();
    const i = acquireSegments(n, .large_head);
    state.segments[i].young = true;
    listAppend(u32, &state.young_large, i);
    state.nursery_budget += n;
    return segmentStart(i);
}

/// Allocate `words` (header included) in the old generation; collector only.
fn allocOld(words: usize) *Header {
    const class = classFor(words);
    const cell_words: usize = size_classes[class];
    const blocks = &state.blocks[class];
    while (state.block_cursor[class] < blocks.items.len) : (state.block_cursor[class] += 1) {
        const i = blocks.items[state.block_cursor[class]];
        const seg = &state.segments[i];
        if (seg.free_list != 0) {
            // Free cells are zero apart from their link in word 1.
            const cell: [*]u64 = @ptrFromInt(seg.free_list);
            seg.free_list = cell[1];
            cell[1] = 0;
            return @ptrCast(cell);
        }
        if (seg.bump < seg.cells) {
            const h: *Header = @ptrFromInt(segmentStart(i) + seg.bump * cell_words * 8);
            seg.bump += 1;
            return h;
        }
    }
    const i = acquireSegments(1, .small);
    const seg = &state.segments[i];
    seg.class = class;
    seg.cells = @intCast(segment_words / cell_words);
    seg.bump = 1;
    listAppend(u32, blocks, i);
    return @ptrFromInt(segmentStart(i));
}

/// Allocate an object that is never freed or moved (interned symbols and keywords, vars,
/// namespaces). Its value slots must be written with `store`, like any old object's.
pub fn allocPermanent(type_id: object.TypeId, len: usize) *Header {
    const payload = @max(len, 1);
    world.lock();
    defer world.unlock();
    ensureInit();
    // Don't allocate in the middle of a collection.
    while (sk_gc_pending != 0) world_cond.wait(&world);
    const h = if (1 + payload >= large_words) blk: {
        const n = ((1 + payload) * 8 + segment_size - 1) / segment_size;
        break :blk @as(*Header, @ptrFromInt(segmentStart(acquireSegments(n, .large_head))));
    } else allocOld(1 + payload);
    h.* = Header.init(type_id, @intCast(payload));
    h.gc.old = true;
    listAppend(*Header, &state.permanent, h);
    return h;
}

// ---------------------------------------------------------------------------------------
// Minor collection

/// Calls its argument with the [low, high) range of every suspended fiber's stack
/// (fiber.zig, M2.2): the collector scans them like the running ones.
pub var scan_suspended_fibers: ?*const fn (*const fn (usize, usize) void) void = null;

/// Set the top of the stack the calling thread runs on: a fiber switch changes it.
pub fn setStackHigh(high: usize) void {
    if (current) |m| m.stack_high = high;
}

fn rangeVisitor(comptime visit: fn (usize) void) fn (usize, usize) void {
    return struct {
        fn f(low: usize, high: usize) void {
            var p = std.mem.alignForward(usize, low, 8);
            while (p + 8 <= high) : (p += 8) visit(@as(*const usize, @ptrFromInt(p)).*);
        }
    }.f;
}

fn scanStacks(comptime visit: fn (usize) void) void {
    if (scan_suspended_fibers) |f| f(&rangeVisitor(visit));
    var it = state.mutators;
    while (it) |m| : (it = m.next) {
        var p = std.mem.alignForward(usize, m.saved_sp, 8);
        while (p + 8 <= m.stack_high) : (p += 8) {
            visit(@as(*const usize, @ptrFromInt(p)).*);
        }
    }
}

fn pinIfYoung(word: usize) void {
    const h = findObject(word) orelse return;
    const seg = segmentOf(h);
    switch (seg.kind) {
        .nursery => if (!h.gc.pinned) {
            h.gc.pinned = true;
            seg.has_pins = true;
            listAppend(*Header, &state.pinned, h);
        },
        .large_head => if (seg.young and !seg.reached) {
            seg.reached = true;
            listAppend(*Header, &state.worklist, h);
        },
        else => {},
    }
}

/// The new location of the object `v` refers to, copying it out of the nursery if needed.
fn evacuate(v: Value) Value {
    if (!v.isObject()) return v;
    const h = v.toObject();
    const seg = segmentOf(h);
    switch (seg.kind) {
        .nursery => {
            if (h.gc.forwarded) return Value.fromObject(@ptrFromInt(h.payload()[0]));
            if (h.gc.pinned) return v;
            const words = h.size() / 8;
            const copy = allocOld(words);
            const src: [*]const u64 = @ptrCast(h);
            const dst: [*]u64 = @ptrCast(copy);
            @memcpy(dst[0..words], src[0..words]);
            copy.gc = .{ .old = true };
            h.gc.forwarded = true;
            h.payload()[0] = @intFromPtr(copy);
            state.stats.bytes_promoted += words * 8;
            state.stats.old_bytes += @as(usize, size_classes[classFor(words)]) * 8;
            listAppend(*Header, &state.worklist, copy);
            return Value.fromObject(copy);
        },
        .large_head => {
            if (seg.young and !seg.reached) {
                seg.reached = true;
                listAppend(*Header, &state.worklist, h);
            }
            return v;
        },
        else => return v,
    }
}

fn scanChildrenMinor(h: *Header) void {
    for (h.valueSlots()) |*slot| slot.* = evacuate(slot.*);
}

fn minor() void {
    state.stats.minor_collections += 1;
    var it = state.mutators;
    while (it) |m| : (it = m.next) {
        m.cursor = 0;
        m.limit = 0;
    }
    // Conservative roots: whatever the stacks may point at stays put.
    scanStacks(pinIfYoung);
    // Precise roots.
    for (state.roots.items) |slots| {
        for (slots) |*slot| slot.* = evacuate(slot.*);
    }
    for (state.remembered.items) |h| scanChildrenMinor(h);
    for (state.pinned.items) |h| scanChildrenMinor(h);
    while (state.worklist.pop()) |h| scanChildrenMinor(h);
    finalizeMinor();

    // Promote segments with pinned objects, keeping only those objects; free the rest.
    for (state.nursery.items) |i| {
        const seg = &state.segments[i];
        if (seg.has_pins) @memset(seg.bits.?, 0);
    }
    for (state.pinned.items) |h| {
        const i = segmentIndex(@intFromPtr(h)).?;
        setStart(state.segments[i].bits.?, (@intFromPtr(h) - segmentStart(i)) / 8);
        h.gc.pinned = false;
        h.gc.old = true;
    }
    for (state.nursery.items) |i| {
        const seg = &state.segments[i];
        if (seg.has_pins) {
            seg.kind = .pinned;
            seg.has_pins = false;
            state.stats.old_bytes += segment_size;
        } else releaseSegments(i, 1);
    }
    for (state.young_large.items) |i| {
        const seg = &state.segments[i];
        if (seg.reached) {
            seg.reached = false;
            seg.young = false;
            const h: *Header = @ptrFromInt(segmentStart(i));
            h.gc.old = true;
            state.stats.old_bytes += @as(usize, seg.run) * segment_size;
        } else releaseSegments(i, seg.run);
    }
    for (state.remembered.items) |h| h.gc.remembered = false;
    state.remembered.clearRetainingCapacity();
    state.pinned.clearRetainingCapacity();
    state.nursery.clearRetainingCapacity();
    state.young_large.clearRetainingCapacity();
    state.nursery_budget = 0;
}

// ---------------------------------------------------------------------------------------
// Major collection

fn mark(h: *Header) void {
    if (h.gc.marked) return;
    h.gc.marked = true;
    listAppend(*Header, &state.worklist, h);
}

fn markConservative(word: usize) void {
    if (findObject(word)) |h| mark(h);
}

fn major() void {
    minor(); // now every live object is old
    state.stats.major_collections += 1;
    scanStacks(markConservative);
    for (state.permanent.items) |h| mark(h);
    for (state.roots.items) |slots| {
        for (slots) |v| if (v.isObject()) mark(v.toObject());
    }
    while (state.worklist.pop()) |h| {
        for (h.valueSlots()) |v| if (v.isObject()) mark(v.toObject());
    }
    finalizeMajor();
    sweep();
}

fn sweep() void {
    var live: usize = 0;
    var i: usize = 0;
    while (i < state.high_water) : (i += 1) {
        const seg = &state.segments[i];
        switch (seg.kind) {
            .small => {
                const cell_words: usize = size_classes[seg.class];
                var used: usize = 0;
                seg.free_list = 0;
                var c: usize = seg.bump;
                while (c > 0) {
                    c -= 1;
                    const h: *Header = @ptrFromInt(segmentStart(i) + c * cell_words * 8);
                    if (h.type_id != .invalid and h.gc.marked) {
                        h.gc.marked = false;
                        used += 1;
                    } else {
                        // Free (or already free): clear it and thread it on the list.
                        const words: [*]u64 = @ptrCast(h);
                        @memset(words[0..cell_words], 0);
                        words[1] = seg.free_list;
                        seg.free_list = @intFromPtr(h);
                    }
                }
                if (used == 0) {
                    removeBlock(seg.class, @intCast(i));
                    releaseSegments(i, 1);
                } else live += used * cell_words * 8;
            },
            .pinned => {
                const bits = seg.bits.?;
                var any = false;
                for (bits, 0..) |*w, k| {
                    var set = w.*;
                    while (set != 0) {
                        const bit: u6 = @intCast(@ctz(set));
                        set &= set - 1;
                        const h: *Header = @ptrFromInt(segmentStart(i) + (k * 64 + bit) * 8);
                        if (h.gc.marked) {
                            h.gc.marked = false;
                            any = true;
                        } else w.* &= ~(@as(u64, 1) << bit);
                    }
                }
                if (any) live += segment_size else releaseSegments(i, 1);
            },
            .large_head => {
                const h: *Header = @ptrFromInt(segmentStart(i));
                const n = seg.run;
                if (h.gc.marked) {
                    h.gc.marked = false;
                    live += @as(usize, n) * segment_size;
                } else releaseSegments(i, n);
                i += n - 1;
            },
            else => {},
        }
    }
    for (&state.block_cursor) |*c| c.* = 0;
    state.stats.old_bytes = live;
    state.next_major = @max(min_major_bytes, live * 2);
}

// ---------------------------------------------------------------------------------------
// Verification (SKEIN_GC_VERIFY=1)

/// Stop the program if `v` points at something that isn't a live object: a freed cell or
/// segment, or the middle of an object. After a major collection nothing is young.
fn verifyValue(v: Value, where: []const u8) void {
    if (!v.isObject()) return;
    const a = @intFromPtr(v.toObject());
    const ok = if (findObject(a)) |h| @intFromPtr(h) == a and h.type_id != .invalid and !isYoung(h) else false;
    if (ok) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: SKEIN_GC_VERIFY: {s} holds 0x{x}, which isn't a live object\n", .{ where, a }) catch "error: SKEIN_GC_VERIFY failed\n";
    platform.writeStderr(msg);
    std.process.exit(70);
}

fn verifyObject(h: *Header, where: []const u8) void {
    for (h.valueSlots()) |v| verifyValue(v, where);
}

/// Check every root, permanent object, live heap object and runtime table, with the world
/// stopped after a major collection.
fn verify() void {
    for (state.roots.items) |slots| {
        for (slots) |v| verifyValue(v, "a root");
    }
    for (state.permanent.items) |h| verifyObject(h, "a permanent object");
    var i: usize = 0;
    while (i < state.high_water) : (i += 1) {
        const seg = &state.segments[i];
        switch (seg.kind) {
            .small => {
                const cell_words: usize = size_classes[seg.class];
                for (0..seg.bump) |c| {
                    const h: *Header = @ptrFromInt(segmentStart(i) + c * cell_words * 8);
                    if (h.type_id != .invalid) verifyObject(h, "a heap object");
                }
            },
            .pinned => {
                for (seg.bits.?, 0..) |w, k| {
                    var set = w;
                    while (set != 0) : (set &= set - 1) {
                        const bit: usize = @ctz(set);
                        verifyObject(@ptrFromInt(segmentStart(i) + (k * 64 + bit) * 8), "a heap object");
                    }
                }
            },
            .large_head => verifyObject(@ptrFromInt(segmentStart(i)), "a large object"),
            else => {},
        }
    }
    if (verify_tables) |f| f(verifyValue);
}

fn removeBlock(class: u8, i: u32) void {
    const blocks = &state.blocks[class];
    for (blocks.items, 0..) |b, k| {
        if (b == i) {
            _ = blocks.orderedRemove(k);
            return;
        }
    }
}

// ---------------------------------------------------------------------------------------
// Statistics

pub fn stats() Stats {
    world.lock();
    defer world.unlock();
    return state.stats;
}

/// Print statistics to standard error (`SKEIN_GC_STATS=1` does this at exit).
pub fn printStats() void {
    const s = stats();
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "gc: {d} minor, {d} major, pauses {d} us total, {d} us max, " ++
        "{d} KiB promoted, {d} KiB old, {d} segments committed\n", .{
        s.minor_collections,   s.major_collections,       s.pause_ns_total / 1000,
        s.pause_ns_max / 1000, s.bytes_promoted / 1024, s.old_bytes / 1024,
        s.committed_segments,
    }) catch return;
    platform.writeStderr(text);
}
