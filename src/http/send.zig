const std = @import("std");
const posix = std.posix;
const necro = @import("necro");
const ffi = necro.py.ffi;
const Response = necro.http.response.Response;
const Lease = necro.core.Lease;

pub const SendSource = union(enum) {
    native: Response,
    python: *ffi.PyObject,
};

pub const SendTask = struct {
    conn: Lease,
    source: SendSource,
    keep_alive: bool = true,
};

pub fn makeResponseSend(conn: Lease, resp: Response) SendTask {
    return .{ .conn = conn, .source = .{ .native = resp }, .keep_alive = true };
}

pub fn makeErrorSend(conn: Lease, status: std.http.Status) SendTask {
    return .{ .conn = conn, .source = .{ .native = Response.init(status) }, .keep_alive = false };
}

pub fn makePythonSend(conn: Lease, py_result: *ffi.PyObject) SendTask {
    return .{ .conn = conn, .source = .{ .python = py_result }, .keep_alive = true };
}

pub fn advanceIovecs(iovecs: []posix.iovec_const, iov_count: *usize, advance: usize) void {
    var remaining = advance;
    var idx: usize = 0;
    while (idx < iov_count.* and remaining > 0) {
        const len = iovecs[idx].len;
        if (remaining < len) {
            iovecs[idx].base += remaining;
            iovecs[idx].len -= remaining;
            remaining = 0;
            break;
        }
        remaining -= len;
        idx += 1;
    }
    if (idx > 0) {
        const next_len = iov_count.* - idx;
        if (next_len > 0) {
            std.mem.copyForwards(posix.iovec_const, iovecs[0..next_len], iovecs[idx..iov_count.*]);
        }
        iov_count.* = next_len;
    }
    std.debug.assert(remaining == 0);
}
