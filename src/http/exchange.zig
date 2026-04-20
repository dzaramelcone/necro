const std = @import("std");
const posix = std.posix;
const necro = @import("necro");
const py = necro.py;
const ffi = py.ffi;
const http = necro.http;
const router = http.router;

const MAX_IOVECS = 4;
const SEND_HDR_CAP = 128;

pub const Request = struct {
    buf: []u8 = &.{},
    len: usize = 0,
    meta: router.Meta = .{},
    router: ?*const router.Router = null,

    pub fn ensureCapacity(self: *Request, ally: std.mem.Allocator, needed: usize) !void {
        if (self.buf.len >= needed) return;
        const new_cap = @max(needed, self.buf.len * 2, 4096);
        const new_buf = try ally.alloc(u8, new_cap);
        if (self.len > 0) @memcpy(new_buf[0..self.len], self.buf[0..self.len]);
        if (self.buf.len > 0) ally.free(self.buf);
        self.buf = new_buf;
    }

    pub fn recvSlice(self: *Request) []u8 {
        return self.buf[self.len..];
    }

    pub fn deinit(self: *Request, ally: std.mem.Allocator) void {
        if (self.buf.len > 0) ally.free(self.buf);
        self.buf = &.{};
        self.len = 0;
        self.meta = .{};
    }

    pub fn method(self: *const Request) []const u8 {
        const r = self.router orelse return "";
        if (self.meta.handler >= r.handler_method_len.len) return "";
        const m_len = r.handler_method_len[self.meta.handler];
        if (m_len == 0 or m_len >= self.len) return "";
        return self.buf[0..m_len];
    }

    pub fn path(self: *const Request) []const u8 {
        const r = self.router orelse return "";
        if (self.meta.handler >= r.handler_method_len.len) return "";
        const m_len = r.handler_method_len[self.meta.handler];
        const start: usize = @as(usize, m_len) + 1;
        const end: usize = self.meta.uri_end;
        if (start > end or end > self.len) return "";
        return self.buf[start..end];
    }

    pub fn body(self: *const Request) []const u8 {
        const off: usize = self.meta.body_off;
        if (off == 0 or off > self.len) return "";
        return self.buf[off..self.len];
    }

    pub fn headerSlice(self: *const Request, i: usize) struct { name: []const u8, value: []const u8 } {
        const h = self.meta.headers[i];
        return .{
            .name = self.buf[h.name_off..][0..h.name_len],
            .value = self.buf[h.value_off..][0..h.value_len],
        };
    }

    pub fn paramSlice(self: *const Request, i: usize) []const u8 {
        const p = self.meta.params[i];
        return self.buf[p.off..][0..p.len];
    }
};

pub const SendState = struct {
    hdr: [SEND_HDR_CAP]u8 = undefined,
    iovecs: [MAX_IOVECS]posix.iovec_const = undefined,
    iov_count: usize = 0,
    total_len: usize = 0,
    sent: usize = 0,
    body: ?[]const u8 = null,
    body_buf: ?[]u8 = null,
    body_py: py.result.PyBodyHold = .{},
    mode: SendMode = .idle,
    close_on_done: bool = false,
    msg: posix.msghdr_const = std.mem.zeroes(posix.msghdr_const),

    pub const SendMode = enum { idle, pending };
};

const aio = necro.aio;

pub const Conn = struct {
    fd: posix.socket_t = undefined,

    recv_token: aio.Token = .{ .tag = .conn_recv },
    send_token: aio.Token = .{ .tag = .conn_send },

    current: ?*Exchange = null,

    idle: aio.IdleList.Node = .{},

    tls: ?*aio.tls.TlsHandshake = null,
};

pub const Exchange = struct {
    conn: ?*Conn = null,
    req: *Request = undefined,
    send: *SendState = undefined,
    aborted: bool = false,
    timeout: aio.IdleList.Node = .{},

    py_coro: ?*ffi.PyObject = null,
    py_future: ?*ffi.PyObject = null,
    io: IoState = .none,

    pub const IoState = union(enum) {
        none,
        redis,
        pg: struct {
            mode: py.future.PgMode,
            stmt_idx: u16,
            model_cls: ?*ffi.PyObject,
        },
    };

    pub fn dropAndCleanup(self: *Exchange) void {
        if (self.py_coro) |coro| {
            ffi.coroutineClose(coro);
            ffi.decref(coro);
            self.py_coro = null;
        }
        if (self.py_future) |f| {
            ffi.decref(f);
            self.py_future = null;
        }
        if (self.io == .pg) ffi.xdecref(self.io.pg.model_cls);
        self.io = .none;
    }
};
