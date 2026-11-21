const std = @import("std");
const log = @import("log.zig");
const config = @import("config.zig");
const fsx = @import("fsx.zig");
const Io = std.Io;

pub const Entry = struct {
    project_name: []const u8 = "",
    project_url: []const u8 = "",
    author: []const u8 = "",
    home_page: []const u8 = "",
    description: []const u8 = "",
    discussion_url: []const u8 = "",
    documentation_url: []const u8 = "",
    tags: ?[]const []const u8 = null,
    version: []const u8 = "",
    origin: []const u8 = "",

    pub fn jsonStringify(self: Entry, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("project_name");
        try jw.write(self.project_name);
        try writeIfPresent(jw, "project_url", self.project_url);
        try jw.objectField("description");
        try jw.write(self.description);
        try writeIfPresent(jw, "author", self.author);
        try writeIfPresent(jw, "home_page", self.home_page);
        try writeIfPresent(jw, "discussion_url", self.discussion_url);
        try writeIfPresent(jw, "documentation_url", self.documentation_url);
        try writeIfPresent(jw, "origin", self.origin);
        try writeIfPresent(jw, "version", self.version);
        if (self.tags) |tags| if (tags.len > 0) {
            try jw.objectField("tags");
            try jw.write(tags);
        };
        try jw.endObject();
    }

    pub fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        var tags_copy: ?[]const []const u8 = null;
        if (self.tags) |tags| {
            const buf = try allocator.alloc([]u8, tags.len);
            errdefer allocator.free(buf);
            for (tags, 0..) |t, i| buf[i] = try allocator.dupe(u8, t);
            tags_copy = buf;
        }
        return .{
            .project_name = try allocator.dupe(u8, self.project_name),
            .project_url = try allocator.dupe(u8, self.project_url),
            .author = try allocator.dupe(u8, self.author),
            .home_page = try allocator.dupe(u8, self.home_page),
            .description = try allocator.dupe(u8, self.description),
            .discussion_url = try allocator.dupe(u8, self.discussion_url),
            .documentation_url = try allocator.dupe(u8, self.documentation_url),
            .tags = tags_copy,
            .version = try allocator.dupe(u8, self.version),
            .origin = try allocator.dupe(u8, self.origin),
        };
    }
};

fn writeIfPresent(jw: *std.json.Stringify, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try jw.objectField(key);
    try jw.write(value);
}

const CatalogFile = struct {
    catalog_name: []const u8 = "",
    date: []const u8 = "",
    entries: []const Entry = &.{},
};

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

