// TODO: rewrite parsing to do one pass and create all Python objects inline —
// memoryviews for body, immutable tuple-of-tuples for headers, str for method/path.
// Eliminate the two-phase Meta+lazy-accessor pattern entirely.

const std = @import("std");
const necro = @import("necro");
const ffi = @import("ffi.zig");
const core = necro.core;
const HandleTask = necro.aio.tasks.HandleTask;

const SmallPool = core.Pool(core.SmallSlab);

const PyObject = ffi.PyObject;

const py_object_size = @sizeOf(ffi.PyObject);

const RequestData = struct {
    pool: ?*SmallPool = null,
    lease: core.Lease = undefined,
    method_obj: ?*PyObject = null,
    path_obj: ?*PyObject = null,
    body_obj: ?*PyObject = null,
    headers_obj: ?*PyObject = null,
    params_obj: ?*PyObject = null,
};

fn getData(obj: *PyObject) *RequestData {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + py_object_size));
}

fn getSlab(self: *const RequestData) ?*const core.SmallSlab {
    const pool = self.pool orelse return null;
    return pool.get(self.lease);
}

fn getMeta(self: *const RequestData) ?*const HandleTask.Meta {
    const slab = getSlab(self) orelse return null;
    return HandleTask.getMeta(slab);
}

fn methodSlice(self: *const RequestData) []const u8 {
    const slab = getSlab(self) orelse return "";
    const meta = HandleTask.getMeta(slab);
    return meta.method_bytes.slice(slab);
}

fn pathSlice(self: *const RequestData) []const u8 {
    const slab = getSlab(self) orelse return "/";
    const meta = HandleTask.getMeta(slab);
    return meta.uri.slice(slab);
}

fn bodySlice(self: *const RequestData) ?[]const u8 {
    const slab = getSlab(self) orelse return null;
    const meta = HandleTask.getMeta(slab);
    if (meta.body.len == 0) return null;
    return meta.body.slice(slab);
}

fn headerName(self: *const RequestData, index: usize) []const u8 {
    const slab = getSlab(self) orelse return "";
    const meta = HandleTask.getMeta(slab);
    return meta.headers[index].name.slice(slab);
}

fn headerValue(self: *const RequestData, index: usize) []const u8 {
    const slab = getSlab(self) orelse return "";
    const meta = HandleTask.getMeta(slab);
    return meta.headers[index].value.slice(slab);
}

fn paramName(self: *const RequestData, index: usize) []const u8 {
    const meta = getMeta(self) orelse return "";
    const p = meta.params[index];
    return p.name_ptr[0..p.name_len];
}

fn paramValue(self: *const RequestData, index: usize) []const u8 {
    const slab = getSlab(self) orelse return "";
    const meta = HandleTask.getMeta(slab);
    return meta.params[index].value.slice(slab);
}

fn increfCached(obj: ?*PyObject) ?*PyObject {
    if (obj) |value| {
        ffi.incref(value);
        return value;
    }
    return null;
}

fn bytesFromSlice(bytes: []const u8) ffi.PythonError!*PyObject {
    const obj = try ffi.bytesNew(@intCast(bytes.len));
    @memcpy(ffi.bytesAsSlice(obj, bytes.len)[0..bytes.len], bytes);
    return obj;
}

fn lowercaseUnicode(s: []const u8) ffi.PythonError!*PyObject {
    const name_obj = try ffi.unicodeFromSlice(s.ptr, s.len);
    defer ffi.decref(name_obj);
    return try ffi.callMethodNoArgs(name_obj, "lower");
}

fn buildHeadersMapping(self: *const RequestData) ffi.PythonError!*PyObject {
    const meta = getMeta(self) orelse return ffi.dictNew();
    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);
    for (0..meta.header_count) |i| {
        const key = try lowercaseUnicode(headerName(self, i));
        defer ffi.decref(key);
        const val = headerValue(self, i);
        const value = try ffi.unicodeFromSlice(val.ptr, val.len);
        defer ffi.decref(value);
        try ffi.dictSetItem(dict, key, value);
    }
    const proxy = try ffi.dictProxyNew(dict);
    ffi.decref(dict);
    return proxy;
}

fn buildParamsMapping(self: *const RequestData) ffi.PythonError!*PyObject {
    const meta = getMeta(self) orelse return ffi.dictNew();
    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);
    for (0..meta.param_count) |i| {
        const name = paramName(self, i);
        const key = try ffi.unicodeFromSlice(name.ptr, name.len);
        defer ffi.decref(key);
        const val = paramValue(self, i);
        const value = try ffi.unicodeFromSlice(val.ptr, val.len);
        defer ffi.decref(value);
        try ffi.dictSetItem(dict, key, value);
    }
    const proxy = try ffi.dictProxyNew(dict);
    ffi.decref(dict);
    return proxy;
}

