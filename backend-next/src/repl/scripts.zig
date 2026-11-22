const std = @import("std");
const dust = @import("../project.zig");
const fsx = @import("../common/fsx.zig");
const zigtui = @import("zigtui");

pub const ScriptFile = struct {
    /// Absolute path on disk.
    abs_path: []const u8,
    /// Path matron expects, e.g. `code/project/script.lua`.
    load_path: []const u8,
    /// Basename shown in the tree.
    name: []const u8,
};

pub const ProjectScripts = struct {
    name: []const u8,
    files: []ScriptFile,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    projects: []ProjectScripts = &.{},
    /// Owned TreeNode storage; labels borrow from projects/files.
    roots: []zigtui.TreeNode = &.{},
    /// Flat child arrays owned per project.
    child_arrays: [][]zigtui.TreeNode = &.{},

    pub fn deinit(self: *Catalog) void {
        for (self.projects) |p| {
            for (p.files) |f| {
                self.allocator.free(f.abs_path);
                self.allocator.free(f.load_path);
                self.allocator.free(f.name);
            }
            self.allocator.free(p.files);
            self.allocator.free(p.name);
        }
        self.allocator.free(self.projects);
        for (self.child_arrays) |arr| self.allocator.free(arr);
        self.allocator.free(self.child_arrays);
        self.allocator.free(self.roots);
        self.* = .{ .allocator = self.allocator };
    }
};

/// Scan `code_dir` for project directories and top-level `*.lua` scripts.
pub fn scan(allocator: std.mem.Allocator, code_dir: []const u8) !Catalog {
    var catalog: Catalog = .{ .allocator = allocator };
    errdefer catalog.deinit();

    const projects = dust.getProjects(allocator, code_dir) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {
            catalog.projects = try allocator.alloc(ProjectScripts, 0);
            catalog.roots = try allocator.alloc(zigtui.TreeNode, 0);
            catalog.child_arrays = try allocator.alloc([]zigtui.TreeNode, 0);
            return catalog;
        },
        else => return err,
    };
    defer {
        for (projects) |p| {
            allocator.free(p.name);
            allocator.free(p.root);
        }
        allocator.free(projects);
    }

    var out_projects: std.ArrayListUnmanaged(ProjectScripts) = .empty;
    errdefer {
        for (out_projects.items) |p| {
            for (p.files) |f| {
                allocator.free(f.abs_path);
                allocator.free(f.load_path);
                allocator.free(f.name);
            }
            allocator.free(p.files);
            allocator.free(p.name);
        }
        out_projects.deinit(allocator);
    }

    for (projects) |p| {
        const files = try listProjectScripts(allocator, p.name, p.root);
        if (files.len == 0) {
            for (files) |f| {
                allocator.free(f.abs_path);
                allocator.free(f.load_path);
                allocator.free(f.name);
            }
            allocator.free(files);
            continue;
        }
        try out_projects.append(allocator, .{
            .name = try allocator.dupe(u8, p.name),
            .files = files,
        });
    }

    catalog.projects = try out_projects.toOwnedSlice(allocator);
    try rebuildTree(&catalog);
    return catalog;
}

fn listProjectScripts(allocator: std.mem.Allocator, project_name: []const u8, root: []const u8) ![]ScriptFile {
    var dir = fsx.openDirIterate(root) catch return try allocator.alloc(ScriptFile, 0);
    defer fsx.closeDir(dir);

    var files: std.ArrayListUnmanaged(ScriptFile) = .empty;
    errdefer {
        for (files.items) |f| {
            allocator.free(f.abs_path);
            allocator.free(f.load_path);
            allocator.free(f.name);
        }
        files.deinit(allocator);
    }

    var it = dir.iterate();
    while (try fsx.dirNext(&it)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
        if (isSkippedName(entry.name)) continue;

        const abs = try std.fs.path.join(allocator, &.{ root, entry.name });
        errdefer allocator.free(abs);
        const load_path = try std.fmt.allocPrint(allocator, "code/{s}/{s}", .{ project_name, entry.name });
        errdefer allocator.free(load_path);
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try files.append(allocator, .{
            .abs_path = abs,
            .load_path = load_path,
            .name = name,
        });
    }

    std.mem.sort(ScriptFile, files.items, {}, scriptLess);
    return try files.toOwnedSlice(allocator);
}