pub const Catalog = struct {
    parsed: std.json.Parsed(CatalogFile),
    path: []u8,
    fallback_name: []u8,
    mtime_ns: i96,

    pub fn deinit(self: *Catalog) void {
        const allocator = self.parsed.arena.child_allocator;
        self.parsed.deinit();
        allocator.free(self.path);
        allocator.free(self.fallback_name);
    }

    pub fn name(self: *const Catalog) []const u8 {
        if (self.parsed.value.catalog_name.len > 0) return self.parsed.value.catalog_name;
        return self.fallback_name;
    }

    pub fn dateText(self: *const Catalog) []const u8 {
        if (self.parsed.value.date.len > 0) return self.parsed.value.date;
        return "0001-01-01T00:00:00Z";
    }

    pub fn entries(self: *const Catalog) []const Entry {
        return self.parsed.value.entries;
    }

    pub fn get(self: *const Catalog, project_name: []const u8) ?Entry {
        for (self.entries()) |e| {
            if (std.mem.eql(u8, e.project_name, project_name)) return e;
        }
        return null;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayListUnmanaged(Catalog) = .empty,

    pub fn deinit(self: *Cache) void {
        for (self.items.items) |*c| c.deinit();
        self.items.deinit(self.allocator);
    }

    pub fn lock(self: *Cache, io: Io) void {
        self.mutex.lockUncancelable(io);
    }

    pub fn unlock(self: *Cache, io: Io) void {
        self.mutex.unlock(io);
    }

    /// Caller holds `lock`. Reloads catalogs whose files are newer than the cached copy.
    pub fn refresh(self: *Cache, cfg: *const config.Config) !bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (!fsx.accessExists(self.items.items[i].path)) {
                var dead = self.items.swapRemove(i);
                dead.deinit();
                changed = true;
                continue;
            }
            i += 1;
        }

        for (cfg.catalogs.items) |pattern| {
            const paths = try globMatch(self.allocator, pattern);
            defer {
                for (paths) |p| self.allocator.free(p);
                self.allocator.free(paths);
            }
            for (paths) |p| {
                const st = fsx.statFile(p) catch |err| {
                    log.warn("failed to stat catalog {s}: {s}", .{ p, @errorName(err) });
                    continue;
                };
                if (findByPath(self, p)) |idx| {
                    if (st.mtime.nanoseconds > self.items.items[idx].mtime_ns) {
                        const fresh = loadCatalogFile(self.allocator, p, st.mtime.nanoseconds) catch |err| {
                            log.warn("failed to load catalog {s}: {s}", .{ p, @errorName(err) });
                            continue;
                        };
                        var old = self.items.items[idx];
                        self.items.items[idx] = fresh;
                        old.deinit();
                        changed = true;
                    }
                } else {
                    const fresh = loadCatalogFile(self.allocator, p, st.mtime.nanoseconds) catch |err| {
                        log.warn("failed to load catalog {s}: {s}", .{ p, @errorName(err) });
                        continue;
                    };
                    try self.items.append(self.allocator, fresh);
                    changed = true;
                }
            }
        }
        return changed;
    }

    pub fn findCatalog(self: *const Cache, catalog_name: []const u8) ?*const Catalog {
        for (self.items.items) |*c| {
            if (std.mem.eql(u8, c.name(), catalog_name)) return c;
        }
        return null;
    }

    pub fn findEntry(self: *const Cache, project_name: []const u8) ?Entry {
        for (self.items.items) |*c| {
            if (c.get(project_name)) |e| return e;
        }
        return null;
    }
};

fn findByPath(self: *Cache, path: []const u8) ?usize {
    for (self.items.items, 0..) |c, i| {
        if (std.mem.eql(u8, c.path, path)) return i;
    }
    return null;
}

pub fn loadCatalogFile(allocator: std.mem.Allocator, path: []const u8, mtime_ns: i96) !Catalog {
    const data = try fsx.readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(CatalogFile, allocator, data, parse_options);
    errdefer parsed.deinit();
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    return .{
        .parsed = parsed,
        .path = owned_path,
        .fallback_name = try allocator.dupe(u8, std.fs.path.stem(path)),
        .mtime_ns = mtime_ns,
    };
}

pub fn loadCatalogs(allocator: std.mem.Allocator, cfg: *const config.Config) ![]Catalog {
    var catalogs: std.ArrayListUnmanaged(Catalog) = .empty;
    errdefer {
        for (catalogs.items) |*c| c.deinit();
        catalogs.deinit(allocator);
    }
    for (cfg.catalogs.items) |pattern| {
        const paths = try globMatch(allocator, pattern);
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        for (paths) |p| {
            const st = fsx.statFile(p) catch |err| {
                log.warn("failed to stat catalog {s}: {s}", .{ p, @errorName(err) });
                continue;
            };
            const c = loadCatalogFile(allocator, p, st.mtime.nanoseconds) catch |err| {
                log.warn("failed to load catalog {s}: {s}", .{ p, @errorName(err) });
                continue;
            };
            try catalogs.append(allocator, c);
        }
    }
    std.mem.sort(Catalog, catalogs.items, {}, catalogLess);
    return try catalogs.toOwnedSlice(allocator);
}

fn catalogLess(_: void, a: Catalog, b: Catalog) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const SourceFile = struct {
    source: SourceBody = .{},
};

const SourceBody = struct {
    name: []const u8 = "",
    method: []const u8 = "",
    parameters: Parameters = .{},
};

const Parameters = struct {
    url: []const u8 = "",
};

pub const Source = struct {
    parsed: std.json.Parsed(SourceFile),

    pub fn deinit(self: *Source) void {
        self.parsed.deinit();
    }

    pub fn name(self: Source) []const u8 {
        return self.parsed.value.source.name;
    }

    pub fn method(self: Source) []const u8 {
        return self.parsed.value.source.method;
    }

    pub fn url(self: Source) []const u8 {
        return self.parsed.value.source.parameters.url;
    }
};

