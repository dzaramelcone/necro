//! Python handler driver: invoke handlers, drive coroutines, consume native async yields.

const std = @import("std");
const posix = std.posix;
const ffi = @import("ffi.zig");
const module = @import("module.zig");
const writeJson = @import("json.zig").write;
const necro = @import("necro");
const Response = http.Response;
const core = necro.core;
const http = necro.http;
const stmt = necro.pg.stmt;
const future = necro.py.future;
const SmallPool = core.Pool(core.SmallSlab);

const log = std.log.scoped(.@"necro/py/driver");

pub const PyContext = @import("subinterp.zig").WorkerPyContext;

pub const PyHandlerFlags = extern struct {
    needs_request: bool = true,
    needs_params: bool = false,
    no_args: bool = false,
    is_async: bool = false,
};

fn buildParamsKwargs(params: []const http.PathParam) ffi.PythonError!*ffi.PyObject {
    const kwargs = try ffi.dictNew();
    for (params) |p| {
        const name_obj = try ffi.unicodeFromSlice(p.name.ptr, p.name.len);
        defer ffi.decref(name_obj);
        const val_obj = try ffi.unicodeFromSlice(p.value.ptr, p.value.len);
        defer ffi.decref(val_obj);
        try ffi.dictSetItem(kwargs, name_obj, val_obj);
    }
    return kwargs;
}

pub const InvokeResult = union(enum) {
    native_response: http.Response,
    py_result: *ffi.PyObject,
    redis_yield: future.RedisYield,
    pg_yield: future.PgYield,
};

pub const InvokeMetrics = struct {
    invocations: u64 = 0,
    coroutines: u64 = 0,
    sync_responses: u64 = 0,
    async_immediate_returns: u64 = 0,
    redis_yields: u64 = 0,
    pg_yields: u64 = 0,
    ns_lookup: u64 = 0,
    ns_arg_build: u64 = 0,
    ns_call: u64 = 0,
    ns_resume: u64 = 0,
    ns_yield_consume: u64 = 0,
};

fn nowInstant() ?std.time.Instant {
    return std.time.Instant.now() catch |e| switch (e) {
        error.Unsupported => unreachable,
    };
}

fn accumElapsed(total: *u64, start: ?std.time.Instant) void {
    const t0 = start orelse return;
    const t1 = std.time.Instant.now() catch |e| switch (e) {
        error.Unsupported => unreachable,
    };
    total.* += t1.since(t0);
}

