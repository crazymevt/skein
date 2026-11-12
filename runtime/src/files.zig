//! skein.io's files, directories and streams natively (M2.11 step 7, D-093), matching
//! Phase 0 (host/src/runtime/io.lisp). lib/skein/io.skn wraps these and signals io-error;
//! they return nil or false on failure.
//!
//! A stream is a handle (a fixnum) to an open file, a pipe or a socket (D-106) and its
//! buffers, kept here outside the heap. Reads and writes keep their own offset. Each call that touches the file runs as a
//! blocking call (io.pathBlocking), on copies of its data made outside the heap, since
//! other threads may collect meanwhile.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const coll = @import("coll.zig");
const names = @import("names.zig");
const print = @import("print.zig");
const string = @import("string.zig");
const structs = @import("structs.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const alloc = std.heap.c_allocator;

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

fn copyPath(v: Value) []u8 {
    if (!string.isString(v)) rt.raise(.type_error, "a path must be a string, not {s}", .{readable(v)});
    return alloc.dupe(u8, string.bytes(v)) catch rt.fatal("out of memory", .{});
}

fn utf8(bytes: []const u8, comptime what: []const u8) Value {
    if (!std.unicode.utf8ValidateSlice(bytes)) rt.raise(.@"error", what ++ ": the text isn't UTF-8", .{});
    return string.make(bytes);
}

// ---------------------------------------------------------------------------------------
// Paths

const StatCall = struct { path: []const u8, stat: ?std.Io.File.Stat = null };

fn statBlocking(arg: ?*anyopaque) void {
    const c: *StatCall = @ptrCast(@alignCast(arg));
    c.stat = std.Io.Dir.cwd().statFile(io.stdIo(), c.path, .{}) catch null;
}

/// [kind size modified] for the file or directory at path (kind :file, :directory or
/// :other; modified in milliseconds since 1970), or nil if there's none.
fn stat(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: StatCall = .{ .path = p };
    io.pathBlocking(statBlocking, &call);
    const st = call.stat orelse return Value.nil;
    const kind = switch (st.kind) {
        .file => "file",
        .directory => "directory",
        else => "other",
    };
    const ms: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms));
    return coll.vectorOf(&.{ names.keyword(null, kind), Value.fromFixnum(@intCast(st.size)), Value.fromFixnum(ms) });
}

// ---------------------------------------------------------------------------------------
// Temporary files and owner-only permissions (M3.5, D-107)

const TempCall = struct { dir: []const u8, prefix: []const u8, suffix: []const u8, directory: bool, out: ?[]u8 = null };

fn tempBlocking(arg: ?*anyopaque) void {
    const c: *TempCall = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const letters = "abcdefghijklmnopqrstuvwxyz0123456789";
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var bytes: [12]u8 = undefined;
        sio.random(&bytes);
        var name: [12]u8 = undefined;
        for (bytes, 0..) |b, i| name[i] = letters[b % letters.len];
        const p = std.fmt.allocPrint(alloc, "{s}/{s}{s}{s}", .{ c.dir, c.prefix, name, c.suffix }) catch return;
        const cwd = std.Io.Dir.cwd();
        const made = if (c.directory)
            cwd.createDir(sio, p, platform.ownerOnlyPermissions(true))
        else if (cwd.createFile(sio, p, .{ .exclusive = true, .permissions = platform.ownerOnlyPermissions(false) })) |f|
            f.close(sio)
        else |err|
            err;
        made catch |err| {
            alloc.free(p);
            if (err == error.PathAlreadyExists) continue;
            return;
        };
        c.out = p;
        return;
    }
}

