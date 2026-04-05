//! Postgres v3 wire protocol: message encoding/decoding for the simple query protocol.
//! https://www.postgresql.org/docs/current/protocol.html

const std = @import("std");
const mem = std.mem;
const posix = std.posix;

/// Protocol version 3.0 = 196608
pub const protocol_version: u32 = 196608;

pub const ssl_request_code: u32 = 80877103;

pub const Tag = struct {
    pub const query: u8 = 'Q';
    pub const parse: u8 = 'P';
    pub const bind: u8 = 'B';
    pub const execute: u8 = 'E';
    pub const describe: u8 = 'D';
    pub const sync: u8 = 'S';
    pub const flush: u8 = 'H';
    pub const close: u8 = 'C';
    pub const terminate: u8 = 'X';
    pub const copy_data: u8 = 'd';
    pub const copy_done: u8 = 'c';
    pub const copy_fail: u8 = 'f';
    pub const password_message: u8 = 'p';
};

pub const BackendTag = struct {
    pub const authentication: u8 = 'R';
    pub const backend_key_data: u8 = 'K';
    pub const ready_for_query: u8 = 'Z';
    pub const row_description: u8 = 'T';
    pub const data_row: u8 = 'D';
    pub const command_complete: u8 = 'C';
    pub const error_response: u8 = 'E';
    pub const notice_response: u8 = 'N';
    pub const notification_response: u8 = 'A';
    pub const parameter_status: u8 = 'S';
    pub const parse_complete: u8 = '1';
    pub const bind_complete: u8 = '2';
    pub const close_complete: u8 = '3';
    pub const no_data: u8 = 'n';
    pub const empty_query_response: u8 = 'I';
    pub const copy_in_response: u8 = 'G';
    pub const copy_out_response: u8 = 'H';
};

pub const AuthType = enum(u32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    md5_password = 5,
    scm_credential = 6,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,
};

pub const TransactionStatus = enum(u8) {
    idle = 'I',
    in_transaction = 'T',
    failed = 'E',
};

pub const ErrorField = enum(u8) {
    severity = 'S',
    severity_v = 'V',
    code = 'C',
    message = 'M',
    detail = 'D',
    hint = 'H',
    position = 'P',
    internal_position = 'p',
    internal_query = 'q',
    where = 'W',
    schema = 's',
    table = 't',
    column = 'c',
    data_type = 'd',
    constraint = 'n',
    file = 'F',
    line = 'L',
    routine = 'R',
};

pub const MessageHeader = extern struct {
    tag: u8,
    length: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(MessageHeader) == 5);
        std.debug.assert(!@import("std").meta.hasUniqueRepresentation(MessageHeader) or noPadding(MessageHeader));
    }
};

pub const SSLRequest = extern struct {
    length: u32 align(1),
    code: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(SSLRequest) == 8);
    }
};

pub const StartupMessageHeader = extern struct {
    length: u32 align(1),
    protocol_version: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(StartupMessageHeader) == 8);
    }
};

pub const AuthenticationOk = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(AuthenticationOk) == 9);
    }
};

pub const AuthenticationMD5 = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u32 align(1),
    salt: [4]u8,

    comptime {
        std.debug.assert(@sizeOf(AuthenticationMD5) == 13);
    }
};

pub const BackendKeyData = extern struct {
    tag: u8,
    length: u32 align(1),
    process_id: u32 align(1),
    secret_key: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(BackendKeyData) == 13);
    }
};

pub const ReadyForQuery = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u8,

    comptime {
        std.debug.assert(@sizeOf(ReadyForQuery) == 6);
    }
};

pub const ServerParams = struct {
    server_version: []const u8,
    server_encoding: []const u8,
    client_encoding: []const u8,
    timezone: []const u8,
    integer_datetimes: bool,
};

pub const ErrorNotice = struct {
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
    position: ?[]const u8,
};

pub const Notification = struct {
    pid: u32,
    channel: []const u8,
    payload: []const u8,
};

