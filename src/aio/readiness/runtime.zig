//! Staged event-driven pipeline.
//!
//! DAG:
//!   [kernel recv] → ParseTask → HandleTask ─┬→ SendTask → [kernel sendv] → recv
//!                                            └→ RedisTask ··· → SendTask

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const ring = @import("ring.zig");
const RecvPool = ring.RecvPool;
const Ring = ring.Ring;
const dispatch = @import("dispatch.zig");
const necro = @import("necro");
const py = necro.py;
const aio = necro.aio;
const http = necro.http;
const necro_pg = necro.pg;
const ffi = py.ffi;
const driver = py.driver;
const core = necro.core;
const metrics = core.metrics;
const backend_metrics = @import("metrics.zig");
const instant = metrics.instant;
const elapsedNs = metrics.elapsedNs;
const SmallPool = core.Pool(core.SmallSlab);
const BigPool = core.RefCountedPool(core.BigSlab);
const pg_stream = necro_pg.stream.Stream(Ring);

const log = std.log.scoped(.@"necro/aio/readiness/runtime");

const MAX_IOVECS = 4;
const RECV_BUFFER_COUNT = 1024;
const SMALL_POOL_COUNT: u16 = 1024;
const BIG_POOL_COUNT: u16 = 1536;

pub const Conn = struct {
    fd: posix.socket_t = undefined,
    lease: core.Lease = undefined,
    recv: Ring = .{},
    recv_slice: []u8 = &.{},

    head_parser: std.http.HeadParser = .{},
    head_fed: usize = 0,

    req_slab: ?core.Lease = null,
    req_keepalive: bool = true,

    recv_token: aio.Token = .{ .tag = .conn_recv },
    send_token: aio.Token = .{ .tag = .conn_send },

    send_hdr: [128]u8 = undefined,
    send_iovecs: [4]posix.iovec_const = undefined,
    send_iov_count: usize = 0,
    send_total_len: usize = 0,
    send_sent: usize = 0,
    send_body: ?[]const u8 = null,
    send_body_lease: ?core.Lease = null,
    send_body_py: driver.PyBodyHold = .{},
    send_mode: enum { idle, pending } = .idle,
    send_close_on_done: bool = false,

    idle: aio.IdleList.Node = .{},

    fn resetRecv(self: *Conn, http_recv_pool: *RecvPool) !void {
        self.recv.clear();
        self.head_parser = .{};
        self.head_fed = 0;
        const w = try self.recv.writable(http_recv_pool);
        self.recv_slice = w.slice;
    }
};

pub const PgConn = struct {
    fd: posix.socket_t = undefined,
    send_token: aio.Token = .{ .tag = .pg_send },
    recv_token: aio.Token = .{ .tag = .pg_recv },
    send_len: usize = 0,
    send_offset: usize = 0,
    send_state: enum { idle, sending } = .idle,
    recv_state: enum { idle, receiving, parsing, err } = .idle,
    in_flight: usize = 0,
    send_buf: []u8 = &.{},
    send_slab: ?core.Lease = null,
    waiter_q: core.BatchQueue(aio.tasks.PgWaiter, aio.BATCH_QUEUE_CAPACITY) = .{},
    prepared: [necro_pg.stmt.STMT_CACHE_CAPACITY]bool = .{false} ** necro_pg.stmt.STMT_CACHE_CAPACITY,
    transport: Ring = .{},
};