/// (%make-temp dir prefix suffix directory?): a new file (or directory), made only for
/// this call (exclusively) with owner-only permissions, named prefix, 12 random letters
/// and digits, and suffix, in dir; its path, or nil if it can't be made.
fn makeTemp(dir: Value, prefix: Value, suffix: Value, directory: bool) Value {
    const d = copyPath(dir);
    defer alloc.free(d);
    const pre = copyPath(prefix);
    defer alloc.free(pre);
    const suf = copyPath(suffix);
    defer alloc.free(suf);
    var call: TempCall = .{ .dir = d, .prefix = pre, .suffix = suf, .directory = directory };
    io.pathBlocking(tempBlocking, &call);
    const out = call.out orelse return Value.nil;
    defer alloc.free(out);
    return string.make(out);
}

const OwnerCall = struct { path: []const u8, ok: bool = false };

fn ownerOnlyBlocking(arg: ?*anyopaque) void {
    const c: *OwnerCall = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(sio, c.path, .{}) catch return;
    if (!platform.has_owner_only) {
        c.ok = true;
        return;
    }
    cwd.setFilePermissions(sio, c.path, platform.ownerOnlyPermissions(st.kind == .directory), .{}) catch return;
    c.ok = true;
}

/// (%owner-only path): make the file or directory only its owner's (modes 600 and 700;
/// nothing on Windows); false if it doesn't exist or can't be changed.
fn ownerOnly(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: OwnerCall = .{ .path = p };
    io.pathBlocking(ownerOnlyBlocking, &call);
    return Value.fromBool(call.ok);
}

/// (%permissions path): the file's mode bits (POSIX), or nil (Windows, or no file).
fn permissionsOf(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: StatCall = .{ .path = p };
    io.pathBlocking(statBlocking, &call);
    const st = call.stat orelse return Value.nil;
    const bits = platform.modeBits(st.permissions) orelse return Value.nil;
    return Value.fromFixnum(@intCast(bits));
}

const TwoPaths = struct { a: []const u8, b: []const u8 = "", ok: bool = false };

fn deleteBlocking(arg: ?*anyopaque) void {
    const c: *TwoPaths = @ptrCast(@alignCast(arg));
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io.stdIo(), c.a) catch {
        cwd.deleteDir(io.stdIo(), c.a) catch return;
    };
    c.ok = true;
}

fn renameBlocking(arg: ?*anyopaque) void {
    const c: *TwoPaths = @ptrCast(@alignCast(arg));
    const cwd = std.Io.Dir.cwd();
    cwd.rename(c.a, cwd, c.b, io.stdIo()) catch return;
    c.ok = true;
}

fn twoPaths(f: *const fn (?*anyopaque) void, a: Value, b: ?Value) Value {
    const pa = copyPath(a);
    defer alloc.free(pa);
    const pb = if (b) |v| copyPath(v) else "";
    defer if (b != null) alloc.free(pb);
    var call: TwoPaths = .{ .a = pa, .b = pb };
    io.pathBlocking(f, &call);
    return Value.fromBool(call.ok);
}

// ---------------------------------------------------------------------------------------
// Whole files as bytes

const ReadCall = struct { path: []const u8, data: ?[]u8 = null };

fn readBytesBlocking(arg: ?*anyopaque) void {
    const c: *ReadCall = @ptrCast(@alignCast(arg));
    c.data = std.Io.Dir.cwd().readFileAlloc(io.stdIo(), c.path, alloc, .unlimited) catch null;
}

/// The file's bytes, a u8 array, or nil.
fn readBytes(path: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: ReadCall = .{ .path = p };
    io.pathBlocking(readBytesBlocking, &call);
    const data = call.data orelse return Value.nil;
    defer alloc.free(data);
    const a = structs.makePrim(.u8, data.len);
    @memcpy(structs.bytesOf(a).?, data);
    return a;
}

const WriteCall = struct { path: []const u8, data: []const u8, append: bool, ok: bool = false };

fn writeBytesBlocking(arg: ?*anyopaque) void {
    const c: *WriteCall = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const file = std.Io.Dir.cwd().createFile(sio, c.path, .{ .truncate = !c.append }) catch return;
    defer file.close(sio);
    const at = if (c.append) file.length(sio) catch return else 0;
    file.writePositionalAll(sio, c.data, at) catch return;
    c.ok = true;
}