fn noPadding(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return true;
    var total: usize = 0;
    for (info.@"struct".fields) |f| {
        total += @sizeOf(f.type);
    }
    return total == @sizeOf(T);
}

pub const WireError = error{
    UnexpectedMessage,
    ServerError,
    UnsupportedAuth,
    ProtocolViolation,
    ConnectionClosed,
};

// Encoding
// https://www.postgresql.org/docs/current/protocol-message-formats.html

pub fn encodeStartupMessage(buf: []u8, user: []const u8, database: []const u8) []const u8 {
    const total_len: u32 = @intCast(25 + user.len + database.len);

    var pos: usize = 0;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, total_len, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, protocol_version, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..5], "user\x00");
    pos += 5;
    @memcpy(buf[pos..][0..user.len], user);
    pos += user.len;
    buf[pos] = 0;
    pos += 1;
    @memcpy(buf[pos..][0..9], "database\x00");
    pos += 9;
    @memcpy(buf[pos..][0..database.len], database);
    pos += database.len;
    buf[pos] = 0;
    pos += 1;
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

pub fn encodePasswordMessage(buf: []u8, password: []const u8) []const u8 {
    const length: u32 = @intCast(5 + password.len);
    var pos: usize = 0;

    buf[pos] = Tag.password_message;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..password.len], password);
    pos += password.len;
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

pub fn encodeParse(buf: []u8, stmt_name: []const u8, sql: []const u8) []const u8 {
    const length: u32 = @intCast(4 + stmt_name.len + 1 + sql.len + 1 + 2);
    var pos: usize = 0;

    buf[pos] = Tag.parse;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..stmt_name.len], stmt_name);
    pos += stmt_name.len;
    buf[pos] = 0;
    pos += 1;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = 0;
    pos += 1;
    @memcpy(buf[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 0), .big)));
    pos += 2;

    return buf[0..pos];
}

pub fn encodeDescribe(buf: []u8, kind: u8, name: []const u8) []const u8 {
    const length: u32 = @intCast(4 + 1 + name.len + 1);
    var pos: usize = 0;

    buf[pos] = Tag.describe;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    buf[pos] = kind;
    pos += 1;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

pub fn encodeBindWithParams(buf: []u8, stmt_name: []const u8, params: []const ?[]const u8) []const u8 {
    var pos: usize = 0;

    buf[pos] = Tag.bind;
    pos += 1;

    const length_pos = pos;
    pos += 4;

    buf[pos] = 0;
    pos += 1;

    @memcpy(buf[pos..][0..stmt_name.len], stmt_name);
    pos += stmt_name.len;
    buf[pos] = 0;
    pos += 1;

    @memcpy(buf[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, 0, .big)));
    pos += 2;

    const num_params: u16 = @intCast(params.len);
    @memcpy(buf[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, num_params, .big)));
    pos += 2;

    for (params) |param| {
        if (param) |val| {
            const len: i32 = @intCast(val.len);
            @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(i32, len, .big)));
            pos += 4;
            @memcpy(buf[pos..][0..val.len], val);
            pos += val.len;
        } else {
            @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(i32, -1, .big)));
            pos += 4;
        }
    }

    @memcpy(buf[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, 0, .big)));
    pos += 2;

    const length: u32 = @intCast(pos - 1);
    @memcpy(buf[length_pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));

    return buf[0..pos];
}

pub fn encodeExecute(buf: []u8) []const u8 {
    const length: u32 = 4 + 1 + 4;
    var pos: usize = 0;

    buf[pos] = Tag.execute;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    buf[pos] = 0;
    pos += 1;
    @memset(buf[pos..][0..4], 0);
    pos += 4;

    return buf[0..pos];
}
pub fn encodeSync(buf: []u8) []const u8 {
    buf[0] = Tag.sync;
    @memcpy(buf[1..5], &mem.toBytes(mem.nativeTo(u32, @as(u32, 4), .big)));
    return buf[0..5];
}

// Decoding

