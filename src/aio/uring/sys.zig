//! io_uring backend — backend-owned pending slots with decoded CQE metadata.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const necro_log = @import("../log.zig");
const ring = @import("ring.zig");

const log = std.log.scoped(.@"necro/aio/uring/sys");
const ring_base_flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
const ring_tuned_flags = ring_base_flags | linux.IORING_SETUP_CQE32;
const ring_sqpoll_idle_ms: u32 = 2000;

pub const Op = union(enum) {
    accept: struct {
        socket: std.posix.socket_t,
    },
    accept_multishot: struct {
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
    recv_multishot: struct {
        socket: std.posix.socket_t,
        buffer_group: u16,
        flags: u32 = 0,
    },
    send: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
    },
    send_zc: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
        send_flags: u32 = 0,
        zc_flags: u16 = 0,
    },
    sendmsg_zc: struct {
        socket: std.posix.socket_t,
        msg: *const posix.msghdr_const,
        send_flags: u32 = 0,
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

pub const Completion = struct {
    result: i32,
    flags: u32 = 0,
    buffer_id: ?u16 = null,
    more: bool = false,
    notification: bool = false,
    buffer_more: bool = false,
};

pub const CompletionBatch = struct {
    tokens: []*anyopaque,
    completions: []Completion,
};

pub const IoUring = struct {
    const PendingKind = enum(u8) {
        oneshot,
        multishot,
        send_zc,
    };

    const PendingSlot = struct {
        in_use: bool = false,
        token: *anyopaque = undefined,
        kind: PendingKind = .oneshot,
    };

    ring: ring.Ring,
    pending: []PendingSlot,
    free_stack: []u16,
    free_len: usize,
    tokens_buf: []*anyopaque,
    completion_buf: []Completion,
    cqe_buf: []ring.Cqe,

    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUring {
        const ring = try initRingWithFallbacks(entries);
        const pending = try allocator.alloc(PendingSlot, entries);
        for (pending) |*slot| slot.* = .{};
        const free_stack = try allocator.alloc(u16, entries);
        for (free_stack, 0..) |*slot, idx| {
            slot.* = @intCast(entries - idx - 1);
        }

        return .{
            .ring = ring,
            .pending = pending,
            .free_stack = free_stack,
            .free_len = entries,
            .tokens_buf = try allocator.alloc(*anyopaque, entries),
            .completion_buf = try allocator.alloc(Completion, entries),
            .cqe_buf = try allocator.alloc(ring.Cqe, entries),
        };
    }

    pub fn deinit(self: *IoUring, allocator: std.mem.Allocator) void {
        self.ring.deinit();
        allocator.free(self.pending);
        allocator.free(self.free_stack);
        allocator.free(self.tokens_buf);
        allocator.free(self.completion_buf);
        allocator.free(self.cqe_buf);
    }

    pub fn queue(self: *IoUring, token: *anyopaque, op: Op) !void {
        log.debug("sqe: {s}", .{@tagName(op)});
        const slot_idx = try self.allocPending(token, pendingKindFor(op));
        errdefer self.releasePending(slot_idx);
        const udata: u64 = slot_idx + 1;
        switch (op) {
            .accept => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_accept(inner.socket, null, null, 0);
                sqe.user_data = udata;
            },
            .accept_multishot => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_multishot_accept(inner.socket, null, null, 0);
                sqe.user_data = udata;
            },
            .recv => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_recv(inner.socket, inner.buffer, 0);
                sqe.user_data = udata;
            },
            .recv_multishot => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_rw(.RECV, inner.socket, 0, 0, 0);
                sqe.rw_flags = inner.flags;
                sqe.flags |= linux.IOSQE_BUFFER_SELECT;
                sqe.buf_index = inner.buffer_group;
                sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
                sqe.user_data = udata;
            },
            .send => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_send(inner.socket, inner.buffer, 0);
                sqe.user_data = udata;
            },
            .send_zc => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_send_zc(inner.socket, inner.buffer, inner.send_flags, inner.zc_flags);
                sqe.user_data = udata;
            },
            .sendmsg_zc => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_sendmsg_zc(inner.socket, inner.msg, inner.send_flags);
                sqe.user_data = udata;
            },
            .sendv => |inner| {
                const sqe = try self.ring.getSqe();
                sqe.prep_writev(inner.socket, inner.iovecs, 0);
                sqe.user_data = udata;
            },
            .connect => |inner| {
                var addr = inner.addr;
                const sqe = try self.ring.getSqe();
                sqe.prep_connect(inner.socket, &addr.any, addr.getOsSockLen());
                sqe.user_data = udata;
            },
            .close => |fd| {
                const sqe = try self.ring.getSqe();
                sqe.prep_close(fd);
                sqe.user_data = udata;
            },
            .timer => |inner| {
                const ts: linux.kernel_timespec = .{ .sec = inner.seconds, .nsec = inner.nanos };
                const sqe = try self.ring.getSqe();
                sqe.prep_timeout(&ts, 0, 0);
                sqe.user_data = udata;
            },
        }
    }

    pub fn publish(self: *IoUring) !void {
        const to_submit = self.ring.flushSq();
        var flags: u32 = 0;
        const need_enter = self.ring.sqRingNeedsEnter(&flags);
        if (to_submit == 0 and !need_enter) return;

        _ = while (true) {
            break self.ring.enter(to_submit, 0, flags) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => return e,
            };
        };
    }

    pub fn reap(self: *IoUring, wait_nr: u32) !CompletionBatch {
        necro_log.bumpLoop();
        const count = while (true) {
            break self.ring.copyCqes(self.cqe_buf, wait_nr) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => return e,
            };
        };

        log.debug("io_uring: reaped={d} wait={d}", .{ count, wait_nr });

        for (self.cqe_buf[0..count], 0..) |cqe, i| {
            std.debug.assert(cqe.user_data != 0);
            const slot_idx: usize = @intCast(cqe.user_data - 1);
            std.debug.assert(slot_idx < self.pending.len);
            const slot = &self.pending[slot_idx];
            const completion = decodeCompletion(cqe);
            self.tokens_buf[i] = slot.token;
            self.completion_buf[i] = completion;
            if (shouldReleasePending(slot.kind, completion)) self.releasePending(slot_idx);
        }

        return .{
            .tokens = self.tokens_buf[0..count],
            .completions = self.completion_buf[0..count],
        };
    }

    fn initRingWithFallbacks(entries: u16) !ring.Ring {
        return tryInitRing(entries, ring_tuned_flags | linux.IORING_SETUP_SQPOLL, ring_sqpoll_idle_ms) catch |err| switch (err) {
            error.PermissionDenied, error.ArgumentsInvalid, error.SystemOutdated => tryInitRing(entries, ring_tuned_flags, 0) catch |fallback_err| switch (fallback_err) {
                error.ArgumentsInvalid, error.SystemOutdated => tryInitRing(entries, ring_base_flags, 0) catch |legacy_err| switch (legacy_err) {
                    error.ArgumentsInvalid, error.SystemOutdated => ring.Ring.init(entries, 0),
                    else => legacy_err,
                },
                else => fallback_err,
            },
            else => return err,
        };
    }

    fn tryInitRing(entries: u16, flags: u32, sq_thread_idle: u32) !ring.Ring {
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = flags,
            .sq_thread_idle = sq_thread_idle,
        });
        return try ring.Ring.initParams(entries, &params);
    }

    fn allocPending(self: *IoUring, token: *anyopaque, kind: PendingKind) !usize {
        if (self.free_len == 0) return error.Overflow;
        self.free_len -= 1;
        const idx = self.free_stack[self.free_len];
        self.pending[idx] = .{
            .in_use = true,
            .token = token,
            .kind = kind,
        };
        return idx;
    }

    fn releasePending(self: *IoUring, idx: usize) void {
        std.debug.assert(idx < self.pending.len);
        std.debug.assert(self.pending[idx].in_use);
        self.pending[idx] = .{};
        self.free_stack[self.free_len] = @intCast(idx);
        self.free_len += 1;
    }

    fn pendingKindFor(op: Op) PendingKind {
        return switch (op) {
            .accept_multishot, .recv_multishot => .multishot,
            .send_zc, .sendmsg_zc => .send_zc,
            else => .oneshot,
        };
    }

    fn decodeCompletion(cqe: ring.Cqe) Completion {
        const flags = cqe.flags;
        return .{
            .result = cqe.res,
            .flags = flags,
            .buffer_id = if (flags & linux.IORING_CQE_F_BUFFER != 0) cqe.bufferId() catch null else null,
            .more = flags & linux.IORING_CQE_F_MORE != 0,
            .notification = flags & linux.IORING_CQE_F_NOTIF != 0,
            .buffer_more = flags & linux.IORING_CQE_F_BUF_MORE != 0,
        };
    }

    fn shouldReleasePending(kind: PendingKind, completion: Completion) bool {
        return switch (kind) {
            .oneshot => true,
            .multishot => !completion.more,
            .send_zc => completion.notification or !completion.more,
        };
    }
};

