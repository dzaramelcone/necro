const std = @import("std");
const posix = std.posix;
const Event = @import("sys.zig").Event;

pub fn start(pipeline: anytype, listen_fd: posix.socket_t) !void {
    pipeline.listen_fd = listen_fd;
    pipeline.accept_token = .{ .tag = .accept };
    try pipeline.backend.arm(listen_fd, .read, @ptrCast(&pipeline.accept_token));
}

pub fn classifyEvent(pipeline: anytype, event: Event) !void {
    if (event.is_wake) return; // no-op; run loop re-checks shutdown flag
    const Token = @TypeOf(pipeline.accept_token);
    const token: *Token = @ptrCast(@alignCast(event.token));
    switch (token.tag) {
        .accept => try pipeline.onAcceptable(),
        .conn_recv => try pipeline.onConnReadable(token, event.eof),
        .conn_send => try pipeline.onConnWritable(token),
        .redis_send => try pipeline.onRedisWritable(),
        .redis_recv => try pipeline.onRedisReadable(),
        .pg_send => try pipeline.onPgWritable(pipeline.matchPgSendToken(token) orelse return),
        .pg_recv => try pipeline.onPgReadable(pipeline.matchPgRecvToken(token) orelse return),
        .wake => {},
    }
}

pub fn armConnRead(pipeline: anytype, conn: anytype) !void {
    try pipeline.backend.arm(conn.fd, .read, @ptrCast(&conn.recv_token));
}

pub fn armConnWrite(pipeline: anytype, conn: anytype) !void {
    try pipeline.backend.arm(conn.fd, .write, @ptrCast(&conn.send_token));
}

pub fn armRedisRead(pipeline: anytype) !void {
    const fd = pipeline.redis_fd orelse return;
    try pipeline.backend.arm(fd, .read, @ptrCast(&pipeline.redis_recv_token));
}

pub fn armRedisWrite(pipeline: anytype) !void {
    const fd = pipeline.redis_fd orelse return;
    try pipeline.backend.arm(fd, .write, @ptrCast(&pipeline.redis_send_token));
}

pub fn armPgRead(pipeline: anytype, pg: anytype) !void {
    try pipeline.backend.arm(pg.fd, .read, @ptrCast(&pg.recv_token));
}

pub fn armPgWrite(pipeline: anytype, pg: anytype) !void {
    try pipeline.backend.arm(pg.fd, .write, @ptrCast(&pg.send_token));
}
