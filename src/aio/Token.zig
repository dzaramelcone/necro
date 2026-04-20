@"align": usize = 0,
tag: Tag = .conn_recv,

pub const Tag = enum(u8) {
    conn_recv,
    conn_send,
    accept,
    redis_send,
    redis_recv,
    pg_send,
    pg_recv,
};
