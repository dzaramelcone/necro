//! SIMD Header matching and common response headers.

const std = @import("std");

const COMMON_RESPONSE_HDR_CAP = 64;

threadlocal var cached_common_response_hdr: [COMMON_RESPONSE_HDR_CAP]u8 = undefined;
threadlocal var cached_common_response_len: usize = 0;
threadlocal var cached_common_response_epoch: i64 = 0;

pub inline fn headersEqlLiteral(comptime needle: []const u8, input: []const u8) bool {
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

pub inline fn headerValueOf(comptime name: []const u8, line: []const u8) ?[]const u8 {
    const needle = name ++ ":";
    if (line.len < needle.len) return null;
    if (!headersEqlLiteral(needle, line[0..needle.len])) return null;
    return std.mem.trimLeft(u8, line[needle.len..], " \t");
}

pub inline fn headerEqls(comptime name: []const u8, comptime value: []const u8, line: []const u8) bool {
    const actual = headerValueOf(name, line) orelse return false;
    return headersEqlLiteral(value, actual);
}

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
