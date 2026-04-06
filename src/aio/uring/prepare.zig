//! Prepare a Python handler's return value for the uring send path.

const std = @import("std");
const ffi = @import("../../py/ffi.zig");
const Response = @import("../../http/response.zig").Response;
const Slab = @import("../../db/slab.zig").Slab;
const SlabPool = @import("../../db/slab.zig").SlabPool;
const tryWriteJson = @import("../../py/json.zig").tryWrite;

const PyObject = ffi.PyObject;

pub const PyBodyHold = struct {
    owner: ?*PyObject = null,
    buffer: ?ffi.BufferView = null,

    pub fn deinit(self: *PyBodyHold) void {
        if (self.buffer) |*view| ffi.releaseBuffer(view);
        ffi.xdecref(self.owner);
        self.* = .{};
    }
};

pub const Prepared = struct {
    response: Response,
    body_slab: ?*Slab = null,
    py_body: PyBodyHold = .{},

    pub fn fromResponse(response: Response) Prepared {
        return .{ .response = response };
    }

    pub fn deinit(self: *Prepared) void {
        if (self.body_slab) |s| s.release();
        self.py_body.deinit();
        self.* = undefined;
    }
};

pub const PrepareError = ffi.PythonError || error{
    UnsupportedReturnType,
    BufferTooSmall,
    SlabPoolExhausted,
    OutOfMemory,
};

fn prepareBinary(py_result: *PyObject) PrepareError!Prepared {
    if (ffi.isBytes(py_result)) {
        var resp = Response.init(.ok);
        _ = resp.setBody(ffi.bytesData(py_result));
        return .{
            .response = resp,
            .py_body = .{ .owner = ffi.increfBorrowed(py_result) },
        };
    }

    if (ffi.isMemoryView(py_result)) {
        var view = try ffi.getReadOnlyBuffer(py_result);
        errdefer ffi.releaseBuffer(&view);
        if (!ffi.bufferIsReadOnly(&view)) return error.UnsupportedReturnType;
        var resp = Response.init(.ok);
        _ = resp.setBody(ffi.bufferData(&view));
        return .{
            .response = resp,
            .py_body = .{
                .owner = ffi.increfBorrowed(py_result),
                .buffer = view,
            },
        };
    }

    return error.UnsupportedReturnType;
}

fn prepareText(py_result: *PyObject) PrepareError!Prepared {
    if (!ffi.isString(py_result)) return error.UnsupportedReturnType;
    const s = try ffi.unicodeAsUTF8(py_result);
    return .{
        .response = Response.text(std.mem.span(s)),
        .py_body = .{ .owner = ffi.increfBorrowed(py_result) },
    };
}

fn prepareJson(py_result: *PyObject, body_buf: []u8, response_pool: *SlabPool) PrepareError!Prepared {
    var pos: usize = 0;
    const wrote = tryWriteJson(py_result, body_buf, &pos) catch |err| switch (err) {
        error.BufferTooSmall => {
            const body_slab = try response_pool.acquire();
            errdefer body_slab.release();
            var slab_pos: usize = 0;
            const slab_wrote = try tryWriteJson(py_result, &body_slab.data, &slab_pos);
            if (!slab_wrote) return error.UnsupportedReturnType;
            return .{
                .response = Response.json(body_slab.data[0..slab_pos]),
                .body_slab = body_slab,
            };
        },
        else => return err,
    };
    if (!wrote) return error.UnsupportedReturnType;
    return Prepared.fromResponse(Response.json(body_buf[0..pos]));
}

pub fn prepare(
    py_result: *PyObject,
    body_buf: []u8,
    response_pool: *SlabPool,
) PrepareError!Prepared {
    if (ffi.isNone(py_result)) {
        return Prepared.fromResponse(Response.init(.no_content));
    }

    if (prepareBinary(py_result)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    if (prepareText(py_result)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    if (prepareJson(py_result, body_buf, response_pool)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    return error.UnsupportedReturnType;
}