/// Write the bytes of data (a string, a u8 array or a byte view) to the file, replacing
/// it or after what it holds; false if it can't be written.
fn writeBytes(path: Value, data: Value, append: bool) Value {
    const d = alloc.dupe(u8, dataBytes(data, "write-bytes")) catch rt.fatal("out of memory", .{});
    defer alloc.free(d);
    const p = copyPath(path);
    defer alloc.free(p);
    var call: WriteCall = .{ .path = p, .data = d, .append = append };
    io.pathBlocking(writeBytesBlocking, &call);
    return Value.fromBool(call.ok);
}

fn dataBytes(data: Value, comptime what: []const u8) []const u8 {
    if (string.isString(data)) return string.bytes(data);
    return structs.bytesOf(data) orelse
        rt.raise(.type_error, what ++ " needs a string, a u8 array or a byte view, not {s}", .{readable(data)});
}

// ---------------------------------------------------------------------------------------
// Streams

const Stream = struct {
    file: std.Io.File,
    /// The offset of the next read, or of the next write once the buffer is flushed.
    offset: u64,
    /// Read: bytes buf[start..end] are read but not yet taken.
    buf: [16384]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    /// Write: bytes not yet written.
    pending: std.ArrayList(u8) = .empty,
    failed: bool = false,
    /// A pipe (a process's stdin, stdout or stderr, D-103): read and written in sequence,
    /// with no offset.
    pipe: bool = false,
    /// A pipe whose descriptor is closed already: at its end, or a program's stdin once
    /// the program has ended. Reads give the end; writes fail; close frees the rest.
    released: bool = false,
    /// Which stream it is, as its handle (a table slot, reused once closed) can't say.
    serial: u64 = 0,
    /// A TCP socket (net.zig, D-106): read and written in sequence, through the socket's
    /// calls; `file` is unused.
    sock: ?std.Io.net.Stream = null,
    /// A socket's limit on each read, in nanoseconds (0: none). A read that runs out sets
    /// timed_out, and the reading function signals net-timeout.
    read_timeout: u64 = 0,
    timed_out: bool = false,
    /// A socket this side has shut down: a read's error is its end (Windows fails reads
    /// after shutdown where POSIX returns the end).
    shut: bool = false,
    /// Why a read or write failed: the system's error's name, for the error message.
    why: []const u8 = "",
    /// What read-line or read-text had gathered when a read timed out, which the next
    /// read starts with, so a timeout loses nothing.
    carry: std.ArrayList(u8) = .empty,
};

var serials = std.atomic.Value(u64).init(1);

var lock: platform.Mutex = .{};
var table: std.ArrayList(?*Stream) = .empty;

fn streamOf(h: Value) *Stream {
    // The lock is released before raising: a raise unwinds past defer.
    lock.lock();
    var found: ?*Stream = null;
    if (h.isFixnum()) {
        const i = h.toFixnum();
        if (i >= 1 and i <= table.items.len) found = table.items[@intCast(i - 1)];
    }
    lock.unlock();
    return found orelse rt.raise(.@"error", "the stream is closed", .{});
}

const OpenCall = struct { path: []const u8, mode: i64, file: ?std.Io.File = null, offset: u64 = 0 };

fn openBlocking(arg: ?*anyopaque) void {
    const c: *OpenCall = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const cwd = std.Io.Dir.cwd();
    c.file = switch (c.mode) {
        0 => cwd.openFile(sio, c.path, .{}) catch return,
        else => cwd.createFile(sio, c.path, .{ .truncate = c.mode == 1 }) catch return,
    };
    if (c.mode == 2) c.offset = c.file.?.length(sio) catch 0;
}

