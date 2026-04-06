const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;

const page_size_min = std.heap.page_size_min;

pub const Cqe = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
    extra: [16]u8,

    pub fn err(self: Cqe) linux.E {
        if (self.res > -4096 and self.res < 0) {
            return @as(linux.E, @enumFromInt(-self.res));
        }
        return .SUCCESS;
    }

    pub fn bufferId(self: Cqe) !u16 {
        if (self.flags & linux.IORING_CQE_F_BUFFER == 0) return error.NoBufferSelected;
        return @as(u16, @intCast(self.flags >> linux.IORING_CQE_BUFFER_SHIFT));
    }
};

pub const Ring = struct {
    fd: posix.fd_t = -1,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    flags: u32,
    features: u32,
    cqe_stride: usize,

    pub fn init(entries: u16, flags: u32) !Ring {
        var params = mem.zeroInit(linux.io_uring_params, .{
            .flags = flags,
            .sq_thread_idle = 1000,
        });
        return try initParams(entries, &params);
    }

    pub fn initParams(entries: u16, p: *linux.io_uring_params) !Ring {
        if (entries == 0) return error.EntriesZero;
        if (!std.math.isPowerOfTwo(entries)) return error.EntriesNotPowerOfTwo;

        assert(p.sq_entries == 0);
        assert(p.cq_entries == 0 or p.flags & linux.IORING_SETUP_CQSIZE != 0);
        assert(p.features == 0);
        assert(p.wq_fd == 0 or p.flags & linux.IORING_SETUP_ATTACH_WQ != 0);
        assert(p.resv[0] == 0);
        assert(p.resv[1] == 0);
        assert(p.resv[2] == 0);

        const res = linux.io_uring_setup(entries, p);
        switch (linux.E.init(res)) {
            .SUCCESS => {},
            .FAULT => return error.ParamsOutsideAccessibleAddressSpace,
            .INVAL => return error.ArgumentsInvalid,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            .NOSYS => return error.SystemOutdated,
            else => |errno| return posix.unexpectedErrno(errno),
        }
        const fd = @as(posix.fd_t, @intCast(res));
        assert(fd >= 0);
        errdefer posix.close(fd);

        if ((p.features & linux.IORING_FEAT_SINGLE_MMAP) == 0) {
            return error.SystemOutdated;
        }

        assert(p.sq_entries != 0);
        assert(p.cq_entries != 0);
        assert(p.cq_entries >= p.sq_entries);

        const cqe_stride: usize = if (p.flags & linux.IORING_SETUP_CQE32 != 0) 32 else @sizeOf(linux.io_uring_cqe);

        var sq = try SubmissionQueue.init(fd, p.*, cqe_stride);
        errdefer sq.deinit();
        var cq = try CompletionQueue.init(fd, p.*, sq, cqe_stride);
        errdefer cq.deinit();

        assert(sq.head.* == 0);
        assert(sq.tail.* == 0);
        assert(sq.mask == p.sq_entries - 1);
        assert(sq.dropped.* == 0);
        assert(sq.array.len == p.sq_entries);
        assert(sq.sqes.len == p.sq_entries);
        assert(sq.sqe_head == 0);
        assert(sq.sqe_tail == 0);

        assert(cq.head.* == 0);
        assert(cq.tail.* == 0);
        assert(cq.mask == p.cq_entries - 1);
        assert(cq.overflow.* == 0);
        assert(cq.entries == p.cq_entries);

        return .{
            .fd = fd,
            .sq = sq,
            .cq = cq,
            .flags = p.flags,
            .features = p.features,
            .cqe_stride = cqe_stride,
        };
    }

    pub fn deinit(self: *Ring) void {
        assert(self.fd >= 0);
        self.cq.deinit();
        self.sq.deinit();
        posix.close(self.fd);
        self.fd = -1;
    }

    pub fn getSqe(self: *Ring) !*linux.io_uring_sqe {
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const next = self.sq.sqe_tail +% 1;
        if (next -% head > self.sq.sqes.len) return error.SubmissionQueueFull;
        const sqe = &self.sq.sqes[self.sq.sqe_tail & self.sq.mask];
        self.sq.sqe_tail = next;
        return sqe;
    }

    pub fn flushSq(self: *Ring) u32 {
        if (self.sq.sqe_head != self.sq.sqe_tail) {
            const to_submit = self.sq.sqe_tail -% self.sq.sqe_head;
            var tail = self.sq.tail.*;
            var i: usize = 0;
            while (i < to_submit) : (i += 1) {
                self.sq.array[tail & self.sq.mask] = self.sq.sqe_head & self.sq.mask;
                tail +%= 1;
                self.sq.sqe_head +%= 1;
            }
            @atomicStore(u32, self.sq.tail, tail, .release);
        }
        return self.sqReady();
    }

    pub fn sqRingNeedsEnter(self: *Ring, flags: *u32) bool {
        assert(flags.* == 0);
        if ((self.flags & linux.IORING_SETUP_SQPOLL) == 0) return true;
        if ((@atomicLoad(u32, self.sq.flags, .unordered) & linux.IORING_SQ_NEED_WAKEUP) != 0) {
            flags.* |= linux.IORING_ENTER_SQ_WAKEUP;
            return true;
        }
        return false;
    }

    pub fn sqReady(self: *Ring) u32 {
        return self.sq.sqe_tail -% @atomicLoad(u32, self.sq.head, .acquire);
    }

    pub fn cqReady(self: *Ring) u32 {
        return @atomicLoad(u32, self.cq.tail, .acquire) -% self.cq.head.*;
    }

    pub fn cqRingNeedsFlush(self: *Ring) bool {
        return (@atomicLoad(u32, self.sq.flags, .unordered) & linux.IORING_SQ_CQ_OVERFLOW) != 0;
    }

    pub fn enter(self: *Ring, to_submit: u32, min_complete: u32, flags: u32) !u32 {
        assert(self.fd >= 0);
        const res = linux.io_uring_enter(self.fd, to_submit, min_complete, flags, null);
        switch (linux.E.init(res)) {
            .SUCCESS => {},
            .AGAIN => return error.SystemResources,
            .BADF => return error.FileDescriptorInvalid,
            .BADFD => return error.FileDescriptorInBadState,
            .BUSY => return error.CompletionQueueOvercommitted,
            .INVAL => return error.SubmissionQueueEntryInvalid,
            .FAULT => return error.BufferInvalid,
            .NXIO => return error.RingShuttingDown,
            .OPNOTSUPP => return error.OpcodeNotSupported,
            .INTR => return error.SignalInterrupt,
            else => |errno| return posix.unexpectedErrno(errno),
        }
        return @as(u32, @intCast(res));
    }

    pub fn copyCqes(self: *Ring, cqes: []Cqe, wait_nr: u32) !u32 {
        const count = self.copyCqesReady(cqes);
        if (count > 0) return count;
        if (self.cqRingNeedsFlush() or wait_nr > 0) {
            _ = try self.enter(0, wait_nr, linux.IORING_ENTER_GETEVENTS);
            return self.copyCqesReady(cqes);
        }
        return 0;
    }

    pub fn cqAdvance(self: *Ring, count: u32) void {
        if (count > 0) {
            @atomicStore(u32, self.cq.head, self.cq.head.* +% count, .release);
        }
    }

    fn copyCqesReady(self: *Ring, cqes: []Cqe) u32 {
        const ready = self.cqReady();
        const count = @min(cqes.len, ready);
        var i: usize = 0;
        const head = self.cq.head.* & self.cq.mask;
        while (i < count) : (i += 1) {
            const idx = (head + @as(u32, @intCast(i))) & self.cq.mask;
            self.cq.copyOut(idx, &cqes[i]);
        }
        self.cqAdvance(@intCast(count));
        return @intCast(count);
    }
};

