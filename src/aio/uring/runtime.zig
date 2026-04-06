//! Staged event-driven pipeline.
//! Each stage defines its own typed task.
//!
//! Connections are pure data (fd + leased recv queue).
//!
//! DAG:
//!   [kernel recv]
//!     └→ ParseTask
//!        └→ HandleTask (Python) ─┬→ SendTask → [kernel send/sendmsg_zc] → recv
//!                                └→ RedisTask ··· → SendTask
//!
//! The uring path uses connection-owned send state so response buffers stay
//! valid across partial sends and zerocopy notifications.

const std = @import("std");
const posix = std.posix;
const io_uring = @import("sys.zig");
const Completion = io_uring.Completion;
const Pool = @import("../../pool.zig").Pool;
const http1 = @import("../../http/parser.zig");
const handler_mod = @import("../../handler.zig");
const driver = @import("../../py/driver.zig");
const ffi = @import("../../py/ffi.zig");
const future_mod = @import("../../py/loop/futures.zig");
const py_module = @import("../../py/module.zig");
const necro_request = @import("../../py/request.zig");
const py_send = @import("prepare.zig");
const c = ffi.c;
const router_mod = @import("../../http/router.zig");
const response_mod = @import("../../http/response.zig");
const metrics_mod = @import("metrics.zig");
const Stats = metrics_mod.Stats;
const stmt_cache_mod = @import("../../db/stmt.zig");
const StmtCache = stmt_cache_mod.Cache;
const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;
const pg_stream = @import("../../db/pg_stream_uring.zig");
const slab_mod = @import("../../db/slab.zig");
const SlabPool = slab_mod.SlabPool;
const uring_recv_group = @import("recv_group.zig");
const UringRecvGroup = uring_recv_group.Group;
const uring_recv_queue = @import("recv_queue.zig");
const UringRecvQueue = uring_recv_queue.Queue;
const row = @import("../../db/row.zig");
const PyBodyHold = py_send.PyBodyHold;
const PgMode = future_mod.PgMode;

const log = std.log.scoped(.@"necro/pipeline");

const MAX_BATCH = 1024;
const MAX_IOVECS = 4; // status | common | per-response | body
const SEND_HDR_CAP = 128;
const HTTP_RECV_BUFFER_COUNT: u16 = 256;
const HTTP_RECV_BUFFER_SIZE: u32 = 16 * 1024;
const HTTP_RECV_GROUP_ID: u16 = 1;
const HTTP_RECV_MAX_BYTES: usize = 64 * 1024;

// sendmsg_zc has extra notification overhead. Keep tiny responses on sendv and
// reserve zerocopy sends for bodies large enough to amortize it.
const HTTP_SEND_ZC_MIN_BYTES: usize = 4 * 1024;

const PG_RECV_BUFFER_COUNT = uring_recv_group.DEFAULT_BUFFER_COUNT;
const PG_RECV_BUFFER_SIZE = uring_recv_group.DEFAULT_BUFFER_SIZE;
const PG_RECV_GROUP_ID: u16 = 2;
const PG_RECV_MAX_BYTES = @as(usize, PG_RECV_BUFFER_SIZE) * @as(usize, PG_RECV_BUFFER_COUNT);

const REQUEST_SLAB_CACHE = 128;
const REQUEST_SLAB_MAX_LIVE = 512;
const RESPONSE_SLAB_CACHE = 128;
const RESPONSE_SLAB_MAX_LIVE = 1024;
const RESULT_SLAB_CACHE = 128;
const RESULT_SLAB_MAX_LIVE = 1024;

pub const Token = struct {
    _align: usize = 0,
    tag: Tag = .conn_recv,

    pub const Tag = enum(u8) {
        conn_recv,
        conn_send,
        accept,
        redis_send,
        redis_recv,
        pg_send,
        pg_recv,
    };
};

pub const Conn = struct {
    fd: posix.socket_t = undefined,
    pool_index: u16 = 0,
    recv_queue: UringRecvQueue = .{ .max_bytes = HTTP_RECV_MAX_BYTES },
    recv_armed: bool = false,
    parse_queued: bool = false,
    inflight_request_len: usize = 0,

    // Streaming SIMD header parser from stdlib
    head_parser: std.http.HeadParser = .{},
    head_fed: usize = 0,

    // Small response scratch for buffered fallback bodies.
    // First-class str/bytes/memoryview responses can bypass this entirely by
    // borrowing Python-owned memory until send completion.
    body_buf: [4096]u8 = undefined,

    send_hdr: [SEND_HDR_CAP]u8 = undefined,
    send_iovecs: [MAX_IOVECS]posix.iovec_const = undefined,
    send_iov_count: usize = 0,
    send_msg: posix.msghdr_const = std.mem.zeroes(posix.msghdr_const),
    send_body: ?[]const u8 = null,
    send_body_lease: ?*slab_mod.Slab = null,
    send_body_py: PyBodyHold = .{},
    send_total_len: usize = 0,
    send_sent: usize = 0,
    send_mode: enum { idle, sendv, sendmsg_zc } = .idle,
    zc_hold: ?ZcHold = null,
    zc_notif_pending: bool = false,
    close_after_notif: bool = false,

    recv_token: Token = .{ .tag = .conn_recv },
    send_token: Token = .{ .tag = .conn_send },

    pub fn resetRecv(self: *Conn, group: *UringRecvGroup) void {
        self.recv_queue.clear(group);
        self.recv_armed = false;
        self.parse_queued = false;
        self.inflight_request_len = 0;
        self.head_parser = .{};
        self.head_fed = 0;
    }
};

const ZcHold = struct {
    hdr: [SEND_HDR_CAP]u8 = undefined,
    hdr_len: usize = 0,
};

pub const ParseTask = struct { conn: u16 };

pub const HandleTask = struct {
    conn: u16,
    header_end: usize,
    content_length: usize,
};

const PythonHandleKind = enum(u8) {
    no_args,
    params_only,
    request,
};

pub const PythonHandleTask = struct {
    conn: u16,
    py_id: u32,
    kind: PythonHandleKind,
    is_async: bool = false,
    request_backing: ?necro_request.Backing = null,
    params: [8]router_mod.PathParam = undefined,
    param_count: u8 = 0,
};

const PyReadyTask = union(enum) {
    invoke: PythonHandleTask,
    redis_resume: RedisResumeReady,
    pg_resume: PgResumeReady,
};

const RedisResumeReady = struct {
    waiter: RedisWaiter,
    result: *ffi.PyObject,
};

const PgResumeReady = struct {
    waiter: PgWaiter,
    result: *ffi.PyObject,
};

const SendSource = union(enum) {
    native: response_mod.Response,
    python: *ffi.PyObject,
};

pub const SendTask = struct {
    conn: u16,
    source: SendSource,
    keep_alive: bool = true,
};

const RedisWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
    py_future: *ffi.PyObject,
};

const PgWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
    py_future: *ffi.PyObject,
    mode: PgMode,
    stmt_idx: u16,
    model_cls: ?*ffi.PyObject,
};

const MAX_PG_CONNS = 8;
const PG_WAITER_CAP = MAX_BATCH;

pub const PgConn = struct {
    fd: posix.socket_t = undefined,
    send_token: Token = .{ .tag = .pg_send },
    recv_token: Token = .{ .tag = .pg_recv },
    send_buf: [16384]u8 = undefined,
    send_len: usize = 0,
    send_state: enum { idle, sending } = .idle,
    send_offset: usize = 0,
    recv_queue: UringRecvQueue = .{ .max_bytes = PG_RECV_MAX_BYTES },
    recv_state: enum { idle, parsing, err } = .idle,
    recv_armed: bool = false,
    fail_status: std.http.Status = .internal_server_error,
    fail_body: ?[]const u8 = null,
    in_flight: usize = 0,
    prepared: [MAX_PG_STMTS]bool = .{false} ** MAX_PG_STMTS,
    waiters: [PG_WAITER_CAP]PgWaiter = undefined,
    waiter_head: usize = 0,
    waiter_tail: usize = 0,
    waiter_count: usize = 0,
    batch_sizes: [PG_WAITER_CAP]u16 = undefined,
    batch_head: usize = 0,
    batch_tail: usize = 0,
    batch_count: usize = 0,

    fn pushWaiter(self: *PgConn, conn_idx: u16, py_coro: *ffi.PyObject, py_future: *ffi.PyObject, mode: PgMode, stmt_idx: u16, model_cls: ?*ffi.PyObject) !void {
        if (self.waiter_count >= PG_WAITER_CAP) return error.WaiterQueueFull;
        self.waiters[self.waiter_tail] = .{
            .conn_idx = conn_idx,
            .py_coro = py_coro,
            .py_future = py_future,
            .mode = mode,
            .stmt_idx = stmt_idx,
            .model_cls = model_cls,
        };
        self.waiter_tail = (self.waiter_tail + 1) % PG_WAITER_CAP;
        self.waiter_count += 1;
    }

    fn peekWaiter(self: *const PgConn) ?PgWaiter {
        if (self.waiter_count == 0) return null;
        return self.waiters[self.waiter_head];
    }

    fn popWaiter(self: *PgConn) ?PgWaiter {
        if (self.waiter_count == 0) return null;
        const w = self.waiters[self.waiter_head];
        self.waiter_head = (self.waiter_head + 1) % PG_WAITER_CAP;
        self.waiter_count -= 1;
        return w;
    }

    fn pushBatch(self: *PgConn, query_count: usize) !void {
        if (query_count == 0) return;
        if (query_count > std.math.maxInt(u16) or self.batch_count >= PG_WAITER_CAP) {
            return error.WaiterQueueFull;
        }
        self.batch_sizes[self.batch_tail] = @intCast(query_count);
        self.batch_tail = (self.batch_tail + 1) % PG_WAITER_CAP;
        self.batch_count += 1;
    }

    fn currentBatchRemaining(self: *const PgConn) usize {
        if (self.batch_count == 0) return 0;
        return self.batch_sizes[self.batch_head];
    }

    fn completeBatchQuery(self: *PgConn) !void {
        if (self.batch_count == 0) return error.ProtocolViolation;
        std.debug.assert(self.batch_sizes[self.batch_head] > 0);
        self.batch_sizes[self.batch_head] -= 1;
        if (self.batch_sizes[self.batch_head] == 0) _ = self.popBatch();
    }

    fn popBatch(self: *PgConn) ?u16 {
        if (self.batch_count == 0) return null;
        const size = self.batch_sizes[self.batch_head];
        self.batch_head = (self.batch_head + 1) % PG_WAITER_CAP;
        self.batch_count -= 1;
        return size;
    }

    fn clearBatches(self: *PgConn) void {
        self.batch_head = 0;
        self.batch_tail = 0;
        self.batch_count = 0;
    }
};