/// (%open-stream path mode): a handle, or nil if the file can't be opened. Mode 0 reads,
/// 1 writes (replacing the file), 2 appends.
fn open(path: Value, mode: Value) Value {
    const p = copyPath(path);
    defer alloc.free(p);
    var call: OpenCall = .{ .path = p, .mode = mode.toFixnum() };
    io.pathBlocking(openBlocking, &call);
    const file = call.file orelse return Value.nil;
    const s = alloc.create(Stream) catch rt.fatal("out of memory", .{});
    s.* = .{ .file = file, .offset = call.offset };
    return register(s);
}

/// A stream handle for a process's pipe (process.zig, D-103), which the stream now owns,
/// and its serial number, for releasePipe.
pub fn registerPipe(file: std.Io.File) struct { Value, u64 } {
    const s = alloc.create(Stream) catch rt.fatal("out of memory", .{});
    s.* = .{ .file = file, .offset = 0, .pipe = true };
    const h = register(s);
    return .{ h, s.serial };
}

/// A stream handle for a connected socket (net.zig, D-106), which the stream now owns.
pub fn registerSocket(sock: std.Io.net.Stream) Value {
    const s = alloc.create(Stream) catch rt.fatal("out of memory", .{});
    s.* = .{ .file = undefined, .offset = 0, .sock = sock };
    return register(s);
}

const ShutdownCall = struct { sock: std.Io.net.Stream };

fn shutdownBlocking(arg: ?*anyopaque) void {
    const c: *ShutdownCall = @ptrCast(@alignCast(arg));
    c.sock.shutdown(io.stdIo(), .both) catch {};
}

/// End the socket stream h's connection both ways, so a read waiting on it (in another
/// fiber) gets the end of the stream; the stream stays open until it's closed.
pub fn shutdownSocket(h: Value) void {
    const s = streamOf(h);
    var call: ShutdownCall = .{ .sock = s.sock orelse rt.raise(.@"error", "the stream isn't a socket", .{}) };
    s.shut = true;
    @import("sched.zig").blocking(shutdownBlocking, &call);
}

/// Set the socket stream h's limit on each read, in nanoseconds (0: none).
pub fn setReadTimeout(h: Value, nanos: u64) void {
    const s = streamOf(h);
    if (s.sock == null) rt.raise(.@"error", "the stream isn't a socket", .{});
    s.read_timeout = nanos;
}

fn register(s: *Stream) Value {
    s.serial = serials.fetchAdd(1, .monotonic);
    lock.lock();
    defer lock.unlock();
    for (table.items, 0..) |slot, i| {
        if (slot == null) {
            table.items[i] = s;
            return Value.fromFixnum(@intCast(i + 1));
        }
    }
    table.append(alloc, s) catch rt.fatal("out of memory", .{});
    return Value.fromFixnum(@intCast(table.items.len));
}

/// Read from a socket into its buffer: how many bytes (0 at its end), waiting at most its
/// read timeout. A read that times out is cancelled, unless it finished meanwhile.
fn readSocket(s: *Stream) !usize {
    const sio = io.stdIo();
    var bufs = [_][]u8{s.buf[0..]};
    const op: std.Io.Operation = .{ .net_read = .{ .socket_handle = s.sock.?.socket.handle, .data = &bufs } };
    if (s.read_timeout == 0) return (try (try sio.operate(op)).net_read).data_len;
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    batch.addAt(0, op);
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@intCast(s.read_timeout)), .clock = .awake } };
    batch.awaitConcurrent(sio, timeout) catch |err| switch (err) {
        error.Timeout => {
            batch.cancel(sio);
            const done = batch.next() orelse return error.Timeout;
            return (try done.result.net_read).data_len;
        },
        else => |e| return e,
    };
    return (try batch.next().?.result.net_read).data_len;
}

