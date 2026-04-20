const std = @import("std");
const necro = @import("necro");
const ffi = necro.py.ffi;
const serialize = necro.json;
const core = necro.core;
const stmt = @import("stmt.zig");

const SerializeStrategy = @import("strategy.zig").SerializeStrategy;
const PyObject = ffi.PyObject;

const MAX_FIELDS = stmt.MAX_COLS;
const NULL_LEN: u16 = 0xFFFF;

pub const JsonKeyTable = struct {
    keys: [2048]u8 = undefined,
    offsets: [MAX_FIELDS + 1]u16 = .{0} ** (MAX_FIELDS + 1),
    built: bool = false,

    pub fn build(self: *JsonKeyTable, names: []const *PyObject) !void {
        if (self.built) return;
        var pos: u16 = 0;
        for (names, 0..) |name, i| {
            self.offsets[i] = pos;
            const key_str = try ffi.unicodeAsUTF8(name);
            const key_span = std.mem.span(key_str);

            const prefix: u8 = if (i == 0) '{' else ',';
            if (pos + 2 + key_span.len + 2 > self.keys.len) return error.JsonKeysTooLarge;
            self.keys[pos] = prefix;
            self.keys[pos + 1] = '"';
            @memcpy(self.keys[pos + 2 ..][0..key_span.len], key_span);
            self.keys[pos + 2 + key_span.len] = '"';
            self.keys[pos + 2 + key_span.len + 1] = ':';
            pos += @intCast(2 + key_span.len + 2);
        }
        self.offsets[names.len] = pos;
        self.built = true;
    }

    pub fn fragment(self: *const JsonKeyTable, i: usize) []const u8 {
        return self.keys[self.offsets[i]..self.offsets[i + 1]];
    }
};

const Schema = struct {
    field_count: u16 = 0,
    field_keys: [MAX_FIELDS]*PyObject = undefined,
    field_strategies: [MAX_FIELDS]SerializeStrategy = undefined,
    json: JsonKeyTable = .{},
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, names: []const *PyObject, strategies: []const SerializeStrategy) !*Schema {
        const s = try allocator.create(Schema);
        s.* = .{ .field_count = @intCast(names.len), .allocator = allocator };
        errdefer s.destroy();

        for (names, strategies, 0..) |n, st, i| {
            s.field_keys[i] = ffi.increfBorrowed(n);
            s.field_strategies[i] = st;
        }
        try s.json.build(s.field_keys[0..s.field_count]);
        return s;
    }

    fn destroy(self: *Schema) void {
        const allocator = self.allocator;
        for (0..self.field_count) |i| ffi.decref(self.field_keys[i]);
        allocator.destroy(self);
    }

    fn lookupField(self: *const Schema, name: *PyObject) ?usize {
        for (0..self.field_count) |i| {
            const key = self.field_keys[i];
            if (key == name or ffi.richCompareEq(name, key)) return i;
        }
        return null;
    }
};

const RowObject = extern struct {
    ob_base: PyObject,
    stmt_cache: ?*stmt.Cache = null,
    stmt_idx: u16 = 0,
    field_count: u16 = 0,
    row_data: ?[*]u8 = null,
    row_data_len: usize = 0,
    parent_row: ?*PyObject = null,
    schema: ?*Schema = null,
    field_offsets: [MAX_FIELDS]u16 = .{0} ** MAX_FIELDS,
    field_lens: [MAX_FIELDS]u16 = .{NULL_LEN} ** MAX_FIELDS,
    field_cache: [MAX_FIELDS]?*PyObject = .{null} ** MAX_FIELDS,
};

fn rowData(self: *const RowObject) [*]u8 {
    return self.row_data.?;
}

fn fieldSlice(self: *const RowObject, i: usize) []const u8 {
    return rowData(self)[self.field_offsets[i]..][0..self.field_lens[i]];
}

fn lookupFieldIndex(self: *const RowObject, name: *PyObject) ?usize {
    if (self.schema) |schema| return schema.lookupField(name);

    const cache = self.stmt_cache orelse return null;
    const entry = cache.get(self.stmt_idx);

    for (0..self.field_count) |i| {
        const key = entry.col_keys[i];
        if (key == name or ffi.richCompareEq(name, key)) return i;
    }
    return null;
}

