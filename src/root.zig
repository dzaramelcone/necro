//! Necro - Python extension module entry point.

const std = @import("std");
pub const py = @import("py/mod.zig");
pub const http = @import("http/mod.zig");
pub const aio = @import("aio/mod.zig");
pub const core = @import("core/mod.zig");
pub const pg = @import("pg/mod.zig");
pub const json = @import("json/serialize.zig");
pub const redis = @import("redis/resp.zig");
pub const server = @import("server.zig");

pub const std_options: std.Options = .{
    .logFn = core.log.logFn,
};

comptime {
    @export(&py.module.pyInitCore, .{ .name = "PyInit_core", .linkage = .strong });
}