fn fillSocketBlocking(arg: ?*anyopaque) void {
    const s: *Stream = @ptrCast(@alignCast(arg));
    const n = readSocket(s) catch |err| {
        if (err == error.Timeout) {
            s.timed_out = true;
            return;
        }
        if (!s.shut) {
            s.failed = true;
            s.why = @errorName(err);
        }
        s.eof = true;
        return;
    };
    s.start = 0;
    s.end = n;
    if (n == 0) s.eof = true;
}

fn fillBlocking(arg: ?*anyopaque) void {
    const s: *Stream = @ptrCast(@alignCast(arg));
    const sio = io.stdIo();
    const n = (if (s.pipe)
        s.file.readStreaming(sio, &.{s.buf[0..]})
    else
        s.file.readPositional(sio, &.{s.buf[0..]}, s.offset)) catch |err| {
        // A pipe's end, when the program closes its side, is the end of the stream.
        if (err != error.EndOfStream) s.failed = true;
        s.eof = true;
        releaseBlocking(s);
        return;
    };
    s.start = 0;
    s.end = n;
    s.offset += n;
    if (n == 0) {
        s.eof = true;
        releaseBlocking(s);
    }
}

/// At a pipe's end, close its descriptor at once rather than when the stream is closed:
/// so a program's output that is read to its end holds no descriptor.
fn releaseBlocking(s: *Stream) void {
    if (!s.pipe or s.released) return;
    s.file.close(io.stdIo());
    s.released = true;
}

/// Release the pipe stream `h` if it is still the stream `serial` (a program's stdin once
/// the program has ended, process.zig): what it holds unwritten is dropped, and writes
/// fail from now on. A stream closed meanwhile is left alone, whatever took its slot.
pub fn releasePipe(h: Value, serial: u64) void {
    lock.lock();
    var found: ?*Stream = null;
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= table.items.len)
        found = table.items[@intCast(h.toFixnum() - 1)];
    if (found) |s| if (s.serial != serial) {
        found = null;
    };
    lock.unlock();
    const s = found orelse return;
    if (!s.pipe or s.released) return;
    s.pending.clearRetainingCapacity();
    s.eof = true;
    releaseBlocking(s);
}

/// Refill an empty read buffer; false at the end of the file. A socket's read that times
/// out signals net-timeout, after `keep` (what the caller had gathered) is put by for the
/// next read.
fn fill(s: *Stream, keep: ?*std.ArrayList(u8)) bool {
    if (s.start < s.end) return true;
    if (s.eof) return false;
    if (s.sock != null) {
        // A socket's calls touch no paths, so they needn't run on a thread of their own.
        @import("sched.zig").blocking(fillSocketBlocking, s);
        if (s.timed_out) {
            s.timed_out = false;
            if (keep) |k| {
                s.carry.clearRetainingCapacity();
                s.carry.appendSlice(alloc, k.items) catch rt.fatal("out of memory", .{});
            }
            @import("net.zig").raiseTimeout(s.read_timeout);
        }
    } else io.pathBlocking(fillBlocking, s);
    return s.start < s.end;
}

/// Start `out` with what a timed-out read had gathered, if anything.
fn takeCarry(s: *Stream, out: *std.ArrayList(u8)) bool {
    if (s.carry.items.len == 0) return false;
    out.appendSlice(alloc, s.carry.items) catch rt.fatal("out of memory", .{});
    s.carry.clearRetainingCapacity();
    return true;
}

fn checkFailed(s: *Stream) void {
    if (s.failed) {
        if (s.why.len > 0) rt.raise(.@"error", "the stream couldn't be read or written ({s})", .{s.why});
        rt.raise(.@"error", "the stream couldn't be read or written", .{});
    }
}

