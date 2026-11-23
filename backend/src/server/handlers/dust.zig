const std = @import("std");
const httpz = @import("httpz");
const dust = @import("../../project/dust.zig");
const fsx = @import("../../common/fsx.zig");
const urlx = @import("../../common/urlx.zig");
const respond = @import("../respond.zig");
const static = @import("../static.zig");
const server = @import("../server.zig");

const App = server.App;
const log = std.log.scoped(.server);

var save_seq: std.atomic.Value(u32) = .init(0);

const body_read_timeout_ms: usize = 300_000;

/// GET/HEAD /api/v1/dust and /api/v1/dust/*
pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = dustName(req.url.path);
    const abs = dust.devicePath(res.arena, app.cfg.dust_path, name) catch |e| switch (e) {
        error.BadPath => {
            try respond.err(res, .bad_request, "invalid path");
            return;
        },
        else => return e,
    };

    if (name.len == 0 or std.mem.eql(u8, name, "/")) {
        const st = fsx.statFile(abs) catch {
            try respond.notFound(req, res, "file does not exist");
            return;
        };
        const entries = dust.listDir(res.arena, abs, "/api/v1/dust") catch |e| {
            try respond.err(res, .bad_request, @errorName(e));
            return;
        };
        const body = try formatDirListing(res.arena, "", "/api/v1/dust", entries);
        var lm_buf: [respond.http_date_len]u8 = undefined;
        const last_modified = respond.formatHttpDateFromStat(&lm_buf, st);
        try res.headerOpts("Last-Modified", last_modified, .{ .dupe_value = true });
        if (req.method == .HEAD) {
            res.setStatus(.ok);
            res.header("Cache-Control", "no-store");
            res.content_type = .JSON;
            const len = try std.fmt.allocPrint(res.arena, "{d}", .{body.len});
            res.header("Content-Length", len);
            return;
        }
        respond.jsonBody(res, .ok, body);
        return;
    }

    const st = fsx.statFile(abs) catch {
        try respond.notFound(req, res, "file does not exist");
        return;
    };

    if (st.kind == .directory) {
        var n = name;
        if (n.len > 0 and n[0] == '/') n = n[1..];
        const prefix = try std.fmt.allocPrint(res.arena, "/api/v1/dust/{s}", .{n});
        const entries = try dust.listDir(res.arena, abs, prefix);
        const body = try formatDirListing(res.arena, n, prefix, entries);
        var lm_buf: [respond.http_date_len]u8 = undefined;
        const last_modified = respond.formatHttpDateFromStat(&lm_buf, st);
        try res.headerOpts("Last-Modified", last_modified, .{ .dupe_value = true });
        if (req.method == .HEAD) {
            res.setStatus(.ok);
            res.header("Cache-Control", "no-store");
            res.content_type = .JSON;
            const len = try std.fmt.allocPrint(res.arena, "{d}", .{body.len});
            res.header("Content-Length", len);
            return;
        }
        respond.jsonBody(res, .ok, body);
        return;
    }

    try static.sendPath(req, res, abs, true);
}

