//! What the REPL and `skein dev` need from the runtime (M2.6, D-081): file modification
//! dates for the watcher, reading the terminal, and a TCP server on localhost for the REPL
//! server. Phase 0 does these in CL (host/src/repl/repl.lisp), so it has only stand-ins.
//!
//! Everything goes through std.Io, on every platform. A call that waits runs as a
//! `sched.blocking` call, so its worker is handed to other fibers meanwhile. Servers and
//! connections are small integers naming entries of a table; text is read in chunks, and
//! a UTF-8 sequence split between two reads is held back until the rest arrives.

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
// Streams: the terminal and TCP connections

const Kind = enum { stdin, server, connection };

const Entry = struct {
    kind: Kind,
    server: net.Server = undefined,
    stream: net.Stream = undefined,
    /// The start of a UTF-8 sequence that the last read split.
    pending: [4]u8 = undefined,
    pending_len: usize = 0,
    closed: bool = false,
};

var lock: platform.Mutex = .{};
var table: std.ArrayList(?*Entry) = .empty;

fn add(e: Entry) Value {
    const p = alloc.create(Entry) catch rt.fatal("out of memory", .{});
    p.* = e;
    lock.lock();
    defer lock.unlock();
    table.append(alloc, p) catch rt.fatal("out of memory", .{});
    return Value.fromFixnum(@intCast(table.items.len - 1));
}

fn entry(h: Value, comptime what: []const u8) *Entry {
    if (!h.isFixnum()) rt.raise(.type_error, what ++ " needs a handle", .{});
    lock.lock();
    defer lock.unlock();
    const i: usize = @intCast(h.toFixnum());
    if (i >= table.items.len) rt.raise(.@"error", what ++ ": no such handle", .{});
    return table.items[i] orelse rt.raise(.@"error", what ++ ": the handle is closed", .{});
}

var stdin_handle: ?Value = null;

/// The handle of standard input (made once).
fn stdinHandle() Value {
    if (stdin_handle) |h| return h;
    const h = add(.{ .kind = .stdin });
    stdin_handle = h;
    return h;
}

const ReadCall = struct { e: *Entry, buf: []u8, n: usize = 0, failed: bool = false };

