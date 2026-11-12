//! skein.process's primitives natively (M3.1, D-103): programs started without waiting for
//! them, their standard streams as skein.io streams over pipes (files.zig), and a reaper
//! thread per program that waits for it to end and wakes the fibers waiting for it
//! (tasks.zig). lib/skein/process.skn wraps these.
//!
//! A process is a handle (a fixnum) into a table kept outside the heap, as a stream is. On
//! Windows a program starts in a job object of its own, which holds what it starts; on
//! Unix, destroy-tree! walks the process table for its descendants (platform).

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const print = @import("print.zig");
const seq = @import("seq.zig");
const string = @import("string.zig");
const io = @import("io.zig");
const files = @import("files.zig");
const tasks = @import("tasks.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

/// A copy of the string `v` outside the heap.
fn copyString(v: Value, comptime what: []const u8) []u8 {
    if (!string.isString(v)) rt.raise(.type_error, what ++ ", not {s}", .{readable(v)});
    return alloc.dupe(u8, string.bytes(v)) catch rt.fatal("out of memory", .{});
}

// ---------------------------------------------------------------------------------------
// The table

const running = std.math.minInt(i64);

const Proc = struct {
    child: std.process.Child,
    pid: i64,
    /// The exit status, or the number of the signal that ended it (as run-process reports
    /// it); `running` until the reaper sees it end.
    exit: std.atomic.Value(i64) = std.atomic.Value(i64).init(running),
    /// The wait queue key (tasks.zig) of the fibers waiting for it to end.
    key: u64,
    /// The job object it runs in, and a handle to signal it with, on Windows. Both stay
    /// open after it ends, so that destroy-tree! can still reach what it started.
    job: ?*anyopaque = null,
    handle: ?*anyopaque = null,
    /// Unused: programs stay in this program's process group (D-103's step 3).
    own_group: bool = false,
    /// Whether its stdin pipe has been released, once it was seen to end.
    stdin_released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Its stdin, stdout and stderr as stream handles, or nil, and the streams' serial
    /// numbers (files.zig).
    streams: [3]Value = .{ Value.nil, Value.nil, Value.nil },
    serials: [3]u64 = .{ 0, 0, 0 },
};

var lock: platform.Mutex = .{};
var table: std.ArrayList(?*Proc) = .empty;
var serial = std.atomic.Value(u64).init(0);

fn procOf(h: Value) *Proc {
    lock.lock();
    var found: ?*Proc = null;
    if (h.isFixnum()) {
        const i = h.toFixnum();
        if (i >= 1 and i <= table.items.len) found = table.items[@intCast(i - 1)];
    }
    lock.unlock();
    return found orelse rt.raise(.type_error, "not a process: {s}", .{readable(h)});
}

fn register(p: *Proc) Value {
    lock.lock();
    defer lock.unlock();
    table.append(alloc, p) catch rt.fatal("out of memory", .{});
    return Value.fromFixnum(@intCast(table.items.len));
}

// ---------------------------------------------------------------------------------------
// Starting a program

/// How one of the program's standard streams is connected: a pipe, the parent's, nothing,
/// or a file, written from its start or appended to.
const Redirect = union(enum) { pipe, inherit, discard, file: []u8, append: []u8, merge };

fn redirectOf(v: Value, comptime which: []const u8) Redirect {
    if (string.isString(v)) return .{ .file = copyString(v, which ++ " must be a keyword or a file's path") };
    // [path true]: appended to.
    if (coll.isVector(v) and coll.vectorCount(v) == 2 and coll.vectorNth(v, 1).? == Value.true)
        return .{ .append = copyString(coll.vectorNth(v, 0).?, which ++ "'s file must be a path") };
    if (names.isKeyword(v) and names.nsOf(v) == null) {
        const n = names.nameOf(v);
        if (std.mem.eql(u8, n, "pipe")) return .pipe;
        if (std.mem.eql(u8, n, "inherit")) return .inherit;
        if (std.mem.eql(u8, n, "discard")) return .discard;
        // :err :out, the error output where the output goes.
        if (std.mem.eql(u8, which, ":err") and std.mem.eql(u8, n, "out")) return .merge;
    }
    rt.raise(.@"error", which ++ " must be :pipe, :inherit, :discard or a file's path, not {s}", .{readable(v)});
}

const StartCall = struct {
    argv: []const []const u8,
    dir: ?[]const u8,
    env: ?*const std.process.Environ.Map,
    redirects: [3]Redirect,
    child: ?std.process.Child = null,
    /// Why it couldn't be started, if it couldn't.
    failure: ?anyerror = null,
    /// Files opened for redirections, closed once the program has them.
    opened: [3]?std.Io.File = .{ null, null, null },
    /// With :err :out and a piped stdout: the read end of the pipe both go to.
    merged: ?std.Io.File = null,
};

fn startBlocking(arg: ?*anyopaque) void {
    const c: *StartCall = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const cwd = std.Io.Dir.cwd();
    var stdio: [3]std.process.SpawnOptions.StdIo = undefined;
    for (c.redirects, 0..) |r, i| {
        stdio[i] = switch (r) {
            .pipe => .pipe,
            .inherit => .inherit,
            .discard => .ignore,
            .file => |path| file: {
                const f = (if (i == 0)
                    cwd.openFile(sio, path, .{})
                else
                    cwd.createFile(sio, path, .{ .truncate = true })) catch |e| {
                    c.failure = e;
                    return closeOpened(c);
                };
                c.opened[i] = f;
                break :file .{ .file = f };
            },
            .append => |path| file: {
                const f = cwd.createFile(sio, path, .{ .truncate = false }) catch |e| {
                    c.failure = e;
                    return closeOpened(c);
                };
                // The program inherits the position, at the end.
                platform.seekToEnd(f.handle);
                c.opened[i] = f;
                break :file .{ .file = f };
            },
            // Settled below, once stdout's is.
            .merge => .inherit,
        };
    }
    if (c.redirects[2] == .merge) {
        if (c.redirects[1] == .pipe) {
            // One pipe for both, which Zig's spawn can't make.
            const p = platform.makePipe() orelse return closeOpened(c);
            c.merged = p[0];
            c.opened[1] = p[1];
            stdio[1] = .{ .file = p[1] };
        }
        stdio[2] = stdio[1];
    }
    var options: std.process.SpawnOptions = .{
        .argv = c.argv,
        .cwd = if (c.dir) |d| .{ .path = d } else .inherit,
        .environ_map = c.env,
        .stdin = stdio[0],
        .stdout = stdio[1],
        .stderr = stdio[2],
    };
    platform.processGroupOptions(&options, c.redirects[0] != .inherit);
    c.child = std.process.spawn(sio, options) catch |e| blk: {
        c.failure = e;
        break :blk null;
    };
    closeOpened(c);
    if (c.child == null) if (c.merged) |m| {
        m.close(sio);
        c.merged = null;
    };
}

fn closeOpened(c: *StartCall) void {
    for (&c.opened) |*f| if (f.*) |file| {
        file.close(io.stdIo());
        f.* = null;
    };
}

/// The environment `env` (a map of strings) as a std map, outside the heap.
fn environOf(env: Value) std.process.Environ.Map {
    if (!coll.isMap(env)) rt.raise(.type_error, "an environment must be a map of strings, not {s}", .{readable(env)});
    var map = std.process.Environ.Map.init(alloc);
    const Put = struct {
        fn f(m: *std.process.Environ.Map, k: Value, v: Value) bool {
            if (!string.isString(k) or !string.isString(v))
                rt.raise(.type_error, "an environment's names and values must be strings, not {s} {s}", .{ readable(k), readable(v) });
            m.put(string.bytes(k), string.bytes(v)) catch rt.fatal("out of memory", .{});
            return true;
        }
    };
    coll.mapEach(env, &map, Put.f);
    return map;
}

/// (%process-start argv dir env in out err): start the program, without a shell, found on
/// the PATH, in `dir` (nil: here) with the environment `env` (a map; nil: this program's),
/// its streams connected as in, out and err say. A process handle, or nil if it couldn't
/// be started: a string, the reason.
fn start(argv: Value, dir: Value, env: Value, in: Value, out: Value, err: Value) Value {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    var s = seq.seq(argv);
    while (s != Value.nil) : (s = seq.seqNext(s)) {
        args.append(alloc, copyString(seq.seqFirst(s), "a program and its arguments must be strings")) catch
            rt.fatal("out of memory", .{});
    }
    if (args.items.len == 0) rt.raise(.@"error", "a process needs a program to run", .{});
    const d: ?[]u8 = if (dir == Value.nil) null else copyString(dir, "a directory must be a path");
    defer if (d) |x| alloc.free(x);
    var map: ?std.process.Environ.Map = if (env == Value.nil) null else environOf(env);
    defer if (map) |*m| m.deinit();
    var call: StartCall = .{
        .argv = args.items,
        .dir = d,
        .env = if (map) |*m| m else null,
        .redirects = .{ redirectOf(in, ":in"), redirectOf(out, ":out"), redirectOf(err, ":err") },
    };
    defer for (call.redirects) |r| switch (r) {
        .file, .append => |path| alloc.free(path),
        else => {},
    };
    platform.prepareForProcesses();
    io.pathBlocking(startBlocking, &call);
    var child = call.child orelse
        return string.make(if (call.failure) |e| @errorName(e) else "unknown");
    const p = alloc.create(Proc) catch rt.fatal("out of memory", .{});
    p.* = .{ .child = child, .pid = platform.childProcessId(&child), .key = (6 << 40) | serial.fetchAdd(1, .monotonic) };
    p.job = platform.startedProcess(&p.child);
    p.handle = platform.childHandle(&p.child);
    // The streams own the pipes now: wait would close what it still holds.
    if (p.child.stdin) |f| p.streams[0], p.serials[0] = files.registerPipe(f);
    if (p.child.stdout) |f| p.streams[1], p.serials[1] = files.registerPipe(f);
    if (call.merged) |f| p.streams[1], p.serials[1] = files.registerPipe(f);
    if (p.child.stderr) |f| p.streams[2], p.serials[2] = files.registerPipe(f);
    p.child.stdin = null;
    p.child.stdout = null;
    p.child.stderr = null;
    // A detached thread of the platform's (Zig's Thread.detach panics on Linux when the
    // thread has already ended, as a reaper of a quick program can have). Its stack holds
    // the thread-local storage on Linux, about 260 KB: 2 MB, reserved rather than used.
    if (!platform.spawnThread(reapEntry, p, 2 << 20))
        rt.fatal("cannot start a thread to wait for a program", .{});
    return register(p);
}

fn reapEntry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    reap(@ptrCast(@alignCast(arg)));
    return null;
}