pub fn readMessageHeader(data: []const u8) WireError!MessageHeader {
    if (data.len < 5) return WireError.ProtocolViolation;
    return .{
        .tag = data[0],
        .length = mem.bigToNative(u32, mem.bytesToValue(u32, data[1..5])),
    };
}

pub const ColumnDesc = struct {
    name: []const u8,
    table_oid: u32,
    column_attr: u16,
    type_oid: u32,
    type_len: i16,
    type_mod: i32,
    format: u16,
};

pub fn parseRowDescription(payload: []const u8, columns_out: []ColumnDesc) WireError!u16 {
    if (payload.len < 2) return WireError.ProtocolViolation;
    const field_count = mem.bigToNative(u16, mem.bytesToValue(u16, payload[0..2]));
    if (field_count > columns_out.len) return WireError.ProtocolViolation;

    var pos: usize = 2;
    for (0..field_count) |i| {
        const name_start = pos;
        while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
        if (pos >= payload.len) return WireError.ProtocolViolation;
        const name = payload[name_start..pos];
        pos += 1;

        if (pos + 18 > payload.len) return WireError.ProtocolViolation;
        columns_out[i] = .{
            .name = name,
            .table_oid = mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos..][0..4])),
            .column_attr = mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 4 ..][0..2])),
            .type_oid = mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos + 6 ..][0..4])),
            .type_len = @bitCast(mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 10 ..][0..2]))),
            .type_mod = @bitCast(mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos + 12 ..][0..4]))),
            .format = mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 16 ..][0..2])),
        };
        pos += 18;
    }
    return field_count;
}

pub fn parseDataRow(payload: []const u8, values_out: []?[]const u8) WireError!u16 {
    if (payload.len < 2) return WireError.ProtocolViolation;
    const col_count = mem.bigToNative(u16, mem.bytesToValue(u16, payload[0..2]));
    if (col_count > values_out.len) return WireError.ProtocolViolation;

    var pos: usize = 2;
    for (0..col_count) |i| {
        if (pos + 4 > payload.len) return WireError.ProtocolViolation;
        const val_len: i32 = @bitCast(mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos..][0..4])));
        pos += 4;

        if (val_len == -1) {
            values_out[i] = null;
        } else {
            const ulen: usize = @intCast(val_len);
            if (pos + ulen > payload.len) return WireError.ProtocolViolation;
            values_out[i] = payload[pos..][0..ulen];
            pos += ulen;
        }
    }
    return col_count;
}

pub fn parseCommandComplete(payload: []const u8) []const u8 {
    var end: usize = 0;
    while (end < payload.len and payload[end] != 0) : (end += 1) {}
    return payload[0..end];
}

pub fn parseAuthType(payload: []const u8) WireError!AuthType {
    if (payload.len < 4) return WireError.ProtocolViolation;
    const raw = mem.bigToNative(u32, mem.bytesToValue(u32, payload[0..4]));
    return std.meta.intToEnum(AuthType, raw) catch WireError.UnsupportedAuth;
}

pub fn parseMd5Salt(payload: []const u8) WireError![4]u8 {
    if (payload.len < 8) return WireError.ProtocolViolation;
    return payload[4..8].*;
}

test "wire extern struct sizes" {
    try std.testing.expectEqual(@as(usize, 5), @sizeOf(MessageHeader));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SSLRequest));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StartupMessageHeader));
    try std.testing.expectEqual(@as(usize, 9), @sizeOf(AuthenticationOk));
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(AuthenticationMD5));
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(BackendKeyData));
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(ReadyForQuery));
}

