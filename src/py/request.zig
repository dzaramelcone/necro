const std = @import("std");
const ffi = @import("ffi.zig");
const necro = @import("necro");
const http = necro.http;

const PyObject = ffi.PyObject;
const Request = http.exchange.Request;

const RequestObject = extern struct {
    ob_base: ffi.PyObject,

    method_obj: ?*PyObject = null,
    path_obj: ?*PyObject = null,
    body_obj: ?*PyObject = null,
    headers_obj: ?*PyObject = null,
    params_obj: ?*PyObject = null,
};

fn self(obj: *PyObject) *RequestObject {
    return @ptrCast(@alignCast(obj));
}

fn requestDealloc(obj: ?*PyObject) callconv(.c) void {
    const s = self(obj orelse return);
    ffi.xdecref(s.method_obj);
    ffi.xdecref(s.path_obj);
    ffi.xdecref(s.body_obj);
    ffi.xdecref(s.headers_obj);
    ffi.xdecref(s.params_obj);
    ffi.freeObject(obj.?);
}

fn lowercaseUnicode(slice: []const u8) ffi.PythonError!*PyObject {
    const obj = try ffi.unicodeFromSlice(slice.ptr, slice.len);
    defer ffi.decref(obj);
    return ffi.callMethodNoArgs(obj, "lower");
}

fn buildHeaders(req: *const Request) ffi.PythonError!*PyObject {
    const n: isize = @intCast(req.meta.num_headers);
    const tup = try ffi.tupleNew(n);
    errdefer ffi.decref(tup);
    for (0..@intCast(n)) |i| {
        const h = req.headerSlice(i);
        const name_obj = try lowercaseUnicode(h.name);
        errdefer ffi.decref(name_obj);
        const val_obj = try ffi.unicodeFromSlice(h.value.ptr, h.value.len);
        errdefer ffi.decref(val_obj);
        const pair = try ffi.tupleNew(2);
        try ffi.tupleSetItem(pair, 0, name_obj);
        try ffi.tupleSetItem(pair, 1, val_obj);
        try ffi.tupleSetItem(tup, @intCast(i), pair);
    }
    return tup;
}

fn buildParams(req: *const Request) ffi.PythonError!*PyObject {
    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);
    const router = req.router orelse return dict;
    const handler_id = req.meta.handler;
    if (handler_id >= router.handler_param_start.len) return dict;
    const pn_start = router.handler_param_start[handler_id];
    const pn_count = router.handler_param_count[handler_id];
    const n = @min(pn_count, req.meta.num_params);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const span = router.param_names[pn_start + i];
        const name = router.prefix_buf[span.off..][0..span.len];
        const value = req.paramSlice(i);
        const name_obj = try ffi.unicodeFromSlice(name.ptr, name.len);
        defer ffi.decref(name_obj);
        const value_obj = try ffi.unicodeFromSlice(value.ptr, value.len);
        defer ffi.decref(value_obj);
        if (ffi.c.PyDict_SetItem(dict, name_obj, value_obj) != 0) return error.PythonError;
    }
    return dict;
}

fn buildBody(req: *const Request) ffi.PythonError!*PyObject {
    const b = req.body();
    const obj = try ffi.bytesNew(@intCast(b.len));
    @memcpy(ffi.bytesAsSlice(obj, b.len)[0..b.len], b);
    return obj;
}

fn populate(req: *const Request, s: *RequestObject) ffi.PythonError!void {
    const m = req.method();
    s.method_obj = try ffi.unicodeFromSlice(m.ptr, m.len);
    const p = req.path();
    s.path_obj = try ffi.unicodeFromSlice(p.ptr, p.len);
    s.body_obj = try buildBody(req);
    s.headers_obj = try buildHeaders(req);
    s.params_obj = try buildParams(req);
}

const Attr = enum { method, path, body, headers, params };

fn matchAttr(name_obj: *PyObject) ?Attr {
    const z = ffi.unicodeAsUTF8(name_obj) catch return null;
    const name: []const u8 = std.mem.sliceTo(z, 0);
    if (std.mem.eql(u8, name, "method")) return .method;
    if (std.mem.eql(u8, name, "path")) return .path;
    if (std.mem.eql(u8, name, "body")) return .body;
    if (std.mem.eql(u8, name, "headers")) return .headers;
    if (std.mem.eql(u8, name, "params")) return .params;
    return null;
}

fn getAttr(s: *RequestObject, attr: Attr) ?*PyObject {
    const slot: ?*PyObject = switch (attr) {
        .method => s.method_obj,
        .path => s.path_obj,
        .body => s.body_obj,
        .headers => s.headers_obj,
        .params => s.params_obj,
    };
    return ffi.increfBorrowed(slot.?);
}

fn requestGetAttr(self_obj: ?*PyObject, name_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const s = self(self_obj orelse return null);
    const name = name_obj orelse return null;
    const attr = matchAttr(name) orelse return ffi.genericGetAttr(self_obj, name_obj);
    return getAttr(s, attr);
}

fn requestSubscript(self_obj: ?*PyObject, key_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const s = self(self_obj orelse return null);
    const key = key_obj orelse return null;
    const attr = matchAttr(key) orelse {
        ffi.errSetString(ffi.exc.KeyError(), "unknown key");
        return null;
    };
    return getAttr(s, attr);
}

fn requestRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const s = self(self_obj orelse return null);
    const m_c = ffi.unicodeAsUTF8(s.method_obj.?) catch return null;
    const p_c = ffi.unicodeAsUTF8(s.path_obj.?) catch return null;
    const m = std.mem.span(m_c);
    const p = std.mem.span(p_c);
    var buf: [256]u8 = undefined;
    const repr = std.fmt.bufPrint(&buf, "Request({s} {s})", .{ m, p }) catch return null;
    return ffi.unicodeFromSlice(repr.ptr, repr.len) catch return null;
}

const type_slots = ffi.table(ffi.TypeSlot, .{
    ffi.typeSlot(ffi.Slot.dealloc, requestDealloc),
    ffi.typeSlot(ffi.Slot.getattro, requestGetAttr),
    ffi.typeSlot(ffi.Slot.mp_subscript, requestSubscript),
    ffi.typeSlot(ffi.Slot.repr, requestRepr),
});

const type_spec = ffi.TypeSpec{
    .name = "necro.core.Request",
    .basicsize = @intCast(@sizeOf(RequestObject)),
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

pub fn create(req: *Request) ffi.PythonError!*PyObject {
    const tp = request_type orelse return error.PythonError;
    const tp_obj: *ffi.PyTypeObject = @ptrCast(@alignCast(tp));
    const obj: *PyObject = tp_obj.tp_alloc.?(tp_obj, 0) orelse return error.PythonError;
    const s: *RequestObject = @ptrCast(@alignCast(obj));
    s.method_obj = null;
    s.path_obj = null;
    s.body_obj = null;
    s.headers_obj = null;
    s.params_obj = null;

    populate(req, s) catch |err| {
        ffi.decref(obj);
        return err;
    };
    return obj;
}