/// The reaper: wait for the program to end, record how, and wake its waiters. A thread
/// the runtime doesn't know, which touches no heap objects. It collects the program, and
/// releases its handles, under the lock that signal takes, after recording its end: so a
/// signal reaches the program while it runs, or nothing, never a pid or handle reused.
fn reap(p: *Proc) void {
    platform.awaitExit(&p.child);
    lock.lock();
    const code = platform.collectExit(&p.child);
    p.exit.store(code, .release);
    p.job = platform.afterExit(p.handle, p.job);
    p.handle = null;
    lock.unlock();
    tasks.notifyFromAnyThread(p.key);
}

// ---------------------------------------------------------------------------------------
// Waiting

fn ended(arg: ?*anyopaque) bool {
    const p: *Proc = @ptrCast(@alignCast(arg));
    return p.exit.load(.acquire) != running;
}

/// Once the program is seen to have ended, release its stdin pipe: nothing reads it, and
/// a program that is waited for but never closed holds no descriptor.
fn noteEnded(p: *Proc) void {
    if (p.streams[0] != Value.nil and !p.stdin_released.swap(true, .acq_rel)) files.releasePipe(p.streams[0], p.serials[0]);
}

/// (%process-wait h seconds): the exit status once it ends, or nil if `seconds` (nil: no
/// limit) pass first. A fiber parks meanwhile.
fn waitFor(h: Value, seconds: Value) Value {
    const p = procOf(h);
    if (!ended(p) and !tasks.waitForKey(p.key, ended, p, seconds)) return Value.nil;
    noteEnded(p);
    return Value.fromFixnum(p.exit.load(.acquire));
}

