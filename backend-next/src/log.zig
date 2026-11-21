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

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit("info", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit("warning", fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    emit("debug", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit("error", fmt, args);
}
