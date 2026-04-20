//! necro HTTP server

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Socket = @import("socket.zig").Socket;
const necro = @import("necro");
const runtime = necro.aio.runtime;
const subinterp = necro.py.subinterp;
const http = necro.http;

const log = std.log.scoped(.@"necro/server");
var interp_mutex: std.Thread.Mutex = .{};

pub var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// How long workers keep servicing in-flight work after shutdown is requested
/// before force-exiting.
pub const DRAIN_MS: i64 = 1000;

const MAX_PIPELINES: usize = 256;
var pipeline_registry: [MAX_PIPELINES]?*runtime.Pipeline = .{null} ** MAX_PIPELINES;
var pipeline_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

fn registerPipeline(pl: *runtime.Pipeline) void {
    const idx = pipeline_count.fetchAdd(1, .acq_rel);
    if (idx < pipeline_registry.len) {
        @atomicStore(?*runtime.Pipeline, &pipeline_registry[idx], pl, .release);
    }
}

fn resetRegistry() void {
    pipeline_count.store(0, .release);
    for (&pipeline_registry) |*slot| @atomicStore(?*runtime.Pipeline, slot, null, .release);
}

pub fn requestShutdown() void {
    const was_running = shutdown_flag.swap(true, .acq_rel) == false;
    if (was_running) std.debug.print(
        \\
        \\
        \\⛧   Dawn approaches! Your thralls scream in anguish
        \\    as they are dragged back down into their graves!
        \\
    , .{});
    const n = pipeline_count.load(.acquire);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (@atomicLoad(
            ?*runtime.Pipeline,
            &pipeline_registry[i],
            .acquire,
        )) |pl| {
            pl.wake();
        }
    }
}

pub const Server = struct {
    router: http.router.Router,
    host: []const u8,
    port: u16,
    num_threads: u16,
    backlog: u31,
    idle_ms: i64,
    exchange_timeout_ms: i64,
    tls_cert_path: ?[]const u8,
    tls_key_path: ?[]const u8,

    pub fn init(host: []const u8, port: u16) Server {
        return .{
            .router = .{},
            .host = host,
            .port = port,
            .num_threads = 1,
            .backlog = 2048,
            .idle_ms = 300_000,
            .exchange_timeout_ms = 30_000,
            .tls_cert_path = null,
            .tls_key_path = null,
        };
    }
};

