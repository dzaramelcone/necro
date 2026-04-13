const std = @import("std");
const necro = @import("necro");
const ffi = necro.py.ffi;
const py = necro.py;
const driver = py.driver;
const http = necro.http;
const core = necro.core;
const metrics = core.metrics;
const Request = necro.http.request.Request;
const SmallSlab = necro.core.SmallSlab;

const instant = metrics.instant;
const elapsedNs = metrics.elapsedNs;

pub const ParseTask = struct {
    conn: necro.core.Lease,
};

pub const HandleTask = struct {
    conn: necro.core.Lease,
    slab: necro.core.Lease,

    const MAX_HEADERS = 64;
    const MAX_PARAMS = 8;
    pub const DATA_OFFSET = @sizeOf(Meta);

    pub const Span = packed struct {
        off: u16 = 0,
        len: u16 = 0,

        pub fn slice(self: Span, slab: *const SmallSlab) []const u8 {
            return slab.data[self.off .. self.off + self.len];
        }

        fn fromSlice(slab: *const SmallSlab, s: []const u8) Span {
            return .{
                .off = @intCast(@intFromPtr(s.ptr) - @intFromPtr(&slab.data)),
                .len = @intCast(s.len),
            };
        }
    };

    pub const Meta = struct {
        method: ?std.http.Method = null,
        keepalive: bool = true,
        header_end: u16 = 0,
        content_length: u32 = 0,
        method_bytes: Span = .{},
        uri: Span = .{},
        body: Span = .{},
        header_count: u8 = 0,
        param_count: u8 = 0,
        headers: [MAX_HEADERS]HeaderSpan = @splat(.{}),
        params: [MAX_PARAMS]Param = @splat(.{}),

        pub const HeaderSpan = struct {
            name: Span = .{},
            value: Span = .{},
        };

        pub const Param = struct {
            name_ptr: [*]const u8 = undefined,
            name_len: u16 = 0,
            value: Span = .{},
        };
    };

    pub fn getMeta(slab: *const SmallSlab) *const Meta {
        return @ptrCast(@alignCast(&slab.data));
    }

    fn getMetaMut(slab: *SmallSlab) *Meta {
        return @ptrCast(@alignCast(&slab.data));
    }

    pub fn writeMeta(slab: *SmallSlab, req: *const Request, header_end: usize, content_length: usize) void {
        const m = getMetaMut(slab);
        m.* = .{
            .method = req.method,
            .keepalive = req.keepalive,
            .header_end = @intCast(header_end),
            .content_length = @intCast(content_length),
        };
        if (req.method_bytes) |mb| m.method_bytes = Span.fromSlice(slab, mb);
        if (req.uri) |u| m.uri = Span.fromSlice(slab, u);
        if (req.body) |b| m.body = Span.fromSlice(slab, b);
        m.header_count = @intCast(req.header_count);
        for (req.headers[0..req.header_count], 0..) |h, i| {
            m.headers[i] = .{
                .name = Span.fromSlice(slab, h.name),
                .value = Span.fromSlice(slab, h.value),
            };
        }
    }

    pub fn writeParams(slab: *SmallSlab, params: []const necro.http.router.PathParam) void {
        const m = getMetaMut(slab);
        m.param_count = @intCast(@min(params.len, MAX_PARAMS));
        for (params[0..m.param_count], 0..) |p, i| {
            m.params[i] = .{
                .name_ptr = p.name.ptr,
                .name_len = @intCast(p.name.len),
                .value = Span.fromSlice(slab, p.value),
            };
        }
    }
};

pub const PythonHandleTask = struct {
    conn: necro.core.Lease,
    py_id: u32,
    kind: Kind,
    is_async: bool = false,
    request_slab: ?necro.core.Lease = null,
    params: [8]necro.http.router.PathParam = undefined,
    param_count: u8 = 0,

    pub const Kind = enum(u8) {
        no_args,
        params_only,
        request,
    };
};

pub const RedisWaiter = struct {
    conn: necro.core.Lease,
    py_coro: *ffi.PyObject,
    py_future: *ffi.PyObject,

    pub fn fromYield(conn: necro.core.Lease, yield: necro.py.future.RedisYield) RedisWaiter {
        return .{
            .conn = conn,
            .py_coro = yield.py_coro,
            .py_future = yield.py_future,
        };
    }
};

