const std = @import("std");
const yaml = @import("yaml");
const log = std.log.scoped(.config);
const fsx = @import("fsx.zig");

/// Minimal config covering the maiden.yaml keys the Go binary uses.
pub const Config = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayListUnmanaged([]const u8) = .empty,
    catalogs: std.ArrayListUnmanaged([]const u8) = .empty,
    catalog_output_dir: []u8 = &.{},
    dust_path: []u8 = &.{},
    dust_code: []u8 = &.{},
    web_path: []u8 = &.{},
    doc_path: []u8 = &.{},
    config_used: ?[]u8 = null,

    /// Free every path and list owned by this config.
    pub fn deinit(self: *Config) void {
        for (self.sources.items) |s| self.allocator.free(s);
        self.sources.deinit(self.allocator);
        for (self.catalogs.items) |s| self.allocator.free(s);
        self.catalogs.deinit(self.allocator);
        if (self.catalog_output_dir.len > 0) self.allocator.free(self.catalog_output_dir);
        if (self.dust_path.len > 0) self.allocator.free(self.dust_path);
        if (self.dust_code.len > 0) self.allocator.free(self.dust_code);
        if (self.web_path.len > 0) self.allocator.free(self.web_path);
        if (self.doc_path.len > 0) self.allocator.free(self.doc_path);
        if (self.config_used) |p| self.allocator.free(p);
    }
};

