const std = @import("std");
const cli = @import("cli.zig");

/// Process entry. Installs the filesystem helpers, then runs the CLI.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    defer arg_it.deinit();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }
    while (arg_it.next()) |a| {
        try args.append(gpa, try gpa.dupe(u8, a));
    }

    const fsx = @import("fsx.zig");
    fsx.setIo(io);
    fsx.setAllocator(gpa);
    fsx.setEnviron(init.environ_map);
    defer fsx.deinitCaches();

    cli.run(gpa, io, args.items) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        // exit() skips defers; free caches before aborting.
        fsx.deinitCaches();
        std.process.exit(1);
    };
}