pub fn loadSources(allocator: std.mem.Allocator, cfg: *const config.Config) ![]Source {
    var sources: std.ArrayListUnmanaged(Source) = .empty;
    errdefer {
        for (sources.items) |*s| s.deinit();
        sources.deinit(allocator);
    }
    for (cfg.sources.items) |pattern| {
        const paths = try globMatch(allocator, pattern);
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        for (paths) |p| {
            const s = loadSourceFile(allocator, p) catch |err| {
                log.warn("failed to load source {s}: {s}", .{ p, @errorName(err) });
                continue;
            };
            try sources.append(allocator, s);
        }
    }
    return try sources.toOwnedSlice(allocator);
}

fn loadSourceFile(allocator: std.mem.Allocator, path: []const u8) !Source {
    const data = try fsx.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);
    return .{
        .parsed = try std.json.parseFromSlice(SourceFile, allocator, data, parse_options),
    };
}

pub fn searchCatalogs(catalogs: []const Catalog, name: []const u8) ?Entry {
    for (catalogs) |*c| {
        if (c.get(name)) |e| return e;
    }
    return null;
}

pub fn emptyCatalogJson(name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "file_info": {{
        \\    "version": 1,
        \\    "kind": "script_catalog"
        \\  }},
        \\  "catalog_name": "{s}",
        \\  "entries": []
        \\}}
        \\
    , .{name});
}

var download_seq: std.atomic.Value(u32) = .init(0);

/// Download `url` to a temporary sibling, fsync it, then rename over `output_path`.
/// A failed transfer leaves the previous file in place.
pub fn downloadToFile(allocator: std.mem.Allocator, io: Io, url: []const u8, output_path: []const u8, detail: *std.ArrayListUnmanaged(u8)) !void {
    log.debug("downloading: {s}", .{url});
    if (std.fs.path.dirname(output_path)) |dir| {
        try fsx.makePath(dir);
    }

    const curl = fsx.curlExecutable() catch return error.CurlNotFound;
    const seq = download_seq.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.partial-{d}", .{ output_path, seq });
    defer allocator.free(tmp);

    var committed = false;
    defer if (!committed) fsx.deleteFile(tmp) catch {};

    const argv = [_][]const u8{ curl, "-fsSL", "-o", tmp, url };
    const result = try std.process.run(allocator, io, .{
        .exe = .detect,
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        try appendBounded(allocator, detail, result.stderr, 1024);
        log.warn("download failed: {s}", .{detail.items});
        return error.DownloadFailed;
    }

    const file = try fsx.openFile(tmp);
    fsx.syncFile(file);
    fsx.closeFile(file);
    try fsx.rename(tmp, output_path);
    committed = true;
    fsx.syncParent(output_path);
}

fn appendBounded(allocator: std.mem.Allocator, dest: *std.ArrayListUnmanaged(u8), text: []const u8, max: usize) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const slice = if (trimmed.len > max) trimmed[trimmed.len - max ..] else trimmed;
    try dest.appendSlice(allocator, slice);
}

fn globMatch(allocator: std.mem.Allocator, pattern: []const u8) ![][]u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star| {
        const dir_path = std.fs.path.dirname(pattern) orelse ".";
        const file_pat = pattern[star..];
        const suffix = if (std.mem.startsWith(u8, file_pat, "*")) file_pat[1..] else file_pat;

        var dir = fsx.openDirIterate(dir_path) catch return try allocator.alloc([]u8, 0);
        defer fsx.closeDir(dir);

        var matches: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (matches.items) |m| allocator.free(m);
            matches.deinit(allocator);
        }
        var it = dir.iterate();
        while (try fsx.dirNext(&it)) |entry| {
            if (entry.kind != .file) continue;
            if (suffix.len == 0 or std.mem.endsWith(u8, entry.name, suffix)) {
                const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try matches.append(allocator, full);
            }
        }
        std.mem.sort([]u8, matches.items, {}, sliceLess);
        return try matches.toOwnedSlice(allocator);
    }
    const one = try allocator.alloc([]u8, 1);
    one[0] = try allocator.dupe(u8, pattern);
    return one;
}

fn sliceLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
