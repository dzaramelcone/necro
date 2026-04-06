//! TCP socket setup — bind, listen, close.

const std = @import("std");
const posix = std.posix;

pub const Socket = struct {
    handle: posix.socket_t,
    addr: std.net.Address,

    pub fn initTcp(host: []const u8, port: u16) !Socket {
        const addr = try std.net.Address.parseIp4(host, port);
        const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
        const handle = try posix.socket(addr.any.family, flags, posix.IPPROTO.TCP);
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        return .{ .handle = handle, .addr = addr };
    }

    pub fn enableReusePort(self: Socket) !void {
        try posix.setsockopt(self.handle, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }

    pub fn bind(self: Socket) !void {
        try posix.bind(self.handle, &self.addr.any, self.addr.getOsSockLen());
    }

    pub fn listen(self: Socket, backlog: u31) !void {
        try posix.listen(self.handle, backlog);
    }

    pub fn close(self: Socket) void {
        posix.close(self.handle);
    }
};
