const std = @import("std");

fn pyQuery(b: *std.Build, expr: []const u8) []const u8 {
    return std.mem.trim(u8, b.run(&.{ "python3.14", "-c", expr }), " \n\r\t");
}

fn addPython(b: *std.Build, m: *std.Build.Module, link_lib: bool) void {
    const target = m.resolved_target.?.result;
    const sysroot = switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => "macos-aarch64",
            else => @panic("necro only supports macos on aarch64"),
        },
        .linux => switch (target.cpu.arch) {
            .aarch64 => "linux-aarch64",
            .x86_64 => "linux-x86_64",
            else => @panic("necro only supports linux on aarch64 or x86_64"),
        },
        else => @panic("necro only supports macos and linux"),
    };
    m.addIncludePath(.{ .cwd_relative = b.fmt("sysroot/{s}/include/python3.14", .{sysroot}) });
    if (link_lib) {
        const libdir = switch (target.os.tag) {
            .macos => pyQuery(b, "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))"),
            .linux => b.fmt("sysroot/{s}/lib", .{sysroot}),
            else => unreachable,
        };
        m.addLibraryPath(.{ .cwd_relative = libdir });
        m.linkSystemLibrary("python3.14", .{});
    }
    m.link_libc = true;
}

fn addTls(b: *std.Build, m: *std.Build.Module) void {
    const target = m.resolved_target.?.result;
    if (target.os.tag != .linux) return;

    const sysroot = switch (target.cpu.arch) {
        .aarch64 => "linux-aarch64",
        .x86_64 => "linux-x86_64",
        else => unreachable,
    };
    m.addIncludePath(b.path("src/aio/tls"));
    m.addSystemIncludePath(.{ .cwd_relative = b.fmt("sysroot/{s}/include", .{sysroot}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("sysroot/{s}/lib", .{sysroot}) });
    m.linkSystemLibrary("ssl", .{ .use_pkg_config = .no });
    m.linkSystemLibrary("crypto", .{ .use_pkg_config = .no });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    const options = b.addOptions();

    const pyext = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
    pyext.root_module.addOptions("build_options", options);
    pyext.root_module.addImport("necro", pyext.root_module);
    pyext.lto = if (is_macos or optimize == .Debug) null else .full;
    pyext.link_gc_sections = true;
    if (is_macos) pyext.linker_allow_shlib_undefined = true;
    addPython(b, pyext.root_module, false);
    addTls(b, pyext.root_module);
    b.installArtifact(pyext);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options);
    unit_tests.root_module.addImport("necro", unit_tests.root_module);
    addPython(b, unit_tests.root_module, true);
    addTls(b, unit_tests.root_module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
