//! URI path normalization: percent-decoding, dot-segment removal, slash collapsing.

const std = @import("std");
const request = @import("request.zig");
const ParseError = request.ParseError;

pub fn normalizePath(path: []u8) ParseError![]u8 {
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