fn isSkippedName(name: []const u8) bool {
    _ = name;
    return false;
}

fn scriptLess(_: void, a: ScriptFile, b: ScriptFile) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn rebuildTree(catalog: *Catalog) !void {
    for (catalog.child_arrays) |arr| catalog.allocator.free(arr);
    catalog.allocator.free(catalog.child_arrays);
    catalog.allocator.free(catalog.roots);

    const child_arrays = try catalog.allocator.alloc([]zigtui.TreeNode, catalog.projects.len);
    errdefer {
        for (child_arrays) |arr| catalog.allocator.free(arr);
        catalog.allocator.free(child_arrays);
    }
    @memset(child_arrays, &.{});

    const roots = try catalog.allocator.alloc(zigtui.TreeNode, catalog.projects.len);
    errdefer catalog.allocator.free(roots);

    for (catalog.projects, 0..) |p, i| {
        const children = try catalog.allocator.alloc(zigtui.TreeNode, p.files.len);
        for (p.files, 0..) |f, j| {
            children[j] = .{ .label = f.name };
        }
        child_arrays[i] = children;
        roots[i] = .{
            .label = p.name,
            .children = children,
            .expanded = true,
        };
    }

    catalog.child_arrays = child_arrays;
    catalog.roots = roots;
}

/// Resolve the focused script from a flat tree selection index (same order as ZigTUI Tree).
pub fn scriptAtSelection(catalog: *const Catalog, selected: ?usize) ?ScriptFile {
    const sel = selected orelse return null;
    var idx: usize = 0;
    for (catalog.projects, 0..) |p, pi| {
        if (idx == sel) return null; // project directory node
        idx += 1;
        const expanded = if (pi < catalog.roots.len) catalog.roots[pi].expanded else true;
        if (!expanded) continue;
        for (p.files) |f| {
            if (idx == sel) return f;
            idx += 1;
        }
    }
    return null;
}

/// Resolve the project name when a top-level directory node is selected.
pub fn projectAtSelection(catalog: *const Catalog, selected: ?usize) ?[]const u8 {
    const sel = selected orelse return null;
    var idx: usize = 0;
    for (catalog.projects, 0..) |p, pi| {
        if (idx == sel) return p.name;
        idx += 1;
        const expanded = if (pi < catalog.roots.len) catalog.roots[pi].expanded else true;
        if (!expanded) continue;
        idx += p.files.len;
    }
    return null;
}

/// Flat tree index of the script with `load_path`, if currently visible.
pub fn selectionForLoadPath(catalog: *const Catalog, load_path: []const u8) ?usize {
    var idx: usize = 0;
    for (catalog.projects, 0..) |p, pi| {
        idx += 1;
        const expanded = if (pi < catalog.roots.len) catalog.roots[pi].expanded else true;
        if (!expanded) continue;
        for (p.files) |f| {
            if (std.mem.eql(u8, f.load_path, load_path)) return idx;
            idx += 1;
        }
    }
    return null;
}

pub const CreatedScript = struct {
    abs_path: []u8,
    load_path: []u8,

    pub fn deinit(self: CreatedScript, allocator: std.mem.Allocator) void {
        allocator.free(self.abs_path);
        allocator.free(self.load_path);
    }
};

/// Trim and validate a new project/script name.
pub fn validateProjectName(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyName;
    if (trimmed[0] == '.') return error.InvalidName;
    if (std.mem.eql(u8, trimmed, "..")) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) return error.InvalidName;
    return trimmed;
}

/// Create `{dust_code}/{name}/` and `{name}.lua` inside it. Caller frees via `CreatedScript.deinit`.
pub fn createProjectScript(allocator: std.mem.Allocator, dust_code: []const u8, name: []const u8) !CreatedScript {
    const valid = try validateProjectName(name);
    const dir = try std.fs.path.join(allocator, &.{ dust_code, valid });
    defer allocator.free(dir);

    if (fsx.accessExists(dir)) return error.AlreadyExists;

    try fsx.makePath(dir);
    errdefer fsx.deleteTree(dir) catch {};

    const lua_name = try std.fmt.allocPrint(allocator, "{s}.lua", .{valid});
    defer allocator.free(lua_name);
    const abs_path = try std.fs.path.join(allocator, &.{ dir, lua_name });
    errdefer allocator.free(abs_path);

    const file = try fsx.createFile(abs_path);
    defer fsx.closeFile(file);

    const load_path = try std.fmt.allocPrint(allocator, "code/{s}/{s}.lua", .{ valid, valid });
    errdefer allocator.free(load_path);

    return .{ .abs_path = abs_path, .load_path = load_path };
}

