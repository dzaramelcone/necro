//! Postgres client: TCP/Unix connect + startup/auth handshake.

// TODO: Reconnect, etc

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const wire = @import("wire.zig");
const auth = @import("auth.zig");

const CONNECT_TIMEOUT_MS: i32 = 5_000;
const HANDSHAKE_IO_TIMEOUT_MS: i32 = 5_000;

pub const Client = struct {
    const read_buf_size = 8192;

    fd: posix.socket_t,
    allocator: mem.Allocator,

    const BackendMessage = struct {
        tag: u8,
        payload: []u8,
        buf: [read_buf_size]u8,
    };

    pub fn connect(
        allocator: mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
    ) !Client {
        const fd = if (host.len > 0 and host[0] == '/')
            try connectUnix(host, port)
        else
            try connectTcp(host, port);
        errdefer posix.close(fd);

        var client = Client{ .fd = fd, .allocator = allocator };

        var startup_buf: [256]u8 = undefined;
        const startup_msg = wire.encodeStartupMessage(&startup_buf, user, database);
        try client.sendAll(startup_msg);

        try client.handleStartupResponse(user, password);

        return client;
    }

    fn connectUnix(dir: []const u8, port: u16) !posix.socket_t {
        var path_buf: [108]u8 = undefined;
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        const path = try std.fmt.bufPrint(&path_buf, "{s}/.s.PGSQL.{d}\x00", .{ dir, port });
        @memcpy(addr.path[0..path.len], path[0..path.len]);
        const sock_flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
        const fd = try posix.socket(posix.AF.UNIX, sock_flags, 0);
        errdefer posix.close(fd);
        try finishConnect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        return fd;
    }

    fn connectTcp(host: []const u8, port: u16) !posix.socket_t {
        const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.UnknownHostName;

        const addr = list.addrs[0];
        const sock_flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
        const fd = try posix.socket(addr.any.family, sock_flags, posix.IPPROTO.TCP);
        errdefer posix.close(fd);
        try finishConnect(fd, &addr.any, addr.getOsSockLen());
        return fd;
    }

    fn finishConnect(fd: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
        posix.connect(fd, addr, addr_len) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };
        var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        const n = try posix.poll(&pfd, CONNECT_TIMEOUT_MS);
        if (n == 0) return error.ConnectionTimedOut;
        try posix.getsockoptError(fd);
    }

    fn sendAll(self: *Client, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = posix.write(self.fd, data[sent..]) catch |err| switch (err) {
                error.WouldBlock => {
                    try waitFor(self.fd, posix.POLL.OUT);
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.ConnectionRefused;
            sent += n;
        }
    }

    fn readExact(self: *Client, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(self.fd, buf[total..]) catch |err| switch (err) {
                error.WouldBlock => {
                    try waitFor(self.fd, posix.POLL.IN);
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.ConnectionRefused;
            total += n;
        }
    }

    fn waitFor(fd: posix.socket_t, events: i16) !void {
        var pfd = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = try posix.poll(&pfd, HANDSHAKE_IO_TIMEOUT_MS);
        if (n == 0) return error.ConnectionTimedOut;
    }

    fn readBackendMessage(self: *Client) !BackendMessage {
        var header_buf: [5]u8 = undefined;
        try self.readExact(&header_buf);
        const header = try wire.readMessageHeader(&header_buf);
        const payload_len = header.length - 4;

        var result = BackendMessage{
            .tag = header.tag,
            .payload = undefined,
            .buf = undefined,
        };

        if (payload_len > read_buf_size) return error.MessageTooLarge;
        try self.readExact(result.buf[0..payload_len]);
        result.payload = result.buf[0..payload_len];
        return result;
    }

    fn handleStartupResponse(self: *Client, user: []const u8, password: ?[]const u8) !void {
        while (true) {
            const msg = try self.readBackendMessage();
            switch (msg.tag) {
                wire.BackendTag.authentication => {
                    const auth_type = try wire.parseAuthType(msg.payload);
                    switch (auth_type) {
                        .ok => {},
                        .cleartext_password => {
                            var pw_buf: [256]u8 = undefined;
                            const pw = password orelse return error.AuthenticationFailed;
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, pw);
                            try self.sendAll(pw_msg);
                        },
                        .md5_password => {
                            var pw_buf: [256]u8 = undefined;
                            const pw = password orelse return error.AuthenticationFailed;
                            const salt = try wire.parseMd5Salt(msg.payload);
                            const md5_hash = auth.computeMd5Password(user, pw, salt);
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, &md5_hash);
                            try self.sendAll(pw_msg);
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                wire.BackendTag.parameter_status => {},
                wire.BackendTag.backend_key_data => {},
                wire.BackendTag.ready_for_query => return,
                wire.BackendTag.error_response => return error.ServerError,
                else => {},
            }
        }
    }
};
