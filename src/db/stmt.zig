//! Statement cache for the extended query protocol.
//!
//! Maps SQL strings to statement names ("s0", "s1", ...) and caches
//! RowDescription column metadata from the first Describe response.
//!
//! First query sends Parse+Describe+Bind+Execute+Sync.
//! Subsequent queries send Bind+Execute+Sync, skipping SQL parsing on server.

const std = @import("std");
const wire = @import("wire.zig");
const strategy = @import("strategy.zig");
const ffi = @import("../py/ffi.zig");

pub const MAX_STMTS = 128;
pub const MAX_COLS = 64;
pub const HASH_SLOTS = 256;
const SLOT_MASK = HASH_SLOTS - 1;
const EMPTY_SLOT: u16 = 0xFFFF;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(HASH_SLOTS));
    std.debug.assert(HASH_SLOTS > MAX_STMTS);
}

pub const Entry = struct {
    sql_hash: u64,
    col_count: u16 = 0,
    described: bool = false,

    col_keys: [MAX_COLS]*ffi.PyObject = undefined,

    col_strategies: [MAX_COLS]strategy.SerializeStrategy = .{.text_escape} ** MAX_COLS,

    json_keys: [2048]u8 = undefined,
    json_key_offsets: [MAX_COLS + 1]u16 = .{0} ** (MAX_COLS + 1),
    json_keys_built: bool = false,

    bind_template: [128]u8 = undefined,
    bind_template_len: u16 = 0,
    bind_template_built: bool = false,

    pub fn buildJsonKeys(self: *Entry) void {
        if (self.json_keys_built) return;
        var pos: u16 = 0;
        for (0..self.col_count) |i| {
            self.json_key_offsets[i] = pos;
            const key = self.col_keys[i];
            const key_str = ffi.unicodeAsUTF8(key) catch continue;
            const key_span = std.mem.span(key_str);

            const prefix: u8 = if (i == 0) '{' else ',';
            if (pos + 1 + 1 + key_span.len + 2 > self.json_keys.len) break;
            self.json_keys[pos] = prefix;
            self.json_keys[pos + 1] = '"';
            @memcpy(self.json_keys[pos + 2 ..][0..key_span.len], key_span);
            self.json_keys[pos + 2 + key_span.len] = '"';
            self.json_keys[pos + 2 + key_span.len + 1] = ':';
            pos += @intCast(2 + key_span.len + 2);
        }
        self.json_key_offsets[self.col_count] = pos;
        self.json_keys_built = true;
    }

    pub fn buildBindTemplate(self: *Entry, stmt_name: []const u8) void {
        var pos: usize = 0;
        const bind = wire.encodeBindWithParams(self.bind_template[pos..], stmt_name, &.{});
        pos += bind.len;
        const exec = wire.encodeExecute(self.bind_template[pos..]);
        pos += exec.len;
        self.bind_template_len = @intCast(pos);
        self.bind_template_built = true;
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
};

pub const Cache = struct {
    pub const Encoded = struct {
        bytes_written: usize,
        stmt_idx: u16,
    };

    entries: [MAX_STMTS]Entry = undefined,
    len: u16 = 0,
    hash_slots: [HASH_SLOTS]u16 = .{EMPTY_SLOT} ** HASH_SLOTS,

    pub fn lookup(self: *const Cache, sql_hash: u64) ?u16 {
        var slot: usize = @as(usize, @truncate(sql_hash)) & SLOT_MASK;
        for (0..HASH_SLOTS) |_| {
            const idx = self.hash_slots[slot];
            if (idx == EMPTY_SLOT) return null;
            if (self.entries[idx].sql_hash == sql_hash) return idx;
            slot = (slot + 1) & SLOT_MASK;
        }
        unreachable;
    }

    pub fn insert(self: *Cache, sql_hash: u64) !u16 {
        if (self.len >= MAX_STMTS) return error.StmtCacheFull;
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

    pub fn stmtName(idx: u16, buf: *[8]u8) []const u8 {
        return std.fmt.bufPrint(buf, "s{d}", .{idx}) catch buf[0..2];
    }

    pub fn encode(
        self: *Cache,
        buf: []u8,
        sql: []const u8,
        conn_prepared: *[MAX_STMTS]bool,
        params: *const ParamBuffer,
    ) !Encoded {
        const sql_hash = std.hash.Wyhash.hash(0, sql);
        var pos: usize = 0;
        var name_buf: [8]u8 = undefined;

        const idx = if (self.lookup(sql_hash)) |i| i else try self.insert(sql_hash);
        const name = stmtName(idx, &name_buf);

        if (!conn_prepared[idx]) {
            const parse = wire.encodeParse(buf[pos..], name, sql);
            pos += parse.len;
            if (!self.entries[idx].described) {
                const desc = wire.encodeDescribe(buf[pos..], 'S', name);
                pos += desc.len;
            }
            conn_prepared[idx] = true;
            if (!self.entries[idx].bind_template_built) {
                self.entries[idx].buildBindTemplate(name);
            }
        }

        if (params.len == 0 and self.entries[idx].bind_template_built) {
            const tlen = self.entries[idx].bind_template_len;
            @memcpy(buf[pos..][0..tlen], self.entries[idx].bind_template[0..tlen]);
            pos += tlen;
        } else {
            const bind = wire.encodeBindWithParams(buf[pos..], name, params.view());
            pos += bind.len;
            const exec = wire.encodeExecute(buf[pos..]);
            pos += exec.len;
        }
        return .{ .bytes_written = pos, .stmt_idx = idx };
    }
};
