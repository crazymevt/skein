//! skein.io's primitives natively (M1.9 step 1, D-058), matching Phase 0
//! (host/src/runtime/io.lisp): reading and writing files, checking that one exists, and
//! running a program. lib/skein/io.skn wraps them and signals io-error; these return nil
//! (or false) on failure.
//!
//! Files and processes go through Zig's std.Io. Each operation runs in `gc.blocking`, so
//! other threads can collect while it waits; it therefore works on copies of its strings
//! made outside the heap.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const sched = @import("sched.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const print = @import("print.zig");
const seq = @import("seq.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

var io_lock: platform.Mutex = .{};
var threaded: std.Io.Threaded = undefined;
var io_ready = false;

/// The std.Io instance, made on first use with the process's environment (to find
/// programs on PATH).
pub fn stdIo() std.Io {
    io_lock.lock();
    defer io_lock.unlock();
    if (!io_ready) {
        threaded = std.Io.Threaded.init(alloc, .{ .environ = platform.processEnviron() });
        io_ready = true;
    }
    return threaded.io();
}

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

/// A copy of the string `v` outside the heap.
fn copyString(v: Value, comptime what: []const u8) []u8 {
    if (!string.isString(v)) coll.unsupported(what ++ ", not {s}", .{readable(v)});
    return alloc.dupe(u8, string.bytes(v)) catch rt.fatal("out of memory", .{});
}

fn copyPath(v: Value) []u8 {
    return copyString(v, "a path must be a string");
}

/// This machine's zig target triple (DESIGN §19.1).
const host_target = @tagName(builtin.cpu.arch) ++ switch (builtin.os.tag) {
    .macos => "-macos",
    .linux => "-linux-gnu",
    .windows => "-windows-gnu",
    else => @compileError("the Skein runtime supports macOS, Linux and Windows"),
};

/// A Skein string of `bytes`, or null if they aren't UTF-8 (Phase 0 can't decode them).
fn decoded(bytes: []const u8) ?Value {
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return string.make(bytes);
}

// ---------------------------------------------------------------------------------------
// Files

const ReadCall = struct { path: []const u8, data: ?[]u8 = null };

fn readBlocking(arg: ?*anyopaque) void {
    const c: *ReadCall = @ptrCast(@alignCast(arg));
    c.data = std.Io.Dir.cwd().readFileAlloc(stdIo(), c.path, alloc, .unlimited) catch null;
}

/// The file's contents as a string, or nil if it can't be read.
fn readFile(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: ReadCall = .{ .path = p };
    sched.blocking(readBlocking, &call);
    const data = call.data orelse return Value.nil;
    defer alloc.free(data);
    return decoded(data) orelse Value.nil;
}

const WriteCall = struct { path: []const u8, text: []const u8, ok: bool = false };

fn writeBlocking(arg: ?*anyopaque) void {
    const c: *WriteCall = @ptrCast(@alignCast(arg));
    std.Io.Dir.cwd().writeFile(stdIo(), .{ .sub_path = c.path, .data = c.text }) catch return;
    c.ok = true;
}

/// Write `text` to the file, replacing it; false if it can't be written.
fn writeFile(path: Value, text: Value) Value {
    const t = copyString(text, "write-file needs a string");
    defer alloc.free(t);
    const p = copyPath(path);
    defer alloc.free(p);
    var call: WriteCall = .{ .path = p, .text = t };
    sched.blocking(writeBlocking, &call);
    return Value.fromBool(call.ok);
}

const ExistsCall = struct { path: []const u8, exists: bool = false };

fn existsBlocking(arg: ?*anyopaque) void {
    const c: *ExistsCall = @ptrCast(@alignCast(arg));
    std.Io.Dir.cwd().access(stdIo(), c.path, .{}) catch return;
    c.exists = true;
}

/// True if a file or directory exists at `path`.
fn fileExists(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: ExistsCall = .{ .path = p };
    sched.blocking(existsBlocking, &call);
    return Value.fromBool(call.exists);
}

// Directories and copies, for packaging (M1.11, D-069). Each runs as a blocking call.

const PathCall = struct { a: []const u8, b: []const u8 = "", ok: bool = false };

fn makeDirectoriesBlocking(arg: ?*anyopaque) void {
    const c: *PathCall = @ptrCast(@alignCast(arg));
    std.Io.Dir.cwd().createDirPath(stdIo(), c.a) catch return;
    c.ok = true;
}

fn copyFileBlocking(arg: ?*anyopaque) void {
    const c: *PathCall = @ptrCast(@alignCast(arg));
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(c.a, cwd, c.b, stdIo(), .{}) catch return;
    c.ok = true;
}

fn deleteTreeBlocking(arg: ?*anyopaque) void {
    const c: *PathCall = @ptrCast(@alignCast(arg));
    std.Io.Dir.cwd().deleteTree(stdIo(), c.a) catch return;
    c.ok = true;
}

/// Run `f` on the path strings `a` and `b` (or "") as a blocking call; true if it worked.
fn pathCall(f: *const fn (?*anyopaque) void, a: Value, b: ?Value) Value {
    const pa = copyPath(a);
    defer alloc.free(pa);
    const pb = if (b) |v| copyPath(v) else "";
    defer if (b != null) alloc.free(pb);
    var call: PathCall = .{ .a = pa, .b = pb };
    sched.blocking(f, &call);
    return Value.fromBool(call.ok);
}

const ListCall = struct { path: []const u8, names: std.ArrayList([]u8) = .empty, ok: bool = false };

fn listBlocking(arg: ?*anyopaque) void {
    const c: *ListCall = @ptrCast(@alignCast(arg));
    const io = stdIo();
    var dir = std.Io.Dir.cwd().openDir(io, c.path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        const slash = entry.kind == .directory;
        const n = alloc.alloc(u8, entry.name.len + @intFromBool(slash)) catch return;
        @memcpy(n[0..entry.name.len], entry.name);
        if (slash) n[entry.name.len] = '/';
        c.names.append(alloc, n) catch return;
    }
    c.ok = true;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The names in the directory at `path`, sorted, each directory's ending with /; nil if
/// it can't be read.
fn listDirectory(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: ListCall = .{ .path = p };
    defer {
        for (call.names.items) |n| alloc.free(n);
        call.names.deinit(alloc);
    }
    sched.blocking(listBlocking, &call);
    if (!call.ok) return Value.nil;
    std.mem.sort([]u8, call.names.items, {}, lessThan);
    var out = coll.vectorOf(&.{});
    for (call.names.items) |n| out = coll.vectorConj(out, decoded(n) orelse continue);
    return out;
}

/// The directory holding the program's assets, ending with / (skein.io/resource-dir,
/// D-073): the executable's directory, or a macOS app's Contents/Resources. Separators
/// are /, which every OS accepts.
fn resourceDir() Value {
    var buf: [2048]u8 = undefined;
    const n = std.process.executableDirPath(stdIo(), buf[0..1024]) catch
        rt.raise(.@"error", "cannot find the program's executable", .{});
    for (buf[0..n]) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    const sub = platform.resourceSubdirectory(buf[0..n]);
    const text = std.fmt.bufPrint(buf[n..], "/{s}", .{sub}) catch unreachable;
    return decoded(buf[0 .. n + text.len]) orelse
        rt.raise(.@"error", "the program's directory isn't UTF-8", .{});
}

// ---------------------------------------------------------------------------------------
// Processes

const RunCall = struct {
    argv: []const []const u8,
    dir: ?[]const u8,
    result: ?std.process.RunResult = null,
};

fn runBlocking(arg: ?*anyopaque) void {
    const c: *RunCall = @ptrCast(@alignCast(arg));
    c.result = std.process.run(alloc, stdIo(), .{
        .argv = c.argv,
        .cwd = if (c.dir) |d| .{ .path = d } else .inherit,
    }) catch null;
}

/// Run `argv` (the program, then its arguments) without a shell, in `dir` (or the current
/// directory if nil). Returns {:exit :out :err}, or nil if the program can't be started.
fn runProcess(argv: Value, dir: Value) Value {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    var s = seq.seq(argv);
    while (s != Value.nil) : (s = seq.seqNext(s)) {
        const a = seq.seqFirst(s);
        if (!string.isString(a)) break;
        args.append(alloc, copyString(a, "")) catch rt.fatal("out of memory", .{});
    }
    if (s != Value.nil or args.items.len == 0)
        coll.unsupported("run-process needs a vector of strings, not {s}", .{readable(argv)});
    const d: ?[]u8 = if (dir == Value.nil) null else copyPath(dir);
    defer if (d) |x| alloc.free(x);
    var call: RunCall = .{ .argv = args.items, .dir = d };
    sched.blocking(runBlocking, &call);
    const r = call.result orelse return Value.nil;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    // As SBCL reports it: the exit status, or the number of the signal that ended it.
    const code: i64 = switch (r.term) {
        .exited => |n| n,
        .signal, .stopped => |sig| @intFromEnum(sig),
        .unknown => |n| n,
    };
    const out = decoded(r.stdout) orelse return Value.nil;
    const err = decoded(r.stderr) orelse return Value.nil;
    return coll.mapOf(&.{
        names.keyword(null, "exit"), Value.fromFixnum(code),
        names.keyword(null, "out"),  out,
        names.keyword(null, "err"),  err,
    });
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const Entry = struct {
    name: []const u8,
    min: u32,
    max: ?u32,
    impl: *const fn (Args) Value,
};

pub const entries = [_]Entry{
    .{ .name = "%getenv", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            // The environment variable's value, or nil. (Internal: the native compiler
            // reads SKEIN_HOME and SKEIN_ZIG.)
            const n = copyString(a[0], "%getenv needs a name");
            defer alloc.free(n);
            const z = alloc.dupeSentinel(u8, n, 0) catch rt.fatal("out of memory", .{});
            defer alloc.free(z);
            const v = std.c.getenv(z.ptr) orelse return Value.nil;
            return decoded(std.mem.span(v)) orelse Value.nil;
        }
    }.f },
    .{ .name = "%host-target", .min = 0, .max = 0, .impl = struct {
        fn f(a: Args) Value {
            // This machine's zig target triple, as DESIGN §19.1 names it. (Internal: the
            // native compiler's default target, M1.11.)
            _ = a;
            return string.make(host_target);
        }
    }.f },
    .{ .name = "%read-file", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readFile(a[0]);
        }
    }.f },
    .{ .name = "%write-file", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return writeFile(a[0], a[1]);
        }
    }.f },
    .{ .name = "%file-exists?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return fileExists(a[0]);
        }
    }.f },
    // For packaging (M1.11): true, or false if it failed.
    .{ .name = "%make-directories", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return pathCall(makeDirectoriesBlocking, a[0], null);
        }
    }.f },
    .{ .name = "%copy-file", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return pathCall(copyFileBlocking, a[0], a[1]);
        }
    }.f },
    .{ .name = "%delete-tree", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return pathCall(deleteTreeBlocking, a[0], null);
        }
    }.f },
    .{ .name = "%list-directory", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return listDirectory(a[0]);
        }
    }.f },
    .{ .name = "%resource-dir", .min = 0, .max = 0, .impl = struct {
        fn f(a: Args) Value {
            _ = a;
            return resourceDir();
        }
    }.f },
    .{ .name = "%run-process", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return runProcess(a[0], a[1]);
        }
    }.f },
};
