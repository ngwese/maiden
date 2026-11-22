const std = @import("std");

/// Runtime minimum level. Comptime `std_options.log_level` stays `.debug` so
/// debug calls are not stripped; this filters what actually prints.
pub var level: std.log.Level = .info;

pub fn setDebug(enabled: bool) void {
    level = if (enabled) .debug else .info;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(level)) return;
    std.log.defaultLog(message_level, scope, format, args);
}
