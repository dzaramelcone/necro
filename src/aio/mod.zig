const builtin = @import("builtin");

pub const Token = @import("Token.zig");
pub const IdleList = @import("IdleList.zig");
pub const runtime = @import("readiness/runtime.zig");
pub const backend_name = @import("readiness/sys.zig").name;
pub const tls = @import("tls.zig");

pub const BATCH_QUEUE_CAPACITY: usize = 1024;