/// PUT /api/v1/dust and /api/v1/dust/*
pub fn put(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = dustName(req.url.path);
    const abs = dust.devicePath(res.arena, app.cfg.dust_path, name) catch |e| switch (e) {
        error.BadPath => {
            try respond.err(res, .bad_request, "invalid path");
            return;
        },
        else => return e,
    };

    const qs = try req.query();
    if (qs.get("kind")) |kind| {
        if (std.mem.eql(u8, kind, "directory")) {
            fsx.makePath(abs) catch |e| {
                try respond.err(res, .internal_server_error, @errorName(e));
                return;
            };
            fsx.syncParent(abs);
            const text = try std.fmt.allocPrint(res.arena, "created directory {s}", .{abs});
            try respond.msg(res, .ok, text);
            return;
        }
    }

    if (respond.ifUnmodifiedSinceFailed(req, abs)) {
        try respond.err(res, .precondition_failed, "file has been modified");
        return;
    }

    const content_type = if (req.header("content-type")) |ct| try res.arena.dupe(u8, ct) else null;
    if (std.fs.path.dirname(abs)) |dir| {
        fsx.makePath(dir) catch |e| {
            try respond.err(res, .internal_server_error, @errorName(e));
            return;
        };
    }

    // Write to a sibling first so a full disk does not truncate the live script.
    const tmp = try std.fmt.allocPrint(res.arena, "{s}.maiden-save-{d}", .{ abs, save_seq.fetchAdd(1, .monotonic) });
    var committed = false;
    defer if (!committed) fsx.deleteFile(tmp) catch {};

    const file = fsx.createFile(tmp) catch |e| {
        try respond.err(res, .internal_server_error, @errorName(e));
        return;
    };
    defer fsx.closeFile(file);

    var body_reader = req.reader(body_read_timeout_ms) catch |e| {
        try respond.err(res, .bad_request, @errorName(e));
        return;
    };
    // Use httpz Reader.read directly — its Io.Reader has an empty buffer and
    // discardRemaining/readSliceShort panic or busy-loop on that interface.
    const saved = streamMultipartValue(res.arena, &body_reader, content_type, file) catch |e| switch (e) {
        error.NoMultipart, error.FieldNotFound => {
            try respond.err(res, .bad_request, "http: no such file");
            return;
        },
        else => {
            try respond.err(res, .internal_server_error, @errorName(e));
            return;
        },
    };
    fsx.syncFile(file);
    fsx.rename(tmp, abs) catch |e| {
        try respond.err(res, .internal_server_error, @errorName(e));
        return;
    };
    committed = true;
    fsx.syncParent(abs);

    const filename = if (saved.filename.len > 0) saved.filename else "value";
    const text = try std.fmt.allocPrint(res.arena, "uploaded {s} ({d}) to {s}", .{ filename, saved.bytes, abs });
    var lm_buf: [respond.http_date_len]u8 = undefined;
    if (fsx.statFile(abs)) |st| {
        const last_modified = respond.formatHttpDateFromStat(&lm_buf, st);
        try res.headerOpts("Last-Modified", last_modified, .{ .dupe_value = true });
        try respond.value(res, .ok, .{ .message = text });
    } else |_| {
        try respond.msg(res, .ok, text);
    }
}

/// PATCH /api/v1/dust and /api/v1/dust/* — rename via form field `name`.
pub fn patch(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = dustName(req.url.path);
    const abs = dust.devicePath(res.arena, app.cfg.dust_path, name) catch |e| switch (e) {
        error.BadPath => {
            try respond.err(res, .bad_request, "invalid path");
            return;
        },
        else => return e,
    };

    if (!fsx.accessExists(abs)) {
        try respond.err(res, .not_found, "file does not exist");
        return;
    }
    const content_type = if (req.header("content-type")) |ct| try res.arena.dupe(u8, ct) else null;
    const body_bytes = try readBody(req, res.arena, 64 * 1024);
    const new_name = extractFormName(res.arena, body_bytes, content_type) catch {
        try respond.err(res, .bad_request, "missing 'name' key in form");
        return;
    };

    var n = name;
    if (n.len > 0 and n[0] == '/') n = n[1..];
    const parent = std.fs.path.dirname(n) orelse "";
    const rename_rel = if (parent.len > 0)
        try std.fs.path.join(res.arena, &.{ parent, new_name })
    else
        new_name;
    const rename_abs = dust.devicePath(res.arena, app.cfg.dust_path, rename_rel) catch |e| switch (e) {
        error.BadPath => {
            try respond.err(res, .bad_request, "invalid path");
            return;
        },
        else => return e,
    };

    fsx.rename(abs, rename_abs) catch |e| {
        try respond.err(res, .internal_server_error, @errorName(e));
        return;
    };
    fsx.syncParent(rename_abs);

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rename_rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try parts.append(res.arena, part);
    }
    const url = try dust.resourcePath(res.arena, "/api/v1/dust", parts.items);
    try respond.value(res, .ok, .{ .url = url });
}

/// DELETE /api/v1/dust and /api/v1/dust/*
pub fn delete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = dustName(req.url.path);
    const abs = dust.devicePath(res.arena, app.cfg.dust_path, name) catch |e| switch (e) {
        error.BadPath => {
            try respond.err(res, .bad_request, "invalid path");
            return;
        },
        else => return e,
    };

    if (!fsx.accessExists(abs)) {
        try respond.err(res, .not_found, "file does not exist");
        return;
    }
    fsx.deleteTree(abs) catch |e| {
        try respond.err(res, .internal_server_error, @errorName(e));
        return;
    };
    const text = try std.fmt.allocPrint(res.arena, "deleted {s}", .{abs});
    try respond.msg(res, .ok, text);
}

fn dustName(path: []const u8) []const u8 {
    const prefix = "/api/v1/dust";
    if (path.len > prefix.len) return path[prefix.len..];
    return "";
}

