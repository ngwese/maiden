const std = @import("std");

/// Build the `maiden` executable. `-Dversion` and `-Dcompile-time` set the strings reported by `version`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "maiden version string") orelse "development";
    const compile_time = b.option([]const u8, "compile-time", "compile timestamp") orelse "";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "compile_time", compile_time);

    const exe = b.addExecutable(.{
        .name = "maiden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
        // Match norns packaging: dynamically link glibc (and system libc on other hosts).
        .linkage = .dynamic,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run maiden");
    run_step.dependOn(&run_cmd.step);
}
