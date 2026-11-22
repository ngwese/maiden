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
        if (isHelpFlag(a)) {
            try printRootUsage();
            return;
        } else if (std.mem.eql(u8, a, "--debug")) {
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
        try printRootUsage();
        return;
    }

    const cmd = args[i];
    i += 1;
    const rest = args[i..];

    if (std.mem.eql(u8, cmd, "help")) {
        try cmdHelp(rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "version")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("version", "print maiden version", null);
            return;
        }
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
    try printRootUsage();
    std.process.exit(1);
}

fn isHelpFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (isHelpFlag(a)) return true;
    }
    return false;
}

fn printRootUsage() !void {
    std.debug.print(
        \\web editor for norns scripts
        \\
        \\Usage:
        \\  maiden [command]
        \\
        \\Available Commands:
        \\  catalog     manage the script catalog
        \\  help        Help about any command
        \\  project     manage dust projects
        \\  repl        norns repl
        \\  server      run the backend server for maiden
        \\  version     print maiden version
        \\
        \\Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\  -h, --help            help for maiden
        \\
        \\Use "maiden [command] --help" for more information about a command.
        \\
    , .{});
}

fn printCatalogUsage() !void {
    std.debug.print(
        \\manage the script catalog
        \\
        \\Usage:
        \\  maiden catalog [command]
        \\
        \\Available Commands:
        \\  init        init an empty catalog file
        \\  list        list projects
        \\  update      update configured catalogs
        \\
        \\Flags:
        \\  -h, --help   help for catalog
        \\
        \\Global Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\
        \\Use "maiden catalog [command] --help" for more information about a command.
        \\
    , .{});
}

fn printProjectUsage() !void {
    std.debug.print(
        \\manage dust projects
        \\
        \\Usage:
        \\  maiden project [command]
        \\
        \\Available Commands:
        \\  install     install a script/project
        \\  list        list installed script/project(s)
        \\  push        push a git based project
        \\  remove      remove a project dir
        \\  update      update a script/project
        \\
        \\Flags:
        \\  -h, --help   help for project
        \\
        \\Global Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\
        \\Use "maiden project [command] --help" for more information about a command.
        \\
    , .{});
}

fn printLeafUsage(name: []const u8, short: []const u8, use_extra: ?[]const u8) !void {
    const use = use_extra orelse name;
    std.debug.print(
        \\{s}
        \\
        \\Usage:
        \\  maiden {s} [flags]
        \\
        \\Flags:
        \\  -h, --help   help for {s}
        \\
        \\Global Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\
    , .{ short, use, name });
}

fn printServerUsage() !void {
    std.debug.print(
        \\run the backend server for maiden
        \\
        \\Usage:
        \\  maiden server [flags]
        \\
        \\Flags:
        \\      --port port       HTTP port (default 5000)
        \\      --fd descriptor   file descriptor on which to serve HTTP (overrides -port)
        \\      --data path       path to user data directory (dust) (default "data/")
        \\      --app path        path to maiden web app directory (default "app/")
        \\      --doc path        path to norns lua docs (default "doc/")
        \\  -h, --help            help for server
        \\
        \\Global Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\
    , .{});
}

fn printProjectUpdateUsage() !void {
    std.debug.print(
        \\update a script/project
        \\
        \\Usage:
        \\  maiden project update [names] [flags]
        \\
        \\Flags:
        \\      --all    update all installed projects
        \\  -h, --help   help for update
        \\
        \\Global Flags:
        \\      --config string   use specific config file
        \\      --debug           enable debug logging
        \\
    , .{});
}

fn cmdHelp(args: []const []const u8) !void {
    if (args.len == 0) {
        try printRootUsage();
        return;
    }
    const topic = args[0];
    if (std.mem.eql(u8, topic, "catalog")) {
        if (args.len > 1) {
            try helpCatalogSub(args[1]);
        } else {
            try printCatalogUsage();
        }
        return;
    }
    if (std.mem.eql(u8, topic, "project")) {
        if (args.len > 1) {
            try helpProjectSub(args[1]);
        } else {
            try printProjectUsage();
        }
        return;
    }
    if (std.mem.eql(u8, topic, "server")) {
        try printServerUsage();
        return;
    }
    if (std.mem.eql(u8, topic, "version")) {
        try printLeafUsage("version", "print maiden version", null);
        return;
    }
    if (std.mem.eql(u8, topic, "repl")) {
        try printLeafUsage("repl", "norns repl", null);
        return;
    }
    if (std.mem.eql(u8, topic, "help")) {
        std.debug.print(
            \\Help about any command
            \\
            \\Usage:
            \\  maiden help [command] [flags]
            \\
            \\Flags:
            \\  -h, --help   help for help
            \\
            \\Global Flags:
            \\      --config string   use specific config file
            \\      --debug           enable debug logging
            \\
        , .{});
        return;
    }
    log.err("unknown help topic: {s}", .{topic});
    try printRootUsage();
    std.process.exit(1);
}

