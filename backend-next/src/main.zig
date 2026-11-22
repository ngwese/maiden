const std = @import("std");
const cli = @import("cli.zig");
const zigtui = @import("zigtui");
const common = @import("common.zig");

/// Compile all log levels; runtime filtering is in `common.log.logFn` / `--debug`.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = common.log.logFn,
};

/// Restore the terminal if a panic happens while the REPL is in raw mode.
/// No-op when raw mode was never entered (e.g. `maiden server`).
pub const panic = zigtui.panic;

/// Process entry. Installs the filesystem helpers, then runs the CLI.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip argv0

    const fsx = common.fsx;
    fsx.setIo(io);
    fsx.setAllocator(gpa);
    fsx.setEnviron(init.environ_map);
    defer fsx.deinitCaches();

    cli.run(gpa, io, &arg_it) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        // exit() skips defers; free caches before aborting.
        fsx.deinitCaches();
        std.process.exit(1);
    };
}

test {
    _ = @import("repl.zig");
    _ = @import("common.zig");
    _ = @import("catalog.zig");
    _ = @import("project.zig");
    _ = @import("server.zig");
}
