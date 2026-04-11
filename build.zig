const std = @import("std");

fn linkPython(m: *std.Build.Module) void {
    const target = m.resolved_target.?.result;
    switch (target.os.tag) {
        .macos => {
            m.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/include/python3.14" });
            m.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib" });
        },
        .linux => switch (target.cpu.arch) {
            .aarch64 => {
                m.addIncludePath(.{ .cwd_relative = "sysroot/linux-aarch64/include/python3.14" });
                m.addLibraryPath(.{ .cwd_relative = "sysroot/linux-aarch64/lib" });
            },
            .x86_64 => {
                m.addIncludePath(.{ .cwd_relative = "sysroot/linux-x86_64/include/python3.14" });
                m.addLibraryPath(.{ .cwd_relative = "sysroot/linux-x86_64/lib" });
            },
            else => @panic("necro only supports linux on aarch64 or x86_64"),
        },
        else => @panic("necro only supports macos and linux"),
    }
    m.linkSystemLibrary("python3.14", .{});
    m.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.option(bool, "metrics", "Enable pipeline metrics") orelse false;

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
    const options = b.addOptions();
    options.addOption(bool, "metrics", metrics);
    pyext.root_module.addOptions("build_options", options);
    pyext.root_module.addImport("necro", pyext.root_module);
    const os = target.result.os.tag;
    pyext.lto = if (os == .macos) null else .full;
    pyext.link_gc_sections = true;
    linkPython(pyext.root_module);
    b.installArtifact(pyext);
}