// ── Typed stage queues ────────────────────────────────────────────

pub fn Queue(comptime T: type) type {
    return struct {
        items: [MAX_BATCH]T = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), item: T) !void {
            if (self.len >= MAX_BATCH) return error.Overflow;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }

        pub fn mutableSlice(self: *@This()) []T {
            return self.items[0..self.len];
        }
    };
}

// ── Pipeline ──────────────────────────────────────────────────────

pub const Pipeline = struct {
    backend: io_uring.IoUring,
    conns: *Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_token: Token = .{ .tag = .accept },
    accept_armed: bool = false,
    req_ctx: ?*const handler_mod.RequestContext = null,

    // Typed stage queues
    parse_q: Queue(ParseTask) = .{},
    handle_q: Queue(HandleTask) = .{},
    py_ready_q: Queue(PyReadyTask) = .{},
    send_q: Queue(SendTask) = .{},
    close_q: Queue(u16) = .{},
    py_body_release: std.ArrayListUnmanaged(PyBodyHold) = .{},

    // ── Redis state (full-duplex: independent send/recv) ───────
    redis_fd: ?posix.socket_t = null,
    redis_send_token: Token = .{ .tag = .redis_send },
    redis_recv_token: Token = .{ .tag = .redis_recv },
    redis_send_buf: [8192]u8 = undefined,
    redis_send_len: usize = 0,
    redis_send_state: enum { idle, sending } = .idle,
    redis_send_offset: usize = 0,
    redis_recv_buf: [8192]u8 = undefined,
    redis_recv_len: usize = 0,
    redis_parse_pos: usize = 0,
    redis_recv_state: enum { idle, receiving, parsing, err } = .idle,
    redis_waiters: [MAX_BATCH]RedisWaiter = undefined,
    redis_waiter_head: usize = 0,
    redis_waiter_tail: usize = 0,
    redis_waiter_count: usize = 0,
    redis_in_flight: usize = 0, // commands sent, awaiting RESP response

    // ── Postgres connection pool (full-duplex, round-robin) ────
    pg_conns: [MAX_PG_CONNS]PgConn = undefined,
    pg_conn_count: u8 = 0,
    pg_next_conn: u8 = 0, // round-robin counter
    pg_last_conn: u8 = 0, // last connection selected by pgSendSlice
    pg_wire_ns: u64 = 0, // total pg parse+py time (set by stagePostgres)
    pg_stmt_cache: StmtCache = .{},
    http_recv_group: UringRecvGroup,
    pg_recv_group: UringRecvGroup,
    request_pool: SlabPool,
    response_pool: SlabPool,
    pg_result_pool: SlabPool,

    // Stage timing stats
    stats: Stats = .{},

    pub fn init(self: *Pipeline, allocator: std.mem.Allocator, conns: *Pool(Conn), entries: u16) !void {
        var backend = try io_uring.IoUring.init(allocator, entries);
        errdefer backend.deinit(allocator);

        const http_recv_group = try UringRecvGroup.init(
            backend.ring.fd,
            allocator,
            HTTP_RECV_GROUP_ID,
            HTTP_RECV_BUFFER_SIZE,
            HTTP_RECV_BUFFER_COUNT,
        );
        const pg_recv_group = UringRecvGroup.init(
            backend.ring.fd,
            allocator,
            PG_RECV_GROUP_ID,
            PG_RECV_BUFFER_SIZE,
            PG_RECV_BUFFER_COUNT,
        ) catch |err| {
            var group = http_recv_group;
            try group.deinit();
            return err;
        };

        var request_pool = SlabPool.init(allocator, REQUEST_SLAB_MAX_LIVE);
        errdefer request_pool.deinit();

        var response_pool = SlabPool.init(allocator, RESPONSE_SLAB_MAX_LIVE);
        errdefer response_pool.deinit();

        var result_pool = SlabPool.init(allocator, RESULT_SLAB_MAX_LIVE);
        errdefer result_pool.deinit();

        self.* = .{
            .backend = backend,
            .conns = conns,
            .allocator = allocator,
            .http_recv_group = http_recv_group,
            .pg_recv_group = pg_recv_group,
            .request_pool = request_pool,
            .response_pool = response_pool,
            .pg_result_pool = result_pool,
        };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) !void {
        if (self.req_ctx) |ctx| {
            if (ctx.py_ctx) |py_ctx| {
                py_ctx.py.acquireGil();
                defer py_ctx.py.releaseGil();
                self.drainPendingPyBodyReleases();
            }
        }
        var conn_iter = self.conns.iterator();
        while (conn_iter.next_ptr()) |conn| {
            conn.recv_queue.deinit(&self.http_recv_group);
        }
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            pg.recv_queue.deinit(&self.pg_recv_group);
        }
        try self.http_recv_group.deinit();
        try self.pg_recv_group.deinit();
        self.request_pool.deinit();
        self.response_pool.deinit();
        self.pg_result_pool.deinit();
        self.py_body_release.deinit(allocator);
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        self.listen_fd = listen_fd;
        self.accept_token = .{ .tag = .accept };
        try self.armAccept();
    }

    // ── Main loop ─────────────────────────────────────────────────

    pub fn run(self: *Pipeline) !void {
        _ = http1.commonResponseHeaders();
        while (self.running) {
            _ = try self.cycle(1);
            while (try self.cycle(0)) {}
        }
    }

    fn cycle(self: *Pipeline, wait_nr: u32) !bool {
        const m = comptime metrics_mod.enabled;
        const t0 = if (m) instant() else {};
        try self.backend.publish();
        const completions = try self.backend.reap(wait_nr);
        if (completions.tokens.len == 0) return false;
        const t_io = if (m) instant() else {};

        // Refresh cached response prefix (once per second)
        _ = http1.commonResponseHeaders();

        // Reset queues
        self.parse_q.len = 0;
        self.handle_q.len = 0;
        self.py_ready_q.len = 0;
        self.send_q.len = 0;
        self.close_q.len = 0;

        self.stats.recordBatchSize(completions.tokens.len);

        // CQE-driven completion routing
        for (completions.tokens, completions.completions) |token, completion| {
            try self.handleCompletion(token, completion);
        }
        const t_classify = if (m) instant() else {};

        // DAG
        try self.stageParse();
        const t_parse = if (m) instant() else {};

        const http_requests = if (m) self.handle_q.len else 0;
        try self.stageHandlePrep();
        const t_handle_prep = if (m) instant() else {};

        // GIL held across Python invoke + redis + postgres stages (one acquire for all Python work)
        const py_ctx = if (self.req_ctx) |ctx| ctx.py_ctx else null;
        const need_gil = py_ctx != null and (self.py_ready_q.len > 0 or
            self.redis_recv_state == .parsing or
            self.redis_recv_state == .err or
            self.anyPgNeedsGil() or
            self.py_body_release.items.len > 0);
        if (need_gil) py_ctx.?.py.acquireGil();
        defer if (need_gil) py_ctx.?.py.releaseGil();

        try self.stageHandlePython();
        const t_handle_py = if (m) instant() else {};
        try self.stageRedis();
        try self.drainPythonReady();
        const t_redis = if (m) instant() else {};
        const pg_rows_before = if (m) self.totalPgWaiters() else 0;
        try self.stagePostgres();
        try self.drainPythonReady();
        const t_pg = if (m) instant() else {};

        try self.stageSerializeAndSend();
        const t_send = if (m) instant() else {};
        self.stageClose();
        if (need_gil) self.drainPendingPyBodyReleases();
        try self.backend.publish();

        self.stats.cycles += 1;
        self.stats.completions += completions.tokens.len;
        if (comptime m) {
            self.stats.http_requests += http_requests;
            self.stats.ns_io += t_io.since(t0);
            self.stats.ns_classify += t_classify.since(t_io);
            self.stats.ns_parse += t_parse.since(t_classify);
            self.stats.ns_handle_prep += t_handle_prep.since(t_parse);
            self.stats.ns_handle_py += t_handle_py.since(t_handle_prep);
            self.stats.ns_redis += t_redis.since(t_handle_py);
            self.stats.ns_pg_wire += self.pg_wire_ns;
            self.stats.ns_pg_flush += t_pg.since(t_redis) -| self.pg_wire_ns;
            self.stats.pg_rows += pg_rows_before -| self.totalPgWaiters();
            self.stats.ns_send += t_send.since(t_pg);
            if (self.stats.cycles % 10000 == 0) self.stats.dump();
        }

        return true;
    }

    // ── Classify ──────────────────────────────────────────────────

    pub fn onAccept(self: *Pipeline, completion: Completion) void {
        if (completion.result < 0) return;
        const client_fd: posix.socket_t = @intCast(completion.result);

        const idx = self.conns.borrow() catch {
            posix.close(client_fd);
            return;
        };
        const conn = self.conns.get_ptr(idx);
        conn.* = .{
            .fd = client_fd,
            .pool_index = @intCast(idx),
            .recv_token = .{ .tag = .conn_recv },
            .send_token = .{ .tag = .conn_send },
        };
        conn.resetRecv(&self.http_recv_group);
        self.submitConnRecv(conn) catch {
            posix.close(client_fd);
            conn.recv_queue.clear(&self.http_recv_group);
            self.conns.release(idx);
        };
    }

    pub fn onConnRecvCompletion(self: *Pipeline, token: *Token, completion: Completion) !void {
        const conn: *Conn = @fieldParentPtr("recv_token", token);
        if (completion.result == 0) {
            try self.close_q.push(conn.pool_index);
            return;
        }
        if (completion.result < 0) {
            conn.recv_armed = completion.more;
            if (cqeErrno(completion.result) == .NOBUFS) {
                if (!conn.recv_armed) try self.submitConnRecv(conn);
                if (!conn.parse_queued and conn.recv_queue.queuedBytes() > conn.head_fed) {
                    conn.parse_queued = true;
                    try self.parse_q.push(.{ .conn = conn.pool_index });
                }
                return;
            }
            try self.close_q.push(conn.pool_index);
            return;
        }

        const lease = self.http_recv_group.take(completion) catch {
            try self.close_q.push(conn.pool_index);
            return;
        };
        conn.recv_queue.append(&self.http_recv_group, lease) catch |err| switch (err) {
            error.TransportQueueFull, error.TransportSegmentQueueFull => {
                self.http_recv_group.release(lease);
                try self.close_q.push(conn.pool_index);
                return;
            },
        };

        conn.recv_armed = completion.more;
        if (!conn.recv_armed) try self.submitConnRecv(conn);
        if (!conn.parse_queued) {
            conn.parse_queued = true;
            try self.parse_q.push(.{ .conn = conn.pool_index });
        }
    }

    pub fn onConnSendCompletion(self: *Pipeline, token: *Token, completion: Completion) !void {
        const conn: *Conn = @fieldParentPtr("send_token", token);
        if (completion.notification) {
            conn.zc_hold = null;
            conn.zc_notif_pending = false;
            if (conn.send_mode == .idle and conn.send_total_len == 0) {
                self.releaseConnSendBody(conn);
            }
            if (conn.close_after_notif and conn.send_mode == .idle) {
                conn.close_after_notif = false;
                conn.recv_queue.clear(&self.http_recv_group);
                self.conns.release(conn.pool_index);
            }
            return;
        }
        if (completion.result < 0) {
            try self.close_q.push(conn.pool_index);
            return;
        }
        if (conn.send_mode == .idle) return;

        const sent_now: usize = @intCast(completion.result);
        if (sent_now == 0) {
            try self.close_q.push(conn.pool_index);
            return;
        }

        conn.send_sent += sent_now;
        if (conn.send_sent < conn.send_total_len) {
            advanceIovecs(&conn.send_iovecs, &conn.send_iov_count, sent_now);
            if (conn.send_mode == .sendmsg_zc) conn.send_mode = .sendv;
            try self.submitConnSend(conn);
            return;
        }

        conn.send_mode = .idle;
        conn.send_total_len = 0;
        conn.send_sent = 0;
        conn.send_iov_count = 0;
        if (!conn.zc_notif_pending) self.releaseConnSendBody(conn);

        conn.recv_queue.setParseOffset(conn.inflight_request_len);
        _ = conn.recv_queue.consumeParsed(&self.http_recv_group);
        conn.inflight_request_len = 0;
        conn.head_parser = .{};
        conn.head_fed = 0;
        if (conn.recv_queue.queuedBytes() > 0) {
            if (!conn.parse_queued) {
                conn.parse_queued = true;
                try self.parse_q.push(.{ .conn = conn.pool_index });
            }
        } else if (!conn.recv_armed) {
            try self.submitConnRecv(conn);
        }
    }

    // ── Stage: Parse ──────────────────────────────────────────────

    fn stageParse(self: *Pipeline) !void {
        for (self.parse_q.slice()) |pt| {
            const conn = self.conns.get_ptr(pt.conn);
            conn.parse_queued = false;

            var feed_off = conn.head_fed;
            while (feed_off < conn.recv_queue.queuedBytes() and conn.head_parser.state != .finished) {
                const chunk = conn.recv_queue.contiguousFrom(feed_off) orelse break;
                if (chunk.len == 0) break;
                const consumed = conn.head_parser.feed(chunk);
                feed_off += consumed;
                if (consumed < chunk.len) break;
            }
            conn.head_fed = feed_off;

            if (conn.head_parser.state != .finished) {
                if (!conn.recv_armed) try self.submitConnRecv(conn);
                continue;
            }

            const header_end = conn.head_fed;
            const content_length = quickContentLengthQueue(&conn.recv_queue, header_end);
            if (content_length > 0) {
                const body_received = conn.recv_queue.queuedBytes() - header_end;
                if (body_received < content_length) {
                    if (!conn.recv_armed) try self.submitConnRecv(conn);
                    continue;
                }
            }

            conn.inflight_request_len = header_end + content_length;
            try self.handle_q.push(.{
                .conn = pt.conn,
                .header_end = header_end,
                .content_length = content_length,
            });
        }
    }

    // ── Stage: Handle Prep / Python ──────────────────────────────
    // Prep stays outside the GIL and does everything that can be decided
    // from native state:
    //   - SIMD first-byte screening
    //   - route matching
    //   - request parsing when a native handler or Python request object is needed
    //   - native handler execution
    //
    // Only the actual Python call path runs under the GIL in stageHandlePython.

    fn stageHandlePrep(self: *Pipeline) !void {
        const req_ctx = self.req_ctx orelse return;
        const batch = self.handle_q.slice();
        if (batch.len == 0) return;

        var first_bytes: [MAX_BATCH]u8 = undefined;
        for (batch, 0..) |ht, i| {
            const conn = self.conns.get_ptr(ht.conn);
            first_bytes[i] = if (conn.recv_queue.queuedBytes() > 0) conn.recv_queue.byteAt(0) else 0;
        }
        var is_get: [MAX_BATCH]bool = .{false} ** MAX_BATCH;
        simdScreenBytes(first_bytes[0..batch.len], 'G', is_get[0..batch.len]);

        for (batch, 0..) |ht, i| {
            const conn = self.conns.get_ptr(ht.conn);

            if (is_get[i]) {
                if (conn.recv_queue.sliceIfContiguous(0, ht.header_end)) |data| {
                    if (data.len >= 6 and std.mem.eql(u8, data[1..4], "ET ")) {
                        const uri_end = std.mem.indexOfScalarPos(u8, data, 4, ' ') orelse {
                            try self.send_q.push(makeErrorSend(ht.conn, .bad_request));
                            continue;
                        };
                        const uri = data[4..uri_end];
                        switch (req_ctx.router.match(.GET, uri)) {
                            .found => |found| try self.dispatchMatchedRouteNoGil(req_ctx, ht, null, found),
                            .not_found => try self.send_q.push(makeErrorSend(ht.conn, .not_found)),
                            .method_not_allowed => {
                                var resp = response_mod.Response.init(.method_not_allowed);
                                resp.body = "Method Not Allowed";
                                try self.send_q.push(makeResponseSend(ht.conn, resp));
                            },
                        }
                        continue;
                    }
                }
            }

            var parsed = self.parseHandleRequestQueue(conn, ht) catch {
                try self.send_q.push(makeErrorSend(ht.conn, .bad_request));
                continue;
            };
            defer parsed.deinit(self.allocator);
            const req = parsed.req;
            switch (req_ctx.router.match(req.method orelse .GET, req.uri orelse "/")) {
                .found => |found| try self.dispatchMatchedRouteNoGil(req_ctx, ht, &req, found),
                .not_found => try self.send_q.push(makeErrorSend(ht.conn, .not_found)),
                .method_not_allowed => {
                    var resp = response_mod.Response.init(.method_not_allowed);
                    resp.body = "Method Not Allowed";
                    try self.send_q.push(makeResponseSend(ht.conn, resp));
                },
            }
        }
    }

    fn stageHandlePython(self: *Pipeline) !void {
        if (self.py_ready_q.len == 0) return;
        try self.drainPythonReady();
    }

    fn drainPythonReady(self: *Pipeline) !void {
        const req_ctx = self.req_ctx orelse return;
        const py_ctx = req_ctx.py_ctx orelse return;

        while (self.py_ready_q.len > 0) {
            const batch = self.py_ready_q.mutableSlice();
            const batch_len = self.py_ready_q.len;
            self.py_ready_q.len = 0;

            var invoke_metrics = driver.InvokeMetrics{};
            for (batch[0..batch_len]) |*task| {
                switch (task.*) {
                    .invoke => |*invoke| try self.runInvokeReadyTask(py_ctx, invoke, &invoke_metrics),
                    .redis_resume => |ready_task| try self.runRedisResumeReadyTask(py_ctx, ready_task),
                    .pg_resume => |ready_task| try self.runPgResumeReadyTask(py_ctx, ready_task),
                }
            }
            self.stats.accumInvokeMetrics(&invoke_metrics);
        }
    }

    fn runInvokeReadyTask(
        self: *Pipeline,
        py_ctx: *handler_mod.PyContext,
        task: *PythonHandleTask,
        invoke_metrics: *driver.InvokeMetrics,
    ) !void {
        const m = comptime metrics_mod.enabled;
        if (m) switch (task.kind) {
            .no_args => self.stats.py_no_args += 1,
            .params_only => self.stats.py_params_only += 1,
            .request => self.stats.py_request += 1,
        };
        const t_request_obj = if (m) instant() else {};
        const request_obj = self.buildPythonHandleRequestObject(task) catch {
            if (m) {
                self.stats.ns_py_request_obj += elapsedNs(t_request_obj);
            }
            try self.send_q.push(makeErrorSend(task.conn, .internal_server_error));
            return;
        };
        if (m) {
            self.stats.ns_py_request_obj += elapsedNs(t_request_obj);
        }
        defer ffi.xdecref(request_obj);

        const t_invoke = if (m) instant() else {};
        const result = try driver.invokePythonHandlerWithKnownFlags(
            py_ctx.py.necro_module,
            task.py_id,
            task.kind == .no_args,
            task.kind == .params_only,
            task.is_async,
            request_obj,
            task.params[0..task.param_count],
            self.redisSendSlice(),
            self.pgSendSlice(),
            self.pgStmtCache(),
            self.pgConnPrepared(),
            if (m) invoke_metrics else null,
        );
        if (m) {
            self.stats.ns_py_invoke_total += elapsedNs(t_invoke);
        }
        try self.handleResult(task.conn, result);
    }

    fn runRedisResumeReadyTask(
        self: *Pipeline,
        py_ctx: *handler_mod.PyContext,
        ready_task: RedisResumeReady,
    ) !void {
        defer ffi.decref(ready_task.result);
        const waiter = ready_task.waiter;
        defer ffi.decref(waiter.py_future);

        future_mod.setResult(waiter.py_future, ready_task.result) catch {
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
            return;
        };

        const send = ffi.iterSend(waiter.py_coro, ffi.none());
        switch (send.status) {
            .next => {
                const yielded = send.result.?;
                defer ffi.decref(yielded);
                const state = py_module.getState(py_ctx.py.necro_module) orelse {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                const yield = future_mod.consumeYield(
                    &state.future_types,
                    yielded,
                    waiter.py_coro,
                    self.redisSendSlice(),
                    self.pgSendSlice(),
                    self.pgStmtCache(),
                    self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro, ry.py_future);
                        self.redis_in_flight += 1;
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.py_future, pg_yield.mode, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse {
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                try self.send_q.push(makePythonSend(waiter.conn_idx, py_res));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
            },
        }
    }

    fn runPgResumeReadyTask(
        self: *Pipeline,
        py_ctx: *handler_mod.PyContext,
        ready_task: PgResumeReady,
    ) !void {
        defer ffi.decref(ready_task.result);
        defer ffi.xdecref(ready_task.waiter.model_cls);
        const waiter = ready_task.waiter;
        defer ffi.decref(waiter.py_future);

        future_mod.setResult(waiter.py_future, ready_task.result) catch {
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
            return;
        };

        const send = ffi.iterSend(waiter.py_coro, ffi.none());
        switch (send.status) {
            .next => {
                const yielded = send.result.?;
                defer ffi.decref(yielded);
                const state = py_module.getState(py_ctx.py.necro_module) orelse {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                const yield = future_mod.consumeYield(
                    &state.future_types,
                    yielded,
                    waiter.py_coro,
                    self.redisSendSlice(),
                    self.pgSendSlice(),
                    self.pgStmtCache(),
                    self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro, ry.py_future);
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.py_future, pg_yield.mode, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse {
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                try self.send_q.push(makePythonSend(waiter.conn_idx, py_res));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
            },
        }
    }

    fn buildPythonHandleRequestObject(_: *Pipeline, task: *PythonHandleTask) !?*ffi.PyObject {
        if (task.kind != .request) return null;

        var backing = task.request_backing orelse return error.MissingRequestBacking;
        task.request_backing = null;
        return necro_request.create(backing) catch {
            backing.deinit();
            return error.PythonError;
        };
    }

    fn instant() std.time.Instant {
        return std.time.Instant.now() catch |e| switch (e) {
            error.Unsupported => unreachable,
        };
    }

    fn elapsedNs(start_at: std.time.Instant) u64 {
        return instant().since(start_at);
    }

    fn dispatchMatchedRouteNoGil(
        self: *Pipeline,
        req_ctx: *const handler_mod.RequestContext,
        ht: HandleTask,
        parsed_req: ?*const http1.Request,
        found: anytype,
    ) !void {
        if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
            if (req_ctx.py_ctx == null) {
                try self.send_q.push(makeErrorSend(ht.conn, .service_unavailable));
                return;
            }
            const flags = if (req_ctx.py_handler_flags) |table| table[found.handler_id] else handler_mod.PyHandlerFlags{};
            if (flags.no_args) {
                try self.queuePythonHandle(ht.conn, py_id, .no_args, flags.is_async, &.{});
                return;
            }
            if (flags.needs_params) {
                try self.queuePythonHandle(ht.conn, py_id, .params_only, flags.is_async, found.params[0..found.param_count]);
                return;
            }
            try self.queuePythonHandle(ht.conn, py_id, .request, flags.is_async, found.params[0..found.param_count]);
            return;
        }

        if (req_ctx.handlers[found.handler_id]) |native| {
            var parsed_storage: ?ParsedHandleRequest = null;
            defer if (parsed_storage) |*parsed| parsed.deinit(self.allocator);
            const req = if (parsed_req) |req|
                req
            else blk: {
                parsed_storage = self.parseHandleRequestQueue(self.conns.get_ptr(ht.conn), ht) catch {
                    try self.send_q.push(makeErrorSend(ht.conn, .bad_request));
                    return;
                };
                break :blk &parsed_storage.?.req;
            };
            try self.send_q.push(makeResponseSend(ht.conn, native(req)));
            return;
        }

        try self.send_q.push(makeErrorSend(ht.conn, .internal_server_error));
    }

    fn queuePythonHandle(
        self: *Pipeline,
        conn_idx: u16,
        py_id: u32,
        kind: PythonHandleKind,
        is_async: bool,
        params: []const router_mod.PathParam,
    ) !void {
        var task = PythonHandleTask{
            .conn = conn_idx,
            .py_id = py_id,
            .kind = kind,
            .is_async = is_async,
        };
        errdefer if (task.request_backing) |*backing| backing.deinit();
        var stable_params = params;
        if (kind == .request) {
            const conn = self.conns.get_ptr(conn_idx);
            const lease = try self.request_pool.acquire();
            errdefer lease.release();
            const request_len = conn.inflight_request_len;
            if (request_len > lease.data.len) return error.BufferTooSmall;
            conn.recv_queue.copyInto(0, lease.data[0..request_len]);
            const parsed_req = try http1.Request.parse(lease.data[0..request_len]);
            if (params.len > 0) {
                if (self.req_ctx) |req_ctx| {
                    switch (req_ctx.router.match(parsed_req.method orelse .GET, parsed_req.uri orelse "/")) {
                        .found => |found| stable_params = found.params[0..found.param_count],
                        else => {},
                    }
                }
            }
            task.request_backing = try necro_request.Backing.fromParsed(lease, request_len, &parsed_req, stable_params);
        }
        task.param_count = copyPathParams(&task.params, stable_params);
        try self.py_ready_q.push(.{ .invoke = task });
    }

    fn parseHandleRequestQueue(self: *Pipeline, conn: *const Conn, ht: HandleTask) !ParsedHandleRequest {
        const request_end = std.math.add(usize, ht.header_end, ht.content_length) catch return error.MalformedRequest;
        if (request_end > conn.recv_queue.queuedBytes()) return error.MalformedRequest;
        if (conn.recv_queue.sliceIfContiguous(0, request_end)) |data| {
            return .{ .req = try http1.Request.parse(data) };
        }

        const bytes = try self.allocator.alloc(u8, request_end);
        errdefer self.allocator.free(bytes);
        conn.recv_queue.copyInto(0, bytes);
        return .{
            .req = try http1.Request.parse(bytes),
            .owned = bytes,
        };
    }

    fn copyPathParams(dst: *[8]router_mod.PathParam, src: []const router_mod.PathParam) u8 {
        std.debug.assert(src.len <= dst.len);
        for (src, 0..) |param, i| dst[i] = param;
        return @intCast(src.len);
    }

    /// Handle an InvokeResult: response goes to send_q, yields update send buffers + push waiters.
    fn handleResult(self: *Pipeline, conn: u16, result: driver.InvokeResult) !void {
        const m = comptime metrics_mod.enabled;
        const t_result = if (m) instant() else {};
        switch (result) {
            .native_response => |resp| {
                try self.send_q.push(makeResponseSend(conn, resp));
                if (m) {
                    const elapsed = elapsedNs(t_result);
                    self.stats.ns_py_result += elapsed;
                    self.stats.ns_py_result_response += elapsed;
                }
            },
            .py_result => |py_result| {
                try self.send_q.push(makePythonSend(conn, py_result));
                if (m) {
                    const elapsed = elapsedNs(t_result);
                    self.stats.ns_py_result += elapsed;
                    self.stats.ns_py_result_response += elapsed;
                }
            },
            .redis_yield => |ry| {
                self.redis_send_len += ry.bytes_written;
                try self.pushRedisWaiter(conn, ry.py_coro, ry.py_future);
                if (m) {
                    const elapsed = elapsedNs(t_result);
                    self.stats.ns_py_result += elapsed;
                    self.stats.ns_py_result_yield += elapsed;
                }
            },
            .pg_yield => |pg| {
                const pg_conn = &self.pg_conns[self.pg_last_conn];
                pg_conn.send_len += pg.bytes_written;
                errdefer ffi.xdecref(pg.model_cls);
                try pg_conn.pushWaiter(conn, pg.py_coro, pg.py_future, pg.mode, pg.stmt_idx, pg.model_cls);
                if (m) {
                    const elapsed = elapsedNs(t_result);
                    self.stats.ns_py_result += elapsed;
                    self.stats.ns_py_result_yield += elapsed;
                }
            },
        }
    }

    /// Remaining writable slice of the redis send buffer.
    fn redisSendSlice(self: *Pipeline) ?[]u8 {
        if (self.redis_fd == null) return null;
        if (self.redis_send_len >= self.redis_send_buf.len) return null;
        return self.redis_send_buf[self.redis_send_len..];
    }

    /// Pick the next PgConn round-robin and return its writable send slice.
    fn pgSendSlice(self: *Pipeline) ?[]u8 {
        if (self.pg_conn_count == 0) return null;
        const idx = self.pg_next_conn;
        self.pg_next_conn = (self.pg_next_conn + 1) % self.pg_conn_count;
        self.pg_last_conn = idx;
        const pg = &self.pg_conns[idx];
        if (pg.send_len >= pg.send_buf.len) return null;
        return pg.send_buf[pg.send_len..];
    }

    /// Statement cache for prepared statements.
    fn pgStmtCache(self: *Pipeline) ?*StmtCache {
        if (self.pg_conn_count == 0) return null;
        return &self.pg_stmt_cache;
    }

    /// Per-connection prepared statement bitset for the last selected connection.
    fn pgConnPrepared(self: *Pipeline) ?*[MAX_PG_STMTS]bool {
        if (self.pg_conn_count == 0) return null;
        return &self.pg_conns[self.pg_last_conn].prepared;
    }

    // ── Stage: Serialize + Send ───────────────────────────────────
    // Formats per-response headers, builds connection-owned send state,
    // then submits either sendv or sendmsg_zc.
    //
    // Each response is scattered across up to 4 iovecs:
    //   [0] status line       — static string ("HTTP/1.1 200 OK\r\n")
    //   [1] common headers    — cached per-second ("Server: necro\r\nDate: ...\r\n")
    //   [2] per-response hdrs — "Connection: keep-alive\r\nContent-Type: ...\r\nContent-Length: N\r\n\r\n"
    //   [3] body              — from conn.body_buf or static string

    fn stageSerializeAndSend(self: *Pipeline) !void {
        const common = http1.commonResponseHeaders();

        for (self.send_q.mutableSlice()) |*st| {
            const conn = self.conns.get_ptr(st.conn);
            if (conn.send_mode != .idle) {
                self.discardSendTask(st);
                try self.close_q.push(st.conn);
                continue;
            }

            var prepared = switch (st.source) {
                .native => |resp| py_send.Prepared.fromResponse(resp),
                .python => |py_result| blk: {
                    defer ffi.decref(py_result);
                    break :blk py_send.prepare(py_result, &conn.body_buf, &self.response_pool) catch {
                        if (ffi.errOccurred()) ffi.errPrint();
                        break :blk py_send.Prepared.fromResponse(response_mod.Response.init(.internal_server_error));
                    };
                },
            };
            defer prepared.deinit();

            try prepareConnSend(conn, &prepared, st.keep_alive, common);
            self.submitConnSend(conn) catch {
                conn.send_mode = .idle;
                conn.send_total_len = 0;
                conn.send_sent = 0;
                conn.send_iov_count = 0;
                if (!conn.zc_notif_pending) self.releaseConnSendBody(conn);
                conn.zc_hold = null;
                conn.zc_notif_pending = false;
                try self.close_q.push(st.conn);
            };
        }
    }

    fn prepareConnSend(
        conn: *Conn,
        prepared: *py_send.Prepared,
        keep_alive: bool,
        common: []const u8,
    ) error{UnsupportedStatus}!void {
        const use_zc = shouldUseSendMsgZc(conn, &prepared.response, keep_alive, common);

        conn.send_mode = if (use_zc) .sendmsg_zc else .sendv;
        conn.send_sent = 0;
        conn.send_body = prepared.response.body;
        if (conn.send_body_lease) |s| s.release();
        conn.send_body_py.deinit();
        conn.send_body_lease = prepared.body_slab;
        conn.send_body_py = prepared.py_body;
        prepared.body_slab = null;
        prepared.py_body = .{};
        conn.send_iov_count = 0;

        if (use_zc) {
            var hold = ZcHold{};
            hold.hdr_len = writeResponseHeaders(hold.hdr[0..], &prepared.response, keep_alive);
            conn.zc_hold = hold;
            conn.zc_notif_pending = true;
        } else {
            const hdr_len = writeResponseHeaders(conn.send_hdr[0..], &prepared.response, keep_alive);
            conn.send_iovecs[2] = .{ .base = conn.send_hdr[0..].ptr, .len = hdr_len };
            if (!conn.zc_notif_pending) conn.zc_hold = null;
        }

        const status_line = try statusLine(prepared.response.status);
        conn.send_iovecs[0] = .{ .base = status_line.ptr, .len = status_line.len };
        conn.send_iov_count += 1;
        conn.send_iovecs[1] = .{ .base = common.ptr, .len = common.len };
        conn.send_iov_count += 1;
        if (use_zc) {
            const hdr = conn.zc_hold.?.hdr[0..conn.zc_hold.?.hdr_len];
            conn.send_iovecs[2] = .{ .base = hdr.ptr, .len = hdr.len };
        }
        conn.send_iov_count += 1;
        if (prepared.response.body) |body| {
            conn.send_iovecs[3] = .{ .base = body.ptr, .len = body.len };
            conn.send_iov_count += 1;
        }

        conn.send_total_len = totalIovLen(conn.send_iovecs[0..conn.send_iov_count]);
        conn.send_msg = .{
            .name = null,
            .namelen = 0,
            .iov = conn.send_iovecs[0..conn.send_iov_count].ptr,
            .iovlen = conn.send_iov_count,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
    }

    fn shouldUseSendMsgZc(
        conn: *const Conn,
        response: *const response_mod.Response,
        keep_alive: bool,
        common: []const u8,
    ) bool {
        if (conn.zc_notif_pending) return false;
        const body = response.body orelse return false;
        if (bodyPointsIntoConn(conn, body)) return false;
        const status_line_len = (statusLine(response.status) catch return false).len;
        const total_len = status_line_len + common.len + estimateResponseHeaderLen(response, keep_alive) + body.len;
        return total_len >= HTTP_SEND_ZC_MIN_BYTES;
    }

    fn discardSendTask(_: *Pipeline, st: *SendTask) void {
        switch (st.source) {
            .native => {},
            .python => |py_result| ffi.decref(py_result),
        }
    }

    fn releaseConnSendBody(self: *Pipeline, conn: *Conn) void {
        if (conn.send_body_lease) |s| s.release();
        conn.send_body_lease = null;
        self.queuePyBodyRelease(&conn.send_body_py);
        conn.send_body = null;
    }

    fn queuePyBodyRelease(self: *Pipeline, hold: *PyBodyHold) void {
        if (hold.owner == null and hold.buffer == null) return;
        self.py_body_release.append(self.allocator, hold.*) catch {
            if (self.req_ctx) |ctx| {
                if (ctx.py_ctx) |py_ctx| {
                    py_ctx.py.acquireGil();
                    defer py_ctx.py.releaseGil();
                }
            }
            hold.deinit();
            return;
        };
        hold.* = .{};
    }

    fn drainPendingPyBodyReleases(self: *Pipeline) void {
        for (self.py_body_release.items) |*hold| hold.deinit();
        self.py_body_release.clearRetainingCapacity();
    }

    fn bodyPointsIntoConn(conn: *const Conn, body: []const u8) bool {
        const body_ptr = @intFromPtr(body.ptr);
        const conn_ptr = @intFromPtr(&conn.body_buf);
        const conn_end = conn_ptr + conn.body_buf.len;
        return body_ptr >= conn_ptr and body_ptr < conn_end;
    }

    fn totalIovLen(iovecs: []const posix.iovec_const) usize {
        var total: usize = 0;
        for (iovecs) |iov| total += iov.len;
        return total;
    }

    fn advanceIovecs(iovecs: *[MAX_IOVECS]posix.iovec_const, iov_count: *usize, advance: usize) void {
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

    // ── Redis IO ──────────────────────────────────────────────────
    // Redis completions arrive during classify. The state machine drives
    // send → recv transitions. RESP parsing + coroutine resumption happens
    // here with GIL held, pushing completed responses to send_q.

    /// IO state machine only — no Python work. Defers RESP parsing to stageRedis.
    pub fn onRedisSendIO(self: *Pipeline, completion: Completion) !void {
        if (completion.result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        const sent: usize = @intCast(completion.result);
        self.redis_send_offset += sent;
        if (self.redis_send_offset < self.redis_send_len) {
            try self.submitRedisSend();
            return;
        }
        // Send complete — compact and go idle
        self.redis_send_len = 0;
        self.redis_send_offset = 0;
        self.redis_send_state = .idle;
    }

    pub fn onRedisRecvIO(self: *Pipeline, completion: Completion) !void {
        if (completion.result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        self.redis_recv_len += @intCast(completion.result);
        self.redis_recv_state = .parsing;
    }

    /// Process redis: parse RESP responses + flush pending sends.
    /// Full-duplex: send and receive operate independently.
    /// GIL is already held from stageHandle.
    fn stageRedis(self: *Pipeline) !void {
        if (self.redis_fd == null) return;

        // 1. Handle deferred errors
        if (self.redis_recv_state == .err) {
            try self.failRedisWaiters();
        }

        // 2. Parse RESP responses
        if (self.redis_recv_state == .parsing) {
            try self.parseRedisResponses();

            if (self.redis_in_flight > 0) {
                self.compactRedisRecv();
                self.redis_recv_state = .receiving;
                try self.submitRedisRecv();
            } else {
                self.redis_recv_state = .idle;
            }
        }

        // 3. Flush pending sends (independent of recv state)
        const new_queries = self.redis_waiter_count - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try self.submitRedisSend();
            // Arm recv if not already receiving
            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .receiving;
                try self.submitRedisRecv();
            }
        }
    }

    fn parseRedisResponses(self: *Pipeline) !void {
        while (self.redis_in_flight > 0 and self.redis_waiter_count > 0) {
            if (!try self.parseOneResp()) break; // incomplete
        }
    }

    /// Parse one RESP response and resume the head waiter's coroutine.
    fn parseOneResp(self: *Pipeline) !bool {
        const data = self.redis_recv_buf[self.redis_parse_pos..self.redis_recv_len];
        if (data.len == 0) return false;

        const crlf_pos = std.mem.indexOf(u8, data, "\r\n") orelse return false;
        const type_byte = data[0];
        const line = data[1..crlf_pos];

        const py_result: *ffi.PyObject = switch (type_byte) {
            '+' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                break :blk ffi.unicodeFromSlice(line.ptr, line.len) catch return false;
            },
            '-' => {
                self.redis_parse_pos += crlf_pos + 2;
                // Set Python exception, resume waiter with error
                var err_buf: [256:0]u8 = undefined;
                if (line.len < err_buf.len) {
                    @memcpy(err_buf[0..line.len], line);
                    err_buf[line.len] = 0;
                    c.PyErr_SetString(c.PyExc_RuntimeError, err_buf[0..line.len :0]);
                }
                try self.failHeadWaiter();
                self.redis_in_flight -= 1;
                return true;
            },
            ':' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                const val = std.fmt.parseInt(i64, line, 10) catch return false;
                break :blk ffi.longFromLong(val) catch return false;
            },
            '_' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                break :blk ffi.getNone();
            },
            '$' => blk: {
                const len_val = std.fmt.parseInt(i64, line, 10) catch return false;
                if (len_val < 0) {
                    self.redis_parse_pos += crlf_pos + 2;
                    break :blk ffi.getNone();
                }
                const payload_len: usize = @intCast(len_val);
                const total_needed = crlf_pos + 2 + payload_len + 2;
                if (data.len < total_needed) return false; // incomplete
                // Allocate PyBytes, copy payload
                const py_bytes = c.PyBytes_FromStringAndSize(null, @intCast(payload_len)) orelse return false;
                const dest: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(py_bytes));
                @memcpy(dest[0..payload_len], data[crlf_pos + 2 ..][0..payload_len]);
                self.redis_parse_pos += total_needed;
                break :blk py_bytes;
            },
            else => return false,
        };

        // Queue head waiter for Python resumption under the shared ready drain.
        const waiter = self.popRedisWaiter() orelse {
            ffi.decref(py_result);
            return true;
        };
        errdefer ffi.decref(py_result);
        try self.py_ready_q.push(.{
            .redis_resume = .{
                .waiter = waiter,
                .result = py_result,
            },
        });
        self.redis_in_flight -= 1;
        return true;
    }

    fn failHeadWaiter(self: *Pipeline) !void {
        const waiter = self.popRedisWaiter() orelse return;
        ffi.decref(waiter.py_future);
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(makeErrorSend(waiter.conn_idx, .internal_server_error));
    }

    fn failRedisWaiters(self: *Pipeline) !void {
        while (self.redis_waiter_count > 0) {
            try self.failHeadWaiter();
        }
        self.redis_recv_state = .idle;
        self.redis_send_state = .idle;
        self.redis_in_flight = 0;
    }

    fn pushRedisWaiter(self: *Pipeline, conn_idx: u16, py_coro: *ffi.PyObject, py_future: *ffi.PyObject) !void {
        if (self.redis_waiter_count >= MAX_BATCH) return error.WaiterQueueFull;
        self.redis_waiters[self.redis_waiter_tail] = .{ .conn_idx = conn_idx, .py_coro = py_coro, .py_future = py_future };
        self.redis_waiter_tail = (self.redis_waiter_tail + 1) % MAX_BATCH;
        self.redis_waiter_count += 1;
    }

    fn popRedisWaiter(self: *Pipeline) ?RedisWaiter {
        if (self.redis_waiter_count == 0) return null;
        const w = self.redis_waiters[self.redis_waiter_head];
        self.redis_waiter_head = (self.redis_waiter_head + 1) % MAX_BATCH;
        self.redis_waiter_count -= 1;
        return w;
    }

    fn compactRedisRecv(self: *Pipeline) void {
        if (self.redis_parse_pos > 0) {
            const remaining = self.redis_recv_len - self.redis_parse_pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.redis_recv_buf[0..remaining], self.redis_recv_buf[self.redis_parse_pos..self.redis_recv_len]);
            }
            self.redis_recv_len = remaining;
            self.redis_parse_pos = 0;
        }
    }

    pub fn initRedis(self: *Pipeline, fd: posix.socket_t) void {
        self.redis_fd = fd;
        self.redis_send_token = .{ .tag = .redis_send };
        self.redis_recv_token = .{ .tag = .redis_recv };
        log.info("redis connected fd={d}", .{fd});
    }

    // ── Postgres IO ──────────────────────────────────────────────
    // Mirrors redis: IO state machine (GIL-free), parsing + coroutine
    // resumption in stagePostgres (under GIL).

    fn cqeErrno(result: i32) ?posix.E {
        if (result >= 0) return null;
        return @enumFromInt(@as(u16, @intCast(-result)));
    }

    fn markPgFatal(pg: *PgConn, status: std.http.Status, body: ?[]const u8) void {
        pg.recv_state = .err;
        pg.recv_armed = false;
        pg.fail_status = status;
        pg.fail_body = body;
    }

    pub fn onPgSendIO(_: *Pipeline, pg: *PgConn, completion: Completion) !void {
        if (completion.result <= 0) {
            markPgFatal(pg, .internal_server_error, null);
            return;
        }
        const sent: usize = @intCast(completion.result);
        pg.send_offset += sent;
        if (pg.send_offset < pg.send_len) {
            return; // partial send — will be re-submitted by stagePostgres
        }
        pg.send_len = 0;
        pg.send_offset = 0;
        pg.send_state = .idle;
    }

    pub fn onPgRecvIO(self: *Pipeline, pg: *PgConn, completion: Completion) !void {
        if (completion.result == 0) {
            markPgFatal(pg, .internal_server_error, null);
            return;
        }
        if (completion.result < 0) {
            pg.recv_armed = completion.more;
            if (cqeErrno(completion.result) == .NOBUFS) {
                pg.recv_state = if (pg.recv_queue.queuedBytes() > 0) .parsing else .idle;
                return;
            }
            markPgFatal(pg, .internal_server_error, null);
            return;
        }

        const lease = self.pg_recv_group.take(completion) catch {
            markPgFatal(pg, .internal_server_error, "Postgres recv completion missing or corrupt buffer metadata");
            return;
        };
        pg.recv_queue.append(&self.pg_recv_group, lease) catch |err| {
            switch (err) {
                error.TransportQueueFull, error.TransportSegmentQueueFull => {
                    markPgFatal(pg, .internal_server_error, "Postgres receive queue exhausted");
                    return;
                },
            }
        };

        const received: usize = @intCast(completion.result);
        pg.recv_armed = completion.more;
        pg.recv_state = .parsing;
        self.stats.pg_recv_ops += 1;
        self.stats.pg_recv_bytes += received;
    }

    /// Process postgres: parse responses + flush pending sends for all connections.
    /// GIL is already held from stageHandle.
    fn stagePostgres(self: *Pipeline) !void {
        self.pg_wire_ns = 0;
        if (self.pg_conn_count == 0) return;

        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            // 1. Handle deferred errors
            if (pg.recv_state == .err) {
                try self.failPgConnWaitersWithStatus(pg, pg.fail_status, pg.fail_body);
            }

            // 2. Parse responses
            if (pg.recv_state == .parsing) {
                const t0 = if (comptime metrics_mod.enabled) instant() else {};
                try self.parsePgConnResponses(pg);
                if (comptime metrics_mod.enabled) {
                    self.pg_wire_ns += instant().since(t0);
                }
                _ = pg.recv_queue.consumeParsed(&self.pg_recv_group);

                if (pg.recv_state == .err) {
                    try self.failPgConnWaitersWithStatus(pg, pg.fail_status, pg.fail_body);
                    continue;
                }

                pg.recv_state = .idle;
                if (pg.in_flight > 0 and !pg.recv_armed) try self.submitPgRecv(pg);
            }

            // 3. Flush pending sends — append single Sync for entire batch
            const new_queries = pg.waiter_count - pg.in_flight;
            if (new_queries > 0 and pg.send_state == .idle and pg.send_len > 0) {
                const wire_mod = @import("../../db/wire.zig");
                const sync = wire_mod.encodeSync(pg.send_buf[pg.send_len..]);
                pg.send_len += sync.len;
                pg.in_flight += new_queries;
                try pg.pushBatch(new_queries);
                pg.send_state = .sending;
                try self.submitPgSend(pg);
                if (!pg.recv_armed) try self.submitPgRecv(pg);
            }

            // 4. Re-submit partial sends
            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try self.submitPgSend(pg);
            }
        }
    }

    /// Parse PG responses from a batched Sync. Queries complete on CommandComplete
    /// (not ReadyForQuery). Results are collected first, then all coroutines are
    /// resumed together after parsing to avoid cascading re-yields.
    ///
    /// With batched Sync: N × (BindComplete + DataRow* + CommandComplete) + ReadyForQuery.
    /// ReadyForQuery may arrive in a later recv — we don't wait for it.
    fn wrapPgRowResult(waiter: PgWaiter, result_obj: *ffi.PyObject) ffi.PythonError!*ffi.PyObject {
        if (waiter.model_cls) |model_cls| {
            if (row.isRow(result_obj)) {
                errdefer ffi.decref(result_obj);
                const model_obj = try ffi.callMethodOneArg(model_cls, "_necro_from_row", result_obj);
                ffi.decref(result_obj);
                return model_obj;
            }
        }
        return result_obj;
    }

    fn parsePgConnResponses(self: *Pipeline, pg: *PgConn) !void {
        const wire = @import("../../db/wire.zig");

        // Collected completed query results — resumed after parse loop
        const CompletedQuery = struct { waiter: PgWaiter, result: *ffi.PyObject };
        var completed: [PG_WAITER_CAP]CompletedQuery = undefined;
        var completed_count: usize = 0;

        // Per-query accumulation state
        var py_result: ?*ffi.PyObject = null;
        var py_list: ?*ffi.PyObject = null;
        // Save position at the start of current query (not entire batch)
        var query_save_pos = pg.recv_queue.parseOffset();

        while (pg.peekWaiter()) |waiter| {
            const message = pg_stream.nextMessage(&pg.recv_queue, pg.recv_queue.parseOffset()) catch |err| switch (err) {
                error.MessageTooLarge => {
                    if (py_result) |r| ffi.decref(r);
                    if (py_list) |l| ffi.decref(l);
                    try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres message exceeds receive queue capacity");
                    return;
                },
                else => return err,
            };
            if (message == null) {
                // Incomplete mid-query — rollback current query only
                pg.recv_queue.setParseOffset(query_save_pos);
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const msg = message.?;
            pg.recv_queue.setParseOffset(pg.recv_queue.parseOffset() + msg.total_len);

            // ReadyForQuery is a batch-level message, not per-query
            if (msg.header.tag == wire.BackendTag.ready_for_query) {
                query_save_pos = pg.recv_queue.parseOffset();
                continue; // consume it, don't break — there may be more batches
            }

            const stmt_entry = self.pg_stmt_cache.get(waiter.stmt_idx);
            const col_count: u16 = if (stmt_entry.described) stmt_entry.col_count else 0;

            switch (msg.header.tag) {
                wire.BackendTag.parse_complete, wire.BackendTag.bind_complete => continue,
                wire.BackendTag.no_data => {
                    if (!stmt_entry.described) {
                        stmt_entry.col_count = 0;
                        stmt_entry.described = true;
                    }
                    continue;
                },
                wire.BackendTag.row_description => {
                    _ = pg_stream.applyRowDescription(self.allocator, &pg.recv_queue, msg.payload_off, msg.payload_len, stmt_entry) catch |err| switch (err) {
                        error.ProtocolViolation => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres protocol violation");
                            return;
                        },
                        else => return err,
                    };
                },
                wire.BackendTag.data_row => {
                    const raw_result = pg_stream.materializeDataRow(
                        self.allocator,
                        &pg.recv_queue,
                        msg.payload_off,
                        msg.payload_len,
                        &self.pg_stmt_cache,
                        waiter.stmt_idx,
                        stmt_entry,
                        col_count,
                        &self.pg_result_pool,
                    ) catch |err| switch (err) {
                        error.ProtocolViolation => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres protocol violation");
                            return;
                        },
                        error.MessageTooLarge, error.RowTooLarge => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres row exceeds receive/result capacity");
                            return;
                        },
                        else => return err,
                    };
                    const result_obj = try wrapPgRowResult(waiter, raw_result);

                    if (waiter.mode == .fetch_one) {
                        if (py_result == null) py_result = result_obj else ffi.decref(result_obj);
                    } else if (waiter.mode == .fetch_all) {
                        if (py_list == null) py_list = c.PyList_New(0) orelse return error.PythonError;
                        if (c.PyList_Append(py_list.?, result_obj) != 0) return error.PythonError;
                        ffi.decref(result_obj);
                    } else {
                        ffi.decref(result_obj);
                    }
                },
                wire.BackendTag.command_complete => {
                    if (waiter.mode == .execute) {
                        const count = pg_stream.parseCommandCompleteCount(&pg.recv_queue, msg.payload_off, msg.payload_len);
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (waiter.mode == .fetch_all)
                        py_list orelse (c.PyList_New(0) orelse return error.PythonError)
                    else
                        py_result orelse ffi.getNone();

                    completed[completed_count] = .{ .waiter = waiter, .result = final_result };
                    completed_count += 1;
                    _ = pg.popWaiter();
                    pg.in_flight -= 1;
                    try pg.completeBatchQuery();
                    py_result = null;
                    py_list = null;
                    query_save_pos = pg.recv_queue.parseOffset(); // this query is fully parsed
                },
                wire.BackendTag.error_response => {
                    if (py_list) |l| ffi.decref(l);
                    if (py_result) |r| ffi.decref(r);
                    py_list = null;
                    py_result = null;

                    const failed_in_batch = pg.currentBatchRemaining();
                    if (failed_in_batch == 0 or pg.popBatch() == null) {
                        for (completed[0..completed_count]) |cq| {
                            ffi.decref(cq.result);
                            ffi.decref(cq.waiter.py_future);
                            ffi.xdecref(cq.waiter.model_cls);
                            ffi.coroutineClose(cq.waiter.py_coro);
                            ffi.decref(cq.waiter.py_coro);
                            try self.send_q.push(makeErrorSend(cq.waiter.conn_idx, .internal_server_error));
                        }
                        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                        return;
                    }

                    for (0..failed_in_batch) |_| {
                        const failed_waiter = pg.popWaiter() orelse {
                            for (completed[0..completed_count]) |cq| {
                                ffi.decref(cq.result);
                                ffi.decref(cq.waiter.py_future);
                                ffi.xdecref(cq.waiter.model_cls);
                                ffi.coroutineClose(cq.waiter.py_coro);
                                ffi.decref(cq.waiter.py_coro);
                                try self.send_q.push(makeErrorSend(cq.waiter.conn_idx, .internal_server_error));
                            }
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                            return;
                        };
                        ffi.decref(failed_waiter.py_future);
                        ffi.xdecref(failed_waiter.model_cls);
                        ffi.coroutineClose(failed_waiter.py_coro);
                        ffi.decref(failed_waiter.py_coro);
                        try self.send_q.push(makeErrorSend(failed_waiter.conn_idx, .internal_server_error));
                        pg.in_flight -= 1;
                    }

                    query_save_pos = pg.recv_queue.parseOffset();

                    for (completed[0..completed_count]) |cq| {
                        errdefer ffi.decref(cq.result);
                        errdefer ffi.decref(cq.waiter.py_future);
                        errdefer ffi.xdecref(cq.waiter.model_cls);
                        try self.py_ready_q.push(.{
                            .pg_resume = .{
                                .waiter = cq.waiter,
                                .result = cq.result,
                            },
                        });
                    }
                    completed_count = 0;
                },
                else => continue,
            }
        }

        // Queue completed queries after parsing to keep completion batching cheap.
        for (completed[0..completed_count]) |cq| {
            errdefer ffi.decref(cq.result);
            errdefer ffi.decref(cq.waiter.py_future);
            errdefer ffi.xdecref(cq.waiter.model_cls);
            try self.py_ready_q.push(.{
                .pg_resume = .{
                    .waiter = cq.waiter,
                    .result = cq.result,
                },
            });
        }
    }

    fn failPgConnWaitersWithStatus(self: *Pipeline, pg: *PgConn, status: std.http.Status, body: ?[]const u8) !void {
        while (pg.waiter_count > 0) {
            const waiter = pg.popWaiter() orelse break;
            ffi.decref(waiter.py_future);
            ffi.xdecref(waiter.model_cls);
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            if (body) |msg| {
                var resp = response_mod.Response.init(status);
                _ = resp.setContentType("text/plain");
                _ = resp.setBody(msg);
                try self.send_q.push(makeResponseSend(waiter.conn_idx, resp));
            } else {
                try self.send_q.push(makeErrorSend(waiter.conn_idx, status));
            }
        }
        pg.recv_state = .idle;
        pg.recv_armed = false;
        pg.send_state = .idle;
        pg.in_flight = 0;
        pg.fail_status = .internal_server_error;
        pg.fail_body = null;
        pg.recv_queue.clear(&self.pg_recv_group);
        pg.clearBatches();
    }

    fn anyPgNeedsGil(self: *Pipeline) bool {
        for (self.pg_conns[0..self.pg_conn_count]) |pg| {
            if (pg.recv_state == .parsing or pg.recv_state == .err) return true;
        }
        return false;
    }

    fn totalPgWaiters(self: *Pipeline) usize {
        var total: usize = 0;
        for (self.pg_conns[0..self.pg_conn_count]) |pg| {
            total += pg.waiter_count;
        }
        return total;
    }

    pub fn addPgConn(self: *Pipeline, fd: posix.socket_t) !void {
        if (self.pg_conn_count >= MAX_PG_CONNS) return error.TooManyPgConns;
        const idx = self.pg_conn_count;
        self.pg_conns[idx] = .{};
        self.pg_conns[idx].fd = fd;
        self.pg_conns[idx].send_token = .{ .tag = .pg_send };
        self.pg_conns[idx].recv_token = .{ .tag = .pg_recv };
        self.pg_conn_count += 1;
        log.info("postgres pool: connection {d} fd={d}", .{ idx, fd });
    }

    fn handleCompletion(self: *Pipeline, token_ptr: *anyopaque, completion: Completion) !void {
        const token: *Token = @ptrCast(@alignCast(token_ptr));
        switch (token.tag) {
            .accept => {
                if (completion.result >= 0) self.onAccept(completion);
                if (!completion.more) {
                    self.accept_armed = false;
                    try self.armAccept();
                }
            },
            .conn_recv => try self.onConnRecvCompletion(token, completion),
            .conn_send => try self.onConnSendCompletion(token, completion),
            .redis_send => try self.onRedisSendIO(completion),
            .redis_recv => try self.onRedisRecvIO(completion),
            .pg_send => try self.onPgSendIO(@fieldParentPtr("send_token", token), completion),
            .pg_recv => try self.onPgRecvIO(@fieldParentPtr("recv_token", token), completion),
        }
    }

    fn armAccept(self: *Pipeline) !void {
        if (self.accept_armed) return;
        try self.backend.queue(&self.accept_token, .{
            .accept_multishot = .{ .socket = self.listen_fd },
        });
        self.accept_armed = true;
    }

    fn submitConnRecv(self: *Pipeline, conn: *Conn) !void {
        try self.backend.queue(&conn.recv_token, .{
            .recv_multishot = .{
                .socket = conn.fd,
                .buffer_group = self.http_recv_group.groupId(),
            },
        });
        conn.recv_armed = true;
    }

    fn submitConnSend(self: *Pipeline, conn: *Conn) !void {
        switch (conn.send_mode) {
            .idle => return,
            .sendv => try self.backend.queue(&conn.send_token, .{
                .sendv = .{
                    .socket = conn.fd,
                    .iovecs = conn.send_iovecs[0..conn.send_iov_count],
                },
            }),
            .sendmsg_zc => try self.backend.queue(&conn.send_token, .{
                .sendmsg_zc = .{
                    .socket = conn.fd,
                    .msg = &conn.send_msg,
                },
            }),
        }
    }

    fn submitRedisSend(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        try self.backend.queue(&self.redis_send_token, .{
            .send = .{
                .socket = fd,
                .buffer = self.redis_send_buf[self.redis_send_offset..self.redis_send_len],
            },
        });
    }

    fn submitRedisRecv(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        try self.backend.queue(&self.redis_recv_token, .{
            .recv = .{
                .socket = fd,
                .buffer = self.redis_recv_buf[self.redis_recv_len..],
            },
        });
    }

    fn submitPgSend(self: *Pipeline, pg: *PgConn) !void {
        try self.backend.queue(&pg.send_token, .{
            .send = .{
                .socket = pg.fd,
                .buffer = pg.send_buf[pg.send_offset..pg.send_len],
            },
        });
    }

    fn submitPgRecv(self: *Pipeline, pg: *PgConn) !void {
        try self.backend.queue(&pg.recv_token, .{
            .recv_multishot = .{
                .socket = pg.fd,
                .buffer_group = self.pg_recv_group.groupId(),
            },
        });
        pg.recv_armed = true;
    }

    // ── Close ─────────────────────────────────────────────────────

    fn stageClose(self: *Pipeline) void {
        for (self.close_q.slice()) |index| {
            const conn = self.conns.get_ptr(index);
            if (conn.zc_notif_pending) {
                conn.recv_queue.clear(&self.http_recv_group);
                conn.recv_armed = false;
                conn.parse_queued = false;
                conn.inflight_request_len = 0;
                conn.head_parser = .{};
                conn.head_fed = 0;
                conn.send_mode = .idle;
                conn.send_total_len = 0;
                conn.send_sent = 0;
                conn.send_iov_count = 0;
                if (!conn.zc_notif_pending) self.releaseConnSendBody(conn);
                if (conn.fd >= 0) posix.close(conn.fd);
                conn.fd = -1;
                conn.close_after_notif = true;
                continue;
            }
            conn.recv_queue.clear(&self.http_recv_group);
            conn.recv_armed = false;
            conn.parse_queued = false;
            conn.inflight_request_len = 0;
            conn.head_parser = .{};
            conn.head_fed = 0;
            self.releaseConnSendBody(conn);
            posix.close(conn.fd);
            self.conns.release(index);
        }
    }
};

