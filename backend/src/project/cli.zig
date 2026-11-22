const std = @import("std");
const clap = @import("clap");
const common = @import("../common.zig");
const clapx = common.clapx;
const config = common.config;
const fsx = common.fsx;
const git = common.git;
const log = std.log.scoped(.cli);
const catalog = @import("../catalog.zig");
const dust = @import("dust.zig");

pub const Command = enum {
    list,
    install,
    update,
    push,
    remove,
};

const parsers = .{
    .subcommand = clap.parsers.enumeration(Command),
};

pub const params = clap.parseParamsComptime(
    \\-h, --help   help for project
    \\<subcommand>
    \\
);

pub const list_params = clap.parseParamsComptime(
    \\-h, --help   help for list
    \\<str>...
    \\
);

pub const install_params = clap.parseParamsComptime(
    \\-h, --help   help for install
    \\<str>...
    \\
);

pub const update_params = clap.parseParamsComptime(
    \\-h, --help   help for update
    \\    --all    update all installed projects
    \\<str>...
    \\
);

pub const push_params = clap.parseParamsComptime(
    \\-h, --help   help for push
    \\<str>...
    \\
);

pub const remove_params = clap.parseParamsComptime(
    \\-h, --help   help for remove
    \\<str>...
    \\
);

const commands = [_]clapx.Entry{
    .{ .name = "install", .description = "install a script/project" },
    .{ .name = "list", .description = "list installed script/project(s)" },
    .{ .name = "push", .description = "push a git based project" },
    .{ .name = "remove", .description = "remove a project dir" },
    .{ .name = "update", .description = "update a script/project" },
};

pub fn printHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "manage dust projects",
        .usage = "maiden project [command]",
        .commands = &commands,
        .params = &params,
        .global_flags = true,
        .more = "Use \"maiden project [command] --help\" for more information about a command.",
    });
}

pub fn printListHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "list installed script/project(s)",
        .usage = "maiden project list [names] [flags]",
        .args = &.{
            .{ .name = "names", .description = "optional project names to list (default: all)" },
        },
        .params = &list_params,
        .global_flags = true,
    });
}

pub fn printInstallHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "install a script/project",
        .usage = "maiden project install <names or urls> [flags]",
        .args = &.{
            .{ .name = "names", .description = "project names or URLs to install" },
        },
        .params = &install_params,
        .global_flags = true,
    });
}

pub fn printUpdateHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "update a script/project",
        .usage = "maiden project update [names] [flags]",
        .args = &.{
            .{ .name = "names", .description = "project names to update" },
        },
        .params = &update_params,
        .global_flags = true,
    });
}

pub fn printPushHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "push a git based project",
        .usage = "maiden project push [flags]",
        .args = &.{
            .{ .name = "names", .description = "git-based project names to push" },
        },
        .params = &push_params,
        .global_flags = true,
    });
}

pub fn printRemoveHelp(io: std.Io) !void {
    try clapx.print(io, .{
        .summary = "remove a project dir",
        .usage = "maiden project remove <names> [flags]",
        .args = &.{
            .{ .name = "names", .description = "project names to remove" },
        },
        .params = &remove_params,
        .global_flags = true,
    });
}

pub fn printHelpTopic(io: std.Io, topic: ?[]const u8) !void {
    const sub = topic orelse {
        try printHelp(io);
        return;
    };
    const cmd = std.meta.stringToEnum(Command, sub) orelse {
        log.err("unknown help topic: project {s}", .{sub});
        try printHelp(io);
        std.process.exit(1);
    };
    switch (cmd) {
        .list => try printListHelp(io),
        .install => try printInstallHelp(io),
        .update => try printUpdateHelp(io),
        .push => try printPushHelp(io),
        .remove => try printRemoveHelp(io),
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
        .install => try runInstall(allocator, io, config_path, iter),
        .update => try runUpdate(allocator, io, config_path, iter),
        .push => try runPush(allocator, io, config_path, iter),
        .remove => try runRemove(allocator, io, config_path, iter),
    }
}

fn loadDustConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) !config.Config {
    var cfg = try config.load(allocator, config_path);
    errdefer cfg.deinit();
    try config.ensureDustCode(&cfg, allocator);
    if (!fsx.accessExists(cfg.dust_code)) {
        log.err("dust directory '{s}' does not exist", .{cfg.dust_code});
        std.process.exit(1);
    }
    return cfg;
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

    var cfg = try loadDustConfig(allocator, config_path);
    defer cfg.deinit();

    const projects = try dust.getProjects(allocator, cfg.dust_code);
    defer {
        for (projects) |p| {
            allocator.free(p.name);
            allocator.free(p.root);
        }
        allocator.free(projects);
    }
    std.debug.print("project\tgit\tversion\tdir\t\n", .{});
    std.debug.print("-------\t---\t-------\t---\t\n", .{});
    const selected = res.positionals[0];
    if (selected.len == 0) {
        for (projects) |p| try printProjectRow(allocator, io, p);
    } else {
        for (selected) |name| {
            if (dust.searchProjects(projects, name)) |p| {
                try printProjectRow(allocator, io, p);
            } else {
                log.warn("Unknown project: {s}", .{name});
            }
        }
    }
}

