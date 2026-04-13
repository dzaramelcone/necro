//! Staged event-driven pipeline.
//!
//! DAG:
//!   [kernel recv]
//!     └→ ParseTask
//!        └→ HandleTask (Python) ─┬→ SendTask → [kernel send/sendmsg_zc] → recv
//!                                └→ RedisTask ··· → SendTask

const std = @import("std");
const posix = std.posix;
const io_uring = @import("sys.zig");
const Completion = io_uring.Completion;
const necro = @import("necro");
const py = necro.py;
const aio = necro.aio;
const http = necro.http;
const ffi = py.ffi;
const driver = py.driver;
const core = necro.core;
const SmallPool = core.Pool(core.SmallSlab);
const BigPool = core.RefCountedPool(core.BigSlab);
const pg_stream = necro.pg.stream.Stream(@import("recv_queue.zig").Queue);
const metrics = necro.core.metrics;
const backend_metrics = @import("metrics.zig");
const uring_recv_group = @import("recv_group.zig");
const UringRecvGroup = uring_recv_group.Group;
const uring_recv_queue = @import("recv_queue.zig");
const UringRecvQueue = uring_recv_queue.Queue;

const log = std.log.scoped(.@"necro/aio/uring/runtime");

const MAX_IOVECS = 4;
const SEND_HDR_CAP = 128;
const HTTP_RECV_BUFFER_COUNT: u16 = 256;
const HTTP_RECV_BUFFER_SIZE: u32 = 16 * 1024;
const HTTP_RECV_GROUP_ID: u16 = 1;
const HTTP_RECV_MAX_BYTES: usize = 64 * 1024;

const HTTP_SEND_ZC_MIN_BYTES: usize = 4 * 1024;

const PG_RECV_BUFFER_COUNT = uring_recv_group.DEFAULT_BUFFER_COUNT;
const PG_RECV_BUFFER_SIZE = uring_recv_group.DEFAULT_BUFFER_SIZE;
const PG_RECV_GROUP_ID: u16 = 2;
const PG_RECV_MAX_BYTES = @as(usize, PG_RECV_BUFFER_SIZE) * @as(usize, PG_RECV_BUFFER_COUNT);

const SMALL_POOL_COUNT: u16 = 1024;
const BIG_POOL_COUNT: u16 = 1536;

