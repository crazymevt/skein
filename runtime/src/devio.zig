//! What the REPL and `skein dev` need from the runtime (M2.6, D-081): file modification
//! dates for the watcher and reading the terminal. Its REPL and Swank servers use skein.net
//! (D-106). Phase 0 does these in CL (host/src/repl/repl.lisp), so it has only stand-ins.
//!
//! Everything goes through std.Io, on every platform. A call that waits runs as a
//! `sched.blocking` call, so its worker is handed to other fibers meanwhile. The terminal
//! is read in chunks, and a UTF-8 sequence split between two reads is held back until the
//! rest arrives.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const sched = @import("sched.zig");
const string = @import("string.zig");
const coll = @import("coll.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;
const net = std.Io.net;

extern fn sk_exit(status: c_int) noreturn;

// ---------------------------------------------------------------------------------------
// File dates

const StatCall = struct { path: []const u8, mtime: ?i96 = null };

fn statBlocking(arg: ?*anyopaque) void {
    const c: *StatCall = @ptrCast(@alignCast(arg));
    const st = std.Io.Dir.cwd().statFile(io.stdIo(), c.path, .{}) catch return;
    c.mtime = st.mtime.nanoseconds;
}

/// The file's modification time in nanoseconds since 1970, or nil if it can't be read.
fn fileMtime(path: Value) Value {
    if (!string.isString(path)) rt.raise(.type_error, "%file-mtime needs a path", .{});
    const p = alloc.dupe(u8, string.bytes(path)) catch rt.fatal("out of memory", .{});
    defer alloc.free(p);
    var call: StatCall = .{ .path = p };
    io.pathBlocking(statBlocking, &call);
    const t = call.mtime orelse return Value.nil;
    return Value.fromFixnum(@intCast(t));
}

const RealCall = struct { path: []const u8, out: ?[:0]u8 = null };

fn realPathBlocking(arg: ?*anyopaque) void {
    const c: *RealCall = @ptrCast(@alignCast(arg));
    c.out = std.Io.Dir.cwd().realPathFileAlloc(io.stdIo(), c.path, alloc) catch null;
}

/// The absolute path of an existing file (relative paths are from the current directory),
/// or nil: Swank sends Emacs absolute paths (M2.7, D-086).
fn absolutePath(path: Value) Value {
    if (!string.isString(path)) rt.raise(.type_error, "%absolute-path needs a path", .{});
    const p = alloc.dupe(u8, string.bytes(path)) catch rt.fatal("out of memory", .{});
    defer alloc.free(p);
    var call: RealCall = .{ .path = p };
    io.pathBlocking(realPathBlocking, &call);
    const out = call.out orelse return Value.nil;
    defer alloc.free(out);
    return string.make(out);
}

// ---------------------------------------------------------------------------------------
// The terminal (skein.net's sockets are streams of files.zig, D-106)

const Entry = struct {
    /// The start of a UTF-8 sequence that the last read split.
    pending: [4]u8 = undefined,
    pending_len: usize = 0,
    closed: bool = false,
};

var stdin_entry: Entry = .{};

const ReadCall = struct { buf: []u8, n: usize = 0, failed: bool = false };

fn readBlocking(arg: ?*anyopaque) void {
    const c: *ReadCall = @ptrCast(@alignCast(arg));
    var bufs = [_][]u8{c.buf};
    c.n = std.Io.File.stdin().readStreaming(io.stdIo(), &bufs) catch {
        c.failed = true;
        return;
    };
}

/// The length of the longest prefix of `bytes` that doesn't end inside a UTF-8 sequence.
fn completeLength(bytes: []const u8) usize {
    var i = bytes.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const b = bytes[i];
        if (b & 0xC0 != 0x80) {
            const need: usize = if (b < 0x80) 1 else if (b >> 5 == 0b110) 2 else if (b >> 4 == 0b1110) 3 else if (b >> 3 == 0b11110) 4 else 1;
            return if (back >= need) bytes.len else i;
        }
    }
    return bytes.len;
}