/// (%process-signal h kind tree): signal the program by intent (0 interrupt, 1 terminate,
/// 2 kill) while it runs; with `tree`, what it started too, even once it has ended (its
/// process group or job object). Returns nil.
fn signal(h: Value, kind: Value, tree: Value) Value {
    const p = procOf(h);
    if (!kind.isFixnum() or kind.toFixnum() < 0 or kind.toFixnum() > 2)
        rt.raise(.@"error", "%process-signal needs 0, 1 or 2, not {s}", .{readable(kind)});
    // Under the reaper's lock: it has recorded the end before it collects the program.
    lock.lock();
    defer lock.unlock();
    platform.signalProcess(p.pid, p.handle, p.job, @intCast(kind.toFixnum()), tree.isTruthy(), p.own_group, ended(p));
    return Value.nil;
}

fn exitOf(h: Value) Value {
    const p = procOf(h);
    const code = p.exit.load(.acquire);
    if (code == running) return Value.nil;
    noteEnded(p);
    return Value.fromFixnum(code);
}

// ---------------------------------------------------------------------------------------
// The environment and this program

/// (%environment): this program's environment, a map of strings.
fn environment() Value {
    var map = platform.processEnviron().createMap(alloc) catch rt.fatal("out of memory", .{});
    defer map.deinit();
    var result = coll.mapOf(&.{});
    var it = map.iterator();
    while (it.next()) |e| {
        if (!std.unicode.utf8ValidateSlice(e.key_ptr.*) or !std.unicode.utf8ValidateSlice(e.value_ptr.*)) continue;
        result = coll.mapAssoc(result, string.make(e.key_ptr.*), string.make(e.value_ptr.*));
    }
    return result;
}