fn fieldStrategy(self: *const RowObject, i: usize) SerializeStrategy {
    if (self.schema) |schema| return schema.field_strategies[i];
    const cache = self.stmt_cache orelse return .text_escape;
    return cache.get(self.stmt_idx).col_strategies[i];
}

fn jsonKeyFragment(self: *const RowObject, i: usize) []const u8 {
    if (self.schema) |schema| return schema.json.fragment(i);
    const cache = self.stmt_cache orelse return &.{};
    return cache.get(self.stmt_idx).json.fragment(i);
}

const SerializeError = serialize.SerializeError || error{BufferTooSmall};

const PG_EPOCH_TO_UNIX_DAYS: i32 = 10957;
const PG_EPOCH_TO_UNIX_US: i64 = 946684800 * 1_000_000;

const HEX_LOWER = "0123456789abcdef";

fn readBinInt(val: []const u8) i64 {
    return switch (val.len) {
        2 => std.mem.readInt(i16, val[0..2], .big),
        4 => std.mem.readInt(i32, val[0..4], .big),
        8 => std.mem.readInt(i64, val[0..8], .big),
        else => unreachable,
    };
}

fn readBinFloat(val: []const u8) f64 {
    return switch (val.len) {
        4 => @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, val[0..4], .big)))),
        8 => @bitCast(std.mem.readInt(u64, val[0..8], .big)),
        else => unreachable,
    };
}

fn hexEncode16(input: *const [16]u8) [32]u8 {
    const in: @Vector(16, u8) = input.*;
    const shift4: @Vector(16, u8) = @splat(4);
    const mask_0f: @Vector(16, u8) = @splat(0x0F);
    const c0: @Vector(16, u8) = @splat('0');
    const c39: @Vector(16, u8) = @splat(39);
    const c9: @Vector(16, u8) = @splat(9);
    const cz: @Vector(16, u8) = @splat(0);

    const hi_nib = in >> shift4;
    const lo_nib = in & mask_0f;

    const hi_chars = hi_nib + c0 + @select(u8, hi_nib > c9, c39, cz);
    const lo_chars = lo_nib + c0 + @select(u8, lo_nib > c9, c39, cz);

    const interleaved: @Vector(32, u8) = std.simd.interlace(.{ hi_chars, lo_chars });
    return interleaved;
}

fn writeUuid(val: []const u8, out: []u8) SerializeError!usize {
    if (val.len != 16 or out.len < 36) return error.BufferTooSmall;
    const hex_arr = hexEncode16(val[0..16]);
    const hex: @Vector(32, u8) = hex_arr;
    const dash_vec: @Vector(32, u8) = @splat('-');

    const v0 = @shuffle(u8, hex, dash_vec, @Vector(16, i32){
        0, 1, 2, 3, 4, 5, 6, 7, -1, 8, 9, 10, 11, -1, 12, 13,
    });
    const v1 = @shuffle(u8, hex, dash_vec, @Vector(16, i32){
        14, 15, -1, 16, 17, 18, 19, -1, 20, 21, 22, 23, 24, 25, 26, 27,
    });
    const v2 = @shuffle(u8, hex, dash_vec, @Vector(4, i32){ 28, 29, 30, 31 });

    const a0: [16]u8 = v0;
    const a1: [16]u8 = v1;
    const a2: [4]u8 = v2;
    @memcpy(out[0..16], &a0);
    @memcpy(out[16..32], &a1);
    @memcpy(out[32..36], &a2);
    return 36;
}

fn daysToYmd(unix_days: i64) struct { year: u16, month: u4, day: u5 } {
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(unix_days) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
    };
}

fn writeDate(val: []const u8, out: []u8) SerializeError!usize {
    if (val.len != 4) return error.BufferTooSmall;
    const days_from_2000: i32 = std.mem.readInt(i32, val[0..4], .big);
    const unix_days: i64 = @as(i64, days_from_2000) + PG_EPOCH_TO_UNIX_DAYS;
    if (unix_days < 0) return error.BufferTooSmall;
    const ymd = daysToYmd(unix_days);
    const written = std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ ymd.year, ymd.month, ymd.day }) catch return error.BufferTooSmall;
    return written.len;
}