fn runInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &install_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printInstallHelp(io);
        return;
    }

    const names = res.positionals[0];
    if (names.len < 1) return error.MissingArgs;

    var cfg = try loadDustConfig(allocator, config_path);
    defer cfg.deinit();

    const catalogs = try catalog.loadCatalogs(allocator, &cfg);
    defer {
        for (catalogs) |*c| c.deinit();
        allocator.free(catalogs);
    }
    for (names) |arg| {
        var project_url: []const u8 = arg;
        var project_name: []const u8 = dust.inferProjectNameFromURL(arg);
        var entry: ?catalog.Entry = null;
        if (catalog.searchCatalogs(catalogs, arg)) |e| {
            project_url = e.project_url;
            project_name = e.project_name;
            entry = e;
        }
        std.debug.print("Installing: {s} ({s})... ", .{ project_name, project_url });
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        defer detail.deinit(allocator);
        dust.install(allocator, io, cfg.dust_code, project_name, project_url, entry, &detail) catch |err| {
            const why = if (detail.items.len > 0) detail.items else @errorName(err);
            std.debug.print("failed: {s}\n", .{why});
            continue;
        };
        std.debug.print("done.\n", .{});
    }
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

    var cfg = try loadDustConfig(allocator, config_path);
    defer cfg.deinit();

    const catalogs = try catalog.loadCatalogs(allocator, &cfg);
    defer {
        for (catalogs) |*c| c.deinit();
        allocator.free(catalogs);
    }
    const projects = try dust.getProjects(allocator, cfg.dust_code);
    defer {
        for (projects) |p| {
            allocator.free(p.name);
            allocator.free(p.root);
        }
        allocator.free(projects);
    }

    if (res.args.all != 0) {
        for (projects) |p| try updateOne(allocator, io, cfg.dust_code, catalogs, p);
    } else {
        for (res.positionals[0]) |name| {
            if (dust.searchProjects(projects, name)) |p| {
                try updateOne(allocator, io, cfg.dust_code, catalogs, p);
            } else {
                std.debug.print("Unknown project: {s}\n", .{name});
            }
        }
    }
}

fn runPush(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &push_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printPushHelp(io);
        return;
    }

    const names = res.positionals[0];
    if (names.len < 1) return error.MissingArgs;

    var cfg = try loadDustConfig(allocator, config_path);
    defer cfg.deinit();

    for (names) |name| {
        const root = try std.fs.path.join(allocator, &.{ cfg.dust_code, name });
        defer allocator.free(root);
        try git.push(allocator, io, root);
    }
}

fn runRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    iter: *std.process.Args.Iterator,
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &remove_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| clapx.fail(io, &diag, err);
    defer res.deinit();

    if (res.args.help != 0) {
        try printRemoveHelp(io);
        return;
    }

    const names = res.positionals[0];
    if (names.len < 1) return error.MissingArgs;

    var cfg = try loadDustConfig(allocator, config_path);
    defer cfg.deinit();

    const projects = try dust.getProjects(allocator, cfg.dust_code);
    defer {
        for (projects) |p| {
            allocator.free(p.name);
            allocator.free(p.root);
        }
        allocator.free(projects);
    }
    for (names) |name| {
        if (dust.searchProjects(projects, name)) |p| {
            std.debug.print("Removing: {s} ({s})... ", .{ p.name, p.root });
            try fsx.deleteTree(p.root);
            std.debug.print("done.\n", .{});
        } else {
            std.debug.print("Unknown project: '{s}'\n", .{name});
        }
    }
}

fn printProjectRow(allocator: std.mem.Allocator, io: std.Io, p: dust.Project) !void {
    const managed = p.isManaged();
    var version: []const u8 = "";
    var owned: ?[]u8 = null;
    if (managed) {
        owned = git.shortHead(allocator, io, p.root) catch null;
        if (owned) |v| version = v;
    }
    defer if (owned) |v| allocator.free(v);
    std.debug.print("{s}\t{}\t{s}\t{s}\t\n", .{ p.name, managed, version, p.root });
}

fn updateOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    code_dir: []const u8,
    catalogs: []const catalog.Catalog,
    p: dust.Project,
) !void {
    std.debug.print("Updating: {s} ... ", .{p.name});
    if (p.isManaged()) {
        const entry = catalog.searchCatalogs(catalogs, p.name);
        const pulled = try git.pull(allocator, io, p.root);
        switch (pulled) {
            .up_to_date => std.debug.print("already up-to-date\n", .{}),
            .updated => {
                dust.noteUpdated(allocator, io, p.root, entry) catch |err| {
                    log.warn("metadata update failed: {s}", .{@errorName(err)});
                };
                std.debug.print("done.\n", .{});
            },
            .failed => |msg| {
                defer allocator.free(msg);
                std.debug.print("failed: {s}\n", .{msg});
            },
        }
        return;
    }
    if (catalog.searchCatalogs(catalogs, p.name)) |entry| {
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        defer detail.deinit(allocator);
        dust.replaceProject(allocator, io, code_dir, p.name, entry.project_url, entry, &detail) catch |err| {
            const why = if (detail.items.len > 0) detail.items else @errorName(err);
            std.debug.print("failed: {s}\n", .{why});
            return;
        };
        std.debug.print("done.\n", .{});
    } else {
        std.debug.print("failed: cannot find in catalog\n", .{});
    }
}