/// SIMD batch screen: compare N bytes against a target byte.
/// Writes true/false into `out` for each match.
/// Uses vectorized comparison when available (NEON: 16 lanes, AVX2: 32 lanes).
fn simdScreenBytes(bytes: []const u8, target: u8, out: []bool) void {
    const V = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const splat: @Vector(V, u8) = @splat(target);
    var i: usize = 0;

    while (i + V <= bytes.len) : (i += V) {
        const v: @Vector(V, u8) = bytes[i..][0..V].*;
        const mask = v == splat;
        inline for (0..V) |j| {
            out[i + j] = mask[j];
        }
    }
    // Scalar remainder
    while (i < bytes.len) : (i += 1) {
        out[i] = bytes[i] == target;
    }
}

fn quickContentLengthQueue(queue: *const UringRecvQueue, header_end: usize) usize {
    if (header_end < 4) return 0;
    switch (queue.byteAt(0)) {
        'G', 'H', 'D', 'O' => return 0,
        else => {},
    }

    const needle = "Content-Length: ";
    var i: usize = 0;
    while (i + needle.len <= header_end) : (i += 1) {
        var matched = true;
        for (needle, 0..) |ch, off| {
            if (queue.byteAt(i + off) != ch) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;

        const start = i + needle.len;
        var end = start;
        while (end < header_end) : (end += 1) {
            const ch = queue.byteAt(end);
            if (ch < '0' or ch > '9') break;
        }
        if (end == start) return 0;

        var tmp: [32]u8 = undefined;
        const len = end - start;
        if (len > tmp.len) return 0;
        queue.copyInto(start, tmp[0..len]);
        return std.fmt.parseInt(usize, tmp[0..len], 10) catch 0;
    }
    return 0;
}

const ParsedHandleRequest = struct {
    req: http1.Request,
    owned: ?[]u8 = null,

    fn deinit(self: *ParsedHandleRequest, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

// ── Send Constructors ─────────────────────────────────────────────

fn statusLine(status: std.http.Status) error{UnsupportedStatus}![]const u8 {
    return switch (status) {
        .ok => "HTTP/1.1 200 OK\r\n",
        .created => "HTTP/1.1 201 Created\r\n",
        .no_content => "HTTP/1.1 204 No Content\r\n",
        .moved_permanently => "HTTP/1.1 301 Moved Permanently\r\n",
        .found => "HTTP/1.1 302 Found\r\n",
        .not_modified => "HTTP/1.1 304 Not Modified\r\n",
        .bad_request => "HTTP/1.1 400 Bad Request\r\n",
        .unauthorized => "HTTP/1.1 401 Unauthorized\r\n",
        .forbidden => "HTTP/1.1 403 Forbidden\r\n",
        .not_found => "HTTP/1.1 404 Not Found\r\n",
        .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\n",
        .payload_too_large => "HTTP/1.1 413 Content Too Large\r\n",
        .teapot => "HTTP/1.1 418 I'm a Teapot\r\n",
        .too_many_requests => "HTTP/1.1 429 Too Many Requests\r\n",
        .internal_server_error => "HTTP/1.1 500 Internal Server Error\r\n",
        .bad_gateway => "HTTP/1.1 502 Bad Gateway\r\n",
        .service_unavailable => "HTTP/1.1 503 Service Unavailable\r\n",
        .gateway_timeout => "HTTP/1.1 504 Gateway Timeout\r\n",
        else => return error.UnsupportedStatus,
    };
}

/// Build a SendTask from a Response object.
fn makeResponseSend(conn_idx: u16, resp: response_mod.Response) SendTask {
    return .{
        .conn = conn_idx,
        .source = .{ .native = resp },
        .keep_alive = true,
    };
}

fn makeErrorSend(conn_idx: u16, status: std.http.Status) SendTask {
    return .{
        .conn = conn_idx,
        .source = .{ .native = response_mod.Response.init(status) },
        .keep_alive = false,
    };
}

fn makePythonSend(conn_idx: u16, py_result: *ffi.PyObject) SendTask {
    return .{
        .conn = conn_idx,
        .source = .{ .python = py_result },
        .keep_alive = true,
    };
}

/// Format per-response headers directly into the provided connection-owned
/// header buffer:
///   Connection: keep-alive\r\n
///   Content-Type: ...\r\n    (from handler)
///   Content-Length: N\r\n
///   \r\n
fn writeResponseHeaders(dst: []u8, resp: *const response_mod.Response, keep_alive: bool) usize {
    var pos: usize = 0;

    const conn_hdr = if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";
    @memcpy(dst[pos..][0..conn_hdr.len], conn_hdr);
    pos += conn_hdr.len;

    // User headers from the Response
    for (resp.headers[0..resp.header_count]) |h| {
        const needed = h.name.len + 2 + h.value.len + 2;
        if (pos + needed > dst.len) break;
        @memcpy(dst[pos..][0..h.name.len], h.name);
        pos += h.name.len;
        dst[pos] = ':';
        dst[pos + 1] = ' ';
        pos += 2;
        @memcpy(dst[pos..][0..h.value.len], h.value);
        pos += h.value.len;
        dst[pos] = '\r';
        dst[pos + 1] = '\n';
        pos += 2;
    }

    // Content-Length
    const body_len = if (resp.body) |b| b.len else 0;
    {
        const cl = "Content-Length: ";
        @memcpy(dst[pos..][0..cl.len], cl);
        pos += cl.len;
        const len_str = std.fmt.bufPrint(dst[pos..], "{d}", .{body_len}) catch return pos;
        pos += len_str.len;
        dst[pos] = '\r';
        dst[pos + 1] = '\n';
        pos += 2;
    }

    // End of headers
    dst[pos] = '\r';
    dst[pos + 1] = '\n';
    pos += 2;
    return pos;
}

fn estimateResponseHeaderLen(resp: *const response_mod.Response, keep_alive: bool) usize {
    var total: usize = if (keep_alive) "Connection: keep-alive\r\n".len else "Connection: close\r\n".len;
    for (resp.headers[0..resp.header_count]) |h| {
        total += h.name.len + 2 + h.value.len + 2;
    }
    const body_len = if (resp.body) |b| b.len else 0;
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch "";
    total += "Content-Length: ".len + len_str.len + 4;
    return total;
}

// ── Tests ─────────────────────────────────────────────────────────

test "HeadParser finds header end" {
    var p: std.http.HeadParser = .{};
    const data = "GET / HTTP/1.1\r\nHost: h\r\n\r\nbody";
    const consumed = p.feed(data);
    try std.testing.expectEqual(std.http.HeadParser.State.finished, p.state);
    try std.testing.expectEqualStrings("body", data[consumed..]);
}

test "HeadParser streaming" {
    var p: std.http.HeadParser = .{};
    _ = p.feed("GET / HTTP/1.1\r\nHost: h\r\n\r");
    try std.testing.expect(p.state != .finished);
    _ = p.feed("\nbody");
    try std.testing.expectEqual(std.http.HeadParser.State.finished, p.state);
}

test "simdScreenBytes classifies GET" {
    const input = "GGPGDGOH";
    var out: [8]bool = undefined;
    simdScreenBytes(input, 'G', &out);
    try std.testing.expect(out[0]); // G
    try std.testing.expect(out[1]); // G
    try std.testing.expect(!out[2]); // P
    try std.testing.expect(out[3]); // G
    try std.testing.expect(!out[4]); // D
    try std.testing.expect(out[5]); // G
    try std.testing.expect(!out[6]); // O
    try std.testing.expect(!out[7]); // H
}

test "Queue typed" {
    var q: Queue(HandleTask) = .{};
    try q.push(.{ .conn = 1, .header_end = 100, .content_length = 0 });
    try q.push(.{ .conn = 5, .header_end = 200, .content_length = 42 });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(u16, 1), q.slice()[0].conn);
}
