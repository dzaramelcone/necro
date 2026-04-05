//! Three-layer CPython FFI bridge.
//!
//! Layer 1: Raw CPython C API bindings via @cImport.
//! Layer 2: Zig-idiomatic wrappers with error handling and refcount helpers.
//! Layer 3: Comptime function wrapper — converts Zig functions to CPython
//!          callables, handling error union → PyErr_SetString conversion.

const std = @import("std");

// ── Layer 1: Raw CPython C API ──────────────────────────────────────

pub const c = @cImport({
    @cInclude("Python.h");
});

/// Opaque PyObject pointer from CPython.
pub const PyObject = c.PyObject;

// PyEval_SaveThread/RestoreThread use PyThreadState*, but the imported type
// is not useful to us here. We only need the opaque saved thread-state token.
pub extern fn PyEval_SaveThread() ?*anyopaque;
pub extern fn PyEval_RestoreThread(?*anyopaque) void;

// ── Layer 2: Zig-idiomatic wrappers ─────────────────────────────────

pub const PythonError = error{
    PythonError,
    ImportError,
    AttributeError,
    TypeError,
    CallError,
    ConversionError,
    ModuleStateError,
};

/// Initialize the CPython interpreter.
pub fn init() void {
    c.Py_Initialize();
}

/// Finalize the CPython interpreter.
pub fn deinit() void {
    if (c.Py_IsInitialized() != 0) {
        c.Py_Finalize();
    }
}

/// Execute a Python code string. Returns error.PythonError on failure.
pub fn runString(code: [*:0]const u8) PythonError!void {
    if (c.PyRun_SimpleString(code) != 0) return error.PythonError;
}

/// Import a Python module by name without printing exceptions.
pub fn importModuleRaw(name: [*:0]const u8) PythonError!*PyObject {
    return c.PyImport_ImportModule(name) orelse error.ImportError;
}

/// Import a Python module by name. Caller must decref the returned object.
pub fn importModule(name: [*:0]const u8) PythonError!*PyObject {
    return importModuleRaw(name) catch |err| {
        errPrint();
        return err;
    };
}

/// Get an attribute from a Python object without printing exceptions.
pub fn getAttrRaw(obj: *PyObject, attr: [*:0]const u8) PythonError!*PyObject {
    return c.PyObject_GetAttrString(obj, attr) orelse error.AttributeError;
}

/// Get an attribute from a Python object. Caller must decref the result.
pub fn getAttr(obj: *PyObject, attr: [*:0]const u8) PythonError!*PyObject {
    return getAttrRaw(obj, attr) catch |err| {
        errPrint();
        return err;
    };
}

/// Get an attribute if present, clearing AttributeError for missing attrs.
pub fn getAttrOptional(obj: *PyObject, attr: [*:0]const u8) PythonError!?*PyObject {
    return c.PyObject_GetAttrString(obj, attr) orelse {
        if (c.PyErr_ExceptionMatches(c.PyExc_AttributeError) != 0) {
            c.PyErr_Clear();
            return null;
        }
        return error.AttributeError;
    };
}

/// Set an attribute on a Python object without printing exceptions.
pub fn setAttrRaw(obj: *PyObject, attr: [*:0]const u8, value: *PyObject) PythonError!void {
    if (c.PyObject_SetAttrString(obj, attr, value) != 0) return error.AttributeError;
}

/// Set an attribute on a Python object.
pub fn setAttr(obj: *PyObject, attr: [*:0]const u8, value: *PyObject) PythonError!void {
    return setAttrRaw(obj, attr, value) catch |err| {
        errPrint();
        return err;
    };
}

/// Call a Python callable with optional args tuple without printing exceptions.
pub fn callObjectRaw(callable: *PyObject, args: ?*PyObject) PythonError!*PyObject {
    return c.PyObject_CallObject(callable, args) orelse error.CallError;
}

/// Call a Python callable with optional args tuple. Caller must decref result.
pub fn callObject(callable: *PyObject, args: ?*PyObject) PythonError!*PyObject {
    return callObjectRaw(callable, args) catch |err| {
        errPrint();
        return err;
    };
}

/// Call a Python callable with kwargs without printing exceptions.
pub fn callObjectKwargsRaw(callable: *PyObject, args: ?*PyObject, kwargs: *PyObject) PythonError!*PyObject {
    return c.PyObject_Call(callable, args, kwargs) orelse error.CallError;
}

