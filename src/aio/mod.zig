const builtin = @import("builtin");

pub const Token = @import("Token.zig");
pub const IdleList = @import("IdleList.zig");
pub const tasks = @import("tasks.zig");
pub const runtime = switch (builtin.os.tag) {
    .linux => @import("uring/runtime.zig"),
    else => @import("kq/runtime.zig"),
};

pub const BATCH_QUEUE_CAPACITY: usize = 1024;
