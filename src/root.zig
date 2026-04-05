//! Necro - Python extension module entry point.

const std = @import("std");
const log = @import("log.zig");
const module = @import("py/module.zig");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
};

comptime {
    @export(&module.pyInitCore, .{ .name = "PyInit_core", .linkage = .strong });
}