pub fn invokePythonHandlerWithKnownFlags(
    mod: *ffi.PyObject,
    handler_id: u32,
    no_args: bool,
    needs_params: bool,
    is_async: bool,
    req_obj: ?*ffi.PyObject,
    params: []const http.PathParam,
    redis_send_buf: ?[]u8,
    pg_send_buf: ?[]u8,
    pg_stmt_cache: ?*stmt.Cache,
    pg_conn_prepared: ?*[stmt.STMT_CACHE_CAPACITY]bool,
    metrics: ?*InvokeMetrics,
) !InvokeResult {
    if (metrics) |m| m.invocations += 1;

    const t_lookup = if (metrics != null) nowInstant() else null;
    const handler = module.getHandler(mod, handler_id) orelse {
        return .{ .native_response = http.Response.init(.internal_server_error) };
    };
    if (metrics) |m| accumElapsed(&m.ns_lookup, t_lookup);

    const t_call = if (metrics != null) nowInstant() else null;
    const call_result = if (no_args) blk: {
        break :blk ffi.vectorcallNoArgs(handler) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
    } else if (needs_params) blk: {
        if (params.len == 0) {
            break :blk ffi.vectorcallNoArgs(handler) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .native_response = http.Response.init(.internal_server_error) };
            };
        }

        const t_args = if (metrics != null) nowInstant() else null;
        const kwargs = buildParamsKwargs(params) catch {
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
        defer ffi.decref(kwargs);
        const empty_args = ffi.tupleNew(0) catch {
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
        defer ffi.decref(empty_args);
        if (metrics) |m| accumElapsed(&m.ns_arg_build, t_args);

        break :blk ffi.callObjectKwargs(handler, empty_args, kwargs) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
    } else blk: {
        const request = req_obj orelse {
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
        break :blk ffi.vectorcallOneArg(handler, request) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = http.Response.init(.internal_server_error) };
        };
    };
    if (metrics) |m| accumElapsed(&m.ns_call, t_call);

    if (is_async) {
        if (metrics) |m| m.coroutines += 1;

        const t_resume = if (metrics != null) nowInstant() else null;
        const send = ffi.iterSend(call_result, ffi.none());
        if (metrics) |m| accumElapsed(&m.ns_resume, t_resume);

        switch (send.status) {
            .next => {
                const yielded = send.result.?;
                defer ffi.decref(yielded);

                const t_yield_consume = if (metrics != null) nowInstant() else null;
                const state = module.getState(mod) orelse {
                    ffi.coroutineClose(call_result);
                    ffi.decref(call_result);
                    return .{ .native_response = http.Response.init(.internal_server_error) };
                };
                const yield = future.consumeYield(
                    &state.future_types,
                    yielded,
                    call_result,
                    redis_send_buf,
                    pg_send_buf,
                    pg_stmt_cache,
                    pg_conn_prepared,
                ) catch {
                    ffi.coroutineClose(call_result);
                    ffi.decref(call_result);
                    return .{ .native_response = http.Response.init(.service_unavailable) };
                };
                if (metrics) |m| {
                    accumElapsed(&m.ns_yield_consume, t_yield_consume);
                    switch (yield) {
                        .redis => m.redis_yields += 1,
                        .pg => m.pg_yields += 1,
                    }
                }
                return switch (yield) {
                    .redis => |redis_yield| .{ .redis_yield = redis_yield },
                    .pg => |pg_yield| .{ .pg_yield = pg_yield },
                };
            },
            .@"return" => {
                ffi.decref(call_result);
                if (metrics) |m| m.async_immediate_returns += 1;
                const py_result = send.result orelse {
                    return .{ .native_response = http.Response.init(.internal_server_error) };
                };
                return .{ .py_result = py_result };
            },
            .@"error" => {
                ffi.decref(call_result);
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .native_response = http.Response.init(.internal_server_error) };
            },
        }
    }

    if (metrics) |m| m.sync_responses += 1;
    return .{ .py_result = call_result };
}

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
    body_pool: ?*SmallPool = null,
    body_lease: core.Lease = undefined,
    py_body: PyBodyHold = .{},

    pub fn fromResponse(response: Response) Prepared {
        return .{ .response = response };
    }

    pub fn deinit(self: *Prepared) void {
        if (self.body_pool) |p| p.release(self.body_lease);
        self.py_body.deinit();
        self.* = undefined;
    }
};

pub const PrepareError = ffi.PythonError || error{
    UnsupportedReturnType,
    ResponseBodyTooLarge,
    PoolExhausted,
    OutOfMemory,
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

fn prepareJson(py_result: *ffi.PyObject, pool: *SmallPool) PrepareError!Prepared {
    const lease = try pool.borrow();
    errdefer pool.release(lease);
    const body = pool.get(lease);
    var slab_pos: usize = 0;
    writeJson(py_result, &body.data, &slab_pos) catch |e| return switch (e) {
        error.UnsupportedType => error.UnsupportedReturnType,
        error.BufferTooSmall => error.ResponseBodyTooLarge,
        else => @errorCast(e),
    };
    return .{
        .response = Response.json(body.data[0..slab_pos]),
        .body_pool = pool,
        .body_lease = lease,
    };
}

pub fn prepare(py_result: *ffi.PyObject, pool: *SmallPool) PrepareError!Prepared {
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

    if (prepareJson(py_result, pool)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    return error.UnsupportedReturnType;
}

fn shutdownSignalHandler(_: c_int) callconv(.c) void {
    necro.server.requestShutdown();
}

fn installShutdownSignals() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = shutdownSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
}

pub fn startServer(mod: *ffi.PyObject, host: []const u8, port: u16, threads: usize, module_name: []const u8, search_path: []const u8, backlog: u16, version: []const u8) !void {
    log.debug("startServer host={s} port={d} threads={d} module={s} path={s} backlog={d} version={s}", .{ host, port, threads, module_name, search_path, backlog, version });
    const state = module.getState(mod) orelse return error.ModuleNotSet;

    installShutdownSignals();

    var server = necro.server.Server.init(std.heap.smp_allocator, host, port);
    defer server.deinit();
    server.num_threads = @intCast(threads);
    server.backlog = @intCast(backlog);

    var i: u32 = 0;
    while (i < state.py_handler_count) : (i += 1) {
        const entry = state.route_entries[i];
        const method = std.meta.stringToEnum(std.http.Method, entry.method[0..entry.method_len]) orelse continue;
        server.router.addRoute(method, entry.path[0..entry.path_len], i) catch continue;
    }

    const saved_tstate = ffi.PyEval_SaveThread();
    try necro.server.run(std.heap.smp_allocator, &server, module_name, search_path, version);
    ffi.PyEval_RestoreThread(saved_tstate);
}
