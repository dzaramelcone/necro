const std = @import("std");

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        free_stack: []*T,
        free_len: usize,
        backing_allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            std.debug.assert(count > 0);
            const items = try allocator.alloc(T, count);
            errdefer allocator.free(items);
            const free_stack = try allocator.alloc(*T, count);

            for (0..count) |i| free_stack[i] = &items[count - 1 - i];

            return .{
                .items = items,
                .free_stack = free_stack,
                .free_len = count,
                .backing_allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.backing_allocator.free(self.free_stack);
            self.backing_allocator.free(self.items);
            self.* = undefined;
        }

        pub fn borrow(self: *Self) !*T {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            return self.free_stack[self.free_len];
        }

        pub fn release(self: *Self, item: *T) void {
            std.debug.assert(self.free_len < self.items.len);
            self.free_stack[self.free_len] = item;
            self.free_len += 1;
        }

        pub fn numActive(self: *const Self) usize {
            return self.items.len - self.free_len;
        }
    };
}

test "Pool: borrow returns pointer, release reuses slot" {
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

test "Pool: exhaustion returns PoolExhausted" {
    var pool: Pool(u8) = try .init(std.testing.allocator, 2);
    defer pool.deinit();
    _ = try pool.borrow();
    _ = try pool.borrow();
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
}

test "Pool: borrow returns stable pointer" {
    var pool: Pool(u64) = try .init(std.testing.allocator, 4);
    defer pool.deinit();

    const ptr = try pool.borrow();
    ptr.* = 0xDEADBEEF;

    _ = try pool.borrow();
    _ = try pool.borrow();

    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), ptr.*);
}
