const std = @import("std");
const posix = std.posix;

pub fn advanceIovecs(iovecs: []posix.iovec_const, iov_count: *usize, advance: usize) void {
    var remaining = advance;
    var idx: usize = 0;
    while (idx < iov_count.* and remaining > 0) {
        const len = iovecs[idx].len;
        if (remaining < len) {
            iovecs[idx].base += remaining;
            iovecs[idx].len -= remaining;
            remaining = 0;
            break;
        }
        remaining -= len;
        idx += 1;
    }
    if (idx > 0) {
        const next_len = iov_count.* - idx;
        if (next_len > 0) {
            std.mem.copyForwards(posix.iovec_const, iovecs[0..next_len], iovecs[idx..iov_count.*]);
        }
        iov_count.* = next_len;
    }
    std.debug.assert(remaining == 0);
}