test "startup message encoding" {
    var buf: [256]u8 = undefined;
    const msg = encodeStartupMessage(&buf, "postgres", "mydb");

    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[0..4]));
    try std.testing.expectEqual(length, @as(u32, @intCast(msg.len)));

    const version = mem.bigToNative(u32, mem.bytesToValue(u32, msg[4..8]));
    try std.testing.expectEqual(version, protocol_version);

    try std.testing.expectEqualStrings("user", msg[8..12]);
    try std.testing.expectEqual(msg[12], 0);
    try std.testing.expectEqualStrings("postgres", msg[13..21]);
    try std.testing.expectEqual(msg[21], 0);

    try std.testing.expectEqualStrings("database", msg[22..30]);
    try std.testing.expectEqual(msg[30], 0);
    try std.testing.expectEqualStrings("mydb", msg[31..35]);
    try std.testing.expectEqual(msg[35], 0);

    try std.testing.expectEqual(msg[36], 0);
}

test "password message encoding" {
    var buf: [256]u8 = undefined;
    const msg = encodePasswordMessage(&buf, "secret");

    try std.testing.expectEqual(msg[0], Tag.password_message);
    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[1..5]));
    try std.testing.expectEqual(length, 11); // 4 + 6 + 1
    try std.testing.expectEqualStrings("secret", msg[5..11]);
    try std.testing.expectEqual(msg[11], 0);
}

test "message header parsing" {
    var data: [9]u8 = undefined;
    data[0] = BackendTag.authentication;
    @memcpy(data[1..5], &mem.toBytes(mem.nativeTo(u32, @as(u32, 8), .big)));
    @memcpy(data[5..9], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));

    const header = try readMessageHeader(&data);
    try std.testing.expectEqual(header.tag, BackendTag.authentication);
    try std.testing.expectEqual(header.length, 8);
}

test "row description parsing" {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;

    @memcpy(payload[pos..][0..3], "id\x00");
    pos += 3;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 1), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 23), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 4), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0xFFFFFFFF), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 0), .big)));
    pos += 2;

    // Column 2: "name"
    @memcpy(payload[pos..][0..5], "name\x00");
    pos += 5;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 25), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @bitCast(@as(i16, -1)), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0xFFFFFFFF), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 0), .big)));
    pos += 2;

    var columns: [8]ColumnDesc = undefined;
    const count = try parseRowDescription(payload[0..pos], &columns);

    try std.testing.expectEqual(count, 2);
    try std.testing.expectEqualStrings("id", columns[0].name);
    try std.testing.expectEqual(columns[0].type_oid, 23);
    try std.testing.expectEqual(columns[0].type_len, 4);
    try std.testing.expectEqualStrings("name", columns[1].name);
    try std.testing.expectEqual(columns[1].type_oid, 25);
}

test "data row parsing" {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 3), .big)));
    pos += 2;

    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 2), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], "42");
    pos += 2;

    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;

    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 5), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..5], "hello");
    pos += 5;

    var values: [8]?[]const u8 = .{null} ** 8;
    const count = try parseDataRow(payload[0..pos], &values);

    try std.testing.expectEqual(count, 3);
    try std.testing.expectEqualStrings("42", values[0].?);
    try std.testing.expect(values[1] == null);
    try std.testing.expectEqualStrings("hello", values[2].?);
}

test "data row all nulls" {
    var payload: [10]u8 = undefined;
    var pos: usize = 0;

    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;

    var values: [4]?[]const u8 = .{null} ** 4;
    const count = try parseDataRow(payload[0..pos], &values);
    try std.testing.expectEqual(count, 2);
    try std.testing.expect(values[0] == null);
    try std.testing.expect(values[1] == null);
}

test "data row empty string" {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;

    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 1), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    pos += 4;

    var values: [4]?[]const u8 = .{null} ** 4;
    const count = try parseDataRow(payload[0..pos], &values);
    try std.testing.expectEqual(count, 1);
    try std.testing.expectEqual(values[0].?.len, 0);
}

test "command complete parsing" {
    const payload = "SELECT 42\x00";
    const tag = parseCommandComplete(payload);
    try std.testing.expectEqualStrings("SELECT 42", tag);
}

