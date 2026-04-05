//! HTTP/1.1 request parser. Single-pass, zero-copy, zero-alloc.

const std = @import("std");
pub const MAX_HEADERS: usize = 64;

const COMMON_RESPONSE_HDR_CAP = 64;

threadlocal var cached_common_response_hdr: [COMMON_RESPONSE_HDR_CAP]u8 = undefined;
threadlocal var cached_common_response_len: usize = 0;
threadlocal var cached_common_response_epoch: i64 = 0;

pub const Method = std.http.Method;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    MalformedRequest,
    BadMethod,
    BadVersion,
    UriTooLong,
    TooManyHeaders,
    HeaderTooLarge,
    BadHeaderLine,
    BufferFull,
    InvalidPercentEncoding,
    InvalidPath,
};

pub const Request = struct {
    method: ?Method = null,
    method_bytes: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    headers: [MAX_HEADERS]Header = undefined,
    header_count: usize = 0,
    content_length: ?usize = null,
    keepalive: bool = true,
    body: ?[]const u8 = null,

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
        const normalized_path = try normalizePath(uri_mut[0..path_end]);
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

            if (headerValueOf("Content-Length", line)) |cl_val| {
                req.content_length = std.fmt.parseInt(usize, cl_val, 10) catch
                    return error.MalformedRequest;
            }
            if (headerEqls("Connection", "close", line)) req.keepalive = false;
        }

        const rest = lines.rest();
        if (rest.len > 0) {
            req.body = rest;
        }

        return req;
    }
};

fn refreshCommonResponseHeaders() void {
    const now = std.time.timestamp();
    if (now == cached_common_response_epoch and cached_common_response_len > 0) return;
    cached_common_response_epoch = now;

    const epoch_secs: u64 = @intCast(now);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const days_since_epoch = es.getEpochDay().day;
    const dow = @mod(days_since_epoch + 3, 7);

    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    cached_common_response_len = (std.fmt.bufPrint(
        &cached_common_response_hdr,
        "Server: necro\r\nDate: {s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT\r\n",
        .{
            day_names[dow],
            month_day.day_index + 1,
            month_names[month_day.month.numeric() - 1],
            year_day.year,
            hour,
            minute,
            second,
        },
    ) catch &.{}).len;
}

pub fn commonResponseHeaders() []const u8 {
    refreshCommonResponseHeaders();
    return cached_common_response_hdr[0..cached_common_response_len];
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn toUpperHex(c: u8) u8 {
    return if (c >= 'a' and c <= 'f') c - 32 else c;
}

fn normalizePath(path: []u8) ParseError![]u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < path.len) {
        const c = path[read];
        if (c != '%') {
            path[write] = c;
            read += 1;
            write += 1;
            continue;
        }
        if (read + 2 >= path.len) return error.InvalidPercentEncoding;
        const h1 = hexVal(path[read + 1]) orelse return error.InvalidPercentEncoding;
        const h2 = hexVal(path[read + 2]) orelse return error.InvalidPercentEncoding;
        const decoded: u8 = (h1 << 4) | h2;
        if (decoded == 0) return error.InvalidPath;
        if (isUnreserved(decoded)) {
            path[write] = decoded;
            read += 3;
            write += 1;
        } else {
            path[write] = '%';
            path[write + 1] = toUpperHex(path[read + 1]);
            path[write + 2] = toUpperHex(path[read + 2]);
            read += 3;
            write += 3;
        }
    }
    const stage_a_len = write;

    for (path[0..stage_a_len]) |b| {
        if (b == 0) return error.InvalidPath;
    }

    const src_len = stage_a_len;
    var r: usize = 0;
    var w: usize = 0;

    while (r < src_len) {
        if (r + 3 <= src_len and path[r] == '.' and path[r + 1] == '.' and path[r + 2] == '/') {
            r += 3;
            continue;
        }
        if (r + 2 <= src_len and path[r] == '.' and path[r + 1] == '/') {
            r += 2;
            continue;
        }
        if (r + 3 <= src_len and path[r] == '/' and path[r + 1] == '.' and path[r + 2] == '/') {
            r += 2; // leave the leading '/', consume "/."
            continue;
        }
        if (r + 2 <= src_len and path[r] == '/' and path[r + 1] == '/') {
            r += 1;
            continue;
        }
        if (r + 2 == src_len and path[r] == '/' and path[r + 1] == '.') {
            path[w] = '/';
            w += 1;
            r += 2;
            continue;
        }
        if (r + 4 <= src_len and path[r] == '/' and path[r + 1] == '.' and path[r + 2] == '.' and path[r + 3] == '/') {
            r += 3;
            popSegment(path, &w);
            continue;
        }
        if (r + 3 == src_len and path[r] == '/' and path[r + 1] == '.' and path[r + 2] == '.') {
            popSegment(path, &w);
            path[w] = '/';
            w += 1;
            r += 3;
            continue;
        }
        if (src_len - r == 1 and path[r] == '.') {
            r += 1;
            continue;
        }
        if (src_len - r == 2 and path[r] == '.' and path[r + 1] == '.') {
            r += 2;
            continue;
        }
        var end = r;
        if (path[end] == '/') end += 1;
        while (end < src_len and path[end] != '/') end += 1;
        const seg_len = end - r;
        if (w != r) {
            std.mem.copyForwards(u8, path[w .. w + seg_len], path[r..end]);
        }
        w += seg_len;
        r = end;
    }

    if (w == 0 and src_len > 0 and path[0] == '/') {
        path[0] = '/';
        w = 1;
    }

    return path[0..w];
}

