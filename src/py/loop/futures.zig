//! Zig-native futures for the necro async loop.

const std = @import("std");
const necro = @import("necro");
const ffi = @import("../ffi.zig");
const resp = necro.redis;
const stmt = necro.pg.stmt;

const c = ffi.c; // needed by callback section - cleanup pending
const PyObject = ffi.PyObject;
const PyTypeObject = ffi.PyTypeObject;
const VisitProc = ffi.VisitProc;

const MAX_REDIS_ARGS = 7;
const MAX_PG_ARGS = 3;

/// Fixed-capacity owned reference slots. `clear` and `traverse` keep the
/// count in sync with the slots - callers can't decref without resetting.
fn Args(comptime MAX: comptime_int) type {
    return struct {
        slots: [MAX]?*PyObject = [_]?*PyObject{null} ** MAX,
        count: u8 = 0,

        const Self = @This();

        pub fn push(self: *Self, ref: *PyObject) void {
            std.debug.assert(self.count < MAX);
            self.slots[self.count] = ffi.increfBorrowed(ref);
            self.count += 1;
        }

        pub fn clear(self: *Self) void {
            ffi.decrefArgs(self.slots[0..self.count]);
            self.count = 0;
        }

        pub fn traverse(self: *const Self, visit: VisitProc, arg: ?*anyopaque) c_int {
            return ffi.traverseArgs(self.slots[0..self.count], visit, arg);
        }
    };
}

pub const TypeState = extern struct {
    future_type: ?*PyObject = null,
    task_type: ?*PyObject = null,
    future_iter_type: ?*PyObject = null,
};

const TypeSpecs = struct {
    future: *const ffi.TypeSpec,
    task: *const ffi.TypeSpec,
    future_iter: *const ffi.TypeSpec,
};

const Step = union(enum) {
    none,
    redis: RedisStep,
    pg: PgStep,
};

pub const SubmittedYield = union(enum) {
    redis: RedisYield,
    pg: PgYield,
};

const FutureState = enum(u8) {
    pending,
    cancelled,
    finished,
};

pub const FutureObject = struct {
    ob_base: PyObject,
    type_state: ?*TypeState = null,
    weakreflist: ?*PyObject = null,
    result: ?*PyObject = null,
    exception: ?*PyObject = null,
    exception_tb: ?*PyObject = null,
    cancel_message: ?*PyObject = null,
    state: FutureState = .pending,
    submitted: bool = false,
    step: Step = .none,
};

pub const TaskObject = struct {
    future: FutureObject,
    coro: ?*PyObject = null,
    context: ?*PyObject = null,
    name: ?*PyObject = null,
    num_cancels_requested: u32 = 0,
};

pub const FutureIterObject = struct {
    ob_base: PyObject,
    future: ?*PyObject = null,
    yielded: bool = false,
};

pub fn initTypes(mod: *PyObject, type_state: *TypeState, specs: TypeSpecs) ffi.PythonError!void {
    clearTypes(type_state);

    const weaklist_offset = @offsetOf(FutureObject, "weakreflist");

    const future_iter_type = try ffi.typeFromModuleAndSpec(mod, specs.future_iter, null);
    errdefer ffi.decref(future_iter_type);

    const future_type = try ffi.typeFromModuleAndSpec(mod, specs.future, null);
    errdefer ffi.decref(future_type);
    const future_tp: *PyTypeObject = @ptrCast(@alignCast(future_type));
    future_tp.tp_weaklistoffset = @intCast(weaklist_offset);

    const task_bases = try ffi.tupleNew(1);
    defer ffi.decref(task_bases);
    try ffi.tupleSetItem(task_bases, 0, ffi.increfBorrowed(future_type));
    const task_type = try ffi.typeFromModuleAndSpec(mod, specs.task, task_bases);
    errdefer ffi.decref(task_type);
    const task_tp: *PyTypeObject = @ptrCast(@alignCast(task_type));
    task_tp.tp_weaklistoffset = @intCast(weaklist_offset);

    try ffi.setAttrRaw(mod, "Future", future_type);
    try ffi.setAttrRaw(mod, "Task", task_type);

    type_state.future_type = future_type;
    type_state.task_type = task_type;
    type_state.future_iter_type = future_iter_type;
}