fn writeTime(val: []const u8, out: []u8) SerializeError!usize {
    if (val.len != 8) return error.BufferTooSmall;
    const micros: i64 = std.mem.readInt(i64, val[0..8], .big);
    if (micros < 0) return error.BufferTooSmall;
    const hour: u64 = @intCast(@divTrunc(micros, 3600 * 1_000_000));
    const rem1: u64 = @intCast(@mod(micros, 3600 * 1_000_000));
    const minute = rem1 / (60 * 1_000_000);
    const rem2 = rem1 % (60 * 1_000_000);
    const second = rem2 / 1_000_000;
    const us = rem2 % 1_000_000;
    const written = std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hour, minute, second, us }) catch return error.BufferTooSmall;
    return written.len;
}

fn writeTimestamp(val: []const u8, out: []u8, tz: bool) SerializeError!usize {
    if (val.len != 8) return error.BufferTooSmall;
    const micros_from_2000: i64 = std.mem.readInt(i64, val[0..8], .big);
    const unix_us = micros_from_2000 + PG_EPOCH_TO_UNIX_US;
    if (unix_us < 0) return error.BufferTooSmall;
    const seconds_total: u64 = @intCast(@divTrunc(unix_us, 1_000_000));
    const us: u64 = @intCast(@mod(unix_us, 1_000_000));
    const days: i64 = @intCast(seconds_total / 86400);
    const second_of_day = seconds_total % 86400;
    const hour = second_of_day / 3600;
    const minute = (second_of_day % 3600) / 60;
    const second = second_of_day % 60;
    const ymd = daysToYmd(days);
    const written = if (tz)
        std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{
            ymd.year, ymd.month, ymd.day, hour, minute, second, us,
        }) catch return error.BufferTooSmall
    else
        std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
            ymd.year, ymd.month, ymd.day, hour, minute, second, us,
        }) catch return error.BufferTooSmall;
    return written.len;
}

fn writeBytea(val: []const u8, out: []u8) SerializeError!usize {
    const need = 2 + val.len * 2;
    if (out.len < need) return error.BufferTooSmall;
    out[0] = '\\';
    out[1] = 'x';
    var o: usize = 2;
    for (val) |b| {
        out[o] = HEX_LOWER[b >> 4];
        out[o + 1] = HEX_LOWER[b & 0xF];
        o += 2;
    }
    return need;
}

fn writeNumeric(val: []const u8, out: []u8) SerializeError!usize {
    if (val.len < 8) return error.BufferTooSmall;
    const ndigits: u16 = std.mem.readInt(u16, val[0..2], .big);
    const weight: i16 = std.mem.readInt(i16, val[2..4], .big);
    const sign: u16 = std.mem.readInt(u16, val[4..6], .big);
    const dscale: u16 = std.mem.readInt(u16, val[6..8], .big);
    const digits_bytes = val[8..];
    if (digits_bytes.len != @as(usize, ndigits) * 2) return error.BufferTooSmall;

    if (sign != 0x0000 and sign != 0x4000) {
        if (out.len < 4) return error.BufferTooSmall;
        @memcpy(out[0..4], "null");
        return 4;
    }

    var pos: usize = 0;
    if (sign == 0x4000) {
        if (pos >= out.len) return error.BufferTooSmall;
        out[pos] = '-';
        pos += 1;
    }

    if (ndigits == 0) {
        if (pos >= out.len) return error.BufferTooSmall;
        out[pos] = '0';
        pos += 1;
    } else if (weight < 0) {
        if (pos >= out.len) return error.BufferTooSmall;
        out[pos] = '0';
        pos += 1;
    } else {
        const first_digit = std.mem.readInt(u16, digits_bytes[0..2], .big);
        const written = std.fmt.bufPrint(out[pos..], "{d}", .{first_digit}) catch return error.BufferTooSmall;
        pos += written.len;
        var di: usize = 1;
        var w: i16 = weight;
        while (w > 0) : (w -= 1) {
            if (pos + 4 > out.len) return error.BufferTooSmall;
            const d: u16 = if (di < ndigits) std.mem.readInt(u16, digits_bytes[di * 2 ..][0..2], .big) else 0;
            _ = std.fmt.bufPrint(out[pos..][0..4], "{d:0>4}", .{d}) catch return error.BufferTooSmall;
            pos += 4;
            di += 1;
        }
    }

    if (dscale > 0) {
        if (pos + 1 + dscale > out.len) return error.BufferTooSmall;
        out[pos] = '.';
        pos += 1;
        var frac_written: usize = 0;
        var di: i32 = @as(i32, weight) + 1;
        while (frac_written < dscale) : (di += 1) {
            const remaining: usize = @as(usize, dscale) - frac_written;
            const this_digits: usize = if (remaining >= 4) 4 else remaining;
            const d: u16 = if (di >= 0 and di < @as(i32, @intCast(ndigits)))
                std.mem.readInt(u16, digits_bytes[@as(usize, @intCast(di)) * 2 ..][0..2], .big)
            else
                0;
            var tmp: [4]u8 = undefined;
            _ = std.fmt.bufPrint(&tmp, "{d:0>4}", .{d}) catch unreachable;
            @memcpy(out[pos..][0..this_digits], tmp[0..this_digits]);
            pos += this_digits;
            frac_written += this_digits;
        }
    }

    return pos;
}