pub const Pipeline = struct {
    backend: sys.Backend,
    conns: *core.Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_token: aio.Token = .{ .tag = .accept },
    wake_token: aio.Token = .{ .tag = .wake },
    router: *const http.Router = undefined,
    py_ctx: *driver.PyContext = undefined,

    parse_q: core.Queue(aio.tasks.ParseTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    handle_q: core.Queue(aio.tasks.HandleTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    send_q: core.Queue(http.send.SendTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    close_q: core.Queue(core.Lease, aio.BATCH_QUEUE_CAPACITY) = .{},
    py_ready_q: core.Queue(aio.tasks.PyReadyTask, aio.BATCH_QUEUE_CAPACITY) = .{},

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
    redis_recv_state: enum { idle, receiving, parsing, err } = .idle,
    redis_waiter_q: core.Queue(aio.tasks.RedisWaiter, aio.BATCH_QUEUE_CAPACITY) = .{},
    redis_in_flight: usize = 0,

    pg_conn: ?PgConn = null,

    pg_stmt_cache: necro_pg.stmt.Cache = .{},
    http_recv_pool: RecvPool,
    pg_transport_pool: RecvPool,
    small_pool: SmallPool,
    big_pool: BigPool,
    py_body_release: std.ArrayListUnmanaged(driver.PyBodyHold) = .{},

    idle: aio.IdleList = .{},
    cycle_now_ns: i64 = 0,

    stats: metrics.Stats = .{},
    backend_stats: backend_metrics.Metrics = .{},
    pg_wire_ns: u64 = 0,

    pub fn init(self: *Pipeline, allocator: std.mem.Allocator, conns: *core.Pool(Conn), entries: u16, router: *const http.Router, py_ctx: *driver.PyContext, idle_ms: i64) !void {
        var backend = try sys.Backend.init(allocator, entries);
        errdefer backend.deinit(allocator);

        var http_recv_pool = try RecvPool.init(allocator, RECV_BUFFER_COUNT);
        errdefer http_recv_pool.deinit();

        var pg_transport_pool = try RecvPool.init(allocator, RECV_BUFFER_COUNT);
        errdefer pg_transport_pool.deinit();

        var small_pool = try SmallPool.init(allocator, SMALL_POOL_COUNT);
        errdefer small_pool.deinit();

        var big_pool = try BigPool.init(allocator, BIG_POOL_COUNT);
        errdefer big_pool.deinit();

        self.* = .{
            .backend = backend,
            .conns = conns,
            .allocator = allocator,
            .router = router,
            .py_ctx = py_ctx,
            .http_recv_pool = http_recv_pool,
            .pg_transport_pool = pg_transport_pool,
            .small_pool = small_pool,
            .big_pool = big_pool,
        };
        self.idle.ms = idle_ms;
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        if (self.pg_conn) |*pg| {
            if (pg.send_slab) |l| self.big_pool.release(l);
            pg.transport.deinit(&self.pg_transport_pool);
        }
        self.http_recv_pool.deinit();
        self.pg_transport_pool.deinit();
        self.small_pool.deinit();
        self.big_pool.deinit();
        self.py_body_release.deinit(allocator);
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        try dispatch.start(self, listen_fd);
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
        const m = comptime metrics.enabled;
        const t0 = if (m) instant() else {};

        const timeout_ns: ?i64 = if (wait_nr == 0) null else blk: {
            const deadline = self.idle.nextDeadlineNs() orelse break :blk null;
            const now = std.time.nanoTimestamp();
            const remaining: i64 = @intCast(@max(@as(i128, 0), deadline - now));
            break :blk remaining;
        };
        const events = try self.backend.wait(wait_nr, timeout_ns);
        if (wait_nr == 0 and events.len == 0) return false;
        const t_io = if (m) instant() else {};

        self.cycle_now_ns = @intCast(std.time.nanoTimestamp());
        http.headers.refreshCommonResponseHeaders(@divTrunc(self.cycle_now_ns, std.time.ns_per_s));

        while (self.idle.expireOne(self.cycle_now_ns)) |n| {
            const conn: *Conn = @fieldParentPtr("idle", n);
            try self.close_q.push(conn.lease);
        }

        self.backend_stats.recordBatchSize(events.len);

        for (events) |event| {
            try dispatch.classifyEvent(self, event);
        }
        const t_classify = if (m) instant() else {};

        try self.stageParse();
        const t_parse = if (m) instant() else {};

        const http_requests = if (m) self.handle_q.len else 0;
        try self.stageHandlePrep();
        const t_handle_prep = if (m) instant() else {};

        const py_ctx = self.py_ctx;
        const need_gil = !self.py_ready_q.isEmpty() or
            self.redis_recv_state == .parsing or
            self.redis_recv_state == .err or
            self.anyPgNeedsGil() or
            self.py_body_release.items.len > 0;
        if (need_gil) py_ctx.gil.lock();
        defer if (need_gil) py_ctx.gil.unlock();

        try self.drainPythonReady();
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

        self.stats.cycles += 1;
        self.stats.completions += events.len;
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
            if (self.stats.cycles % 10000 == 0) {
                self.stats.dump();
                self.backend_stats.dump();
            }
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
            const lease = self.conns.borrow() catch {
                posix.close(fd);
                continue;
            };
            const conn = self.conns.get(lease);
            conn.* = .{
                .fd = fd,
                .lease = lease,
                .recv_token = .{ .tag = .conn_recv },
                .send_token = .{ .tag = .conn_send },
            };
            conn.resetRecv(&self.http_recv_pool) catch {
                posix.close(fd);
                self.conns.release(lease);
                continue;
            };
            dispatch.armConnRead(self, conn) catch {
                posix.close(fd);
                conn.recv.deinit(&self.http_recv_pool);
                self.conns.release(lease);
                continue;
            };
            self.idle.append(&conn.idle, self.cycle_now_ns);
        }
    }

    pub fn onConnReadable(self: *Pipeline, token: *aio.Token, eof: bool) !void {
        const conn: *Conn = @fieldParentPtr("recv_token", token);
        const index = conn.lease;

        if (eof) {
            try self.close_q.push(index);
            return;
        }

        var received_any = false;
        while (true) {
            const n = posix.recv(conn.fd, conn.recv_slice, 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    try self.close_q.push(index);
                    return;
                },
            };
            if (n == 0) {
                try self.close_q.push(index);
                return;
            }
            received_any = true;
            conn.recv.noteReceived(n);
            const w = try conn.recv.writable(&self.http_recv_pool);
            conn.recv_slice = w.slice;
        }
        if (received_any) self.idle.bump(&conn.idle, self.cycle_now_ns);
        try self.parse_q.push(.{ .conn = index });
    }

    pub fn onConnWritable(self: *Pipeline, token: *aio.Token) !void {
        const conn: *Conn = @fieldParentPtr("send_token", token);
        if (conn.send_mode == .idle) return;
        try self.drainConnSend(conn);
    }

    fn drainConnSend(self: *Pipeline, conn: *Conn) !void {
        while (conn.send_sent < conn.send_total_len) {
            const n = posix.writev(conn.fd, conn.send_iovecs[0..conn.send_iov_count]) catch |err| switch (err) {
                error.WouldBlock => {
                    try dispatch.armConnWrite(self, conn);
                    return;
                },
                else => return err,
            };
            if (n == 0) return error.ConnectionReset;
            conn.send_sent += n;
            if (conn.send_sent < conn.send_total_len) {
                http.send.advanceIovecs(&conn.send_iovecs, &conn.send_iov_count, n);
            }
        }

        conn.send_mode = .idle;
        conn.send_sent = 0;
        conn.send_total_len = 0;
        conn.send_iov_count = 0;
        self.releaseConnSendBody(conn);

        if (conn.send_close_on_done) {
            conn.send_close_on_done = false;
            try self.close_q.push(conn.lease);
            return;
        }

        try conn.resetRecv(&self.http_recv_pool);
        self.idle.bump(&conn.idle, self.cycle_now_ns);
    }

    fn stageParse(self: *Pipeline) !void {
        while (self.parse_q.pop()) |pt| {
            const conn = self.conns.get(pt.conn);
            const data = conn.recv.usedMut();

            const new_bytes = data[conn.head_fed..];
            const consumed = conn.head_parser.feed(new_bytes);
            conn.head_fed += consumed;

            if (conn.head_parser.state != .finished) {
                const w = conn.recv.writable(&self.http_recv_pool) catch {
                    try self.close_q.push(pt.conn);
                    continue;
                };
                conn.recv_slice = w.slice;
                continue;
            }

            const header_end = conn.head_fed;
            const max_header = core.SmallSlab.SIZE - aio.tasks.HandleTask.DATA_OFFSET;
            if (header_end > max_header) {
                try self.send_q.push(http.send.makeErrorSend(pt.conn, .bad_request));
                continue;
            }
            const slab_lease = self.small_pool.borrow() catch {
                try self.send_q.push(http.send.makeErrorSend(pt.conn, .service_unavailable));
                continue;
            };
            const slab = self.small_pool.get(slab_lease);
            @memcpy(slab.data[aio.tasks.HandleTask.DATA_OFFSET .. aio.tasks.HandleTask.DATA_OFFSET + header_end], data[0..header_end]);
            const req = http.parser.parse(slab.data[aio.tasks.HandleTask.DATA_OFFSET .. aio.tasks.HandleTask.DATA_OFFSET + header_end]) catch {
                self.small_pool.release(slab_lease);
                try self.send_q.push(http.send.makeErrorSend(pt.conn, .bad_request));
                continue;
            };
            const content_length = req.content_length orelse 0;
            if (content_length > 0) {
                const body_received = data.len - header_end;
                if (body_received < content_length) {
                    self.small_pool.release(slab_lease);
                    const w = conn.recv.writable(&self.http_recv_pool) catch {
                        try self.close_q.push(pt.conn);
                        continue;
                    };
                    conn.recv_slice = w.slice;
                    continue;
                }
                @memcpy(slab.data[aio.tasks.HandleTask.DATA_OFFSET + header_end .. aio.tasks.HandleTask.DATA_OFFSET + header_end + content_length], data[header_end .. header_end + content_length]);
            }

            aio.tasks.HandleTask.writeMeta(slab, &req, header_end, content_length);
            conn.req_slab = slab_lease;
            conn.req_keepalive = req.keepalive;
            try self.handle_q.push(.{
                .conn = pt.conn,
                .slab = slab_lease,
            });
        }
    }

    fn stageHandlePrep(self: *Pipeline) !void {
        while (self.handle_q.pop()) |ht| {
            const slab = self.small_pool.get(ht.slab);
            const meta = aio.tasks.HandleTask.getMeta(slab);
            const m = meta.method orelse .GET;
            const u = meta.uri.slice(slab);

            switch (self.router.match(m, u)) {
                .found => |found| {
                    const py_id = found.handler_id;
                    const kq_flags = py.module.getHandlerFlags(self.py_ctx.necro_module, py_id);
                    var task = aio.tasks.PythonHandleTask{
                        .conn = ht.conn,
                        .py_id = py_id,
                        .kind = if (kq_flags.no_args) .no_args else if (kq_flags.needs_params) .params_only else .request,
                        .is_async = kq_flags.is_async,
                        .param_count = @intCast(found.param_count),
                    };
                    @memcpy(task.params[0..found.param_count], found.params[0..found.param_count]);
                    if (task.kind == .request) {
                        aio.tasks.HandleTask.writeParams(self.small_pool.get(ht.slab), found.params[0..found.param_count]);
                        task.request_slab = ht.slab;
                    }
                    try self.py_ready_q.push(.{ .invoke = task });
                },
                .not_found => try self.send_q.push(http.send.makeErrorSend(ht.conn, .not_found)),
                .method_not_allowed => {
                    var r = http.response.Response.init(.method_not_allowed);
                    r.body = "Method Not Allowed";
                    try self.send_q.push(http.send.makeResponseSend(ht.conn, r));
                },
            }
        }
    }

    fn drainPythonReady(self: *Pipeline) !void {
        const py_ctx = self.py_ctx;

        var invoke_metrics = driver.InvokeMetrics{};
        while (self.py_ready_q.pop()) |popped| {
            var task = popped;
            switch (task) {
                .invoke => |*invoke| try aio.tasks.runInvoke(self, py_ctx, invoke, &invoke_metrics),
                .redis_resume => |ready| try aio.tasks.runRedisResume(self, py_ctx, ready),
                .pg_resume => |ready| try aio.tasks.runPgResume(self, py_ctx, ready),
            }
        }
        self.stats.accumInvokeMetrics(&invoke_metrics);
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
            const conn = self.conns.get(st.conn);

            var prepared = switch (st.source) {
                .native => |resp| driver.Prepared.fromResponse(resp),
                .python => |py_result| blk: {
                    defer ffi.decref(py_result);
                    break :blk driver.prepare(py_result, &self.small_pool) catch {
                        if (ffi.errOccurred()) ffi.errPrint();
                        break :blk driver.Prepared.fromResponse(http.response.Response.init(.internal_server_error));
                    };
                },
            };
            defer prepared.deinit();

            const resp = &prepared.response;
            const status_line = http.response.statusLine(resp.status) catch {
                try self.close_q.push(st.conn);
                continue;
            };

            const will_keep_alive = st.keep_alive and conn.req_keepalive;
            const hdr_len = http.response.writeResponseHeaders(conn.send_hdr[0..], resp, will_keep_alive);
            conn.send_close_on_done = !will_keep_alive;

            if (conn.send_body_lease) |l| self.small_pool.release(l);
            conn.send_body_py.deinit();
            conn.send_body = resp.body;
            conn.send_body_lease = if (prepared.body_pool != null) prepared.body_lease else null;
            conn.send_body_py = prepared.py_body;
            prepared.body_pool = null;
            prepared.py_body = .{};

            var iov_count: usize = 0;
            var total_len: usize = 0;
            conn.send_iovecs[iov_count] = .{ .base = status_line.ptr, .len = status_line.len };
            total_len += status_line.len;
            iov_count += 1;
            conn.send_iovecs[iov_count] = .{ .base = common.ptr, .len = common.len };
            total_len += common.len;
            iov_count += 1;
            conn.send_iovecs[iov_count] = .{ .base = &conn.send_hdr, .len = hdr_len };
            total_len += hdr_len;
            iov_count += 1;
            if (conn.send_body) |body| {
                conn.send_iovecs[iov_count] = .{ .base = body.ptr, .len = body.len };
                total_len += body.len;
                iov_count += 1;
            }

            conn.send_iov_count = iov_count;
            conn.send_total_len = total_len;
            conn.send_sent = 0;
            conn.send_mode = .pending;

            self.drainConnSend(conn) catch {
                try self.close_q.push(st.conn);
            };
        }
    }

    fn releaseConnSendBody(self: *Pipeline, conn: *Conn) void {
        if (conn.req_slab) |l| self.small_pool.release(l);
        conn.req_slab = null;
        if (conn.send_body_lease) |l| self.small_pool.release(l);
        conn.send_body_lease = null;
        self.queuePyBodyRelease(&conn.send_body_py);
        conn.send_body = null;
    }

    fn queuePyBodyRelease(self: *Pipeline, hold: *driver.PyBodyHold) void {
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
                self.redis_recv_state = .receiving;
                try dispatch.armRedisRead(self);
            } else {
                self.redis_recv_state = .idle;
            }
        }

        const new_queries = self.redis_waiter_q.len - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try dispatch.armRedisWrite(self);

            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .receiving;
                try dispatch.armRedisRead(self);
            }
        }
    }

    fn parseRedisResponses(self: *Pipeline) !void {
        while (self.redis_in_flight > 0 and !self.redis_waiter_q.isEmpty()) {}
    }

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

                var err_buf: [256:0]u8 = undefined;
                if (line.len < err_buf.len) {
                    @memcpy(err_buf[0..line.len], line);
                    err_buf[line.len] = 0;
                    ffi.errSetString(ffi.exc.RuntimeError(), err_buf[0..line.len :0]);
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

                const py_bytes = ffi.bytesNew(@intCast(payload_len)) catch return false;
                const dest: [*]u8 = ffi.bytesAsSlice(py_bytes, payload_len);
                @memcpy(dest[0..payload_len], data[crlf_pos + 2 ..][0..payload_len]);
                self.redis_parse_pos += total_needed;
                break :blk py_bytes;
            },
            else => return false,
        };

        const waiter = self.redis_waiter_q.pop() orelse return false;
        try self.py_ready_q.push(.{ .redis_resume = .{ .waiter = waiter, .result = py_result } });
        self.redis_in_flight -= 1;
        return true;
    }

    fn failHeadWaiter(self: *Pipeline) !void {
        const waiter = self.redis_waiter_q.pop() orelse return;
        ffi.decref(waiter.py_future);
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
    }

    fn failRedisWaiters(self: *Pipeline) !void {
        while (!self.redis_waiter_q.isEmpty()) {
            try self.failHeadWaiter();
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

    pub fn onPgReadable(self: *Pipeline, pg: *PgConn) !void {
        while (true) {
            const w = pg.transport.writable(&self.pg_transport_pool) catch {
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
            pg.transport.noteReceived(n);
            self.stats.pg_recv_ops += 1;
            self.stats.pg_recv_bytes += n;
        }
        if (pg.transport.used_len > 0) pg.recv_state = .parsing;
    }

    fn stagePostgres(self: *Pipeline) !void {
        self.pg_wire_ns = 0;
        if (self.pg_conn == null) return;

        if (self.pg_conn) |*pg| {
            if (pg.recv_state == .err) {
                try self.failPgConnWaiters(pg);
            }

            if (pg.recv_state == .parsing) {
                const t0 = try std.time.Instant.now();
                try self.parsePgConnResponses(pg);
                self.pg_wire_ns += (try std.time.Instant.now()).since(t0);
                _ = pg.transport.consumeParsed();

                if (pg.in_flight > 0) {
                    pg.recv_state = .receiving;
                    try dispatch.armPgRead(self, pg);
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
                try dispatch.armPgWrite(self, pg);
                if (pg.recv_state == .idle) {
                    pg.recv_state = .receiving;
                    try dispatch.armPgRead(self, pg);
                }
            }

            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try dispatch.armPgWrite(self, pg);
            }
        }
    }

    fn wrapPgRowResult(waiter: aio.tasks.PgWaiter, result_obj: *ffi.PyObject) ffi.PythonError!*ffi.PyObject {
        if (waiter.model_cls) |model_cls| {
            if (necro_pg.row.isRow(result_obj)) {
                errdefer ffi.decref(result_obj);
                const model_obj = try ffi.callMethodOneArg(model_cls, "_necro_from_row", result_obj);
                ffi.decref(result_obj);
                return model_obj;
            }
        }
        return result_obj;
    }

    fn parsePgConnResponses(self: *Pipeline, pg: *PgConn) !void {
        const CompletedQuery = struct { waiter: aio.tasks.PgWaiter, result: *ffi.PyObject };
        var completed: [aio.BATCH_QUEUE_CAPACITY]CompletedQuery = undefined;
        var completed_count: usize = 0;

        var py_result: ?*ffi.PyObject = null;
        var py_list: ?*ffi.PyObject = null;
        var query_save_pos = pg.transport.parseOffset();
        var scratch: [65536]u8 = undefined;

        while (pg.waiter_q.peek()) |waiter_ptr| {
            const waiter = waiter_ptr.*;
            const message = pg_stream.nextMessage(&pg.transport, &scratch, pg.transport.parseOffset()) catch |err| switch (err) {
                error.MessageTooLarge => {
                    if (py_result) |r| ffi.decref(r);
                    if (py_list) |l| ffi.decref(l);
                    try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres message exceeds transport ring capacity");
                    return;
                },
                else => return err,
            };
            if (message == null) {
                pg.transport.setParseOffset(query_save_pos);
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const msg = message.?;
            pg.transport.setParseOffset(pg.transport.parseOffset() + msg.total_len);

            if (msg.header.tag == necro_pg.wire.BackendTag.ready_for_query) {
                query_save_pos = pg.transport.parseOffset();
            }

            const stmt_entry = self.pg_stmt_cache.get(waiter.stmt_idx);
            const col_count: u16 = if (stmt_entry.described) stmt_entry.col_count else 0;

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
                        msg.payload,
                        &self.pg_stmt_cache,
                        waiter.stmt_idx,
                        col_count,
                        &self.big_pool,
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

                    if (waiter.mode == .fetch_one) {
                        if (py_result == null) py_result = result_obj else ffi.decref(result_obj);
                    } else if (waiter.mode == .fetch_all) {
                        if (py_list == null) py_list = try ffi.listNew(0);
                        try ffi.listAppend(py_list.?, result_obj);
                        ffi.decref(result_obj);
                    } else {
                        ffi.decref(result_obj);
                    }
                },
                necro_pg.wire.BackendTag.command_complete => {
                    if (waiter.mode == .execute) {
                        const count = pg_stream.parseCommandCompleteCount(msg.payload);
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (waiter.mode == .fetch_all)
                        py_list orelse try ffi.listNew(0)
                    else
                        py_result orelse ffi.getNone();

                    completed[completed_count] = .{ .waiter = waiter, .result = final_result };
                    completed_count += 1;
                    _ = pg.waiter_q.pop();
                    pg.in_flight -= 1;
                    try pg.waiter_q.completeOne();
                    py_result = null;
                    py_list = null;
                },
                necro_pg.wire.BackendTag.error_response => {
                    if (py_list) |l| ffi.decref(l);
                    if (py_result) |r| ffi.decref(r);
                    py_list = null;
                    py_result = null;

                    const failed_in_batch = pg.waiter_q.remaining();
                    if (failed_in_batch == 0 or pg.waiter_q.popBatch() == null) {
                        for (completed[0..completed_count]) |cq| {
                            ffi.decref(cq.result);
                            ffi.decref(cq.waiter.py_future);
                            ffi.xdecref(cq.waiter.model_cls);
                            ffi.coroutineClose(cq.waiter.py_coro);
                            ffi.decref(cq.waiter.py_coro);
                            try self.send_q.push(http.send.makeErrorSend(cq.waiter.conn, .internal_server_error));
                        }
                        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                        return;
                    }

                    for (0..failed_in_batch) |_| {
                        const failed_waiter = pg.waiter_q.pop() orelse {
                            for (completed[0..completed_count]) |cq| {
                                ffi.decref(cq.result);
                                ffi.decref(cq.waiter.py_future);
                                ffi.xdecref(cq.waiter.model_cls);
                                ffi.coroutineClose(cq.waiter.py_coro);
                                ffi.decref(cq.waiter.py_coro);
                                try self.send_q.push(http.send.makeErrorSend(cq.waiter.conn, .internal_server_error));
                            }
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres batch accounting mismatch");
                            return;
                        };
                        ffi.decref(failed_waiter.py_future);
                        ffi.xdecref(failed_waiter.model_cls);
                        ffi.coroutineClose(failed_waiter.py_coro);
                        ffi.decref(failed_waiter.py_coro);
                        try self.send_q.push(http.send.makeErrorSend(failed_waiter.conn, .internal_server_error));
                        pg.in_flight -= 1;
                    }

                    query_save_pos = pg.transport.parseOffset();

                    for (completed[0..completed_count]) |cq| {
                        try self.py_ready_q.push(.{ .pg_resume = .{ .waiter = cq.waiter, .result = cq.result } });
                    }
                    completed_count = 0;
                },
                else => continue,
            }
        }

        for (completed[0..completed_count]) |cq| {
            try self.py_ready_q.push(.{ .pg_resume = .{ .waiter = cq.waiter, .result = cq.result } });
        }
    }

    fn failPgConnForRecvPool(self: *Pipeline, pg: *PgConn) !void {
        const total = self.pg_transport_pool.items.len;
        const free = self.pg_transport_pool.free_len;
        log.warn(
            "postgres transport pool exhausted: fd={d} waiters={d} in_use={d}/{d} free={d}",
            .{ pg.fd, pg.waiter_q.items.len, total - free, total, free },
        );
        try self.failPgConnWaitersWithStatus(pg, .service_unavailable, "Postgres transport pool exhausted");
    }

    fn failPgConnWaiters(self: *Pipeline, pg: *PgConn) !void {
        try self.failPgConnWaitersWithStatus(pg, .internal_server_error, null);
    }

    fn failPgConnWaitersWithStatus(self: *Pipeline, pg: *PgConn, status: std.http.Status, body: ?[]const u8) !void {
        while (!pg.waiter_q.isEmpty()) {
            const waiter = pg.waiter_q.pop() orelse break;
            ffi.decref(waiter.py_future);
            ffi.xdecref(waiter.model_cls);
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            if (body) |msg| {
                var resp = http.response.Response.init(status);
                resp.addHeader("Content-Type", "text/plain");
                resp.body = msg;
                try self.send_q.push(http.send.makeResponseSend(waiter.conn, resp));
            } else {
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, status));
            }
        }
        pg.recv_state = .idle;
        pg.send_state = .idle;
        pg.in_flight = 0;
        pg.transport.clear();
        pg.waiter_q.clear();
    }

    pub fn matchPgSendToken(self: *Pipeline, token: *aio.Token) ?*PgConn {
        if (self.pg_conn) |*pg| {
            if (token == &pg.send_token) return pg;
        }
        return null;
    }

    pub fn matchPgRecvToken(self: *Pipeline, token: *aio.Token) ?*PgConn {
        if (self.pg_conn) |*pg| {
            if (token == &pg.recv_token) return pg;
        }
        return null;
    }

    fn anyPgNeedsGil(self: *Pipeline) bool {
        if (self.pg_conn) |pg| {
            if (pg.recv_state == .parsing or pg.recv_state == .err) return true;
        }
        return false;
    }

    fn totalPgWaiters(self: *Pipeline) usize {
        if (self.pg_conn) |pg| return pg.waiter_q.items.len;
        return 0;
    }

    pub fn setPgConn(self: *Pipeline, fd: posix.socket_t) !void {
        if (self.pg_conn != null) return error.PgConnAlreadySet;

        const lease = try self.big_pool.borrow();
        errdefer self.big_pool.release(lease);
        const body = self.big_pool.get(lease);
        self.pg_conn = .{
            .fd = fd,
            .send_token = .{ .tag = .pg_send },
            .recv_token = .{ .tag = .pg_recv },
            .send_slab = lease,
            .send_buf = body.data[0..],
        };
        log.info("postgres: connection fd={d}", .{fd});
    }

    fn stageClose(self: *Pipeline) void {
        while (self.close_q.pop()) |index| {
            const conn = self.conns.get(index);
            if (conn.fd < 0) continue;
            if (conn.req_slab) |l| self.small_pool.release(l);
            conn.req_slab = null;
            self.releaseConnSendBody(conn);
            self.idle.remove(&conn.idle);
            self.backend.disarm(conn.fd);
            posix.close(conn.fd);
            conn.fd = -1;
            conn.recv.deinit(&self.http_recv_pool);
            self.conns.release(index);
        }
    }
};

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
