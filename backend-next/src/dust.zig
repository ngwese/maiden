const std = @import("std");
const log = @import("log.zig");
const git = @import("git.zig");
const catalog = @import("catalog.zig");
const fsx = @import("fsx.zig");
const jsonx = @import("jsonx.zig");
const Io = std.Io;

pub const Project = struct {
    name: []const u8,
    root: []const u8,

    pub fn isManaged(self: Project) bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_dir = std.fmt.bufPrint(&path_buf, "{s}/.git", .{self.root}) catch return false;
        const st = fsx.statFile(git_dir) catch return false;
        return st.kind == .directory;
    }
};

pub const Meta = struct {
    installed_on: []const u8 = "",
    updated_on: []const u8 = "",
    project_url: []const u8 = "",
    catalog_entry: ?catalog.Entry = null,
};

pub const MetaFile = struct {
    installed_on: []const u8 = "",
    updated_on: []const u8 = "",
    project_url: []const u8 = "",
    catalog_entry: ?catalog.Entry = null,
};

pub fn devicePath(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) ![]u8 {
    const n = try fsx.relativeInside(name);
    if (n.len == 0) return try allocator.dupe(u8, data_dir);
    return try std.fs.path.join(allocator, &.{ data_dir, n });
}

pub fn resourcePath(allocator: std.mem.Allocator, prefix: []const u8, parts: []const []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, prefix);
    for (parts) |p| {
        if (p.len == 0) continue;
        try list.append(allocator, '/');
        for (p) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try list.append(allocator, c);
            } else {
                var buf: [3]u8 = undefined;
                _ = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{c});
                try list.appendSlice(allocator, &buf);
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub const FileInfo = struct {
    name: []const u8,
    url: []const u8,
    is_dir: bool,
};

pub fn listDir(allocator: std.mem.Allocator, abs_path: []const u8, url_prefix: []const u8) ![]FileInfo {
    var dir = try fsx.openDirIterate(abs_path);
    defer fsx.closeDir(dir);

    var entries: std.ArrayListUnmanaged(FileInfo) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.url);
        }
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try fsx.dirNext(&it)) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const url = try resourcePath(allocator, url_prefix, &.{entry.name});
        errdefer allocator.free(url);
        try entries.append(allocator, .{
            .name = name,
            .url = url,
            .is_dir = entry.kind == .directory,
        });
    }
    std.mem.sort(FileInfo, entries.items, {}, fileLess);
    return try entries.toOwnedSlice(allocator);
}

fn fileLess(_: void, a: FileInfo, b: FileInfo) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn getProjects(allocator: std.mem.Allocator, code_dir: []const u8) ![]Project {
    var dir = try fsx.openDirIterate(code_dir);
    defer fsx.closeDir(dir);

    var projects: std.ArrayListUnmanaged(Project) = .empty;
    errdefer {
        for (projects.items) |p| {
            allocator.free(p.name);
            allocator.free(p.root);
        }
        projects.deinit(allocator);
    }

    var it = dir.iterate();
    while (try fsx.dirNext(&it)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const root = try std.fs.path.join(allocator, &.{ code_dir, entry.name });
        errdefer allocator.free(root);
        try projects.append(allocator, .{ .name = name, .root = root });
    }
    std.mem.sort(Project, projects.items, {}, projectLess);
    return try projects.toOwnedSlice(allocator);
}

