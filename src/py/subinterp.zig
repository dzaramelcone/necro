//! Per-worker sub-interpreter support (PEP 734).
//!
//! Each worker thread creates its own sub-interpreter with its own GIL via
//! Py_NewInterpreterFromConfig(OWN_GIL). No cross-thread GIL contention.

const std = @import("std");
const ffi = @import("ffi.zig");
const module = @import("module.zig");

const log = std.log.scoped(.@"necro/py/subinterp");

/// Per-worker sub-interpreter: owns a GIL lock and a necro.core module instance.
pub const WorkerPyContext = struct {
    gil: ffi.GilLock,
    necro_module: *ffi.PyObject,

    /// Create a sub-interpreter for the calling thread.
    /// Acquires the main GIL (no-op if already held), creates the sub-interpreter,
    /// imports the user's app module. On error, cleans up via errdefer.
    pub fn init(module_name: []const u8, search_path: []const u8) !WorkerPyContext {
        log.debug("creating sub-interpreter for module={s} path={s}", .{ module_name, search_path });
        _ = ffi.gilStateEnsure();

        const tstate = try ffi.newInterpreter(.{});
        errdefer ffi.Py_EndInterpreter(tstate);

        // Sub-interpreters start with minimal sys.path - prepend the caller's
        // module directory and load site packages.
        const sys_path = try ffi.sysGetObject("path");
        const search = try ffi.unicodeFromSlice(search_path.ptr, search_path.len);
        defer ffi.decref(search);
        try ffi.listInsert(sys_path, 0, search);
        const site_mod = try ffi.importModule("site");
        ffi.decref(site_mod);

        // Import the user module. The top-level code runs as a side effect,
        // registering route handlers via decorators.
        const user_mod = try ffi.importModuleSlice(module_name);
        ffi.decref(user_mod);

        const necro_mod = try ffi.importModule("necro.core");

        // Save and release the sub-interpreter's thread state. Each request
        // will reattach via GilLock.lock(), which uses PyEval_RestoreThread on
        // this interpreter's OWN GIL, bypassing the global GIL state machine.
        const saved = ffi.PyEval_SaveThread();
        log.debug("sub-interpreter created, GIL released", .{});

        return .{
            .gil = .{ .tstate = saved },
            .necro_module = necro_mod,
        };
    }

    /// Destroy the sub-interpreter. Must be called from the owning thread.
    ///
    /// TODO: register an `m_free` destructor on the module's `PyModuleDef` so
    /// CPython releases handlers automatically during `Py_EndInterpreter`.
    /// That removes this file's import of module.zig entirely. Requires
    /// exposing `m_free` through ffi.zig's PyModuleDef helpers first.
    pub fn deinit(self: *WorkerPyContext) void {
        log.debug("destroying sub-interpreter", .{});
        self.gil.lock();
        module.releaseHandlers(self.necro_module);
        ffi.decref(self.necro_module);
        if (self.gil.tstate) |ts| ffi.Py_EndInterpreter(ts);
    }
};
