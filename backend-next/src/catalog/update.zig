const std = @import("std");
const Io = std.Io;
const catalog = @import("catalog.zig");
const config = @import("../common/config.zig");
const log = std.log.scoped(.catalog);

/// Download each configured catalog source once. Used by `maiden catalog update`.
/// Does not start the retry loop the server runs in the background.
pub fn updateCatalogs(allocator: std.mem.Allocator, io: Io, cfg: *config.Config) !void {
    try updateConfiguredCatalogs(allocator, io, cfg);
}

pub fn updateConfiguredCatalogs(allocator: std.mem.Allocator, io: Io, cfg: *config.Config) !void {
    const sources = try catalog.loadSources(allocator, cfg);
    defer {
        for (sources) |*s| s.deinit();
        allocator.free(sources);
    }
    for (sources) |src| {
        if (cfg.catalog_output_dir.len == 0) continue;
        if (src.method().len == 0) {
            log.warn("source method not specified for {s}", .{src.name()});
            continue;
        }
        if (!std.mem.eql(u8, src.method(), "download")) {
            log.warn("unhandled source method: {s}", .{src.method()});
            continue;
        }
        const fname = try std.fmt.allocPrint(allocator, "{s}.json", .{src.name()});
        defer allocator.free(fname);
        const out_path = try std.fs.path.join(allocator, &.{ cfg.catalog_output_dir, fname });
        defer allocator.free(out_path);
        log.info("Updating: {s}; ", .{src.name()});
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        defer detail.deinit(allocator);
        catalog.downloadToFile(allocator, io, src.url(), out_path, &detail) catch |err| {
            log.warn("download failed: {s} {s}", .{ @errorName(err), detail.items });
        };
    }
}
