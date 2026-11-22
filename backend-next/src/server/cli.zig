const std = @import("std");
const clap = @import("clap");
const common = @import("../common.zig");
const clapx = common.clapx;
const config = common.config;
const server = @import("server.zig");

pub const params = clap.parseParamsComptime(
    \\-h, --help          help for server
    \\    --port <u16>    HTTP port (default 5000)
    \\    --fd <i32>      file descriptor on which to serve HTTP (overrides --port)
    \\    --data <str>    path to user data directory (dust) (default "data/")
    \\    --app <str>     path to maiden web app directory (default "app/")
    \\    --doc <str>     path to norns lua docs (default "doc/")
    \\
);

pub fn printHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "run the backend server for maiden",
        .usage = "maiden server [flags]",
        .params = &params,
        .global_flags = true,
    });
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(io);
        return;
    }

    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();
    try config.applyServerFlags(&cfg, allocator, res.args.data, res.args.app, res.args.doc);

    try server.run(.{
        .allocator = allocator,
        .io = io,
        .cfg = &cfg,
        .port = res.args.port orelse 5000,
        .fd = res.args.fd orelse 0,
        .version = common.versionString(),
    });
}