/// Vectorcall a Python callable with no arguments (PEP 590).
/// Fastest calling convention — no tuple creation, no method lookup.
pub fn vectorcallNoArgs(callable: *PyObject) PythonError!*PyObject {
    return c.PyObject_Vectorcall(callable, null, 0, null) orelse error.CallError;
}

/// Vectorcall a Python callable with a single positional argument (PEP 590).
/// Avoids tuple creation — passes a stack array directly.
pub fn vectorcallOneArg(callable: *PyObject, arg: *PyObject) PythonError!*PyObject {
    var args = [1]?*PyObject{arg};
    return c.PyObject_Vectorcall(callable, @ptrCast(&args), 1, null) orelse error.CallError;
}

/// Call a Python callable with no args using the CPython fast path.
pub fn callNoArgs(callable: *PyObject) PythonError!*PyObject {
    return c.PyObject_CallNoArgs(callable) orelse error.CallError;
}

/// Call a Python callable with one positional arg using the CPython fast path.
pub fn callOneArg(callable: *PyObject, arg: *PyObject) PythonError!*PyObject {
    return c.PyObject_CallOneArg(callable, arg) orelse error.CallError;
}

/// Call a Python callable with args tuple and kwargs dict. Caller must decref result.
pub fn callObjectKwargs(callable: *PyObject, args: ?*PyObject, kwargs: *PyObject) PythonError!*PyObject {
    return callObjectKwargsRaw(callable, args, kwargs) catch |err| {
        errPrint();
        return err;
    };
}

pub fn callMethodNoArgs(obj: *PyObject, method: [*:0]const u8) PythonError!*PyObject {
    const callable = try getAttrRaw(obj, method);
    defer decref(callable);
    return callNoArgs(callable);
}

pub fn callMethodOneArg(obj: *PyObject, method: [*:0]const u8, arg: *PyObject) PythonError!*PyObject {
    const callable = try getAttrRaw(obj, method);
    defer decref(callable);
    return callOneArg(callable, arg);
}

// ── Reference counting ──────────────────────────────────────────────

pub fn incref(obj: *PyObject) void {
    c.Py_IncRef(obj);
}

pub fn decref(obj: *PyObject) void {
    c.Py_DecRef(obj);
}

pub fn increfBorrowed(obj: *PyObject) *PyObject {
    incref(obj);
    return obj;
}

pub fn xincref(obj: ?*PyObject) void {
    if (obj) |o| c.Py_IncRef(o);
}

pub fn xdecref(obj: ?*PyObject) void {
    if (obj) |o| c.Py_DecRef(o);
}

// ── Error handling ──────────────────────────────────────────────────

/// Check if a Python exception is currently set.
pub fn errOccurred() bool {
    return c.PyErr_Occurred() != null;
}

/// Clear any pending Python exception.
pub fn errClear() void {
    c.PyErr_Clear();
}

/// Set a Python exception with a message string.
pub fn errSetString(exc_type: *PyObject, message: [*:0]const u8) void {
    c.PyErr_SetString(exc_type, message);
}

/// Print and clear the current Python exception (to stderr).
pub fn errPrint() void {
    c.PyErr_Print();
}

/// Properly close a suspended coroutine/generator by calling its .close() method.
/// This throws GeneratorExit into the coroutine, allowing finally blocks to run
/// and preventing GC corruption from half-unwound frames.
/// Must be called BEFORE decref on any coroutine that was suspended (yielded).
pub fn coroutineClose(coro: *PyObject) void {
    const close_result = c.PyObject_CallMethod(coro, "close", null);
    if (close_result) |r| {
        c.Py_DecRef(r);
    } else {
        c.PyErr_Clear();
    }
}

/// Fast coroutine/generator send — bypasses method lookup, tuple creation,
/// and StopIteration exception overhead. Uses the am_send slot directly.
pub const SendResult = enum(c_int) { @"return" = 0, @"error" = -1, next = 1 };
pub fn iterSend(iter: *PyObject, arg: *PyObject) struct { result: ?*PyObject, status: SendResult } {
    var presult: ?*PyObject = null;
    const status: SendResult = @enumFromInt(c.PyIter_Send(iter, arg, &presult));
    return .{ .result = presult, .status = status };
}

// ── Object creation helpers ─────────────────────────────────────────

pub fn longFromLong(v: c_long) PythonError!*PyObject {
    return c.PyLong_FromLong(v) orelse return error.PythonError;
}

