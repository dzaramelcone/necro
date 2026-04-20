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

pub const ParseError = error{
    ProtocolError,
};

pub const Value = union(enum) {
    simple: []const u8,
    err: []const u8,
    integer: i64,
    null_val,
    bulk: []const u8,
};

pub const ParseResult = union(enum) {
    incomplete,
    message: struct {
        value: Value,
        consumed: usize,
    },
};

pub fn parseOne(data: []const u8) ParseError!ParseResult {
    if (data.len == 0) return .incomplete;

    const crlf_pos = std.mem.indexOf(u8, data, "\r\n") orelse return .incomplete;
    const line = data[1..crlf_pos];

    return switch (data[0]) {
        '+' => .{ .message = .{ .value = .{ .simple = line }, .consumed = crlf_pos + 2 } },
        '-' => .{ .message = .{ .value = .{ .err = line }, .consumed = crlf_pos + 2 } },
        ':' => .{ .message = .{
            .value = .{ .integer = std.fmt.parseInt(i64, line, 10) catch return error.ProtocolError },
            .consumed = crlf_pos + 2,
        } },
        '_' => .{ .message = .{ .value = .null_val, .consumed = crlf_pos + 2 } },
        '$' => blk: {
            const len_val = std.fmt.parseInt(i64, line, 10) catch return error.ProtocolError;
            if (len_val < 0) break :blk .{ .message = .{ .value = .null_val, .consumed = crlf_pos + 2 } };
            const payload_len: usize = @intCast(len_val);
            const total_needed = crlf_pos + 2 + payload_len + 2;
            if (data.len < total_needed) break :blk .incomplete;
            break :blk .{ .message = .{
                .value = .{ .bulk = data[crlf_pos + 2 ..][0..payload_len] },
                .consumed = total_needed,
            } };
        },
        else => error.ProtocolError,
    };
}

test "parseOne: simple string" {
    const result = try parseOne("+OK\r\n");
    try std.testing.expectEqualStrings("OK", result.message.value.simple);
    try std.testing.expectEqual(@as(usize, 5), result.message.consumed);
}

test "parseOne: error" {
    const result = try parseOne("-ERR bad\r\n");
    try std.testing.expectEqualStrings("ERR bad", result.message.value.err);
}

test "parseOne: integer" {
    const result = try parseOne(":42\r\n");
    try std.testing.expectEqual(@as(i64, 42), result.message.value.integer);
}

test "parseOne: null" {
    const result = try parseOne("_\r\n");
    try std.testing.expect(result.message.value == .null_val);
}

test "parseOne: bulk string" {
    const result = try parseOne("$5\r\nhello\r\n");
    try std.testing.expectEqualStrings("hello", result.message.value.bulk);
    try std.testing.expectEqual(@as(usize, 11), result.message.consumed);
}

test "parseOne: bulk string incomplete" {
    const result = try parseOne("$5\r\nhel");
    try std.testing.expect(result == .incomplete);
}

test "parseOne: negative bulk is null" {
    const result = try parseOne("$-1\r\n");
    try std.testing.expect(result.message.value == .null_val);
}

test "parseOne: empty data" {
    const result = try parseOne("");
    try std.testing.expect(result == .incomplete);
}

test "parseOne: no crlf yet" {
    const result = try parseOne("+OK");
    try std.testing.expect(result == .incomplete);
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