pub const PgWaiter = struct {
    conn: necro.core.Lease,
    py_coro: *ffi.PyObject,
    py_future: *ffi.PyObject,
    mode: necro.py.future.PgMode,
    stmt_idx: u16,
    model_cls: ?*ffi.PyObject,

    pub fn fromYield(conn: necro.core.Lease, yield: necro.py.future.PgYield) PgWaiter {
        return .{
            .conn = conn,
            .py_coro = yield.py_coro,
            .py_future = yield.py_future,
            .mode = yield.mode,
            .stmt_idx = yield.stmt_idx,
            .model_cls = yield.model_cls,
        };
    }
};

pub const RedisResumeReady = struct {
    waiter: RedisWaiter,
    result: *ffi.PyObject,
};

pub const PgResumeReady = struct {
    waiter: PgWaiter,
    result: *ffi.PyObject,
};

pub const PyReadyTask = union(enum) {
    invoke: PythonHandleTask,
    redis_resume: RedisResumeReady,
    pg_resume: PgResumeReady,
};

fn buildRequestObject(self: anytype, task: *PythonHandleTask) !?*ffi.PyObject {
    if (task.kind != .request) return null;
    const slab_lease = task.request_slab orelse return error.MissingRequestSlab;
    task.request_slab = null;
    return py.request.create(&self.small_pool, slab_lease) catch {
        return error.PythonError;
    };
}

/// Invoke a Python handler. Shared between kq and uring runtimes.
/// `self` must be a Pipeline-like struct with fields: small_pool, send_q, stats;
/// and methods: redisSendSlice(), pgSendSlice(), pgStmtCache(), pgConnPrepared(), handleResult().
pub fn runInvoke(
    self: anytype,
    py_ctx: *driver.PyContext,
    task: *PythonHandleTask,
    invoke_metrics: *driver.InvokeMetrics,
) !void {
    const m = comptime metrics.enabled;
    if (m) switch (task.kind) {
        .no_args => self.stats.py_no_args += 1,
        .params_only => self.stats.py_params_only += 1,
        .request => self.stats.py_request += 1,
    };
    const t_request_obj = if (m) instant() else {};
    const request_obj = buildRequestObject(self, task) catch {
        if (m) self.stats.ns_py_request_obj += elapsedNs(t_request_obj);
        try self.send_q.push(http.send.makeErrorSend(task.conn, .internal_server_error));
        return;
    };
    if (m) self.stats.ns_py_request_obj += elapsedNs(t_request_obj);
    defer ffi.xdecref(request_obj);

    const t_invoke = if (m) instant() else {};
    const result = driver.invokePythonHandlerWithKnownFlags(
        py_ctx.necro_module,
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
    ) catch {
        if (m) self.stats.ns_py_invoke_total += elapsedNs(t_invoke);
        try self.send_q.push(http.send.makeErrorSend(task.conn, .internal_server_error));
        return;
    };
    if (m) self.stats.ns_py_invoke_total += elapsedNs(t_invoke);
    try handleResult(self, task.conn, result);
}