pub fn longAsLong(obj: *PyObject) PythonError!c_long {
    const val = c.PyLong_AsLong(obj);
    if (val == -1 and c.PyErr_Occurred() != null) return error.ConversionError;
    return val;
}

pub fn floatFromDouble(v: f64) PythonError!*PyObject {
    return c.PyFloat_FromDouble(v) orelse return error.PythonError;
}

pub fn floatAsDouble(obj: *PyObject) PythonError!f64 {
    const val = c.PyFloat_AsDouble(obj);
    if (val == -1.0 and c.PyErr_Occurred() != null) return error.ConversionError;
    return val;
}

pub fn unicodeFromString(s: [*:0]const u8) PythonError!*PyObject {
    return c.PyUnicode_FromString(s) orelse return error.PythonError;
}

/// Create a Python str from a pointer + length. No null terminator needed.
/// One copy: src buffer → Python heap. Python manages the result.
pub fn unicodeFromSlice(ptr: [*]const u8, len: usize) PythonError!*PyObject {
    return c.PyUnicode_DecodeUTF8(ptr, @intCast(len), null) orelse return error.PythonError;
}

pub fn unicodeAsUTF8(obj: *PyObject) PythonError![*:0]const u8 {
    return c.PyUnicode_AsUTF8(obj) orelse error.ConversionError;
}

pub fn boolFromBool(v: bool) *PyObject {
    return c.PyBool_FromLong(@intFromBool(v));
}

/// Borrowed reference to None — no incref, do NOT decref.
/// Use for transient reads (e.g. passing to PyIter_Send which increfs internally).
pub fn none() *PyObject {
    return @ptrCast(&c._Py_NoneStruct);
}

/// Check if an object is None.
pub fn isNone(obj: *PyObject) bool {
    return obj == none();
}

/// New reference to None — caller must decref.
pub fn getNone() *PyObject {
    const n = none();
    incref(n);
    return n;
}

// ── Bytes operations ────────────────────────────────────────────────

/// Check if an object is bytes.
pub fn isBytes(obj: *PyObject) bool {
    return c.PyBytes_Check(obj) != 0;
}

/// Allocate a PyBytes with uninitialized buffer. Caller must decref.
/// Pass null data to get writable memory via bytesAsSlice.
pub fn bytesNew(len: isize) PythonError!*PyObject {
    return c.PyBytes_FromStringAndSize(null, len) orelse return error.PythonError;
}

/// Get a mutable pointer to the PyBytes internal buffer.
pub fn bytesAsSlice(obj: *PyObject, len: usize) [*]u8 {
    const ptr: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(obj));
    _ = len;
    return ptr;
}

/// Get PyBytes data as a const slice.
pub fn bytesData(obj: *PyObject) []const u8 {
    const ptr: [*]const u8 = @ptrCast(c.PyBytes_AS_STRING(obj));
    const len: usize = @intCast(c.PyBytes_GET_SIZE(obj));
    return ptr[0..len];
}

pub const BufferView = struct {
    raw: c.Py_buffer,
};

pub fn isMemoryView(obj: *PyObject) bool {
    return c.PyMemoryView_Check(obj) != 0;
}

pub fn getReadOnlyBuffer(obj: *PyObject) PythonError!BufferView {
    var view: c.Py_buffer = undefined;
    if (c.PyObject_GetBuffer(obj, &view, c.PyBUF_CONTIG_RO) != 0) return error.ConversionError;
    return .{ .raw = view };
}

pub fn bufferIsReadOnly(view: *const BufferView) bool {
    return view.raw.readonly != 0;
}

pub fn bufferData(view: *const BufferView) []const u8 {
    const buf_ptr = view.raw.buf orelse @panic("null Py_buffer.buf");
    const ptr: [*]const u8 = @ptrCast(@alignCast(buf_ptr));
    const len: usize = @intCast(view.raw.len);
    return ptr[0..len];
}

pub fn releaseBuffer(view: *BufferView) void {
    c.PyBuffer_Release(&view.raw);
    view.* = undefined;
}

// ── Tuple operations ────────────────────────────────────────────────

pub fn tupleNew(len: isize) PythonError!*PyObject {
    return c.PyTuple_New(len) orelse return error.PythonError;
}

