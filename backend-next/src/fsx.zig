const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// Process-wide Io handle for filesystem helpers. Set once from main/cli.
pub var io: Io = undefined;
pub var environ: ?*const std.process.Environ.Map = null;
/// Outlives every request. Cached paths must be allocated here, not in a request arena.
var gpa: std.mem.Allocator = undefined;

pub fn setIo(i: Io) void {
    io = i;
}

pub fn setAllocator(allocator: std.mem.Allocator) void {
    gpa = allocator;
}

pub fn setEnviron(map: *const std.process.Environ.Map) void {
    environ = map;
}

pub fn getenv(key: []const u8) ?[]const u8 {
    if (environ) |map| return map.get(key);
    return null;
}

pub fn accessExists(path: []const u8) bool {
    if (Dir.cwd().access(io, path, .{})) |_| return true else |_| {}
    if (std.fs.path.isAbsolute(path)) {
        if (Dir.accessAbsolute(io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

pub fn openFile(path: []const u8) !File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

pub fn createFile(path: []const u8) !File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.createFileAbsolute(io, path, .{});
    }
    return Dir.cwd().createFile(io, path, .{});
}

pub fn closeFile(file: File) void {
    file.close(io);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const limit: Io.Limit = .limited(max);
    if (std.fs.path.isAbsolute(path)) {
        return Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    return Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

pub fn writeAll(file: File, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

pub fn makePath(path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

pub fn deleteTree(path: []const u8) !void {
    try Dir.cwd().deleteTree(io, path);
}

pub fn deleteFile(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try Dir.deleteFileAbsolute(io, path);
    } else {
        try Dir.cwd().deleteFile(io, path);
    }
}

pub fn rename(old: []const u8, new_path: []const u8) !void {
    try Dir.rename(Dir.cwd(), old, Dir.cwd(), new_path, io);
}

pub fn statFile(path: []const u8) !File.Stat {
    return Dir.cwd().statFile(io, path, .{});
}

pub fn openDirIterate(path: []const u8) !Dir {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

pub fn closeDir(dir: Dir) void {
    dir.close(io);
}

pub fn dirNext(dir: *Dir.Iterator) !?Dir.Entry {
    return dir.next(io);
}

pub fn fileReader(file: File, buffer: []u8) File.Reader {
    return file.reader(io, buffer);
}

pub fn setCloexec(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

pub fn syncFile(file: File) void {
    file.sync(io) catch {};
}

pub fn syncParent(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    const dir = openDir(parent) catch return;
    defer closeDir(dir);
    _ = std.posix.system.fsync(dir.handle);
}

pub fn openDir(path: []const u8) !Dir {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openDirAbsolute(io, path, .{});
    }
    return Dir.cwd().openDir(io, path, .{});
}

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
var curl_bin: ?[]u8 = null;
var systemctl_bin: ?[]u8 = null;

fn cachedBin(name: []const u8, slot: *?[]u8) ![]const u8 {
    bin_lock.lockUncancelable(io);
    defer bin_lock.unlock(io);
    if (slot.*) |path| return path;
    const found = try findInPath(gpa, name);
    slot.* = found;
    return found;
}

pub fn gitExecutable() ![]const u8 {
    return cachedBin("git", &git_bin);
}

pub fn curlExecutable() ![]const u8 {
    return cachedBin("curl", &curl_bin);
}

pub fn systemctlExecutable() ![]const u8 {
    return cachedBin("systemctl", &systemctl_bin);
}

/// Rejects NUL and `..` components. A leading slash is stripped.
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
