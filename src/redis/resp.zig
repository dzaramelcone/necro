const std = @import("std");

pub const RespError = error{
    BufferOverflow,
    TooManyParts,
};

const MAX_PARTS = 16;

pub fn writeCommand(buf: []u8, cmd: []const u8, args: []const []const u8) RespError!usize {
    if (args.len + 1 > MAX_PARTS) return error.TooManyParts;

    var pos: usize = 0;

    if (pos >= buf.len) return error.BufferOverflow;
    buf[pos] = '*';
    pos += 1;
    const count_text = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{args.len + 1}) catch return error.BufferOverflow;
    pos += count_text.len;

    try writeBulk(buf, &pos, cmd);
    for (args) |arg| try writeBulk(buf, &pos, arg);

    return pos;
}

fn writeBulk(buf: []u8, pos: *usize, s: []const u8) RespError!void {
    if (pos.* >= buf.len) return error.BufferOverflow;
    buf[pos.*] = '$';
    pos.* += 1;
    const len_text = std.fmt.bufPrint(buf[pos.*..], "{d}\r\n", .{s.len}) catch return error.BufferOverflow;
    pos.* += len_text.len;
    if (pos.* + s.len + 2 > buf.len) return error.BufferOverflow;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
    buf[pos.*] = '\r';
    buf[pos.* + 1] = '\n';
    pos.* += 2;
}

test "writeCommand: GET with one arg" {
    var buf: [64]u8 = undefined;
    const n = try writeCommand(&buf, "GET", &[_][]const u8{"mykey"});
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n", buf[0..n]);
}

test "writeCommand: SET key value" {
    var buf: [64]u8 = undefined;
    const n = try writeCommand(&buf, "SET", &[_][]const u8{ "foo", "bar" });
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n", buf[0..n]);
}

test "writeCommand: PING with no args" {
    var buf: [32]u8 = undefined;
    const n = try writeCommand(&buf, "PING", &[_][]const u8{});
    try std.testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", buf[0..n]);
}

test "writeCommand: buffer overflow returns error" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.BufferOverflow, writeCommand(&buf, "GET", &[_][]const u8{"this_is_a_longer_key"}));
}

test "writeCommand: too many parts" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p" };
    try std.testing.expectError(error.TooManyParts, writeCommand(&buf, "CMD", args[0..]));
}

test "writeCommand: empty arg" {
    var buf: [32]u8 = undefined;
    const n = try writeCommand(&buf, "SET", &[_][]const u8{ "k", "" });
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n", buf[0..n]);
}
