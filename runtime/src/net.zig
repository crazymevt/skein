//! TCP sockets for skein.net (M3.4, D-106). A connected socket is a stream of files.zig,
//! so skein.io's functions read and write it; servers are small integers naming entries
//! of a table here. lib/skein/net.skn wraps these and signals io-error and net-timeout.
//!
//! Connecting runs on a thread of its own, which the caller stops waiting for at the
//! timeout: std.Io's connect has no timeout yet. A connection that arrives after its
//! caller gave up is closed by that thread.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const sched = @import("sched.zig");
const string = @import("string.zig");
const names = @import("names.zig");
const cond = @import("cond.zig");
const files = @import("files.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;
const net = std.Io.net;

// ---------------------------------------------------------------------------------------
// net-timeout

/// skein.net's net-timeout condition class (%net-timeout-class!), a root of the heap.
var timeout_class = [1]Value{Value.nil};
var rooted = std.atomic.Value(bool).init(false);

/// Signal net-timeout (an io-error without a path) for a read that waited `nanos`.
pub fn raiseTimeout(nanos: u64) noreturn {
    var buf: [128]u8 = undefined;
    const ms = nanos / std.time.ns_per_ms;
    const text = std.fmt.bufPrint(&buf, "the socket read nothing in {d}.{d:0>3} s", .{ ms / 1000, ms % 1000 }) catch "the socket read timed out";
    signalTimeout(text);
}

fn signalTimeout(text: []const u8) noreturn {
    const class = timeout_class[0];
    if (class == Value.nil) rt.raise(.@"error", "{s}", .{text});
    cond.signalError(cond.makeCondition(class, &.{ names.keyword(null, "message"), string.make(text) }));
}

// ---------------------------------------------------------------------------------------
// Connecting

const Connect = struct {
    host: []u8,
    port: u16,
    lock: platform.Mutex = .{},
    cond: platform.Condition = .{},
    done: bool = false,
    abandoned: bool = false,
    stream: ?net.Stream = null,
    failure: []const u8 = "",
};

/// Connect to host (an IP address, or a name to look up) and port, or say why not.
fn connectTo(host: []const u8, port: u16) union(enum) { ok: net.Stream, failed: []const u8 } {
    const sio = io.stdIo();
    if (net.IpAddress.parse(host, port)) |address| {
        const s = address.connect(sio, .{ .mode = .stream }) catch |err| return .{ .failed = why(err) };
        return .{ .ok = s };
    } else |_| {}
    const name = net.HostName.init(host) catch return .{ .failed = "not a host name or an IP address" };
    const s = name.connect(sio, port, .{ .mode = .stream }) catch |err| return .{ .failed = why(err) };
    return .{ .ok = s };
}

fn why(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "the connection was refused",
        error.UnknownHostName => "unknown host",
        error.NetworkUnreachable, error.HostUnreachable => "the host can't be reached",
        error.ConnectionTimedOut, error.Timeout => "the connection timed out",
        error.AddressUnavailable => "the address isn't available",
        else => @errorName(err),
    };
}

fn connectThread(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c: *Connect = @ptrCast(@alignCast(arg));
    const result = connectTo(c.host, c.port);
    c.lock.lock();
    if (c.abandoned) {
        c.lock.unlock();
        if (result == .ok) result.ok.close(io.stdIo());
        alloc.free(c.host);
        alloc.destroy(c);
        return null;
    }
    switch (result) {
        .ok => |s| c.stream = s,
        .failed => |f| c.failure = f,
    }
    c.done = true;
    c.cond.signal();
    c.lock.unlock();
    return null;
}

const ConnectCall = struct { c: *Connect, timeout: u64, started: bool = true, timed_out: bool = false };

fn connectBlocking(arg: ?*anyopaque) void {
    const call: *ConnectCall = @ptrCast(@alignCast(arg));
    const c = call.c;
    // 2 MB: more than the program's thread-local storage (Linux, D-103).
    if (!platform.spawnThread(connectThread, c, 2 << 20)) {
        call.started = false;
        return;
    }
    const deadline = platform.monotonicNanos() +| call.timeout;
    c.lock.lock();
    while (!c.done) {
        if (call.timeout == 0) {
            c.cond.wait(&c.lock);
            continue;
        }
        const now = platform.monotonicNanos();
        if (now >= deadline) {
            c.abandoned = true;
            call.timed_out = true;
            break;
        }
        c.cond.timedWait(&c.lock, deadline - now);
    }
    c.lock.unlock();
}

