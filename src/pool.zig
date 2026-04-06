const std = @import("std");

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        active: []bool,
        free_stack: []u16,
        free_len: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            const items = try allocator.alloc(T, size);
            errdefer allocator.free(items);
            const active = try allocator.alloc(bool, size);
            errdefer allocator.free(active);
            const free_stack = try allocator.alloc(u16, size);
            errdefer allocator.free(free_stack);

            @memset(active, false);
            for (free_stack, 0..) |*slot, i| {
                slot.* = @intCast(size - 1 - i);
            }

            return .{
                .items = items,
                .active = active,
                .free_stack = free_stack,
                .free_len = size,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.active);
            self.allocator.free(self.free_stack);
        }

        pub fn borrow(self: *Self) !usize {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            const idx = self.free_stack[self.free_len];
            self.active[idx] = true;
            return idx;
        }

        pub fn release(self: *Self, idx: usize) void {
            std.debug.assert(self.active[idx]);
            self.active[idx] = false;
            self.free_stack[self.free_len] = @intCast(idx);
            self.free_len += 1;
        }

        pub fn get(self: *const Self, idx: usize) *T {
            return &self.items[idx];
        }
    };
}

test "borrow and release" {
    var pool: Pool(u64) = try .init(std.testing.allocator, 4);
    defer pool.deinit();

    const a = try pool.borrow();
    const b = try pool.borrow();
    try std.testing.expect(a != b);

    pool.release(a);
    const c = try pool.borrow();
    try std.testing.expectEqual(a, c);
    pool.release(b);
    pool.release(c);
}

test "exhaustion" {
    var pool: Pool(u8) = try .init(std.testing.allocator, 2);
    defer pool.deinit();

    _ = try pool.borrow();
    _ = try pool.borrow();
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
}

test "release then re-borrow fills all slots" {
    var pool: Pool(u32) = try .init(std.testing.allocator, 3);
    defer pool.deinit();

    const a = try pool.borrow();
    const b = try pool.borrow();
    const cc = try pool.borrow();
    try std.testing.expectError(error.PoolExhausted, pool.borrow());

    pool.release(b);
    const d = try pool.borrow();
    try std.testing.expectEqual(b, d);

    pool.release(a);
    pool.release(cc);
    pool.release(d);
}

test "borrow returns distinct indices" {
    var pool: Pool(u8) = try .init(std.testing.allocator, 64);
    defer pool.deinit();

    var seen = [_]bool{false} ** 64;
    for (0..64) |_| {
        const idx = try pool.borrow();
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "get returns stable pointer across borrow/release" {
    var pool: Pool(u64) = try .init(std.testing.allocator, 4);
    defer pool.deinit();

    const idx = try pool.borrow();
    const ptr = pool.get(idx);
    ptr.* = 0xDEADBEEF;

    _ = try pool.borrow();
    _ = try pool.borrow();

    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), pool.get(idx).*);
    try std.testing.expectEqual(ptr, pool.get(idx));
}

test "lifo reuse order" {
    var pool: Pool(u8) = try .init(std.testing.allocator, 4);
    defer pool.deinit();

    const a = try pool.borrow();
    const b = try pool.borrow();
    pool.release(a);
    pool.release(b);

    const first = try pool.borrow();
    const second = try pool.borrow();
    try std.testing.expectEqual(b, first);
    try std.testing.expectEqual(a, second);
}

test "size 1 pool" {
    var pool: Pool(u8) = try .init(std.testing.allocator, 1);
    defer pool.deinit();

    const idx = try pool.borrow();
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
    pool.release(idx);
    const again = try pool.borrow();
    try std.testing.expectEqual(idx, again);
    pool.release(again);
}