/// The next line (without its newline, or a \r before it), or nil at the end.
fn readLine(h: Value) Value {
    const s = streamOf(h);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var any = takeCarry(s, &line);
    while (fill(s, &line)) {
        any = true;
        const chunk = s.buf[s.start..s.end];
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |i| {
            line.appendSlice(alloc, chunk[0..i]) catch rt.fatal("out of memory", .{});
            s.start += i + 1;
            if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') line.items.len -= 1;
            return utf8(line.items, "read-line");
        }
        line.appendSlice(alloc, chunk) catch rt.fatal("out of memory", .{});
        s.start = s.end;
    }
    checkFailed(s);
    if (!any) return Value.nil;
    return utf8(line.items, "read-line");
}

/// The rest of the stream, a string ("" at the end).
fn readRest(h: Value) Value {
    const s = streamOf(h);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    _ = takeCarry(s, &text);
    while (fill(s, &text)) {
        text.appendSlice(alloc, s.buf[s.start..s.end]) catch rt.fatal("out of memory", .{});
        s.start = s.end;
    }
    checkFailed(s);
    return utf8(text.items, "read-text");
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

/// The text that has arrived (a non-empty string), waiting for some; nil at the end. A
/// character split between two reads waits for its rest (skein dev's REPL server reads a
/// client this way, D-106).
fn readSome(h: Value) Value {
    const s = streamOf(h);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    _ = takeCarry(s, &text);
    while (true) {
        const keep = completeLength(text.items);
        if (keep > 0) {
            s.carry.appendSlice(alloc, text.items[keep..]) catch rt.fatal("out of memory", .{});
            return utf8(text.items[0..keep], "read");
        }
        if (!fill(s, &text)) {
            checkFailed(s);
            // What's left of a split character at the end isn't text.
            return Value.nil;
        }
        text.appendSlice(alloc, s.buf[s.start..s.end]) catch rt.fatal("out of memory", .{});
        s.start = s.end;
    }
}

/// Read up to n bytes into array from index start; how many, or nil at the end.
fn readInto(h: Value, array: Value, start: Value, n: Value) Value {
    const s = streamOf(h);
    const len = (structs.bytesOf(array) orelse rt.raise(.type_error, "read-bytes! needs a u8 array or a byte view, not {s}", .{readable(array)})).len;
    if (!start.isFixnum() or !n.isFixnum() or start.toFixnum() < 0 or n.toFixnum() < 0 or
        @as(usize, @intCast(start.toFixnum() + n.toFixnum())) > len)
        rt.raise(.index_error, "read-bytes! of {s} bytes from {s} doesn't fit the array of {d}", .{ readable(n), readable(start), len });
    const at: usize = @intCast(start.toFixnum());
    const want: usize = @intCast(n.toFixnum());
    if (want == 0) return Value.fromFixnum(0);
    if (s.carry.items.len > 0) {
        // Bytes a timed-out read-line had gathered come first.
        const got = @min(want, s.carry.items.len);
        @memcpy(structs.bytesOf(array).?[at .. at + got], s.carry.items[0..got]);
        s.carry.replaceRange(alloc, 0, got, &.{}) catch rt.fatal("out of memory", .{});
        return Value.fromFixnum(@intCast(got));
    }
    if (!fill(s, null)) {
        checkFailed(s);
        return Value.nil;
    }
    const got = @min(want, s.end - s.start);
    // The array's address is taken after the blocking fill, which may let it move.
    @memcpy(structs.bytesOf(array).?[at .. at + got], s.buf[s.start .. s.start + got]);
    s.start += got;
    return Value.fromFixnum(@intCast(got));
}

fn flushBlocking(arg: ?*anyopaque) void {
    const s: *Stream = @ptrCast(@alignCast(arg));
    if (s.released) {
        // Its program has ended: nothing reads it.
        s.failed = true;
        return;
    }
    if (s.sock) |sock| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.net.Stream.Writer.init(sock, io.stdIo(), &buf);
        w.interface.writeAll(s.pending.items) catch {
            s.failed = true;
            s.why = if (w.err) |e| @errorName(e) else "the write failed";
            return;
        };
        w.interface.flush() catch {
            s.failed = true;
            s.why = if (w.err) |e| @errorName(e) else "the write failed";
            return;
        };
        s.pending.clearRetainingCapacity();
        return;
    }
    // A pipe whose reader has gone fails (the runtime ignores SIGPIPE, process.zig).
    (if (s.pipe)
        s.file.writeStreamingAll(io.stdIo(), s.pending.items)
    else
        s.file.writePositionalAll(io.stdIo(), s.pending.items, s.offset)) catch {
        s.failed = true;
        return;
    };
    s.offset += s.pending.items.len;
    s.pending.clearRetainingCapacity();
}

