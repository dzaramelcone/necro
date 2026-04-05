//! Python <-> Postgres parameter adapter.
//! Converts a Python tuple of params into a stmt.ParamBuffer ready for encode.

const std = @import("std");
const ffi = @import("ffi.zig");
const stmt = @import("../db/stmt.zig");

const PyObject = ffi.PyObject;

pub fn paramsFromTuple(tuple: *PyObject, out: *stmt.ParamBuffer) !void {
    const n: usize = @intCast(ffi.tupleSize(tuple));
    if (n > stmt.ParamBuffer.MAX) return error.TooManyParams;

    for (0..n) |i| {
        const p = ffi.tupleGetItem(tuple, @intCast(i)) orelse return error.InvalidState;
        if (ffi.isNone(p)) {
            out.setNull(i);
            continue;
        }
        if (ffi.isString(p)) {
            const text = try ffi.unicodeAsUTF8(p);
            out.setBorrowed(i, std.mem.span(text));
            continue;
        }
        const str_obj = try ffi.objectStr(p);
        defer ffi.decref(str_obj);
        const text = try ffi.unicodeAsUTF8(str_obj);
        try out.setCopy(i, std.mem.span(text));
    }
    out.len = n;
}
