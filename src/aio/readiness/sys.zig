const builtin = @import("builtin");

pub const EventKind = enum { read, write };

pub const Event = struct {
    token: *anyopaque,
    kind: EventKind,
    eof: bool,
    is_wake: bool = false,
};

pub const Backend = switch (builtin.os.tag) {
    .linux => @import("epoll.zig").Backend,
    else => @import("kq.zig").Backend,
};

pub const name: []const u8 = switch (builtin.os.tag) {
    .linux => "epoll",
    .macos => "kqueue",
    else => "readiness",
};