fn attributeKey(name_obj: *PyObject) ?[]const u8 {
    if (!ffi.isString(name_obj)) return null;
    const name = ffi.unicodeAsUTF8(name_obj) catch return null;
    return std.mem.span(name);
}

fn getKnownField(self: *RequestData, name: []const u8) ffi.PythonError!?*PyObject {
    if (std.mem.eql(u8, name, "method")) {
        if (increfCached(self.method_obj)) |cached| return cached;
        const obj = try ffi.unicodeFromSlice(methodSlice(self).ptr, methodSlice(self).len);
        self.method_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "path")) {
        if (increfCached(self.path_obj)) |cached| return cached;
        const obj = try ffi.unicodeFromSlice(pathSlice(self).ptr, pathSlice(self).len);
        self.path_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "body")) {
        if (increfCached(self.body_obj)) |cached| return cached;
        const obj = if (bodySlice(self)) |body|
            try bytesFromSlice(body)
        else
            ffi.getNone();
        self.body_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "headers")) {
        if (increfCached(self.headers_obj)) |cached| return cached;
        const mapping = try buildHeadersMapping(self);
        self.headers_obj = mapping;
        ffi.incref(mapping);
        return mapping;
    }
    if (std.mem.eql(u8, name, "params")) {
        if (increfCached(self.params_obj)) |cached| return cached;
        const mapping = try buildParamsMapping(self);
        self.params_obj = mapping;
        ffi.incref(mapping);
        return mapping;
    }
    if (std.mem.eql(u8, name, "keepalive")) {
        return ffi.boolFromBool((getMeta(self) orelse return ffi.boolFromBool(true)).keepalive);
    }
    return null;
}

fn requestDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const data = getData(obj);
    ffi.xdecref(data.method_obj);
    ffi.xdecref(data.path_obj);
    ffi.xdecref(data.body_obj);
    ffi.xdecref(data.headers_obj);
    ffi.xdecref(data.params_obj);
    ffi.freeObject(obj);
}

fn requestGetAttr(self_obj: ?*PyObject, name_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const name = name_obj orelse return null;
    const key = attributeKey(name) orelse return ffi.genericGetAttr(self_obj, name_obj);
    const data = getData(obj);
    if (getKnownField(data, key)) |field| return field else |_| return null;
    return ffi.genericGetAttr(self_obj, name_obj);
}

fn requestSubscript(self_obj: ?*PyObject, key_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const key = key_obj orelse return null;
    const name = attributeKey(key) orelse {
        ffi.errSetString(ffi.exc.KeyError(), "request keys must be strings");
        return null;
    };
    const data = getData(obj);
    if (getKnownField(data, name)) |field| return field else |_| return null;
    ffi.errSetString(ffi.exc.KeyError(), "unknown request key");
    return null;
}

fn requestRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const data = getData(obj);
    var buf: [192]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "Request({s} {s})", .{ methodSlice(data), pathSlice(data) })) |s| {
        if (ffi.unicodeFromSlice(s.ptr, s.len)) |v| return v else |_| return null;
    } else |_| return null;
}

const type_slots = ffi.table(ffi.TypeSlot, .{
    ffi.typeSlot(ffi.Slot.dealloc, requestDealloc),
    ffi.typeSlot(ffi.Slot.getattro, requestGetAttr),
    ffi.typeSlot(ffi.Slot.mp_subscript, requestSubscript),
    ffi.typeSlot(ffi.Slot.repr, requestRepr),
});

const type_spec = ffi.TypeSpec{
    .name = "necro.core.Request",
    .basicsize = @intCast(py_object_size + @sizeOf(RequestData)),
    .itemsize = 0,
    .flags = ffi.flags.DEFAULT,
    .slots = @ptrCast(@constCast(&type_slots)),
};

threadlocal var request_type: ?*PyObject = null;

pub fn initType(mod: *PyObject) ffi.PythonError!void {
    if (request_type != null) return;
    request_type = try ffi.typeFromModuleAndSpec(mod, &type_spec, null);
    try ffi.setAttrRaw(mod, "Request", request_type.?);
}

pub fn create(pool: *SmallPool, lease: core.Lease) ffi.PythonError!*PyObject {
    const tp = request_type orelse return error.PythonError;
    const tp_obj: *ffi.PyTypeObject = @ptrCast(@alignCast(tp));
    const obj: *PyObject = tp_obj.tp_alloc.?(tp_obj, 0) orelse return error.PythonError;
    getData(obj).* = .{ .pool = pool, .lease = lease };
    return obj;
}