pub const Conn = struct {
    fd: posix.socket_t = undefined,
    lease: core.Lease = undefined,
    recv_queue: UringRecvQueue = .{ .max_bytes = HTTP_RECV_MAX_BYTES },
    recv_armed: bool = false,
    parse_queued: bool = false,
    inflight_request_len: usize = 0,
    req_slab: ?core.Lease = null,
    req_keepalive: bool = true,

    head_parser: std.http.HeadParser = .{},
    head_fed: usize = 0,

    send_hdr: [SEND_HDR_CAP]u8 = undefined,
    send_iovecs: [MAX_IOVECS]posix.iovec_const = undefined,
    send_iov_count: usize = 0,
    send_msg: posix.msghdr_const = std.mem.zeroes(posix.msghdr_const),
    send_body: ?[]const u8 = null,
    send_body_lease: ?core.Lease = null,
    send_body_py: driver.PyBodyHold = .{},
    send_total_len: usize = 0,
    send_sent: usize = 0,
    send_mode: enum { idle, sendv, sendmsg_zc } = .idle,
    send_close_on_done: bool = false,
    zc_hold: ?ZcHold = null,
    zc_notif_pending: bool = false,
    close_after_notif: bool = false,

    idle: aio.IdleList.Node = .{},

    recv_token: aio.Token = .{ .tag = .conn_recv },
    send_token: aio.Token = .{ .tag = .conn_send },

    fn resetRecv(self: *Conn, group: *UringRecvGroup) void {
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

pub const PgConn = struct {
    fd: posix.socket_t = undefined,
    send_token: aio.Token = .{ .tag = .pg_send },
    recv_token: aio.Token = .{ .tag = .pg_recv },
    send_len: usize = 0,
    send_offset: usize = 0,
    send_state: enum { idle, sending } = .idle,
    recv_state: enum { idle, parsing, err } = .idle,
    recv_armed: bool = false,
    in_flight: usize = 0,
    send_buf: []u8 = &.{},
    send_slab: ?core.Lease = null,
    waiter_q: core.BatchQueue(aio.tasks.PgWaiter, aio.BATCH_QUEUE_CAPACITY) = .{},
    prepared: [necro.pg.stmt.STMT_CACHE_CAPACITY]bool = .{false} ** necro.pg.stmt.STMT_CACHE_CAPACITY,
    recv_queue: UringRecvQueue = .{ .max_bytes = PG_RECV_MAX_BYTES },
    fail_status: std.http.Status = .internal_server_error,
    fail_body: ?[]const u8 = null,
};

pub const Pipeline = struct {
    backend: io_uring.IoUring,
    conns: *core.Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_token: aio.Token = .{ .tag = .accept },
    accept_armed: bool = false,
    wake_fd: posix.fd_t = -1,
    wake_token: aio.Token = .{ .tag = .wake },
    wake_buf: [8]u8 = undefined,
    router: *const http.Router = undefined,
    py_ctx: *driver.PyContext = undefined,

    parse_q: core.Queue(aio.tasks.ParseTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    handle_q: core.Queue(aio.tasks.HandleTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    py_ready_q: core.Queue(aio.tasks.PyReadyTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    send_q: core.Queue(http.send.SendTask, aio.BATCH_QUEUE_CAPACITY) = .{},
    close_q: core.Queue(core.Lease, aio.BATCH_QUEUE_CAPACITY) = .{},
    py_body_release: std.ArrayListUnmanaged(driver.PyBodyHold) = .{},

    idle: aio.IdleList = .{},
    cycle_now_ns: i64 = 0,

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
    pg_wire_ns: u64 = 0,
    pg_stmt_cache: necro.pg.stmt.Cache = .{},
    http_recv_group: UringRecvGroup,
    pg_recv_group: UringRecvGroup,
    small_pool: SmallPool,
    big_pool: BigPool,

    stats: metrics.Stats = .{},
    backend_stats: backend_metrics.Metrics = .{},

    pub fn init(
        self: *Pipeline,
        allocator: std.mem.Allocator,
        conns: *core.Pool(Conn),
        entries: u16,
        router: *const http.Router,
        py_ctx: *driver.PyContext,
        idle_ms: i64,
    ) !void {
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
            .http_recv_group = http_recv_group,
            .pg_recv_group = pg_recv_group,
            .small_pool = small_pool,
            .big_pool = big_pool,
        };
        self.idle.ms = idle_ms;
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) !void {
        {
            self.py_ctx.gil.lock();
            defer self.py_ctx.gil.unlock();
            self.drainPendingPyBodyReleases();
        }
        var conn_iter = self.conns.iterator();
        while (conn_iter.next_ptr()) |conn| {
            conn.recv_queue.deinit(&self.http_recv_group);
        }
        if (self.pg_conn) |*pg| {
            if (pg.send_slab) |l| self.big_pool.release(l);
            pg.recv_queue.deinit(&self.pg_recv_group);
        }
        try self.http_recv_group.deinit();
        try self.pg_recv_group.deinit();
        self.small_pool.deinit();
        self.big_pool.deinit();
        self.py_body_release.deinit(allocator);
        if (self.wake_fd >= 0) posix.close(self.wake_fd);
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        self.listen_fd = listen_fd;
        self.accept_token = .{ .tag = .accept };
        try self.armAccept();

        self.wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        try self.submitWakeRecv();
    }

    fn submitWakeRecv(self: *Pipeline) !void {
        try self.backend.queue(&self.wake_token, .{
            .read = .{ .fd = self.wake_fd, .buffer = &self.wake_buf },
        });
    }

    pub fn wake(self: *Pipeline) void {
        const v: u64 = 1;
        _ = std.posix.write(self.wake_fd, std.mem.asBytes(&v)) catch {};
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
        try self.backend.publish();
        const completions = try self.backend.reap(wait_nr);
        if (wait_nr == 0 and completions.tokens.len == 0) return false;
        const t_io = if (m) instant() else {};

        self.cycle_now_ns = @intCast(std.time.nanoTimestamp());
        http.headers.refreshCommonResponseHeaders(@divTrunc(self.cycle_now_ns, std.time.ns_per_s));

        while (self.idle.expireOne(self.cycle_now_ns)) |n| {
            const conn: *Conn = @fieldParentPtr("idle", n);
            try self.close_q.push(conn.lease);
        }

        self.backend_stats.recordBatchSize(completions.tokens.len);

        for (completions.tokens, completions.completions) |token, completion| {
            try self.handleCompletion(token, completion);
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
            if (self.stats.cycles % 10000 == 0) {
                self.stats.dump();
                self.backend_stats.dump();
            }
        }

        return true;
    }

    pub fn onAccept(self: *Pipeline, completion: Completion) void {
        if (completion.result < 0) return;
        const client_fd: posix.socket_t = @intCast(completion.result);

        const lease = self.conns.borrow() catch {
            posix.close(client_fd);
            return;
        };
        const conn = self.conns.get(lease);
        conn.* = .{
            .fd = client_fd,
            .lease = lease,
            .recv_token = .{ .tag = .conn_recv },
            .send_token = .{ .tag = .conn_send },
        };
        conn.resetRecv(&self.http_recv_group);
        self.submitConnRecv(conn) catch {
            posix.close(client_fd);
            conn.recv_queue.clear(&self.http_recv_group);
            self.conns.release(lease);
            return;
        };
        self.idle.append(&conn.idle, self.cycle_now_ns);
    }

    pub fn onConnRecvCompletion(self: *Pipeline, token: *aio.Token, completion: Completion) !void {
        const conn: *Conn = @fieldParentPtr("recv_token", token);
        if (completion.result == 0) {
            try self.close_q.push(conn.lease);
            return;
        }
        if (completion.result < 0) {
            conn.recv_armed = completion.more;
            if (cqeErrno(completion.result) == .NOBUFS) {
                if (!conn.recv_armed) try self.submitConnRecv(conn);
                if (!conn.parse_queued and conn.recv_queue.queuedBytes() > conn.head_fed) {
                    conn.parse_queued = true;
                    try self.parse_q.push(.{ .conn = conn.lease });
                }
                return;
            }
            try self.close_q.push(conn.lease);
            return;
        }

        const lease = self.http_recv_group.take(completion) catch {
            try self.close_q.push(conn.lease);
            return;
        };
        conn.recv_queue.append(&self.http_recv_group, lease) catch |err| switch (err) {
            error.TransportQueueFull, error.TransportSegmentQueueFull => {
                self.http_recv_group.release(lease);
                try self.close_q.push(conn.lease);
                return;
            },
        };

        self.idle.bump(&conn.idle, self.cycle_now_ns);

        conn.recv_armed = completion.more;
        if (!conn.recv_armed) try self.submitConnRecv(conn);
        if (!conn.parse_queued) {
            conn.parse_queued = true;
            try self.parse_q.push(.{ .conn = conn.lease });
        }
    }

    pub fn onConnSendCompletion(self: *Pipeline, token: *aio.Token, completion: Completion) !void {
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
                self.conns.release(conn.lease);
            }
            return;
        }
        if (completion.result < 0) {
            try self.close_q.push(conn.lease);
            return;
        }
        if (conn.send_mode == .idle) return;

        const sent_now: usize = @intCast(completion.result);
        if (sent_now == 0) {
            try self.close_q.push(conn.lease);
            return;
        }

        conn.send_sent += sent_now;
        if (conn.send_sent < conn.send_total_len) {
            http.send.advanceIovecs(&conn.send_iovecs, &conn.send_iov_count, sent_now);
            if (conn.send_mode == .sendmsg_zc) conn.send_mode = .sendv;
            try self.submitConnSend(conn);
            return;
        }

        conn.send_mode = .idle;
        conn.send_total_len = 0;
        conn.send_sent = 0;
        conn.send_iov_count = 0;
        if (!conn.zc_notif_pending) self.releaseConnSendBody(conn);

        if (conn.send_close_on_done) {
            conn.send_close_on_done = false;
            if (conn.zc_notif_pending) {
                conn.close_after_notif = true;
            } else {
                try self.close_q.push(conn.lease);
            }
            return;
        }

        self.idle.bump(&conn.idle, self.cycle_now_ns);

        conn.recv_queue.setParseOffset(conn.inflight_request_len);
        _ = conn.recv_queue.consumeParsed(&self.http_recv_group);
        conn.inflight_request_len = 0;
        conn.head_parser = .{};
        conn.head_fed = 0;
        if (conn.recv_queue.queuedBytes() > 0) {
            if (!conn.parse_queued) {
                conn.parse_queued = true;
                try self.parse_q.push(.{ .conn = conn.lease });
            }
        } else if (!conn.recv_armed) {
            try self.submitConnRecv(conn);
        }
    }

    fn stageParse(self: *Pipeline) !void {
        while (self.parse_q.pop()) |pt| {
            const conn = self.conns.get(pt.conn);
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
            conn.recv_queue.copyInto(0, slab.data[aio.tasks.HandleTask.DATA_OFFSET .. aio.tasks.HandleTask.DATA_OFFSET + header_end]);
            const req = http.parser.parse(slab.data[aio.tasks.HandleTask.DATA_OFFSET .. aio.tasks.HandleTask.DATA_OFFSET + header_end]) catch {
                self.small_pool.release(slab_lease);
                try self.send_q.push(http.send.makeErrorSend(pt.conn, .bad_request));
                continue;
            };
            const content_length = req.content_length orelse 0;
            if (content_length > 0) {
                const body_received = conn.recv_queue.queuedBytes() - header_end;
                if (body_received < content_length) {
                    self.small_pool.release(slab_lease);
                    if (!conn.recv_armed) try self.submitConnRecv(conn);
                    continue;
                }
            }

            aio.tasks.HandleTask.writeMeta(slab, &req, header_end, content_length);
            conn.inflight_request_len = header_end + content_length;
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
                .found => |found| try self.dispatchMatchedRouteNoGil(ht, found),
                .not_found => try self.send_q.push(http.send.makeErrorSend(ht.conn, .not_found)),
                .method_not_allowed => {
                    var resp = http.response.Response.init(.method_not_allowed);
                    resp.body = "Method Not Allowed";
                    try self.send_q.push(http.send.makeResponseSend(ht.conn, resp));
                },
            }
        }
    }

    fn stageHandlePython(self: *Pipeline) !void {
        if (self.py_ready_q.isEmpty()) return;
        try self.drainPythonReady();
    }

    fn drainPythonReady(self: *Pipeline) !void {
        const py_ctx = self.py_ctx;

        var invoke_metrics = driver.InvokeMetrics{};
        while (self.py_ready_q.pop()) |popped| {
            var task = popped;
            switch (task) {
                .invoke => |*invoke| try aio.tasks.runInvoke(self, py_ctx, invoke, &invoke_metrics),
                .redis_resume => |ready_task| try aio.tasks.runRedisResume(self, py_ctx, ready_task),
                .pg_resume => |ready_task| try aio.tasks.runPgResume(self, py_ctx, ready_task),
            }
        }
        self.stats.accumInvokeMetrics(&invoke_metrics);
    }

    const instant = metrics.instant;
    const elapsedNs = metrics.elapsedNs;

    fn dispatchMatchedRouteNoGil(
        self: *Pipeline,
        ht: aio.tasks.HandleTask,
        found: anytype,
    ) !void {
        const py_id = found.handler_id;
        const flags = py.module.getHandlerFlags(self.py_ctx.necro_module, py_id);
        if (flags.no_args) {
            try self.queuePythonHandle(ht.conn, py_id, .no_args, flags.is_async, &.{}, null);
            return;
        }
        if (flags.needs_params) {
            try self.queuePythonHandle(ht.conn, py_id, .params_only, flags.is_async, found.params[0..found.param_count], null);
            return;
        }
        try self.queuePythonHandle(ht.conn, py_id, .request, flags.is_async, found.params[0..found.param_count], ht.slab);
    }

    fn queuePythonHandle(
        self: *Pipeline,
        conn_lease: core.Lease,
        py_id: u32,
        kind: aio.tasks.PythonHandleTask.Kind,
        is_async: bool,
        params: []const http.router.PathParam,
        slab_lease: ?core.Lease,
    ) !void {
        var task = aio.tasks.PythonHandleTask{
            .conn = conn_lease,
            .py_id = py_id,
            .kind = kind,
            .is_async = is_async,
        };
        if (kind == .request) {
            const sl = slab_lease orelse return error.MissingRequestSlab;
            aio.tasks.HandleTask.writeParams(self.small_pool.get(sl), params);
            task.request_slab = sl;
        }
        task.param_count = copyPathParams(&task.params, params);
        try self.py_ready_q.push(.{ .invoke = task });
    }

    fn copyPathParams(dst: *[8]http.router.PathParam, src: []const http.router.PathParam) u8 {
        std.debug.assert(src.len <= dst.len);
        for (src, 0..) |param, i| dst[i] = param;
        return @intCast(src.len);
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

    pub fn pgStmtCache(self: *Pipeline) ?*necro.pg.stmt.Cache {
        if (self.pg_conn == null) return null;
        return &self.pg_stmt_cache;
    }

    pub fn pgConnPrepared(self: *Pipeline) ?*[necro.pg.stmt.STMT_CACHE_CAPACITY]bool {
        if (self.pg_conn == null) return null;
        return &self.pg_conn.?.prepared;
    }

    fn stageSerializeAndSend(self: *Pipeline) !void {
        const common = http.headers.commonResponseHeaders();

        while (self.send_q.pop()) |st| {
            const conn = self.conns.get(st.conn);
            if (conn.send_mode != .idle) {
                discardSendTask(st);
                try self.close_q.push(st.conn);
                continue;
            }

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

            const will_keep_alive = st.keep_alive and conn.req_keepalive;
            try self.prepareConnSend(conn, &prepared, will_keep_alive, common);
            conn.send_close_on_done = !will_keep_alive;
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
        self: *Pipeline,
        conn: *Conn,
        prepared: *driver.Prepared,
        keep_alive: bool,
        common: []const u8,
    ) error{UnsupportedStatus}!void {
        const use_zc = shouldUseSendMsgZc(conn, &prepared.response, keep_alive, common);

        conn.send_mode = if (use_zc) .sendmsg_zc else .sendv;
        conn.send_sent = 0;
        conn.send_body = prepared.response.body;
        if (conn.send_body_lease) |l| self.small_pool.release(l);
        conn.send_body_py.deinit();
        conn.send_body_lease = if (prepared.body_pool != null) prepared.body_lease else null;
        conn.send_body_py = prepared.py_body;
        prepared.body_pool = null;
        prepared.py_body = .{};
        conn.send_iov_count = 0;

        if (use_zc) {
            var hold = ZcHold{};
            hold.hdr_len = http.response.writeResponseHeaders(hold.hdr[0..], &prepared.response, keep_alive);
            conn.zc_hold = hold;
            conn.zc_notif_pending = true;
        } else {
            const hdr_len = http.response.writeResponseHeaders(conn.send_hdr[0..], &prepared.response, keep_alive);
            conn.send_iovecs[2] = .{ .base = conn.send_hdr[0..].ptr, .len = hdr_len };
            if (!conn.zc_notif_pending) conn.zc_hold = null;
        }

        const status_line = try http.response.statusLine(prepared.response.status);
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
        response: *const http.response.Response,
        keep_alive: bool,
        common: []const u8,
    ) bool {
        if (conn.zc_notif_pending) return false;
        const body = response.body orelse return false;
        const status_line_len = (http.response.statusLine(response.status) catch return false).len;
        const total_len = status_line_len + common.len + estimateResponseHeaderLen(response, keep_alive) + body.len;
        return total_len >= HTTP_SEND_ZC_MIN_BYTES;
    }

    fn discardSendTask(st: http.send.SendTask) void {
        switch (st.source) {
            .native => {},
            .python => |py_result| ffi.decref(py_result),
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

    fn totalIovLen(iovecs: []const posix.iovec_const) usize {
        var total: usize = 0;
        for (iovecs) |iov| total += iov.len;
        return total;
    }

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
                try self.submitRedisRecv();
            } else {
                self.redis_recv_state = .idle;
            }
        }

        const new_queries = self.redis_waiter_q.len - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try self.submitRedisSend();

            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .receiving;
                try self.submitRedisRecv();
            }
        }
    }

    fn parseRedisResponses(self: *Pipeline) !void {
        while (self.redis_in_flight > 0 and self.redis_waiter_q.len > 0) {
            if (!try self.parseOneResp()) break;
        }
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
                if (data.len < total_needed) return false;

                const py_bytes = ffi.bytesNew(@intCast(payload_len)) catch return false;
                const dest: [*]u8 = ffi.bytesAsSlice(py_bytes, payload_len);
                @memcpy(dest[0..payload_len], data[crlf_pos + 2 ..][0..payload_len]);
                self.redis_parse_pos += total_needed;
                break :blk py_bytes;
            },
            else => return false,
        };

        const waiter = self.redis_waiter_q.pop() orelse {
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
            return;
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

    fn stagePostgres(self: *Pipeline) !void {
        self.pg_wire_ns = 0;
        if (self.pg_conn == null) return;

        if (self.pg_conn) |*pg| {
            if (pg.recv_state == .err) {
                try self.failPgConnWaitersWithStatus(pg, pg.fail_status, pg.fail_body);
            }

            if (pg.recv_state == .parsing) {
                const t0 = if (comptime metrics.enabled) instant() else {};
                try self.parsePgConnResponses(pg);
                if (comptime metrics.enabled) {
                    self.pg_wire_ns += instant().since(t0);
                }
                _ = pg.recv_queue.consumeParsed(&self.pg_recv_group);

                if (pg.recv_state == .err) {
                    try self.failPgConnWaitersWithStatus(pg, pg.fail_status, pg.fail_body);
                    return;
                }

                pg.recv_state = .idle;
                if (pg.in_flight > 0 and !pg.recv_armed) try self.submitPgRecv(pg);
            }

            const new_queries = pg.waiter_q.items.len - pg.in_flight;
            if (new_queries > 0 and pg.send_state == .idle and pg.send_len > 0) {
                const sync = necro.pg.wire.encodeSync(pg.send_buf[pg.send_len..]);
                pg.send_len += sync.len;
                pg.in_flight += new_queries;
                try pg.waiter_q.pushBatch(@intCast(new_queries));
                pg.send_state = .sending;
                try self.submitPgSend(pg);
                if (!pg.recv_armed) try self.submitPgRecv(pg);
            }

            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try self.submitPgSend(pg);
            }
        }
    }

    ///
    fn wrapPgRowResult(waiter: aio.tasks.PgWaiter, result_obj: *ffi.PyObject) ffi.PythonError!*ffi.PyObject {
        if (waiter.model_cls) |model_cls| {
            if (necro.pg.row.isRow(result_obj)) {
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
        var query_save_pos = pg.recv_queue.parseOffset();
        var scratch: [65536]u8 = undefined;

        while (pg.waiter_q.peek()) |waiter| {
            const message = pg_stream.nextMessage(&pg.recv_queue, &scratch, pg.recv_queue.parseOffset()) catch |err| switch (err) {
                error.MessageTooLarge => {
                    if (py_result) |r| ffi.decref(r);
                    if (py_list) |l| ffi.decref(l);
                    try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres message exceeds receive queue capacity");
                    return;
                },
                else => return err,
            };
            if (message == null) {
                pg.recv_queue.setParseOffset(query_save_pos);
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const msg = message.?;
            pg.recv_queue.setParseOffset(pg.recv_queue.parseOffset() + msg.total_len);

            if (msg.header.tag == necro.pg.wire.BackendTag.ready_for_query) {
                query_save_pos = pg.recv_queue.parseOffset();
                continue;
            }

            const stmt_entry = self.pg_stmt_cache.get(waiter.stmt_idx);
            const col_count: u16 = if (stmt_entry.described) stmt_entry.col_count else 0;

            switch (msg.header.tag) {
                necro.pg.wire.BackendTag.parse_complete, necro.pg.wire.BackendTag.bind_complete => continue,
                necro.pg.wire.BackendTag.no_data => {
                    if (!stmt_entry.described) {
                        stmt_entry.col_count = 0;
                        stmt_entry.described = true;
                    }
                    continue;
                },
                necro.pg.wire.BackendTag.row_description => {
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
                necro.pg.wire.BackendTag.data_row => {
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
                            try self.failPgConnWaitersWithStatus(pg, .internal_server_error, "Postgres row exceeds receive/result capacity");
                            return;
                        },
                        else => return err,
                    };
                    const result_obj = try wrapPgRowResult(waiter.*, raw_result);

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
                necro.pg.wire.BackendTag.command_complete => {
                    if (waiter.mode == .execute) {
                        const count = pg_stream.parseCommandCompleteCount(msg.payload);
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (waiter.mode == .fetch_all)
                        py_list orelse try ffi.listNew(0)
                    else
                        py_result orelse ffi.getNone();

                    completed[completed_count] = .{ .waiter = waiter.*, .result = final_result };
                    completed_count += 1;
                    _ = pg.waiter_q.pop();
                    pg.in_flight -= 1;
                    try pg.waiter_q.completeOne();
                    py_result = null;
                    py_list = null;
                    query_save_pos = pg.recv_queue.parseOffset();
                },
                necro.pg.wire.BackendTag.error_response => {
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
        pg.recv_armed = false;
        pg.send_state = .idle;
        pg.in_flight = 0;
        pg.fail_status = .internal_server_error;
        pg.fail_body = null;
        pg.recv_queue.clear(&self.pg_recv_group);
        pg.waiter_q.clear();
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

    fn handleCompletion(self: *Pipeline, token_ptr: *anyopaque, completion: Completion) !void {
        const token: *aio.Token = @ptrCast(@alignCast(token_ptr));
        switch (token.tag) {
            .accept => {
                const draining = necro.server.shutdown_flag.load(.acquire);
                if (!draining and completion.result >= 0) self.onAccept(completion);
                if (!completion.more) {
                    self.accept_armed = false;
                    if (!draining) try self.armAccept();
                }
            },
            .conn_recv => try self.onConnRecvCompletion(token, completion),
            .conn_send => try self.onConnSendCompletion(token, completion),
            .redis_send => try self.onRedisSendIO(completion),
            .redis_recv => try self.onRedisRecvIO(completion),
            .pg_send => try self.onPgSendIO(@fieldParentPtr("send_token", token), completion),
            .pg_recv => try self.onPgRecvIO(@fieldParentPtr("recv_token", token), completion),
            .wake => try self.submitWakeRecv(),
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

    fn stageClose(self: *Pipeline) void {
        while (self.close_q.pop()) |index| {
            const conn = self.conns.get(index);
            if (conn.fd < 0 and !conn.zc_notif_pending) continue;
            self.idle.remove(&conn.idle);
            if (conn.zc_notif_pending) {
                if (conn.req_slab) |l| self.small_pool.release(l);
                conn.req_slab = null;
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
            if (conn.req_slab) |l| self.small_pool.release(l);
            conn.req_slab = null;
            conn.recv_queue.clear(&self.http_recv_group);
            conn.recv_armed = false;
            conn.parse_queued = false;
            conn.inflight_request_len = 0;
            conn.head_parser = .{};
            conn.head_fed = 0;
            self.releaseConnSendBody(conn);
            posix.shutdown(conn.fd, .both) catch {};
            posix.close(conn.fd);
            self.conns.release(index);
        }
    }
};

fn estimateResponseHeaderLen(resp: *const http.response.Response, keep_alive: bool) usize {
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
