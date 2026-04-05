//! Ref-counted slab allocator for lending to Python.
//! In theory, a Python process could hold a reference
//! to a row result indefinitely without ever copying it.
//! On the happy path, it could also be written back to the
//! connection socket without ever having been copied.

const std = @import("std");

pub const CAPACITY: usize = 64 * 1024;

pub const Slab = struct {
    pool: *SlabPool,
    refs: usize = 1,
    next_free: ?*Slab = null,
    data: [CAPACITY]u8 = undefined,

    pub fn retain(self: *Slab) *Slab {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *Slab) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) {
            self.next_free = self.pool.free_head;
            self.pool.free_head = self;
        }
    }
};

pub const SlabPool = struct {
    allocator: std.mem.Allocator,
    max_slabs: usize,
    live_slabs: usize = 0,
    free_head: ?*Slab = null,

    pub fn init(allocator: std.mem.Allocator, max_slabs: usize) SlabPool {
        return .{ .allocator = allocator, .max_slabs = max_slabs };
    }

    pub fn deinit(self: *SlabPool) void {
        while (self.free_head) |slab| {
            self.free_head = slab.next_free;
            self.allocator.destroy(slab);
        }
    }

    pub fn acquire(self: *SlabPool) !*Slab {
        if (self.free_head) |slab| {
            self.free_head = slab.next_free;
            slab.refs = 1;
            slab.next_free = null;
            return slab;
        }
        if (self.live_slabs >= self.max_slabs) return error.SlabPoolExhausted;
        const slab = try self.allocator.create(Slab);
        slab.* = .{ .pool = self };
        self.live_slabs += 1;
        return slab;
    }
};

test "pool enforces ceiling and reuses released slabs" {
    var pool = SlabPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    const slab = try pool.acquire();
    try std.testing.expectError(error.SlabPoolExhausted, pool.acquire());

    slab.release();
    const reused = try pool.acquire();
    try std.testing.expectEqual(slab, reused);
    reused.release();
}

test "slab retain keeps memory alive until final release" {
    var pool = SlabPool.init(std.testing.allocator, 1);
    defer pool.deinit();

    const slab = try pool.acquire();
    const shared = slab.retain();

    slab.release();
    try std.testing.expectError(error.SlabPoolExhausted, pool.acquire());

    shared.release();
    const reused = try pool.acquire();
    try std.testing.expectEqual(slab, reused);
    reused.release();
}
