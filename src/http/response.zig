//! Response type carried to the wire.
//! This could be improved significantly.

const std = @import("std");

const MAX_RESPONSE_HEADERS = 4;

const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub fn writeResponseHeaders(dst: []u8, resp: *const Response, keep_alive: bool) usize {
    var pos: usize = 0;

    const conn_hdr = if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";
    @memcpy(dst[pos..][0..conn_hdr.len], conn_hdr);
    pos += conn_hdr.len;

    for (resp.headers[0..resp.header_count]) |h| {
        const needed = h.name.len + 2 + h.value.len + 2;
        if (pos + needed > dst.len) break;
        @memcpy(dst[pos..][0..h.name.len], h.name);
        pos += h.name.len;
        dst[pos] = ':';
        dst[pos + 1] = ' ';
        pos += 2;
        @memcpy(dst[pos..][0..h.value.len], h.value);
        pos += h.value.len;
        dst[pos] = '\r';
        dst[pos + 1] = '\n';
        pos += 2;
    }

    const body_len = if (resp.body) |b| b.len else 0;
    {
        const cl = "Content-Length: ";
        @memcpy(dst[pos..][0..cl.len], cl);
        pos += cl.len;
        const len_str = std.fmt.bufPrint(dst[pos..], "{d}", .{body_len}) catch return pos;
        pos += len_str.len;
        dst[pos] = '\r';
        dst[pos + 1] = '\n';
        pos += 2;
    }

    dst[pos] = '\r';
    dst[pos + 1] = '\n';
    pos += 2;

    return pos;
}

pub fn statusLine(status: std.http.Status) error{UnsupportedStatus}![]const u8 {
    return switch (status) {
        .ok => "HTTP/1.1 200 OK\r\n",
        .created => "HTTP/1.1 201 Created\r\n",
        .no_content => "HTTP/1.1 204 No Content\r\n",
        .moved_permanently => "HTTP/1.1 301 Moved Permanently\r\n",
        .found => "HTTP/1.1 302 Found\r\n",
        .not_modified => "HTTP/1.1 304 Not Modified\r\n",
        .bad_request => "HTTP/1.1 400 Bad Request\r\n",
        .unauthorized => "HTTP/1.1 401 Unauthorized\r\n",
        .forbidden => "HTTP/1.1 403 Forbidden\r\n",
        .not_found => "HTTP/1.1 404 Not Found\r\n",
        .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\n",
        .payload_too_large => "HTTP/1.1 413 Content Too Large\r\n",
        .teapot => "HTTP/1.1 418 I'm a Teapot\r\n",
        .too_many_requests => "HTTP/1.1 429 Too Many Requests\r\n",
        .internal_server_error => "HTTP/1.1 500 Internal Server Error\r\n",
        .bad_gateway => "HTTP/1.1 502 Bad Gateway\r\n",
        .service_unavailable => "HTTP/1.1 503 Service Unavailable\r\n",
        .gateway_timeout => "HTTP/1.1 504 Gateway Timeout\r\n",
        else => return error.UnsupportedStatus,
    };
}

pub const Response = struct {
    status: std.http.Status,
    headers: [MAX_RESPONSE_HEADERS]Header = undefined,
    header_count: u8 = 0,
    body: ?[]const u8 = null,

    pub fn init(status: std.http.Status) Response {
        return .{ .status = status };
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) void {
        std.debug.assert(self.header_count < MAX_RESPONSE_HEADERS);
        self.headers[self.header_count] = .{ .name = name, .value = value };
        self.header_count += 1;
    }

    pub fn json(body: []const u8) Response {
        var r = Response.init(.ok);
        r.addHeader("Content-Type", "application/json");
        r.body = body;
        return r;
    }

    pub fn text(body: []const u8) Response {
        var r = Response.init(.ok);
        r.addHeader("Content-Type", "text/plain");
        r.body = body;
        return r;
    }
};

test "init sets status only" {
    const r = Response.init(.internal_server_error);
    try std.testing.expectEqual(std.http.Status.internal_server_error, r.status);
    try std.testing.expectEqual(@as(u8, 0), r.header_count);
    try std.testing.expect(r.body == null);
}

test "json sets content-type and body" {
    const r = Response.json("{\"ok\":true}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expectEqual(@as(u8, 1), r.header_count);
    try std.testing.expectEqualStrings("Content-Type", r.headers[0].name);
    try std.testing.expectEqualStrings("application/json", r.headers[0].value);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body.?);
}

test "text sets content-type and body" {
    const r = Response.text("hello");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expectEqualStrings("text/plain", r.headers[0].value);
    try std.testing.expectEqualStrings("hello", r.body.?);
}

test "addHeader appends" {
    var r = Response.init(.method_not_allowed);
    r.addHeader("Allow", "GET, POST");
    try std.testing.expectEqual(@as(u8, 1), r.header_count);
    try std.testing.expectEqualStrings("Allow", r.headers[0].name);
    try std.testing.expectEqualStrings("GET, POST", r.headers[0].value);
}
