const std = @import("std");
const posix = std.posix;

const necro = @import("necro");
const ffi = @import("ffi.zig");
const module = @import("module.zig");
pub const PyContext = @import("subinterp.zig").WorkerPyContext;

const log = std.log.scoped(.@"necro/py/driver");

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

pub fn startServer(
    mod: *ffi.PyObject,
    host: []const u8,
    port: u16,
    threads: usize,
    module_name: []const u8,
    search_path: []const u8,
    backlog: u16,
    version: []const u8,
    tls_cert_path: ?[]const u8,
    tls_key_path: ?[]const u8,
) !void {
    log.debug("startServer host={s} port={d} threads={d} module={s} path={s} backlog={d} version={s} cert={?s} key={?s}", .{
        host,
        port,
        threads,
        module_name,
        search_path,
        backlog,
        version,
        tls_cert_path,
        tls_key_path,
    });

    installShutdownSignals();

    var server = necro.server.Server.init(host, port);
    server.num_threads = @intCast(threads);
    server.backlog = @intCast(backlog);
    server.tls_cert_path = tls_cert_path;
    server.tls_key_path = tls_key_path;

    const state = module.getState(mod) orelse return error.ModuleNotSet;
    var i: u32 = 0;
    while (i < state.py_handler_count) : (i += 1) {
        const entry = state.route_entries[i];
        server.router.addRoute(
            entry.method[0..entry.method_len],
            entry.path[0..entry.path_len],
            i,
        );
    }
    server.router.compile();

    const saved_tstate = ffi.PyEval_SaveThread();
    try necro.server.run(
        std.heap.smp_allocator,
        &server,
        module_name,
        search_path,
        version,
    );
    ffi.PyEval_RestoreThread(saved_tstate);
}