pub fn run(allocator: std.mem.Allocator, server: *const Server, module_name: []const u8, search_path: []const u8, version: []const u8) !void {
    shutdown_flag.store(false, .release);
    resetRegistry();

    const cert_set = server.tls_cert_path != null;
    const key_set = server.tls_key_path != null;
    if (cert_set != key_set) {
        log.err("--cert and --key must be supplied together", .{});
        std.posix.exit(2);
    }
    if (cert_set and key_set) {
        std.fs.cwd().access(server.tls_cert_path.?, .{}) catch |err| {
            log.err("tls cert/key not readable: {s}: {}", .{
                server.tls_cert_path.?,
                err,
            });
            std.posix.exit(2);
        };
        std.fs.cwd().access(server.tls_key_path.?, .{}) catch |err| {
            log.err("tls cert/key not readable: {s}: {}", .{
                server.tls_key_path.?,
                err,
            });
            std.posix.exit(2);
        };

    const num_threads = server.num_threads;

    const first_socket = try Socket.initTcp(server.host, server.port);
    first_socket.bind() catch |err| switch (err) {
        error.AddressInUse => {
            log.err("port {d} is already in use", .{server.port});
            std.posix.exit(2);
        },
        else => return err,
    };
    if (num_threads > 1) try first_socket.enableReusePort();
    try first_socket.listen(server.backlog);

    const s_plural = if (num_threads == 1) "" else "s";
    const rises = if (num_threads == 1) "s" else "";
    std.debug.print(
        \\
        \\⛧   necro v{s} · pid {d} · {s}
        \\    {s}://{s}:{d}/
        \\
        \\    Screaming souls arise from your gutteral incantations!
        \\    {d} thrall{s} rise{s} from the grave to serve your dark command!
        \\
        \\
    , .{
        version,
        std.c.getpid(),
        @import("aio/mod.zig").backend_name,
        "http",
        server.host,
        server.port,
        num_threads,
        s_plural,
        rises,
    });

    if (cert_set and key_set) {
        std.debug.print("    tls: cert={s} key={s}\n\n", .{
            server.tls_cert_path.?,
            server.tls_key_path.?,
        });
    }

    var threads: std.ArrayListUnmanaged(std.Thread) = .{};
    defer threads.deinit(allocator);

    for (1..num_threads) |i| {
        const t = try std.Thread.spawn(
            .{},
            pipelineThreadMain,
            .{ allocator, server, @as(?Socket, null), @as(u16, @intCast(i)), module_name, search_path },
        );
        try threads.append(allocator, t);
    }

    try pipelineThreadMain(allocator, server, first_socket, 0, module_name, search_path);

    for (threads.items) |t| t.join();
    std.debug.print(
        \\
        \\
        \\⛧   necro shutdown completed · pid {d}
        \\
    , .{std.c.getpid()});
}

fn pipelineThreadMain(allocator: std.mem.Allocator, server: *const Server, existing_socket: ?Socket, thread_idx: u16, module_name: []const u8, search_path: []const u8) !void {

    // Pin thread to CPU core (Linux only) - prevents cache thrashing from migration
    if (comptime @import("builtin").os.tag == .linux) {
        var set: std.os.linux.cpu_set_t = .{0} ** @typeInfo(std.os.linux.cpu_set_t).array.len;
        const word_idx = thread_idx / @bitSizeOf(usize);
        set[word_idx] = @as(usize, 1) << @intCast(thread_idx % @bitSizeOf(usize));
        std.os.linux.sched_setaffinity(0, &set) catch |err| {
            log.info("core affinity failed for thread {d}: {}", .{ thread_idx, err });
        };
    }
    const listen_socket = if (existing_socket) |s| s else blk: {
        const s = try Socket.initTcp(server.host, server.port);
        try s.enableReusePort();
        try s.bind();
        try s.listen(server.backlog);
        break :blk s;
    };

    var worker_py = blk: {
        interp_mutex.lock();
        defer interp_mutex.unlock();
        break :blk try subinterp.WorkerPyContext.init(module_name, search_path);
    };
    defer worker_py.deinit();

    var conns = try necro.core.Pool(necro.http.exchange.Conn).init(allocator, 1024);
    defer conns.deinit();

    const pl = try allocator.create(runtime.Pipeline);
    defer allocator.destroy(pl);
    try pl.init(
        allocator,
        &conns,
        1024,
        &server.router,
        &worker_py,
        server.idle_ms,
        server.exchange_timeout_ms,
    );
    necro.pg.row.init(allocator);
    try pl.init(allocator, &conns, 1024, &server.router, &worker_py, server.idle_ms);

    const redis_host = std.posix.getenv("REDIS_HOST") orelse "127.0.0.1";
    const redis_fd = connectTcpNonBlocking(redis_host, 6379) catch |err| blk: {
        log.info("redis not available at {s}: {}, redis commands will fail", .{ redis_host, err });
        break :blk null;
    };
    if (redis_fd) |fd| {
        pl.initRedis(fd);
    }

    {
        const pg_host = posix.getenv("PG_HOST") orelse "127.0.0.1";
        const pg_port_str = posix.getenv("PG_PORT") orelse "5432";
        const pg_port = std.fmt.parseInt(u16, pg_port_str, 10) catch 5432;
        const pg_user = posix.getenv("PG_USER") orelse "postgres";
        const pg_pass = posix.getenv("PG_PASS") orelse "";
        const pg_db = posix.getenv("PG_DB") orelse "postgres";
        const pg_client = @import("pg/conn.zig").Client.connect(allocator, pg_host, pg_port, pg_user, pg_db, pg_pass) catch |err| blk: {
            log.info("postgres not available at {s}:{d}: {}, pg commands will fail", .{ pg_host, pg_port, err });
            break :blk null;
        };
        if (pg_client) |c| try pl.setPgConn(c.fd);
    }

    try pl.start(listen_socket.handle);
    registerPipeline(pl);

    try pl.run();
}

fn connectTcpNonBlocking(host: []const u8, port: u16) !std.posix.socket_t {
    const addr = std.net.Address.resolveIp(host, port) catch blk: {
        const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.NameResolutionFailed;
        break :blk list.addrs[0];
    };
    const fd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(fd);
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };
    return fd;
}