/// Replace `$VAR` and `${VAR}` using the process environment. Unknown names expand to empty.
/// Caller frees the result.
pub fn expandEnv(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and input[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, input, i + 2, '}') orelse {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const key = input[i + 2 .. end];
            if (fsx.getenv(key)) |val| try out.appendSlice(allocator, val);
            i = end + 1;
            continue;
        }
        if (input[i] == '$') {
            var j = i + 1;
            while (j < input.len and (std.ascii.isAlphanumeric(input[j]) or input[j] == '_')) : (j += 1) {}
            const key = input[i + 1 .. j];
            if (key.len > 0) {
                if (fsx.getenv(key)) |val| {
                    try out.appendSlice(allocator, val);
                }
                i = j;
                continue;
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn setOwned(allocator: std.mem.Allocator, dest: *[]u8, value: []const u8) !void {
    const next = try expandEnv(allocator, value);
    if (dest.len > 0) allocator.free(dest.*);
    dest.* = next;
}

/// Load maiden.yaml. `explicit_path` wins; otherwise the search is the working directory,
/// `$HOME/maiden`, `$HOME/.config/maiden`, then `/etc`. Missing files yield the built-in defaults.
/// Caller calls `deinit`.
pub fn load(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !Config {
    var cfg: Config = .{
        .allocator = allocator,
        .dust_path = try allocator.dupe(u8, "data/"),
        .web_path = try allocator.dupe(u8, "app/"),
        .doc_path = try allocator.dupe(u8, "doc/"),
    };
    errdefer cfg.deinit();

    const path = blk: {
        if (explicit_path) |p| break :blk try allocator.dupe(u8, p);
        const candidates = [_][]const u8{ "maiden.yaml", "maiden.yml" };
        for (candidates) |name| {
            if (fsx.accessExists(name)) break :blk try allocator.dupe(u8, name);
        }
        if (fsx.getenv("HOME")) |home| {
            const rels = [_][]const u8{
                "maiden/maiden.yaml",
                "maiden/maiden.yml",
                ".config/maiden/maiden.yaml",
                ".config/maiden/maiden.yml",
            };
            for (rels) |rel| {
                const hp = try std.fs.path.join(allocator, &.{ home, rel });
                defer allocator.free(hp);
                if (fsx.accessExists(hp)) break :blk try allocator.dupe(u8, hp);
            }
        }
        for ([_][]const u8{ "/etc/maiden.yaml", "/etc/maiden.yml" }) |ep| {
            if (fsx.accessExists(ep)) break :blk try allocator.dupe(u8, ep);
        }
        break :blk null;
    };

    if (path) |p| {
        cfg.config_used = p;
        log.debug("used confg: {s}", .{p});
        const content = fsx.readFileAlloc(allocator, p, 1024 * 1024) catch {
            log.warn("unable to open config: {s}", .{p});
            return cfg;
        };
        defer allocator.free(content);
        try parseYaml(allocator, &cfg, content);
    } else {
        log.debug("used confg: ", .{});
    }

    return cfg;
}

const YamlPath = struct {
    path: []const u8 = "",
    code: []const u8 = "",
};

const YamlFile = struct {
    sources: []const []const u8 = &.{},
    catalogs: []const []const u8 = &.{},
    catalogOutputDir: []const u8 = "",
    dust: YamlPath = .{},
    web: YamlPath = .{},
    doc: YamlPath = .{},
};

fn parseYaml(allocator: std.mem.Allocator, cfg: *Config, content: []const u8) !void {
    if (!yamlHasDocument(content)) return;

    var diagnostic: yaml.Diagnostic = .{};
    const parsed = yaml.parseFromSlice(YamlFile, allocator, content, .{
        .ignore_unknown_fields = true,
        .diagnostic = &diagnostic,
    }) catch |err| {
        log.warn("config parse failed: {s}: {s}", .{ @errorName(err), diagnostic.detail() });
        return err;
    };
    defer parsed.deinit();
    const doc = parsed.value;

    for (doc.sources) |item| try cfg.sources.append(allocator, try expandEnv(allocator, item));
    for (doc.catalogs) |item| try cfg.catalogs.append(allocator, try expandEnv(allocator, item));
    if (doc.catalogOutputDir.len > 0) try setOwned(allocator, &cfg.catalog_output_dir, doc.catalogOutputDir);
    if (doc.dust.path.len > 0) try setOwned(allocator, &cfg.dust_path, doc.dust.path);
    if (doc.dust.code.len > 0) try setOwned(allocator, &cfg.dust_code, doc.dust.code);
    if (doc.web.path.len > 0) try setOwned(allocator, &cfg.web_path, doc.web.path);
    if (doc.doc.path.len > 0) try setOwned(allocator, &cfg.doc_path, doc.doc.path);
}

fn yamlHasDocument(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0 and line[0] != '#') return true;
    }
    return false;
}

test "yaml config keeps comments out of values and reads flow lists" {
    var cfg: Config = .{
        .allocator = std.testing.allocator,
        .dust_path = try std.testing.allocator.dupe(u8, "data/"),
        .web_path = try std.testing.allocator.dupe(u8, "app/"),
        .doc_path = try std.testing.allocator.dupe(u8, "doc/"),
    };
    defer cfg.deinit();
    try parseYaml(std.testing.allocator, &cfg,
        \\# comment
        \\sources: ["one.json", two.json] # trailing
        \\catalogOutputDir: "/tmp/out" # keep
        \\dust:
        \\  path: "a:b"
        \\  code: dust-code
        \\web:
        \\  path: web-path
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.sources.items.len);
    try std.testing.expectEqualStrings("one.json", cfg.sources.items[0]);
    try std.testing.expectEqualStrings("two.json", cfg.sources.items[1]);
    try std.testing.expectEqualStrings("/tmp/out", cfg.catalog_output_dir);
    try std.testing.expectEqualStrings("a:b", cfg.dust_path);
    try std.testing.expectEqualStrings("dust-code", cfg.dust_code);
    try std.testing.expectEqualStrings("web-path", cfg.web_path);
}

/// Override dust, web, and doc paths from server flags that were actually set.
/// A null argument leaves the value loaded from yaml or the built-in default.
/// Also fills `dust_code` when it is still empty.
pub fn applyServerFlags(cfg: *Config, allocator: std.mem.Allocator, data: ?[]const u8, app: ?[]const u8, doc: ?[]const u8) !void {
    if (data) |d| try setOwned(allocator, &cfg.dust_path, d);
    if (app) |a| try setOwned(allocator, &cfg.web_path, a);
    if (doc) |d| try setOwned(allocator, &cfg.doc_path, d);
    try ensureDustCode(cfg, allocator);
}

/// Set `dust_code` to `dust_path/code` when it is empty.
pub fn ensureDustCode(cfg: *Config, allocator: std.mem.Allocator) !void {
    if (cfg.dust_code.len != 0) return;
    const joined = try std.fs.path.join(allocator, &.{ cfg.dust_path, "code" });
    cfg.dust_code = joined;
}