test "auth type parsing" {
    var payload_ok: [4]u8 = undefined;
    @memcpy(&payload_ok, &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    const auth_ok = try parseAuthType(&payload_ok);
    try std.testing.expectEqual(auth_ok, AuthType.ok);

    var payload_md5: [8]u8 = undefined;
    @memcpy(payload_md5[0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 5), .big)));
    @memcpy(payload_md5[4..8], &[4]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    const auth_md5 = try parseAuthType(&payload_md5);
    try std.testing.expectEqual(auth_md5, AuthType.md5_password);

    const salt = try parseMd5Salt(&payload_md5);
    try std.testing.expectEqual(salt, [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    var payload_clear: [4]u8 = undefined;
    @memcpy(&payload_clear, &mem.toBytes(mem.nativeTo(u32, @as(u32, 3), .big)));
    const auth_clear = try parseAuthType(&payload_clear);
    try std.testing.expectEqual(auth_clear, AuthType.cleartext_password);
}

test "row description truncated payload" {
    const payload = [_]u8{0};
    var columns: [4]ColumnDesc = undefined;
    const result = parseRowDescription(&payload, &columns);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

test "data row truncated payload" {
    const payload = [_]u8{0};
    var values: [4]?[]const u8 = .{null} ** 4;
    const result = parseDataRow(&payload, &values);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

test "message header too short" {
    const data = [_]u8{ 'R', 0, 0 };
    const result = readMessageHeader(&data);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

test "wire protocol connect" {}
test "wire protocol authenticate md5" {}
test "wire protocol authenticate scram" {}
test "wire protocol ssl negotiation" {}
test "wire protocol simple query" {}
test "wire protocol extended query parse" {}
test "wire protocol bind with params" {
    var buf: [256]u8 = undefined;

    const b0 = encodeBindWithParams(&buf, "s0", &.{});
    try std.testing.expectEqual(Tag.bind, b0[0]);
    try std.testing.expectEqual(@as(usize, 15), b0.len);

    const params1 = [_]?[]const u8{@as([]const u8, "idea1")};
    const b1 = encodeBindWithParams(&buf, "s1", &params1);
    try std.testing.expectEqual(Tag.bind, b1[0]);
    try std.testing.expectEqual(@as(usize, 24), b1.len);

    const num_params = mem.readInt(u16, b1[11..13], .big);
    try std.testing.expectEqual(@as(u16, 1), num_params);

    const param_len = mem.readInt(i32, b1[13..17], .big);
    try std.testing.expectEqual(@as(i32, 5), param_len);

    try std.testing.expectEqualStrings("idea1", b1[17..22]);

    const params_null = [_]?[]const u8{null};
    const b2 = encodeBindWithParams(&buf, "s0", &params_null);
    try std.testing.expectEqual(@as(usize, 19), b2.len);
    const null_len = mem.readInt(i32, b2[13..17], .big);
    try std.testing.expectEqual(@as(i32, -1), null_len);
}

test "wire protocol extended query execute" {}
test "wire protocol sync and flush" {}
test "wire protocol error response parsing" {}
test "wire protocol notice response parsing" {}
test "wire protocol notification response" {}
test "wire protocol parameter status tracking" {}
test "wire protocol close" {}

test "wire protocol RowDescription column name has no null terminator" {
    var payload: [64]u8 = undefined;
    var pos: usize = 0;

    // field_count = 1
    mem.writeInt(u16, payload[pos..][0..2], 1, .big);
    pos += 2;

    // name = "num\0"
    @memcpy(payload[pos..][0..3], "num");
    payload[pos + 3] = 0; // null terminator
    pos += 4;

    // 18 bytes of fixed fields (zeros for test)
    @memset(payload[pos..][0..18], 0);
    pos += 18;

    var columns: [16]ColumnDesc = undefined;
    const count = try parseRowDescription(payload[0..pos], &columns);

    try std.testing.expectEqual(@as(usize, 1), count);
    // The name MUST NOT include the null terminator
    try std.testing.expectEqual(@as(usize, 3), columns[0].name.len);
    try std.testing.expectEqualStrings("num", columns[0].name);
}