/// Matron command that loads `load_path`. Caller frees the result.
pub fn playCommand(allocator: std.mem.Allocator, load_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "norns.script.load(\"{s}\")", .{load_path});
}

pub const stop_command = "norns.script.clear()";

/// Split `$EDITOR` (or `vim`) into argv with `file` appended. Caller frees the slice and each owned arg except `file`.
pub fn editorArgv(allocator: std.mem.Allocator, editor_env: ?[]const u8, file: []const u8) ![]const []const u8 {
    const raw = blk: {
        if (editor_env) |e| {
            const trimmed = std.mem.trim(u8, e, " \t");
            if (trimmed.len > 0) break :blk trimmed;
        }
        break :blk "vim";
    };

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |tok| {
        try parts.append(allocator, try allocator.dupe(u8, tok));
    }
    if (parts.items.len == 0) {
        try parts.append(allocator, try allocator.dupe(u8, "vim"));
    }
    try parts.append(allocator, file);
    return try parts.toOwnedSlice(allocator);
}

/// Free argv from `editorArgv` (the last entry is `file` and is not freed).
pub fn freeEditorArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) {
        allocator.free(argv);
        return;
    }
    for (argv[0 .. argv.len - 1]) |a| allocator.free(a);
    allocator.free(argv);
}

test "validateProjectName" {
    try std.testing.expectEqualStrings("awake", try validateProjectName("  awake  "));
    try std.testing.expectError(error.EmptyName, validateProjectName("   "));
    try std.testing.expectError(error.InvalidName, validateProjectName(".hidden"));
    try std.testing.expectError(error.InvalidName, validateProjectName("a/b"));
}

test "projectAtSelection resolves top-level dirs only" {
    var catalog: Catalog = .{ .allocator = std.testing.allocator };
    defer catalog.deinit();

    const files = try std.testing.allocator.alloc(ScriptFile, 1);
    files[0] = .{
        .abs_path = try std.testing.allocator.dupe(u8, "/dust/code/awake/awake.lua"),
        .load_path = try std.testing.allocator.dupe(u8, "code/awake/awake.lua"),
        .name = try std.testing.allocator.dupe(u8, "awake.lua"),
    };
    const projects = try std.testing.allocator.alloc(ProjectScripts, 1);
    projects[0] = .{
        .name = try std.testing.allocator.dupe(u8, "awake"),
        .files = files,
    };
    catalog.projects = projects;

    const children = try std.testing.allocator.alloc(zigtui.TreeNode, 1);
    children[0] = .{ .label = files[0].name };
    const child_arrays = try std.testing.allocator.alloc([]zigtui.TreeNode, 1);
    child_arrays[0] = children;
    catalog.child_arrays = child_arrays;

    const roots = try std.testing.allocator.alloc(zigtui.TreeNode, 1);
    roots[0] = .{ .label = projects[0].name, .children = children, .expanded = true };
    catalog.roots = roots;

    try std.testing.expectEqualStrings("awake", projectAtSelection(&catalog, 0).?);
    try std.testing.expect(projectAtSelection(&catalog, 1) == null);
    try std.testing.expect(scriptAtSelection(&catalog, 0) == null);
    try std.testing.expectEqualStrings("awake.lua", scriptAtSelection(&catalog, 1).?.name);
}

test "playCommand formats load path" {
    const cmd = try playCommand(std.testing.allocator, "code/foo/bar.lua");
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("norns.script.load(\"code/foo/bar.lua\")", cmd);
}

test "editorArgv splits EDITOR and appends file" {
    const argv = try editorArgv(std.testing.allocator, "nvim -R", "/tmp/x.lua");
    defer freeEditorArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("nvim", argv[0]);
    try std.testing.expectEqualStrings("-R", argv[1]);
    try std.testing.expectEqualStrings("/tmp/x.lua", argv[2]);
}

test "editorArgv falls back to vim" {
    const argv = try editorArgv(std.testing.allocator, "  ", "/tmp/x.lua");
    defer freeEditorArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("vim", argv[0]);
}