/// The next text read from the terminal: a non-empty string, or nil at its end.
fn readText(h: Value) Value {
    if (h != Value.fromFixnum(0)) rt.raise(.@"error", "%read-text needs the terminal", .{});
    const e = &stdin_entry;
    var buf: [4096 + 4]u8 = undefined;
    while (true) {
        if (e.closed) return Value.nil;
        @memcpy(buf[0..e.pending_len], e.pending[0..e.pending_len]);
        var call: ReadCall = .{ .buf = buf[e.pending_len..] };
        sched.blocking(readBlocking, &call);
        if (call.failed or call.n == 0) {
            e.closed = true;
            // What's left of a split sequence at the end isn't text.
            return Value.nil;
        }
        const total = e.pending_len + call.n;
        const keep = completeLength(buf[0..total]);
        e.pending_len = total - keep;
        @memcpy(e.pending[0..e.pending_len], buf[keep..total]);
        if (keep == 0) continue;
        if (!std.unicode.utf8ValidateSlice(buf[0..keep])) rt.raise(.@"error", "the input isn't UTF-8 text", .{});
        return string.make(buf[0..keep]);
    }
}

// ---------------------------------------------------------------------------------------
// Running a program on this terminal (skeinc run, dev and repl, M2.6 step 4)

const AttachedCall = struct { argv: []const []const u8, env: []const [2][]const u8, code: ?i64 = null };

fn attachedBlocking(arg: ?*anyopaque) void {
    const c: *AttachedCall = @ptrCast(@alignCast(arg));
    var map = platform.processEnviron().createMap(alloc) catch return;
    defer map.deinit();
    for (c.env) |kv| map.put(kv[0], kv[1]) catch return;
    var child = std.process.spawn(io.stdIo(), .{ .argv = c.argv, .environ_map = &map }) catch return;
    const term = child.wait(io.stdIo()) catch return;
    c.code = switch (term) {
        .exited => |n| n,
        .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
        .unknown => |n| n,
    };
}

/// Run `argv` (a vector of strings) with this process's standard input, output and error,
/// and the variables of the map `env` added to its environment; wait for it, and return
/// its exit status (128 plus the signal that ended it), or nil if it can't be started.
fn runAttached(argv: Value, env: Value) Value {
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    var vars: std.ArrayList([2][]const u8) = .empty;
    defer {
        for (vars.items) |kv| {
            alloc.free(kv[0]);
            alloc.free(kv[1]);
        }
        vars.deinit(alloc);
    }
    for (0..coll.vectorCount(argv)) |i| {
        const a = coll.vectorNth(argv, i).?;
        if (!string.isString(a)) rt.raise(.type_error, "%run-attached needs a vector of strings", .{});
        args.append(alloc, alloc.dupe(u8, string.bytes(a)) catch rt.fatal("out of memory", .{})) catch rt.fatal("out of memory", .{});
    }
    if (env != Value.nil) {
        const seq = @import("seq.zig");
        var s = seq.seq(env);
        while (s != Value.nil) : (s = seq.seqNext(s)) {
            const e = seq.seqFirst(s);
            const k = coll.vectorNth(e, 0).?;
            const v = coll.vectorNth(e, 1).?;
            if (!string.isString(k) or !string.isString(v)) rt.raise(.type_error, "%run-attached needs a map of strings", .{});
            vars.append(alloc, .{
                alloc.dupe(u8, string.bytes(k)) catch rt.fatal("out of memory", .{}),
                alloc.dupe(u8, string.bytes(v)) catch rt.fatal("out of memory", .{}),
            }) catch rt.fatal("out of memory", .{});
        }
    }
    var call: AttachedCall = .{ .argv = args.items, .env = vars.items };
    io.pathBlocking(attachedBlocking, &call);
    return if (call.code) |c| Value.fromFixnum(c) else Value.nil;
}

// ---------------------------------------------------------------------------------------
// Hot reload of compiled code (M2.9, D-091): a module is a shared library compiled from one
// namespace. Its sk_module_init(count, vars) gets the program's vars that its code uses (in
// the order the compiler declared them; runtime vars aren't found by name), registers its
// constants and functions, and runs the namespace's top-level forms, which rebind them.

const ModuleInit = *const fn (count: u32, vars: [*]const Value) callconv(.c) void;