/// Resume a coroutine with a redis result.
pub fn runRedisResume(self: anytype, py_ctx: *driver.PyContext, ready: RedisResumeReady) !void {
    defer ffi.decref(ready.result);
    const waiter = ready.waiter;
    defer ffi.decref(waiter.py_future);

    py.future.setResult(waiter.py_future, ready.result) catch {
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
        return;
    };

    const send = ffi.iterSend(waiter.py_coro, ffi.none());
    switch (send.status) {
        .next => {
            const yielded = send.result.?;
            defer ffi.decref(yielded);
            const state = py.module.getState(py_ctx.necro_module) orelse {
                ffi.coroutineClose(waiter.py_coro);
                ffi.decref(waiter.py_coro);
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            const yield = py.future.consumeYield(
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
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            switch (yield) {
                .redis => |ry| {
                    self.redis_send_len += ry.bytes_written;
                    try self.redis_waiter_q.push(RedisWaiter.fromYield(waiter.conn, ry));
                    self.redis_in_flight += 1;
                },
                .pg => |pg_yield| {
                    const pg_conn = &self.pg_conn.?;
                    pg_conn.send_len += pg_yield.bytes_written;
                    errdefer ffi.xdecref(pg_yield.model_cls);
                    try pg_conn.waiter_q.push(PgWaiter.fromYield(waiter.conn, pg_yield));
                },
            }
        },
        .@"return" => {
            ffi.decref(waiter.py_coro);
            const py_res = send.result orelse {
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            try self.send_q.push(http.send.makePythonSend(waiter.conn, py_res));
        },
        .@"error" => {
            ffi.decref(waiter.py_coro);
            if (ffi.errOccurred()) ffi.errPrint();
            try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
        },
    }
}

/// Resume a coroutine with a postgres result.
pub fn runPgResume(self: anytype, py_ctx: *driver.PyContext, ready: PgResumeReady) !void {
    defer ffi.decref(ready.result);
    defer ffi.xdecref(ready.waiter.model_cls);
    const waiter = ready.waiter;
    defer ffi.decref(waiter.py_future);

    py.future.setResult(waiter.py_future, ready.result) catch {
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
        return;
    };

    const send = ffi.iterSend(waiter.py_coro, ffi.none());
    switch (send.status) {
        .next => {
            const yielded = send.result.?;
            defer ffi.decref(yielded);
            const state = py.module.getState(py_ctx.necro_module) orelse {
                ffi.coroutineClose(waiter.py_coro);
                ffi.decref(waiter.py_coro);
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            const yield = py.future.consumeYield(
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
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            switch (yield) {
                .redis => |ry| {
                    self.redis_send_len += ry.bytes_written;
                    try self.redis_waiter_q.push(RedisWaiter.fromYield(waiter.conn, ry));
                },
                .pg => |pg_yield| {
                    const pg_conn = &self.pg_conn.?;
                    pg_conn.send_len += pg_yield.bytes_written;
                    errdefer ffi.xdecref(pg_yield.model_cls);
                    try pg_conn.waiter_q.push(PgWaiter.fromYield(waiter.conn, pg_yield));
                },
            }
        },
        .@"return" => {
            ffi.decref(waiter.py_coro);
            const py_res = send.result orelse {
                try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
                return;
            };
            try self.send_q.push(http.send.makePythonSend(waiter.conn, py_res));
        },
        .@"error" => {
            ffi.decref(waiter.py_coro);
            if (ffi.errOccurred()) ffi.errPrint();
            try self.send_q.push(http.send.makeErrorSend(waiter.conn, .internal_server_error));
        },
    }
}

/// Route an InvokeResult: response → send_q, yields → update send buffers + push waiter.
pub fn handleResult(self: anytype, conn: core.Lease, result: driver.InvokeResult) !void {
    const m = comptime metrics.enabled;
    const t_result = if (m) instant() else {};
    switch (result) {
        .native_response => |resp| {
            try self.send_q.push(http.send.makeResponseSend(conn, resp));
            if (m) {
                const elapsed = elapsedNs(t_result);
                self.stats.ns_py_result += elapsed;
                self.stats.ns_py_result_response += elapsed;
            }
        },
        .py_result => |py_obj| {
            try self.send_q.push(http.send.makePythonSend(conn, py_obj));
            if (m) {
                const elapsed = elapsedNs(t_result);
                self.stats.ns_py_result += elapsed;
                self.stats.ns_py_result_response += elapsed;
            }
        },
        .redis_yield => |ry| {
            self.redis_send_len += ry.bytes_written;
            try self.redis_waiter_q.push(RedisWaiter.fromYield(conn, ry));
            if (m) {
                const elapsed = elapsedNs(t_result);
                self.stats.ns_py_result += elapsed;
                self.stats.ns_py_result_yield += elapsed;
            }
        },
        .pg_yield => |py_pg| {
            const pg_conn = &self.pg_conn.?;
            pg_conn.send_len += py_pg.bytes_written;
            errdefer ffi.xdecref(py_pg.model_cls);
            try pg_conn.waiter_q.push(PgWaiter.fromYield(conn, py_pg));
            if (m) {
                const elapsed = elapsedNs(t_result);
                self.stats.ns_py_result += elapsed;
                self.stats.ns_py_result_yield += elapsed;
            }
        },
    }
}