fn readBlocking(arg: ?*anyopaque) void {
    const c: *ReadCall = @ptrCast(@alignCast(arg));
    var bufs = [_][]u8{c.buf};
    c.n = switch (c.e.kind) {
        .stdin => std.Io.File.stdin().readStreaming(io.stdIo(), &bufs) catch {
            c.failed = true;
            return;
        },
        .connection => c.e.stream.read(io.stdIo(), &bufs) catch {
            c.failed = true;
            return;
        },
        .server => unreachable,
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

/// The next text read from the stream: a non-empty string, or nil at its end.
fn readText(h: Value) Value {
    const e = entry(h, "%read-text");
    if (e.kind == .server) rt.raise(.@"error", "%read-text needs a connection or the terminal", .{});
    var buf: [4096 + 4]u8 = undefined;
    while (true) {
        if (e.closed) return Value.nil;
        @memcpy(buf[0..e.pending_len], e.pending[0..e.pending_len]);
        var call: ReadCall = .{ .e = e, .buf = buf[e.pending_len..] };
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

const WriteCall = struct { e: *Entry, text: []const u8, ok: bool = false };

fn writeBlocking(arg: ?*anyopaque) void {
    const c: *WriteCall = @ptrCast(@alignCast(arg));
    var buf: [1024]u8 = undefined;
    var w = net.Stream.Writer.init(c.e.stream, io.stdIo(), &buf);
    w.interface.writeAll(c.text) catch return;
    w.interface.flush() catch return;
    c.ok = true;
}

/// Write the string to the connection; false if it's closed.
fn writeText(h: Value, text: Value) Value {
    const e = entry(h, "%write-text");
    if (e.kind != .connection) rt.raise(.@"error", "%write-text needs a connection", .{});
    if (!string.isString(text)) rt.raise(.type_error, "%write-text needs a string", .{});
    const t = alloc.dupe(u8, string.bytes(text)) catch rt.fatal("out of memory", .{});
    defer alloc.free(t);
    var call: WriteCall = .{ .e = e, .text = t };
    sched.blocking(writeBlocking, &call);
    return Value.fromBool(call.ok);
}

// ---------------------------------------------------------------------------------------
// The server

const ListenCall = struct { port: u16, server: ?net.Server = null };

fn listenBlocking(arg: ?*anyopaque) void {
    const c: *ListenCall = @ptrCast(@alignCast(arg));
    const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(c.port) };
    c.server = address.listen(io.stdIo(), .{ .reuse_address = true }) catch null;
}

/// A server listening on localhost's `port`, or nil if it can't (the port is taken).
fn listen(port: Value) Value {
    if (!port.isFixnum() or port.toFixnum() < 0 or port.toFixnum() > 65535)
        rt.raise(.type_error, "%tcp-listen needs a port number", .{});
    var call: ListenCall = .{ .port = @intCast(port.toFixnum()) };
    sched.blocking(listenBlocking, &call);
    const s = call.server orelse return Value.nil;
    return add(.{ .kind = .server, .server = s });
}

const AcceptCall = struct { e: *Entry, stream: ?net.Stream = null };

fn acceptBlocking(arg: ?*anyopaque) void {
    const c: *AcceptCall = @ptrCast(@alignCast(arg));
    c.stream = c.e.server.accept(io.stdIo()) catch null;
}

/// The next connection to the server, or nil if it's closed.
fn accept(h: Value) Value {
    const e = entry(h, "%tcp-accept");
    if (e.kind != .server) rt.raise(.@"error", "%tcp-accept needs a server", .{});
    var call: AcceptCall = .{ .e = e };
    sched.blocking(acceptBlocking, &call);
    const s = call.stream orelse return Value.nil;
    return add(.{ .kind = .connection, .stream = s });
}

/// Close a server or a connection.
fn close(h: Value) Value {
    const e = entry(h, "%tcp-close");
    switch (e.kind) {
        .server => e.server.deinit(io.stdIo()),
        .connection => e.stream.close(io.stdIo()),
        .stdin => return Value.nil,
    }
    lock.lock();
    defer lock.unlock();
    table.items[@intCast(h.toFixnum())] = null;
    return Value.nil;
}

/// The port a server listens on.
fn serverPort(h: Value) Value {
    const e = entry(h, "%tcp-port");
    if (e.kind != .server) rt.raise(.@"error", "%tcp-port needs a server", .{});
    return Value.fromFixnum(e.server.socket.address.getPort());
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
// Swank's framing (M2.7, D-082) counts UTF-8 bytes

/// [the first n bytes of the string, the rest], or nil if it has fewer than n bytes.
fn utf8Split(s: Value, n: Value) Value {
    if (!string.isString(s)) rt.raise(.type_error, "%utf8-split needs a string", .{});
    if (!n.isFixnum() or n.toFixnum() < 0) rt.raise(.type_error, "%utf8-split needs a byte count", .{});
    const k: usize = @intCast(n.toFixnum());
    const all = string.bytes(s);
    if (k > all.len) return Value.nil;
    if (k < all.len and all[k] & 0xC0 == 0x80) rt.raise(.@"error", "%utf8-split: byte {d} is inside a character", .{k});
    // Copy first: making the strings may move s.
    const t = alloc.dupe(u8, all) catch rt.fatal("out of memory", .{});
    defer alloc.free(t);
    const head = string.make(t[0..k]);
    const tail = string.make(t[k..]);
    return coll.vectorOf(&.{ head, tail });
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
            return stdinHandle();
        }
    }.f },
    .{ .name = "%read-text", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readText(a[0]);
        }
    }.f },
    .{ .name = "%write-text", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return writeText(a[0], a[1]);
        }
    }.f },
    .{ .name = "%tcp-listen", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return listen(a[0]);
        }
    }.f },
    .{ .name = "%tcp-accept", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return accept(a[0]);
        }
    }.f },
    .{ .name = "%tcp-port", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return serverPort(a[0]);
        }
    }.f },
    .{ .name = "%tcp-close", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return close(a[0]);
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
    .{ .name = "%utf8-split", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return utf8Split(a[0], a[1]);
        }
    }.f },
};