fn popSegment(path: []u8, w: *usize) void {
    if (w.* == 0) return;
    var i = w.*;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            w.* = i;
            return;
        }
    }
    w.* = 0;
}

inline fn headersEqlLiteral(comptime needle: []const u8, input: []const u8) bool {
    if (input.len != needle.len) return false;
    const N = needle.len;
    const V = @Vector(N, u8);

    comptime var lowered_arr: [N]u8 = undefined;
    comptime {
        for (needle, 0..) |ch, idx| {
            lowered_arr[idx] = ch | 0x20;
        }
    }
    const lowered_needle: V = lowered_arr;

    const input_vec: V = input[0..N].*;
    const mask: V = @splat(@as(u8, 0x20));
    return @reduce(.And, lowered_needle == (input_vec | mask));
}

inline fn headerValueOf(comptime name: []const u8, line: []const u8) ?[]const u8 {
    const needle = name ++ ":";
    if (line.len < needle.len) return null;
    if (!headersEqlLiteral(needle, line[0..needle.len])) return null;
    return std.mem.trimLeft(u8, line[needle.len..], " \t");
}

inline fn headerEqls(comptime name: []const u8, comptime value: []const u8, line: []const u8) bool {
    const actual = headerValueOf(name, line) orelse return false;
    return headersEqlLiteral(value, actual);
}

test "headersEqlLiteral exact match" {
    try std.testing.expect(headersEqlLiteral("Content-Length", "Content-Length"));
}

test "headersEqlLiteral case fold both ways" {
    try std.testing.expect(headersEqlLiteral("Content-Length", "content-length"));
    try std.testing.expect(headersEqlLiteral("Content-Length", "CONTENT-LENGTH"));
    try std.testing.expect(headersEqlLiteral("Content-Length", "cOnTeNt-LeNgTh"));
}

test "headersEqlLiteral length mismatch rejected" {
    try std.testing.expect(!headersEqlLiteral("Content-Length", "Content-Lengt"));
    try std.testing.expect(!headersEqlLiteral("Content-Length", "Content-Lengths"));
}

test "headersEqlLiteral wrong header rejected" {
    try std.testing.expect(!headersEqlLiteral("Content-Length", "Content-Typeee"));
    try std.testing.expect(!headersEqlLiteral("Connection", "Connectioh"));
}

