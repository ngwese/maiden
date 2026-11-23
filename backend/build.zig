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

    const zigtui = b.dependency("zigtui", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // Share one websocket module with httpz. httpz otherwise pulls a second
    // websocket package whose identical `build` options collide (zig#31613).
    const websocket_mod = websocket.module("websocket");
    const httpz_mod = httpz.module("httpz");
    httpz_mod.addImport("websocket", websocket_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "zigtui", .module = zigtui.module("zigtui") },
            .{ .name = "websocket", .module = websocket_mod },
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "yaml", .module = yaml.module("yaml") },
            .{ .name = "httpz", .module = httpz_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "maiden",
        .root_module = root_mod,
        // Match norns packaging: dynamically link glibc (and system libc on other hosts).
        .linkage = .dynamic,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run maiden");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