test "decodeCompletion extracts io_uring CQE metadata" {
    const cqe = ring.Cqe{
        .user_data = 1,
        .res = 128,
        .flags = linux.IORING_CQE_F_BUFFER |
            linux.IORING_CQE_F_MORE |
            linux.IORING_CQE_F_NOTIF |
            linux.IORING_CQE_F_BUF_MORE |
            (@as(u32, 7) << linux.IORING_CQE_BUFFER_SHIFT),
        .extra = [_]u8{0} ** 16,
    };

    const completion = IoUring.decodeCompletion(cqe);
    try std.testing.expectEqual(@as(i32, 128), completion.result);
    try std.testing.expectEqual(@as(?u16, 7), completion.buffer_id);
    try std.testing.expect(completion.more);
    try std.testing.expect(completion.notification);
    try std.testing.expect(completion.buffer_more);
}

test "shouldReleasePending honors multishot and zerocopy send lifetimes" {
    try std.testing.expect(!IoUring.shouldReleasePending(.multishot, .{
        .result = 64,
        .more = true,
    }));
    try std.testing.expect(IoUring.shouldReleasePending(.multishot, .{
        .result = -@as(i32, @intFromEnum(posix.E.NOBUFS)),
    }));

    try std.testing.expect(!IoUring.shouldReleasePending(.send_zc, .{
        .result = 64,
        .more = true,
    }));
    try std.testing.expect(IoUring.shouldReleasePending(.send_zc, .{
        .result = 0,
        .notification = true,
    }));
}
