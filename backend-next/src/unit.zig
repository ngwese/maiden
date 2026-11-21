const fsx = @import("fsx.zig");
const std = @import("std");

pub const Status = struct {
    state: []const u8,
    sub_state: []const u8,
};

pub const UnitError = error{
    NoDbusConnection,
    UnitNotFound,
    UnrecognizedOperation,
    SystemctlFailed,
    OutOfMemory,
};

fn runSystemctl(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) UnitError!std.process.RunResult {
    const bin = fsx.systemctlExecutable() catch return error.NoDbusConnection;
    var full = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(full);
    full[0] = bin;
    @memcpy(full[1..], argv);

    return std.process.run(allocator, io, .{
        .exe = .detect,
        .argv = full,
    }) catch return error.NoDbusConnection;
}

fn dbusDown(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "Failed to connect") != null or
        std.mem.indexOf(u8, text, "System has not been booted") != null;
}

pub fn getStatus(allocator: std.mem.Allocator, io: std.Io, name: []const u8) UnitError!Status {
    const result = try runSystemctl(allocator, io, &.{ "show", name, "--property=LoadState,ActiveState,SubState", "--no-page" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        if (dbusDown(result.stderr)) return error.NoDbusConnection;
        return error.SystemctlFailed;
    }

    var load_state: []const u8 = "";
    var active_state: []const u8 = "";
    var sub_state: []const u8 = "";

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "LoadState=")) {
            load_state = line["LoadState=".len..];
        } else if (std.mem.startsWith(u8, line, "ActiveState=")) {
            active_state = line["ActiveState=".len..];
        } else if (std.mem.startsWith(u8, line, "SubState=")) {
            sub_state = line["SubState=".len..];
        }
    }

    if (std.mem.eql(u8, load_state, "not-found")) return error.UnitNotFound;

    return .{
        .state = try allocator.dupe(u8, active_state),
        .sub_state = try allocator.dupe(u8, sub_state),
    };
}

/// `systemctl` waits until the job finishes. It does not report the dbus job id,
/// so a successful wait is reported as job_id 0 and result "done", which is the
/// result string systemd uses for a completed job.
pub fn doOperation(allocator: std.mem.Allocator, io: std.Io, name: []const u8, operation: []const u8, detail: *std.ArrayListUnmanaged(u8)) UnitError!void {
    if (!std.mem.eql(u8, operation, "start") and
        !std.mem.eql(u8, operation, "stop") and
        !std.mem.eql(u8, operation, "restart"))
    {
        return error.UnrecognizedOperation;
    }

    const result = try runSystemctl(allocator, io, &.{ operation, name });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        if (dbusDown(result.stderr)) return error.NoDbusConnection;
        const text = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \t\r\n");
        const slice = if (text.len > 1024) text[text.len - 1024 ..] else text;
        try detail.appendSlice(allocator, slice);
        return error.SystemctlFailed;
    }
}
