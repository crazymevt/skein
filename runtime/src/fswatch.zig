//! Watching a directory tree for changes (M3.5, D-107). The platform's watcher (FSEvents,
//! inotify or ReadDirectoryChangesW, in platform.zig) reports changes on a thread of its
//! own into a queue here; skein.io's watch takes them a batch at a time, in a fiber, and
//! filters them by Git's ignore rules. Watchers are small integers naming entries of a
//! table.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const sched = @import("sched.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const coll = @import("coll.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

const Event = struct { kind: platform.WatchKind, path: []u8 };

const Queue = struct {
    lock: platform.Mutex = .{},
    cond: platform.Condition = .{},
    events: std.ArrayList(Event) = .empty,
    watch: ?*platform.Watch = null,
    stopped: bool = false,

    fn report(context: *anyopaque, kind: platform.WatchKind, relative: []const u8) void {
        const q: *Queue = @ptrCast(@alignCast(context));
        const path = alloc.dupe(u8, relative) catch return;
        q.lock.lock();
        defer q.lock.unlock();
        q.events.append(alloc, .{ .kind = kind, .path = path }) catch alloc.free(path);
        q.cond.signal();
    }
};

var lock: platform.Mutex = .{};
var table: std.ArrayList(?*Queue) = .empty;

fn queueOf(h: Value) *Queue {
    lock.lock();
    var found: ?*Queue = null;
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= table.items.len)
        found = table.items[@intCast(h.toFixnum() - 1)];
    lock.unlock();
    return found orelse rt.raise(.@"error", "no such watcher", .{});
}

const StartCall = struct { root: [:0]const u8, q: *Queue };

fn startBlocking(arg: ?*anyopaque) void {
    const c: *StartCall = @ptrCast(@alignCast(arg));
    c.q.watch = platform.startWatch(c.root, .{ .context = c.q, .report = Queue.report });
}

/// (%fswatch-start root): a watcher of the directory tree at root, or nil if it can't be
/// watched.
fn start(root: Value) Value {
    if (!string.isString(root)) rt.raise(.type_error, "watch needs a directory's path", .{});
    const r = alloc.dupeSentinel(u8, string.bytes(root), 0) catch rt.fatal("out of memory", .{});
    defer alloc.free(r);
    const q = alloc.create(Queue) catch rt.fatal("out of memory", .{});
    q.* = .{};
    var call: StartCall = .{ .root = r, .q = q };
    io.pathBlocking(startBlocking, &call);
    if (q.watch == null) {
        alloc.destroy(q);
        return Value.nil;
    }
    lock.lock();
    defer lock.unlock();
    table.append(alloc, q) catch rt.fatal("out of memory", .{});
    return Value.fromFixnum(@intCast(table.items.len));
}

const NextCall = struct { q: *Queue, nanos: u64, events: std.ArrayList(Event) = .empty, stopped: bool = false };

fn nextBlocking(arg: ?*anyopaque) void {
    const c: *NextCall = @ptrCast(@alignCast(arg));
    const q = c.q;
    q.lock.lock();
    defer q.lock.unlock();
    const deadline = platform.monotonicNanos() +| c.nanos;
    while (q.events.items.len == 0 and !q.stopped) {
        if (c.nanos == 0) {
            q.cond.wait(&q.lock);
            continue;
        }
        const now = platform.monotonicNanos();
        if (now >= deadline) break;
        q.cond.timedWait(&q.lock, deadline - now);
    }
    c.events = q.events;
    q.events = .empty;
    c.stopped = q.stopped and c.events.items.len == 0;
}

fn kindKeyword(kind: platform.WatchKind) Value {
    return names.keyword(null, switch (kind) {
        .created => "created",
        .modified => "modified",
        .deleted => "deleted",
        .rescan => "rescan",
    });
}

/// (%fswatch-next watcher nanos): the changes since the last call, as a vector of
/// [kind relative-path], waiting for one up to nanos (0: as long as it takes; an empty
/// vector if none came); nil once the watcher is stopped and has none left.
fn next(h: Value, nanos: Value) Value {
    const n: u64 = if (nanos.isFixnum() and nanos.toFixnum() > 0) @intCast(nanos.toFixnum()) else 0;
    var call: NextCall = .{ .q = queueOf(h), .nanos = n };
    sched.blocking(nextBlocking, &call);
    defer {
        for (call.events.items) |e| alloc.free(e.path);
        call.events.deinit(alloc);
    }
    if (call.stopped) return Value.nil;
    var v = coll.vectorOf(&.{});
    for (call.events.items) |e| {
        const path = string.make(e.path);
        v = coll.vectorConj(v, coll.vectorOf(&.{ kindKeyword(e.kind), path }));
    }
    return v;
}

fn stopBlocking(arg: ?*anyopaque) void {
    const q: *Queue = @ptrCast(@alignCast(arg));
    if (q.watch) |w| platform.stopWatch(w);
    q.lock.lock();
    q.watch = null;
    q.stopped = true;
    q.cond.broadcast();
    q.lock.unlock();
}

/// (%fswatch-stop watcher): stop it; what it reported can still be taken. Stopping it
/// again does nothing.
fn stop(h: Value) Value {
    const q = queueOf(h);
    q.lock.lock();
    const already = q.stopped;
    q.lock.unlock();
    if (!already) io.pathBlocking(stopBlocking, q);
    // The queue stays: a fiber may still be taking from it. It's small.
    return Value.nil;
}

const Args = []const Value;

pub const entries = [_]io.Entry{
    .{ .name = "%fswatch-start", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return start(a[0]);
        }
    }.f },
    .{ .name = "%fswatch-next", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return next(a[0], a[1]);
        }
    }.f },
    .{ .name = "%fswatch-stop", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return stop(a[0]);
        }
    }.f },
};