pub fn clearTypes(type_state: *TypeState) void {
    inline for (std.meta.fields(TypeState)) |field| {
        if (@field(type_state, field.name)) |obj| ffi.decref(obj);
    }
    type_state.* = .{};
}

pub fn traverseTypes(type_state: *const TypeState, visit: VisitProc, arg: ?*anyopaque) c_int {
    inline for (std.meta.fields(TypeState)) |field| {
        if (@field(type_state, field.name)) |obj| {
            const rc = visit.?(@ptrCast(@constCast(obj)), arg);
            if (rc != 0) return rc;
        }
    }
    return 0;
}

fn allocFuture(type_obj: *PyObject, type_state: *TypeState) ffi.PythonError!*FutureObject {
    const self = try ffi.alloc(FutureObject, type_obj);
    self.type_state = type_state;
    return self;
}

fn allocTask(type_obj: *PyObject, type_state: *TypeState) ffi.PythonError!*TaskObject {
    const self = try ffi.alloc(TaskObject, type_obj);
    self.future.type_state = type_state;
    return self;
}

fn coerceException(value: *PyObject) ?*PyObject {
    if (ffi.isTypeObject(value)) return ffi.callObjectRaw(value, null) catch null;
    ffi.incref(value);
    return value;
}

fn isManagedFuture(type_state: *const TypeState, obj: *PyObject) bool {
    const future_type = type_state.future_type orelse return false;
    const future_tp: *PyTypeObject = @ptrCast(@alignCast(future_type));
    return ffi.isSubtype(ffi.objType(obj), future_tp);
}

pub fn consumeYield(
    type_state: *const TypeState,
    yielded: *PyObject,
    py_coro: *PyObject,
    redis_buf: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*stmt.Cache,
    pg_conn_prepared: ?*[stmt.STMT_CACHE_CAPACITY]bool,
) !SubmittedYield {
    if (!isManagedFuture(type_state, yielded)) return error.UnknownFutureType;
    const future: *FutureObject = @ptrCast(@alignCast(yielded));
    if (future.state != .pending or future.submitted) return error.InvalidFutureState;
    future.submitted = true;

    return switch (future.step) {
        .none => error.UnknownFutureType,
        .redis => |*step| try submitRedis(yielded, py_coro, step, redis_buf),
        .pg => |*step| try submitPg(yielded, py_coro, step, pg_buf, pg_stmt_cache, pg_conn_prepared),
    };
}

pub fn setResult(obj: *PyObject, result: *PyObject) !void {
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    if (future.state != .pending) return error.InvalidFutureState;
    ffi.clearOptional(&future.result);
    ffi.clearOptional(&future.exception);
    ffi.clearOptional(&future.exception_tb);
    future.result = ffi.increfBorrowed(result);
    future.state = .finished;
}

pub fn setException(obj: *PyObject, exc: *PyObject) !void {
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    if (future.state != .pending) return error.InvalidFutureState;
    const owned = coerceException(exc) orelse return error.PythonError;
    ffi.clearOptional(&future.result);
    ffi.clearOptional(&future.exception);
    ffi.clearOptional(&future.exception_tb);
    future.exception = owned;
    future.state = .finished;
}

// ── Slot / method implementations (merged from callbacks.zig) ───────

fn clearFutureBase(self: *FutureObject) void {
    ffi.clearOptional(&self.result);
    ffi.clearOptional(&self.exception);
    ffi.clearOptional(&self.exception_tb);
    ffi.clearOptional(&self.cancel_message);
    switch (self.step) {
        .none => {},
        .redis => |*r| r.args.clear(),
        .pg => |*p| p.args.clear(),
    }
    self.step = .none;
    self.type_state = null;
    self.state = .pending;
    self.submitted = false;
}