fn formatDirListing(allocator: std.mem.Allocator, path: []const u8, url: []const u8, entries: []const dust.FileInfo) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer };
    try j.beginObject();
    try j.objectField("path");
    try j.write(path);
    try j.objectField("url");
    try j.write(url);
    try j.objectField("entries");
    try j.beginArray();
    for (entries) |e| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(e.name);
        try j.objectField("url");
        try j.write(e.url);
        if (e.is_dir) {
            try j.objectField("children");
            try j.beginArray();
            try j.endArray();
        }
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    return try out.toOwnedSlice();
}

fn readBody(req: *httpz.Request, arena: std.mem.Allocator, limit: usize) ![]const u8 {
    if (req.body()) |b| {
        if (b.len > limit) return error.StreamTooLong;
        return b;
    }
    var r = try req.reader(30_000);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = try r.read(&chunk);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.StreamTooLong;
        try out.appendSlice(arena, chunk[0..n]);
    }
    return try out.toOwnedSlice(arena);
}

const SavedPart = struct {
    filename: []const u8,
    bytes: u64,
};

/// Stream the multipart part named "value" onto `file`. The request body is not buffered.
fn streamMultipartValue(allocator: std.mem.Allocator, reader: *httpz.Request.Reader, content_type: ?[]const u8, file: std.Io.File) !SavedPart {
    const ct = content_type orelse return error.NoMultipart;
    const boundary = multipartBoundary(ct) orelse return error.NoMultipart;
    var marker_buf: [208]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "--{s}", .{boundary}) catch return error.NoMultipart;
    var delim_buf: [212]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n{s}", .{marker}) catch return error.NoMultipart;

    var scan = MultipartScan{ .reader = reader };
    defer drainHttpzReader(reader);

    try scan.consumeThrough(marker);
    while (true) {
        if (std.mem.startsWith(u8, scan.buffered(), "--")) {
            scan.consume(2);
            return error.FieldNotFound;
        }
        const headers = try scan.readUntil(allocator, "\r\n\r\n", 8192);
        defer allocator.free(headers);
        const is_value = std.mem.indexOf(u8, headers, "name=\"value\"") != null;
        if (!is_value) {
            try scan.consumeThrough(delim);
            continue;
        }
        const filename = try allocator.dupe(u8, filenameFromHeaders(headers));
        var out_buf: [8192]u8 = undefined;
        var out = file.writer(fsx.io, &out_buf);
        const bytes = try scan.writeUntil(&out, delim);
        try flushFileWriter(&out);
        return .{ .filename = filename, .bytes = bytes };
    }
}

fn drainHttpzReader(reader: *httpz.Request.Reader) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch break;
        if (n == 0) break;
    }
}

fn multipartBoundary(ct: []const u8) ?[]const u8 {
    const key = "boundary=";
    const at = std.mem.indexOf(u8, ct, key) orelse return null;
    var boundary = ct[at + key.len ..];
    if (std.mem.indexOfAny(u8, boundary, "; \t")) |end| boundary = boundary[0..end];
    if (boundary.len >= 2 and boundary[0] == '"') {
        boundary = boundary[1..];
        if (std.mem.indexOfScalar(u8, boundary, '"')) |end| boundary = boundary[0..end];
    }
    if (boundary.len == 0 or boundary.len > 200) return null;
    return boundary;
}

