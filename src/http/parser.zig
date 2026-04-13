//! HTTP/1.1 request parser; zero copy zero alloc
//! TODO: Switch to arena and parse into it.

const std = @import("std");
const request = @import("request.zig");
const headers = @import("headers.zig");
const path = @import("path.zig");

const Request = request.Request;
const Method = std.http.Method;
const ParseError = request.ParseError;
const MAX_HEADERS = request.MAX_HEADERS;

pub fn parse(bytes: []u8) ParseError!Request {
    var req = Request{};
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");

    const request_line_const = lines.next() orelse return error.MalformedRequest;
    const rl_start: usize = @intFromPtr(request_line_const.ptr) - @intFromPtr(bytes.ptr);
    const request_line: []u8 = bytes[rl_start .. rl_start + request_line_const.len];
    var chunks = std.mem.tokenizeScalar(u8, request_line, ' ');

    const method_str = chunks.next() orelse return error.MalformedRequest;
    req.method = std.meta.stringToEnum(Method, method_str) orelse return error.BadMethod;
    req.method_bytes = method_str;

    const uri_const = chunks.next() orelse return error.MalformedRequest;
    const uri_start: usize = @intFromPtr(uri_const.ptr) - @intFromPtr(request_line.ptr);
    const uri_mut: []u8 = request_line[uri_start .. uri_start + uri_const.len];
    const path_end = std.mem.indexOfAny(u8, uri_mut, "?#") orelse uri_mut.len;
    const normalized_path = try path.normalizePath(uri_mut[0..path_end]);
    if (path_end == uri_mut.len) {
        req.uri = normalized_path;
    } else {
        const tail_len = uri_mut.len - path_end;
        std.mem.copyForwards(u8, uri_mut[normalized_path.len .. normalized_path.len + tail_len], uri_mut[path_end..]);
        req.uri = uri_mut[0 .. normalized_path.len + tail_len];
    }

    const version = chunks.next() orelse return error.MalformedRequest;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) return error.BadVersion;
    if (chunks.next() != null) return error.MalformedRequest;

    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (req.header_count >= MAX_HEADERS) return error.TooManyHeaders;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeaderLine;
        const name = line[0..colon];
        const value = std.mem.trimLeft(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.BadHeaderLine;

        req.headers[req.header_count] = .{ .name = name, .value = value };
        req.header_count += 1;

        if (headers.headerValueOf("Content-Length", line)) |cl_val| {
            if (req.content_length != null) return error.MalformedRequest;
            req.content_length = std.fmt.parseInt(usize, cl_val, 10) catch
                return error.MalformedRequest;
        }
        if (headers.headerEqls("Connection", "close", line)) req.keepalive = false;
    }

    const rest = lines.rest();
    if (rest.len > 0) {
        req.body = rest;
    }

    return req;
}

fn testParseMut(comptime s: []const u8) ParseError!Request {
    const S = struct {
        threadlocal var buf: [4096]u8 = undefined;
    };
    @memcpy(S.buf[0..s.len], s);
    return parse(S.buf[0..s.len]);
}

test "parse GET request" {
    const req = try testParseMut("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(Method.GET, req.method.?);
    try std.testing.expectEqualStrings("/", req.uri.?);
    try std.testing.expectEqual(@as(usize, 1), req.header_count);
    try std.testing.expectEqualStrings("Host", req.headers[0].name);
    try std.testing.expectEqualStrings("localhost", req.headers[0].value);
    try std.testing.expect(req.keepalive);
}

test "parse POST with body" {
    const req = try testParseMut("POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 13\r\n\r\nHello, world!");
    try std.testing.expectEqual(Method.POST, req.method.?);
    try std.testing.expectEqualStrings("/submit", req.uri.?);
    try std.testing.expectEqual(@as(usize, 13), req.content_length.?);
    try std.testing.expectEqualStrings("Hello, world!", req.body.?);
}

test "parse headers case insensitive matching" {
    const req = try testParseMut("GET / HTTP/1.1\r\nContent-Type: text/html\r\nX-Custom: value\r\n\r\n");
    try std.testing.expectEqualStrings("Content-Type", req.headers[0].name);
    try std.testing.expectEqualStrings("text/html", req.headers[0].value);
}

test "reject bad method" {
    try std.testing.expectError(error.BadMethod, testParseMut("XYZZY / HTTP/1.1\r\n\r\n"));
}

test "reject HTTP/2.0" {
    try std.testing.expectError(error.BadVersion, testParseMut("GET / HTTP/2.0\r\n\r\n"));
}

test "reject HTTP/1.0" {
    try std.testing.expectError(error.BadVersion, testParseMut("GET / HTTP/1.0\r\nHost: h\r\n\r\n"));
}

test "keepalive is default true" {
    const req = try testParseMut("GET / HTTP/1.1\r\nHost: h\r\n\r\n");
    try std.testing.expect(req.keepalive);
}

test "Connection: close flips keepalive off" {
    const req = try testParseMut("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    try std.testing.expect(!req.keepalive);
}

test "Connection: close is case-insensitive on both name and value" {
    const req = try testParseMut("GET / HTTP/1.1\r\nCONNECTION: CLOSE\r\n\r\n");
    try std.testing.expect(!req.keepalive);
}

test "unknown Connection value leaves keepalive at default" {
    const req = try testParseMut("GET / HTTP/1.1\r\nConnection: foo-bar\r\n\r\n");
    try std.testing.expect(req.keepalive);
}

test "parse normalizes path" {
    const req = try testParseMut("GET /users/%61dmin/./profile HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("/users/admin/profile", req.uri.?);
}

test "parse preserves query string after normalization" {
    const req = try testParseMut("GET /a/./b?x=1&y=2 HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("/a/b?x=1&y=2", req.uri.?);
}
test "parse rejects duplicate Content-Length" {
    try std.testing.expectError(error.MalformedRequest, testParseMut("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nhello"));
}
// TODO: fuzz