test "headersEqlLiteral hyphen byte is preserved" {
    try std.testing.expect(!headersEqlLiteral("Content-Length", "ContentXLength"));
}

test "headersEqlLiteral short literal works" {
    try std.testing.expect(headersEqlLiteral("close", "CLOSE"));
    try std.testing.expect(headersEqlLiteral("close", "Close"));
    try std.testing.expect(!headersEqlLiteral("close", "open!"));
}

test "headerValueOf matches and trims whitespace" {
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "Content-Length: 42").?);
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "Content-Length:42").?);
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "Content-Length:    42").?);
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "Content-Length:\t42").?);
}

test "headerValueOf is case-insensitive on name" {
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "content-length: 42").?);
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "CONTENT-LENGTH: 42").?);
    try std.testing.expectEqualStrings("42", headerValueOf("Content-Length", "Content-LENGTH: 42").?);
}

test "headerValueOf returns null on wrong name" {
    try std.testing.expect(headerValueOf("Content-Length", "Content-Type: 42") == null);
    try std.testing.expect(headerValueOf("Content-Length", "Connection: close") == null);
}

test "headerValueOf returns null on short input" {
    try std.testing.expect(headerValueOf("Content-Length", "Content-") == null);
    try std.testing.expect(headerValueOf("Content-Length", "") == null);
}

test "headerValueOf preserves value verbatim (no inner trim)" {
    try std.testing.expectEqualStrings("keep-alive", headerValueOf("Connection", "Connection: keep-alive").?);
    try std.testing.expectEqualStrings("gzip, deflate", headerValueOf("Accept-Encoding", "Accept-Encoding: gzip, deflate").?);
}

fn testParseMut(comptime s: []const u8) ParseError!Request {
    const S = struct {
        threadlocal var buf: [4096]u8 = undefined;
    };
    @memcpy(S.buf[0..s.len], s);
    return Request.parse(S.buf[0..s.len]);
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

test "cached common response headers" {
    const hdr = commonResponseHeaders();
    try std.testing.expect(hdr.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, hdr, "Server: necro\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Date:") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "GMT\r\n"));
}

test "cached response headers stable within same second" {
    const a = commonResponseHeaders();
    const b = commonResponseHeaders();
    try std.testing.expectEqualStrings(a, b);
}

fn testNormalizePathLiteral(comptime s: []const u8) ParseError![]u8 {
    const S = struct {
        threadlocal var buf: [512]u8 = undefined;
    };
    @memcpy(S.buf[0..s.len], s);
    return normalizePath(S.buf[0..s.len]);
}

test "percent-decode unreserved: lowercase letter" {
    try std.testing.expectEqualStrings("/users/admin", try testNormalizePathLiteral("/users/%61dmin"));
}

test "percent-decode unreserved: uppercase letter" {
    try std.testing.expectEqualStrings("/users/A", try testNormalizePathLiteral("/users/%41"));
}

test "percent-decode unreserved: digit" {
    try std.testing.expectEqualStrings("/users/0", try testNormalizePathLiteral("/users/%30"));
}

test "percent-decode unreserved: hyphen" {
    try std.testing.expectEqualStrings("/users/--test", try testNormalizePathLiteral("/users/%2d-test"));
}

test "percent-decode unreserved: period in middle of segment" {
    try std.testing.expectEqualStrings("/users/a.b", try testNormalizePathLiteral("/users/a%2Eb"));
}

test "percent-decode unreserved: underscore" {
    try std.testing.expectEqualStrings("/users/_", try testNormalizePathLiteral("/users/%5F"));
}

test "percent-decode unreserved: tilde" {
    try std.testing.expectEqualStrings("/users/~", try testNormalizePathLiteral("/users/%7E"));
}

test "percent-encoded reserved char stays encoded" {
    try std.testing.expectEqualStrings("/files/%2Fpath", try testNormalizePathLiteral("/files/%2Fpath"));
}

