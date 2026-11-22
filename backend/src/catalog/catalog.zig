const std = @import("std");
const log = std.log.scoped(.catalog);
const config = @import("../common/config.zig");
const fsx = @import("../common/fsx.zig");
const httpx = @import("../common/httpx.zig");
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

    /// std.json hook. Writes the Go catalog entry shape: empty strings are
    /// omitted except `description`, which is always present. Empty `tags` are omitted.
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

    /// Deep copy. The caller owns every string and the `tags` allocation.
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

    /// Free the parsed JSON and the path strings owned by this catalog.
    pub fn deinit(self: *Catalog) void {
        const allocator = self.parsed.arena.child_allocator;
        self.parsed.deinit();
        allocator.free(self.path);
        allocator.free(self.fallback_name);
    }

    /// Catalog name from the file, or the filename stem when `catalog_name` is empty.
    /// The slice is borrowed from this catalog.
    pub fn name(self: *const Catalog) []const u8 {
        if (self.parsed.value.catalog_name.len > 0) return self.parsed.value.catalog_name;
        return self.fallback_name;
    }

    /// `date` from the file, or Go's zero `time.Time` string when the field is absent.
    pub fn dateText(self: *const Catalog) []const u8 {
        if (self.parsed.value.date.len > 0) return self.parsed.value.date;
        return "0001-01-01T00:00:00Z";
    }

    /// Project entries. Slices inside each entry are borrowed from this catalog.
    pub fn entries(self: *const Catalog) []const Entry {
        return self.parsed.value.entries;
    }

    /// First entry whose `project_name` matches, or null. The result borrows this catalog.
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

    /// Free every cached catalog. The caller must not hold `lock`.
    pub fn deinit(self: *Cache) void {
        for (self.items.items) |*c| c.deinit();
        self.items.deinit(self.allocator);
    }

    /// Block until this cache can be read or refreshed. Pair with `unlock`.
    pub fn lock(self: *Cache, io: Io) void {
        self.mutex.lockUncancelable(io);
    }

    /// Release the lock taken by `lock`.
    pub fn unlock(self: *Cache, io: Io) void {
        self.mutex.unlock(io);
    }

    /// Reload catalogs whose files are missing or newer than the cached copy.
    /// Caller holds `lock`. Returns true when the cached set changed.
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

    /// Catalog with this name, or null. Caller holds `lock`. The pointer is invalid after unlock.
    pub fn findCatalog(self: *const Cache, catalog_name: []const u8) ?*const Catalog {
        for (self.items.items) |*c| {
            if (std.mem.eql(u8, c.name(), catalog_name)) return c;
        }
        return null;
    }

    /// First matching project across cached catalogs. Caller holds `lock`.
    /// Entry slices are invalid after the catalog is reloaded or the cache is freed.
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

/// Parse one catalog JSON file. Caller owns the result and must `deinit` it.
/// `mtime_ns` is stored so a cache can skip unchanged files.
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

/// Load every catalog matched by `cfg.catalogs`, sorted by path.
/// A file that fails to parse is skipped. Caller `deinit`s each catalog, then frees the slice.
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

    /// Free the parsed source file.
    pub fn deinit(self: *Source) void {
        self.parsed.deinit();
    }

    /// Source name. Borrowed from the parsed file.
    pub fn name(self: Source) []const u8 {
        return self.parsed.value.source.name;
    }

    /// Retrieval method, such as `"download"`. Borrowed from the parsed file.
    pub fn method(self: Source) []const u8 {
        return self.parsed.value.source.method;
    }

    /// Download URL from `parameters.url`. Borrowed from the parsed file; empty when unset.
    pub fn url(self: Source) []const u8 {
        return self.parsed.value.source.parameters.url;
    }
};

/// Load every catalog source matched by `cfg.sources`.
/// A file that fails to parse is skipped. Caller `deinit`s each source, then frees the slice.
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

/// First entry named `name` in `catalogs`. The result borrows the matching catalog.
pub fn searchCatalogs(catalogs: []const Catalog, name: []const u8) ?Entry {
    for (catalogs) |*c| {
        if (c.get(name)) |e| return e;
    }
    return null;
}

/// JSON for a new empty script catalog named `name`. Caller frees the result.
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
/// A failed transfer leaves the previous file in place and appends a short
/// reason to `detail`.
pub fn downloadToFile(allocator: std.mem.Allocator, io: Io, url: []const u8, output_path: []const u8, detail: *std.ArrayListUnmanaged(u8)) !void {
    log.debug("downloading: {s}", .{url});
    if (std.fs.path.dirname(output_path)) |dir| {
        try fsx.makePath(dir);
    }

    const seq = download_seq.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.partial-{d}", .{ output_path, seq });
    defer allocator.free(tmp);

    var committed = false;
    defer if (!committed) fsx.deleteFile(tmp) catch {};

    httpx.downloadToPath(allocator, io, url, tmp, detail) catch |err| {
        log.warn("download failed: {s}", .{detail.items});
        return err;
    };
    try fsx.rename(tmp, output_path);
    committed = true;
    fsx.syncParent(output_path);
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