fn helpCatalogSub(sub: []const u8) !void {
    if (std.mem.eql(u8, sub, "list")) {
        try printLeafUsage("list", "list projects", "catalog list");
    } else if (std.mem.eql(u8, sub, "init")) {
        try printLeafUsage("init", "init an empty catalog file", "catalog init");
    } else if (std.mem.eql(u8, sub, "update")) {
        try printLeafUsage("update", "update configured catalogs", "catalog update");
    } else {
        log.err("unknown help topic: catalog {s}", .{sub});
        try printCatalogUsage();
        std.process.exit(1);
    }
}

fn helpProjectSub(sub: []const u8) !void {
    if (std.mem.eql(u8, sub, "list")) {
        try printLeafUsage("list", "list installed script/project(s)", "project list [names]");
    } else if (std.mem.eql(u8, sub, "install")) {
        try printLeafUsage("install", "install a script/project", "project install <names or urls>");
    } else if (std.mem.eql(u8, sub, "update")) {
        try printProjectUpdateUsage();
    } else if (std.mem.eql(u8, sub, "push")) {
        try printLeafUsage("push", "push a git based project", "project push");
    } else if (std.mem.eql(u8, sub, "remove")) {
        try printLeafUsage("remove", "remove a project dir", "project remove <names>");
    } else {
        log.err("unknown help topic: project {s}", .{sub});
        try printProjectUsage();
        std.process.exit(1);
    }
}

fn cmdServer(allocator: std.mem.Allocator, io: Io, config_path: ?[]const u8, args: []const []const u8) !void {
    if (hasHelpFlag(args)) {
        try printServerUsage();
        return;
    }

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
    if (args.len == 0 or isHelpFlag(args[0])) {
        try printCatalogUsage();
        return;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("list", "list projects", "catalog list");
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
        return;
    }

    if (std.mem.eql(u8, sub, "init")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("init", "init an empty catalog file", "catalog init");
            return;
        }
        if (rest.len < 1) return error.MissingArgs;
        const path = rest[0];
        const name = std.fs.path.stem(path);
        const json = try catalog.emptyCatalogJson(name, allocator);
        defer allocator.free(json);
        const file = try fsx.createFile(path);
        defer fsx.closeFile(file);
        try fsx.writeAll(file, json);
        return;
    }

    if (std.mem.eql(u8, sub, "update")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("update", "update configured catalogs", "catalog update");
            return;
        }
        var cfg = try config.load(allocator, config_path);
        defer cfg.deinit();
        try server.updateCatalogs(allocator, io, &cfg);
        return;
    }

    try printCatalogUsage();
}

fn cmdProject(allocator: std.mem.Allocator, io: Io, config_path: ?[]const u8, args: []const []const u8) !void {
    if (args.len == 0 or isHelpFlag(args[0])) {
        try printProjectUsage();
        return;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("list", "list installed script/project(s)", "project list [names]");
            return;
        }
    } else if (std.mem.eql(u8, sub, "install")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("install", "install a script/project", "project install <names or urls>");
            return;
        }
    } else if (std.mem.eql(u8, sub, "update")) {
        if (hasHelpFlag(rest)) {
            try printProjectUpdateUsage();
            return;
        }
    } else if (std.mem.eql(u8, sub, "push")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("push", "push a git based project", "project push");
            return;
        }
    } else if (std.mem.eql(u8, sub, "remove")) {
        if (hasHelpFlag(rest)) {
            try printLeafUsage("remove", "remove a project dir", "project remove <names>");
            return;
        }
    } else {
        try printProjectUsage();
        return;
    }

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
        const selected = rest;
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
        if (rest.len < 1) return error.MissingArgs;
        const catalogs = try catalog.loadCatalogs(allocator, &cfg);
        defer {
            for (catalogs) |*c| c.deinit();
            allocator.free(catalogs);
        }
        for (rest) |arg| {
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
        for (rest) |arg| {
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
        if (rest.len < 1) return error.MissingArgs;
        for (rest) |name| {
            const root = try std.fs.path.join(allocator, &.{ cfg.dust_code, name });
            defer allocator.free(root);
            try git.push(allocator, io, root);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "remove")) {
        if (rest.len < 1) return error.MissingArgs;
        const projects = try dust.getProjects(allocator, cfg.dust_code);
        defer {
            for (projects) |p| {
                allocator.free(p.name);
                allocator.free(p.root);
            }
            allocator.free(projects);
        }
        for (rest) |name| {
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
    if (hasHelpFlag(args)) {
        try printLeafUsage("repl", "norns repl", null);
        return;
    }
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
