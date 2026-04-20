const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const necro = @import("necro");
const py = necro.py;
const aio = necro.aio;
const http = necro.http;
const necro_pg = necro.pg;
const ffi = py.ffi;
const driver = py.driver;
const core = necro.core;
const tls = aio.tls;
const pg_stream = necro_pg.stream;
const Ring = necro_pg.ring.Ring;
const log = std.log.scoped(.@"necro/aio/readiness/runtime");
const BUF_SIZE: usize = 4096;
const PG_SEND_BUF_SIZE: usize = 65536;

const Conn = http.exchange.Conn;
const Exchange = http.exchange.Exchange;
const Py = py.step;

var tombstone_storage: Exchange = undefined;
const TOMBSTONE: *Exchange = &tombstone_storage;

pub const PgConn = struct {
    fd: posix.socket_t = undefined,
    send_token: aio.Token = .{ .tag = .pg_send },
    recv_token: aio.Token = .{ .tag = .pg_recv },
    send_len: usize = 0,
    send_offset: usize = 0,
    send_state: enum { idle, sending } = .idle,
    recv_state: enum { idle, parsing, err } = .idle,
    in_flight: usize = 0,
    send_buf: []u8 = &.{},
    waiter_q: core.BatchQueue(*Exchange, aio.BATCH_QUEUE_CAPACITY) = .{},
    stmt_idx_q: core.Queue(u16, aio.BATCH_QUEUE_CAPACITY) = .{},
    prepared: [necro_pg.stmt.STMT_CACHE_CAPACITY]bool = .{false} ** necro_pg.stmt.STMT_CACHE_CAPACITY,
    transport: ?Ring = null,
};

