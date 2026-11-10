//! Tests of what the REPL and skein dev need from the runtime (devio.zig, M2.6): file
//! dates, the localhost server, and reading text a UTF-8 sequence at a time.

const std = @import("std");
const coll = @import("coll.zig");
const core = @import("core.zig");
const func = @import("func.zig");
const string = @import("string.zig");
const io = @import("io.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;

fn call(name: []const u8, args: []const Value) Value {
    return func.call(core.function(name).?, @intCast(args.len), args.ptr);
}

test "a file's modification date, and nil for none" {
    coll.ensureConstants();
    _ = call("%write-file", &.{ string.make(".skein-devio-test"), string.make("x") });
    defer std.Io.Dir.cwd().deleteFile(io.stdIo(), ".skein-devio-test") catch {};
    const t = call("%file-mtime", &.{string.make(".skein-devio-test")});
    try testing.expect(t.isFixnum() and t.toFixnum() > 0);
    try testing.expectEqual(Value.nil, call("%file-mtime", &.{string.make(".no-such-file-here")}));
}

test "the server accepts a connection on localhost and reads and writes text" {
    coll.ensureConstants();
    const server = call("%tcp-listen", &.{Value.fromFixnum(0)});
    try testing.expect(server.isFixnum());
    const port: u16 = @intCast(call("%tcp-port", &.{server}).toFixnum());
    try testing.expect(port != 0);
    // A client, on this thread: connect, then send text whose "é" is split by the read
    // size the server can't control; the server reads whole characters.
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    const client = try address.connect(io.stdIo(), .{ .mode = .stream });
    defer client.close(io.stdIo());
    const conn = call("%tcp-accept", &.{server});
    var wbuf: [64]u8 = undefined;
    var w = std.Io.net.Stream.Writer.init(client, io.stdIo(), &wbuf);
    try w.interface.writeAll("(+ 1 2) ; caf\xc3");
    try w.interface.flush();
    const first = call("%read-text", &.{conn});
    try testing.expectEqualStrings("(+ 1 2) ; caf", string.bytes(first));
    try w.interface.writeAll("\xa9\n");
    try w.interface.flush();
    try testing.expectEqualStrings("\xc3\xa9\n", string.bytes(call("%read-text", &.{conn})));
    try testing.expectEqual(Value.true, call("%write-text", &.{ conn, string.make("3\n") }));
    var rbuf: [16]u8 = undefined;
    var bufs = [_][]u8{&rbuf};
    const n = try client.read(io.stdIo(), &bufs);
    try testing.expectEqualStrings("3\n", rbuf[0..n]);
    _ = call("%tcp-close", &.{conn});
    _ = call("%tcp-close", &.{server});
}

test "Swank's framing counts and splits UTF-8 bytes" {
    coll.ensureConstants();
    const s = string.make("caf\xc3\xa9!");
    try testing.expectEqual(@as(i64, 6), call("%utf8-length", &.{s}).toFixnum());
    const parts = call("%utf8-split", &.{ s, Value.fromFixnum(5) });
    try testing.expectEqualStrings("caf\xc3\xa9", string.bytes(coll.vectorNth(parts, 0).?));
    try testing.expectEqualStrings("!", string.bytes(coll.vectorNth(parts, 1).?));
    try testing.expectEqual(Value.nil, call("%utf8-split", &.{ s, Value.fromFixnum(7) }));
}

test "an existing file's absolute path, and nil for none" {
    coll.ensureConstants();
    _ = call("%write-file", &.{ string.make(".skein-devio-abs"), string.make("x") });
    defer std.Io.Dir.cwd().deleteFile(io.stdIo(), ".skein-devio-abs") catch {};
    const p = string.bytes(call("%absolute-path", &.{string.make(".skein-devio-abs")}));
    try testing.expect(std.fs.path.isAbsolute(p));
    try testing.expect(std.mem.endsWith(u8, p, ".skein-devio-abs"));
    try testing.expectEqual(Value.nil, call("%absolute-path", &.{string.make(".no-such-file-here")}));
}