/// (%executable-path): this program's executable, with / as separators.
fn executablePath() Value {
    var buf: [2048]u8 = undefined;
    const n = std.process.executablePath(io.stdIo(), &buf) catch
        rt.raise(.@"error", "cannot find the program's executable", .{});
    for (buf[0..n]) |*ch| if (ch.* == '\\') {
        ch.* = '/';
    };
    if (!std.unicode.utf8ValidateSlice(buf[0..n])) rt.raise(.@"error", "the program's path isn't UTF-8", .{});
    return string.make(buf[0..n]);
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const entries = [_]io.Entry{
    .{ .name = "%process-start", .min = 6, .max = 6, .impl = struct {
        fn f(a: Args) Value {
            return start(a[0], a[1], a[2], a[3], a[4], a[5]);
        }
    }.f },
    .{ .name = "%process-stream", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            // (%process-stream h i): stream i (0 stdin, 1 stdout, 2 stderr), or nil.
            const p = procOf(a[0]);
            if (!a[1].isFixnum() or a[1].toFixnum() < 0 or a[1].toFixnum() > 2)
                rt.raise(.@"error", "%process-stream needs 0, 1 or 2, not {s}", .{readable(a[1])});
            return p.streams[@intCast(a[1].toFixnum())];
        }
    }.f },
    .{ .name = "%process-signal", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return signal(a[0], a[1], a[2]);
        }
    }.f },
    .{ .name = "%process-pid", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromFixnum(procOf(a[0]).pid);
        }
    }.f },
    .{ .name = "%process-exit", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return exitOf(a[0]);
        }
    }.f },
    .{ .name = "%process-wait", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return waitFor(a[0], a[1]);
        }
    }.f },
    .{ .name = "%interrupt-ignored?", .min = 0, .max = 0, .impl = struct {
        fn f(a: Args) Value {
            // Whether this program ignores SIGINT, which the programs it starts inherit
            // (for tests run by a shell in the background).
            _ = a;
            return Value.fromBool(platform.interruptIgnored());
        }
    }.f },
    .{ .name = "%environment", .min = 0, .max = 0, .impl = struct {
        fn f(a: Args) Value {
            _ = a;
            return environment();
        }
    }.f },
    .{ .name = "%executable-path", .min = 0, .max = 0, .impl = struct {
        fn f(a: Args) Value {
            _ = a;
            return executablePath();
        }
    }.f },
};