pub const Pipeline = struct {
    backend: sys.Backend,
    conns: *core.Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_token: aio.Token = .{ .tag = .accept },
    router: *const http.router.Router = undefined,
    py_ctx: *driver.PyContext = undefined,

    recv_q: core.Queue(sys.Event, aio.BATCH_QUEUE_CAPACITY) = .{},
    send_ev_q: core.Queue(sys.Event, aio.BATCH_QUEUE_CAPACITY) = .{},
    send_q: core.Queue(Py.SendAction, aio.BATCH_QUEUE_CAPACITY) = .{},
    close_q: core.Queue(*Conn, aio.BATCH_QUEUE_CAPACITY) = .{},
    py_ready_q: core.Queue(Py.Job, aio.BATCH_QUEUE_CAPACITY) = .{},

    redis_fd: ?posix.socket_t = null,
    redis_send_token: aio.Token = .{ .tag = .redis_send },
    redis_recv_token: aio.Token = .{ .tag = .redis_recv },
    redis_send_buf: [8192]u8 = undefined,
    redis_send_len: usize = 0,
    redis_send_state: enum { idle, sending } = .idle,
    redis_send_offset: usize = 0,
    redis_recv_buf: [8192]u8 = undefined,
    redis_recv_len: usize = 0,
    redis_parse_pos: usize = 0,
    redis_recv_state: enum { idle, parsing, err } = .idle,
    redis_waiter_q: core.Queue(*Exchange, aio.BATCH_QUEUE_CAPACITY) = .{},
    redis_in_flight: usize = 0,

    pg_conn: ?PgConn = null,

    tls_ctx: ?*tls.TlsContext = null,

    pg_stmt_cache: necro_pg.stmt.Cache = .{},
    py_body_release: std.ArrayListUnmanaged(py.result.PyBodyHold) = .{},

    idle: aio.IdleList = .{},
    exchange_timeout: aio.IdleList = .{ .ms = 30_000 },
    cycle_now_ns: i64 = 0,

    cycle_count: u64 = 0,
    ns_classify: u64 = 0,
    ns_send_ev: u64 = 0,
    ns_recv: u64 = 0,
    ns_python: u64 = 0,
    ns_send: u64 = 0,
    ns_prepare: u64 = 0,
    ns_hdrs: u64 = 0,

    pub fn init(self: *Pipeline, allocator: std.mem.Allocator, conns: *core.Pool(Conn), entries: u16, router: *const http.router.Router, py_ctx: *driver.PyContext, idle_ms: i64, exchange_timeout_ms: i64) !void {
        var backend = try sys.Backend.init(allocator, entries);
        errdefer backend.deinit(allocator);

        self.* = .{
            .backend = backend,
            .conns = conns,
            .allocator = allocator,
            .router = router,
            .py_ctx = py_ctx,
        };
        self.idle.ms = idle_ms;
        self.exchange_timeout.ms = exchange_timeout_ms;
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        if (self.pg_conn) |*pg| {
            if (pg.transport) |*t| t.deinit();
            self.allocator.free(pg.send_buf);
        }
        self.py_body_release.deinit(allocator);
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        try self.startListening(listen_fd);
        try self.backend.wakeRegister();
    }

    pub fn wake(self: *Pipeline) void {
        self.backend.wake();
    }

    pub fn run(self: *Pipeline) !void {
        while (self.running and !necro.server.shutdown_flag.load(.acquire)) {
            _ = try self.cycle(1);
            while (try self.cycle(0)) {}
        }
        try self.drain();
    }

    fn drain(self: *Pipeline) !void {
        const deadline_ms = std.time.milliTimestamp() + necro.server.DRAIN_MS;
        while (self.conns.numActive() > 0 and std.time.milliTimestamp() < deadline_ms) {
            while (try self.cycle(0)) {}
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    fn cycle(self: *Pipeline, wait_nr: u32) !bool {
        const timeout_ns: ?i64 = if (wait_nr == 0) null else blk: {
            const idle_dl = self.idle.nextDeadlineNs();
            const ex_dl = self.exchange_timeout.nextDeadlineNs();
            const deadline_opt: ?i64 = if (idle_dl == null) ex_dl else if (ex_dl == null) idle_dl else @min(idle_dl.?, ex_dl.?);
            const deadline = deadline_opt orelse break :blk null;
            const now = std.time.nanoTimestamp();
            const remaining: i64 = @intCast(@max(@as(i128, 0), deadline - now));
            break :blk remaining;
        };
        const events = try self.backend.wait(wait_nr, timeout_ns);
        if (wait_nr == 0 and events.len == 0 and
            self.py_ready_q.isEmpty() and
            self.send_q.isEmpty() and
            self.close_q.isEmpty()) return false;

        self.cycle_now_ns = @intCast(std.time.nanoTimestamp());
        http.headers.refreshCommonResponseHeaders(@divTrunc(self.cycle_now_ns, std.time.ns_per_s));

        while (self.idle.expireOne(self.cycle_now_ns)) |n| {
            const conn: *Conn = @fieldParentPtr("idle", n);
            try self.close_q.push(conn);
        }

        while (self.exchange_timeout.expireOne(self.cycle_now_ns)) |n| {
            const exchange: *Exchange = @fieldParentPtr("timeout", n);
            if (exchange.conn) |conn| try self.close_q.push(conn);
            self.endExchange(exchange);
        }

        const t0 = try std.time.Instant.now();

        for (events) |event| {
            try self.classifyEvent(event);
        }
        const t_classify = try std.time.Instant.now();

        self.stageClose();
        try self.drainSendEvQ();
        const t_send_ev = try std.time.Instant.now();

        try self.drainRecvQ();
        const t_recv = try std.time.Instant.now();

        const py_ctx = self.py_ctx;
        const need_gil = !self.py_ready_q.isEmpty() or
            self.redis_recv_state == .parsing or
            self.redis_recv_state == .err or
            self.anyPgNeedsGil() or
            self.py_body_release.items.len > 0;
        if (need_gil) py_ctx.gil.lock();
        defer if (need_gil) py_ctx.gil.unlock();

        try self.drainPythonReady();
        try self.stageRedis();
        try self.drainPythonReady();
        try self.stagePostgres();
        try self.drainPythonReady();
        const t_python = try std.time.Instant.now();

        try self.stageSerializeAndSend();
        const t_send = try std.time.Instant.now();

        if (need_gil) self.drainPendingPyBodyReleases();

        self.cycle_count += 1;

        self.ns_classify += t_classify.since(t0);
        self.ns_send_ev += t_send_ev.since(t_classify);
        self.ns_recv += t_recv.since(t_send_ev);
        self.ns_python += t_python.since(t_recv);
        self.ns_send += t_send.since(t_python);

        if (self.cycle_count % 50000 == 0) {
            const total = self.ns_classify + self.ns_send_ev + self.ns_recv + self.ns_python + self.ns_send;
            if (total > 0) {
                std.debug.print("[cycle timing] classify={d}us send_ev={d}us recv={d}us python={d}us send={d}us (prepare={d}us hdrs={d}us)\n", .{
                    self.ns_classify / 1000,
                    self.ns_send_ev / 1000,
                    self.ns_recv / 1000,
                    self.ns_python / 1000,
                    self.ns_send / 1000,
                    self.ns_prepare / 1000,
                    self.ns_hdrs / 1000,
                });
            }
            self.ns_classify = 0;
            self.ns_send_ev = 0;
            self.ns_recv = 0;
            self.ns_python = 0;
            self.ns_send = 0;
            self.ns_prepare = 0;
            self.ns_hdrs = 0;
        }

        return true;
    }

    pub fn onAcceptable(self: *Pipeline) !void {
        if (necro.server.shutdown_flag.load(.acquire)) return;
        while (true) {
            const fd = posix.accept(self.listen_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            const conn = self.conns.borrow() catch {
                posix.close(fd);
                continue;
            };
            conn.* = .{
                .fd = fd,
                .recv_token = .{ .tag = .conn_recv },
                .send_token = .{ .tag = .conn_send },
            };

            if (self.tls_ctx) |tctx| {
                const h = self.allocator.create(tls.TlsHandshake) catch {
                    posix.close(fd);
                    conn.fd = -1;
                    self.conns.release(conn);
                    continue;
                };
                h.* = tls.TlsHandshake.init(tctx, fd) catch {
                    self.allocator.destroy(h);
                    posix.close(fd);
                    conn.fd = -1;
                    self.conns.release(conn);
                    continue;
                };
                conn.tls = h;
                self.idle.append(&conn.idle, self.cycle_now_ns);
                self.driveTlsHandshake(conn) catch {
                    try self.close_q.push(conn);
                };
                continue;
            }

            self.armConnRead(conn) catch {
                posix.close(fd);
                conn.fd = -1;
                self.conns.release(conn);
                continue;
            };
            self.idle.append(&conn.idle, self.cycle_now_ns);
        }
    }

    fn driveTlsHandshake(self: *Pipeline, conn: *Conn) !void {
        const h = conn.tls orelse return;
        switch (h.step()) {
            .want_read => try self.armConnRead(conn),
            .want_write => try self.armConnWrite(conn),
            .complete => {
                h.deinit();
                self.allocator.destroy(h);
                conn.tls = null;
                try self.armConnRead(conn);
            },
            .ktls_failed => {
                log.err("kTLS handoff failed on fd={d}", .{conn.fd});
                h.deinit();
                self.allocator.destroy(h);
                conn.tls = null;
                try self.close_q.push(conn);
            },
            .handshake_err => {
                h.deinit();
                self.allocator.destroy(h);
                conn.tls = null;
                try self.close_q.push(conn);
            },
        }
    }

    pub fn onConnWritable(self: *Pipeline, token: *aio.Token) !void {
        const conn: *Conn = @fieldParentPtr("send_token", token);
        if (conn.tls != null) {
            try self.driveTlsHandshake(conn);
            return;
        }
        const exchange = conn.current orelse return;
        if (exchange.send.mode == .idle) return;
        try self.drainConnSend(conn, exchange);
    }

    fn drainConnSend(self: *Pipeline, conn: *Conn, exchange: *Exchange) !void {
        const ss = exchange.send;
        while (ss.sent < ss.total_len) {
            const n = posix.writev(conn.fd, ss.iovecs[0..ss.iov_count]) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.armConnWrite(conn);
                    return;
                },
                else => return err,
            };
            if (n == 0) return error.ConnectionReset;
            ss.sent += n;
            if (ss.sent < ss.total_len) {
                http.send.advanceIovecs(&ss.iovecs, &ss.iov_count, n);
            }
        }

        ss.mode = .idle;
        ss.sent = 0;
        ss.total_len = 0;
        ss.iov_count = 0;
        const close_on_done = ss.close_on_done;
        ss.close_on_done = false;
        self.releaseExchangeSendBody(exchange);
        self.endExchange(exchange);

        if (close_on_done) {
            try self.close_q.push(conn);
            return;
        }

        try self.armConnRead(conn);
        self.idle.bump(&conn.idle, self.cycle_now_ns);
    }

    fn beginExchange(self: *Pipeline, conn: *Conn) !*Exchange {
        const exchange = try self.allocator.create(Exchange);
        errdefer self.allocator.destroy(exchange);
        exchange.* = .{};
        exchange.conn = conn;
        exchange.req = try self.allocator.create(http.exchange.Request);
        errdefer self.allocator.destroy(exchange.req);
        exchange.req.* = .{};
        exchange.req.router = self.router;
        exchange.send = try self.allocator.create(http.exchange.SendState);
        errdefer self.allocator.destroy(exchange.send);
        exchange.send.* = .{};
        conn.current = exchange;
        self.exchange_timeout.append(&exchange.timeout, self.cycle_now_ns);
        return exchange;
    }

    fn cancelExchange(self: *Pipeline, exchange: *Exchange) void {
        if (exchange.aborted) return;

        self.exchange_timeout.remove(&exchange.timeout);
        switch (exchange.io) {
            .none => {},
            .redis => self.redis_waiter_q.replace(exchange, TOMBSTONE),
            .pg => if (self.pg_conn) |*pg| pg.waiter_q.replace(exchange, TOMBSTONE),
        }

        if (exchange.conn) |conn| {
            if (conn.current == exchange) conn.current = null;
        }
        exchange.conn = null;

        exchange.dropAndCleanup();
        exchange.aborted = true;
    }

    fn finalizeExchange(self: *Pipeline, exchange: *Exchange) void {
        std.debug.assert(exchange.aborted);
        std.debug.assert(exchange.conn == null);
        std.debug.assert(!exchange.timeout.linked);
        std.debug.assert(exchange.io == .none);

        self.releaseExchangeSendBody(exchange);
        exchange.req.deinit(self.allocator);
        self.allocator.destroy(exchange.req);
        self.allocator.destroy(exchange.send);
        self.allocator.destroy(exchange);
    }

    fn endExchange(self: *Pipeline, exchange: *Exchange) void {
        self.cancelExchange(exchange);
        self.finalizeExchange(exchange);
    }

    fn drainRecvQ(self: *Pipeline) !void {
        while (self.recv_q.pop()) |event| {
            const conn: *Conn = @fieldParentPtr("recv_token", @as(*aio.Token, @ptrCast(@alignCast(event.token))));
            if (conn.fd < 0) continue;

            if (conn.tls != null) {
                try self.driveTlsHandshake(conn);
                continue;
            }

            const exchange = conn.current orelse blk: {
                const new_exchange = self.beginExchange(conn) catch {
                    try self.close_q.push(conn);
                    continue;
                };
                break :blk new_exchange;
            };
            const req = exchange.req;

            req.ensureCapacity(self.allocator, req.len + 4096) catch {
                self.endExchange(exchange);
                try self.close_q.push(conn);
                continue;
            };

            var alive = true;
            while (req.len < req.buf.len) {
                const n = posix.recv(conn.fd, req.recvSlice(), 0) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => {
                        try self.close_q.push(conn);
                        alive = false;
                        break;
                    },
                };
                if (n == 0) {
                    try self.close_q.push(conn);
                    alive = false;
                    break;
                }
                req.len += n;
            }
            if (!alive) continue;

            var meta: http.router.Meta = .{};
            self.router.parse(req.buf[0..req.len], &meta) catch |err| {
                if (err == error.Incomplete) {
                    try self.armConnRead(conn);
                    continue;
                }
                exchange.req.meta.keepalive = false;
                try self.send_q.push(.{
                    .exchange = exchange,
                    .source = .{ .native = http.response.Response.init(if (err == error.NoRoute) .not_found else .bad_request) },
                });
                continue;
            };

            if (meta.content_length > 0 and req.len - meta.body_off < meta.content_length) {
                req.meta = meta;
                try self.armConnRead(conn);
                continue;
            }

            req.meta = meta;

            const flags = py.module.getHandlerFlags(self.py_ctx.necro_module, meta.handler);

            try self.py_ready_q.push(.{ .invoke_handler = .{
                .exchange = exchange,
                .handler_id = meta.handler,
                .needs_req = flags.needs_request,
                .needs_params = flags.needs_params,
                .is_async = flags.is_async,
            } });
        }
    }

    fn drainSendEvQ(self: *Pipeline) !void {
        while (self.send_ev_q.pop()) |event| {
            const conn: *Conn = @fieldParentPtr("send_token", @as(*aio.Token, @ptrCast(@alignCast(event.token))));
            if (conn.fd < 0) continue;
            if (conn.tls != null) {
                try self.driveTlsHandshake(conn);
                continue;
            }
            const exchange = conn.current orelse continue;
            if (exchange.send.mode == .idle) continue;
            try self.drainConnSend(conn, exchange);
        }
    }

    fn drainPythonReady(self: *Pipeline) !void {
        while (self.py_ready_q.pop()) |job| {
            const action = Py.run(job, .{
                .mod = self.py_ctx.necro_module,
                .redis_send = self.redisSendSlice(),
                .pg_send = self.pgSendSlice(),
                .pg_stmt_cache = self.pgStmtCache(),
                .pg_prepared = self.pgConnPrepared(),
            }) catch {
                switch (job) {
                    .invoke_handler => |inv| self.endExchange(inv.exchange),
                    .resume_coroutine => |res| self.endExchange(res.exchange),
                }
                continue;
            };
            try self.applyPyAction(action);
        }
    }

    fn applyPyAction(self: *Pipeline, action: Py.Action) !void {
        switch (action) {
            .send => |send| try self.send_q.push(send),
            .fail => |f| {
                try self.send_q.push(.{
                    .exchange = f.exchange,
                    .source = .{ .native = http.response.Response.init(f.status) },
                });
            },
            .wait_redis => |w| {
                self.redis_send_len += w.bytes_written;
                try self.redis_waiter_q.push(w.exchange);
            },
            .wait_pg => |w| {
                const pg = &self.pg_conn.?;
                pg.send_len += w.bytes_written;
                try pg.waiter_q.push(w.exchange);
                try pg.stmt_idx_q.push(w.exchange.io.pg.stmt_idx);
            },
        }
    }

    pub fn redisSendSlice(self: *Pipeline) ?[]u8 {
        if (self.redis_fd == null) return null;
        if (self.redis_send_len >= self.redis_send_buf.len) return null;
        return self.redis_send_buf[self.redis_send_len..];
    }

    pub fn pgSendSlice(self: *Pipeline) ?[]u8 {
        if (self.pg_conn) |*pg| {
            if (pg.send_len >= pg.send_buf.len) return null;
            return pg.send_buf[pg.send_len..];
        }
        return null;
    }

    pub fn pgStmtCache(self: *Pipeline) ?*necro_pg.stmt.Cache {
        if (self.pg_conn == null) return null;
        return &self.pg_stmt_cache;
    }

    pub fn pgConnPrepared(self: *Pipeline) ?*[necro_pg.stmt.STMT_CACHE_CAPACITY]bool {
        if (self.pg_conn == null) return null;
        return &self.pg_conn.?.prepared;
    }

    fn stageSerializeAndSend(self: *Pipeline) !void {
        const common = http.headers.commonResponseHeaders();

        while (self.send_q.pop()) |st| {
            const exchange = st.exchange;
            const conn = exchange.conn orelse {
                self.endExchange(exchange);
                continue;
            };
            const ss = exchange.send;

            const t_prep = try std.time.Instant.now();
            var body_buf: ?[]u8 = null;
            var prepared = switch (st.source) {
                .native => |resp| py.result.Prepared.fromResponse(resp),
                .python => |py_result| blk: {
                    defer ffi.decref(py_result);
                    const buf = self.allocator.alloc(u8, BUF_SIZE) catch {
                        break :blk py.result.Prepared.fromResponse(http.response.Response.init(.internal_server_error));
                    };
                    const p = py.result.prepare(py_result, buf) catch {
                        self.allocator.free(buf);
                        if (ffi.errOccurred()) ffi.errPrint();
                        break :blk py.result.Prepared.fromResponse(http.response.Response.init(.internal_server_error));
                    };
                    body_buf = buf;
                    break :blk p;
                },
            };
            defer prepared.deinit();
            self.ns_prepare += (try std.time.Instant.now()).since(t_prep);

            const resp = &prepared.response;
            const status_line = http.response.statusLine(resp.status) catch {
                if (body_buf) |b| self.allocator.free(b);
                self.endExchange(exchange);
                try self.close_q.push(conn);
                continue;
            };

            const t_hdr = try std.time.Instant.now();
            const will_keep_alive = exchange.req.meta.keepalive;
            const hdr_len = http.response.writeResponseHeaders(ss.hdr[0..], resp, will_keep_alive);
            self.ns_hdrs += (try std.time.Instant.now()).since(t_hdr);
            ss.close_on_done = !will_keep_alive;

            if (ss.body_buf) |b| self.allocator.free(b);
            ss.body_py.deinit();
            ss.body = resp.body;
            ss.body_buf = body_buf;
            ss.body_py = prepared.py_body;
            prepared.py_body = .{};

            var iov_count: usize = 0;
            var total_len: usize = 0;
            ss.iovecs[iov_count] = .{ .base = status_line.ptr, .len = status_line.len };
            total_len += status_line.len;
            iov_count += 1;
            ss.iovecs[iov_count] = .{ .base = common.ptr, .len = common.len };
            total_len += common.len;
            iov_count += 1;
            ss.iovecs[iov_count] = .{ .base = &ss.hdr, .len = hdr_len };
            total_len += hdr_len;
            iov_count += 1;
            if (ss.body) |body| {
                ss.iovecs[iov_count] = .{ .base = body.ptr, .len = body.len };
                total_len += body.len;
                iov_count += 1;
            }

            ss.iov_count = iov_count;
            ss.total_len = total_len;
            ss.sent = 0;
            ss.mode = .pending;

            self.drainConnSend(conn, exchange) catch {
                self.endExchange(exchange);
                try self.close_q.push(conn);
            };
        }
    }

    fn releaseExchangeSendBody(self: *Pipeline, exchange: *Exchange) void {
        const ss = exchange.send;
        if (ss.body_buf) |b| self.allocator.free(b);
        ss.body_buf = null;
        self.queuePyBodyRelease(&ss.body_py);
        ss.body = null;
    }

    fn queuePyBodyRelease(self: *Pipeline, hold: *py.result.PyBodyHold) void {
        if (hold.owner == null and hold.buffer == null) return;
        self.py_body_release.append(self.allocator, hold.*) catch {
            self.py_ctx.gil.lock();
            defer self.py_ctx.gil.unlock();
            hold.deinit();
            return;
        };
        hold.* = .{};
    }

    fn drainPendingPyBodyReleases(self: *Pipeline) void {
        for (self.py_body_release.items) |*hold| hold.deinit();
        self.py_body_release.clearRetainingCapacity();
    }

    pub fn onRedisWritable(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        while (self.redis_send_offset < self.redis_send_len) {
            const buf = self.redis_send_buf[self.redis_send_offset..self.redis_send_len];
            const n = posix.send(fd, buf, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.redis_recv_state = .err;
                    return;
                },
            };
            if (n == 0) {
                self.redis_recv_state = .err;
                return;
            }
            self.redis_send_offset += n;
        }
        self.redis_send_len = 0;
        self.redis_send_offset = 0;
        self.redis_send_state = .idle;
        try self.backend.disarmWrite(fd);
    }

    pub fn onRedisReadable(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        while (self.redis_recv_len < self.redis_recv_buf.len) {
            const buf = self.redis_recv_buf[self.redis_recv_len..];
            const n = posix.recv(fd, buf, 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.redis_recv_state = .err;
                    return;
                },
            };
            if (n == 0) {
                self.redis_recv_state = .err;
                return;
            }
            self.redis_recv_len += n;
        }
        if (self.redis_recv_len > 0) self.redis_recv_state = .parsing;
    }

    fn stageRedis(self: *Pipeline) !void {
        if (self.redis_fd == null) return;

        if (self.redis_recv_state == .err) {
            try self.failRedisWaiters();
        }

        if (self.redis_recv_state == .parsing) {
            try self.parseRedisResponses();

            if (self.redis_in_flight > 0) {
                self.compactRedisRecv();
                self.redis_recv_state = .parsing;
                try self.armRedisRead();
            } else {
                self.redis_recv_state = .idle;
            }
        }

        const new_queries = self.redis_waiter_q.len - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try self.armRedisWrite();

            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .parsing;
                try self.armRedisRead();
            }
        }
    }

    fn parseRedisResponses(self: *Pipeline) !void {
        while (self.redis_in_flight > 0 and !self.redis_waiter_q.isEmpty()) {
            if (!try self.parseOneResp()) break;
        }
    }

    fn parseOneResp(self: *Pipeline) !bool {
        const data = self.redis_recv_buf[self.redis_parse_pos..self.redis_recv_len];
        const parsed = necro.redis.parseOne(data) catch return false;
        const msg = switch (parsed) {
            .incomplete => return false,
            .message => |m| m,
        };
        self.redis_parse_pos += msg.consumed;

        switch (msg.value) {
            .err => |err_msg| {
                var err_buf: [256:0]u8 = undefined;
                if (err_msg.len < err_buf.len) {
                    @memcpy(err_buf[0..err_msg.len], err_msg);
                    err_buf[err_msg.len] = 0;
                    ffi.errSetString(ffi.exc.RuntimeError(), err_buf[0..err_msg.len :0]);
                }
                try self.failHeadRedisWaiter();
                self.redis_in_flight -= 1;
                return true;
            },
            else => {},
        }

        const py_result: *ffi.PyObject = switch (msg.value) {
            .simple => |s| ffi.unicodeFromSlice(s.ptr, s.len) catch return false,
            .integer => |v| ffi.longFromLong(v) catch return false,
            .null_val => ffi.getNone(),
            .bulk => |b| blk: {
                const py_bytes = ffi.bytesNew(@intCast(b.len)) catch return false;
                const dest: [*]u8 = ffi.bytesAsSlice(py_bytes, b.len);
                @memcpy(dest[0..b.len], b);
                break :blk py_bytes;
            },
            .err => unreachable,
        };

        const exchange = self.redis_waiter_q.pop() orelse {
            ffi.decref(py_result);
            return true;
        };
        self.redis_in_flight -= 1;
        if (exchange == TOMBSTONE) {
            ffi.decref(py_result);
            return true;
        }
        self.exchange_timeout.bump(&exchange.timeout, self.cycle_now_ns);
        try self.py_ready_q.push(.{ .resume_coroutine = .{ .exchange = exchange, .result = py_result } });
        return true;
    }

    fn failHeadRedisWaiter(self: *Pipeline) !void {
        const exchange = self.redis_waiter_q.pop() orelse return;
        if (exchange == TOMBSTONE) return;
        exchange.dropAndCleanup();
        self.failExchangeWithStatus(exchange, .internal_server_error);
    }

    fn failRedisWaiters(self: *Pipeline) !void {
        while (!self.redis_waiter_q.isEmpty()) {
            try self.failHeadRedisWaiter();
        }
        self.redis_recv_state = .idle;
        self.redis_send_state = .idle;
        self.redis_in_flight = 0;
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
        log.info("redis socket fd={d}", .{fd});
    }

    pub fn setTlsContext(self: *Pipeline, tctx: *tls.TlsContext) void {
        self.tls_ctx = tctx;
    }

    pub fn onPgWritable(self: *Pipeline, pg: *PgConn) !void {
        while (pg.send_offset < pg.send_len) {
            const buf = pg.send_buf[pg.send_offset..pg.send_len];
            const n = posix.send(pg.fd, buf, 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    pg.recv_state = .err;
                    return;
                },
            };
            if (n == 0) {
                pg.recv_state = .err;
                return;
            }
            pg.send_offset += n;
        }
        pg.send_len = 0;
        pg.send_offset = 0;
        pg.send_state = .idle;
        try self.backend.disarmWrite(pg.fd);
    }

    pub fn onPgReadable(_: *Pipeline, pg: *PgConn) !void {
        var transport = &(pg.transport orelse return);
        while (true) {
            const w = transport.writable() catch {
                pg.recv_state = .err;
                return;
            };
            const n = posix.recv(pg.fd, w.slice, 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    pg.recv_state = .err;
                    return;
                },
            };
            if (n == 0) {
                pg.recv_state = .err;
                return;
            }
            transport.noteReceived(n);
        }
        if (transport.used_len > 0) pg.recv_state = .parsing;
    }

    fn stagePostgres(self: *Pipeline) !void {
        if (self.pg_conn == null) return;

        if (self.pg_conn) |*pg| {
            if (pg.recv_state == .err) {
                try self.failPgConnWaiters(pg);
            }

            if (pg.recv_state == .parsing) {
                try self.parsePgConnResponses(pg);
                _ = (pg.transport orelse return).consumeParsed();

                if (pg.in_flight > 0) {
                    pg.recv_state = .parsing;
                    try self.armPgRead(pg);
                } else {
                    pg.recv_state = .idle;
                }
            }

            const new_queries = pg.waiter_q.items.len - pg.in_flight;
            if (new_queries > 0 and pg.send_state == .idle and pg.send_len > 0) {
                const sync = necro_pg.wire.encodeSync(pg.send_buf[pg.send_len..]);
                pg.send_len += sync.len;
                pg.in_flight += new_queries;
                try pg.waiter_q.pushBatch(@intCast(new_queries));
                pg.send_state = .sending;
                try self.armPgWrite(pg);
                if (pg.recv_state == .idle) {
                    pg.recv_state = .parsing;
                    try self.armPgRead(pg);
                }
            }

            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try self.armPgWrite(pg);
            }
        }
    }

    fn wrapPgRowResult(exchange: *Exchange, result_obj: *ffi.PyObject) ffi.PythonError!*ffi.PyObject {
        if (exchange.io == .pg) {
            if (exchange.io.pg.model_cls) |model_cls| {
                if (necro_pg.row.isRow(result_obj)) {
                    errdefer ffi.decref(result_obj);
                    const model_obj = try ffi.callMethodOneArg(model_cls, "_necro_from_row", result_obj);
                    ffi.decref(result_obj);
                    return model_obj;
                }
            }
        }
        return result_obj;
    }

    const CompletedQuery = struct { exchange: *Exchange, result: *ffi.PyObject };

    noinline fn parsePgConnResponses(self: *Pipeline, pg: *PgConn) !void {
        var transport = &(pg.transport orelse return);
        var completed: [aio.BATCH_QUEUE_CAPACITY]CompletedQuery = undefined;
        var completed_count: usize = 0;

        var py_result: ?*ffi.PyObject = null;
        var py_list: ?*ffi.PyObject = null;
        var query_save_pos = transport.parseOffset();
        var scratch: [65536]u8 = undefined;

        while (pg.waiter_q.peek()) |slot_ptr| {
            const head = slot_ptr.*;
            const message = pg_stream.nextMessage(transport, &scratch, transport.parseOffset()) catch |err| switch (err) {
                error.MessageTooLarge => {
                    if (py_result) |r| ffi.decref(r);
                    if (py_list) |l| ffi.decref(l);
                    try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres message exceeds transport ring capacity");
                    return;
                },
                else => return err,
            };
            if (message == null) {
                transport.setParseOffset(query_save_pos);
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const msg = message.?;
            transport.setParseOffset(transport.parseOffset() + msg.total_len);

            if (msg.header.tag == necro_pg.wire.BackendTag.ready_for_query) {
                query_save_pos = transport.parseOffset();
            }

            const head_stmt_idx: u16 = if (head == TOMBSTONE)
                (pg.stmt_idx_q.peek() orelse {
                    try self.failPgConnWaitersWithStatus(
                        pg,
                        .internal_server_error,
                        "Postgres stmt_idx accounting mismatch",
                    );
                    return;
                }).*
            else
                head.io.pg.stmt_idx;
            const stmt_entry = self.pg_stmt_cache.get(head_stmt_idx);
            const col_count: u16 =
                if (stmt_entry.described)
                    stmt_entry.col_count
                else
                    0;

            if (head == TOMBSTONE) {
                switch (msg.header.tag) {
                    necro_pg.wire.BackendTag.no_data => {
                        if (!stmt_entry.described) {
                            stmt_entry.col_count = 0;
                            stmt_entry.described = true;
                        }
                    },
                    necro_pg.wire.BackendTag.row_description => {
                        _ = try pg_stream.applyRowDescription(msg.payload, stmt_entry);
                    },
                    necro_pg.wire.BackendTag.command_complete => {
                        _ = pg.waiter_q.pop();
                        _ = pg.stmt_idx_q.pop();
                        pg.in_flight -= 1;
                        try pg.waiter_q.completeOne();
                        query_save_pos = transport.parseOffset();
                    },
                    necro_pg.wire.BackendTag.error_response => {
                        if (py_list) |l| ffi.decref(l);
                        if (py_result) |r| ffi.decref(r);
                        py_list = null;
                        py_result = null;
                        try self.failPgBatchOnError(pg, completed[0..completed_count]);
                        completed_count = 0;
                        query_save_pos = transport.parseOffset();
                    },
                    else => {},
                }
                continue;
            }

            const exchange = head;
            const pg_io = exchange.io.pg;

            switch (msg.header.tag) {
                necro_pg.wire.BackendTag.parse_complete, necro_pg.wire.BackendTag.bind_complete => continue,
                necro_pg.wire.BackendTag.no_data => {
                    if (!stmt_entry.described) {
                        stmt_entry.col_count = 0;
                        stmt_entry.described = true;
                    }
                    continue;
                },
                necro_pg.wire.BackendTag.row_description => {
                    _ = pg_stream.applyRowDescription(msg.payload, stmt_entry) catch |err| switch (err) {
                        error.ProtocolViolation => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres protocol violation");
                            return;
                        },
                        else => return err,
                    };
                },
                necro_pg.wire.BackendTag.data_row => {
                    const raw_result = pg_stream.materializeDataRow(
                        self.allocator,
                        msg.payload,
                        &self.pg_stmt_cache,
                        pg_io.stmt_idx,
                        col_count,
                    ) catch |err| switch (err) {
                        error.ProtocolViolation => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(
                                pg,
                                .internal_server_error,
                                "Postgres protocol violation",
                            );
                            return;
                        },
                        error.MessageTooLarge, error.RowTooLarge => {
                            if (py_result) |r| ffi.decref(r);
                            if (py_list) |l| ffi.decref(l);
                            try self.failPgConnWaitersWithStatus(
                                pg,
                                .internal_server_error,
                                "Postgres row exceeds transport/result capacity",
                            );
                            return;
                        },
                        else => return err,
                    };
                    const result_obj = try wrapPgRowResult(exchange, raw_result);

                    if (pg_io.mode == .fetch_one) {
                        if (py_result == null) py_result = result_obj else ffi.decref(result_obj);
                    } else if (pg_io.mode == .fetch_all) {
                        if (py_list == null) py_list = try ffi.listNew(0);
                        try ffi.listAppend(py_list.?, result_obj);
                        ffi.decref(result_obj);
                    } else {
                        ffi.decref(result_obj);
                    }
                },
                necro_pg.wire.BackendTag.command_complete => {
                    if (pg_io.mode == .execute) {
                        const count = pg_stream.parseCommandCompleteCount(msg.payload);
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (pg_io.mode == .fetch_all)
                        py_list orelse try ffi.listNew(0)
                    else
                        py_result orelse ffi.getNone();

                    completed[completed_count] = .{ .exchange = exchange, .result = final_result };
                    completed_count += 1;
                    _ = pg.waiter_q.pop();
                    _ = pg.stmt_idx_q.pop();
                    pg.in_flight -= 1;
                    try pg.waiter_q.completeOne();
                    query_save_pos = transport.parseOffset();
                    py_result = null;
                    py_list = null;
                },
                necro_pg.wire.BackendTag.error_response => {
                    if (py_list) |l| ffi.decref(l);
                    if (py_result) |r| ffi.decref(r);
                    py_list = null;
                    py_result = null;
                    try self.failPgBatchOnError(pg, completed[0..completed_count]);
                    completed_count = 0;
                    query_save_pos = transport.parseOffset();
                },
                else => continue,
            }
        }

        for (completed[0..completed_count]) |cq| {
            self.exchange_timeout.bump(
                &cq.exchange.timeout,
                self.cycle_now_ns,
            );
            try self.py_ready_q.push(.{ .resume_coroutine = .{
                .exchange = cq.exchange,
                .result = cq.result,
            } });
        }
    }

    fn failExchangeWithStatus(self: *Pipeline, exchange: *Exchange, status: std.http.Status) void {
        self.send_q.push(.{
            .exchange = exchange,
            .source = .{ .native = http.response.Response.init(status) },
        }) catch {
            self.endExchange(exchange);
        };
    }

    fn failPgConnWaiters(self: *Pipeline, pg: *PgConn) !void {
        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, null);
    }

    fn failPgConnWaitersWithStatus(self: *Pipeline, pg: *PgConn, status: std.http.Status, body: ?[]const u8) !void {
        while (!pg.waiter_q.isEmpty()) {
            const exchange = pg.waiter_q.pop() orelse break;
            _ = pg.stmt_idx_q.pop();
            if (exchange == TOMBSTONE) continue;
            exchange.dropAndCleanup();
            if (body) |msg| {
                var resp = http.response.Response.init(status);
                resp.addHeader("Content-Type", "text/plain");
                resp.body = msg;
                self.send_q.push(.{
                    .exchange = exchange,
                    .source = .{ .native = resp },
                }) catch {
                    self.endExchange(exchange);
                };
            } else {
                self.failExchangeWithStatus(exchange, status);
            }
        }
        pg.recv_state = .idle;
        pg.send_state = .idle;
        pg.in_flight = 0;
        if (pg.transport) |*t| t.clear();
        pg.waiter_q.clear();
        pg.stmt_idx_q.clear();
    }

    fn failPgBatchOnError(self: *Pipeline, pg: *PgConn, completed: []const CompletedQuery) !void {
        const failed_in_batch = pg.waiter_q.remaining();
        if (failed_in_batch == 0 or pg.waiter_q.popBatch() == null) {
            for (completed) |cq| {
                ffi.decref(cq.result);
                cq.exchange.dropAndCleanup();
                self.failExchangeWithStatus(cq.exchange, .internal_server_error);
            }
            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
            return;
        }

        for (0..failed_in_batch) |_| {
            const exchange = pg.waiter_q.pop() orelse {
                for (completed) |cq| {
                    ffi.decref(cq.result);
                    cq.exchange.dropAndCleanup();
                    self.failExchangeWithStatus(cq.exchange, .internal_server_error);
                }
                try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                return;
            };
            _ = pg.stmt_idx_q.pop();
            pg.in_flight -= 1;
            if (exchange == TOMBSTONE) continue;
            exchange.dropAndCleanup();
            self.failExchangeWithStatus(exchange, .internal_server_error);
        }

        for (completed) |cq| {
            self.exchange_timeout.bump(&cq.exchange.timeout, self.cycle_now_ns);
            try self.py_ready_q.push(.{ .resume_coroutine = .{ .exchange = cq.exchange, .result = cq.result } });
        }
    }

    fn anyPgNeedsGil(self: *Pipeline) bool {
        if (self.pg_conn) |pg| {
            if (pg.recv_state == .parsing or pg.recv_state == .err) return true;
        }
        return false;
    }

    pub fn setPgConn(self: *Pipeline, fd: posix.socket_t) !void {
        if (self.pg_conn != null) return error.PgConnAlreadySet;

        const send_buf = try self.allocator.alloc(u8, PG_SEND_BUF_SIZE);
        errdefer self.allocator.free(send_buf);
        const transport = try Ring.init(self.allocator);
        self.pg_conn = .{
            .fd = fd,
            .send_token = .{ .tag = .pg_send },
            .recv_token = .{ .tag = .pg_recv },
            .send_buf = send_buf,
            .transport = transport,
        };
        log.info("postgres: connection fd={d}", .{fd});
    }

    fn startListening(self: *Pipeline, listen_fd: posix.socket_t) !void {
        self.listen_fd = listen_fd;
        self.accept_token = .{ .tag = .accept };
        try self.backend.arm(listen_fd, .read, @ptrCast(&self.accept_token));
    }

    fn classifyEvent(self: *Pipeline, event: sys.Event) !void {
        if (event.is_wake) return;
        const token: *aio.Token = @ptrCast(@alignCast(event.token));
        switch (token.tag) {
            .accept => try self.onAcceptable(),
            .conn_recv => {
                const conn: *Conn = @alignCast(@fieldParentPtr("recv_token", token));
                if (event.eof) {
                    try self.close_q.push(conn);
                } else {
                    try self.recv_q.push(event);
                }
            },
            .conn_send => {
                const conn: *Conn = @alignCast(@fieldParentPtr("send_token", token));
                if (event.eof) {
                    try self.close_q.push(conn);
                } else {
                    try self.send_ev_q.push(event);
                }
            },
            .redis_send => try self.onRedisWritable(),
            .redis_recv => try self.onRedisReadable(),
            .pg_send => {
                const pg: *PgConn = @fieldParentPtr("send_token", token);
                try self.onPgWritable(pg);
            },
            .pg_recv => {
                const pg: *PgConn = @fieldParentPtr("recv_token", token);
                try self.onPgReadable(pg);
            },
        }
    }

    fn armConnRead(self: *Pipeline, conn: *Conn) !void {
        try self.backend.arm(conn.fd, .read, @ptrCast(&conn.recv_token));
    }

    fn armConnWrite(self: *Pipeline, conn: *Conn) !void {
        try self.backend.arm(conn.fd, .write, @ptrCast(&conn.send_token));
    }

    fn armRedisRead(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        try self.backend.arm(fd, .read, @ptrCast(&self.redis_recv_token));
    }

    fn armRedisWrite(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        try self.backend.arm(fd, .write, @ptrCast(&self.redis_send_token));
    }

    fn armPgRead(self: *Pipeline, pg: *PgConn) !void {
        try self.backend.arm(pg.fd, .read, @ptrCast(&pg.recv_token));
    }

    fn armPgWrite(self: *Pipeline, pg: *PgConn) !void {
        try self.backend.arm(pg.fd, .write, @ptrCast(&pg.send_token));
    }

    fn stageClose(self: *Pipeline) void {
        while (self.close_q.pop()) |conn| {
            if (conn.fd < 0) continue;
            if (conn.tls) |h| {
                h.deinit();
                self.allocator.destroy(h);
                conn.tls = null;
            }
            if (conn.current) |exchange| {
                self.endExchange(exchange);
            }
            std.debug.assert(conn.current == null);
            self.idle.remove(&conn.idle);
            self.backend.disarm(conn.fd);
            posix.close(conn.fd);
            conn.fd = -1;
            self.conns.release(conn);
        }
    }
};
