//! skein.io's files, directories and streams natively (M2.11 step 7, D-093), matching
//! Phase 0 (host/src/runtime/io.lisp). lib/skein/io.skn wraps these and signals io-error;
//! they return nil or false on failure.
//!
//! A stream is a handle (a fixnum) to an open file and its buffers, kept here outside the
//! heap. Reads and writes keep their own offset. Each call that touches the file runs as a
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
};

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

/// A stream handle for a process's pipe (process.zig, D-103), which the stream now owns.
pub fn registerPipe(file: std.Io.File) Value {
    const s = alloc.create(Stream) catch rt.fatal("out of memory", .{});
    s.* = .{ .file = file, .offset = 0, .pipe = true };
    return register(s);
}

fn register(s: *Stream) Value {
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
        return;
    };
    s.start = 0;
    s.end = n;
    s.offset += n;
    if (n == 0) s.eof = true;
}

/// Refill an empty read buffer; false at the end of the file.
fn fill(s: *Stream) bool {
    if (s.start < s.end) return true;
    if (s.eof) return false;
    io.pathBlocking(fillBlocking, s);
    return s.start < s.end;
}

fn checkFailed(s: *Stream) void {
    if (s.failed) rt.raise(.@"error", "the stream couldn't be read or written", .{});
}

/// The next line (without its newline, or a \r before it), or nil at the end.
fn readLine(h: Value) Value {
    const s = streamOf(h);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var any = false;
    while (fill(s)) {
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
    while (fill(s)) {
        text.appendSlice(alloc, s.buf[s.start..s.end]) catch rt.fatal("out of memory", .{});
        s.start = s.end;
    }
    checkFailed(s);
    return utf8(text.items, "read-text");
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
    if (!fill(s)) {
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
    if (s.pending.items.len > 0) io.pathBlocking(flushBlocking, s);
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
    if (s.pending.items.len > 0) flushBlocking(s);
    s.file.close(io.stdIo());
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
