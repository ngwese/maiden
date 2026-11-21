const std = @import("std");
const log = @import("log.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const catalog = @import("catalog.zig");
const dust = @import("dust.zig");
const git = @import("git.zig");
const Io = std.Io;
const fsx = @import("fsx.zig");

/// Dispatch `args`, which include argv0. Unknown commands print usage and exit 1.
pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    fsx.setIo(io);
    var debug = false;
    var config_path: ?[]const u8 = null;
    var i: usize = 1; // skip argv0

    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--debug")) {
            debug = true;
            i += 1;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            config_path = args[i];
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a["--config=".len..];
            i += 1;
        } else {
            break;
        }
    }

    log.debug_enabled = debug;

    if (i >= args.len) {
        try printUsage();
        return;
    }

    const cmd = args[i];
    i += 1;
    const rest = args[i..];

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("{s}\n", .{server.versionString()});
        return;
    }
    if (std.mem.eql(u8, cmd, "server")) {
        try cmdServer(allocator, io, config_path, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "catalog")) {
        try cmdCatalog(allocator, io, config_path, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "project")) {
        try cmdProject(allocator, io, config_path, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "repl")) {
        try cmdRepl(allocator, io, rest);
        return;
    }

    log.err("unknown command: {s}", .{cmd});
    try printUsage();
    std.process.exit(1);
}

fn printUsage() !void {
    std.debug.print(
        \\maiden - web editor for norns scripts
        \\
        \\Usage:
        \\  maiden [flags] <command>
        \\
        \\Flags:
        \\  --debug           enable debug logging
        \\  --config <path>   use specific config file
        \\
        \\Commands:
        \\  server    run the backend server
        \\  version   print maiden version
        \\  catalog   manage the script catalog
        \\  project   manage dust projects
        \\  repl      norns repl
        \\
    , .{});
}

fn cmdServer(allocator: std.mem.Allocator, io: Io, config_path: ?[]const u8, args: []const []const u8) !void {
    var port: u16 = 5000;
    var fd: i32 = 0;
    var data: ?[]const u8 = null;
    var app: ?[]const u8 = null;
    var doc: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--port=")) {
            port = try std.fmt.parseInt(u16, a["--port=".len..], 10);
        } else if (std.mem.eql(u8, a, "--fd")) {
            i += 1;
            fd = try std.fmt.parseInt(i32, args[i], 10);
        } else if (std.mem.startsWith(u8, a, "--fd=")) {
            fd = try std.fmt.parseInt(i32, a["--fd=".len..], 10);
        } else if (std.mem.eql(u8, a, "--data")) {
            i += 1;
            data = args[i];
        } else if (std.mem.startsWith(u8, a, "--data=")) {
            data = a["--data=".len..];
        } else if (std.mem.eql(u8, a, "--app")) {
            i += 1;
            app = args[i];
        } else if (std.mem.startsWith(u8, a, "--app=")) {
            app = a["--app=".len..];
        } else if (std.mem.eql(u8, a, "--doc")) {
            i += 1;
            doc = args[i];
        } else if (std.mem.startsWith(u8, a, "--doc=")) {
            doc = a["--doc=".len..];
        }
    }

    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();
    // Flag defaults like Go: if not set via flag, viper defaults are data/, app/, doc/
    // But flags always have defaults in Go cobra - so they always override.
    // Go defaults: data="data/", app="app/", doc="doc/"
    try config.applyServerFlags(&cfg, allocator, data, app, doc);

    try server.run(.{
        .allocator = allocator,
        .io = io,
        .cfg = &cfg,
        .port = port,
        .fd = fd,
        .version = server.versionString(),
    });
}

fn cmdCatalog(allocator: std.mem.Allocator, io: Io, config_path: ?[]const u8, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    const sub = args[0];
    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();

    if (std.mem.eql(u8, sub, "list")) {
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
        return;
    }

    if (std.mem.eql(u8, sub, "init")) {
        if (args.len < 2) return error.MissingArgs;
        const path = args[1];
        const name = std.fs.path.stem(path);
        const json = try catalog.emptyCatalogJson(name, allocator);
        defer allocator.free(json);
        const file = try fsx.createFile(path);
        defer fsx.closeFile(file);
        try fsx.writeAll(file, json);
        return;
    }

    if (std.mem.eql(u8, sub, "update")) {
        try server.updateCatalogs(allocator, io, &cfg);
        return;
    }

    return error.UnknownSubcommand;
}

fn cmdProject(allocator: std.mem.Allocator, io: Io, config_path: ?[]const u8, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingSubcommand;
    const sub = args[0];
    var cfg = try config.load(allocator, config_path);
    defer cfg.deinit();
    try config.ensureDustCode(&cfg, allocator);
    if (!fsx.accessExists(cfg.dust_code)) {
        log.err("dust directory '{s}' does not exist", .{cfg.dust_code});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub, "list")) {
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
        const selected = args[1..];
        if (selected.len == 0) {
            for (projects) |p| try printProject(allocator, io, p);
        } else {
            for (selected) |name| {
                if (dust.searchProjects(projects, name)) |p| {
                    try printProject(allocator, io, p);
                } else {
                    log.warn("Unknown project: {s}", .{name});
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, sub, "install")) {
        if (args.len < 2) return error.MissingArgs;
        const catalogs = try catalog.loadCatalogs(allocator, &cfg);
        defer {
            for (catalogs) |*c| c.deinit();
            allocator.free(catalogs);
        }
        for (args[1..]) |arg| {
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
        return;
    }

    if (std.mem.eql(u8, sub, "update")) {
        var all = false;
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(allocator);
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else {
                try names.append(allocator, arg);
            }
        }
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
        if (all) {
            for (projects) |p| try updateOne(allocator, io, cfg.dust_code, catalogs, p);
        } else {
            for (names.items) |name| {
                if (dust.searchProjects(projects, name)) |p| {
                    try updateOne(allocator, io, cfg.dust_code, catalogs, p);
                } else {
                    std.debug.print("Unknown project: {s}\n", .{name});
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, sub, "push")) {
        if (args.len < 2) return error.MissingArgs;
        for (args[1..]) |name| {
            const root = try std.fs.path.join(allocator, &.{ cfg.dust_code, name });
            defer allocator.free(root);
            try git.push(allocator, io, root);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        if (args.len < 2) return error.MissingArgs;
        const projects = try dust.getProjects(allocator, cfg.dust_code);
        defer {
            for (projects) |p| {
                allocator.free(p.name);
                allocator.free(p.root);
            }
            allocator.free(projects);
        }
        for (args[1..]) |name| {
            if (dust.searchProjects(projects, name)) |p| {
                std.debug.print("Removing: {s} ({s})... ", .{ p.name, p.root });
                try fsx.deleteTree(p.root);
                std.debug.print("done.\n", .{});
            } else {
                std.debug.print("Unknown project: '{s}'\n", .{name});
            }
        }
        return;
    }

    return error.UnknownSubcommand;
}

fn printProject(allocator: std.mem.Allocator, io: Io, p: dust.Project) !void {
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
    io: Io,
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

fn cmdRepl(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    const binary = fsx.findInPath(allocator, "maiden-repl") catch {
        log.err("maiden-repl not found on PATH", .{});
        std.process.exit(1);
    };
    defer allocator.free(binary);
    const argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = binary;
    @memcpy(argv[1..], args);
    const err = std.process.replace(io, .{
        .exe = .detect,
        .argv = argv,
        .environ_map = fsx.environ,
    });
    log.err("failed to exec maiden-repl: {s}", .{@errorName(err)});
    std.process.exit(1);
}