const SubmissionQueue = struct {
    head: *u32,
    tail: *u32,
    mask: u32,
    flags: *u32,
    dropped: *u32,
    array: []u32,
    sqes: []linux.io_uring_sqe,
    mmap: []align(page_size_min) u8,
    mmap_sqes: []align(page_size_min) u8,
    sqe_head: u32 = 0,
    sqe_tail: u32 = 0,

    fn init(fd: posix.fd_t, p: linux.io_uring_params, cqe_stride: usize) !SubmissionQueue {
        assert(fd >= 0);
        assert((p.features & linux.IORING_FEAT_SINGLE_MMAP) != 0);
        const size = @max(
            p.sq_off.array + p.sq_entries * @sizeOf(u32),
            p.cq_off.cqes + p.cq_entries * cqe_stride,
        );
        const mmap = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQ_RING,
        );
        errdefer posix.munmap(mmap);

        const size_sqes = p.sq_entries * @sizeOf(linux.io_uring_sqe);
        const mmap_sqes = try posix.mmap(
            null,
            size_sqes,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQES,
        );
        errdefer posix.munmap(mmap_sqes);

        const array: [*]u32 = @ptrCast(@alignCast(&mmap[p.sq_off.array]));
        const sqes: [*]linux.io_uring_sqe = @ptrCast(@alignCast(&mmap_sqes[0]));
        assert(p.sq_entries == @as(*u32, @ptrCast(@alignCast(&mmap[p.sq_off.ring_entries]))).*);
        return .{
            .head = @ptrCast(@alignCast(&mmap[p.sq_off.head])),
            .tail = @ptrCast(@alignCast(&mmap[p.sq_off.tail])),
            .mask = @as(*u32, @ptrCast(@alignCast(&mmap[p.sq_off.ring_mask]))).*,
            .flags = @ptrCast(@alignCast(&mmap[p.sq_off.flags])),
            .dropped = @ptrCast(@alignCast(&mmap[p.sq_off.dropped])),
            .array = array[0..p.sq_entries],
            .sqes = sqes[0..p.sq_entries],
            .mmap = mmap,
            .mmap_sqes = mmap_sqes,
        };
    }

    fn deinit(self: *SubmissionQueue) void {
        posix.munmap(self.mmap_sqes);
        posix.munmap(self.mmap);
    }
};