fn projectLess(_: void, a: Project, b: Project) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn searchProjects(projects: []const Project, name: []const u8) ?Project {
    for (projects) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub fn inferProjectNameFromURL(u: []const u8) []const u8 {
    var s = u;
    if (std.mem.indexOfScalar(u8, s, '#')) |i| s = s[0..i];
    if (std.mem.indexOfScalar(u8, s, '?')) |i| s = s[0..i];

    const hosts = [_][]const u8{ "github.com/", "gitlab.com/", "bitbucket.org/" };
    for (hosts) |host| {
        if (std.mem.indexOf(u8, s, host)) |idx| {
            const rest = s[idx + host.len ..];
            var parts = std.mem.splitScalar(u8, rest, '/');
            _ = parts.next();
            if (parts.next()) |repo| {
                if (std.mem.endsWith(u8, repo, ".git")) return repo[0 .. repo.len - 4];
                return repo;
            }
        }
    }

    var base = s;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| {
        if (i > 0) base = base[0..i];
    }
    return base;
}

pub fn readMeta(allocator: std.mem.Allocator, root: []const u8) ?std.json.Parsed(MetaFile) {
    const path = std.fs.path.join(allocator, &.{ root, ".project" }) catch return null;
    defer allocator.free(path);
    const data = fsx.readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(data);
    return std.json.parseFromSlice(MetaFile, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

fn rfc3339(io: Io, buf: *[32]u8) []const u8 {
    const secs_i = Io.Timestamp.now(io, .real).toSeconds();
    const secs: u64 = if (secs_i > 0) @intCast(secs_i) else 0;
    const days: i64 = @intCast(secs / 86400);
    const tod = secs % 86400;
    const civil = civilFromDays(days);
    const hour = tod / 3600;
    const min = (tod % 3600) / 60;
    const sec = tod % 60;
    const year: u32 = @intCast(civil.y);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, civil.m, civil.d, hour, min, sec,
    }) catch unreachable;
}

/// Howard Hinnant's civil_from_days. `days_in` is days since 1970-01-01.
fn civilFromDays(days_in: i64) struct { y: i64, m: u32, d: u32 } {
    const z = days_in + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .y = if (m <= 2) y + 1 else y,
        .m = @intCast(m),
        .d = @intCast(d),
    };
}

const MetaOut = struct {
    file_info: struct {
        version: u32 = 1,
        kind: []const u8 = "project_metadata",
    } = .{},
    installed_on: []const u8,
    updated_on: ?[]const u8 = null,
    project_url: []const u8,
    catalog_entry: ?catalog.Entry = null,
};

