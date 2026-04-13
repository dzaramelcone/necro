const std = @import("std");
const necro = @import("necro");

const CAPACITY: usize = 64 * 1024;

const RecvBuffer = struct {
    data: [CAPACITY]u8 = undefined,
};

pub const RecvPool = necro.core.Pool(RecvBuffer);

const Writable = struct {
    offset: usize,
    slice: []u8,
};

pub const Ring = struct {
    buf_lease: ?necro.core.Lease = null,
    buf: ?*RecvBuffer = null,
    read_pos: usize = 0,
    used_len: usize = 0,
    parse_off: usize = 0,

    pub fn ensure(self: *Ring, pool: *RecvPool) !void {
        if (self.buf != null) return;
        const lease = try pool.borrow();
        self.buf_lease = lease;
        self.buf = pool.get(lease);
    }

    pub fn deinit(self: *Ring, pool: *RecvPool) void {
        if (self.buf_lease) |lease| {
            pool.release(lease);
            self.buf_lease = null;
            self.buf = null;
        }
        self.clear();
    }

    pub fn clear(self: *Ring) void {
        self.read_pos = 0;
        self.used_len = 0;
        self.parse_off = 0;
    }

    pub fn capacity(_: *const Ring) usize {
        return CAPACITY;
    }

    fn bufLease(self: *const Ring) necro.core.Lease {
        return self.buf_lease.?;
    }

    pub fn parseOffset(self: *const Ring) usize {
        return self.parse_off;
    }

    pub fn setParseOffset(self: *Ring, logical_off: usize) void {
        std.debug.assert(logical_off <= self.used_len);
        self.parse_off = logical_off;
    }

    pub fn remainingFrom(self: *const Ring, logical_off: usize) usize {
        std.debug.assert(logical_off <= self.used_len);
        return self.used_len - logical_off;
    }

    fn data(self: *const Ring) *[CAPACITY]u8 {
        return &self.buf.?.data;
    }

    pub fn usedMut(self: *Ring) []u8 {
        return self.data()[self.read_pos..][0..self.used_len];
    }

    pub fn writable(self: *Ring, pool: *RecvPool) !Writable {
        try self.ensure(pool);
        if (self.used_len == 0) {
            self.read_pos = 0;
            self.parse_off = 0;
            return .{
                .offset = 0,
                .slice = self.data(),
            };
        }
        if (self.used_len >= CAPACITY) return error.TransportRingFull;

        const write_pos = self.writePos();
        if (write_pos >= self.read_pos) {
            return .{
                .offset = write_pos,
                .slice = self.data()[write_pos..],
            };
        }
        return .{
            .offset = write_pos,
            .slice = self.data()[write_pos..self.read_pos],
        };
    }

    pub fn noteReceived(self: *Ring, received: usize) void {
        std.debug.assert(received <= self.freeContiguousLen());
        self.used_len += received;
    }

    pub fn consumeParsed(self: *Ring) usize {
        if (self.parse_off == 0) return 0;
        const consumed = self.parse_off;
        self.read_pos = self.logicalIndex(consumed);
        self.used_len -= consumed;
        self.parse_off = 0;
        if (self.used_len == 0) self.read_pos = 0;
        return consumed;
    }

    pub fn sliceIfContiguous(self: *const Ring, logical_off: usize, len: usize) ?[]const u8 {
        std.debug.assert(logical_off + len <= self.used_len);
        const start = self.logicalIndex(logical_off);
        if (start + len <= CAPACITY) {
            return self.data()[start .. start + len];
        }
        return null;
    }

    fn byteAt(self: *const Ring, logical_off: usize) u8 {
        std.debug.assert(logical_off < self.used_len);
        return self.data()[self.logicalIndex(logical_off)];
    }

    pub fn copyInto(self: *const Ring, logical_off: usize, dest: []u8) void {
        std.debug.assert(logical_off + dest.len <= self.used_len);
        if (dest.len == 0) return;
        const d = self.data();
        const start = self.logicalIndex(logical_off);
        const first = @min(dest.len, CAPACITY - start);
        @memcpy(dest[0..first], d[start .. start + first]);
        if (first < dest.len) {
            @memcpy(dest[first..], d[0 .. dest.len - first]);
        }
    }

    fn writePos(self: *const Ring) usize {
        return @mod(self.read_pos + self.used_len, CAPACITY);
    }

    fn logicalIndex(self: *const Ring, logical_off: usize) usize {
        return @mod(self.read_pos + logical_off, CAPACITY);
    }

    fn freeContiguousLen(self: *const Ring) usize {
        if (self.used_len == 0) return CAPACITY;
        if (self.used_len >= CAPACITY) return 0;

        const write_pos = self.writePos();
        if (write_pos >= self.read_pos) {
            return CAPACITY - write_pos;
        }
        return self.read_pos - write_pos;
    }
};

test "ring wraps writable region to the front" {
    var pool: RecvPool = try .init(std.testing.allocator, 1);
    defer pool.deinit();

    var ring: Ring = .{};
    defer ring.deinit(&pool);

    const first = try ring.writable(&pool);
    @memcpy(first.slice[CAPACITY - 4 .. CAPACITY], "tail");
    ring.read_pos = CAPACITY - 4;
    ring.used_len = 4;

    const second = try ring.writable(&pool);
    try std.testing.expectEqual(@as(usize, 0), second.offset);
    try std.testing.expectEqual(@as(usize, CAPACITY - 4), second.slice.len);
    @memcpy(second.slice[0..4], "head");
    ring.noteReceived(4);

    var copied: [8]u8 = undefined;
    ring.copyInto(0, &copied);
    try std.testing.expectEqual(@as(usize, 8), ring.used_len);
    try std.testing.expectEqualStrings("tailhead", &copied);
}

test "ring exposes wrapped logical bytes in order" {
    var pool: RecvPool = try .init(std.testing.allocator, 1);
    defer pool.deinit();

    var ring: Ring = .{};
    defer ring.deinit(&pool);

    const writable = try ring.writable(&pool);
    @memset(writable.slice[0..CAPACITY], 0);
    @memcpy(writable.slice[CAPACITY - 3 .. CAPACITY], "abc");
    @memcpy(writable.slice[0..4], "defg");
    ring.read_pos = CAPACITY - 3;
    ring.used_len = 7;

    var copied: [7]u8 = undefined;
    ring.copyInto(0, &copied);
    try std.testing.expectEqualStrings("abcdefg", &copied);
    try std.testing.expect(ring.sliceIfContiguous(0, 7) == null);
    try std.testing.expectEqual(@as(u8, 'a'), ring.byteAt(0));
    try std.testing.expectEqual(@as(u8, 'g'), ring.byteAt(6));
}
