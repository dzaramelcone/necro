const std = @import("std");

pub const Lease = enum(u16) { _ };

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        backing: []align(@alignOf(T)) u8,
        items: []T,
        free_stack: []u16,
        free_len: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, size: u16) !Self {
            std.debug.assert(size > 0);

            const items_bytes = @as(usize, size) * @sizeOf(T);
            const free_stack_offset = std.mem.alignForward(usize, items_bytes, @alignOf(u16));
            const total = free_stack_offset + @as(usize, size) * @sizeOf(u16);

            const backing = try allocator.alignedAlloc(u8, std.mem.Alignment.of(T), total);
            errdefer allocator.free(backing);

            const items_ptr: [*]T = @ptrCast(backing.ptr);
            const items = items_ptr[0..size];

            const free_stack_ptr: [*]u16 = @ptrCast(@alignCast(backing.ptr + free_stack_offset));
            const free_stack = free_stack_ptr[0..size];

            var i: u16 = 0;
            while (i < size) : (i += 1) free_stack[i] = size - 1 - i;

            return .{
                .backing = backing,
                .items = items,
                .free_stack = free_stack,
                .free_len = size,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.backing);
            self.* = undefined;
        }

        pub fn borrow(self: *Self) !Lease {
            if (self.free_len == 0) return error.PoolExhausted;
            self.free_len -= 1;
            return @enumFromInt(self.free_stack[self.free_len]);
        }

        pub fn release(self: *Self, lease: Lease) void {
            const idx = @intFromEnum(lease);
            std.debug.assert(idx < self.items.len);
            std.debug.assert(self.free_len < self.items.len);
            self.free_stack[self.free_len] = idx;
            self.free_len += 1;
        }

        pub fn get(self: *const Self, lease: Lease) *T {
            return &self.items[@intFromEnum(lease)];
        }

        pub fn numActive(self: *const Self) usize {
            return self.items.len - self.free_len;
        }
    };
}

pub fn RefCountedPool(comptime T: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            refs: u16 = 0,
            body: T = .{},
        };

        inner: Pool(Entry),

        pub fn init(allocator: std.mem.Allocator, size: u16) !Self {
            return .{ .inner = try Pool(Entry).init(allocator, size) };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn borrow(self: *Self) !Lease {
            const lease = try self.inner.borrow();
            self.inner.get(lease).refs = 1;
            return lease;
        }

        pub fn release(self: *Self, lease: Lease) void {
            const entry = self.inner.get(lease);
            std.debug.assert(entry.refs > 0);
            entry.refs -= 1;
            if (entry.refs == 0) self.inner.release(lease);
        }

        pub fn retain(self: *Self, lease: Lease) void {
            const entry = self.inner.get(lease);
            std.debug.assert(entry.refs > 0);
            entry.refs += 1;
        }

        pub fn get(self: *const Self, lease: Lease) *T {
            return &self.inner.get(lease).body;
        }
    };
}

test "Pool: borrow, release, reuse" {
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

test "Pool: get returns stable pointer" {
    var pool: Pool(u64) = try .init(std.testing.allocator, 4);
    defer pool.deinit();

    const l = try pool.borrow();
    const ptr = pool.get(l);
    ptr.* = 0xDEADBEEF;

    _ = try pool.borrow();
    _ = try pool.borrow();

    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), pool.get(l).*);
    try std.testing.expectEqual(ptr, pool.get(l));
}

test "RefCountedPool: retain keeps slot alive until last release" {
    const Dummy = struct { val: u32 = 0 };
    var pool: RefCountedPool(Dummy) = try .init(std.testing.allocator, 1);
    defer pool.deinit();

    const l = try pool.borrow();
    pool.retain(l);

    pool.release(l);
    try std.testing.expectError(error.PoolExhausted, pool.borrow());

    pool.release(l);
    const l2 = try pool.borrow();
    try std.testing.expectEqual(l, l2);
    pool.release(l2);
}
