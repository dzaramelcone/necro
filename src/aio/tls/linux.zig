const std = @import("std");
const log = std.log.scoped(.@"necro/tls");

const c = @cImport({
    @cInclude("ktls_shim.h");
});

pub const Status = enum { want_read, want_write, complete, ktls_failed, handshake_err };

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse {
            logErr("SSL_CTX_new");
            return error.SslCtxNew;
        };
        errdefer c.SSL_CTX_free(ctx);

        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION) == 0) {
            logErr("set_min_proto");
            return error.SslSetMinProto;
        }
        if (c.SSL_CTX_set_max_proto_version(ctx, c.TLS1_3_VERSION) == 0) {
            logErr("set_max_proto");
            return error.SslSetMaxProto;
        }
        if (c.SSL_CTX_set_ciphersuites(ctx, "TLS_AES_256_GCM_SHA384") == 0) {
            logErr("set_ciphersuites");
            return error.SslSetCiphersuites;
        }

        _ = c.SSL_CTX_set_options(ctx, c.necro_ssl_op_enable_ktls());

        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path.ptr) <= 0) {
            logErr("use_certificate_chain_file");
            return error.SslLoadCert;
        }
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) <= 0) {
            logErr("use_PrivateKey_file");
            return error.SslLoadKey;
        }
        if (c.SSL_CTX_check_private_key(ctx) == 0) {
            logErr("check_private_key");
            return error.SslKeyMismatch;
        }

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

pub const TlsHandshake = struct {
    ssl: *c.SSL,

    pub fn init(tctx: *TlsContext, fd: std.posix.fd_t) !TlsHandshake {
        const ssl = c.SSL_new(tctx.ctx) orelse {
            logErr("SSL_new");
            return error.SslNew;
        };
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, fd) == 0) {
            logErr("SSL_set_fd");
            return error.SslSetFd;
        }
        return .{ .ssl = ssl };
    }

    pub fn step(self: *TlsHandshake) Status {
        const rc = c.SSL_accept(self.ssl);
        if (rc == 1) {
            const wbio = c.SSL_get_wbio(self.ssl) orelse return .handshake_err;
            const rbio = c.SSL_get_rbio(self.ssl) orelse return .handshake_err;
            if (c.necro_bio_get_ktls_send(wbio) == 0) return .ktls_failed;
            if (c.necro_bio_get_ktls_recv(rbio) == 0) return .ktls_failed;
            if (c.SSL_pending(self.ssl) > 0) return .ktls_failed;
            return .complete;
        }
        return switch (c.SSL_get_error(self.ssl, rc)) {
            c.SSL_ERROR_WANT_READ => .want_read,
            c.SSL_ERROR_WANT_WRITE => .want_write,
            else => blk: {
                logErr("SSL_accept");
                break :blk .handshake_err;
            },
        };
    }

    pub fn deinit(self: *TlsHandshake) void {
        c.SSL_free(self.ssl);
    }
};

fn logErr(where: []const u8) void {
    var buf: [256]u8 = undefined;
    const e = c.ERR_get_error();
    if (e == 0) {
        log.err("{s}: (no error)", .{where});
        return;
    }
    c.ERR_error_string_n(e, &buf, buf.len);
    log.err("{s}: {s}", .{ where, std.mem.sliceTo(&buf, 0) });
}
