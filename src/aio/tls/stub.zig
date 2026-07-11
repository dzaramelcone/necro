const std = @import("std");

pub const Status = enum { want_read, want_write, complete, ktls_failed, handshake_err };

pub const TlsContext = struct {
    _unused: void = {},

    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        _ = cert_path;
        _ = key_path;
        return error.TlsNotSupportedOnThisPlatform;
    }

    pub fn deinit(self: *TlsContext) void {
        _ = self;
    }
};

pub const TlsHandshake = struct {
    _unused: void = {},

    pub fn init(tctx: *TlsContext, fd: std.posix.fd_t) !TlsHandshake {
        _ = tctx;
        _ = fd;
        return error.TlsNotSupportedOnThisPlatform;
    }

    pub fn step(self: *TlsHandshake) Status {
        _ = self;
        return .handshake_err;
    }

    pub fn deinit(self: *TlsHandshake) void {
        _ = self;
    }
};