fn writeMetaData(allocator: std.mem.Allocator, io: Io, root: []const u8, source_url: []const u8, entry: ?catalog.Entry, installed_on: ?[]const u8, updated_on: ?[]const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, ".project" });
    defer allocator.free(path);

    var now_buf: [32]u8 = undefined;
    const installed = installed_on orelse rfc3339(io, &now_buf);
    const updated: ?[]const u8 = if (updated_on) |u|
        (if (u.len == 0) null else u)
    else
        null;

    const body = try jsonx.stringify(allocator, MetaOut{
        .installed_on = installed,
        .updated_on = updated,
        .project_url = source_url,
        .catalog_entry = entry,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(body);

    const file = try fsx.createFile(path);
    defer fsx.closeFile(file);
    try fsx.writeAll(file, body);
    fsx.syncFile(file);
    fsx.syncParent(path);
}

pub fn noteUpdated(allocator: std.mem.Allocator, io: Io, root: []const u8, entry: ?catalog.Entry) !void {
    const parsed = readMeta(allocator, root) orelse return;
    defer parsed.deinit();
    var now_buf: [32]u8 = undefined;
    const now = rfc3339(io, &now_buf);
    const md = parsed.value;
    const next_entry = entry orelse md.catalog_entry;
    try writeMetaData(allocator, io, root, md.project_url, next_entry, md.installed_on, now);
}

pub fn install(
    allocator: std.mem.Allocator,
    io: Io,
    code_dir: []const u8,
    name: []const u8,
    src_url: []const u8,
    entry: ?catalog.Entry,
    detail: *std.ArrayListUnmanaged(u8),
) !void {
    const dest = try std.fs.path.join(allocator, &.{ code_dir, name });
    defer allocator.free(dest);
    if (fsx.accessExists(dest)) return error.ProjectExists;
    try fsx.makePath(code_dir);
    try installInto(allocator, io, dest, src_url, entry, detail);
}

pub fn replaceProject(
    allocator: std.mem.Allocator,
    io: Io,
    code_dir: []const u8,
    name: []const u8,
    src_url: []const u8,
    entry: ?catalog.Entry,
    detail: *std.ArrayListUnmanaged(u8),
) !void {
    const dest = try std.fs.path.join(allocator, &.{ code_dir, name });
    defer allocator.free(dest);
    const staging = try std.fmt.allocPrint(allocator, "{s}.maiden-new", .{dest});
    defer allocator.free(staging);
    const backup = try std.fmt.allocPrint(allocator, "{s}.maiden-old", .{dest});
    defer allocator.free(backup);

    if (fsx.accessExists(staging)) fsx.deleteTree(staging) catch {};
    try fsx.makePath(code_dir);
    try installInto(allocator, io, staging, src_url, entry, detail);

    if (fsx.accessExists(backup)) fsx.deleteTree(backup) catch {};
    const had = fsx.accessExists(dest);
    if (had) try fsx.rename(dest, backup);
    fsx.rename(staging, dest) catch |err| {
        if (had) fsx.rename(backup, dest) catch {};
        return err;
    };
    if (had) fsx.deleteTree(backup) catch {};
    fsx.syncParent(dest);
}

fn installInto(
    allocator: std.mem.Allocator,
    io: Io,
    dest: []const u8,
    src_url: []const u8,
    entry: ?catalog.Entry,
    detail: *std.ArrayListUnmanaged(u8),
) !void {
    errdefer fsx.deleteTree(dest) catch {};
    if (std.mem.endsWith(u8, src_url, ".zip")) {
        try installZip(allocator, io, src_url, dest);
    } else {
        try git.clone(allocator, io, src_url, dest, detail);
    }
    try writeMetaData(allocator, io, dest, src_url, entry, null, null);
}

var zip_seq: std.atomic.Value(u32) = .init(0);

fn installZip(allocator: std.mem.Allocator, io: Io, src_url: []const u8, dest: []const u8) !void {
    var archive_path: []u8 = undefined;
    var delete_archive = false;

    if (std.mem.startsWith(u8, src_url, "file:") or std.mem.startsWith(u8, src_url, "/")) {
        const path = if (std.mem.startsWith(u8, src_url, "file://"))
            src_url["file://".len..]
        else if (std.mem.startsWith(u8, src_url, "file:"))
            src_url["file:".len..]
        else
            src_url;
        archive_path = try allocator.dupe(u8, path);
    } else {
        archive_path = try downloadToTemp(allocator, io, src_url, dest);
        delete_archive = true;
    }
    defer {
        if (delete_archive) fsx.deleteFile(archive_path) catch {};
        allocator.free(archive_path);
    }

    const seq = zip_seq.fetchAdd(1, .monotonic);
    const tmp_dest = try std.fmt.allocPrint(allocator, "{s}.extract-{d}", .{ dest, seq });
    defer allocator.free(tmp_dest);
    if (fsx.accessExists(tmp_dest)) fsx.deleteTree(tmp_dest) catch {};
    try fsx.makePath(tmp_dest);
    errdefer fsx.deleteTree(tmp_dest) catch {};

    const file = try fsx.openFile(archive_path);
    defer fsx.closeFile(file);
    var read_buf: [4096]u8 = undefined;
    var reader = fsx.fileReader(file, &read_buf);

    const dest_dir = try fsx.openDirIterate(tmp_dest);
    defer fsx.closeDir(dest_dir);
    try std.zip.extract(dest_dir, &reader, .{});

    var tmp = try fsx.openDirIterate(tmp_dest);
    defer fsx.closeDir(tmp);
    var top_name: ?[]u8 = null;
    defer if (top_name) |n| allocator.free(n);
    var count: usize = 0;
    var it = tmp.iterate();
    while (try fsx.dirNext(&it)) |entry| {
        count += 1;
        if (count == 1 and entry.kind == .directory) {
            top_name = try allocator.dupe(u8, entry.name);
        } else if (count > 1) {
            if (top_name) |n| {
                allocator.free(n);
                top_name = null;
            }
        }
    }

    if (count == 1 and top_name != null) {
        const inner = try std.fs.path.join(allocator, &.{ tmp_dest, top_name.? });
        defer allocator.free(inner);
        try fsx.rename(inner, dest);
        fsx.deleteTree(tmp_dest) catch {};
    } else {
        try fsx.rename(tmp_dest, dest);
    }
}

fn downloadToTemp(allocator: std.mem.Allocator, io: Io, url: []const u8, dest: []const u8) ![]u8 {
    const seq = zip_seq.fetchAdd(1, .monotonic);
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.download-{d}.zip", .{ dest, seq });
    errdefer allocator.free(tmp_name);

    const curl = try fsx.curlExecutable();
    const argv = [_][]const u8{ curl, "-fsSL", "-o", tmp_name, url };
    const result = try std.process.run(allocator, io, .{
        .exe = .detect,
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        fsx.deleteFile(tmp_name) catch {};
        log.warn("zip download failed: {s}", .{result.stderr});
        return error.DownloadFailed;
    }
    const file = try fsx.openFile(tmp_name);
    fsx.syncFile(file);
    fsx.closeFile(file);
    return tmp_name;
}