pub fn futureTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return 0));
    const refs = [_]?*PyObject{ self.result, self.exception, self.exception_tb, self.cancel_message };
    const rc = ffi.traverseArgs(&refs, visit, arg);
    if (rc != 0) return rc;
    return switch (self.step) {
        .none => 0,
        .redis => |*r| r.args.traverse(visit, arg),
        .pg => |*p| p.args.traverse(visit, arg),
    };
}

pub fn taskTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const rc = futureTraverse(self_obj, visit, arg);
    if (rc != 0) return rc;
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return 0));
    const refs = [_]?*PyObject{ self.coro, self.context, self.name };
    return ffi.traverseArgs(&refs, visit, arg);
}

pub fn futureClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return 0));
    clearFutureBase(self);
    return 0;
}

pub fn taskClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return 0));
    ffi.clearOptional(&self.coro);
    ffi.clearOptional(&self.context);
    ffi.clearOptional(&self.name);
    _ = futureClear(@ptrCast(self));
    self.num_cancels_requested = 0;
    return 0;
}

pub fn futureDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *FutureObject = @ptrCast(@alignCast(obj));
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    _ = futureClear(obj);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn taskDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *TaskObject = @ptrCast(@alignCast(obj));
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    _ = taskClear(obj);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.future.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn futureIterDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    ffi.clearOptional(&self.future);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn futureIterSelf(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    ffi.incref(obj);
    return obj;
}

fn makeCancelledError(message: ?*PyObject) ?*PyObject {
    const excs = ffi.importModuleRaw("asyncio.exceptions") catch return null;
    defer ffi.decref(excs);
    const cancelled = ffi.getAttrRaw(excs, "CancelledError") catch return null;
    defer ffi.decref(cancelled);
    if (message) |msg| {
        const args = ffi.tupleNew(1) catch return null;
        errdefer ffi.decref(args);
        ffi.tupleSetItem(args, 0, ffi.increfBorrowed(msg)) catch return null;
        const exc = ffi.callObjectRaw(cancelled, args) catch return null;
        ffi.decref(args);
        return exc;
    }
    return ffi.callObjectRaw(cancelled, null) catch return null;
}

fn raiseStoredException(exc: *PyObject) ?*PyObject {
    const exc_type: *PyObject = @ptrCast(@alignCast(c.Py_TYPE(exc)));
    c.PyErr_SetObject(exc_type, exc);
    return null;
}

pub fn futureIterNext(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    const future_obj = self.future orelse return null;
    const future: *FutureObject = @ptrCast(@alignCast(future_obj));

    if (!self.yielded and future.state == .pending) {
        self.yielded = true;
        ffi.incref(future_obj);
        return future_obj;
    }

    if (future.state == .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "await wasn't used with future");
        return null;
    }

    if (future.state == .cancelled) {
        const cancelled = makeCancelledError(future.cancel_message) orelse return null;
        defer ffi.decref(cancelled);
        return raiseStoredException(cancelled);
    }
    if (future.exception) |exc| return raiseStoredException(exc);

    c.PyErr_SetObject(c.PyExc_StopIteration, future.result orelse ffi.none());
    return null;
}

pub fn futureAwait(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "missing future");
        return null;
    };
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    const type_state = future.type_state orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future type state missing");
        return null;
    };
    const iter_type = type_state.future_iter_type orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future iterator type missing");
        return null;
    };
    const iter = ffi.alloc(FutureIterObject, iter_type) catch return null;
    iter.future = ffi.increfBorrowed(obj);
    return @ptrCast(iter);
}

pub fn futureDoneMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.boolFromBool(self.state != .pending);
}

pub fn futureCancelledMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.boolFromBool(self.state == .cancelled);
}

pub fn futureResultMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    switch (self.state) {
        .pending => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "Result is not set.");
            return null;
        },
        .cancelled => {
            const cancelled = makeCancelledError(self.cancel_message) orelse return null;
            defer ffi.decref(cancelled);
            return raiseStoredException(cancelled);
        },
        .finished => {},
    }
    if (self.exception) |exc| return raiseStoredException(exc);
    if (self.result) |result| {
        ffi.incref(result);
        return result;
    }
    return ffi.getNone();
}