const CompletionQueue = struct {
    head: *u32,
    tail: *u32,
    mask: u32,
    overflow: *u32,
    cqes_base: [*]u8,
    entries: u32,
    stride: usize,

    fn init(fd: posix.fd_t, p: linux.io_uring_params, sq: SubmissionQueue, cqe_stride: usize) !CompletionQueue {
        assert(fd >= 0);
        assert((p.features & linux.IORING_FEAT_SINGLE_MMAP) != 0);
        const mmap = sq.mmap;
        assert(p.cq_entries == @as(*u32, @ptrCast(@alignCast(&mmap[p.cq_off.ring_entries]))).*);
        return .{
            .head = @ptrCast(@alignCast(&mmap[p.cq_off.head])),
            .tail = @ptrCast(@alignCast(&mmap[p.cq_off.tail])),
            .mask = @as(*u32, @ptrCast(@alignCast(&mmap[p.cq_off.ring_mask]))).*,
            .overflow = @ptrCast(@alignCast(&mmap[p.cq_off.overflow])),
            .cqes_base = @ptrCast(&mmap[p.cq_off.cqes]),
            .entries = p.cq_entries,
            .stride = cqe_stride,
        };
    }

    fn deinit(self: *CompletionQueue) void {
        _ = self;
    }

    fn copyOut(self: *const CompletionQueue, idx: u32, out: *Cqe) void {
        out.* = std.mem.zeroes(Cqe);
        const src = self.cqes_base + (@as(usize, idx) * self.stride);
        const src_bytes: [*]const u8 = src;
        const dst_bytes = std.mem.asBytes(out);
        @memcpy(dst_bytes[0..self.stride], src_bytes[0..self.stride]);
    }
};

