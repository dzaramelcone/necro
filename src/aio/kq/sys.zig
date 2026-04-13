const std = @import("std");
const posix = std.posix;
const system = posix.system;
const necro = @import("necro");
const necro_log = necro.core.log;

const log = std.log.scoped(.@"necro/aio/kq/sys");

pub const EventKind = enum { read, write };

pub const Event = struct {
    token: *anyopaque,
    kind: EventKind,
    eof: bool,
    is_wake: bool = false,
};

pub const Kqueue = struct {
    kqueue_fd: posix.fd_t,
    changes: []posix.Kevent,
    events: []posix.Kevent,
    event_buf: []Event,
    change_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !Kqueue {
        return .{
            .kqueue_fd = try posix.kqueue(),
            .changes = try allocator.alloc(posix.Kevent, max_events),
            .events = try allocator.alloc(posix.Kevent, max_events),
            .event_buf = try allocator.alloc(Event, max_events),
        };
    }

    pub fn deinit(self: *Kqueue, allocator: std.mem.Allocator) void {
        posix.close(self.kqueue_fd);
        allocator.free(self.changes);
        allocator.free(self.events);
        allocator.free(self.event_buf);
    }

    pub const WAKE_IDENT: usize = 0xB0B0B0B0;

    pub fn wakeRegister(self: *Kqueue) !void {
        const kev: posix.Kevent = .{
            .ident = WAKE_IDENT,
            .filter = system.EVFILT.USER,
            .flags = system.EV.ADD | system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = try posix.kevent(self.kqueue_fd, &.{kev}, &.{}, null);
    }

    pub fn wakeTrigger(kqueue_fd: posix.fd_t) void {
        const kev: posix.Kevent = .{
            .ident = WAKE_IDENT,
            .filter = system.EVFILT.USER,
            .flags = 0,
            .fflags = system.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        };
        _ = posix.kevent(kqueue_fd, &.{kev}, &.{}, null) catch {};
    }

    pub fn arm(self: *Kqueue, fd: posix.socket_t, kind: EventKind, token: *anyopaque) !void {
        if (self.change_count >= self.changes.len) return error.Overflow;
        self.changes[self.change_count] = .{
            .ident = @intCast(fd),
            .filter = switch (kind) {
                .read => system.EVFILT.READ,
                .write => system.EVFILT.WRITE,
            },
            .flags = system.EV.ADD | system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(token),
        };
        self.change_count += 1;
    }

    pub fn disarm(self: *Kqueue, fd: posix.socket_t) void {
        if (self.change_count + 2 > self.changes.len) return;
        self.changes[self.change_count] = .{
            .ident = @intCast(fd),
            .filter = system.EVFILT.READ,
            .flags = system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        self.change_count += 1;
        self.changes[self.change_count] = .{
            .ident = @intCast(fd),
            .filter = system.EVFILT.WRITE,
            .flags = system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        self.change_count += 1;
    }

    pub fn wait(self: *Kqueue, wait_nr: u32, timeout_ns: ?i64) ![]Event {
        necro_log.bumpLoop();

        const zero_spec: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const bounded_spec: posix.timespec = if (timeout_ns) |ns| blk: {
            const clamped: i64 = if (ns < 0) 0 else ns;
            break :blk .{
                .sec = @intCast(@divFloor(clamped, std.time.ns_per_s)),
                .nsec = @intCast(@mod(clamped, std.time.ns_per_s)),
            };
        } else zero_spec;
        const timeout: ?*const posix.timespec = blk: {
            if (wait_nr == 0) break :blk &zero_spec;
            if (timeout_ns != null) break :blk &bounded_spec;
            break :blk null;
        };

        const changes = self.changes[0..self.change_count];
        if (self.change_count > 0)
            log.debug("kevent: submitting {d} changes", .{self.change_count});

        const event_count = try posix.kevent(self.kqueue_fd, changes, self.events, timeout);
        self.change_count = 0;
        log.debug("kevent: reaped {d} events", .{event_count});

        var count: usize = 0;
        for (self.events[0..event_count]) |event| {
            if (event.flags & system.EV.ERROR != 0) continue;

            const is_wake = event.filter == system.EVFILT.USER;
            self.event_buf[count] = .{
                .token = if (is_wake) undefined else @ptrFromInt(event.udata),
                .kind = if (event.filter == system.EVFILT.READ) .read else .write,
                .eof = event.flags & system.EV.EOF != 0,
                .is_wake = is_wake,
            };
            count += 1;
        }

        return self.event_buf[0..count];
    }
};
