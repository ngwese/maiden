const std = @import("std");
const log = @import("log.zig");
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
        try parseYamlSubset(allocator, &cfg, content);
    } else {
        log.debug("used confg: ", .{});
    }

    return cfg;
}

fn parseYamlSubset(allocator: std.mem.Allocator, cfg: *Config, content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var section: enum { none, sources, catalogs, dust, web, doc } = .none;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "sources:")) {
            section = .sources;
            continue;
        }
        if (std.mem.eql(u8, line, "catalogs:")) {
            section = .catalogs;
            continue;
        }
        if (std.mem.eql(u8, line, "dust:")) {
            section = .dust;
            continue;
        }
        if (std.mem.eql(u8, line, "web:")) {
            section = .web;
            continue;
        }
        if (std.mem.eql(u8, line, "doc:")) {
            section = .doc;
            continue;
        }
        if (std.mem.startsWith(u8, line, "catalogOutputDir:")) {
            section = .none;
            try setOwned(allocator, &cfg.catalog_output_dir, trimYamlValue(line["catalogOutputDir:".len..]));
            continue;
        }

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            const owned = try expandEnv(allocator, trimYamlValue(trimmed[2..]));
            switch (section) {
                .sources => try cfg.sources.append(allocator, owned),
                .catalogs => try cfg.catalogs.append(allocator, owned),
                else => allocator.free(owned),
            }
            continue;
        }

        if (section == .dust) {
            if (std.mem.startsWith(u8, trimmed, "path:")) {
                try setOwned(allocator, &cfg.dust_path, trimYamlValue(trimmed["path:".len..]));
            } else if (std.mem.startsWith(u8, trimmed, "code:")) {
                try setOwned(allocator, &cfg.dust_code, trimYamlValue(trimmed["code:".len..]));
            }
        } else if (section == .web and std.mem.startsWith(u8, trimmed, "path:")) {
            try setOwned(allocator, &cfg.web_path, trimYamlValue(trimmed["path:".len..]));
        } else if (section == .doc and std.mem.startsWith(u8, trimmed, "path:")) {
            try setOwned(allocator, &cfg.doc_path, trimYamlValue(trimmed["path:".len..]));
        }
    }
}

fn trimYamlValue(s: []const u8) []const u8 {
    var v = std.mem.trim(u8, s, " \t");
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        v = v[1 .. v.len - 1];
    }
    return v;
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