const LoadCall = struct { path: [:0]const u8, why: []u8, init: ?*anyopaque = null, handle: bool = false };

/// Loading a library can take tens of milliseconds (macOS checks its signature) and
/// touches no Skein objects, so it's a blocking call: a collection needn't wait for it,
/// which would stall every thread, a game's frame included.
fn loadBlocking(arg: ?*anyopaque) void {
    const c: *LoadCall = @ptrCast(@alignCast(arg));
    const handle = platform.loadLibrary(c.path, c.why) orelse return;
    c.handle = true;
    c.init = platform.librarySymbol(handle, "sk_module_init");
}

/// Load the module at `path` and run its init function with `vars`, a vector of vars.
/// Modules are never unloaded: running frames and closures may still use their code.
fn loadModule(path: Value, vars: Value) Value {
    if (!string.isString(path)) rt.raise(.type_error, "%load-module needs a path", .{});
    if (!coll.isVector(vars)) rt.raise(.type_error, "%load-module needs a vector of vars", .{});
    const n = coll.vectorCount(vars);
    // Vars are permanent objects, which never move, so this copy needs no root.
    const vs = alloc.alloc(Value, @max(n, 1)) catch rt.fatal("out of memory", .{});
    defer alloc.free(vs);
    for (0..n) |i| {
        const v = coll.vectorNth(vars, i).?;
        if (!v.isObjectOf(.@"var")) rt.raise(.type_error, "%load-module needs a vector of vars", .{});
        vs[i] = v;
    }
    const p = alloc.dupeSentinel(u8, string.bytes(path), 0) catch rt.fatal("out of memory", .{});
    defer alloc.free(p);
    var why: [512]u8 = undefined;
    @memset(&why, 0);
    var call: LoadCall = .{ .path = p, .why = &why };
    io.pathBlocking(loadBlocking, &call);
    if (!call.handle)
        rt.raise(.@"error", "cannot load the module {s}: {s}", .{ p, std.mem.sliceTo(&why, 0) });
    const sym = call.init orelse rt.raise(.@"error", "the module {s} has no sk_module_init", .{p});
    const init: ModuleInit = @ptrCast(@alignCast(sym));
    init(@intCast(n), vs.ptr);
    return Value.true;
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;
const CoreEntry = @import("compiler.zig").Entry;

pub const entries = [_]CoreEntry{
    // (%set-output-var! var): what's printed goes to the function bound to var, if any.
    .{ .name = "%set-output-var!", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.@"var")) rt.raise(.type_error, "%set-output-var! needs a var", .{});
            @import("print.zig").output_var = a[0];
            return Value.nil;
        }
    }.f },
    .{ .name = "%run-attached", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return runAttached(a[0], a[1]);
        }
    }.f },
    // (%exit status): end the program now.
    .{ .name = "%exit", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!a[0].isFixnum()) rt.raise(.type_error, "%exit needs a status", .{});
            sk_exit(@intCast(a[0].toFixnum()));
        }
    }.f },
    .{ .name = "%main-thread?", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return Value.fromBool(@import("tasks.zig").onMainThreadNow());
        }
    }.f },
    .{ .name = "%file-mtime", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return fileMtime(a[0]);
        }
    }.f },
    .{ .name = "%stdin", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            return Value.fromFixnum(0);
        }
    }.f },
    .{ .name = "%read-text", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readText(a[0]);
        }
    }.f },
    .{ .name = "%load-module", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return loadModule(a[0], a[1]);
        }
    }.f },
    // (%evaluated? f): whether the evaluator made the function f (M2.9, D-091).
    .{ .name = "%evaluated?", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromBool(@import("eval/compile.zig").isEvaluated(a[0]));
        }
    }.f },
    .{ .name = "%absolute-path", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return absolutePath(a[0]);
        }
    }.f },
    // (%utf8-length s): the number of bytes of the string in UTF-8.
    .{ .name = "%utf8-length", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!string.isString(a[0])) rt.raise(.type_error, "%utf8-length needs a string", .{});
            return Value.fromFixnum(@intCast(string.bytes(a[0]).len));
        }
    }.f },
};