pub fn futureExceptionMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    switch (self.state) {
        .pending => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "Exception is not set.");
            return null;
        },
        .cancelled => {
            const cancelled = makeCancelledError(self.cancel_message) orelse return null;
            defer ffi.decref(cancelled);
            return raiseStoredException(cancelled);
        },
        .finished => {},
    }
    if (self.exception) |exc| {
        ffi.incref(exc);
        return exc;
    }
    return ffi.getNone();
}

pub fn futureCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    _ = kwargs;
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.state != .pending) return ffi.boolFromBool(false);
    if (args) |tuple| {
        if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) > 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "cancel() expects at most one argument");
            return null;
        }
        if (ffi.tupleSize(tuple) == 1) {
            ffi.clearOptional(&self.cancel_message);
            self.cancel_message = ffi.increfBorrowed(ffi.tupleGetItem(tuple, 0) orelse return null);
        }
    }
    self.state = .cancelled;
    return ffi.boolFromBool(true);
}

pub fn futureSetResultMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.state != .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future already done");
        return null;
    }
    ffi.clearOptional(&self.result);
    ffi.clearOptional(&self.exception);
    ffi.clearOptional(&self.exception_tb);
    self.result = ffi.increfBorrowed(arg orelse ffi.none());
    self.state = .finished;
    return ffi.getNone();
}

pub fn futureSetExceptionMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    const value = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "set_exception() missing exception");
        return null;
    };
    if (self.state != .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future already done");
        return null;
    }
    const exc = coerceException(value) orelse return null;
    ffi.clearOptional(&self.result);
    ffi.clearOptional(&self.exception);
    ffi.clearOptional(&self.exception_tb);
    self.exception = exc;
    self.state = .finished;
    return ffi.getNone();
}

pub fn futureRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    const state_name = switch (self.state) {
        .pending => "pending",
        .cancelled => "cancelled",
        .finished => if (self.exception != null) "errored" else "finished",
    };
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "<necro.Future state={s}>", .{state_name}) catch return null;
    return ffi.unicodeFromSlice(text.ptr, text.len) catch null;
}

pub fn taskGetCoroMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.coro) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskGetContextMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.context) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskGetNameMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.name) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskSetNameMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    const value = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "set_name() missing value");
        return null;
    };
    ffi.clearOptional(&self.name);
    if (ffi.isString(value)) {
        self.name = ffi.increfBorrowed(value);
    } else {
        self.name = ffi.objectStr(value) catch return null;
    }
    return ffi.getNone();
}

pub fn taskCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    self.num_cancels_requested += 1;
    return futureCancelMethod(@ptrCast(self), args, kwargs);
}

pub fn taskCancellingMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.longFromLong(@intCast(self.num_cancels_requested)) catch null;
}

pub fn taskUncancelMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.num_cancels_requested > 0) self.num_cancels_requested -= 1;
    return ffi.longFromLong(@intCast(self.num_cancels_requested)) catch null;
}

pub fn taskRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    var buf: [128]u8 = undefined;
    const name = if (self.name) |obj| std.mem.span(ffi.unicodeAsUTF8(obj) catch "task") else "task";
    const text = std.fmt.bufPrint(&buf, "<necro.Task name={s}>", .{name}) catch return null;
    return ffi.unicodeFromSlice(text.ptr, text.len) catch null;
}

fn typeStateFromObject(obj: *PyObject) ffi.PythonError!*TypeState {
    const raw = try ffi.typeGetModuleState(c.Py_TYPE(obj));
    return @ptrCast(@alignCast(raw));
}

const FutureInitError = ffi.PythonError || error{
    FutureArgsMustBeTuple,
    FutureTakesNoPositionalArgs,
    FutureKwargsMustBeDict,
    FutureUnexpectedKeyword,
};

const TaskInitError = ffi.PythonError || error{
    TaskMissingCoroutine,
    TaskArgsMustBeTuple,
    TaskTakesExactlyOnePositionalArg,
    TaskKwargsMustBeDict,
    TaskUnexpectedKeyword,
};

