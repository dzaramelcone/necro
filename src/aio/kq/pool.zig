// TODO genericize slab and use here when we redo kq

const std = @import("std");

pub const CAPACITY: usize = 64 * 1024;
pub const DEFAULT_BUFFER_COUNT: usize = 64;

const page_align = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const Pool = struct {
    allocator: std.mem.Allocator,
    buffers: []Buffer,
    free_stack: []u16,
    free_len: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_count: usize) !Pool {
        if (buffer_count > std.math.maxInt(u16)) return error.TransportPoolTooLarge;

        const buffers = try allocator.alloc(Buffer, buffer_count);
        errdefer allocator.free(buffers);

        const free_stack = try allocator.alloc(u16, buffer_count);
        errdefer allocator.free(free_stack);

        var allocated: usize = 0;
        errdefer {
            for (buffers[0..allocated]) |buf| {
                std.heap.page_allocator.free(buf.data);
            }
        }

        for (buffers, 0..) |*buf, idx| {
            const data = try std.heap.page_allocator.alignedAlloc(u8, page_align, CAPACITY);
            allocated = idx + 1;
            buf.* = .{
                .id = @intCast(idx),
                .data = data,
            };
            free_stack[idx] = @intCast(buffer_count - idx - 1);
        }

        return .{
            .allocator = allocator,
            .buffers = buffers,
            .free_stack = free_stack,
            .free_len = buffer_count,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.buffers) |buf| {
            std.heap.page_allocator.free(buf.data);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.free_stack);
        self.* = undefined;
    }

    pub fn acquire(self: *Pool) !*Buffer {
        if (self.free_len == 0) return error.TransportPoolExhausted;
        self.free_len -= 1;
        const idx = self.free_stack[self.free_len];
        const buf = &self.buffers[idx];
        std.debug.assert(!buf.in_use);
        buf.in_use = true;
        return buf;
    }

    pub fn release(self: *Pool, buf: *Buffer) void {
        std.debug.assert(buf.id < self.buffers.len);
        std.debug.assert(buf.in_use);
        buf.in_use = false;
        self.free_stack[self.free_len] = buf.id;
        self.free_len += 1;
    }

    pub fn bufferCount(self: *const Pool) usize {
        return self.buffers.len;
    }

    pub fn freeCount(self: *const Pool) usize {
        return self.free_len;
    }

    pub fn inUseCount(self: *const Pool) usize {
        return self.buffers.len - self.free_len;
    }
};

pub const Buffer = struct {
    id: u16,
    data: []align(std.heap.page_size_min) u8,
    in_use: bool = false,
};

test "transport pool reuses released buffers" {
    var pool = try Pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    const first = try pool.acquire();
    const second = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectError(error.TransportPoolExhausted, pool.acquire());

    pool.release(first);
    pool.release(second);
    try std.testing.expectEqual(@as(usize, 2), pool.freeCount());

    const reused = try pool.acquire();
    try std.testing.expectEqual(second.id, reused.id);
    pool.release(reused);
}
