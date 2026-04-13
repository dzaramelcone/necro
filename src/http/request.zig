//! HTTP/1.1 request types. Pure data, no parsing logic.

const std = @import("std");

pub const MAX_HEADERS: usize = 64;

const Method = std.http.Method;

const Header = struct {
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
};