fn initConstructedFuture(self_obj: *PyObject, args: ?*PyObject, kwargs: ?*PyObject) FutureInitError!void {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj));
    if (args) |tuple| {
        if (!ffi.isTuple(tuple)) return error.FutureArgsMustBeTuple;
        if (ffi.tupleSize(tuple) != 0) return error.FutureTakesNoPositionalArgs;
    }
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) return error.FutureKwargsMustBeDict;
        const kw_loop = ffi.dictGetItemString(kw, "loop");
        const allowed: isize = if (kw_loop != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) return error.FutureUnexpectedKeyword;
    }

    _ = futureClear(self_obj);
    self.type_state = try typeStateFromObject(self_obj);
}

fn initConstructedTask(self_obj: *PyObject, args: ?*PyObject, kwargs: ?*PyObject) TaskInitError!void {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj));
    const tuple = args orelse return error.TaskMissingCoroutine;
    if (!ffi.isTuple(tuple)) return error.TaskArgsMustBeTuple;
    if (ffi.tupleSize(tuple) != 1) return error.TaskTakesExactlyOnePositionalArg;
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) return error.TaskKwargsMustBeDict;
    }

    _ = taskClear(self_obj);

    self.future.type_state = try typeStateFromObject(self_obj);
    self.coro = ffi.increfBorrowed(ffi.tupleGetItem(tuple, 0).?);

    if (kwargs) |kw| {
        const kw_loop = ffi.dictGetItemString(kw, "loop");
        const kw_name = ffi.dictGetItemString(kw, "name");
        const kw_context = ffi.dictGetItemString(kw, "context");
        const kw_eager = ffi.dictGetItemString(kw, "eager_start");
        var allowed: isize = 0;
        if (kw_loop != null) allowed += 1;
        if (kw_name != null) allowed += 1;
        if (kw_context != null) allowed += 1;
        if (kw_eager != null) allowed += 1;
        if (ffi.dictSize(kw) != allowed) return error.TaskUnexpectedKeyword;
        if (kw_context) |ctx| self.context = ffi.increfBorrowed(ctx);
        if (kw_name) |n| {
            if (ffi.isString(n)) {
                self.name = ffi.increfBorrowed(n);
            } else {
                self.name = try ffi.objectStr(n);
            }
        }
    }
}

pub fn futureTypeNew(tp_obj: ?*c.PyTypeObject, _: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future type is null");
        return null;
    };
    return tp.tp_alloc.?(tp, 0);
}

fn setUnhandledInitError(err: anyerror) c_int {
    if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
    return -1;
}

pub fn futureTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    initConstructedFuture(self_obj orelse return -1, args, kwargs) catch |err| switch (err) {
        error.FutureArgsMustBeTuple => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() arguments must be a tuple");
            return -1;
        },
        error.FutureTakesNoPositionalArgs => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() takes no positional arguments");
            return -1;
        },
        error.FutureKwargsMustBeDict => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() keyword arguments must be a dict");
            return -1;
        },
        error.FutureUnexpectedKeyword => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() got an unexpected keyword argument");
            return -1;
        },
        error.ModuleStateError => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "future type state missing");
            return -1;
        },
        else => return setUnhandledInitError(err),
    };
    return 0;
}

pub fn taskTypeNew(tp_obj: ?*c.PyTypeObject, _: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "task type is null");
        return null;
    };
    return tp.tp_alloc.?(tp, 0);
}

pub fn taskTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    initConstructedTask(self_obj orelse return -1, args, kwargs) catch |err| switch (err) {
        error.TaskMissingCoroutine => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() missing coroutine");
            return -1;
        },
        error.TaskArgsMustBeTuple => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() arguments must be a tuple");
            return -1;
        },
        error.TaskTakesExactlyOnePositionalArg => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() takes exactly one positional argument");
            return -1;
        },
        error.TaskKwargsMustBeDict => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() keyword arguments must be a dict");
            return -1;
        },
        error.TaskUnexpectedKeyword => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() got an unexpected keyword argument");
            return -1;
        },
        error.ModuleStateError => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "task type state missing");
            return -1;
        },
        else => return setUnhandledInitError(err),
    };
    return 0;
}

