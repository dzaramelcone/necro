const std = @import("std");
const ffi = @import("ffi.zig");
const writeJson = @import("json.zig").write;
const necro = @import("necro");
const Response = necro.http.Response;

pub const PyBodyHold = struct {
    owner: ?*ffi.PyObject = null,
    buffer: ?ffi.BufferView = null,

    pub fn deinit(self: *PyBodyHold) void {
        if (self.buffer) |*view| ffi.releaseBuffer(view);
        ffi.xdecref(self.owner);
        self.* = .{};
    }
};

pub const Prepared = struct {
    response: Response,
    py_body: PyBodyHold = .{},

    pub fn fromResponse(response: Response) Prepared {
        return .{ .response = response };
    }

    pub fn deinit(self: *Prepared) void {
        self.py_body.deinit();
        self.* = undefined;
    }
};

pub const PrepareError = ffi.PythonError || error{
    UnsupportedReturnType,
    ResponseBodyTooLarge,
};

fn prepareBinary(py_result: *ffi.PyObject) PrepareError!Prepared {
    if (ffi.isBytes(py_result)) {
        var resp = Response.init(.ok);
        resp.body = (ffi.bytesData(py_result));
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
        resp.body = (ffi.bufferData(&view));
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

fn prepareText(py_result: *ffi.PyObject) PrepareError!Prepared {
    if (!ffi.isString(py_result)) return error.UnsupportedReturnType;
    const s = try ffi.unicodeAsUTF8(py_result);
    return .{
        .response = Response.text(std.mem.span(s)),
        .py_body = .{ .owner = ffi.increfBorrowed(py_result) },
    };
}

fn prepareJson(py_result: *ffi.PyObject, buf: []u8) PrepareError!Prepared {
    var pos: usize = 0;
    writeJson(py_result, buf, &pos) catch |e| return switch (e) {
        error.UnsupportedType => error.UnsupportedReturnType,
        error.BufferTooSmall => error.ResponseBodyTooLarge,
        else => @errorCast(e),
    };
    return .{ .response = Response.json(buf[0..pos]) };
}

pub fn prepare(py_result: *ffi.PyObject, buf: []u8) PrepareError!Prepared {
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

    if (prepareJson(py_result, buf)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    return error.UnsupportedReturnType;
}
