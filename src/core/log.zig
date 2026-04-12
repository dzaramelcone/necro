//! Custom log function for necro.

const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

const prefix_fmt = "[{s}] [t:{d}] [loop:{d}] [{s}] {s} | ";

threadlocal var loop_count: u64 = 0;

pub fn bumpLoop() void {
    loop_count += 1;
}

fn formatTimestamp(buf: *[24]u8, ms: i64) []const u8 {
    const secs: c.time_t = @intCast(@divFloor(ms, 1000));
    const millis: u16 = @intCast(@mod(ms, 1000));

    var tm: c.struct_tm = undefined;
    if (c.gmtime_r(&secs, &tm) == null) return buf[0..0];

    const n = c.strftime(buf, buf.len, "%Y-%m-%dT%H:%M:%S", &tm);
    if (n == 0) return buf[0..0];

    var w = std.Io.Writer.fixed(buf[n..]);
    w.print(".{d:0>3}Z", .{millis}) catch {};
    return buf[0 .. n + w.buffered().len];
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_name = comptime @tagName(level);
    const scope_name = if (@tagName(scope).len > 0) @tagName(scope) else "necro";

    var ts_buf: [24]u8 = undefined;
    const ts = formatTimestamp(&ts_buf, std.time.milliTimestamp());

    const prefix_args = .{
        ts,
        std.Thread.getCurrentId(),
        loop_count,
        level_name,
        scope_name,
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(prefix_fmt ++ fmt ++ "\n", prefix_args ++ args) catch return;

    const stderr = std.fs.File.stderr();
    stderr.writeAll(w.buffered()) catch return;
}
