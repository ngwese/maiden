const std = @import("std");
const clap = @import("clap");
const common = @import("common.zig");
const clapx = common.clapx;
const log = std.log.scoped(.cli);
const catalog = @import("catalog.zig");
const project = @import("project.zig");
const server = @import("server.zig");
const repl = @import("repl.zig");

const RootCommand = enum {
    help,
    version,
    server,
    catalog,
    project,
    repl,
};

const root_parsers = .{
    .command = clap.parsers.enumeration(RootCommand),
    .str = clap.parsers.string,
};

pub const root_params = clap.parseParamsComptime(
    \\-h, --help           help for maiden
    \\    --debug          enable debug logging
    \\    --config <str>   use specific config file
    \\<command>
    \\
);

const version_params = clap.parseParamsComptime(
    \\-h, --help   help for version
    \\
);

const help_params = clap.parseParamsComptime(
    \\-h, --help   help for help
    \\<str>
    \\<str>
    \\
);

const root_commands = [_]clapx.Entry{
    .{ .name = "catalog", .description = "manage the script catalog" },
    .{ .name = "help", .description = "Help about any command" },
    .{ .name = "project", .description = "manage dust projects" },
    .{ .name = "repl", .description = "norns repl" },
    .{ .name = "server", .description = "run the backend server for maiden" },
    .{ .name = "version", .description = "print maiden version" },
};

/// Dispatch remaining args from `iter` (argv0 already skipped).
pub fn run(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &root_params, root_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    common.log.setDebug(res.args.debug != 0);
    const config_path = res.args.config;

    if (res.args.help != 0) {
        try printRootHelp(io);
        return;
    }

    const cmd = res.positionals[0] orelse {
        try printRootHelp(io);
        return;
    };

    switch (cmd) {
        .help => try cmdHelp(allocator, io, iter),
        .version => try cmdVersion(allocator, io, iter),
        .server => try server.cli.run(allocator, io, config_path, iter),
        .catalog => try catalog.cli.run(allocator, io, config_path, iter),
        .project => try project.cli.run(allocator, io, config_path, iter),
        .repl => try repl.cli.run(allocator, io, config_path, iter),
    }
}

fn printRootHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "repl, script management, and server for norns",
        .usage = "maiden [command]",
        .commands = &root_commands,
        .params = &root_params,
        .more = "Use \"maiden [command] --help\" for more information about a command.",
    });
}

fn printVersionHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "print maiden version",
        .usage = "maiden version [flags]",
        .params = &version_params,
        .global_flags = true,
    });
}

fn printHelpHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "Help about any command",
        .usage = "maiden help [command] [flags]",
        .params = &help_params,
        .global_flags = true,
    });
}

fn cmdVersion(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &version_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printVersionHelp(io);
        return;
    }
    std.debug.print("{s}\n", .{common.versionString()});
}

fn cmdHelp(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &help_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelpHelp(io);
        return;
    }

    const topic = res.positionals[0] orelse {
        try printRootHelp(io);
        return;
    };
    const sub = res.positionals[1];

    if (std.mem.eql(u8, topic, "catalog")) {
        try catalog.cli.printHelpTopic(io, sub);
        return;
    }
    if (std.mem.eql(u8, topic, "project")) {
        try project.cli.printHelpTopic(io, sub);
        return;
    }
    if (std.mem.eql(u8, topic, "server")) {
        try server.cli.printHelp(io);
        return;
    }
    if (std.mem.eql(u8, topic, "version")) {
        try printVersionHelp(io);
        return;
    }
    if (std.mem.eql(u8, topic, "repl")) {
        try repl.cli.printHelp(io);
        return;
    }
    if (std.mem.eql(u8, topic, "help")) {
        try printHelpHelp(io);
        return;
    }
    log.err("unknown help topic: {s}", .{topic});
    try printRootHelp(io);
    std.process.exit(1);
}
