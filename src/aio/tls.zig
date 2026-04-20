const builtin = @import("builtin");

const impl = if (builtin.os.tag == .linux) @import("tls/linux.zig") else @import("tls/stub.zig");

pub const Status = impl.Status;
pub const TlsContext = impl.TlsContext;
pub const TlsHandshake = impl.TlsHandshake;
