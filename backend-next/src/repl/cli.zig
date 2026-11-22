const std = @import("std");
const clap = @import("clap");
const common = @import("../common.zig");
const clapx = common.clapx;
const app = @import("app.zig");

pub const params = clap.parseParamsComptime(
    \\-h, --help       help for repl
    \\    --api <str>  maiden HTTP API base (default http://127.0.0.1/)
    \\<str>
    \\<str>
    \\
);

pub fn printHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "norns and supercollider repl",
        .usage = "maiden repl [norns_socket] [supercollider_socket] [flags]",
        .args = &.{
            .{ .name = "norns_socket", .description = "websocket URL for matron (optional override)" },
            .{ .name = "supercollider_socket", .description = "websocket URL for supercollider (optional override)" },
        },
        .params = &params,
        .global_flags = true,
        .more =
            \\websocket URLs are discovered via maiden/repl-endpoints.json from the api
            \\host unless overriden by positional arguments.
            \\
            \\Keys:
            \\  tab            switch norns / supercollider
            \\  ctrl-b         focus script list
            \\  ctrl-shift-b   show/hide script browser pane
            \\  ctrl-p         play focused script
            \\  ctrl-x         stop script
            \\  ctrl-e / e     edit focused script in $EDITOR
            \\  ctrl-u         update selected project (catalog / git)
            \\  ctrl-n         new script (script pane focused)
            \\  ctrl-backspace delete selected project directory
            \\  ctrl-l         redraw
            \\  ctrl-c/ctrl-q  quit
            \\
            \\Lines starting with ; are special commands:
            \\  ;install <url>   install a project via the maiden server
            \\  ;restart         restart the active unit (also ;start ;stop)
        ,
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

    try app.run(.{
        .allocator = allocator,
        .io = io,
        .config_path = config_path,
        .norns_url = res.positionals[0],
        .sc_url = res.positionals[1],
        .api_base = res.args.api orelse "http://127.0.0.1/",
    });
}
