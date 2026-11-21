const std = @import("std");

pub var debug_enabled: bool = false;

fn emit(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    const msg = w.buffered();
    if (msg.len == buf.len) {
        std.debug.print("[{s}] {s} (truncated)\n", .{ level, msg });
    } else {
        std.debug.print("[{s}] {s}\n", .{ level, msg });
    }
}

/// Write an info line to stderr. Messages that do not fit in 8KiB are truncated.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit("info", fmt, args);
}

/// Write a warning line to stderr. Messages that do not fit in 8KiB are truncated.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit("warning", fmt, args);
}

/// Write a debug line to stderr when `debug_enabled` is set. Otherwise this is a no-op.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    emit("debug", fmt, args);
}

/// Write an error line to stderr. Messages that do not fit in 8KiB are truncated.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit("error", fmt, args);
}
