const std = @import("std");
const necro = @import("necro");
const ffi = necro.py.ffi;
const row = @import("row.zig");
const strategy = @import("strategy.zig");
const wire = @import("wire.zig");
const Entry = necro.pg.stmt.Entry;
const Cache = necro.pg.stmt.Cache;
const MAX_COLS = necro.pg.stmt.MAX_COLS;
const Ring = @import("ring.zig").Ring;

pub const ParseError = wire.WireError || ffi.PythonError || row.CreateError || error{
    MessageTooLarge,
    OutOfMemory,
    JsonKeysTooLarge,
};

pub const MessageView = struct {
    header: wire.MessageHeader,
    payload: []const u8,
    total_len: usize,
};

const MAX_PG_MESSAGE: usize = 65536;

pub fn nextMessage(t: *const Ring, scratch: []u8, logical_off: usize) ParseError!?MessageView {
    if (t.remainingFrom(logical_off) < 5) return null;

    const raw_header = linearize(t, logical_off, 5, scratch);
    const header = try wire.readMessageHeader(raw_header);
    const total_len = 1 + @as(usize, @intCast(header.length));
    if (total_len > t.capacity()) return error.MessageTooLarge;
    if (t.remainingFrom(logical_off) < total_len) return null;

    const payload_len = total_len - 5;
    return .{
        .header = header,
        .payload = linearize(t, logical_off + 5, payload_len, scratch),
        .total_len = total_len,
    };
}

pub fn applyRowDescription(
    payload: []const u8,
    stmt_entry: *Entry,
) ParseError!u16 {
    if (payload.len < 2) return error.ProtocolViolation;

    var col_descs: [MAX_COLS]wire.ColumnDesc = undefined;
    const field_count = try wire.parseRowDescription(payload, &col_descs);
    if (!stmt_entry.described) {
        stmt_entry.col_count = field_count;
        for (0..field_count) |i| {
            stmt_entry.col_keys[i] = try ffi.unicodeFromSlice(col_descs[i].name.ptr, col_descs[i].name.len);
            stmt_entry.col_strategies[i] = strategy.strategyForOid(col_descs[i].type_oid);
        }
        stmt_entry.described = true;
        try stmt_entry.buildJsonKeys();
    }
    return field_count;
}

pub fn materializeDataRow(
    allocator: std.mem.Allocator,
    payload: []const u8,
    stmt_cache: *Cache,
    stmt_idx: u16,
    col_count: u16,
) ParseError!*ffi.PyObject {
    var values: [MAX_COLS]?[]const u8 = undefined;
    const field_count = try wire.parseDataRow(payload, &values);
    const render_count = @min(col_count, field_count);
    return try row.create(allocator, stmt_cache, stmt_idx, render_count, values[0..render_count]);
}

pub fn parseCommandCompleteCount(payload: []const u8) i64 {
    return parseCommandCompleteTagCount(wire.parseCommandComplete(payload));
}

fn linearize(t: *const Ring, off: usize, len: usize, scratch: []u8) []const u8 {
    if (t.sliceIfContiguous(off, len)) |slice| return slice;
    t.copyInto(off, scratch[0..len]);
    return scratch[0..len];
}

fn parseCommandCompleteTagCount(tag: []const u8) i64 {
    if (tag.len == 0) return 0;
    if (std.mem.lastIndexOfScalar(u8, tag, ' ')) |space| {
        return std.fmt.parseInt(i64, tag[space + 1 ..], 10) catch 0;
    }
    return 0;
}