pub fn setupBufRing(
    fd: posix.fd_t,
    entries: u16,
    group_id: u16,
    flags: linux.io_uring_buf_reg.Flags,
) !*align(page_size_min) linux.io_uring_buf_ring {
    if (entries == 0 or entries > 1 << 15) return error.EntriesNotInRange;
    if (!std.math.isPowerOfTwo(entries)) return error.EntriesNotPowerOfTwo;

    const mmap_size = @as(usize, entries) * @sizeOf(linux.io_uring_buf);
    const mmap = try posix.mmap(
        null,
        mmap_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer posix.munmap(mmap);

    const br: *align(page_size_min) linux.io_uring_buf_ring = @ptrCast(mmap.ptr);
    try registerBufRing(fd, @intFromPtr(br), entries, group_id, flags);
    return br;
}

pub fn freeBufRing(fd: posix.fd_t, br: *align(page_size_min) linux.io_uring_buf_ring, entries: u32, group_id: u16) !void {
    try unregisterBufRing(fd, group_id);
    var mmap: []align(page_size_min) u8 = undefined;
    mmap.ptr = @ptrCast(br);
    mmap.len = entries * @sizeOf(linux.io_uring_buf);
    posix.munmap(mmap);
}

pub fn bufRingInit(br: *linux.io_uring_buf_ring) void {
    br.tail = 0;
}

pub fn bufRingMask(entries: u16) u16 {
    return entries - 1;
}

pub fn bufRingAdd(
    br: *linux.io_uring_buf_ring,
    buffer: []u8,
    buffer_id: u16,
    mask: u16,
    buffer_offset: u16,
) void {
    const bufs: [*]linux.io_uring_buf = @ptrCast(br);
    const buf: *linux.io_uring_buf = &bufs[(br.tail +% buffer_offset) & mask];
    buf.addr = @intFromPtr(buffer.ptr);
    buf.len = @intCast(buffer.len);
    buf.bid = buffer_id;
}

pub fn bufRingAdvance(br: *linux.io_uring_buf_ring, count: u16) void {
    const tail: u16 = br.tail +% count;
    @atomicStore(u16, &br.tail, tail, .release);
}

fn registerBufRing(
    fd: posix.fd_t,
    addr: u64,
    entries: u32,
    group_id: u16,
    flags: linux.io_uring_buf_reg.Flags,
) !void {
    var reg = mem.zeroInit(linux.io_uring_buf_reg, .{
        .ring_addr = addr,
        .ring_entries = entries,
        .bgid = group_id,
        .flags = flags,
    });
    var res = linux.io_uring_register(fd, .REGISTER_PBUF_RING, @as(*const anyopaque, @ptrCast(&reg)), 1);
    if (linux.E.init(res) == .INVAL and reg.flags.inc) {
        reg.flags.inc = false;
        res = linux.io_uring_register(fd, .REGISTER_PBUF_RING, @as(*const anyopaque, @ptrCast(&reg)), 1);
    }
    try handleRegisterBufRingResult(res);
}

fn unregisterBufRing(fd: posix.fd_t, group_id: u16) !void {
    var reg = mem.zeroInit(linux.io_uring_buf_reg, .{
        .bgid = group_id,
    });
    const res = linux.io_uring_register(fd, .UNREGISTER_PBUF_RING, @as(*const anyopaque, @ptrCast(&reg)), 1);
    try handleRegisterBufRingResult(res);
}

fn handleRegisterBufRingResult(res: usize) !void {
    switch (linux.E.init(res)) {
        .SUCCESS => {},
        .INVAL => return error.ArgumentsInvalid,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}