fn flush(s: *Stream) void {
    if (s.pending.items.len > 0) {
        if (s.sock != null) @import("sched.zig").blocking(flushBlocking, s) else io.pathBlocking(flushBlocking, s);
    }
    checkFailed(s);
}

/// Write data (a string, a u8 array or a byte view) from byte start to end.
fn write(h: Value, data: Value, start: Value, end: Value) Value {
    const s = streamOf(h);
    const bytes = dataBytes(data, "write");
    const from: usize = if (start == Value.nil) 0 else @intCast(@max(start.toFixnum(), 0));
    const to: usize = if (end == Value.nil) bytes.len else @intCast(@max(end.toFixnum(), 0));
    if (from > to or to > bytes.len) rt.raise(.index_error, "write of bytes {d} to {d} of {d}", .{ from, to, bytes.len });
    s.pending.appendSlice(alloc, bytes[from..to]) catch rt.fatal("out of memory", .{});
    if (s.pending.items.len >= 65536) flush(s);
    return Value.nil;
}

fn closeBlocking(arg: ?*anyopaque) void {
    const s: *Stream = @ptrCast(@alignCast(arg));
    if (s.released) return;
    if (s.pending.items.len > 0) flushBlocking(s);
    if (s.sock) |sock| sock.close(io.stdIo()) else s.file.close(io.stdIo());
}

/// Flush and close; closing a closed stream does nothing.
fn close(h: Value) Value {
    lock.lock();
    var s: ?*Stream = null;
    if (h.isFixnum() and h.toFixnum() >= 1 and h.toFixnum() <= table.items.len) {
        const i: usize = @intCast(h.toFixnum() - 1);
        s = table.items[i];
        table.items[i] = null;
    }
    lock.unlock();
    const stream = s orelse return Value.nil;
    io.pathBlocking(closeBlocking, stream);
    const failed = stream.failed;
    stream.pending.deinit(alloc);
    stream.carry.deinit(alloc);
    alloc.destroy(stream);
    if (failed) rt.raise(.@"error", "the stream couldn't be written", .{});
    return Value.nil;
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;
const Entry = io.Entry;

/// C's struct tm: the nine fields every C library has first, then room for the rest.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    rest: [4]i64 = undefined,
};

extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
extern "c" fn gmtime_r(t: *const i64, out: *Tm) ?*Tm;
extern "c" fn _localtime64_s(out: *Tm, t: *const i64) c_int;
extern "c" fn _gmtime64_s(out: *Tm, t: *const i64) c_int;

fn utcOffset(seconds: i64) i64 {
    var local: Tm = undefined;
    var utc: Tm = undefined;
    if (@import("builtin").os.tag == .windows) {
        if (_localtime64_s(&local, &seconds) != 0 or _gmtime64_s(&utc, &seconds) != 0) return 0;
    } else {
        if (localtime_r(&seconds, &local) == null or gmtime_r(&seconds, &utc) == null) return 0;
    }
    const days: i64 = if (local.year == utc.year) local.yday - utc.yday else if (local.year > utc.year) 1 else -1;
    return days * 86400 + (@as(i64, local.hour) - utc.hour) * 3600 + (@as(i64, local.min) - utc.min) * 60 +
        (@as(i64, local.sec) - utc.sec);
}

