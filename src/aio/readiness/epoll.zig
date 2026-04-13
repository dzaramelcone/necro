const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const necro = @import("necro");
const necro_log = necro.core.log;
const sys = @import("sys.zig");

const log = std.log.scoped(.@"necro/aio/readiness/epoll");

const EventKind = sys.EventKind;
const Event = sys.Event;

const EPOLLIN = linux.EPOLL.IN;
const EPOLLOUT = linux.EPOLL.OUT;
const EPOLLET = linux.EPOLL.ET;
const EPOLLRDHUP = linux.EPOLL.RDHUP;
const EPOLLHUP = linux.EPOLL.HUP;
const EPOLLERR = linux.EPOLL.ERR;

const Watch = struct {
    read_token: ?*anyopaque = null,
    write_token: ?*anyopaque = null,
    mask: u32 = 0,
    registered: bool = false,
};

pub const Backend = struct {
    epoll_fd: posix.fd_t,
    event_fd: posix.fd_t,
    watches: []Watch,
    events: []linux.epoll_event,
    event_buf: []Event,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !Backend {
        const efd: posix.fd_t = @intCast(linux.epoll_create1(linux.EPOLL.CLOEXEC));
        if (efd < 0) return error.EpollCreateFailed;
        errdefer posix.close(efd);

        const evfd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(evfd);

        const rlim = try posix.getrlimit(.NOFILE);
        const max_fds: usize = @intCast(rlim.cur);
        const watches = try allocator.alloc(Watch, max_fds);
        @memset(watches, .{});
        errdefer allocator.free(watches);

        const events = try allocator.alloc(linux.epoll_event, max_events);
        errdefer allocator.free(events);

        const event_buf = try allocator.alloc(Event, max_events * 2);
        errdefer allocator.free(event_buf);

        return .{
            .epoll_fd = efd,
            .event_fd = evfd,
            .watches = watches,
            .events = events,
            .event_buf = event_buf,
        };
    }

    pub fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        posix.close(self.epoll_fd);
        posix.close(self.event_fd);
        allocator.free(self.watches);
        allocator.free(self.events);
        allocator.free(self.event_buf);
    }

    pub fn wakeRegister(self: *Backend) !void {
        var ev: linux.epoll_event = .{
            .events = EPOLLIN | EPOLLET,
            .data = .{ .u64 = @intCast(self.event_fd) },
        };
        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.event_fd, &ev);
    }

    pub fn wake(self: *const Backend) void {
        var one: u64 = 1;
        _ = posix.write(self.event_fd, std.mem.asBytes(&one)) catch {};
    }

    pub fn arm(self: *Backend, fd: posix.socket_t, kind: EventKind, token: *anyopaque) !void {
        const ufd: usize = @intCast(fd);
        if (ufd >= self.watches.len) return error.FdOutOfRange;
        const w = &self.watches[ufd];

        const bit: u32 = switch (kind) {
            .read => EPOLLIN,
            .write => EPOLLOUT,
        };
        switch (kind) {
            .read => w.read_token = token,
            .write => w.write_token = token,
        }

        const new_mask = w.mask | bit;
        if (w.registered and new_mask == w.mask) return;

        var ev: linux.epoll_event = .{
            .events = new_mask | EPOLLET | EPOLLRDHUP,
            .data = .{ .u64 = @intCast(fd) },
        };
        const op: u32 = if (w.registered) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        try posix.epoll_ctl(self.epoll_fd, op, fd, &ev);
        w.mask = new_mask;
        w.registered = true;
    }

    pub fn disarmWrite(self: *Backend, fd: posix.socket_t) !void {
        const ufd: usize = @intCast(fd);
        if (ufd >= self.watches.len) return;
        const w = &self.watches[ufd];
        if (!w.registered or (w.mask & EPOLLOUT) == 0) return;

        const new_mask = w.mask & ~@as(u32, EPOLLOUT);
        w.write_token = null;
        if (new_mask == 0) {
            try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            w.mask = 0;
            w.registered = false;
            return;
        }
        var ev: linux.epoll_event = .{
            .events = new_mask | EPOLLET | EPOLLRDHUP,
            .data = .{ .u64 = @intCast(fd) },
        };
        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
        w.mask = new_mask;
    }

    pub fn disarm(self: *Backend, fd: posix.socket_t) void {
        const ufd: usize = @intCast(fd);
        if (ufd >= self.watches.len) return;
        self.watches[ufd] = .{};
    }

    pub fn wait(self: *Backend, wait_nr: u32, timeout_ns: ?i64) ![]Event {
        necro_log.bumpLoop();

        const timeout_ms: i32 = blk: {
            if (wait_nr == 0) break :blk 0;
            if (timeout_ns) |ns| {
                if (ns <= 0) break :blk 0;
                const ms: i64 = @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
                break :blk @intCast(@min(ms, std.math.maxInt(i32)));
            }
            break :blk -1;
        };

        const n = posix.epoll_wait(self.epoll_fd, self.events, timeout_ms);
        log.debug("epoll_wait: reaped {d} events", .{n});

        var count: usize = 0;
        for (self.events[0..n]) |ev| {
            const fd: posix.fd_t = @intCast(ev.data.u64);
            if (fd == self.event_fd) {
                var drain: u64 = 0;
                _ = posix.read(self.event_fd, std.mem.asBytes(&drain)) catch {};
                self.event_buf[count] = .{
                    .token = undefined,
                    .kind = .read,
                    .eof = false,
                    .is_wake = true,
                };
                count += 1;
                continue;
            }

            const ufd: usize = @intCast(fd);
            if (ufd >= self.watches.len) continue;
            const w = &self.watches[ufd];
            if (!w.registered) continue;

            const mask = ev.events;
            const has_in = (mask & EPOLLIN) != 0;
            const has_out = (mask & EPOLLOUT) != 0;
            const eof = (mask & (EPOLLHUP | EPOLLRDHUP | EPOLLERR)) != 0;

            if (has_in or (eof and !has_out)) {
                if (w.read_token) |t| {
                    self.event_buf[count] = .{
                        .token = t,
                        .kind = .read,
                        .eof = eof,
                    };
                    count += 1;
                }
            }
            if (has_out) {
                if (w.write_token) |t| {
                    self.event_buf[count] = .{
                        .token = t,
                        .kind = .write,
                        .eof = eof,
                    };
                    count += 1;
                }
            }
        }

        return self.event_buf[0..count];
    }
};