test "percent-encoded hex is uppercased" {
    try std.testing.expectEqualStrings("/files/%2Fpath", try testNormalizePathLiteral("/files/%2fpath"));
}

test "reject truncated percent at end" {
    try std.testing.expectError(error.InvalidPercentEncoding, testNormalizePathLiteral("/users/%"));
}

test "reject percent with one hex digit" {
    try std.testing.expectError(error.InvalidPercentEncoding, testNormalizePathLiteral("/users/%1"));
}

test "reject percent with non-hex digits" {
    try std.testing.expectError(error.InvalidPercentEncoding, testNormalizePathLiteral("/users/%ZZ"));
}

test "reject percent with one non-hex digit" {
    try std.testing.expectError(error.InvalidPercentEncoding, testNormalizePathLiteral("/users/%2G"));
}

test "reject percent-encoded null" {
    try std.testing.expectError(error.InvalidPath, testNormalizePathLiteral("/users/%00foo"));
}

test "reject literal null byte" {
    try std.testing.expectError(error.InvalidPath, testNormalizePathLiteral("/users/\x00foo"));
}

test "dot segment in middle" {
    try std.testing.expectEqualStrings("/a/b", try testNormalizePathLiteral("/a/./b"));
}

test "dot segment at end" {
    try std.testing.expectEqualStrings("/a/b/", try testNormalizePathLiteral("/a/b/."));
}

test "double-dot pops segment" {
    try std.testing.expectEqualStrings("/a/c", try testNormalizePathLiteral("/a/b/../c"));
}

test "double-dot at end pops segment with trailing slash" {
    try std.testing.expectEqualStrings("/a/", try testNormalizePathLiteral("/a/b/.."));
}

test "double-dot cannot pop past root" {
    try std.testing.expectEqualStrings("/a", try testNormalizePathLiteral("/../a"));
}

test "multiple double-dots" {
    try std.testing.expectEqualStrings("/c", try testNormalizePathLiteral("/a/b/../../c"));
}

test "excess double-dots at root are discarded" {
    try std.testing.expectEqualStrings("/c", try testNormalizePathLiteral("/a/b/../../../c"));
}

test "dot segment at start" {
    try std.testing.expectEqualStrings("/a", try testNormalizePathLiteral("/./a"));
}

test "single dot only" {
    try std.testing.expectEqualStrings("/", try testNormalizePathLiteral("/."));
}

test "single double-dot only" {
    try std.testing.expectEqualStrings("/", try testNormalizePathLiteral("/.."));
}

test "collapse double slash" {
    try std.testing.expectEqualStrings("/a/b", try testNormalizePathLiteral("/a//b"));
}

test "collapse triple slash" {
    try std.testing.expectEqualStrings("/a/b", try testNormalizePathLiteral("/a///b"));
}

test "collapse leading double slash" {
    try std.testing.expectEqualStrings("/a", try testNormalizePathLiteral("//a"));
}

test "collapse trailing double slash" {
    try std.testing.expectEqualStrings("/a/", try testNormalizePathLiteral("/a//"));
}

test "combined normalization" {
    try std.testing.expectEqualStrings("/a/b/d", try testNormalizePathLiteral("/a/./b//c/../d"));
}

test "combined percent + dot" {
    try std.testing.expectEqualStrings("/api/v1/users", try testNormalizePathLiteral("/api/%76%31/users"));
}

test "root only" {
    try std.testing.expectEqualStrings("/", try testNormalizePathLiteral("/"));
}

test "pure passthrough" {
    try std.testing.expectEqualStrings("/abc", try testNormalizePathLiteral("/abc"));
}

test "parse normalizes path" {
    const req = try testParseMut("GET /users/%61dmin/./profile HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("/users/admin/profile", req.uri.?);
}

test "parse preserves query string after normalization" {
    const req = try testParseMut("GET /a/./b?x=1&y=2 HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("/a/b?x=1&y=2", req.uri.?);
}
// TODO: fuzz
