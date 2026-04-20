//! necro.core Python extension module (PEP 489 multi-phase init).

const std = @import("std");
const necro = @import("necro");
const ffi = @import("ffi.zig");
const futures = @import("loop/futures.zig");
const type_slots = @import("loop/slots.zig");
const row = necro.pg.row;
const request = @import("request.zig");
const driver = @import("driver.zig");

const PyObject = ffi.PyObject;

const MAX_HANDLERS: usize = 64;

pub const HandlerFlags = extern struct {
    needs_request: bool = true,
    needs_params: bool = false,
    no_args: bool = false,
    is_async: bool = false,
};

const RouteEntry = extern struct {
    method: [8]u8,
    method_len: u8,
    path: [256]u8,
    path_len: u16,
};

pub const ModuleState = extern struct {
    py_handlers: [MAX_HANDLERS]?*PyObject,
    py_handler_count: u32,
    handler_flags: [MAX_HANDLERS]HandlerFlags,
    route_entries: [MAX_HANDLERS]RouteEntry,
    future_types: futures.TypeState,
};

pub fn getState(mod: *PyObject) ?*ModuleState {
    const raw = ffi.moduleGetState(mod) orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn getHandler(mod: *PyObject, handler_id: u32) ?*PyObject {
    const state = getState(mod) orelse return null;
    if (handler_id >= MAX_HANDLERS) return null;
    return state.py_handlers[handler_id];
}

pub fn getHandlerFlags(mod: *PyObject, handler_id: u32) HandlerFlags {
    const state = getState(mod) orelse return HandlerFlags{};
    if (handler_id >= state.py_handler_count) return HandlerFlags{};
    return state.handler_flags[handler_id];
}

fn isCoroutineFunction(obj: *PyObject) bool {
    const inspect_mod = ffi.importModuleRaw("inspect") catch return false;
    defer ffi.decref(inspect_mod);
    const is_coro_fn = ffi.getAttrRaw(inspect_mod, "iscoroutinefunction") catch return false;
    defer ffi.decref(is_coro_fn);
    const result = ffi.callOneArg(is_coro_fn, obj) catch {
        ffi.errClear();
        return false;
    };
    defer ffi.decref(result);
    return ffi.objectIsTrue(result) catch false;
}

fn inspectHandlerFlags(handler_obj: *PyObject) HandlerFlags {
    var flags = HandlerFlags{};
    flags.is_async = isCoroutineFunction(handler_obj);

    const code = ffi.getAttrRaw(handler_obj, "__code__") catch {
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(code);

    const argcount_obj = ffi.getAttrRaw(code, "co_argcount") catch {
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(argcount_obj);
    const argcount = ffi.longAsLong(argcount_obj) catch return flags;

    if (argcount == 0) {
        flags.no_args = true;
        flags.needs_request = false;
        return flags;
    }

    const varnames_obj = ffi.getAttrRaw(code, "co_varnames") catch {
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(varnames_obj);

    const first_param = ffi.tupleGetItem(varnames_obj, 0) orelse return flags;
    if (!ffi.isString(first_param)) return flags;
    const param_name = ffi.unicodeAsUTF8(first_param) catch return flags;
    const name_span = std.mem.span(param_name);

    if (std.mem.eql(u8, name_span, "request") or std.mem.eql(u8, name_span, "req")) {
        flags.needs_request = true;
        return flags;
    }

    if (std.mem.eql(u8, name_span, "self")) {
        if (argcount >= 2) {
            const second_param = ffi.tupleGetItem(varnames_obj, 1) orelse return flags;
            if (!ffi.isString(second_param)) return flags;
            const second_name = ffi.unicodeAsUTF8(second_param) catch return flags;
            const second_span = std.mem.span(second_name);
            if (std.mem.eql(u8, second_span, "request") or std.mem.eql(u8, second_span, "req")) {
                return flags;
            }
        }
        return flags;
    }

    flags.needs_params = true;
    flags.needs_request = false;
    return flags;
}

fn pyAddRoute(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self.?;
    const state = ffi.moduleStateRequired(ModuleState, mod) catch {
        ffi.errSetString(ffi.exc.RuntimeError(), "module state not initialized");
        return null;
    };
    const tuple = args.?;
    if (ffi.tupleSize(tuple) != 3) {
        ffi.errSetString(ffi.exc.TypeError(), "add_route(method, path, handler) requires 3 arguments");
        return null;
    }

    const method_obj = ffi.tupleGetItem(tuple, 0).?;
    const path_obj = ffi.tupleGetItem(tuple, 1).?;
    const handler_obj = ffi.tupleGetItem(tuple, 2).?;
    if (!ffi.isString(method_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "add_route: method must be a string");
        return null;
    }
    if (!ffi.isString(path_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "add_route: path must be a string");
        return null;
    }
    if (!ffi.isCallable(handler_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "add_route: handler must be callable");
        return null;
    }
    if (state.py_handler_count >= MAX_HANDLERS) {
        ffi.errSetString(ffi.exc.RuntimeError(), "too many handlers registered");
        return null;
    }

    const method_span = std.mem.span(ffi.unicodeAsUTF8(method_obj) catch return null);
    const path_span = std.mem.span(ffi.unicodeAsUTF8(path_obj) catch return null);
    if (method_span.len > 8) {
        ffi.errSetString(ffi.exc.ValueError(), "method string too long (max 8)");
        return null;
    }
    if (path_span.len > 256) {
        ffi.errSetString(ffi.exc.ValueError(), "path string too long (max 256)");
        return null;
    }

    const id = state.py_handler_count;
    var entry = RouteEntry{
        .method = std.mem.zeroes([8]u8),
        .method_len = @intCast(method_span.len),
        .path = std.mem.zeroes([256]u8),
        .path_len = @intCast(path_span.len),
    };
    @memcpy(entry.method[0..method_span.len], method_span);
    @memcpy(entry.path[0..path_span.len], path_span);
    state.route_entries[id] = entry;

    ffi.incref(handler_obj);
    state.py_handlers[id] = handler_obj;
    state.handler_flags[id] = inspectHandlerFlags(handler_obj);
    state.py_handler_count = id + 1;
    return ffi.getNone();
}

fn pyRun(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self.?;
    _ = ffi.moduleStateRequired(ModuleState, mod) catch {
        ffi.errSetString(ffi.exc.RuntimeError(), "module state not initialized");
        return null;
    };
    const tuple = args.?;
    const argc = ffi.tupleSize(tuple);
    if (argc != 9) {
        ffi.errSetString(ffi.exc.TypeError(), "run(host, port, threads, module, search_path, backlog, version, cert, key) requires 9 arguments");
        return null;
    }

    const host_obj = ffi.tupleGetItem(tuple, 0).?;
    const port_obj = ffi.tupleGetItem(tuple, 1).?;
    const threads_obj = ffi.tupleGetItem(tuple, 2).?;
    const module_obj = ffi.tupleGetItem(tuple, 3).?;
    const search_path_obj = ffi.tupleGetItem(tuple, 4).?;
    const backlog_obj = ffi.tupleGetItem(tuple, 5).?;
    const version_obj = ffi.tupleGetItem(tuple, 6).?;
    const cert_obj = ffi.tupleGetItem(tuple, 7).?;
    const key_obj = ffi.tupleGetItem(tuple, 8).?;

    if (!ffi.isString(host_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: host must be a string");
        return null;
    }
    if (!ffi.isInt(port_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: port must be an integer");
        return null;
    }
    if (!ffi.isInt(threads_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: threads must be an integer");
        return null;
    }
    if (!ffi.isString(module_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: module must be a string");
        return null;
    }
    if (!ffi.isString(search_path_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: search_path must be a string");
        return null;
    }
    if (!ffi.isInt(backlog_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: backlog must be an integer");
        return null;
    }
    if (!ffi.isString(version_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: version must be a string");
        return null;
    }
    if (!ffi.isString(cert_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: cert must be a string");
        return null;
    }
    if (!ffi.isString(key_obj)) {
        ffi.errSetString(ffi.exc.TypeError(), "run: key must be a string");
        return null;
    }

    const host_span = std.mem.span(ffi.unicodeAsUTF8(host_obj) catch return null);
    const module_span = std.mem.span(ffi.unicodeAsUTF8(module_obj) catch return null);
    const search_path_span = std.mem.span(ffi.unicodeAsUTF8(search_path_obj) catch return null);
    const version_span = std.mem.span(ffi.unicodeAsUTF8(version_obj) catch return null);
    const cert_span = std.mem.span(ffi.unicodeAsUTF8(cert_obj) catch return null);
    const key_span = std.mem.span(ffi.unicodeAsUTF8(key_obj) catch return null);
    const port_long = ffi.longAsLong(port_obj) catch return null;
    const threads_long = ffi.longAsLong(threads_obj) catch return null;
    const backlog_long = ffi.longAsLong(backlog_obj) catch return null;

    if (port_long < 0 or port_long > 65535) {
        ffi.errSetString(ffi.exc.ValueError(), "port must be 0-65535");
        return null;
    }
    if (threads_long < 1 or threads_long > 256) {
        ffi.errSetString(ffi.exc.ValueError(), "threads must be 1-256");
        return null;
    }
    if (backlog_long < 1 or backlog_long > 65535) {
        ffi.errSetString(ffi.exc.ValueError(), "backlog must be 1-65535");
        return null;
    }

    const cert_opt: ?[]const u8 = if (cert_span.len == 0) null else cert_span;
    const key_opt: ?[]const u8 = if (key_span.len == 0) null else key_span;

    driver.startServer(mod, host_span, @intCast(port_long), @intCast(threads_long), module_span, search_path_span, @intCast(backlog_long), version_span, cert_opt, key_opt) catch return null;
    return ffi.getNone();
}

fn redisGet(state: *ModuleState, key: *PyObject) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("GET", &state.future_types, &.{key});
}
fn redisSet(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("SET", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisSetex(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("SETEX", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisDel(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("DEL", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisIncr(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("INCR", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisExpire(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("EXPIRE", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisTtl(state: *ModuleState, key: *PyObject) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("TTL", &state.future_types, &.{key});
}
fn redisExists(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("EXISTS", &state.future_types, args[0..@intCast(nargs)]);
}
fn redisPing(state: *ModuleState) ffi.PythonError!*PyObject {
    return futures.createRedisFuture("PING", &state.future_types, &.{});
}

fn pgExecute(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createPgFuture(.execute, &state.future_types, args[0..@intCast(nargs)]);
}
fn pgFetchOne(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createPgFuture(.fetch_one, &state.future_types, args[0..@intCast(nargs)]);
}
fn pgFetchAll(state: *ModuleState, args: [*]const *PyObject, nargs: ffi.Py_ssize_t) ffi.PythonError!*PyObject {
    return futures.createPgFuture(.fetch_all, &state.future_types, args[0..@intCast(nargs)]);
}

fn getRouteCount(state: *ModuleState) ffi.PythonError!*PyObject {
    return ffi.longFromLong(@intCast(state.py_handler_count));
}

fn pyShutdown(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    necro.server.requestShutdown();
    return ffi.getNone();
}

const methods = ffi.table(ffi.MethodDef, .{
    ffi.methodDef("add_route", pyAddRoute, .varargs),
    ffi.methodDef("run", pyRun, .varargs),
    ffi.methodDef("shutdown", pyShutdown, .no_args),
    ffi.wrapStateMethod("get_route_count", ModuleState, .noargs, getRouteCount),
    ffi.wrapStateMethod("redis_get", ModuleState, .onearg, redisGet),
    ffi.wrapStateMethod("redis_set", ModuleState, .fastcall, redisSet),
    ffi.wrapStateMethod("redis_setex", ModuleState, .fastcall, redisSetex),
    ffi.wrapStateMethod("redis_del", ModuleState, .fastcall, redisDel),
    ffi.wrapStateMethod("redis_incr", ModuleState, .fastcall, redisIncr),
    ffi.wrapStateMethod("redis_expire", ModuleState, .fastcall, redisExpire),
    ffi.wrapStateMethod("redis_ttl", ModuleState, .onearg, redisTtl),
    ffi.wrapStateMethod("redis_exists", ModuleState, .fastcall, redisExists),
    ffi.wrapStateMethod("redis_ping", ModuleState, .noargs, redisPing),
    ffi.wrapStateMethod("pg_execute", ModuleState, .fastcall, pgExecute),
    ffi.wrapStateMethod("pg_fetch_one", ModuleState, .fastcall, pgFetchOne),
    ffi.wrapStateMethod("pg_fetch_all", ModuleState, .fastcall, pgFetchAll),
});

fn moduleExec(mod: ?*PyObject) callconv(.c) c_int {
    const m = mod orelse return -1;
    const state: *ModuleState = getState(m) orelse return -1;
    state.py_handlers = .{null} ** MAX_HANDLERS;
    state.py_handler_count = 0;
    state.handler_flags = .{HandlerFlags{}} ** MAX_HANDLERS;
    state.future_types = .{};

    futures.initTypes(m, &state.future_types, .{
        .future = &type_slots.future_type_spec,
        .task = &type_slots.task_type_spec,
        .future_iter = &type_slots.future_iter_type_spec,
    }) catch {
        if (!ffi.errOccurred()) ffi.errSetString(ffi.exc.RuntimeError(), "failed to initialize future types");
        return -1;
    };

    row.initType(m) catch {
        if (!ffi.errOccurred()) ffi.errSetString(ffi.exc.RuntimeError(), "failed to initialize Row type");
        return -1;
    };

    request.initType(m) catch {
        if (!ffi.errOccurred()) ffi.errSetString(ffi.exc.RuntimeError(), "failed to initialize Request type");
        return -1;
    };

    return 0;
}

fn moduleTraverse(mod: ?*PyObject, visit: ffi.VisitProc, arg: ?*anyopaque) callconv(.c) c_int {
    const m = mod orelse return 0;
    const state: *ModuleState = getState(m) orelse return 0;
    if (futures.traverseTypes(&state.future_types, visit, arg) != 0) return -1;
    const rc = ffi.traverseArgs(state.py_handlers[0..state.py_handler_count], visit, arg);
    if (rc != 0) return rc;
    return 0;
}

fn moduleClear(mod: ?*PyObject) callconv(.c) c_int {
    const m = mod orelse return 0;
    const state: *ModuleState = getState(m) orelse return 0;
    futures.clearTypes(&state.future_types);
    ffi.decrefArgs(&state.py_handlers);
    state.py_handler_count = 0;
    return 0;
}

fn moduleFree(mod_ptr: ?*anyopaque) callconv(.c) void {
    if (mod_ptr) |ptr| {
        _ = moduleClear(@ptrCast(@alignCast(ptr)));
    }
}

const module_slots = ffi.table(ffi.ModuleSlot, .{
    ffi.moduleSlot(ffi.ModSlot.exec, moduleExec),
    ffi.moduleSlot(ffi.ModSlot.multiple_interpreters, ffi.MOD_PER_INTERPRETER_GIL_SUPPORTED),
});

var module_def = ffi.moduleDef(
    "necro.core",
    &methods,
    @sizeOf(ModuleState),
    &module_slots,
    &moduleTraverse,
    &moduleClear,
    &moduleFree,
);

pub fn pyInitCore() callconv(.c) ?*PyObject {
    return ffi.moduleDefInit(&module_def);
}

pub fn releaseHandlers(mod: ?*PyObject) void {
    const m = mod orelse return;
    const state = getState(m) orelse return;
    ffi.decrefArgs(&state.py_handlers);
    state.handler_flags = .{HandlerFlags{}} ** MAX_HANDLERS;
    state.py_handler_count = 0;
}