pub const entries = [_]Entry{
    // (%write-stderr text): skein.log's default handler.
    .{ .name = "%write-stderr", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!string.isString(a[0])) rt.raise(.type_error, "%write-stderr needs a string", .{});
            platform.writeStderr(string.bytes(a[0]));
            return Value.nil;
        }
    }.f },
    // (%epoch-millis): wall-clock time, milliseconds since 1970 (skein.log's times).
    .{ .name = "%epoch-millis", .min = 0, .max = 0, .impl = struct {
        fn f(_: Args) Value {
            const t = std.Io.Clock.real.now(io.stdIo());
            return Value.fromFixnum(@intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms)));
        }
    }.f },
    // (%utc-offset millis): the local time zone's offset from UTC at that time, in
    // seconds east (skein.time/local-time): the local and UTC calendar times, compared.
    .{ .name = "%utc-offset", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            if (!a[0].isFixnum()) rt.raise(.type_error, "%utc-offset needs a time in milliseconds", .{});
            return Value.fromFixnum(utcOffset(@divFloor(a[0].toFixnum(), 1000)));
        }
    }.f },
    .{ .name = "%stat", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return stat(a[0]);
        }
    }.f },
    .{ .name = "%delete-path", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return twoPaths(deleteBlocking, a[0], null);
        }
    }.f },
    .{ .name = "%rename-path", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            return twoPaths(renameBlocking, a[0], a[1]);
        }
    }.f },
    .{ .name = "%read-bytes", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readBytes(a[0]);
        }
    }.f },
    // (%write-bytes path data append?)
    .{ .name = "%write-bytes", .min = 3, .max = 3, .impl = struct {
        fn f(a: Args) Value {
            return writeBytes(a[0], a[1], a[2] != Value.nil and a[2] != Value.false);
        }
    }.f },
    // (%open-default target): Windows' ShellExecuteW (skein.system/open!, D-107).
    .{ .name = "%open-default", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            const t = copyPath(a[0]);
            defer alloc.free(t);
            const Call = struct {
                t: []const u8,
                ok: bool = false,
                fn run(arg: ?*anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(arg));
                    c.ok = platform.openWithDefault(c.t);
                }
            };
            var call: Call = .{ .t = t };
            io.pathBlocking(Call.run, &call);
            return Value.fromBool(call.ok);
        }
    }.f },
    .{ .name = "%make-temp", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return makeTemp(a[0], a[1], a[2], a[3] != Value.nil and a[3] != Value.false);
        }
    }.f },
    .{ .name = "%owner-only", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return ownerOnly(a[0]);
        }
    }.f },
    .{ .name = "%permissions", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return permissionsOf(a[0]);
        }
    }.f },
    .{ .name = "%open-stream", .min = 2, .max = 2, .impl = struct {
        fn f(a: Args) Value {
            if (!a[1].isFixnum() or a[1].toFixnum() < 0 or a[1].toFixnum() > 2) rt.raise(.@"error", "%open-stream's mode is 0, 1 or 2", .{});
            return open(a[0], a[1]);
        }
    }.f },
    .{ .name = "%stream-read-line", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readLine(a[0]);
        }
    }.f },
    .{ .name = "%stream-read-some", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readSome(a[0]);
        }
    }.f },
    .{ .name = "%stream-read-rest", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return readRest(a[0]);
        }
    }.f },
    .{ .name = "%stream-read-bytes", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return readInto(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "%stream-write", .min = 4, .max = 4, .impl = struct {
        fn f(a: Args) Value {
            return write(a[0], a[1], a[2], a[3]);
        }
    }.f },
    .{ .name = "%stream-flush", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            flush(streamOf(a[0]));
            return Value.nil;
        }
    }.f },
    .{ .name = "%stream-close", .min = 1, .max = 1, .impl = struct {
        fn f(a: Args) Value {
            return close(a[0]);
        }
    }.f },
};
