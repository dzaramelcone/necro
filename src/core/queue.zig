const std = @import("std");

pub fn Queue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    const MASK: usize = capacity - 1;

    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, item: T) !void {
            if (self.len == capacity) return error.Overflow;
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) & MASK;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) & MASK;
            self.len -= 1;
            return item;
        }

        pub fn peek(self: *const Self) ?*const T {
            if (self.len == 0) return null;
            return &self.items[self.head];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        pub fn replace(self: *Self, old: T, new: T) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const idx = (self.head + i) & MASK;
                if (self.items[idx] == old) self.items[idx] = new;
            }
        }
    };
}

pub fn BatchQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: Queue(T, capacity) = .{},
        sizes: Queue(u16, capacity) = .{},

        pub fn push(self: *Self, item: T) !void {
            try self.items.push(item);
        }

        pub fn peek(self: *const Self) ?*const T {
            return self.items.peek();
        }

        pub fn pop(self: *Self) ?T {
            return self.items.pop();
        }

        pub fn pushBatch(self: *Self, count: u16) !void {
            if (count == 0) return;
            try self.sizes.push(count);
        }

        pub fn remaining(self: *const Self) u16 {
            const head = self.sizes.peek() orelse return 0;
            return head.*;
        }

        pub fn completeOne(self: *Self) !void {
            if (self.sizes.len == 0) return error.ProtocolViolation;
            const head = &self.sizes.items[self.sizes.head];
            std.debug.assert(head.* > 0);
            head.* -= 1;
            if (head.* == 0) _ = self.sizes.pop();
        }

        pub fn popBatch(self: *Self) ?u16 {
            return self.sizes.pop();
        }

        pub fn clear(self: *Self) void {
            self.items.clear();
            self.sizes.clear();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.items.isEmpty();
        }

        pub fn replace(self: *Self, old: T, new: T) void {
            self.items.replace(old, new);
        }
    };
}

test "ring push/pop fifo order" {
    var q: Queue(u32, 1024) = .{};
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try std.testing.expectEqual(@as(usize, 3), q.len);
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
    try std.testing.expect(q.isEmpty());
}

test "ring tolerates push during drain" {
    var q: Queue(u32, 1024) = .{};
    try q.push(1);
    try q.push(2);
    var seen: usize = 0;
    while (q.pop()) |v| {
        seen += 1;
        if (v == 2) try q.push(99);
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "ring wraps past capacity after many push/pop" {
    var q: Queue(u32, 8) = .{};
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        try q.push(i);
        try std.testing.expectEqual(@as(?u32, i), q.pop());
    }
    try std.testing.expect(q.isEmpty());
}

test "ring overflow returns error" {
    var q: Queue(u32, 4) = .{};
    try q.push(0);
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try std.testing.expectError(error.Overflow, q.push(999));
}

test "ring rejects non-power-of-two capacity at comptime" {
    // Negative test: Queue(u32, 1000) would fail comptime; not exercised here.
}

test "redis accounting: new_queries positive after fresh enqueue" {
    var waiter_q: Queue(u32, 4) = .{};
    const in_flight: usize = 0;

    try waiter_q.push(42);

    const new_queries = waiter_q.len - in_flight;

    try std.testing.expect(new_queries > 0);
}
