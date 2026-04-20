//! Statement cache for the extended query protocol.

const std = @import("std");
const necro = @import("necro");
const wire = @import("wire.zig");
const strategy = @import("strategy.zig");
const row = @import("row.zig");
const ffi = necro.py.ffi;

pub const STMT_CACHE_CAPACITY = 128;
pub const MAX_COLS = 64;

const BIND_RESULT_FORMATS_ALL_BINARY: [4]u8 = .{ 0x00, 0x01, 0x00, 0x01 };

const EXECUTE_MSG: [10]u8 = .{
    'E',  0x00, 0x00, 0x00, 0x09,
    0x00, 0x00, 0x00, 0x00, 0x00,
};

fn encodeTextParam(out: []u8, value: ?[]const u8) usize {
    if (value) |bytes| {
        const len: i32 = @intCast(bytes.len);
        std.mem.writeInt(i32, out[0..4], len, .big);
        @memcpy(out[4..][0..bytes.len], bytes);
        return 4 + bytes.len;
    } else {
        std.mem.writeInt(i32, out[0..4], -1, .big);
        return 4;
    }
}
const HASH_SLOTS = 256;
const SLOT_MASK = HASH_SLOTS - 1;
const EMPTY_SLOT: u16 = 0xFFFF;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(HASH_SLOTS));
    std.debug.assert(HASH_SLOTS > STMT_CACHE_CAPACITY);
}

pub const Entry = struct {
    sql_hash: u64,
    col_count: u16 = 0,
    described: bool = false,

    col_keys: [MAX_COLS]*ffi.PyObject = undefined,

    col_strategies: [MAX_COLS]strategy.SerializeStrategy = .{.text_escape} ** MAX_COLS,

    json: row.JsonKeyTable = .{},

    bind_prefix: [32]u8 = undefined,
    bind_prefix_len: u8 = 0,
    param_count: u16 = 0,
    encode_program_built: bool = false,

    pub fn buildJsonKeys(self: *Entry) !void {
        try self.json.build(self.col_keys[0..self.col_count]);
    }

    fn buildEncodeProgram(self: *Entry, stmt_name: []const u8, param_count: u16) void {
        std.debug.assert(!self.encode_program_built);
        std.debug.assert(11 + stmt_name.len <= self.bind_prefix.len);

        var pos: usize = 0;
        self.bind_prefix[pos] = 'B';
        pos += 1;

        @memset(self.bind_prefix[pos..][0..4], 0);
        pos += 4;
        self.bind_prefix[pos] = 0;
        pos += 1;
        @memcpy(self.bind_prefix[pos..][0..stmt_name.len], stmt_name);
        pos += stmt_name.len;
        self.bind_prefix[pos] = 0;
        pos += 1;

        std.mem.writeInt(u16, self.bind_prefix[pos..][0..2], 0, .big);
        pos += 2;

        std.mem.writeInt(u16, self.bind_prefix[pos..][0..2], param_count, .big);
        pos += 2;

        self.bind_prefix_len = @intCast(pos);
        self.param_count = param_count;
        self.encode_program_built = true;
    }
};

pub const ParamBuffer = struct {
    pub const MAX = 16;
    const SCRATCH_PER = 64;

    slices: [MAX]?[]const u8 = undefined,
    scratch: [MAX][SCRATCH_PER]u8 = undefined,
    len: usize = 0,

    pub fn setNull(self: *ParamBuffer, i: usize) void {
        self.slices[i] = null;
    }

    pub fn setBorrowed(self: *ParamBuffer, i: usize, bytes: []const u8) void {
        self.slices[i] = bytes;
    }

    pub fn setCopy(self: *ParamBuffer, i: usize, bytes: []const u8) !void {
        if (bytes.len > SCRATCH_PER) return error.ParamTooLong;
        @memcpy(self.scratch[i][0..bytes.len], bytes);
        self.slices[i] = self.scratch[i][0..bytes.len];
    }

    pub fn view(self: *const ParamBuffer) []const ?[]const u8 {
        return self.slices[0..self.len];
    }

    pub fn fromTuple(self: *ParamBuffer, tuple: *ffi.PyObject) !void {
        const n: usize = @intCast(ffi.tupleSize(tuple));
        if (n > MAX) return error.TooManyParams;

        for (0..n) |i| {
            const p = ffi.tupleGetItem(tuple, @intCast(i)) orelse return error.InvalidState;
            if (ffi.isNone(p)) {
                self.setNull(i);
                continue;
            }
            if (ffi.isString(p)) {
                const text = try ffi.unicodeAsUTF8(p);
                self.setBorrowed(i, std.mem.span(text));
                continue;
            }
            const str_obj = try ffi.objectStr(p);
            defer ffi.decref(str_obj);
            const text = try ffi.unicodeAsUTF8(str_obj);
            try self.setCopy(i, std.mem.span(text));
        }
        self.len = n;
    }
};

