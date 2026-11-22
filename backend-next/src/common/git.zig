const fsx = @import("fsx.zig");
const std = @import("std");
const log = std.log.scoped(.git);

pub const Pull = union(enum) {
    updated,
    up_to_date,
    failed: []u8,
};

fn capture(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const slice = if (trimmed.len > 1024) trimmed[trimmed.len - 1024 ..] else trimmed;
    return try allocator.dupe(u8, slice);
}

fn runCaptured(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    log.debug("git: {s}", .{argv[1]});
    return try std.process.run(allocator, io, .{
        .exe = .detect,
        .argv = argv,
    });
}

/// `git clone --recurse-submodules` of `url` into `dest`.
/// On failure, appends a bounded copy of git's output to `detail` and returns `error.GitFailed`.
pub fn clone(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8, detail: *std.ArrayListUnmanaged(u8)) !void {
    const git_bin = try fsx.gitExecutable();
    const argv = [_][]const u8{ git_bin, "clone", "--quiet", "--recurse-submodules", url, dest };
    const result = try runCaptured(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        const msg = try capture(allocator, if (result.stderr.len > 0) result.stderr else result.stdout);
        errdefer allocator.free(msg);
        try detail.appendSlice(allocator, msg);
        return error.GitFailed;
    }
}

/// `git pull` in `repo`. `.failed` owns its message; the caller frees it.
/// "Already up to date" is `.up_to_date` even when git exits non-zero.
pub fn pull(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !Pull {
    const git_bin = try fsx.gitExecutable();
    const argv = [_][]const u8{ git_bin, "-C", repo, "pull", "--quiet", "--recurse-submodules" };
    const result = try runCaptured(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    const stderr = result.stderr;
    const up_to_date = std.mem.indexOf(u8, stdout, "Already up to date") != null or
        std.mem.indexOf(u8, stderr, "Already up to date") != null;
    if (!result.term.success()) {
        if (up_to_date) return .up_to_date;
        return .{ .failed = try capture(allocator, if (stderr.len > 0) stderr else stdout) };
    }
    if (up_to_date) return .up_to_date;
    return .updated;
}

/// `git push` in `repo`. Returns `error.GitFailed` when git exits non-zero.
pub fn push(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !void {
    const git_bin = try fsx.gitExecutable();
    const argv = [_][]const u8{ git_bin, "-C", repo, "push", "--quiet" };
    const result = try runCaptured(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        log.warn("git push: {s}", .{result.stderr});
        return error.GitFailed;
    }
}

/// Abbreviated HEAD commit of `repo`, without the trailing newline. Caller frees the result.
pub fn shortHead(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ![]u8 {
    const git_bin = try fsx.gitExecutable();
    const argv = [_][]const u8{ git_bin, "-C", repo, "rev-parse", "--short", "HEAD" };
    const result = try runCaptured(allocator, io, &argv);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        allocator.free(result.stdout);
        return error.GitFailed;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}