/// (%net-connect host port timeout-nanos): a socket stream's handle, or a string saying
/// why it couldn't connect. Running out of time signals net-timeout.
fn connect(host: Value, port: Value, timeout: Value) Value {
    if (!string.isString(host)) rt.raise(.type_error, "connect needs a host name, not a {s}", .{"value"});
    const p = portOf(port, "connect");
    const nanos: u64 = if (timeout.isFixnum() and timeout.toFixnum() > 0) @intCast(timeout.toFixnum()) else 0;
    const c = alloc.create(Connect) catch rt.fatal("out of memory", .{});
    c.* = .{ .host = alloc.dupe(u8, string.bytes(host)) catch rt.fatal("out of memory", .{}), .port = p };
    var call: ConnectCall = .{ .c = c, .timeout = nanos };
    sched.blocking(connectBlocking, &call);
    if (!call.started) {
        alloc.free(c.host);
        alloc.destroy(c);
        return string.make("cannot start a thread to connect");
    }
    if (call.timed_out) {
        // The thread frees c when it finishes.
        var buf: [128]u8 = undefined;
        const ms = nanos / std.time.ns_per_ms;
        signalTimeout(std.fmt.bufPrint(&buf, "connecting timed out after {d}.{d:0>3} s", .{ ms / 1000, ms % 1000 }) catch "connecting timed out");
    }
    const stream = c.stream;
    const failure = c.failure;
    alloc.free(c.host);
    alloc.destroy(c);
    if (stream) |s| return files.registerSocket(s);
    return string.make(failure);
}

fn portOf(port: Value, comptime what: []const u8) u16 {
    if (!port.isFixnum() or port.toFixnum() < 0 or port.toFixnum() > 65535)
        rt.raise(.type_error, what ++ " needs a port number from 0 to 65535", .{});
    return @intCast(port.toFixnum());
}

// ---------------------------------------------------------------------------------------
// Servers

var lock: platform.Mutex = .{};
var servers: std.ArrayList(?*Server) = .empty;

const is_windows = @import("builtin").os.tag == .windows;

/// A listening server. `users` (under `lock`) counts the accepts waiting on it and a
/// close-server at work: the last of them to finish once it's closed frees it, and on
/// Windows closes its socket, after every accept has returned.
const Server = struct {
    server: net.Server,
    users: usize = 0,
    closed: bool = false,
};

/// One user of a closed server is done: the last frees it.
fn release(s: *Server) void {
    lock.lock();
    s.users -= 1;
    const last = s.users == 0;
    lock.unlock();
    if (!last) return;
    if (is_windows) sched.blocking(closeSocketBlocking, s);
    alloc.destroy(s);
}

/// The port of the server h names.
fn serverPort(h: Value) u16 {
    lock.lock();
    defer lock.unlock();
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= servers.items.len) {
        if (servers.items[@intCast(h.toFixnum() - 1)]) |s| return s.server.socket.address.getPort();
    }
    rt.raise(.@"error", "port: the server is closed", .{});
}

/// The server h names, counting the caller among the accepts waiting on it.
fn serverToAccept(h: Value) *Server {
    lock.lock();
    defer lock.unlock();
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= servers.items.len) {
        if (servers.items[@intCast(h.toFixnum() - 1)]) |s| {
            s.users += 1;
            return s;
        }
    }
    rt.raise(.@"error", "accept: the server is closed", .{});
}

const ListenCall = struct { address: net.IpAddress, server: ?net.Server = null, failure: []const u8 = "" };

fn listenBlocking(arg: ?*anyopaque) void {
    const c: *ListenCall = @ptrCast(@alignCast(arg));
    c.server = c.address.listen(io.stdIo(), .{ .reuse_address = true }) catch |err| {
        c.failure = switch (err) {
            error.AddressInUse => "the port is in use",
            error.AddressUnavailable => "the address isn't this machine's",
            else => @errorName(err),
        };
        return;
    };
}

/// (%net-listen host port): a server's handle, or a string saying why it can't listen.
/// host is an IP address, or "localhost".
fn listen(host: Value, port: Value) Value {
    if (!string.isString(host)) rt.raise(.type_error, "listen needs a host address", .{});
    const p = portOf(port, "listen");
    const h = string.bytes(host);
    const address: net.IpAddress = if (std.mem.eql(u8, h, "localhost"))
        .{ .ip4 = net.Ip4Address.loopback(p) }
    else
        net.IpAddress.parse(h, p) catch return string.make("listen needs an IP address or localhost");
    var call: ListenCall = .{ .address = address };
    sched.blocking(listenBlocking, &call);
    const server = call.server orelse return string.make(call.failure);
    const s = alloc.create(Server) catch rt.fatal("out of memory", .{});
    s.* = .{ .server = server };
    lock.lock();
    defer lock.unlock();
    for (servers.items, 0..) |slot, i| {
        if (slot == null) {
            servers.items[i] = s;
            return Value.fromFixnum(@intCast(i + 1));
        }
    }
    servers.append(alloc, s) catch rt.fatal("out of memory", .{});
    return Value.fromFixnum(@intCast(servers.items.len));
}

const AcceptCall = struct { server: *net.Server, stream: ?net.Stream = null };

fn acceptBlocking(arg: ?*anyopaque) void {
    const c: *AcceptCall = @ptrCast(@alignCast(arg));
    c.stream = c.server.accept(io.stdIo()) catch null;
}

