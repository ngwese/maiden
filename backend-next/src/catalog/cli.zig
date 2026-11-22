const std = @import("std");
const clap = @import("clap");
const common = @import("../common.zig");
const clapx = common.clapx;
const config = common.config;
const fsx = common.fsx;
const log = std.log.scoped(.cli);
const catalog = @import("catalog.zig");
const update = @import("update.zig");

pub const Command = enum {
    list,
    init,
    update,
};

const parsers = .{
    .subcommand = clap.parsers.enumeration(Command),
};

pub const params = clap.parseParamsComptime(
    \\-h, --help   help for catalog
    \\<subcommand>
    \\
);

pub const list_params = clap.parseParamsComptime(
    \\-h, --help   help for list
    \\
);

pub const init_params = clap.parseParamsComptime(
    \\-h, --help   help for init
    \\<str>
    \\
);

pub const update_params = clap.parseParamsComptime(
    \\-h, --help   help for update
    \\
);

const commands = [_]clapx.Entry{
    .{ .name = "init", .description = "init an empty catalog file" },
    .{ .name = "list", .description = "list projects" },
    .{ .name = "update", .description = "update configured catalogs" },
};

pub fn printHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "manage the script catalog",
        .usage = "maiden catalog [command]",
        .commands = &commands,
        .params = &params,
        .global_flags = true,
        .more = "Use \"maiden catalog [command] --help\" for more information about a command.",
    });
}

pub fn printListHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "list projects",
        .usage = "maiden catalog list [flags]",
        .params = &list_params,
        .global_flags = true,
    });
}

pub fn printInitHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "init an empty catalog file",
        .usage = "maiden catalog init [flags]",
        .args = &.{
            .{ .name = "path", .description = "path for the new empty catalog file" },
        },
        .params = &init_params,
        .global_flags = true,
    });
}

pub fn printUpdateHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "update configured catalogs",
        .usage = "maiden catalog update [flags]",
        .params = &update_params,
        .global_flags = true,
    });
}

pub fn printHelpTopic(io: std.Io, topic: ?[]const u8) !void {
    const sub = topic orelse {
        try printHelp(io);
        return;
    };
    const cmd = std.meta.stringToEnum(Command, sub) orelse {
        log.err("unknown help topic: catalog {s}", .{sub});
        try printHelp(io);
        std.process.exit(1);
    };
    switch (cmd) {
        .list => try printListHelp(io),
        .init => try printInitHelp(io),
        .update => try printUpdateHelp(io),
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(io);
        return;
    }

    const sub = res.positionals[0] orelse {
        try printHelp(io);
        return;
    };

    switch (sub) {
        .list => try runList(allocator, io, config_path, iter),
        .init => try runInit(allocator, io, iter),
        .update => try runUpdate(allocator, io, config_path, iter),
    }
}

fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &list_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printListHelp(io);
        return;
    }

    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();
    const catalogs = try catalog.loadCatalogs(allocator, &cfg);
    defer {
        for (catalogs) |*c| c.deinit();
        allocator.free(catalogs);
    }
    if (catalogs.len == 0) {
        log.warn("no catalog files loaded", .{});
        return;
    }
    for (catalogs) |c| {
        std.debug.print("[ {s} ]\n", .{c.path});
        std.debug.print("project\tsource\turl\ttags\t\n", .{});
        std.debug.print("-------\t------\t---\t----\t\n", .{});
        for (c.entries()) |e| {
            std.debug.print("{s}\t{s}\t{s}\t", .{ e.project_name, e.origin, e.project_url });
            if (e.tags) |tags| {
                for (tags, 0..) |t, ti| {
                    if (ti > 0) std.debug.print(",", .{});
                    std.debug.print("{s}", .{t});
                }
            }
            std.debug.print("\t\n", .{});
        }
    }
}

fn runInit(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &init_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printInitHelp(io);
        return;
    }

    const path = res.positionals[0] orelse return error.MissingArgs;
    const name = std.fs.path.stem(path);
    const json = try catalog.emptyCatalogJson(name, allocator);
    defer allocator.free(json);
    const file = try fsx.createFile(path);
    defer fsx.closeFile(file);
    try fsx.writeAll(file, json);
}

fn runUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &update_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printUpdateHelp(io);
        return;
    }

    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();
    try update.updateCatalogs(allocator, io, &cfg);
}
