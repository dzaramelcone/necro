//! Zero-copy Python type for PG query results.
//! TODO Convert to arena when req/resp becomes arena backed
//! I think the worst case scatter gather is much cleaner here
//! due to only 1 PG conn, but its nice to have them uniform.

const std = @import("std");
const necro = @import("necro");
const ffi = necro.py.ffi;
const serialize = necro.json;
const core = necro.core;
const stmt = @import("stmt.zig");

pub const BigPool = core.RefCountedPool(core.BigSlab);

const SerializeStrategy = @import("strategy.zig").SerializeStrategy;
const PyObject = ffi.PyObject;

const MAX_FIELDS = stmt.MAX_COLS;
const NULL_LEN: u16 = 0xFFFF;

const schema_allocator = std.heap.c_allocator;

const Schema = struct {
    field_count: u16 = 0,
    field_keys: [MAX_FIELDS]*PyObject = undefined,
    field_strategies: [MAX_FIELDS]SerializeStrategy = undefined,
    json_keys: [2048]u8 = undefined,
    json_key_offsets: [MAX_FIELDS + 1]u16 = undefined,

    fn create(names: []const *PyObject, strategies: []const SerializeStrategy) !*Schema {
        const s = try schema_allocator.create(Schema);
        s.* = .{ .field_count = @intCast(names.len) };
        errdefer s.destroy();

        for (names, strategies, 0..) |n, st, i| {
            s.field_keys[i] = ffi.increfBorrowed(n);
            s.field_strategies[i] = st;
        }
        try s.buildJsonKeys();
        return s;
    }

    fn destroy(self: *Schema) void {
        for (0..self.field_count) |i| ffi.decref(self.field_keys[i]);
        schema_allocator.destroy(self);
    }

    fn lookupField(self: *const Schema, name: *PyObject) ?usize {
        for (0..self.field_count) |i| {
            const key = self.field_keys[i];
            if (key == name or ffi.richCompareEq(name, key)) return i;
        }
        return null;
    }

    fn buildJsonKeys(self: *Schema) !void {
        var pos: u16 = 0;
        for (0..self.field_count) |i| {
            self.json_key_offsets[i] = pos;
            const key_str = try ffi.unicodeAsUTF8(self.field_keys[i]);
            const key_span = std.mem.span(key_str);

            const prefix: u8 = if (i == 0) '{' else ',';
            if (pos + 2 + key_span.len + 2 > self.json_keys.len) return error.JsonKeysTooLarge;
            self.json_keys[pos] = prefix;
            self.json_keys[pos + 1] = '"';
            @memcpy(self.json_keys[pos + 2 ..][0..key_span.len], key_span);
            self.json_keys[pos + 2 + key_span.len] = '"';
            self.json_keys[pos + 2 + key_span.len + 1] = ':';
            pos += @intCast(2 + key_span.len + 2);
        }
        self.json_key_offsets[self.field_count] = pos;
    }
};

const RowObject = extern struct {
    ob_base: PyObject,
    stmt_cache: ?*stmt.Cache = null,
    stmt_idx: u16 = 0,
    field_count: u16 = 0,
    row_pool: ?*BigPool = null,
    row_lease: core.Lease = undefined,
    schema: ?*Schema = null,
    field_offsets: [MAX_FIELDS]u16 = .{0} ** MAX_FIELDS,
    field_lens: [MAX_FIELDS]u16 = .{NULL_LEN} ** MAX_FIELDS,
    field_cache: [MAX_FIELDS]?*PyObject = .{null} ** MAX_FIELDS,
};

fn fieldSlice(self: *const RowObject, i: usize) []const u8 {
    const data = &self.row_pool.?.get(self.row_lease).data;
    return data[self.field_offsets[i]..][0..self.field_lens[i]];
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
    if (self.schema) |schema| {
        return schema.json_keys[schema.json_key_offsets[i]..schema.json_key_offsets[i + 1]];
    }
    const cache = self.stmt_cache orelse return &.{};
    const entry = cache.get(self.stmt_idx);
    return entry.json_keys[entry.json_key_offsets[i]..entry.json_key_offsets[i + 1]];
}

const SerializeError = serialize.SerializeError || error{BufferTooSmall};

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
        .numeric => {
            if (pos.* + val.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..val.len], val);
            pos.* += val.len;
        },
        .bool_convert => {
            if (val.len > 0 and val[0] == 't') {
                if (pos.* + 4 > buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos.*..][0..4], "true");
                pos.* += 4;
            } else {
                if (pos.* + 5 > buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos.*..][0..5], "false");
                pos.* += 5;
            }
        },
        .quoted_raw => {
            if (pos.* + val.len + 2 > buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            @memcpy(buf[pos.* + 1 ..][0..val.len], val);
            buf[pos.* + 1 + val.len] = '"';
            pos.* += val.len + 2;
        },
        .json_raw => {
            if (pos.* + val.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..val.len], val);
            pos.* += val.len;
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
        break :blk try ffi.unicodeFromSlice(val.ptr, val.len);
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
    if (self.row_pool) |p| p.release(self.row_lease);
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
    if (parent.row_pool == null) {
        ffi.errSetString(ffi.exc.RuntimeError(), "row backing slab is missing");
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
    child.row_pool = parent.row_pool;
    child.row_lease = parent.row_lease;
    parent.row_pool.?.retain(parent.row_lease);
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

fn createWithSlab(
    cache: *stmt.Cache,
    stmt_idx: u16,
    count: u16,
    values: []const ?[]const u8,
    pool: *BigPool,
    lease: core.Lease,
    s: *core.BigSlab,
) CreateError!*PyObject {
    const tp = row_type orelse return error.PythonError;
    const obj = try ffi.alloc(RowObject, tp);

    obj.stmt_cache = cache;
    obj.stmt_idx = stmt_idx;
    obj.field_count = count;
    obj.row_pool = pool;
    obj.row_lease = lease;

    for (0..count) |i| {
        if (values[i]) |v| {
            const field_offset = @intFromPtr(v.ptr) - @intFromPtr(&s.data);
            obj.field_offsets[i] = @intCast(field_offset);
            obj.field_lens[i] = @intCast(v.len);
        } else {
            obj.field_offsets[i] = 0;
            obj.field_lens[i] = NULL_LEN;
        }
    }

    return @ptrCast(obj);
}

pub fn create(
    cache: *stmt.Cache,
    stmt_idx: u16,
    field_count: u16,
    values: []const ?[]const u8,
    pool: *BigPool,
) CreateError!*PyObject {
    const count = @min(field_count, MAX_FIELDS);

    var total: usize = 0;
    for (0..count) |i| {
        if (values[i]) |v| {
            if (v.len > std.math.maxInt(u16)) return error.RowTooLarge;
            total += v.len;
            if (total > core.BigSlab.SIZE) return error.RowTooLarge;
        }
    }

    const lease = try pool.borrow();
    errdefer pool.release(lease);
    const s = pool.get(lease);

    var offset: usize = 0;
    const tp = row_type orelse return error.PythonError;
    const obj = try ffi.alloc(RowObject, tp);

    obj.stmt_cache = cache;
    obj.stmt_idx = stmt_idx;
    obj.field_count = count;
    obj.row_pool = pool;
    obj.row_lease = lease;

    for (0..count) |i| {
        if (values[i]) |v| {
            @memcpy(s.data[offset..][0..v.len], v);
            obj.field_offsets[i] = @intCast(offset);
            obj.field_lens[i] = @intCast(v.len);
            offset += v.len;
        } else {
            obj.field_offsets[i] = 0;
            obj.field_lens[i] = NULL_LEN;
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