/// (%net-accept server): the next connection's socket stream, or nil once the server is
/// closed.
fn accept(h: Value) Value {
    const s = serverToAccept(h);
    var call: AcceptCall = .{ .server = &s.server };
    sched.blocking(acceptBlocking, &call);
    lock.lock();
    const closed = s.closed;
    if (!closed) s.users -= 1;
    lock.unlock();
    if (closed) {
        // A connection close-server made to wake it (or one that came as it closed).
        if (call.stream) |stream| stream.close(io.stdIo());
        release(s);
        return Value.nil;
    }
    const stream = call.stream orelse return Value.nil;
    return files.registerSocket(stream);
}

fn closeSocketBlocking(arg: ?*anyopaque) void {
    const s: *Server = @ptrCast(@alignCast(arg));
    s.server.deinit(io.stdIo());
}

/// The server, and how many accepts were waiting on it when it was closed.
const CloseCall = struct { server: *Server, waiting: usize };

fn closeServerBlocking(arg: ?*anyopaque) void {
    const c: *CloseCall = @ptrCast(@alignCast(arg));
    const s = &c.server.server;
    const sio = io.stdIo();
    if (is_windows) {
        // Closing the socket cancels a waiting accept, which Zig's library takes for
        // unreachable (STATUS_CANCELLED): wake each with a connection instead, and the
        // last user closes the socket (release).
        var address = s.socket.address;
        switch (address) {
            .ip4 => |a| if (std.mem.eql(u8, &a.bytes, &.{ 0, 0, 0, 0 })) {
                address = .{ .ip4 = net.Ip4Address.loopback(a.port) };
            },
            .ip6 => |a| if (std.mem.allEqual(u8, &a.bytes, 0)) {
                address = .{ .ip6 = net.Ip6Address.loopback(a.port) };
            },
        }
        const wakers = alloc.alloc(net.Stream, c.waiting) catch rt.fatal("out of memory", .{});
        defer alloc.free(wakers);
        var made: usize = 0;
        while (made < c.waiting) : (made += 1) {
            wakers[made] = address.connect(sio, .{ .mode = .stream }) catch break;
        }
        // Each stays open until the accepts have taken them (or 2 s have passed): one
        // closed sooner could make an accept fail on the reset.
        var pause_lock: platform.Mutex = .{};
        var pause: platform.Condition = .{};
        var tries: usize = 0;
        while (tries < 2000) : (tries += 1) {
            lock.lock();
            const done = c.server.users == 1; // only this close-server
            lock.unlock();
            if (done) break;
            pause_lock.lock();
            pause.timedWait(&pause_lock, std.time.ns_per_ms);
            pause_lock.unlock();
        }
        for (wakers[0..made]) |w| w.close(sio);
        return;
    }
    // Closing the socket alone doesn't wake an accept waiting on it on Linux, where it
    // would wait for ever: shutting it down first does, and the accept then returns nil.
    // (macOS wakes it on close, and fails this harmlessly.)
    sio.vtable.netShutdown(sio.userdata, s.socket.handle, .both) catch {};
    s.deinit(sio);
}

/// (%net-close-server server): stop listening; closing it again does nothing.
fn closeServer(h: Value) Value {
    lock.lock();
    var found: ?*Server = null;
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= servers.items.len) {
        const i: usize = @intCast(h.toFixnum() - 1);
        found = servers.items[i];
        servers.items[i] = null;
    }
    const s = found orelse {
        lock.unlock();
        return Value.nil;
    };
    s.closed = true;
    var call: CloseCall = .{ .server = s, .waiting = s.users };
    s.users += 1;
    lock.unlock();
    sched.blocking(closeServerBlocking, &call);
    release(s);
    return Value.nil;
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const entries = [_]io.Entry{
    // (%net-timeout-class! class): skein.net's net-timeout condition class.
    .{ .name = "%net-timeout-class!", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!rooted.swap(true, .acq_rel)) @import("gc.zig").addRoots(&timeout_class);
            timeout_class[0] = a[0];
            return Value.nil;
        }
    }.f },
    .{ .name = "%net-connect", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return connect(a[0], a[1], a[2]);
        }
    }.f },
    // (%net-read-timeout! stream nanos): 0 for none.
    .{ .name = "%net-read-timeout!", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            if (!a[1].isFixnum() or a[1].toFixnum() < 0) rt.raise(.type_error, "a read timeout must be a number of nanoseconds", .{});
            files.setReadTimeout(a[0], @intCast(a[1].toFixnum()));
            return Value.nil;
        }
    }.f },
    .{ .name = "%net-shutdown", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            files.shutdownSocket(a[0]);
            return Value.nil;
        }
    }.f },
    .{ .name = "%net-listen", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return listen(a[0], a[1]);
        }
    }.f },
    .{ .name = "%net-accept", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return accept(a[0]);
        }
    }.f },
    .{ .name = "%net-port", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return Value.fromFixnum(serverPort(a[0]));
        }
    }.f },
    .{ .name = "%net-close-server", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return closeServer(a[0]);
        }
    }.f },
};
