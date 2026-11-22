const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// Process-wide Io handle for filesystem helpers. Set once from main/cli.
pub var io: Io = undefined;
pub var environ: ?*const std.process.Environ.Map = null;
/// Outlives every request. Cached paths must be allocated here, not in a request arena.
var gpa: std.mem.Allocator = undefined;

/// Install the process Io handle used by every filesystem helper.
pub fn setIo(i: Io) void {
    io = i;
}

/// Install the allocator used for process-lifetime caches such as executable paths.
/// Must outlive every request arena.
pub fn setAllocator(allocator: std.mem.Allocator) void {
    gpa = allocator;
}

/// Install the environment map consulted by `getenv`. The map must outlive the process.
pub fn setEnviron(map: *const std.process.Environ.Map) void {
    environ = map;
}

/// Value of `key`, or null when unset or `setEnviron` has not been called.
/// The slice is borrowed from the environment map.
pub fn getenv(key: []const u8) ?[]const u8 {
    if (environ) |map| return map.get(key);
    return null;
}

/// True when `path` can be accessed. Errors are treated as absence.
pub fn accessExists(path: []const u8) bool {
    if (Dir.cwd().access(io, path, .{})) |_| return true else |_| {}
    if (std.fs.path.isAbsolute(path)) {
        if (Dir.accessAbsolute(io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Open `path` for reading. Absolute and relative paths are both accepted.
pub fn openFile(path: []const u8) !File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

/// Create or truncate `path` for writing. Absolute and relative paths are both accepted.
pub fn createFile(path: []const u8) !File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.createFileAbsolute(io, path, .{});
    }
    return Dir.cwd().createFile(io, path, .{});
}

/// Close `file`.
pub fn closeFile(file: File) void {
    file.close(io);
}

/// Read `path` into memory, failing with `error.StreamTooLong` above `max` bytes.
/// Caller frees the result.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const limit: Io.Limit = .limited(max);
    if (std.fs.path.isAbsolute(path)) {
        return Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    return Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

/// Write `data` to `file` and flush the writer. Does not fsync.
pub fn writeAll(file: File, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// Create `path` and any missing parents.
pub fn makePath(path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

/// Recursively delete `path`, whether it is a file or a directory.
pub fn deleteTree(path: []const u8) !void {
    try Dir.cwd().deleteTree(io, path);
}

/// Delete the file at `path`. Does not remove directories.
pub fn deleteFile(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try Dir.deleteFileAbsolute(io, path);
    } else {
        try Dir.cwd().deleteFile(io, path);
    }
}

/// Rename `old` to `new_path`.
pub fn rename(old: []const u8, new_path: []const u8) !void {
    try Dir.rename(Dir.cwd(), old, Dir.cwd(), new_path, io);
}

/// Stat `path`. Follows the same absolute-path rules as `openFile`.
pub fn statFile(path: []const u8) !File.Stat {
    return Dir.cwd().statFile(io, path, .{});
}

/// Open `path` for iteration. Caller passes the result to `closeDir`.
pub fn openDirIterate(path: []const u8) !Dir {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

/// Close a directory opened by `openDir` or `openDirIterate`.
pub fn closeDir(dir: Dir) void {
    dir.close(io);
}

/// Next directory entry, or null at the end. `Entry.name` is valid only until the next call.
pub fn dirNext(dir: *Dir.Iterator) !?Dir.Entry {
    return dir.next(io);
}

/// Positional reader for `file`. `buffer` is the read-ahead storage and must outlive the reader.
pub fn fileReader(file: File, buffer: []u8) File.Reader {
    return file.reader(io, buffer);
}

/// Set `FD_CLOEXEC` on `fd` so child processes do not inherit it. Failures are ignored.
pub fn setCloexec(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

/// fsync `file`. Failures are ignored.
pub fn syncFile(file: File) void {
    file.sync(io) catch {};
}

/// fsync the directory containing `path` so a rename is durable. Failures are ignored.
pub fn syncParent(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    const dir = openDir(parent) catch return;
    defer closeDir(dir);
    _ = std.posix.system.fsync(dir.handle);
}

/// Open `path` without iteration. Caller passes the result to `closeDir`.
pub fn openDir(path: []const u8) !Dir {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openDirAbsolute(io, path, .{});
    }
    return Dir.cwd().openDir(io, path, .{});
}

/// First executable named `name` on `PATH`. Caller frees the result.
/// Returns `error.BinaryNotFound` when no directory contains it.
pub fn findInPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path_env = getenv("PATH") orelse "/usr/bin:/bin:/usr/local/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (accessExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.BinaryNotFound;
}

var bin_lock: std.Io.Mutex = .init;
var git_bin: ?[]u8 = null;
var systemctl_bin: ?[]u8 = null;

fn cachedBin(name: []const u8, slot: *?[]u8) ![]const u8 {
    bin_lock.lockUncancelable(io);
    defer bin_lock.unlock(io);
    if (slot.*) |path| return path;
    const found = try findInPath(gpa, name);
    slot.* = found;
    return found;
}

/// Path to `git`, cached for the process lifetime. The slice must not be freed.
pub fn gitExecutable() ![]const u8 {
    return cachedBin("git", &git_bin);
}

/// Path to `systemctl`, cached for the process lifetime. The slice must not be freed.
pub fn systemctlExecutable() ![]const u8 {
    return cachedBin("systemctl", &systemctl_bin);
}

/// Free process-lifetime executable path caches. Call before process exit so
/// SafeAllocator does not report intentional caches as leaks.
pub fn deinitCaches() void {
    bin_lock.lockUncancelable(io);
    defer bin_lock.unlock(io);
    if (git_bin) |p| {
        gpa.free(p);
        git_bin = null;
    }
    if (systemctl_bin) |p| {
        gpa.free(p);
        systemctl_bin = null;
    }
}

/// `name` with one leading slash removed, or `error.BadPath` when it contains NUL or a `..` component.
/// The result aliases `name` or a suffix of it.
pub fn relativeInside(name: []const u8) error{BadPath}![]const u8 {
    var n = name;
    if (n.len > 0 and n[0] == '/') n = n[1..];
    if (std.mem.indexOfScalar(u8, n, 0) != null) return error.BadPath;
    var it = std.mem.splitScalar(u8, n, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.BadPath;
    }
    return n;
}
