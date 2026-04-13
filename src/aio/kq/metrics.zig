const std = @import("std");
const necro = @import("necro");
const shared = necro.core.metrics;

const log = std.log.scoped(.@"necro/aio/kq/metrics");

pub const Metrics = struct {
    /// kevent batch size histogram: <32, 32-63, 64-127, 128-255, 256-511, 512+
    event_batch_hist: [6]u64 = .{0} ** 6,

    pub fn recordBatchSize(self: *Metrics, n: usize) void {
        if (comptime !shared.enabled) return;
        const bucket: usize = if (n < 32) 0 else if (n < 64) 1 else if (n < 128) 2 else if (n < 256) 3 else if (n < 512) 4 else 5;
        self.event_batch_hist[bucket] += 1;
    }

    pub fn dump(self: *Metrics) void {
        if (comptime !shared.enabled) return;
        log.info(
            "BATCH_HIST  <32={d}  32-63={d}  64-127={d}  128-255={d}  256-511={d}  512+={d}",
            .{
                self.event_batch_hist[0],
                self.event_batch_hist[1],
                self.event_batch_hist[2],
                self.event_batch_hist[3],
                self.event_batch_hist[4],
                self.event_batch_hist[5],
            },
        );
        self.event_batch_hist = .{0} ** 6;
    }
};
