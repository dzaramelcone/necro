//! Response type carried to the wire.

const std = @import("std");

pub const MAX_HEADERS = 4;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: std.http.Status,
    headers: [MAX_HEADERS]Header = undefined,
    header_count: u8 = 0,
    body: ?[]const u8 = null,

    pub fn init(status: std.http.Status) Response {
        return .{ .status = status };
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) void {
        std.debug.assert(self.header_count < MAX_HEADERS);
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
