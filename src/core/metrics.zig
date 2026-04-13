const std = @import("std");
const necro = @import("necro");
const driver = necro.py.driver;
const build_options = @import("build_options");

const log = std.log.scoped(.@"necro/aio/metrics");

pub const enabled = build_options.metrics;

pub fn instant() std.time.Instant {
    return std.time.Instant.now() catch |e| switch (e) {
        error.Unsupported => unreachable,
    };
}

pub fn elapsedNs(start_at: std.time.Instant) u64 {
    return instant().since(start_at);
}

pub const Stats = struct {
    cycles: u64 = 0,
    completions: u64 = 0,
    http_requests: u64 = 0,
    ns_io: u64 = 0,
    ns_classify: u64 = 0,
    ns_parse: u64 = 0,
    ns_handle_prep: u64 = 0,
    ns_handle_py: u64 = 0,
    ns_py_call: u64 = 0,
    ns_py_lookup: u64 = 0,
    ns_py_arg_build: u64 = 0,
    ns_py_resume: u64 = 0,
    ns_py_yield_consume: u64 = 0,
    ns_py_request_obj: u64 = 0,
    ns_py_invoke_total: u64 = 0,
    ns_py_result: u64 = 0,
    ns_py_result_response: u64 = 0,
    ns_py_result_yield: u64 = 0,
    py_no_args: u64 = 0,
    py_params_only: u64 = 0,
    py_request: u64 = 0,
    py_invocations: u64 = 0,
    py_coroutines: u64 = 0,
    py_sync_responses: u64 = 0,
    py_async_immediate_returns: u64 = 0,
    py_redis_yields: u64 = 0,
    py_pg_yields: u64 = 0,
    ns_redis: u64 = 0,
    ns_pg_wire: u64 = 0,
    ns_pg_flush: u64 = 0,
    pg_rows: u64 = 0,
    ns_send: u64 = 0,
    pg_recv_ops: u64 = 0,
    pg_recv_bytes: u64 = 0,

    pub fn accumInvokeMetrics(self: *Stats, metrics: *const driver.InvokeMetrics) void {
        if (comptime !enabled) return;
        self.py_invocations += metrics.invocations;
        self.py_coroutines += metrics.coroutines;
        self.py_sync_responses += metrics.sync_responses;
        self.py_async_immediate_returns += metrics.async_immediate_returns;
        self.py_redis_yields += metrics.redis_yields;
        self.py_pg_yields += metrics.pg_yields;
        self.ns_py_lookup += metrics.ns_lookup;
        self.ns_py_arg_build += metrics.ns_arg_build;
        self.ns_py_call += metrics.ns_call;
        self.ns_py_resume += metrics.ns_resume;
        self.ns_py_yield_consume += metrics.ns_yield_consume;
    }

    pub fn resetWindow(self: *Stats) void {
        if (comptime !enabled) return;
        const cycles = self.cycles;
        self.* = .{};
        self.cycles = cycles;
    }

    pub fn dump(self: *Stats) void {
        if (comptime !enabled) return;
        const ns_handle = self.ns_handle_prep + self.ns_handle_py;
        const total = self.ns_io + self.ns_classify + self.ns_parse + ns_handle + self.ns_redis + self.ns_pg_wire + self.ns_pg_flush + self.ns_send;
        const cqes = self.completions;
        log.info(
            "PROFILE  cycles={d}  cqes={d}  http={d}  total={d}us  io={d}us  classify={d}us  parse={d}us  handle={d}us(prep={d} py={d})  redis={d}us  pg={d}us({d}rows)  pg_flush={d}us  send={d}us  pg_recv={d}/{d}B",
            .{
                self.cycles,
                cqes,
                self.http_requests,
                us(total),
                us(self.ns_io),
                us(self.ns_classify),
                us(self.ns_parse),
                us(ns_handle),
                us(self.ns_handle_prep),
                us(self.ns_handle_py),
                us(self.ns_redis),
                us(self.ns_pg_wire),
                self.pg_rows,
                us(self.ns_pg_flush),
                us(self.ns_send),
                self.pg_recv_ops,
                self.pg_recv_bytes,
            },
        );
        if (self.py_invocations > 0) {
            const invoke_known = self.ns_py_lookup + self.ns_py_arg_build + self.ns_py_call + self.ns_py_resume + self.ns_py_yield_consume;
            const invoke_other = self.ns_py_invoke_total -| invoke_known;
            log.info(
                "PYPROFILE  invocations={d}  coro={d}  noargs={d}  params={d}  request={d}  sync={d}  async_return={d}  yield_redis={d}  yield_pg={d}",
                .{
                    self.py_invocations,
                    self.py_coroutines,
                    self.py_no_args,
                    self.py_params_only,
                    self.py_request,
                    self.py_sync_responses,
                    self.py_async_immediate_returns,
                    self.py_redis_yields,
                    self.py_pg_yields,
                },
            );
            log.info(
                "PYPROFILE  reqobj={d}us  invoke={d}us(other={d}us)  result={d}us(resp={d}us yield={d}us)  lookup={d}us  args={d}us  call={d}us  resume={d}us  yield_consume={d}us",
                .{
                    us(self.ns_py_request_obj),
                    us(self.ns_py_invoke_total),
                    us(invoke_other),
                    us(self.ns_py_result),
                    us(self.ns_py_result_response),
                    us(self.ns_py_result_yield),
                    us(self.ns_py_lookup),
                    us(self.ns_py_arg_build),
                    us(self.ns_py_call),
                    us(self.ns_py_resume),
                    us(self.ns_py_yield_consume),
                },
            );
        }
        self.resetWindow();
    }
};

fn us(ns: u64) u64 {
    return ns / 1000;
}
