const std = @import("std");
const fsx = @import("fsx.zig");
const log = std.log.scoped(.http);

/// GET `url`, following redirects, and write the body to `dest`.
/// A non-success status leaves the response body in `dest` and returns
/// `error.DownloadFailed`. When `detail` is non-null, a short reason is appended.
pub fn downloadToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest: []const u8,
    detail: ?*std.ArrayListUnmanaged(u8),
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    client.ca_bundle.rescan(allocator, io, std.Io.Timestamp.now(io, .real)) catch |err| {
        log.warn("CA bundle rescan failed: {s}", .{@errorName(err)});
    };

    const file = try fsx.createFile(dest);
    defer fsx.closeFile(file);
    var io_buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &io_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(8),
        .response_writer = &file_writer.interface,
        .keep_alive = false,
    }) catch |err| {
        try note(allocator, detail, @errorName(err));
        return error.DownloadFailed;
    };
    try file_writer.interface.flush();
    fsx.syncFile(file);

    if (result.status.class() != .success) {
        var status_buf: [16]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "HTTP {d}", .{@backingInt(result.status)}) catch "HTTP error";
        try note(allocator, detail, status);
        return error.DownloadFailed;
    }
}

fn note(allocator: std.mem.Allocator, detail: ?*std.ArrayListUnmanaged(u8), text: []const u8) !void {
    const dest = detail orelse return;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const slice = if (trimmed.len > 1024) trimmed[trimmed.len - 1024 ..] else trimmed;
    try dest.appendSlice(allocator, slice);
}
