//! Custom log function for necro.

const std = @import("std");

const prefix_fmt = "[{d}] [t:{d}] [loop:{d}] [{s}] {s} | ";

threadlocal var loop_count: u64 = 0;

pub fn bumpLoop() void {
    loop_count += 1;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_name = comptime @tagName(level);
    const scope_name = if (@tagName(scope).len > 0) @tagName(scope) else "necro";

    const prefix_args = .{
        std.time.milliTimestamp(),
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
