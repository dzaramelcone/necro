const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const sys = @import("sys.zig");
const ring = @import("ring.zig");
const log = std.log.scoped(.@"necro/uring/recv_group");

pub const DEFAULT_BUFFER_SIZE: u32 = 64 * 1024;
pub const DEFAULT_BUFFER_COUNT: u16 = 64;
pub const DEFAULT_GROUP_ID: u16 = 1;

const page_align = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const Lease = struct {
    buffer_id: u16,
    bytes: []u8,
};

pub const Group = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,
    buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    storage: []align(std.heap.page_size_min) u8,
    checked_out: []bool,
    buffer_size: u32,
    buffer_count: u16,
    group_id: u16,
    in_use_count: usize = 0,

    pub fn init(
        fd: posix.fd_t,
        allocator: std.mem.Allocator,
        group_id: u16,
        buffer_size: u32,
        buffer_count: u16,
    ) !Group {
        if (buffer_size == 0 or buffer_count == 0) return error.InvalidConfiguration;
        if (!std.math.isPowerOfTwo(buffer_count)) return error.BufferCountMustBePowerOfTwo;

        const total_bytes = @as(usize, buffer_size) * @as(usize, buffer_count);
        const storage = try std.heap.page_allocator.alignedAlloc(u8, page_align, total_bytes);
        errdefer std.heap.page_allocator.free(storage);

        const checked_out = try allocator.alloc(bool, buffer_count);
        errdefer allocator.free(checked_out);
        @memset(checked_out, false);

        const br = try ring.setupBufRing(fd, buffer_count, group_id, .{ .inc = false });
        errdefer ring.freeBufRing(fd, br, buffer_count, group_id) catch |e| {
            log.err("freeBufRing failed during init rollback: {}", .{e});
        };

        ring.bufRingInit(br);
        const mask = ring.bufRingMask(buffer_count);

        var idx: u16 = 0;
        while (idx < buffer_count) : (idx += 1) {
            const start = @as(usize, idx) * @as(usize, buffer_size);
            const buf = storage[start .. start + buffer_size];
            ring.bufRingAdd(br, buf, idx, mask, idx);
        }
        ring.bufRingAdvance(br, buffer_count);

        return .{
            .fd = fd,
            .allocator = allocator,
            .buf_ring = br,
            .storage = storage,
            .checked_out = checked_out,
            .buffer_size = buffer_size,
            .buffer_count = buffer_count,
            .group_id = group_id,
        };
    }

    pub fn deinit(self: *Group) !void {
        try ring.freeBufRing(self.fd, self.buf_ring, self.buffer_count, self.group_id);
        std.heap.page_allocator.free(self.storage);
        self.allocator.free(self.checked_out);
        self.* = undefined;
    }

    pub fn groupId(self: *const Group) u16 {
        return self.group_id;
    }

    pub fn bufferCount(self: *const Group) usize {
        return self.buffer_count;
    }

    pub fn inUseCount(self: *const Group) usize {
        return self.in_use_count;
    }

    pub fn freeCount(self: *const Group) usize {
        return self.buffer_count - self.in_use_count;
    }

    pub fn totalBytes(self: *const Group) usize {
        return @as(usize, self.buffer_size) * @as(usize, self.buffer_count);
    }

    pub fn take(self: *Group, completion: sys.Completion) !Lease {
        if (completion.result <= 0) return error.InvalidCompletion;
        if (completion.buffer_more) return error.IncrementalBufferUnsupported;

        const buffer_id = completion.buffer_id orelse return error.NoBufferSelected;
        if (buffer_id >= self.buffer_count) return error.BufferIdInvalid;
        if (self.checked_out[buffer_id]) return error.BufferAlreadyCheckedOut;

        const len: usize = @intCast(completion.result);
        if (len > self.buffer_size) return error.BufferOverflow;

        self.checked_out[buffer_id] = true;
        self.in_use_count += 1;

        return .{
            .buffer_id = buffer_id,
            .bytes = self.bufferSlice(buffer_id)[0..len],
        };
    }

    pub fn release(self: *Group, lease: Lease) void {
        std.debug.assert(lease.buffer_id < self.buffer_count);
        std.debug.assert(self.checked_out[lease.buffer_id]);

        self.checked_out[lease.buffer_id] = false;
        self.in_use_count -= 1;

        const mask = ring.bufRingMask(self.buffer_count);
        ring.bufRingAdd(self.buf_ring, self.bufferSlice(lease.buffer_id), lease.buffer_id, mask, 0);
        ring.bufRingAdvance(self.buf_ring, 1);
    }

    fn bufferSlice(self: *Group, buffer_id: u16) []u8 {
        const start = @as(usize, buffer_id) * @as(usize, self.buffer_size);
        return self.storage[start .. start + self.buffer_size];
    }
};