const MultipartScan = struct {
    reader: *httpz.Request.Reader,
    buf: [16384]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn buffered(self: *MultipartScan) []u8 {
        return self.buf[self.start..self.end];
    }

    fn consume(self: *MultipartScan, n: usize) void {
        self.start += n;
    }

    fn fill(self: *MultipartScan) !bool {
        if (self.start > 0) {
            const kept = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..kept], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = kept;
        }
        if (self.end == self.buf.len) return false;
        const n = self.reader.read(self.buf[self.end..]) catch return error.ReadFailed;
        if (n == 0) return false;
        self.end += n;
        return true;
    }

    fn consumeThrough(self: *MultipartScan, needle: []const u8) !void {
        while (true) {
            if (std.mem.indexOf(u8, self.buffered(), needle)) |i| {
                self.consume(i + needle.len);
                return;
            }
            const view = self.buffered();
            if (view.len >= needle.len) self.consume(view.len - (needle.len - 1));
            if (!try self.fill()) return error.FieldNotFound;
        }
    }

    fn readUntil(self: *MultipartScan, allocator: std.mem.Allocator, needle: []const u8, max: usize) ![]u8 {
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        errdefer acc.deinit(allocator);
        while (true) {
            if (std.mem.indexOf(u8, self.buffered(), needle)) |i| {
                try acc.appendSlice(allocator, self.buffered()[0..i]);
                self.consume(i + needle.len);
                return try acc.toOwnedSlice(allocator);
            }
            const view = self.buffered();
            if (view.len >= needle.len) {
                const flush = view.len - (needle.len - 1);
                if (acc.items.len + flush > max) return error.NoMultipart;
                try acc.appendSlice(allocator, view[0..flush]);
                self.consume(flush);
            }
            if (!try self.fill()) return error.FieldNotFound;
        }
    }

    fn writeUntil(self: *MultipartScan, out: *std.Io.File.Writer, needle: []const u8) !u64 {
        var total: u64 = 0;
        while (true) {
            if (std.mem.indexOf(u8, self.buffered(), needle)) |i| {
                const chunk = self.buffered()[0..i];
                try writeFileChunk(out, chunk);
                total += chunk.len;
                self.consume(i + needle.len);
                return total;
            }
            const view = self.buffered();
            if (view.len >= needle.len) {
                const flush = view.len - (needle.len - 1);
                try writeFileChunk(out, view[0..flush]);
                total += flush;
                self.consume(flush);
            }
            if (!try self.fill()) return error.FieldNotFound;
        }
    }
};

fn writeFileChunk(out: *std.Io.File.Writer, data: []const u8) !void {
    out.interface.writeAll(data) catch |e| switch (e) {
        error.WriteFailed => {
            if (out.write_file_err) |file_err| return file_err;
            if (out.err) |file_err| return file_err;
            return e;
        },
    };
}

fn flushFileWriter(out: *std.Io.File.Writer) !void {
    out.interface.flush() catch |e| switch (e) {
        error.WriteFailed => {
            if (out.write_file_err) |file_err| return file_err;
            if (out.err) |file_err| return file_err;
            return e;
        },
    };
}

const Part = struct {
    data: []const u8,
    filename: []const u8,
};

fn extractMultipartField(body: []const u8, content_type: ?[]const u8, field: []const u8) !Part {
    const ct = content_type orelse return error.NoMultipart;
    const bkey = "boundary=";
    const bpos = std.mem.indexOf(u8, ct, bkey) orelse return error.NoMultipart;
    var boundary = ct[bpos + bkey.len ..];
    if (std.mem.indexOfAny(u8, boundary, "; \t")) |end| boundary = boundary[0..end];
    if (boundary.len >= 2 and boundary[0] == '"') {
        boundary = boundary[1..];
        if (std.mem.indexOfScalar(u8, boundary, '"')) |e| boundary = boundary[0..e];
    }

    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "--{s}", .{boundary}) catch return error.NoMultipart;
    var name_buf: [160]u8 = undefined;
    const disp = std.fmt.bufPrint(&name_buf, "name=\"{s}\"", .{field}) catch return error.FieldNotFound;

    var rest = body;
    while (std.mem.indexOf(u8, rest, marker)) |idx| {
        rest = rest[idx + marker.len ..];
        if (std.mem.startsWith(u8, rest, "--")) break;
        if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..];

        const header_end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse break;
        const headers = rest[0..header_end];
        const after = rest[header_end + 4 ..];

        if (std.mem.indexOf(u8, headers, disp) != null) {
            const next = std.mem.indexOf(u8, after, marker) orelse after.len;
            var data = after[0..next];
            if (std.mem.endsWith(u8, data, "\r\n")) data = data[0 .. data.len - 2];
            return .{ .data = data, .filename = filenameFromHeaders(headers) };
        }
        rest = after;
    }
    return error.FieldNotFound;
}

fn filenameFromHeaders(headers: []const u8) []const u8 {
    const key = "filename=\"";
    const i = std.mem.indexOf(u8, headers, key) orelse return "";
    const rest = headers[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..end];
}

fn extractFormName(allocator: std.mem.Allocator, body: []const u8, content_type: ?[]const u8) ![]const u8 {
    if (content_type) |ct| {
        if (std.mem.indexOf(u8, ct, "multipart/") != null) {
            return (try extractMultipartField(body, ct, "name")).data;
        }
    }
    if (std.mem.indexOf(u8, body, "name=")) |i| {
        var v = body[i + 5 ..];
        if (std.mem.indexOfScalar(u8, v, '&')) |e| v = v[0..e];
        return urlx.percentDecode(allocator, v);
    }
    return error.MissingName;
}
