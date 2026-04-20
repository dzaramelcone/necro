const std = @import("std");
const necro = @import("necro");
const ffi = necro.py.ffi;
const module = necro.py.module;
const future = necro.py.future;
const request = necro.py.request;
const http = necro.http;
const stmt = necro.pg.stmt;

const Ex = http.exchange.Exchange;

pub const InvokeHandler = struct {
    exchange: *Ex,
    handler_id: u32,
    needs_req: bool,
    needs_params: bool,
    is_async: bool,
};

pub const ResumeCoroutine = struct {
    exchange: *Ex,
    result: *ffi.PyObject,
};

pub const Job = union(enum) {
    invoke_handler: InvokeHandler,
    resume_coroutine: ResumeCoroutine,
};

pub const Action = union(enum) {
    send: SendAction,
    wait_redis: struct {
        exchange: *Ex,
        bytes_written: usize,
    },
    wait_pg: struct {
        exchange: *Ex,
        bytes_written: usize,
    },
    fail: struct {
        exchange: *Ex,
        status: std.http.Status,
    },
};

pub const SendAction = struct {
    exchange: *Ex,
    source: SendSource,
};

pub const SendSource = union(enum) {
    native: http.Response,
    python: *ffi.PyObject,
};

pub const Input = struct {
    mod: *ffi.PyObject,
    redis_send: ?[]u8,
    pg_send: ?[]u8,
    pg_stmt_cache: ?*stmt.Cache,
    pg_prepared: ?*[stmt.STMT_CACHE_CAPACITY]bool,
};

pub fn run(job: Job, input: Input) !Action {
    switch (job) {
        .invoke_handler => |inv| return invoke(inv, input),
        .resume_coroutine => |res| return resumeCoroutine(res, input),
    }
}

fn invoke(inv: InvokeHandler, input: Input) !Action {
    const exchange = inv.exchange;
    const handler = module.getHandler(input.mod, inv.handler_id) orelse
        return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };

    const call_result = callHandler(handler, inv, exchange) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
    };

    if (!inv.is_async)
        return .{ .send = .{ .exchange = exchange, .source = .{ .python = call_result } } };

    return stepCoroutine(exchange, call_result, ffi.none(), input);
}

fn callHandler(handler: *ffi.PyObject, inv: InvokeHandler, exchange: *Ex) !*ffi.PyObject {
    if (inv.needs_params) {
        const req = exchange.req;
        const n = req.meta.num_params;
        if (n == 0) return ffi.vectorcallNoArgs(handler);

        var args: [http.router.MAX_PARAMS]?*ffi.PyObject = .{null} ** http.router.MAX_PARAMS;
        var built: usize = 0;
        errdefer for (args[0..built]) |a| ffi.xdecref(a);
        while (built < n) : (built += 1) {
            const slice = req.paramSlice(built);
            args[built] = try ffi.unicodeFromSlice(slice.ptr, slice.len);
        }
        const result = ffi.c.PyObject_Vectorcall(
            handler,
            @ptrCast(&args),
            @intCast(n),
            null,
        ) orelse return error.CallError;
        for (args[0..n]) |a| ffi.xdecref(a);
        return result;
    }

    if (inv.needs_req) {
        const req_obj = try request.create(exchange.req);
        defer ffi.decref(req_obj);
        return ffi.vectorcallOneArg(handler, req_obj);
    }

    return ffi.vectorcallNoArgs(handler);
}

fn resumeCoroutine(res: ResumeCoroutine, input: Input) !Action {
    defer ffi.decref(res.result);
    const exchange = res.exchange;
    std.debug.assert(!exchange.aborted);

    if (exchange.io == .pg) ffi.xdecref(exchange.io.pg.model_cls);
    exchange.io = .none;

    const py_future = exchange.py_future orelse
        return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
    const py_coro = exchange.py_coro orelse
        return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };

    future.setResult(py_future, res.result) catch {
        ffi.coroutineClose(py_coro);
        exchange.dropAndCleanup();
        return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
    };

    exchange.py_future = null;
    exchange.py_coro = null;
    defer ffi.decref(py_future);
    return stepCoroutine(exchange, py_coro, ffi.none(), input);
}

fn stepCoroutine(exchange: *Ex, coro: *ffi.PyObject, send_val: *ffi.PyObject, input: Input) !Action {
    const send = ffi.iterSend(coro, send_val);
    switch (send.status) {
        .next => {
            const yielded = send.result.?;
            defer ffi.decref(yielded);

            const state = module.getState(input.mod) orelse {
                ffi.coroutineClose(coro);
                ffi.decref(coro);
                return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
            };

            const yield = future.consumeYield(
                &state.future_types,
                yielded,
                coro,
                input.redis_send,
                input.pg_send,
                input.pg_stmt_cache,
                input.pg_prepared,
            ) catch {
                ffi.coroutineClose(coro);
                ffi.decref(coro);
                return .{ .fail = .{ .exchange = exchange, .status = .service_unavailable } };
            };

            switch (yield) {
                .redis => |ry| {
                    exchange.py_coro = coro;
                    exchange.py_future = ry.py_future;
                    exchange.io = .redis;
                    return .{ .wait_redis = .{ .exchange = exchange, .bytes_written = ry.bytes_written } };
                },
                .pg => |pg| {
                    exchange.py_coro = coro;
                    exchange.py_future = pg.py_future;
                    exchange.io = .{ .pg = .{
                        .mode = pg.mode,
                        .stmt_idx = pg.stmt_idx,
                        .model_cls = pg.model_cls,
                    } };
                    return .{ .wait_pg = .{ .exchange = exchange, .bytes_written = pg.bytes_written } };
                },
            }
        },
        .@"return" => {
            ffi.decref(coro);
            const py_result = send.result orelse
                return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
            return .{ .send = .{ .exchange = exchange, .source = .{ .python = py_result } } };
        },
        .@"error" => {
            ffi.decref(coro);
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .fail = .{ .exchange = exchange, .status = .internal_server_error } };
        },
    }
}

test "resumeCoroutine must xdecref pg model_cls" {
    if (ffi.c.Py_IsInitialized() == 0) ffi.c.Py_Initialize();

    const obj: *ffi.PyObject = @ptrCast(ffi.c.PyList_New(0) orelse return);
    const before = ffi.refcnt(obj);
    try std.testing.expectEqual(@as(isize, 1), before);

    ffi.incref(obj);
    try std.testing.expectEqual(before + 1, ffi.refcnt(obj));

    ffi.xdecref(obj);
    try std.testing.expectEqual(before, ffi.refcnt(obj));

    ffi.decref(obj);
}