pub const Cache = struct {
    pub const Encoded = struct {
        bytes_written: usize,
        stmt_idx: u16,
    };

    entries: [STMT_CACHE_CAPACITY]Entry = undefined,
    len: u16 = 0,
    hash_slots: [HASH_SLOTS]u16 = .{EMPTY_SLOT} ** HASH_SLOTS,

    fn lookup(self: *const Cache, sql_hash: u64) ?u16 {
        var slot: usize = @as(usize, @truncate(sql_hash)) & SLOT_MASK;
        for (0..HASH_SLOTS) |_| {
            const idx = self.hash_slots[slot];
            if (idx == EMPTY_SLOT) return null;
            if (self.entries[idx].sql_hash == sql_hash) return idx;
            slot = (slot + 1) & SLOT_MASK;
        }
        unreachable;
    }

    fn insert(self: *Cache, sql_hash: u64) !u16 {
        if (self.len >= STMT_CACHE_CAPACITY) return error.StmtCacheFull;
        const idx = self.len;
        self.entries[idx] = .{ .sql_hash = sql_hash };
        self.len += 1;

        var slot: usize = @as(usize, @truncate(sql_hash)) & SLOT_MASK;
        for (0..HASH_SLOTS) |_| {
            if (self.hash_slots[slot] == EMPTY_SLOT) {
                self.hash_slots[slot] = idx;
                return idx;
            }
            slot = (slot + 1) & SLOT_MASK;
        }
        unreachable;
    }

    pub fn get(self: *Cache, idx: u16) *Entry {
        return &self.entries[idx];
    }

    fn stmtName(idx: u16, buf: *[8]u8) []const u8 {
        return std.fmt.bufPrint(buf, "s{d}", .{idx}) catch buf[0..2];
    }

    pub fn encode(
        self: *Cache,
        buf: []u8,
        sql: []const u8,
        conn_prepared: *[STMT_CACHE_CAPACITY]bool,
        params: *const ParamBuffer,
    ) !Encoded {
        const sql_hash = std.hash.Wyhash.hash(0, sql);
        var pos: usize = 0;
        var name_buf: [8]u8 = undefined;

        const idx = if (self.lookup(sql_hash)) |i| i else try self.insert(sql_hash);
        const entry = &self.entries[idx];
        const name = stmtName(idx, &name_buf);

        if (!entry.encode_program_built) {
            entry.buildEncodeProgram(name, @intCast(params.len));
        }
        std.debug.assert(params.len == entry.param_count);

        if (!conn_prepared[idx]) {
            const parse = wire.encodeParse(buf[pos..], name, sql);
            pos += parse.len;
            if (!entry.described) {
                const desc = wire.encodeDescribe(buf[pos..], 'S', name);
                pos += desc.len;
            }
            conn_prepared[idx] = true;
        }

        const bind_start = pos;

        @memcpy(buf[pos..][0..entry.bind_prefix_len], entry.bind_prefix[0..entry.bind_prefix_len]);
        pos += entry.bind_prefix_len;

        var params_bytes: usize = 0;
        const slices = params.view();
        for (0..entry.param_count) |i| {
            const written = encodeTextParam(buf[pos..], slices[i]);
            pos += written;
            params_bytes += written;
        }

        @memcpy(buf[pos..][0..BIND_RESULT_FORMATS_ALL_BINARY.len], BIND_RESULT_FORMATS_ALL_BINARY[0..]);
        pos += BIND_RESULT_FORMATS_ALL_BINARY.len;

        @memcpy(buf[pos..][0..EXECUTE_MSG.len], EXECUTE_MSG[0..]);
        pos += EXECUTE_MSG.len;

        const bind_length: u32 = @intCast(entry.bind_prefix_len + params_bytes + BIND_RESULT_FORMATS_ALL_BINARY.len - 1);
        std.mem.writeInt(u32, buf[bind_start + 1 ..][0..4], bind_length, .big);

        return .{ .bytes_written = pos, .stmt_idx = idx };
    }
};
