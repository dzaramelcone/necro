const std = @import("std");
const posix = std.posix;
const kqueue = @import("sys.zig");
const Completion = kqueue.Completion;
const Op = kqueue.Op;

pub fn start(pipeline: anytype, listen_fd: posix.socket_t) !void {
    pipeline.listen_fd = listen_fd;
    pipeline.accept_token = .{ .tag = .accept };
    try queueAccept(pipeline);
}

pub fn classifyCompletion(pipeline: anytype, token_ptr: *anyopaque, completion: Completion) !void {
    const Token = @TypeOf(pipeline.accept_token);
    const token: *Token = @ptrCast(@alignCast(token_ptr));
    switch (token.tag) {
        .accept => {
            try queueAccept(pipeline);
            pipeline.onAccept(completion.result);
        },
        .redis_send => try pipeline.onRedisSendIO(completion.result),
        .redis_recv => try pipeline.onRedisRecvIO(completion.result),
        .pg_send => try pipeline.onPgSendIO(pipeline.matchPgSendToken(token) orelse return, completion.result),
        .pg_recv => try pipeline.onPgRecvIO(pipeline.matchPgRecvToken(token) orelse return, completion.result),
        .conn => try pipeline.onConnCompletion(token, completion),
    }
}

pub fn submitConnRecv(pipeline: anytype, conn: anytype) !void {
    const op = Op{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
    try pipeline.backend.queue(&conn.token, op);
}

pub fn submitConnSendv(pipeline: anytype, conn: anytype, iovecs: []const posix.iovec_const) !void {
    const op = Op{ .sendv = .{
        .socket = conn.fd,
        .iovecs = iovecs,
    } };
    try pipeline.backend.queue(&conn.token, op);
}

pub fn submitRedisSend(pipeline: anytype) !void {
    const fd = pipeline.redis_fd orelse return;
    const op = Op{ .send = .{
        .socket = fd,
        .buffer = pipeline.redis_send_buf[pipeline.redis_send_offset..pipeline.redis_send_len],
    } };
    try pipeline.backend.queue(&pipeline.redis_send_token, op);
}

pub fn submitRedisRecv(pipeline: anytype) !void {
    const fd = pipeline.redis_fd orelse return;
    const op = Op{ .recv = .{
        .socket = fd,
        .buffer = pipeline.redis_recv_buf[pipeline.redis_recv_len..],
    } };
    try pipeline.backend.queue(&pipeline.redis_recv_token, op);
}

pub fn submitPgSend(pipeline: anytype, pg: anytype) !void {
    const op = Op{ .send = .{
        .socket = pg.fd,
        .buffer = pg.send_buf[pg.send_offset..pg.send_len],
    } };
    try pipeline.backend.queue(&pg.send_token, op);
}

pub fn submitPgRecv(pipeline: anytype, pg: anytype) !void {
    const writable = try pg.transport.writable(&pipeline.pg_transport_pool);
    const op = Op{ .recv = .{
        .socket = pg.fd,
        .buffer = writable.slice,
    } };
    try pipeline.backend.queue(&pg.recv_token, op);
}

fn queueAccept(pipeline: anytype) !void {
    try pipeline.backend.queue(&pipeline.accept_token, Op{ .accept = .{ .socket = pipeline.listen_fd } });
}