pub const PgMode = enum(u8) {
    execute,
    fetch_one,
    fetch_all,
};

pub const PgYield = struct {
    py_coro: *PyObject,
    py_future: *PyObject,
    bytes_written: usize,
    mode: PgMode,
    stmt_idx: u16,
    model_cls: ?*PyObject,
};

const PgStep = struct {
    mode: PgMode,
    args: Args(MAX_PG_ARGS) = .{},
};

pub fn createPgFuture(
    comptime mode: PgMode,
    type_state: *TypeState,
    args: []const *PyObject,
) ffi.PythonError!*PyObject {
    if (args.len > MAX_PG_ARGS) return error.TypeError;
    const type_obj = type_state.future_type orelse return error.PythonError;
    const self = try allocFuture(type_obj, type_state);

    var step = PgStep{ .mode = mode };
    for (args) |arg| step.args.push(arg);
    self.step = .{ .pg = step };

    return @ptrCast(self);
}

fn submitPg(
    yielded: *PyObject,
    py_coro: *PyObject,
    step: *const PgStep,
    buf: ?[]u8,
    stmt_cache: ?*stmt.Cache,
    prepared: ?*[stmt.STMT_CACHE_CAPACITY]bool,
) !SubmittedYield {
    const out = buf orelse return error.NoPgSendBuffer;
    const cache = stmt_cache orelse return error.NoPgStmtCache;
    const prep = prepared orelse return error.NoPgConnPrepared;

    const sql_obj = step.args.slots[0] orelse return error.InvalidState;
    const params_obj = step.args.slots[1] orelse return error.InvalidState;
    const sql = std.mem.span(try ffi.unicodeAsUTF8(sql_obj));

    var params: stmt.ParamBuffer = .{};
    try params.fromTuple(params_obj);

    const encoded = try cache.encode(out, sql, prep, &params);

    const model_cls = switch (step.mode) {
        .execute => null,
        else => if (step.args.count > 2) step.args.slots[2] else null,
    };

    return .{
        .pg = .{
            .py_coro = py_coro,
            .py_future = ffi.increfBorrowed(yielded),
            .bytes_written = encoded.bytes_written,
            .mode = step.mode,
            .stmt_idx = encoded.stmt_idx,
            .model_cls = if (model_cls) |cls| ffi.increfBorrowed(cls) else null,
        },
    };
}

const RedisStep = struct {
    cmd: []const u8,
    args: Args(MAX_REDIS_ARGS) = .{},
};
pub const RedisYield = struct {
    py_coro: *PyObject,
    py_future: *PyObject,
    bytes_written: usize,
};

pub fn createRedisFuture(
    comptime cmd: []const u8,
    type_state: *TypeState,
    args: []const *PyObject,
) ffi.PythonError!*PyObject {
    if (args.len > MAX_REDIS_ARGS) return error.TypeError;
    const type_obj = type_state.future_type orelse return error.PythonError;
    const self = try allocFuture(type_obj, type_state);

    var step = RedisStep{ .cmd = cmd };
    for (args) |arg| step.args.push(arg);
    self.step = .{ .redis = step };

    return @ptrCast(self);
}

fn submitRedis(
    yielded: *PyObject,
    py_coro: *PyObject,
    step: *const RedisStep,
    buf: ?[]u8,
) !SubmittedYield {
    const out = buf orelse return error.NoRedisBuffer;

    var arg_slices: [MAX_REDIS_ARGS][]const u8 = undefined;
    var i: usize = 0;
    while (i < step.args.count) : (i += 1) {
        const obj = step.args.slots[i] orelse return error.InvalidState;
        if (!ffi.isString(obj)) return error.TypeError;
        const text = try ffi.unicodeAsUTF8(obj);
        arg_slices[i] = std.mem.span(text);
    }

    const written = try resp.writeCommand(out, step.cmd, arg_slices[0..step.args.count]);

    return .{
        .redis = .{
            .py_coro = py_coro,
            .py_future = ffi.increfBorrowed(yielded),
            .bytes_written = written,
        },
    };
}
