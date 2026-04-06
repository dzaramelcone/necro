//! kqueue backend — readiness notifications backed by per-backend pending slots.

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const necro_log = @import("../log.zig");

const log = std.log.scoped(.@"necro/aio/kq");

pub const Op = union(enum) {
    accept: struct {
        socket: std.posix.socket_t,
    },
    connect: struct {
        socket: std.posix.socket_t,
        addr: std.net.Address,
    },
    recv: struct {
        socket: std.posix.socket_t,
        buffer: []u8,
    },
    send: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
    },
    sendv: struct {
        socket: std.posix.socket_t,
        iovecs: []const std.posix.iovec_const,
    },
    close: std.posix.socket_t,
    timer: struct {
        seconds: u63,
        nanos: u32,
    },
};

const OpTag = std.meta.Tag(Op);

pub const Completion = struct {
    op_tag: OpTag,
    result: i32,
};

pub const Kqueue = struct {
    const PendingSlot = struct {
        in_use: bool = false,
        token: *anyopaque = undefined,
        op: Op = undefined,
    };

    kqueue_fd: posix.fd_t,
    changes: []posix.Kevent,
    events: []posix.Kevent,
    pending: []PendingSlot,
    free_stack: []u16,
    free_len: usize,
    tokens_buf: []*anyopaque,
    completion_buf: []Completion,
    change_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !Kqueue {
        const pending = try allocator.alloc(PendingSlot, max_events);
        for (pending) |*slot| slot.* = .{};
        const free_stack = try allocator.alloc(u16, max_events);
        for (free_stack, 0..) |*slot, idx| {
            slot.* = @intCast(max_events - idx - 1);
        }
        return .{
            .kqueue_fd = try posix.kqueue(),
            .changes = try allocator.alloc(posix.Kevent, max_events),
            .events = try allocator.alloc(posix.Kevent, max_events),
            .pending = pending,
            .free_stack = free_stack,
            .free_len = max_events,
            .tokens_buf = try allocator.alloc(*anyopaque, max_events),
            .completion_buf = try allocator.alloc(Completion, max_events),
        };
    }

    pub fn deinit(self: *Kqueue, allocator: std.mem.Allocator) void {
        posix.close(self.kqueue_fd);
        allocator.free(self.changes);
        allocator.free(self.events);
        allocator.free(self.pending);
        allocator.free(self.free_stack);
        allocator.free(self.tokens_buf);
        allocator.free(self.completion_buf);
    }

    pub fn queue(self: *Kqueue, token: *anyopaque, op: Op) !void {
        log.debug("queue: {s}", .{@tagName(op)});

        if (self.change_count >= self.changes.len) return error.Overflow;

        switch (op) {
            .accept => |inner| {
                const slot_idx = try self.allocPending(token, op);
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.READ,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(slot_idx + 1),
                };
                self.change_count += 1;
            },
            .recv => |inner| {
                const slot_idx = try self.allocPending(token, op);
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.READ,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(slot_idx + 1),
                };
                self.change_count += 1;
            },
            .send => |inner| {
                const slot_idx = try self.allocPending(token, op);
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(slot_idx + 1),
                };
                self.change_count += 1;
            },
            .sendv => |inner| {
                const slot_idx = try self.allocPending(token, op);
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(slot_idx + 1),
                };
                self.change_count += 1;
            },
            .connect => |inner| {
                const slot_idx = try self.allocPending(token, op);
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(slot_idx + 1),
                };
                self.change_count += 1;
            },
            .close => |fd| {
                posix.close(fd);
            },
            .timer => {},
        }
    }

    pub fn submitAndWait(self: *Kqueue, wait_nr: u32) !struct { tokens: []*anyopaque, completions: []Completion } {
        necro_log.bumpLoop();

        const timeout_spec: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const timeout: ?*const posix.timespec = if (wait_nr == 0) &timeout_spec else null;

        const changes = self.changes[0..self.change_count];
        if (self.change_count > 0)
            log.debug("kevent: submitting {d} changes", .{self.change_count});

        const event_count = try posix.kevent(self.kqueue_fd, changes, self.events, timeout);
        self.change_count = 0;
        log.debug("kevent: reaped {d} events", .{event_count});

        var result_count: usize = 0;
        for (self.events[0..event_count]) |event| {
            const slot_idx: usize = @intCast(event.udata - 1);
            const slot = &self.pending[slot_idx];
            defer self.releasePending(slot_idx);

            self.tokens_buf[result_count] = slot.token;
            self.completion_buf[result_count] = .{
                .op_tag = std.meta.activeTag(slot.op),
                .result = performIo(slot.op),
            };
            result_count += 1;
        }

        return .{
            .tokens = self.tokens_buf[0..result_count],
            .completions = self.completion_buf[0..result_count],
        };
    }

    fn allocPending(self: *Kqueue, token: *anyopaque, op: Op) !usize {
        if (self.free_len == 0) return error.Overflow;
        self.free_len -= 1;
        const idx = self.free_stack[self.free_len];
        self.pending[idx] = .{ .in_use = true, .token = token, .op = op };
        return idx;
    }

    fn releasePending(self: *Kqueue, idx: usize) void {
        std.debug.assert(idx < self.pending.len);
        std.debug.assert(self.pending[idx].in_use);
        self.pending[idx] = .{};
        self.free_stack[self.free_len] = @intCast(idx);
        self.free_len += 1;
    }

    /// Perform the syscall that kqueue said is ready.
    fn performIo(op: Op) i32 {
        switch (op) {
            .accept => |inner| {
                var addr: posix.sockaddr = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                const rc = system.accept(inner.socket, &addr, @ptrCast(&addr_len));
                return @intCast(rc);
            },
            .recv => |inner| {
                const rc = system.recvfrom(inner.socket, inner.buffer.ptr, inner.buffer.len, 0, null, null);
                return @intCast(rc);
            },
            .send => |inner| {
                const rc = system.sendto(inner.socket, inner.buffer.ptr, inner.buffer.len, 0, null, 0);
                return @intCast(rc);
            },
            .sendv => |inner| {
                const rc = system.writev(inner.socket, inner.iovecs.ptr, @intCast(inner.iovecs.len));
                return @intCast(rc);
            },
            .connect => return 0,
            .close => return 0,
            .timer => return 0,
        }
    }
};
