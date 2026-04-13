const std = @import("std");
const recv_group = @import("recv_group.zig");

const DEFAULT_MAX_BYTES = @as(usize, recv_group.DEFAULT_BUFFER_SIZE) * @as(usize, recv_group.DEFAULT_BUFFER_COUNT);

const MAX_SEGMENTS = recv_group.DEFAULT_BUFFER_COUNT;

const Segment = struct {
    lease: recv_group.Lease,
    start: usize = 0,

    fn available(self: Segment) usize {
        return self.lease.bytes.len - self.start;
    }

    fn slice(self: Segment) []const u8 {
        return self.lease.bytes[self.start..];
    }
};

pub const Queue = struct {
    segments: [MAX_SEGMENTS]Segment = undefined,
    head_idx: usize = 0,
    seg_count: usize = 0,
    used_len: usize = 0,
    parse_off: usize = 0,
    max_bytes: usize = DEFAULT_MAX_BYTES,

    pub fn deinit(self: *Queue, group: *recv_group.Group) void {
        self.clear(group);
    }

    pub fn clear(self: *Queue, group: *recv_group.Group) void {
        while (self.seg_count > 0) {
            const seg = self.segments[self.head_idx];
            group.release(seg.lease);
            self.head_idx = (self.head_idx + 1) % self.segments.len;
            self.seg_count -= 1;
        }
        self.readReset();
    }

    pub fn capacity(self: *const Queue) usize {
        return self.max_bytes;
    }

    pub fn queuedBytes(self: *const Queue) usize {
        return self.used_len;
    }

    fn segmentCount(self: *const Queue) usize {
        return self.seg_count;
    }

    pub fn parseOffset(self: *const Queue) usize {
        return self.parse_off;
    }

    pub fn setParseOffset(self: *Queue, logical_off: usize) void {
        std.debug.assert(logical_off <= self.used_len);
        self.parse_off = logical_off;
    }

    pub fn remainingFrom(self: *const Queue, logical_off: usize) usize {
        std.debug.assert(logical_off <= self.used_len);
        return self.used_len - logical_off;
    }

    pub fn append(self: *Queue, group: *recv_group.Group, lease: recv_group.Lease) !void {
        errdefer group.release(lease);

        if (lease.bytes.len == 0) return;
        if (self.seg_count >= self.segments.len) return error.TransportSegmentQueueFull;
        if (self.used_len + lease.bytes.len > self.max_bytes) return error.TransportQueueFull;

        const tail_idx = (self.head_idx + self.seg_count) % self.segments.len;
        self.segments[tail_idx] = .{ .lease = lease };
        self.seg_count += 1;
        self.used_len += lease.bytes.len;
    }

    pub fn consumeParsed(self: *Queue, group: *recv_group.Group) usize {
        if (self.parse_off == 0) return 0;

        var remaining = self.parse_off;
        const consumed = remaining;
        self.parse_off = 0;
        self.used_len -= consumed;

        while (remaining > 0) {
            std.debug.assert(self.seg_count > 0);
            const head_seg = &self.segments[self.head_idx];
            const available = head_seg.available();
            if (remaining < available) {
                head_seg.start += remaining;
                remaining = 0;
                break;
            }

            remaining -= available;
            const lease = head_seg.lease;
            self.head_idx = (self.head_idx + 1) % self.segments.len;
            self.seg_count -= 1;
            group.release(lease);
        }

        if (self.seg_count == 0) self.readReset();
        return consumed;
    }

    pub fn sliceIfContiguous(self: *const Queue, logical_off: usize, len: usize) ?[]const u8 {
        std.debug.assert(logical_off + len <= self.used_len);
        if (len == 0) return &.{};

        const loc = self.locate(logical_off);
        const seg = self.segments[loc.seg_idx];
        if (loc.seg_off + len <= seg.available()) {
            const s = seg.slice();
            return s[loc.seg_off .. loc.seg_off + len];
        }
        return null;
    }

    pub fn contiguousFrom(self: *const Queue, logical_off: usize) ?[]const u8 {
        std.debug.assert(logical_off <= self.used_len);
        if (logical_off == self.used_len) return &.{};

        const loc = self.locate(logical_off);
        const seg = self.segments[loc.seg_idx];
        return seg.slice()[loc.seg_off..];
    }

    fn byteAt(self: *const Queue, logical_off: usize) u8 {
        std.debug.assert(logical_off < self.used_len);
        const loc = self.locate(logical_off);
        return self.segments[loc.seg_idx].slice()[loc.seg_off];
    }

    pub fn copyInto(self: *const Queue, logical_off: usize, dest: []u8) void {
        std.debug.assert(logical_off + dest.len <= self.used_len);
        if (dest.len == 0) return;

        var copied: usize = 0;
        var loc = self.locate(logical_off);
        while (copied < dest.len) {
            const seg = self.segments[loc.seg_idx];
            const available = seg.available() - loc.seg_off;
            const take = @min(dest.len - copied, available);
            const s = seg.slice();
            @memcpy(dest[copied .. copied + take], s[loc.seg_off .. loc.seg_off + take]);
            copied += take;
            loc.seg_idx = (loc.seg_idx + 1) % self.segments.len;
            loc.seg_off = 0;
        }
    }

    fn readReset(self: *Queue) void {
        self.head_idx = 0;
        self.seg_count = 0;
        self.used_len = 0;
        self.parse_off = 0;
    }

    const Location = struct {
        seg_idx: usize,
        seg_off: usize,
    };

    fn locate(self: *const Queue, logical_off: usize) Location {
        std.debug.assert(logical_off <= self.used_len);

        var remaining = logical_off;
        var seg_idx = self.head_idx;
        var count = self.seg_count;
        while (count > 0) : (count -= 1) {
            const seg = self.segments[seg_idx];
            const available = seg.available();
            if (remaining < available) {
                return .{ .seg_idx = seg_idx, .seg_off = remaining };
            }
            remaining -= available;
            seg_idx = (seg_idx + 1) % self.segments.len;
        }

        unreachable;
    }
};
