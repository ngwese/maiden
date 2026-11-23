const std = @import("std");
const httpz = @import("httpz");
const fsx = @import("../common/fsx.zig");
const respond = @import("respond.zig");
const server = @import("server.zig");

const App = server.App;

const large_file_threshold: u64 = 256 * 1024;

/// GET / → 302 /maiden/
pub fn redirectRoot(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.setStatus(.found);
    res.header("Location", "/maiden/");
}

/// GET /maiden (no trailing slash) → 302 /maiden/; otherwise serve web_path.
pub fn maiden(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (std.mem.eql(u8, req.url.path, "/maiden")) {
        res.setStatus(.found);
        res.header("Location", "/maiden/");
        return;
    }
    try serveStatic(app, req, res, app.cfg.web_path, "/maiden");
}

/// GET /doc/* → serve doc_path.
pub fn doc(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try serveStatic(app, req, res, app.cfg.doc_path, "/doc");
}

fn serveStatic(app: *App, req: *httpz.Request, res: *httpz.Response, root: []const u8, prefix: []const u8) !void {
    _ = app;
    const path = req.url.path;
    var rel = path[prefix.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) rel = "index.html";
    rel = fsx.relativeInside(rel) catch {
        try respond.notFound(req, res, "not found");
        return;
    };
    if (rel.len == 0) rel = "index.html";

    const full = try std.fs.path.join(res.arena, &.{ root, rel });
    if (fsx.statFile(full)) |st| {
        if (st.kind == .directory) {
            const index = try std.fs.path.join(res.arena, &.{ full, "index.html" });
            try sendPath(req, res, index, false);
            return;
        }
    } else |_| {}
    try sendPath(req, res, full, false);
}

/// Send a filesystem path as the response body (or headers-only for HEAD).
pub fn sendPath(req: *httpz.Request, res: *httpz.Response, path: []const u8, sniff: bool) !void {
    const file = fsx.openFile(path) catch {
        try respond.notFound(req, res, "not found");
        return;
    };
    defer fsx.closeFile(file);

    const st = try file.stat(fsx.io);
    const ctype = contentType(file, path, sniff);
    var lm_buf: [respond.http_date_len]u8 = undefined;
    const last_modified = respond.formatHttpDateFromStat(&lm_buf, st);

    res.setStatus(.ok);
    res.header("Content-Type", ctype);
    try res.headerOpts("Last-Modified", last_modified, .{ .dupe_value = true });
    res.header("Cache-Control", "no-store");

    if (req.method == .HEAD) {
        const len = try std.fmt.allocPrint(res.arena, "{d}", .{st.size});
        res.header("Content-Length", len);
        return;
    }

    if (st.size <= large_file_threshold) {
        const data = try res.arena.alloc(u8, @intCast(st.size));
        const n = file.readPositionalAll(fsx.io, data, 0) catch 0;
        res.body = data[0..n];
        return;
    }

    var read_buf: [8192]u8 = undefined;
    var fr = file.reader(fsx.io, &read_buf);
    var chunk_buf: [8192]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk_buf) catch |e| switch (e) {
            error.ReadFailed => {
                if (fr.err) |file_err| return file_err;
                return e;
            },
        };
        if (n == 0) break;
        try res.chunk(chunk_buf[0..n]);
    }
}

fn contentType(file: std.Io.File, path: []const u8, sniff: bool) []const u8 {
    if (extType(path)) |t| return t;
    if (!sniff) return "application/octet-stream";
    var buf: [512]u8 = undefined;
    const n = file.readPositionalAll(fsx.io, &buf, 0) catch 0;
    if (looksLikeText(buf[0..n])) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

/// MIME type from file extension, or null when unknown.
pub fn extType(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".map")) return "application/json";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".sc") or std.mem.endsWith(u8, path, ".scd")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".lua") or
        std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".csv") or
        std.mem.endsWith(u8, path, ".yml") or
        std.mem.endsWith(u8, path, ".yaml") or
        std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".xml"))
    {
        return "text/plain; charset=utf-8";
    }
    if (std.mem.endsWith(u8, path, ".wav")) return "audio/wav";
    if (std.mem.endsWith(u8, path, ".mp3")) return "audio/mpeg";
    if (std.mem.endsWith(u8, path, ".ogg")) return "audio/ogg";
    if (std.mem.endsWith(u8, path, ".aif") or std.mem.endsWith(u8, path, ".aiff")) return "audio/aiff";
    return null;
}

fn looksLikeText(data: []const u8) bool {
    if (data.len == 0) return true;
    for (data) |c| {
        if (c == 0) return false;
        if (c < 0x09) return false;
        if (c > 0x0d and c < 0x20 and c != 0x1b) return false;
    }
    return true;
}
