//! Staged event-driven pipeline.
//!
//! Connections are pure data (fd + recv buffer). Each stage defines its own
//! typed task. The stage processor IS the state machine.
//!
//! DAG:
//!   [kernel recv] → ParseTask → HandleTask ─┬→ SendTask → [kernel sendv] → recv
//!                                            └→ RedisTask ··· → SendTask
//!
//! sendv scatter-gathers the shared HTTP response prefix + per-response headers + body.

const std = @import("std");
const posix = std.posix;
const kqueue = @import("sys.zig");
const Completion = kqueue.Completion;
const Pool = @import("../../pool.zig").Pool;
const ZeroCopy = @import("../../zero_copy.zig").ZeroCopy;
const http1 = @import("../../http/parser.zig");
const handler_mod = @import("../../handler.zig");
const driver = @import("../../py/driver.zig");
const ffi = @import("../../py/ffi.zig");
const c = ffi.c;
const module = @import("../../py/module.zig");
const router_mod = @import("../../http/router.zig");
const response_mod = @import("../../http/response.zig");
const stmt_cache_mod = @import("../../db/stmt.zig");
const StmtCache = stmt_cache_mod.Cache;
const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;
const pg_stream = @import("../../db/pg_stream.zig");
const slab_mod = @import("../../db/slab.zig");
const SlabPool = slab_mod.SlabPool;
const ring_mod = @import("ring.zig");
const RecvPool = ring_mod.RecvPool;
const Ring = ring_mod.Ring;
const dispatch = @import("dispatch.zig");
const row = @import("../../db/row.zig");

const log = std.log.scoped(.@"necro/pipeline");

const MAX_BATCH = 1024;
const MAX_IOVECS = 4; // status | common | per-response | body
const RECV_BUFFER_COUNT = 64;
const RESULT_SLAB_CACHE = 128;
const RESULT_SLAB_MAX_LIVE = 1024;

// ── Connection — pure data ────────────────────────────────────────

pub const Token = struct {
    _align: usize = 0,
    tag: Tag = .conn,

    pub const Tag = enum(u8) {
        conn,
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
    zc: ZeroCopy(u8) = undefined,
    recv_slice: []u8 = &.{},
    initialized: bool = false,

    // Streaming SIMD header parser from stdlib
    head_parser: std.http.HeadParser = .{},
    head_fed: usize = 0,

    // Body buffer — Python response body is copied here.
    // Lives until send completes. Eliminates resp_buf[8192].
    body_buf: [4096]u8 = undefined,

    // Embedded token for backend user_data round-trip.
    // The pipeline recovers Conn via @fieldParentPtr.
    token: Token = .{},

    pub fn ensureInit(self: *Conn, allocator: std.mem.Allocator) !void {
        if (!self.initialized) {
            self.zc = try ZeroCopy(u8).init(allocator, 4096);
            self.initialized = true;
        }
    }

    pub fn resetRecv(self: *Conn) void {
        self.zc.clear_retaining_capacity();
        self.head_parser = .{};
        self.head_fed = 0;
        self.recv_slice = self.zc.get_write_area(4096) catch &.{};
    }
};

// ── Typed tasks ───────────────────────────────────────────────────

pub const ParseTask = struct { conn: u16 };

pub const HandleTask = struct {
    conn: u16,
    header_end: usize,
    content_length: usize,
};

pub const SendTask = struct {
    conn: u16,
    // Per-response header fragment: "Content-Type: ...\r\nContent-Length: N\r\n\r\n"
    hdr: [128]u8,
    hdr_len: usize,
    // Pointers for sendv iovecs
    status_line: []const u8, // static string
    body: ?[]const u8, // points into conn.body_buf or static
};

const RedisWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
};

const PgWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
    cmd: driver.PgCmd,
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
    transport: Ring = .{},
    recv_state: enum { idle, receiving, parsing, err } = .idle,
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

    fn pushWaiter(self: *PgConn, conn_idx: u16, py_coro: *ffi.PyObject, cmd: driver.PgCmd, stmt_idx: u16, model_cls: ?*ffi.PyObject) !void {
        if (self.waiter_count >= PG_WAITER_CAP) return error.WaiterQueueFull;
        self.waiters[self.waiter_tail] = .{
            .conn_idx = conn_idx,
            .py_coro = py_coro,
            .cmd = cmd.normalize(),
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
    backend: kqueue.Kqueue,
    conns: *Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_token: Token = .{ .tag = .accept },
    req_ctx: ?*const handler_mod.RequestContext = null,

    // Typed stage queues
    parse_q: Queue(ParseTask) = .{},
    handle_q: Queue(HandleTask) = .{},
    send_q: Queue(SendTask) = .{},
    close_q: Queue(u16) = .{},

    // iovecs storage — one set of MAX_IOVECS per send task, reused each cycle
    iovecs_buf: [MAX_BATCH][MAX_IOVECS]posix.iovec_const = undefined,

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
    pg_transport_pool: RecvPool,
    pg_result_pool: SlabPool,

    pub fn init(self: *Pipeline, allocator: std.mem.Allocator, conns: *Pool(Conn), entries: u16) !void {
        var backend = try kqueue.Kqueue.init(allocator, entries);
        errdefer backend.deinit(allocator);

        var pg_transport_pool = try RecvPool.init(allocator, RECV_BUFFER_COUNT);
        errdefer pg_transport_pool.deinit();

        var result_pool = SlabPool.init(allocator, RESULT_SLAB_MAX_LIVE);
        errdefer result_pool.deinit();

        self.* = .{
            .backend = backend,
            .conns = conns,
            .allocator = allocator,
            .pg_transport_pool = pg_transport_pool,
            .pg_result_pool = result_pool,
        };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            pg.transport.deinit(&self.pg_transport_pool);
        }
        self.pg_transport_pool.deinit();
        self.pg_result_pool.deinit();
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        try dispatch.start(self, listen_fd);
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
        const completions = try self.backend.submitAndWait(wait_nr);
        if (completions.tokens.len == 0) return false;

        // Refresh cached response prefix (once per second)
        _ = http1.commonResponseHeaders();

        // Reset queues
        self.parse_q.len = 0;
        self.handle_q.len = 0;
        self.send_q.len = 0;
        self.close_q.len = 0;

        // Classify
        for (completions.tokens, completions.completions) |token, completion| {
            try dispatch.classifyCompletion(self, token, completion);
        }

        // DAG
        try self.stageParse();

        // GIL held across handle + redis + postgres stages (one acquire for all Python work)
        const py_ctx = if (self.req_ctx) |ctx| ctx.py_ctx else null;
        const need_gil = py_ctx != null and (self.handle_q.len > 0 or self.redis_recv_state == .parsing or self.redis_recv_state == .err or self.anyPgNeedsGil());
        if (need_gil) py_ctx.?.py.acquireGil();
        defer if (need_gil) py_ctx.?.py.releaseGil();

        try self.stageHandle();
        try self.stageRedis();
        try self.stagePostgres();

        try self.stageSerializeAndSend();
        self.stageClose();

        return true;
    }

    // ── Classify ──────────────────────────────────────────────────

    pub fn onAccept(self: *Pipeline, result: i32) void {
        if (result < 0) return;
        const client_fd: posix.socket_t = @intCast(result);

        const idx = self.conns.borrow() catch {
            posix.close(client_fd);
            return;
        };
        const conn = self.conns.get_ptr(idx);
        conn.fd = client_fd;
        conn.pool_index = @intCast(idx);
        conn.token = .{ .tag = .conn };
        conn.ensureInit(self.allocator) catch {
            posix.close(client_fd);
            self.conns.release(idx);
            return;
        };
        conn.resetRecv();

        dispatch.submitConnRecv(self, conn) catch {
            posix.close(client_fd);
            self.conns.release(idx);
            return;
        };
    }

    pub fn onConnCompletion(self: *Pipeline, token: *Token, completion: Completion) !void {
        const conn: *Conn = @fieldParentPtr("token", token);
        const index = conn.pool_index;

        switch (completion.op_tag) {
            .recv => {
                if (completion.result <= 0) {
                    try self.close_q.push(index);
                    return;
                }
                conn.zc.mark_written(@intCast(completion.result));
                try self.parse_q.push(.{ .conn = index });
            },
            .send, .sendv => {
                if (completion.result < 0) {
                    try self.close_q.push(index);
                    return;
                }
                // Send complete — keepalive
                conn.resetRecv();
                try dispatch.submitConnRecv(self, conn);
            },
            else => {},
        }
    }

    // ── Stage: Parse ──────────────────────────────────────────────

    fn stageParse(self: *Pipeline) !void {
        for (self.parse_q.slice()) |pt| {
            const conn = self.conns.get_ptr(pt.conn);
            const data = conn.zc.as_slice();

            const new_bytes = data[conn.head_fed..];
            const consumed = conn.head_parser.feed(new_bytes);
            conn.head_fed += consumed;

            if (conn.head_parser.state != .finished) {
                conn.recv_slice = conn.zc.get_write_area(4096) catch {
                    try self.close_q.push(pt.conn);
                    continue;
                };
                dispatch.submitConnRecv(self, conn) catch {
                    try self.close_q.push(pt.conn);
                    continue;
                };
                continue;
            }

            const header_end = conn.head_fed;
            const content_length = quickContentLength(data[0..header_end]);
            if (content_length > 0) {
                const body_received = data.len - header_end;
                if (body_received < content_length) {
                    conn.recv_slice = conn.zc.get_write_area(
                        content_length - body_received,
                    ) catch {
                        try self.close_q.push(pt.conn);
                        continue;
                    };
                    dispatch.submitConnRecv(self, conn) catch {
                        try self.close_q.push(pt.conn);
                        continue;
                    };
                    continue;
                }
            }

            try self.handle_q.push(.{
                .conn = pt.conn,
                .header_end = header_end,
                .content_length = content_length,
            });
        }
    }

    // ── Stage: Handle (batched + SIMD screened) ────────────────
    // 1. SIMD screen: gather first bytes from N requests, vectorized
    //    classify which are GET. For GET-to-root with no_args handler,
    //    skip Request.parse() and dict building entirely.
    // 2. GIL acquired once for the entire batch.
    // 3. Remaining requests: full parse → route → invoke.

    fn stageHandle(self: *Pipeline) !void {
        const req_ctx = self.req_ctx orelse return;
        const batch = self.handle_q.slice();
        if (batch.len == 0) return;

        // ── SIMD screen: gather + classify ───────────────────────
        var first_bytes: [MAX_BATCH]u8 = undefined;
        for (batch, 0..) |ht, i| {
            const data = self.conns.get_ptr(ht.conn).zc.as_slice();
            first_bytes[i] = if (data.len > 0) data[0] else 0;
        }
        var is_get: [MAX_BATCH]bool = .{false} ** MAX_BATCH;
        simdScreenBytes(first_bytes[0..batch.len], 'G', is_get[0..batch.len]);

        const py_ctx = req_ctx.py_ctx;

        for (batch, 0..) |ht, i| {
            const conn = self.conns.get_ptr(ht.conn);
            const data = conn.zc.as_slice();

            // Fast path: SIMD told us byte[0]=='G'. Check "GET / " or "GET /x".
            if (is_get[i] and data.len >= 6 and std.mem.eql(u8, data[1..4], "ET ")) {
                const uri_start = 4;
                const uri_end = std.mem.indexOfScalarPos(u8, data, uri_start, ' ') orelse data.len;
                const uri = data[uri_start..uri_end];

                switch (req_ctx.router.match(.GET, uri)) {
                    .found => |found| {
                        if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                            if (py_ctx) |py| {
                                const flags = module.getHandlerFlags(py.py.necro_module, py_id);
                                if (flags.no_args) {
                                    const result = try driver.invokePythonHandler(
                                        py.py.necro_module,
                                        py_id,
                                        &http1.Request{},
                                        &.{},
                                        &conn.body_buf,
                                        null,
                                        self.redisSendSlice(),
                                        self.pgSendSlice(),
                                        self.pgStmtCache(),
                                        self.pgConnPrepared(),
                                        null,
                                    );
                                    try self.handleResult(ht.conn, result);
                                    continue;
                                }
                                const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                    try self.send_q.push(try makeErrorSend(ht.conn, .bad_request));
                                    continue;
                                };
                                const result = driver.invokePythonHandler(
                                    py.py.necro_module,
                                    py_id,
                                    &req,
                                    found.params[0..found.param_count],
                                    &conn.body_buf,
                                    null,
                                    self.redisSendSlice(),
                                    self.pgSendSlice(),
                                    self.pgStmtCache(),
                                    self.pgConnPrepared(),
                                    null,
                                ) catch {
                                    try self.send_q.push(try makeErrorSend(ht.conn, .internal_server_error));
                                    continue;
                                };
                                try self.handleResult(ht.conn, result);
                                continue;
                            }
                            try self.send_q.push(try makeErrorSend(ht.conn, .service_unavailable));
                        } else if (req_ctx.handlers[found.handler_id]) |h| {
                            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                try self.send_q.push(try makeErrorSend(ht.conn, .bad_request));
                                continue;
                            };
                            try self.send_q.push(try makeResponseSend(ht.conn, h(&req)));
                        } else {
                            try self.send_q.push(try makeErrorSend(ht.conn, .internal_server_error));
                        }
                        continue;
                    },
                    .not_found => {
                        try self.send_q.push(try makeErrorSend(ht.conn, .not_found));
                        continue;
                    },
                    .method_not_allowed => {
                        var r = response_mod.Response.init(.method_not_allowed);
                        r.body = "Method Not Allowed";
                        try self.send_q.push(try makeResponseSend(ht.conn, r));
                        continue;
                    },
                }
            }

            // Slow path: non-GET or SIMD screen missed — full parse
            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                try self.send_q.push(try makeErrorSend(ht.conn, .bad_request));
                continue;
            };
            switch (req_ctx.router.match(req.method orelse .GET, req.uri orelse "/")) {
                .found => |found| {
                    if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                        if (py_ctx) |py| {
                            const result = try driver.invokePythonHandler(
                                py.py.necro_module,
                                py_id,
                                &req,
                                found.params[0..found.param_count],
                                &conn.body_buf,
                                null,
                                self.redisSendSlice(),
                                self.pgSendSlice(),
                                self.pgStmtCache(),
                                self.pgConnPrepared(),
                                null,
                            );
                            try self.handleResult(ht.conn, result);
                        } else {
                            try self.send_q.push(try makeErrorSend(ht.conn, .service_unavailable));
                        }
                    } else if (req_ctx.handlers[found.handler_id]) |h| {
                        try self.send_q.push(try makeResponseSend(ht.conn, h(&req)));
                    } else {
                        try self.send_q.push(try makeErrorSend(ht.conn, .internal_server_error));
                    }
                },
                .not_found => try self.send_q.push(try makeErrorSend(ht.conn, .not_found)),
                .method_not_allowed => {
                    var r = response_mod.Response.init(.method_not_allowed);
                    r.body = "Method Not Allowed";
                    try self.send_q.push(try makeResponseSend(ht.conn, r));
                },
            }
        }
    }

    /// Handle an InvokeResult: response goes to send_q, yields update send buffers + push waiters.
    fn handleResult(self: *Pipeline, conn: u16, result: driver.InvokeResult) !void {
        switch (result) {
            .response => |owned| {
                var resp = owned;
                defer resp.deinit();
                try self.send_q.push(try makeResponseSend(conn, resp.response));
            },
            .redis_yield => |ry| {
                self.redis_send_len += ry.bytes_written;
                try self.pushRedisWaiter(conn, ry.py_coro);
            },
            .pg_yield => |pg| {
                // The round-robin PgConn was selected by pgSendSlice before
                // classifySentinel wrote into its send buffer. pg_last_conn
                // tracks which connection was selected.
                const pg_conn = &self.pg_conns[self.pg_last_conn];
                pg_conn.send_len += pg.bytes_written;
                errdefer ffi.xdecref(pg.model_cls);
                try pg_conn.pushWaiter(conn, pg.py_coro, pg.cmd, pg.stmt_idx, pg.model_cls);
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
    // Formats per-response headers, builds iovecs, submits sendv.
    //
    // Each response is scattered across up to 4 iovecs:
    //   [0] status line       — static string ("HTTP/1.1 200 OK\r\n")
    //   [1] common headers    — cached per-second ("Server: necro\r\nDate: ...\r\n")
    //   [2] per-response hdrs — "Connection: keep-alive\r\nContent-Type: ...\r\nContent-Length: N\r\n\r\n"
    //   [3] body              — from conn.body_buf or static string

    fn stageSerializeAndSend(self: *Pipeline) !void {
        const common = http1.commonResponseHeaders();

        for (self.send_q.mutableSlice(), 0..) |*st, i| {
            const conn = self.conns.get_ptr(st.conn);

            var iov_count: usize = 0;
            // [0] status line
            self.iovecs_buf[i][iov_count] = .{ .base = st.status_line.ptr, .len = st.status_line.len };
            iov_count += 1;
            // [1] common headers
            self.iovecs_buf[i][iov_count] = .{ .base = common.ptr, .len = common.len };
            iov_count += 1;
            // [2] per-response headers
            self.iovecs_buf[i][iov_count] = .{ .base = &st.hdr, .len = st.hdr_len };
            iov_count += 1;
            // [3] body
            if (st.body) |body| {
                self.iovecs_buf[i][iov_count] = .{ .base = body.ptr, .len = body.len };
                iov_count += 1;
            }

            dispatch.submitConnSendv(self, conn, self.iovecs_buf[i][0..iov_count]) catch {
                try self.close_q.push(st.conn);
            };
        }
    }

    // ── Redis IO ──────────────────────────────────────────────────
    // Redis completions arrive during classify. The state machine drives
    // send → recv transitions. RESP parsing + coroutine resumption happens
    // here with GIL held, pushing completed responses to send_q.

    /// IO state machine only — no Python work. Defers RESP parsing to stageRedis.
    pub fn onRedisSendIO(self: *Pipeline, result: i32) !void {
        if (result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        const sent: usize = @intCast(result);
        self.redis_send_offset += sent;
        if (self.redis_send_offset < self.redis_send_len) {
            try dispatch.submitRedisSend(self);
            return;
        }
        // Send complete — compact and go idle
        self.redis_send_len = 0;
        self.redis_send_offset = 0;
        self.redis_send_state = .idle;
    }

    pub fn onRedisRecvIO(self: *Pipeline, result: i32) !void {
        if (result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        self.redis_recv_len += @intCast(result);
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
                try dispatch.submitRedisRecv(self);
            } else {
                self.redis_recv_state = .idle;
            }
        }

        // 3. Flush pending sends (independent of recv state)
        const new_queries = self.redis_waiter_count - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try dispatch.submitRedisSend(self);
            // Arm recv if not already receiving
            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .receiving;
                try dispatch.submitRedisRecv(self);
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

        // Resume head waiter's coroutine with the parsed result
        try self.resumeRedisWaiter(py_result);
        self.redis_in_flight -= 1;
        return true;
    }

    /// Resume the head waiter's Python coroutine with a redis result.
    /// Uses PyIter_Send — no method lookup, no StopIteration exception overhead.
    fn resumeRedisWaiter(self: *Pipeline, result: *ffi.PyObject) !void {
        defer ffi.decref(result); // iterSend increfs internally; we own the creation ref
        const waiter = self.popRedisWaiter() orelse return;
        const conn = self.conns.get_ptr(waiter.conn_idx);

        const send = ffi.iterSend(waiter.py_coro, result);
        switch (send.status) {
            .next => {
                // Coroutine yielded again — classify sentinel
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                const yield = driver.classifySentinel(
                    sentinel,
                    waiter.py_coro,
                    self.redisSendSlice(),
                    self.pgSendSlice(),
                    self.pgStmtCache(),
                    self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro);
                        self.redis_in_flight += 1;
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.cmd, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse {
                    try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                defer ffi.decref(py_res);
                const resp = driver.convertPythonResponse(py_res, &conn.body_buf) catch
                    response_mod.Response.init(.internal_server_error);
                try self.send_q.push(try makeResponseSend(waiter.conn_idx, resp));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
            },
        }
    }

    fn failHeadWaiter(self: *Pipeline) !void {
        const waiter = self.popRedisWaiter() orelse return;
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
    }

    fn failRedisWaiters(self: *Pipeline) !void {
        while (self.redis_waiter_count > 0) {
            try self.failHeadWaiter();
        }
        self.redis_recv_state = .idle;
        self.redis_send_state = .idle;
        self.redis_in_flight = 0;
    }

    fn pushRedisWaiter(self: *Pipeline, conn_idx: u16, py_coro: *ffi.PyObject) !void {
        if (self.redis_waiter_count >= MAX_BATCH) return error.WaiterQueueFull;
        self.redis_waiters[self.redis_waiter_tail] = .{ .conn_idx = conn_idx, .py_coro = py_coro };
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

    pub fn onPgSendIO(_: *Pipeline, pg: *PgConn, result: i32) !void {
        if (result <= 0) {
            pg.recv_state = .err;
            return;
        }
        const sent: usize = @intCast(result);
        pg.send_offset += sent;
        if (pg.send_offset < pg.send_len) {
            return; // partial send — will be re-submitted by stagePostgres
        }
        pg.send_len = 0;
        pg.send_offset = 0;
        pg.send_state = .idle;
    }

    pub fn onPgRecvIO(_: *Pipeline, pg: *PgConn, result: i32) !void {
        if (result <= 0) {
            pg.recv_state = .err;
            return;
        }
        const received: usize = @intCast(result);
        pg.transport.noteReceived(received);
        pg.recv_state = .parsing;
    }

    /// Process postgres: parse responses + flush pending sends for all connections.
    /// GIL is already held from stageHandle.
    fn stagePostgres(self: *Pipeline) !void {
        self.pg_wire_ns = 0;
        if (self.pg_conn_count == 0) return;

        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            // 1. Handle deferred errors
            if (pg.recv_state == .err) {
                try self.failPgConnWaiters(pg);
            }

            // 2. Parse responses
            if (pg.recv_state == .parsing) {
                const t0 = try std.time.Instant.now();
                try self.parsePgConnResponses(pg);
                self.pg_wire_ns += (try std.time.Instant.now()).since(t0);
                _ = pg.transport.consumeParsed();

                if (pg.in_flight > 0) {
                    pg.recv_state = .receiving;
                    dispatch.submitPgRecv(self, pg) catch |err| switch (err) {
                        error.RecvPoolExhausted => {
                            try self.failPgConnForRecvPool(pg);
                            continue;
                        },
                        error.RingFull => {
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres transport ring full");
                            continue;
                        },
                        else => return err,
                    };
                } else {
                    pg.recv_state = .idle;
                }
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
                try dispatch.submitPgSend(self, pg);
                if (pg.recv_state == .idle) {
                    pg.recv_state = .receiving;
                    dispatch.submitPgRecv(self, pg) catch |err| switch (err) {
                        error.RecvPoolExhausted => {
                            try self.failPgConnForRecvPool(pg);
                            continue;
                        },
                        error.RingFull => {
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres transport ring full");
                            continue;
                        },
                        else => return err,
                    };
                }
            }

            // 4. Re-submit partial sends
            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try dispatch.submitPgSend(self, pg);
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
        var query_save_pos = pg.transport.parseOffset();

        while (pg.peekWaiter()) |waiter| {
            const message = pg_stream.nextMessage(&pg.transport, pg.transport.parseOffset()) catch |err| switch (err) {
                error.MessageTooLarge => {
                    if (py_result) |r| ffi.decref(r);
                    if (py_list) |l| ffi.decref(l);
                    try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres message exceeds transport ring capacity");
                    return;
                },
                else => return err,
            };
            if (message == null) {
                // Incomplete mid-query — rollback current query only
                pg.transport.setParseOffset(query_save_pos);
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const msg = message.?;
            pg.transport.setParseOffset(pg.transport.parseOffset() + msg.total_len);

            // ReadyForQuery is a batch-level message, not per-query
            if (msg.header.tag == wire.BackendTag.ready_for_query) {
                query_save_pos = pg.transport.parseOffset();
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
                    _ = pg_stream.applyRowDescription(self.allocator, &pg.transport, msg.payload_off, msg.payload_len, stmt_entry) catch |err| switch (err) {
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
                        &pg.transport,
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
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres row exceeds transport/result capacity");
                            return;
                        },
                        else => return err,
                    };
                    const result_obj = try wrapPgRowResult(waiter, raw_result);

                    const wait_cmd = waiter.cmd.normalize();
                    if (wait_cmd == .FETCH_ONE) {
                        if (py_result == null) py_result = result_obj else ffi.decref(result_obj);
                    } else if (wait_cmd == .FETCH_ALL) {
                        if (py_list == null) py_list = c.PyList_New(0) orelse return error.PythonError;
                        if (c.PyList_Append(py_list.?, result_obj) != 0) return error.PythonError;
                        ffi.decref(result_obj);
                    } else {
                        ffi.decref(result_obj);
                    }
                },
                wire.BackendTag.command_complete => {
                    if (waiter.cmd == .EXECUTE) {
                        const count = pg_stream.parseCommandCompleteCount(&pg.transport, msg.payload_off, msg.payload_len);
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (waiter.cmd == .FETCH_ALL)
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
                    query_save_pos = pg.transport.parseOffset(); // this query is fully parsed
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
                            ffi.xdecref(cq.waiter.model_cls);
                            ffi.coroutineClose(cq.waiter.py_coro);
                            ffi.decref(cq.waiter.py_coro);
                            try self.send_q.push(try makeErrorSend(cq.waiter.conn_idx, .internal_server_error));
                        }
                        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                        return;
                    }

                    for (0..failed_in_batch) |_| {
                        const failed_waiter = pg.popWaiter() orelse {
                            for (completed[0..completed_count]) |cq| {
                                ffi.decref(cq.result);
                                ffi.xdecref(cq.waiter.model_cls);
                                ffi.coroutineClose(cq.waiter.py_coro);
                                ffi.decref(cq.waiter.py_coro);
                                try self.send_q.push(try makeErrorSend(cq.waiter.conn_idx, .internal_server_error));
                            }
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                            return;
                        };
                        ffi.xdecref(failed_waiter.model_cls);
                        ffi.coroutineClose(failed_waiter.py_coro);
                        ffi.decref(failed_waiter.py_coro);
                        try self.send_q.push(try makeErrorSend(failed_waiter.conn_idx, .internal_server_error));
                        pg.in_flight -= 1;
                    }

                    query_save_pos = pg.transport.parseOffset();

                    for (completed[0..completed_count]) |cq| {
                        try self.resumePgWaiter(cq.waiter, cq.result);
                    }
                    completed_count = 0;
                },
                else => continue,
            }
        }

        // Resume completed queries after parsing to keep completion batching cheap.
        for (completed[0..completed_count]) |cq| {
            try self.resumePgWaiter(cq.waiter, cq.result);
        }
    }

    fn resumePgWaiter(self: *Pipeline, waiter: PgWaiter, result: *ffi.PyObject) !void {
        defer ffi.decref(result); // iterSend increfs internally; we own the creation ref
        defer ffi.xdecref(waiter.model_cls);
        const conn = self.conns.get_ptr(waiter.conn_idx);
        const send = ffi.iterSend(waiter.py_coro, result);
        switch (send.status) {
            .next => {
                // Coroutine yielded again — classify sentinel
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                const yield = driver.classifySentinel(
                    sentinel,
                    waiter.py_coro,
                    self.redisSendSlice(),
                    self.pgSendSlice(),
                    self.pgStmtCache(),
                    self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro);
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.cmd, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse return error.PythonError;
                defer ffi.decref(py_res);
                const resp = driver.convertPythonResponse(py_res, &conn.body_buf) catch
                    response_mod.Response.init(.internal_server_error);
                try self.send_q.push(try makeResponseSend(waiter.conn_idx, resp));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(try makeErrorSend(waiter.conn_idx, .internal_server_error));
            },
        }
    }

    fn failPgConnForRecvPool(self: *Pipeline, pg: *PgConn) !void {
        log.warn(
            "postgres transport pool exhausted: fd={d} waiters={d} in_use={d}/{d} free={d}",
            .{ pg.fd, pg.waiter_count, self.pg_transport_pool.inUseCount(), self.pg_transport_pool.bufferCount(), self.pg_transport_pool.freeCount() },
        );
        try self.failPgConnWaitersWithStatus(pg, .service_unavailable, "Postgres transport pool exhausted");
    }

    fn failPgConnWaiters(self: *Pipeline, pg: *PgConn) !void {
        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, null);
    }

    fn failPgConnWaitersWithStatus(self: *Pipeline, pg: *PgConn, status: std.http.Status, body: ?[]const u8) !void {
        while (pg.waiter_count > 0) {
            const waiter = pg.popWaiter() orelse break;
            ffi.xdecref(waiter.model_cls);
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            if (body) |msg| {
                var resp = response_mod.Response.init(status);
                _ = resp.setContentType("text/plain");
                _ = resp.setBody(msg);
                try self.send_q.push(try makeResponseSend(waiter.conn_idx, resp));
            } else {
                try self.send_q.push(try makeErrorSend(waiter.conn_idx, status));
            }
        }
        pg.recv_state = .idle;
        pg.send_state = .idle;
        pg.in_flight = 0;
        pg.transport.clear();
        pg.clearBatches();
    }

    pub fn matchPgSendToken(self: *Pipeline, token: *Token) ?*PgConn {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            if (token == &pg.send_token) return pg;
        }
        return null;
    }

    pub fn matchPgRecvToken(self: *Pipeline, token: *Token) ?*PgConn {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            if (token == &pg.recv_token) return pg;
        }
        return null;
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

    // ── Close ─────────────────────────────────────────────────────

    fn stageClose(self: *Pipeline) void {
        for (self.close_q.slice()) |index| {
            const conn = self.conns.get_ptr(index);
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

/// Scan raw header bytes for Content-Length without a full Request.parse().
/// Methods that never carry a body (GET, HEAD, DELETE, OPTIONS) return 0
/// immediately — the common fast path under benchmarks.
fn quickContentLength(data: []const u8) usize {
    if (data.len < 4) return 0;
    switch (data[0]) {
        'G', 'H', 'D', 'O' => return 0,
        else => {},
    }
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, data, needle) orelse return 0;
    const start = pos + needle.len;
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return 0;
    return std.fmt.parseInt(usize, data[start..end], 10) catch 0;
}

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
/// Per-response headers go into st.hdr. Body pointer set from resp.body.
fn makeResponseSend(conn_idx: u16, resp: response_mod.Response) error{UnsupportedStatus}!SendTask {
    var st = SendTask{
        .conn = conn_idx,
        .hdr = undefined,
        .hdr_len = 0,
        .status_line = try statusLine(resp.status),
        .body = resp.body,
    };
    writePerResponseHeaders(&st, &resp);
    return st;
}

fn makeErrorSend(conn_idx: u16, status: std.http.Status) error{UnsupportedStatus}!SendTask {
    var st = SendTask{
        .conn = conn_idx,
        .hdr = undefined,
        .hdr_len = 0,
        .status_line = try statusLine(status),
        .body = null,
    };
    const suffix = "Connection: close\r\nContent-Length: 0\r\n\r\n";
    @memcpy(st.hdr[0..suffix.len], suffix);
    st.hdr_len = suffix.len;
    return st;
}

/// Format per-response headers into SendTask.hdr:
///   Connection: keep-alive\r\n
///   Content-Type: ...\r\n    (from handler)
///   Content-Length: N\r\n
///   \r\n
fn writePerResponseHeaders(st: *SendTask, resp: *const response_mod.Response) void {
    var pos: usize = 0;

    const ka = "Connection: keep-alive\r\n";
    @memcpy(st.hdr[pos..][0..ka.len], ka);
    pos += ka.len;

    // User headers from the Response
    for (resp.headers[0..resp.header_count]) |h| {
        const needed = h.name.len + 2 + h.value.len + 2;
        if (pos + needed > st.hdr.len) break;
        @memcpy(st.hdr[pos..][0..h.name.len], h.name);
        pos += h.name.len;
        st.hdr[pos] = ':';
        st.hdr[pos + 1] = ' ';
        pos += 2;
        @memcpy(st.hdr[pos..][0..h.value.len], h.value);
        pos += h.value.len;
        st.hdr[pos] = '\r';
        st.hdr[pos + 1] = '\n';
        pos += 2;
    }

    // Content-Length
    const body_len = if (resp.body) |b| b.len else 0;
    {
        const cl = "Content-Length: ";
        @memcpy(st.hdr[pos..][0..cl.len], cl);
        pos += cl.len;
        const len_str = std.fmt.bufPrint(st.hdr[pos..], "{d}", .{body_len}) catch return;
        pos += len_str.len;
        st.hdr[pos] = '\r';
        st.hdr[pos + 1] = '\n';
        pos += 2;
    }

    // End of headers
    st.hdr[pos] = '\r';
    st.hdr[pos + 1] = '\n';
    pos += 2;

    st.hdr_len = pos;
}

// ── Tests ─────────────────────────────────────────────────────────

test "makeResponseSend 200 text" {
    _ = http1.commonResponseHeaders();
    const resp = response_mod.Response.text("hello");
    const st = try makeResponseSend(5, resp);
    try std.testing.expectEqual(@as(u16, 5), st.conn);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", st.status_line);
    try std.testing.expectEqualStrings("hello", st.body.?);
    // Per-response headers should contain Content-Type and Content-Length
    const hdr = st.hdr[0..st.hdr_len];
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "\r\n\r\n"));
}

test "makeErrorSend" {
    const st = try makeErrorSend(3, .bad_request);
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request\r\n", st.status_line);
    try std.testing.expect(st.body == null);
    try std.testing.expect(std.mem.indexOf(u8, st.hdr[0..st.hdr_len], "Connection: close") != null);
}

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

test "quickContentLength GET" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("GET / HTTP/1.1\r\nHost: h\r\n\r\n"));
}

test "quickContentLength HEAD" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("HEAD / HTTP/1.1\r\n\r\n"));
}

test "quickContentLength POST with body" {
    try std.testing.expectEqual(@as(usize, 13), quickContentLength("POST /x HTTP/1.1\r\nContent-Length: 13\r\n\r\n"));
}

test "quickContentLength POST no body" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("POST /x HTTP/1.1\r\nHost: h\r\n\r\n"));
}

test "Queue typed" {
    var q: Queue(HandleTask) = .{};
    try q.push(.{ .conn = 1, .header_end = 100, .content_length = 0 });
    try q.push(.{ .conn = 5, .header_end = 200, .content_length = 42 });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(u16, 1), q.slice()[0].conn);
}