/// Set item in tuple. Steals a reference to value.
pub fn tupleSetItem(tuple: *PyObject, index: isize, value: *PyObject) PythonError!void {
    if (c.PyTuple_SetItem(tuple, index, value) != 0) return error.PythonError;
}

// ── Dict operations ─────────────────────────────────────────────────

pub fn dictNew() PythonError!*PyObject {
    return c.PyDict_New() orelse return error.PythonError;
}

pub fn dictSetItemString(dict: *PyObject, key: [*:0]const u8, value: *PyObject) PythonError!void {
    if (c.PyDict_SetItemString(dict, key, value) != 0) return error.PythonError;
}

/// Set a dict item using a PyObject key (avoids temporary string creation).
pub fn dictSetItem(dict: *PyObject, key: *PyObject, value: *PyObject) PythonError!void {
    if (c.PyDict_SetItem(dict, key, value) != 0) return error.PythonError;
}

/// Returns a borrowed reference (do not decref).
pub fn dictGetItem(dict: *PyObject, key: *PyObject) ?*PyObject {
    return c.PyDict_GetItem(dict, key);
}

/// Returns a borrowed reference (do not decref).
pub fn dictGetItemString(dict: *PyObject, key: [*:0]const u8) ?*PyObject {
    return c.PyDict_GetItemString(dict, key);
}

// ── List operations ─────────────────────────────────────────────────

pub fn listNew(len: isize) PythonError!*PyObject {
    return c.PyList_New(len) orelse return error.PythonError;
}

pub fn listAppend(list: *PyObject, item: *PyObject) PythonError!void {
    if (c.PyList_Append(list, item) != 0) return error.PythonError;
}

// ── Layer 3: Comptime function wrapper ──────────────────────────────

/// Wrap a Zig function as a CPython method definition.
/// The Zig function must take no arguments (METH_NOARGS) and return
/// either *PyObject or PythonError!*PyObject.
pub fn wrapNoArgs(comptime name: [*:0]const u8, comptime func: fn () PythonError!*PyObject) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = &struct {
            fn wrapper(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
                return func() catch |err| {
                    c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                    return null;
                };
            }
        }.wrapper,
        .ml_flags = c.METH_NOARGS,
        .ml_doc = null,
    };
}

/// Wrap a Zig function as a CPython METH_VARARGS method definition.
/// The Zig function signature: fn(?*PyObject, ?*PyObject) callconv(.c) ?*PyObject
pub fn wrapVarArgs(comptime name: [*:0]const u8, comptime func: *const fn (?*PyObject, ?*PyObject) callconv(.c) ?*PyObject) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = func,
        .ml_flags = c.METH_VARARGS,
        .ml_doc = null,
    };
}

pub fn moduleStateRequired(comptime T: type, mod: *PyObject) PythonError!*T {
    const raw = moduleGetState(mod) orelse return error.ModuleStateError;
    return @ptrCast(@alignCast(raw));
}

fn raiseBoundaryError(err: anyerror) ?*PyObject {
    if (err == error.PythonError) return null;
    if (err == error.ModuleStateError) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module state not initialized");
        return null;
    }

    if (!errOccurred()) {
        c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
    }
    return null;
}

pub const StateMethodKind = enum {
    noargs,
    onearg,
    fastcall,
};

pub fn wrapStateMethod(
    comptime name: [*:0]const u8,
    comptime State: type,
    comptime kind: StateMethodKind,
    comptime func: anytype,
) c.PyMethodDef {
    return switch (kind) {
        .noargs => .{
            .ml_name = name,
            .ml_meth = @ptrCast(&struct {
                fn wrapper(self: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
                    const mod = self.?;
                    const state = moduleStateRequired(State, mod) catch |err| return raiseBoundaryError(err);
                    return func(state) catch |err| return raiseBoundaryError(err);
                }
            }.wrapper),
            .ml_flags = c.METH_NOARGS,
            .ml_doc = null,
        },
        .onearg => .{
            .ml_name = name,
            .ml_meth = @ptrCast(&struct {
                fn wrapper(self: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
                    const mod = self.?;
                    const state = moduleStateRequired(State, mod) catch |err| return raiseBoundaryError(err);
                    return func(state, arg.?) catch |err| return raiseBoundaryError(err);
                }
            }.wrapper),
            .ml_flags = c.METH_O,
            .ml_doc = null,
        },
        .fastcall => .{
            .ml_name = name,
            .ml_meth = @ptrCast(&struct {
                fn wrapper(self: ?*PyObject, args: [*]const *PyObject, nargs: c.Py_ssize_t) callconv(.c) ?*PyObject {
                    const mod = self.?;
                    const state = moduleStateRequired(State, mod) catch |err| return raiseBoundaryError(err);
                    return func(state, args, nargs) catch |err| return raiseBoundaryError(err);
                }
            }.wrapper),
            .ml_flags = c.METH_FASTCALL,
            .ml_doc = null,
        },
    };
}

