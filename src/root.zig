//! Necro — Python extension module entry point.
//!
//! This file is the root of the `core.so` shared library inside the `necro`
//! Python package. Python's extension loader finds `PyInit_core` as a C symbol
//! in the .so at import time;
//! the comptime reference below keeps the linker from stripping it under
//! LTO + --gc-sections.

const std = @import("std");
const log = @import("log.zig");
const module = @import("python/module.zig");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
};

comptime {
    _ = &module.PyInit_core;
}
