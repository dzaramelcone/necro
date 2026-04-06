//! Shared handler/runtime types used by the active server pipelines.

const Request = @import("http/request.zig").Request;
const Router = @import("http/router.zig").Router;
const Response = @import("http/response.zig").Response;
const PyContext = @import("py/subinterp.zig").WorkerPyContext;

pub const HandlerFn = *const fn (*const Request) Response;

pub const PyHandlerFlags = extern struct {
    needs_request: bool = true,
    needs_params: bool = false,
    no_args: bool = false,
    is_async: bool = false,
};

pub const RequestContext = struct {
    router: *const Router,
    handlers: *const [64]?HandlerFn,
    py_handler_ids: *const [64]?u32,
    py_handler_flags: ?*const [64]PyHandlerFlags = null,
    py_ctx: ?*PyContext = null,
};