/// Python str check.
pub fn isString(obj: *PyObject) bool {
    return c.PyUnicode_Check(obj) != 0;
}

/// Python dict check.
pub fn isDict(obj: *PyObject) bool {
    return c.PyDict_Check(obj) != 0;
}

/// Python tuple check.
pub fn isTuple(obj: *PyObject) bool {
    return c.PyTuple_Check(obj) != 0;
}

/// Python callable check.
pub fn isCallable(obj: *PyObject) bool {
    return c.PyCallable_Check(obj) != 0;
}

/// Get tuple item (borrowed reference — do NOT decref).
pub fn tupleGetItem(tuple: *PyObject, index: isize) ?*PyObject {
    return c.PyTuple_GetItem(tuple, index);
}

/// Get tuple size.
pub fn tupleSize(tuple: *PyObject) isize {
    return c.PyTuple_Size(tuple);
}

/// Get dict size.
pub fn dictSize(dict: *PyObject) isize {
    return c.PyDict_Size(dict);
}

/// Get Python object's string representation. Caller must decref.
pub fn objectStr(obj: *PyObject) PythonError!*PyObject {
    return c.PyObject_Str(obj) orelse error.ConversionError;
}

pub fn objectIsTrue(obj: *PyObject) PythonError!bool {
    const result = c.PyObject_IsTrue(obj);
    if (result < 0) return error.ConversionError;
    return result == 1;
}

/// Create a PyModuleDef with the given name and methods table.
/// The methods slice must be null-terminated (last entry all zeroes).
///
/// For single-phase init: pass m_size = -1, slots = null, no GC callbacks.
/// For multi-phase init (PEP 489): pass m_size = @sizeOf(State), slots = &slot_array,
///   and GC callbacks (traverse/clear/free) for any PyObject* in the state.
pub fn moduleDef(
    name: [*:0]const u8,
    methods: [*]const c.PyMethodDef,
    m_size: isize,
    slots: ?[*]const c.PyModuleDef_Slot,
    traverse: c.traverseproc,
    clear: c.inquiry,
    free: c.freefunc,
) c.PyModuleDef {
    return .{
        .m_base = std.mem.zeroes(c.PyModuleDef_Base),
        .m_name = name,
        .m_doc = null,
        .m_size = m_size,
        .m_methods = @constCast(methods),
        .m_slots = if (slots) |s| @constCast(s) else null,
        .m_traverse = traverse,
        .m_clear = clear,
        .m_free = free,
    };
}

/// Initialize a multi-phase module definition (PEP 489).
/// Returns a PyObject* that CPython uses to create the module per-interpreter.
pub fn moduleDefInit(def: *c.PyModuleDef) ?*PyObject {
    return c.PyModuleDef_Init(def);
}

/// Get the per-interpreter module state from a module object.
/// Returns null if the module has no state (m_size <= 0).
pub fn moduleGetState(mod: *PyObject) ?*anyopaque {
    return c.PyModule_GetState(mod);
}

pub fn typeGetModuleState(tp: *c.PyTypeObject) PythonError!*anyopaque {
    return c.PyType_GetModuleState(tp) orelse error.ModuleStateError;
}

/// Create a module from a PyModuleDef (single-phase init).
/// Caller must decref the result.
pub fn createModule(def: *c.PyModuleDef) PythonError!*PyObject {
    return c.PyModule_Create(def) orelse return error.PythonError;
}

// ── Tests ───────────────────────────────────────────────────────────

test "initialize and finalize python" {
    init();
    defer deinit();
    // If we get here without crashing, init/deinit works.
    try std.testing.expect(c.Py_IsInitialized() != 0);
}

test "run python string" {
    init();
    defer deinit();
    try runString("x = 1 + 1");
}

test "import module" {
    init();
    defer deinit();

    const sys = try importModule("sys");
    defer decref(sys);

    const version = try getAttr(sys, "version");
    defer decref(version);

    const version_str = try unicodeAsUTF8(version);
    const span = std.mem.span(version_str);
    // Python 3.14 version string starts with "3.14"
    try std.testing.expect(span.len > 0);
}