fn writeFieldValue(self: *const RowObject, i: usize, buf: []u8, pos: *usize) SerializeError!void {
    if (self.field_lens[i] == NULL_LEN) {
        if (pos.* + 4 > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos.*..][0..4], "null");
        pos.* += 4;
        return;
    }

    const val = fieldSlice(self, i);
    switch (fieldStrategy(self, i)) {
        .text_escape => {
            if (pos.* + 2 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            const written = try serialize.writeJsonEscaped(buf[pos.*..], val);
            pos.* += written;
            if (pos.* >= buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .json_raw => {
            if (pos.* + val.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..val.len], val);
            pos.* += val.len;
        },
        .bin_bool => {
            const truthy = val.len > 0 and val[0] != 0;
            const text = if (truthy) "true" else "false";
            if (pos.* + text.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..text.len], text);
            pos.* += text.len;
        },
        .bin_int => {
            const v = readBinInt(val);
            const written = std.fmt.bufPrint(buf[pos.*..], "{d}", .{v}) catch return error.BufferTooSmall;
            pos.* += written.len;
        },
        .bin_float => {
            const v = readBinFloat(val);
            if (!std.math.isFinite(v)) {
                if (pos.* + 4 > buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos.*..][0..4], "null");
                pos.* += 4;
            } else {
                const written = std.fmt.bufPrint(buf[pos.*..], "{d}", .{v}) catch return error.BufferTooSmall;
                pos.* += written.len;
            }
        },
        .bin_numeric => {
            pos.* += try writeNumeric(val, buf[pos.*..]);
        },
        .bin_date => {
            if (pos.* + 12 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeDate(val, buf[pos.*..]);
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .bin_time => {
            if (pos.* + 17 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeTime(val, buf[pos.*..]);
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .bin_timestamp => {
            if (pos.* + 28 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeTimestamp(val, buf[pos.*..], false);
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .bin_timestamptz => {
            if (pos.* + 29 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeTimestamp(val, buf[pos.*..], true);
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .bin_uuid => {
            if (pos.* + 38 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeUuid(val, buf[pos.*..]);
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .bin_jsonb => {
            if (val.len < 1) return error.BufferTooSmall;
            const body = val[1..];
            if (pos.* + body.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..body.len], body);
            pos.* += body.len;
        },
        .bin_bytea => {
            if (pos.* + 2 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            pos.* += try writeBytea(val, buf[pos.*..]);
            if (pos.* >= buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
        },
    }
}

fn cachedFieldValue(self: *RowObject, i: usize) ffi.PythonError!*PyObject {
    if (self.field_cache[i]) |cached| {
        ffi.incref(cached);
        return cached;
    }

    const value = if (self.field_lens[i] == NULL_LEN)
        ffi.getNone()
    else blk: {
        const val = fieldSlice(self, i);
        switch (fieldStrategy(self, i)) {
            .bin_int => break :blk try ffi.longFromLong(readBinInt(val)),
            .bin_float => break :blk try ffi.floatFromDouble(readBinFloat(val)),
            .bin_bool => break :blk ffi.boolFromBool(val.len > 0 and val[0] != 0),
            .bin_numeric => {
                var tmp: [128]u8 = undefined;
                const n = writeNumeric(val, &tmp) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_date => {
                var tmp: [16]u8 = undefined;
                const n = writeDate(val, &tmp) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_time => {
                var tmp: [24]u8 = undefined;
                const n = writeTime(val, &tmp) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_timestamp => {
                var tmp: [32]u8 = undefined;
                const n = writeTimestamp(val, &tmp, false) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_timestamptz => {
                var tmp: [32]u8 = undefined;
                const n = writeTimestamp(val, &tmp, true) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_uuid => {
                var tmp: [36]u8 = undefined;
                const n = writeUuid(val, &tmp) catch return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(tmp[0..].ptr, n);
            },
            .bin_jsonb => {
                if (val.len < 1) return error.ConversionError;
                break :blk try ffi.unicodeFromSlice(val[1..].ptr, val.len - 1);
            },
            .bin_bytea => {
                const bytes_obj = try ffi.bytesNew(@intCast(val.len));
                @memcpy(ffi.bytesAsSlice(bytes_obj, val.len)[0..val.len], val);
                break :blk bytes_obj;
            },
            .text_escape, .json_raw => break :blk try ffi.unicodeFromSlice(val.ptr, val.len),
        }
    };
    self.field_cache[i] = value;
    ffi.incref(value);
    return value;
}

fn fieldMemoryView(self_obj: *PyObject, self: *const RowObject, i: usize) ?*PyObject {
    if (self.field_lens[i] == NULL_LEN) return ffi.getNone();
    return ffi.memoryViewFromSlice(self_obj, fieldSlice(self, i));
}

fn rowDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *RowObject = @ptrCast(@alignCast(obj));
    for (&self.field_cache) |*cached| {
        if (cached.*) |value| ffi.decref(value);
    }
    if (self.schema) |schema| schema.destroy();
    if (self.parent_row == null) {
        if (self.row_data) |data| row_allocator.free(data[0..self.row_data_len]);
    }
    ffi.xdecref(self.parent_row);
    ffi.freeObject(obj);
}

fn rowGetAttr(self_obj: ?*PyObject, name_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const name = name_obj orelse return null;
    const self: *RowObject = @ptrCast(@alignCast(obj));
    if (lookupFieldIndex(self, name)) |i| {
        if (cachedFieldValue(self, i)) |v| return v else |_| return null;
    }
    return ffi.genericGetAttr(self_obj, name_obj);
}

fn rowRaw(self_obj: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const tuple = args orelse return null;
    if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) != 1) {
        ffi.errSetString(ffi.exc.TypeError(), "raw(name) takes exactly one argument");
        return null;
    }
    const name = ffi.tupleGetItem(tuple, 0) orelse return null;
    if (!ffi.isString(name)) {
        ffi.errSetString(ffi.exc.TypeError(), "raw(name) requires a string");
        return null;
    }
    const self: *RowObject = @ptrCast(@alignCast(obj));
    const index = lookupFieldIndex(self, name) orelse {
        ffi.errSetString(ffi.exc.AttributeError(), "unknown field");
        return null;
    };
    return fieldMemoryView(obj, self, index);
}

fn createSubrow(
    obj: *PyObject,
    field_names_obj: *PyObject,
    indexes_obj: *PyObject,
    nullable: bool,
) !?*PyObject {
    if (!ffi.isTuple(field_names_obj) or !ffi.isTuple(indexes_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "subrow metadata requires tuples");
        return error.TypeError;
    }

    const field_count = ffi.tupleSize(field_names_obj);
    if (field_count != ffi.tupleSize(indexes_obj) or field_count < 0 or field_count > MAX_FIELDS) {
        ffi.errSetString(ffi.exc.ValueError(), "subrow metadata field count mismatch");
        return error.ConversionError;
    }

    const parent: *RowObject = @ptrCast(@alignCast(obj));
    if (parent.row_data == null) {
        ffi.errSetString(ffi.exc.RuntimeError(), "row backing data is missing");
        return error.PythonError;
    }

    var field_names: [MAX_FIELDS]*PyObject = undefined;
    var field_strategies: [MAX_FIELDS]SerializeStrategy = undefined;
    var selected_indexes: [MAX_FIELDS]usize = undefined;
    var all_null = field_count > 0;
    for (0..@intCast(field_count)) |i| {
        const field_name = ffi.tupleGetItem(field_names_obj, @intCast(i)) orelse {
            ffi.errSetString(ffi.exc.RuntimeError(), "subrow field name lookup failed");
            return error.PythonError;
        };
        const index_obj = ffi.tupleGetItem(indexes_obj, @intCast(i)) orelse {
            ffi.errSetString(ffi.exc.RuntimeError(), "subrow index lookup failed");
            return error.PythonError;
        };
        if (!ffi.isString(field_name)) {
            ffi.errSetString(ffi.exc.TypeError(), "subrow field names must be strings");
            return error.TypeError;
        }

        const field_index_long = try ffi.longAsLong(index_obj);
        if (field_index_long < 0 or field_index_long >= parent.field_count) {
            ffi.errSetString(ffi.exc.IndexError(), "subrow index out of range");
            return error.ConversionError;
        }

        const parent_index: usize = @intCast(field_index_long);
        field_names[i] = field_name;
        selected_indexes[i] = parent_index;
        field_strategies[i] = fieldStrategy(parent, parent_index);
        if (parent.field_lens[parent_index] != NULL_LEN) all_null = false;
    }

    if (nullable and all_null) return ffi.getNone();

    const schema = try Schema.create(
        row_allocator,
        field_names[0..@intCast(field_count)],
        field_strategies[0..@intCast(field_count)],
    );
    errdefer schema.destroy();

    const tp = row_type orelse {
        ffi.errSetString(ffi.exc.RuntimeError(), "necro.Row type is not initialized");
        return error.PythonError;
    };
    const child = try ffi.alloc(RowObject, tp);
    child.field_count = @intCast(field_count);
    child.row_data = parent.row_data;
    child.parent_row = ffi.increfBorrowed(obj);
    child.schema = schema;

    for (0..@intCast(field_count)) |i| {
        const pi = selected_indexes[i];
        child.field_offsets[i] = parent.field_offsets[pi];
        child.field_lens[i] = parent.field_lens[pi];
    }

    return @ptrCast(child);
}

fn rowSubrow(self_obj: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const tuple = args orelse return null;
    const argc = ffi.tupleSize(tuple);
    if (!ffi.isTuple(tuple) or (argc != 2 and argc != 3)) {
        ffi.errSetString(ffi.exc.TypeError(), "subrow(field_names, indexes, nullable=False)");
        return null;
    }

    const field_names_obj = ffi.tupleGetItem(tuple, 0) orelse return null;
    const indexes_obj = ffi.tupleGetItem(tuple, 1) orelse return null;
    const nullable = if (argc == 3) blk: {
        const flag_obj = ffi.tupleGetItem(tuple, 2) orelse return null;
        break :blk if (ffi.objectIsTrue(flag_obj)) |v| v else |_| return null;
    } else false;

    if (createSubrow(obj, field_names_obj, indexes_obj, nullable)) |result| return result else |_| return null;
}

fn rowRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *RowObject = @ptrCast(@alignCast(self_obj orelse return null));
    var buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "Row({d} fields)", .{self.field_count})) |s| {
        if (ffi.unicodeFromSlice(s.ptr, s.len)) |v| return v else |_| return null;
    } else |_| return null;
}

const row_methods = ffi.table(ffi.MethodDef, .{
    ffi.methodDef("raw", rowRaw, .varargs),
    ffi.methodDef("subrow", rowSubrow, .varargs),
});

const row_type_slots = ffi.table(ffi.TypeSlot, .{
    ffi.typeSlot(ffi.Slot.dealloc, rowDealloc),
    ffi.typeSlot(ffi.Slot.getattro, rowGetAttr),
    ffi.typeSlot(ffi.Slot.repr, rowRepr),
    ffi.typeSlot(ffi.Slot.methods, &row_methods),
    ffi.typeSlot(ffi.Slot.doc, "necro row"),
});

const row_type_spec = ffi.TypeSpec{
    .name = "necro.core.Row",
    .basicsize = @sizeOf(RowObject),
    .itemsize = 0,
    .flags = ffi.flags.DEFAULT,
    .slots = @ptrCast(@constCast(&row_type_slots)),
};

threadlocal var row_type: ?*PyObject = null;
threadlocal var row_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    row_allocator = allocator;
}

pub fn initType(mod: *PyObject) ffi.PythonError!void {
    if (row_type != null) return;
    row_type = try ffi.typeFromModuleAndSpec(mod, &row_type_spec, null);
    try ffi.setAttrRaw(mod, "Row", row_type.?);
}

pub fn isRow(obj: *PyObject) bool {
    const tp = row_type orelse return false;
    return ffi.isSubtype(ffi.objType(obj), @ptrCast(@alignCast(tp)));
}

pub const CreateError = ffi.PythonError || error{
    PoolExhausted,
    OutOfMemory,
    RowTooLarge,
};

pub fn create(
    allocator: std.mem.Allocator,
    cache: *stmt.Cache,
    stmt_idx: u16,
    field_count: u16,
    values: []const ?[]const u8,
) CreateError!*PyObject {
    const count = @min(field_count, MAX_FIELDS);

    var total: usize = 0;
    for (0..count) |i| {
        if (values[i]) |v| {
            if (v.len > std.math.maxInt(u16)) return error.RowTooLarge;
            total += v.len;
        }
    }

    const tp = row_type orelse return error.PythonError;
    const obj = try ffi.alloc(RowObject, tp);
    errdefer ffi.freeObject(@ptrCast(obj));

    obj.stmt_cache = cache;
    obj.stmt_idx = stmt_idx;
    obj.field_count = count;

    if (total > 0) {
        const data = try allocator.alloc(u8, total);
        obj.row_data = data.ptr;
        obj.row_data_len = total;

        var offset: usize = 0;
        for (0..count) |i| {
            if (values[i]) |v| {
                @memcpy(data[offset..][0..v.len], v);
                obj.field_offsets[i] = @intCast(offset);
                obj.field_lens[i] = @intCast(v.len);
                offset += v.len;
            } else {
                obj.field_offsets[i] = 0;
                obj.field_lens[i] = NULL_LEN;
            }
        }
    }

    return @ptrCast(obj);
}

pub fn serializeOne(obj: *PyObject, buf: []u8) SerializeError!usize {
    const self: *RowObject = @ptrCast(@alignCast(obj));
    if (self.schema == null and self.stmt_cache == null) return error.BufferTooSmall;

    var pos: usize = 0;
    for (0..self.field_count) |i| {
        const frag = jsonKeyFragment(self, i);
        if (pos + frag.len >= buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..frag.len], frag);
        pos += frag.len;
        try writeFieldValue(self, i, buf, &pos);
    }

    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = '}';
    pos += 1;
    return pos;
}

test hexEncode16 {
    const input: [16]u8 = .{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    };
    const out = hexEncode16(&input);
    try std.testing.expectEqualSlices(u8, "00112233445566778899aabbccddeeff", &out);
}

test writeUuid {
    var buf: [36]u8 = undefined;
    const input: [16]u8 = .{
        0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4,
        0xA7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const n = try writeUuid(&input, &buf);
    try std.testing.expectEqual(@as(usize, 36), n);
    try std.testing.expectEqualSlices(u8, "550e8400-e29b-41d4-a716-446655440000", &buf);

    const zero: [16]u8 = @splat(0);
    const n2 = try writeUuid(&zero, &buf);
    try std.testing.expectEqual(@as(usize, 36), n2);
    try std.testing.expectEqualSlices(u8, "00000000-0000-0000-0000-000000000000", &buf);
}