test "call python function" {
    init();
    defer deinit();

    try runString("def add(a, b): return a + b");

    const main_mod = try importModule("__main__");
    defer decref(main_mod);

    const add_fn = try getAttr(main_mod, "add");
    defer decref(add_fn);

    const args = try tupleNew(2);
    // tupleSetItem steals the reference — no decref on the items
    try tupleSetItem(args, 0, try longFromLong(3));
    try tupleSetItem(args, 1, try longFromLong(4));

    const result = try callObject(add_fn, args);
    defer decref(result);
    decref(args);

    const val = try longAsLong(result);
    try std.testing.expectEqual(@as(c_long, 7), val);
}

test "python exception handling" {
    init();
    defer deinit();

    // PyRun_SimpleString returns -1 on exception
    const err = runString("raise ValueError('test error')");
    try std.testing.expectError(error.PythonError, err);
}

test "reference counting" {
    init();
    defer deinit();

    // Create object, verify refcount management doesn't crash
    const obj = try longFromLong(42);
    incref(obj);
    decref(obj);
    decref(obj);

    // xincref/xdecref handle null safely
    xincref(null);
    xdecref(null);

    // Verify gc.collect() reports no issues
    try runString("import gc; gc.collect()");
}

test "unicode round-trip" {
    init();
    defer deinit();

    const obj = try unicodeFromString("hello necro");
    defer decref(obj);

    const back = try unicodeAsUTF8(obj);
    const span = std.mem.span(back);
    try std.testing.expect(std.mem.eql(u8, span, "hello necro"));
}

test "float round-trip" {
    init();
    defer deinit();

    const obj = try floatFromDouble(3.14);
    defer decref(obj);

    const val = try floatAsDouble(obj);
    try std.testing.expect(@abs(val - 3.14) < 0.001);
}

test "dict operations" {
    init();
    defer deinit();

    const dict = try dictNew();
    defer decref(dict);

    const val = try longFromLong(42);
    try dictSetItemString(dict, "key", val);
    decref(val);

    const got = dictGetItemString(dict, "key"); // borrowed ref
    try std.testing.expect(got != null);
    const got_val = try longAsLong(got.?);
    try std.testing.expectEqual(@as(c_long, 42), got_val);
}

test "list operations" {
    init();
    defer deinit();

    const list = try listNew(0);
    defer decref(list);

    const item = try longFromLong(99);
    try listAppend(list, item);
    decref(item);

    const size = c.PyList_Size(list);
    try std.testing.expectEqual(@as(isize, 1), size);
}

test "tuple operations" {
    init();
    defer deinit();

    const tuple = try tupleNew(2);
    defer decref(tuple);

    // tupleSetItem steals refs
    try tupleSetItem(tuple, 0, try longFromLong(10));
    try tupleSetItem(tuple, 1, try longFromLong(20));

    const size = c.PyTuple_Size(tuple);
    try std.testing.expectEqual(@as(isize, 2), size);
}

test "bool and none" {
    init();
    defer deinit();

    const t = boolFromBool(true);
    defer decref(t);
    const f = boolFromBool(false);
    defer decref(f);

    const none_obj = getNone();
    defer decref(none_obj);
    try std.testing.expect(c.Py_IsNone(none_obj) != 0);
}

test "error set and check" {
    init();
    defer deinit();

    try std.testing.expect(!errOccurred());
    errSetString(c.PyExc_RuntimeError, "test error");
    try std.testing.expect(errOccurred());
    errClear();
    try std.testing.expect(!errOccurred());
}

test "wrapNoArgs produces valid method" {
    init();
    defer deinit();

    const answer = struct {
        fn call() PythonError!*PyObject {
            return longFromLong(42);
        }
    }.call;

    var methods = [_]c.PyMethodDef{
        wrapNoArgs("answer", answer),
        std.mem.zeroes(c.PyMethodDef),
    };

    var def = moduleDef("test_wrap", &methods, -1, null, null, null, null);
    const mod = try createModule(&def);
    defer decref(mod);

    const func = try getAttr(mod, "answer");
    defer decref(func);

    const result = try callObject(func, null);
    defer decref(result);

    const val = try longAsLong(result);
    try std.testing.expectEqual(@as(c_long, 42), val);
}
