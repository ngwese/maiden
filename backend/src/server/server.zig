const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = std.Io.net;
const log = std.log.scoped(.server);
const config = @import("../common/config.zig");
const dust = @import("../project.zig");
const fsx = @import("../common/fsx.zig");
const catalog = @import("../catalog.zig");
const unit = @import("unit.zig");
const git = @import("../common/git.zig");
const jsonx = @import("../common/jsonx.zig");
const urlx = @import("../common/urlx.zig");

const max_connections: u32 = 16;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    port: u16 = 5000,
    fd: i32 = 0,
    version: []const u8,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    version: []const u8,
    port: u16,
    fd: i32,
    inflight: std.atomic.Value(u32) = .init(0),
    cache: catalog.Cache,

    fn deinit(self: *Shared) void {
        self.cache.deinit();
    }
};

/// Serve HTTP until the process exits. Listens on `opts.port`, or on `opts.fd` when it is non-zero.
pub fn run(opts: Options) !void {
    const io = opts.io;
    var shared = Shared{
        .allocator = opts.allocator,
        .io = io,
        .cfg = opts.cfg,
        .version = opts.version,
        .port = opts.port,
        .fd = opts.fd,
        .cache = .{ .allocator = opts.allocator },
    };
    defer shared.deinit();

    const http_location = if (opts.fd > 0)
        try std.fmt.allocPrint(opts.allocator, "fd {d}", .{opts.fd})
    else
        try std.fmt.allocPrint(opts.allocator, "port {d}", .{opts.port});
    defer opts.allocator.free(http_location);

    log.info("maiden: {s}", .{opts.version});
    log.info("  http: {s}", .{http_location});
    log.info("   app: {s}", .{opts.cfg.web_path});
    log.info("  data: {s}", .{opts.cfg.dust_path});
    log.info("   doc: {s}", .{opts.cfg.doc_path});

    var server: net.Server = undefined;
    if (opts.fd > 0) {
        fsx.setCloexec(opts.fd);
        server = .{
            .socket = .{
                .handle = opts.fd,
                .address = try net.IpAddress.parseIp4("0.0.0.0", 0),
            },
            .options = {},
        };
    } else {
        const addr = try net.IpAddress.parseIp4("0.0.0.0", opts.port);
        server = try addr.listen(io, .{ .reuse_address = true });
        fsx.setCloexec(server.socket.handle);
    }
    defer if (opts.fd == 0) server.deinit(io);

    shared.cache.lock(io);
    _ = shared.cache.refresh(shared.cfg) catch |err| blk: {
        log.warn("initial catalog load: {s}", .{@errorName(err)});
        break :blk false;
    };
    shared.cache.unlock(io);

    const bg = try io.concurrent(backgroundCatalogUpdate, .{&shared});
    defer bg.cancel(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("accept failed: {s}", .{@errorName(err)});
            io.sleep(Io.Duration.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        fsx.setCloexec(stream.socket.handle);
        group.concurrent(io, handleConnection, .{ &shared, stream }) catch {
            var s = stream;
            s.close(io);
        };
    }
}

fn backgroundCatalogUpdate(shared: *Shared) void {
    const io = shared.io;
    io.sleep(Io.Duration.fromSeconds(15), .awake) catch {};
    var attempts: usize = 5;
    while (attempts > 0) {
        log.debug("attempting to update catalogs", .{});
        catalog.updateConfiguredCatalogs(shared.allocator, io, shared.cfg) catch |err| {
            log.debug("catalog update error: {s}", .{@errorName(err)});
        };
        shared.cache.lock(io);
        const changed = shared.cache.refresh(shared.cfg) catch false;
        shared.cache.unlock(io);
        if (changed) {
            log.debug("catalogs updated", .{});
            break;
        }
        attempts -= 1;
        log.debug("catalog update, no change, sleeping, {d} more attempts", .{attempts});
        io.sleep(Io.Duration.fromSeconds(60), .awake) catch {};
    }
}

const Ctx = struct {
    shared: *Shared,
    io: Io,
    arena: std.mem.Allocator,
};

fn handleConnection(shared: *Shared, stream: net.Stream) void {
    const io = shared.io;
    const n = shared.inflight.fetchAdd(1, .monotonic);
    defer _ = shared.inflight.fetchSub(1, .monotonic);
    if (n >= max_connections) {
        log.warn("refusing connection; {d} already in flight", .{n});
        var s = stream;
        s.close(io);
        return;
    }

    defer {
        var s = stream;
        s.close(io);
    }

    var arena_state = std.heap.ArenaAllocator.init(shared.allocator);
    defer arena_state.deinit();

    var send_buffer: [8192]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var http_server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        defer _ = arena_state.reset(.{ .retain_with_limit = 256 * 1024 });
        const ctx = Ctx{ .shared = shared, .io = io, .arena = arena_state.allocator() };

        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.debug("receiveHead: {s}", .{@errorName(err)});
                return;
            },
        };
        serveRequest(&ctx, &request) catch |err| {
            log.err("serve '{s}': {s}", .{ request.head.target, @errorName(err) });
            respondErr(&request, ctx.arena, .internal_server_error, @errorName(err)) catch return;
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn serveRequest(ctx: *const Ctx, request: *http.Server.Request) !void {
    const method = request.head.method;
    const target = request.head.target;
    const path = pathOnly(target);
    const query = queryOnly(target);

    log.debug("{s} {s}", .{ @tagName(method), path });

    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ""))) {
        try respond(request, .found, "", &.{
            .{ .name = "Location", .value = "/maiden/" },
        });
        return;
    }

    if (std.mem.eql(u8, path, "/maiden")) {
        try respond(request, .found, "", &.{
            .{ .name = "Location", .value = "/maiden/" },
        });
        return;
    }

    if (std.mem.startsWith(u8, path, "/maiden")) {
        try serveStatic(ctx, request, ctx.shared.cfg.web_path, "/maiden", path);
        return;
    }
    if (std.mem.startsWith(u8, path, "/doc")) {
        try serveStatic(ctx, request, ctx.shared.cfg.doc_path, "/doc", path);
        return;
    }

    if (std.mem.eql(u8, path, "/api/v1") or std.mem.eql(u8, path, "/api/v1/")) {
        if (method == .GET) {
            try respondValue(request, ctx.arena, .ok, .{ .api = "maiden", .version = ctx.shared.version });
            return;
        }
    }

    if (std.mem.startsWith(u8, path, "/api/v1/dust")) {
        try handleDust(ctx, request, method, path, query);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/unit/")) {
        try handleUnit(ctx, request, method, path, query);
        return;
    }
    if (std.mem.eql(u8, path, "/api/v1/catalogs")) {
        try handleCatalogs(ctx, request, method, target);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/catalog/")) {
        try handleCatalog(ctx, request, method, path, target);
        return;
    }
    if (std.mem.eql(u8, path, "/api/v1/projects")) {
        try handleProjects(ctx, request, method, target);
        return;
    }
    if (std.mem.eql(u8, path, "/api/v1/project/install")) {
        try handleProjectInstall(ctx, request, method, query);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/v1/project/")) {
        try handleProject(ctx, request, method, path, query);
        return;
    }

    try respondErr(request, ctx.arena, .not_found, "not found");
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

fn queryOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[i + 1 ..];
    return "";
}

fn queryGet(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        } else if (std.mem.eql(u8, pair, key)) {
            return "";
        }
    }
    return null;
}

fn respond(request: *http.Server.Request, status: http.Status, body: []const u8, headers: []const http.Header) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers,
    });
}

fn respondJson(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try respondJsonWithHeaders(request, status, body, &.{});
}

fn respondJsonWithHeaders(
    request: *http.Server.Request,
    status: http.Status,
    body: []const u8,
    extra: []const http.Header,
) !void {
    var headers: [8]http.Header = undefined;
    headers[0] = .{ .name = "Content-Type", .value = "application/json; charset=utf-8" };
    headers[1] = .{ .name = "Cache-Control", .value = "no-store" };
    @memcpy(headers[2..][0..extra.len], extra);
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers[0 .. 2 + extra.len],
    });
}

fn respondValue(request: *http.Server.Request, arena: std.mem.Allocator, status: http.Status, value: anytype) !void {
    const body = try jsonx.stringifyOmitNull(arena, value);
    try respondJson(request, status, body);
}

fn respondValueWithHeaders(
    request: *http.Server.Request,
    arena: std.mem.Allocator,
    status: http.Status,
    value: anytype,
    extra: []const http.Header,
) !void {
    const body = try jsonx.stringifyOmitNull(arena, value);
    try respondJsonWithHeaders(request, status, body, extra);
}

fn respondErr(request: *http.Server.Request, arena: std.mem.Allocator, status: http.Status, message: []const u8) !void {
    try respondValue(request, arena, status, .{ .@"error" = message });
}

fn respondMsg(request: *http.Server.Request, arena: std.mem.Allocator, status: http.Status, message: []const u8) !void {
    try respondValue(request, arena, status, .{ .message = message });
}

const http_date_len = "Sun, 06 Nov 1994 08:49:37 GMT".len;

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn formatHttpDate(buf: *[http_date_len]u8, secs: i64) []const u8 {
    const epoch = std.time.epoch;
    const unsigned: u64 = if (secs < 0) 0 else @intCast(secs);
    const es = epoch.EpochSeconds{ .secs = unsigned };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    // 1970-01-01 was Thursday; weekday_names[0] is Sunday.
    const weekday = @as(usize, @intCast((ed.day + 4) % 7));
    const month = @as(usize, @intCast(md.month.numeric() - 1));
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekday_names[weekday],
        md.day_index + 1,
        month_names[month],
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

fn formatHttpDateFromStat(buf: *[http_date_len]u8, st: std.Io.File.Stat) []const u8 {
    return formatHttpDate(buf, st.mtime.toSeconds());
}

fn parseMonthName(name: []const u8) ?u4 {
    for (month_names, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, name)) return @intCast(i + 1);
    }
    return null;
}

/// Parse IMF-fix HTTP-date (`Sun, 06 Nov 1994 08:49:37 GMT`) to Unix seconds.
fn parseHttpDate(value: []const u8) ?i64 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len < http_date_len) return null;
    // Skip weekday and comma+space: "Sun, "
    if (v.len < 5 or v[3] != ',' or v[4] != ' ') return null;
    const day = std.fmt.parseInt(u8, v[5..7], 10) catch return null;
    if (v[7] != ' ') return null;
    const month = parseMonthName(v[8..11]) orelse return null;
    if (v[11] != ' ') return null;
    const year = std.fmt.parseInt(u16, v[12..16], 10) catch return null;
    if (v[16] != ' ') return null;
    const hour = std.fmt.parseInt(u8, v[17..19], 10) catch return null;
    if (v[19] != ':') return null;
    const minute = std.fmt.parseInt(u8, v[20..22], 10) catch return null;
    if (v[22] != ':') return null;
    const second = std.fmt.parseInt(u8, v[23..25], 10) catch return null;
    // Require an exact IMF-fixix date. fetch() joins duplicate headers with ", ",
    // and HTTP-dates themselves contain commas — rejecting trailing junk avoids
    // treating the first of two joined dates as authoritative.
    if (v.len != http_date_len or !std.ascii.eqlIgnoreCase(v[25..29], " GMT")) return null;
    if (day == 0 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;

    const epoch = std.time.epoch;
    if (year < epoch.epoch_year) return null;
    var days: u64 = 0;
    var y: epoch.Year = epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += epoch.getDaysInYear(y);
    }
    var month_i: u4 = 1;
    while (month_i < month) : (month_i += 1) {
        days += epoch.getDaysInMonth(year, @enumFromInt(month_i));
    }
    if (day == 0 or day > epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    days += day - 1;
    return @intCast(days * epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second);
}

fn findRequestHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// True when an existing resource is newer than `If-Unmodified-Since` (precondition failed).
fn ifUnmodifiedSinceFailed(request: *http.Server.Request, abs: []const u8) bool {
    const raw = findRequestHeader(request, "If-Unmodified-Since") orelse return false;
    const since = parseHttpDate(raw) orelse return false;
    const st = fsx.statFile(abs) catch return false;
    return st.mtime.toSeconds() > since;
}

fn serveStatic(ctx: *const Ctx, request: *http.Server.Request, root: []const u8, prefix: []const u8, path: []const u8) !void {
    var rel = path[prefix.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) rel = "index.html";
    rel = fsx.relativeInside(rel) catch {
        try respondErr(request, ctx.arena, .not_found, "not found");
        return;
    };
    if (rel.len == 0) rel = "index.html";

    const full = try std.fs.path.join(ctx.arena, &.{ root, rel });
    if (fsx.statFile(full)) |st| {
        if (st.kind == .directory) {
            const index = try std.fs.path.join(ctx.arena, &.{ full, "index.html" });
            try sendPath(request, ctx.arena, index, false);
            return;
        }
    } else |_| {}
    try sendPath(request, ctx.arena, full, false);
}

fn sendPath(request: *http.Server.Request, arena: std.mem.Allocator, path: []const u8, sniff: bool) !void {
    const file = fsx.openFile(path) catch {
        try respondErr(request, arena, .not_found, "not found");
        return;
    };
    defer fsx.closeFile(file);
    const ctype = contentType(file, path, sniff);
    try respondSendFile(request, file, ctype);
}

fn respondSendFile(request: *http.Server.Request, file: std.Io.File, content_type: []const u8) !void {
    const st = try file.stat(fsx.io);
    var lm_buf: [http_date_len]u8 = undefined;
    const last_modified = formatHttpDateFromStat(&lm_buf, st);
    var body_buf: [4096]u8 = undefined;
    var body = try request.respondStreaming(&body_buf, .{
        .content_length = st.size,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "Last-Modified", .value = last_modified },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        },
    });
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(fsx.io, &read_buf);
    _ = try body.writer.sendFileAll(&reader, .unlimited);
    try body.end();
}

fn contentType(file: std.Io.File, path: []const u8, sniff: bool) []const u8 {
    if (extType(path)) |t| return t;
    if (!sniff) return "application/octet-stream";
    var buf: [512]u8 = undefined;
    const n = file.readPositionalAll(fsx.io, &buf, 0) catch 0;
    if (looksLikeText(buf[0..n])) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

fn extType(path: []const u8) ?[]const u8 {
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

fn handleDust(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, path: []const u8, query: []const u8) !void {
    const name = if (path.len > "/api/v1/dust".len) path["/api/v1/dust".len..] else "";
    const abs = dust.devicePath(ctx.arena, ctx.shared.cfg.dust_path, name) catch |err| switch (err) {
        error.BadPath => {
            try respondErr(request, ctx.arena, .bad_request, "invalid path");
            return;
        },
        else => return err,
    };

    if (method == .GET or method == .HEAD) {
        if (name.len == 0 or std.mem.eql(u8, name, "/")) {
            const st = fsx.statFile(abs) catch {
                try respondErr(request, ctx.arena, .not_found, "file does not exist");
                return;
            };
            const entries = dust.listDir(ctx.arena, abs, "/api/v1/dust") catch |err| {
                try respondErr(request, ctx.arena, .bad_request, @errorName(err));
                return;
            };
            const body = try formatDirListing(ctx.arena, "", "/api/v1/dust", entries);
            var lm_buf: [http_date_len]u8 = undefined;
            const last_modified = formatHttpDateFromStat(&lm_buf, st);
            try respondJsonWithHeaders(request, .ok, body, &.{
                .{ .name = "Last-Modified", .value = last_modified },
            });
            return;
        }

        const st = fsx.statFile(abs) catch {
            try respondErr(request, ctx.arena, .not_found, "file does not exist");
            return;
        };

        if (st.kind == .directory) {
            var n = name;
            if (n.len > 0 and n[0] == '/') n = n[1..];
            const prefix = try std.fmt.allocPrint(ctx.arena, "/api/v1/dust/{s}", .{n});
            const entries = try dust.listDir(ctx.arena, abs, prefix);
            const body = try formatDirListing(ctx.arena, n, prefix, entries);
            var lm_buf: [http_date_len]u8 = undefined;
            const last_modified = formatHttpDateFromStat(&lm_buf, st);
            try respondJsonWithHeaders(request, .ok, body, &.{
                .{ .name = "Last-Modified", .value = last_modified },
            });
            return;
        }

        try sendPath(request, ctx.arena, abs, true);
        return;
    }

    if (method == .PUT) {
        if (queryGet(query, "kind")) |kind| {
            if (std.mem.eql(u8, kind, "directory")) {
                fsx.makePath(abs) catch |err| {
                    try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
                    return;
                };
                fsx.syncParent(abs);
                const text = try std.fmt.allocPrint(ctx.arena, "created directory {s}", .{abs});
                try respondMsg(request, ctx.arena, .ok, text);
                return;
            }
        }

        if (ifUnmodifiedSinceFailed(request, abs)) {
            try respondErr(request, ctx.arena, .precondition_failed, "file has been modified");
            return;
        }

        // content_type points into the receive buffer. Reading the body
        // reuses that buffer, so copy it before the read or the boundary is lost.
        const content_type = if (request.head.content_type) |ct| try ctx.arena.dupe(u8, ct) else null;
        if (std.fs.path.dirname(abs)) |dir| {
            fsx.makePath(dir) catch |err| {
                try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
                return;
            };
        }

        // Write to a sibling first so a full disk does not truncate the live script.
        const tmp = try std.fmt.allocPrint(ctx.arena, "{s}.maiden-save-{d}", .{ abs, save_seq.fetchAdd(1, .monotonic) });
        var committed = false;
        defer if (!committed) fsx.deleteFile(tmp) catch {};

        const file = fsx.createFile(tmp) catch |err| {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        };
        defer fsx.closeFile(file);

        var body_buf: [8192]u8 = undefined;
        const reader = request.readerExpectContinue(&body_buf) catch |err| {
            try respondErr(request, ctx.arena, .bad_request, @errorName(err));
            return;
        };
        const saved = streamMultipartValue(ctx.arena, reader, content_type, file) catch |err| switch (err) {
            error.NoMultipart, error.FieldNotFound => {
                try respondErr(request, ctx.arena, .bad_request, "http: no such file");
                return;
            },
            else => {
                try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
                return;
            },
        };
        fsx.syncFile(file);
        fsx.rename(tmp, abs) catch |err| {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        };
        committed = true;
        fsx.syncParent(abs);

        const filename = if (saved.filename.len > 0) saved.filename else "value";
        const text = try std.fmt.allocPrint(ctx.arena, "uploaded {s} ({d}) to {s}", .{ filename, saved.bytes, abs });
        var lm_buf: [http_date_len]u8 = undefined;
        if (fsx.statFile(abs)) |st| {
            const last_modified = formatHttpDateFromStat(&lm_buf, st);
            try respondValueWithHeaders(request, ctx.arena, .ok, .{ .message = text }, &.{
                .{ .name = "Last-Modified", .value = last_modified },
            });
        } else |_| {
            try respondMsg(request, ctx.arena, .ok, text);
        }
        return;
    }

    if (method == .PATCH) {
        if (!fsx.accessExists(abs)) {
            try respondErr(request, ctx.arena, .not_found, "file does not exist");
            return;
        }
        const content_type = if (request.head.content_type) |ct| try ctx.arena.dupe(u8, ct) else null;
        const body_bytes = try readBody(ctx, request, 64 * 1024);
        const new_name = extractFormName(ctx.arena, body_bytes, content_type) catch {
            try respondErr(request, ctx.arena, .bad_request, "missing 'name' key in form");
            return;
        };

        var n = name;
        if (n.len > 0 and n[0] == '/') n = n[1..];
        const parent = std.fs.path.dirname(n) orelse "";
        const rename_rel = if (parent.len > 0)
            try std.fs.path.join(ctx.arena, &.{ parent, new_name })
        else
            new_name;
        const rename_abs = dust.devicePath(ctx.arena, ctx.shared.cfg.dust_path, rename_rel) catch |err| switch (err) {
            error.BadPath => {
                try respondErr(request, ctx.arena, .bad_request, "invalid path");
                return;
            },
            else => return err,
        };

        fsx.rename(abs, rename_abs) catch |err| {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        };
        fsx.syncParent(rename_abs);

        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, rename_rel, '/');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            try parts.append(ctx.arena, part);
        }
        const url = try dust.resourcePath(ctx.arena, "/api/v1/dust", parts.items);
        try respondValue(request, ctx.arena, .ok, .{ .url = url });
        return;
    }

    if (method == .DELETE) {
        if (!fsx.accessExists(abs)) {
            try respondErr(request, ctx.arena, .not_found, "file does not exist");
            return;
        }
        fsx.deleteTree(abs) catch |err| {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        };
        const text = try std.fmt.allocPrint(ctx.arena, "deleted {s}", .{abs});
        try respondMsg(request, ctx.arena, .ok, text);
        return;
    }

    try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
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

fn readBody(ctx: *const Ctx, request: *http.Server.Request, limit: usize) ![]u8 {
    var buf: [8192]u8 = undefined;
    const reader = try request.readerExpectContinue(&buf);
    return try reader.allocRemaining(ctx.arena, .limited(limit));
}

var save_seq: std.atomic.Value(u32) = .init(0);

const SavedPart = struct {
    filename: []const u8,
    bytes: u64,
};

/// Stream the multipart part named "value" onto `file`. The request body is not buffered.
fn streamMultipartValue(allocator: std.mem.Allocator, reader: *std.Io.Reader, content_type: ?[]const u8, file: std.Io.File) !SavedPart {
    const ct = content_type orelse return error.NoMultipart;
    const boundary = multipartBoundary(ct) orelse return error.NoMultipart;
    var marker_buf: [208]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "--{s}", .{boundary}) catch return error.NoMultipart;
    var delim_buf: [212]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n{s}", .{marker}) catch return error.NoMultipart;

    var scan = MultipartScan{ .reader = reader };
    defer _ = scan.reader.discardRemaining() catch {};

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
    reader: *std.Io.Reader,
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
        const n = self.reader.readSliceShort(self.buf[self.end..]) catch |err| return err;
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
    out.interface.writeAll(data) catch |err| switch (err) {
        error.WriteFailed => {
            if (out.write_file_err) |file_err| return file_err;
            if (out.err) |file_err| return file_err;
            return err;
        },
    };
}

fn flushFileWriter(out: *std.Io.File.Writer) !void {
    out.interface.flush() catch |err| switch (err) {
        error.WriteFailed => {
            if (out.write_file_err) |file_err| return file_err;
            if (out.err) |file_err| return file_err;
            return err;
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

fn handleUnit(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, path: []const u8, query: []const u8) !void {
    if (method != .GET) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }
    const name = path["/api/v1/unit/".len..];
    if (queryGet(query, "do")) |op| {
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        unit.doOperation(ctx.arena, ctx.io, name, op, &detail) catch |err| switch (err) {
            error.NoDbusConnection => {
                try respondErr(request, ctx.arena, .service_unavailable, "no dbus connection");
                return;
            },
            error.UnrecognizedOperation => {
                try respondErr(request, ctx.arena, .bad_request, "unrecognized operation");
                return;
            },
            else => {
                const msg = if (detail.items.len > 0) detail.items else @errorName(err);
                try respondErr(request, ctx.arena, .internal_server_error, msg);
                return;
            },
        };
        try respondValue(request, ctx.arena, .ok, .{ .job_id = @as(i32, 0), .result = "done" });
        return;
    }

    const status = unit.getStatus(ctx.arena, ctx.io, name) catch |err| switch (err) {
        error.NoDbusConnection => {
            try respondErr(request, ctx.arena, .service_unavailable, "no dbus connection");
            return;
        },
        error.UnitNotFound => {
            const msg = try std.fmt.allocPrint(ctx.arena, "unknown unit: {s}", .{name});
            try respondErr(request, ctx.arena, .not_found, msg);
            return;
        },
        else => {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        },
    };
    try respondValue(request, ctx.arena, .ok, .{ .state = status.state, .sub_state = status.sub_state });
}

fn refreshCache(ctx: *const Ctx) void {
    ctx.shared.cache.lock(ctx.io);
    defer ctx.shared.cache.unlock(ctx.io);
    _ = ctx.shared.cache.refresh(ctx.shared.cfg) catch |err| blk: {
        log.warn("catalog refresh: {s}", .{@errorName(err)});
        break :blk false;
    };
}

fn handleCatalogs(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, target: []const u8) !void {
    if (method != .GET) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }
    refreshCache(ctx);
    const sources = catalog.loadSources(ctx.arena, ctx.shared.cfg) catch try ctx.arena.alloc(catalog.Source, 0);

    var cache_held = true;
    ctx.shared.cache.lock(ctx.io);
    errdefer if (cache_held) ctx.shared.cache.unlock(ctx.io);

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var j: std.json.Stringify = .{ .writer = &out.writer };
    try j.beginObject();
    try j.objectField("catalogs");
    try j.beginArray();
    for (ctx.shared.cache.items.items) |*c| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(c.name());
        try j.objectField("date");
        try j.write(c.dateText());
        try j.objectField("url");
        const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/catalog/{s}", .{c.name()});
        try j.write(url);
        try j.endObject();
    }
    for (sources) |s| {
        var exists = false;
        for (ctx.shared.cache.items.items) |*c| {
            if (std.mem.eql(u8, c.name(), s.name())) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        try j.beginObject();
        try j.objectField("name");
        try j.write(s.name());
        try j.objectField("date");
        try j.write("0001-01-01T00:00:00Z");
        try j.objectField("url");
        const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/catalog/{s}", .{s.name()});
        try j.write(url);
        try j.endObject();
    }
    try j.endArray();
    try j.objectField("url");
    try j.write(target);
    try j.endObject();
    const body = try out.toOwnedSlice();
    ctx.shared.cache.unlock(ctx.io);
    cache_held = false;
    try respondJson(request, .ok, body);
}

fn handleCatalog(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, path: []const u8, target: []const u8) !void {
    const rest = path["/api/v1/catalog/".len..];

    if (std.mem.indexOf(u8, rest, "/install/")) |i| {
        if (method != .POST) {
            try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
            return;
        }
        const cat_name = rest[0..i];
        const project = rest[i + "/install/".len ..];
        refreshCache(ctx);
        ctx.shared.cache.lock(ctx.io);
        const found = ctx.shared.cache.findCatalog(cat_name);
        if (found == null) {
            ctx.shared.cache.unlock(ctx.io);
            try respondErr(request, ctx.arena, .not_found, "unable to find script catalog");
            return;
        }
        const entry = found.?.get(project);
        if (entry == null) {
            ctx.shared.cache.unlock(ctx.io);
            try respondErr(request, ctx.arena, .not_found, "cannot find in catalog");
            return;
        }
        const owned = try entry.?.clone(ctx.arena);
        ctx.shared.cache.unlock(ctx.io);

        var detail: std.ArrayListUnmanaged(u8) = .empty;
        dust.install(ctx.arena, ctx.io, ctx.shared.cfg.dust_code, owned.project_name, owned.project_url, owned, &detail) catch |err| {
            const why = if (detail.items.len > 0) detail.items else @errorName(err);
            const msg = try std.fmt.allocPrint(ctx.arena, "install failed: {s}", .{why});
            try respondErr(request, ctx.arena, .internal_server_error, msg);
            return;
        };
        const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/project/{s}", .{owned.project_name});
        try respondValue(request, ctx.arena, .created, .{ .catalog_entry = owned, .url = url });
        return;
    }

    if (std.mem.endsWith(u8, rest, "/update")) {
        if (method != .POST) {
            try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
            return;
        }
        const raw_name = rest[0 .. rest.len - "/update".len];
        const name = if (std.mem.endsWith(u8, raw_name, "/")) raw_name[0 .. raw_name.len - 1] else raw_name;

        const sources = catalog.loadSources(ctx.arena, ctx.shared.cfg) catch {
            try respondErr(request, ctx.arena, .internal_server_error, "unable to load catalog sources");
            return;
        };
        for (sources) |src| {
            if (!std.mem.eql(u8, src.name(), name)) continue;
            if (src.method().len == 0) {
                try respondErr(request, ctx.arena, .internal_server_error, "source method not specified");
                return;
            }
            if (!std.mem.eql(u8, src.method(), "download")) {
                try respondErr(request, ctx.arena, .internal_server_error, "unhandled source method");
                return;
            }
            const fname = try std.fmt.allocPrint(ctx.arena, "{s}.json", .{src.name()});
            const out_path = try std.fs.path.join(ctx.arena, &.{ ctx.shared.cfg.catalog_output_dir, fname });
            var detail: std.ArrayListUnmanaged(u8) = .empty;
            catalog.downloadToFile(ctx.arena, ctx.io, src.url(), out_path, &detail) catch {
                const why = if (detail.items.len > 0) detail.items else "download failed";
                try respondErr(request, ctx.arena, .internal_server_error, why);
                return;
            };
            break;
        }

        refreshCache(ctx);
        const updated = blk: {
            ctx.shared.cache.lock(ctx.io);
            defer ctx.shared.cache.unlock(ctx.io);
            break :blk if (ctx.shared.cache.findCatalog(name)) |c|
                try formatCatalogContent(ctx.arena, c)
            else
                null;
        };
        if (updated) |body| {
            try respondJson(request, .ok, body);
            return;
        }
        const msg = try std.fmt.allocPrint(ctx.arena, "unknown catalog: {s}", .{name});
        try respondValue(request, ctx.arena, .not_found, .{ .@"error" = msg, .name = name, .url = target });
        return;
    }

    const name = rest;
    if (method == .POST) {
        try respondErr(request, ctx.arena, .internal_server_error, "create not implemented");
        return;
    }
    if (method == .DELETE) {
        try respondErr(request, ctx.arena, .internal_server_error, "delete not implemented");
        return;
    }
    if (method != .GET) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }

    refreshCache(ctx);
    const found = blk: {
        ctx.shared.cache.lock(ctx.io);
        defer ctx.shared.cache.unlock(ctx.io);
        break :blk if (ctx.shared.cache.findCatalog(name)) |c|
            try formatCatalogContent(ctx.arena, c)
        else
            null;
    };
    if (found) |body| {
        try respondJson(request, .ok, body);
        return;
    }
    const msg = try std.fmt.allocPrint(ctx.arena, "unknown catalog: {s}", .{name});
    try respondValue(request, ctx.arena, .not_found, .{ .@"error" = msg, .name = name, .url = target });
}

fn formatCatalogContent(allocator: std.mem.Allocator, c: *const catalog.Catalog) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer };
    try j.beginObject();
    try j.objectField("name");
    try j.write(c.name());
    try j.objectField("updated");
    try j.write(c.dateText());
    try j.objectField("entries");
    try j.write(c.entries());
    try j.objectField("url");
    const url = try std.fmt.allocPrint(allocator, "/api/v1/catalog/{s}", .{c.name()});
    try j.write(url);
    try j.endObject();
    return try out.toOwnedSlice();
}

const MetaBody = struct {
    file_info: struct {
        version: u32 = 1,
        kind: []const u8 = "project_metadata",
    } = .{},
    installed_on: []const u8,
    updated_on: ?[]const u8 = null,
    project_url: []const u8,
    catalog_entry: ?catalog.Entry = null,
};

fn metaBody(parsed: std.json.Parsed(dust.MetaFile)) MetaBody {
    const md = parsed.value;
    return .{
        .installed_on = md.installed_on,
        .updated_on = if (md.updated_on.len == 0) null else md.updated_on,
        .project_url = md.project_url,
        .catalog_entry = md.catalog_entry,
    };
}

fn handleProjects(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, target: []const u8) !void {
    if (method != .GET) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }
    const projects = dust.getProjects(ctx.arena, ctx.shared.cfg.dust_code) catch {
        try respondErr(request, ctx.arena, .internal_server_error, "failed loading projects");
        return;
    };

    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var j: std.json.Stringify = .{ .writer = &out.writer, .options = jsonx.omit_null };
    try j.beginObject();
    try j.objectField("projects");
    try j.beginArray();
    for (projects) |p| {
        const managed = p.isManaged();
        const version = if (managed) git.shortHead(ctx.arena, ctx.io, p.root) catch "" else "";
        const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/project/{s}", .{p.name});
        try j.beginObject();
        try j.objectField("project_name");
        try j.write(p.name);
        try j.objectField("managed");
        try j.write(managed);
        try j.objectField("version");
        try j.write(version);
        try j.objectField("url");
        try j.write(url);
        if (dust.readMeta(ctx.arena, p.root)) |parsed| {
            try j.objectField("meta_data");
            try j.write(metaBody(parsed));
        }
        try j.endObject();
    }
    try j.endArray();
    try j.objectField("url");
    try j.write(target);
    try j.endObject();
    try respondJson(request, .ok, out.written());
}

fn handleProject(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, path: []const u8, query: []const u8) !void {
    const name = path["/api/v1/project/".len..];
    const projects = dust.getProjects(ctx.arena, ctx.shared.cfg.dust_code) catch {
        try respondErr(request, ctx.arena, .internal_server_error, "failed loading projects");
        return;
    };
    const p = dust.searchProjects(projects, name);

    if (method == .DELETE) {
        if (p == null) {
            const msg = try std.fmt.allocPrint(ctx.arena, "unknown project: {s}", .{name});
            try respondErr(request, ctx.arena, .not_found, msg);
            return;
        }
        fsx.deleteTree(p.?.root) catch |err| {
            try respondErr(request, ctx.arena, .internal_server_error, @errorName(err));
            return;
        };
        const msg = try std.fmt.allocPrint(ctx.arena, "removed {s}", .{name});
        try respondMsg(request, ctx.arena, .ok, msg);
        return;
    }
    if (method != .GET) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }
    if (p == null) {
        const msg = try std.fmt.allocPrint(ctx.arena, "unknown project: {s}", .{name});
        try respondErr(request, ctx.arena, .not_found, msg);
        return;
    }

    if (queryGet(query, "update") != null) {
        if (p.?.isManaged()) {
            refreshCache(ctx);
            ctx.shared.cache.lock(ctx.io);
            const entry_copy: ?catalog.Entry = if (ctx.shared.cache.findEntry(p.?.name)) |e| try e.clone(ctx.arena) else null;
            ctx.shared.cache.unlock(ctx.io);

            const pulled = git.pull(ctx.arena, ctx.io, p.?.root) catch |err| {
                const msg = try std.fmt.allocPrint(ctx.arena, "update failed: {s}", .{@errorName(err)});
                try respondErr(request, ctx.arena, .internal_server_error, msg);
                return;
            };
            switch (pulled) {
                .failed => |msg| {
                    const text = try std.fmt.allocPrint(ctx.arena, "update failed: {s}", .{msg});
                    try respondErr(request, ctx.arena, .internal_server_error, text);
                    return;
                },
                .updated => {
                    dust.noteUpdated(ctx.arena, ctx.io, p.?.root, entry_copy) catch |err| {
                        log.warn("metadata update failed: {s}", .{@errorName(err)});
                    };
                    try respondValue(request, ctx.arena, .ok, .{ .name = p.?.name, .updated = true });
                    return;
                },
                .up_to_date => {
                    try respondValue(request, ctx.arena, .ok, .{ .name = p.?.name, .updated = false });
                    return;
                },
            }
        }

        refreshCache(ctx);
        ctx.shared.cache.lock(ctx.io);
        const entry_copy: ?catalog.Entry = if (ctx.shared.cache.findEntry(p.?.name)) |e| try e.clone(ctx.arena) else null;
        ctx.shared.cache.unlock(ctx.io);
        const entry = entry_copy orelse {
            try respondErr(request, ctx.arena, .not_found, "cannot find in catalog");
            return;
        };
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        dust.replaceProject(ctx.arena, ctx.io, ctx.shared.cfg.dust_code, p.?.name, entry.project_url, entry, &detail) catch |err| {
            const why = if (detail.items.len > 0) detail.items else @errorName(err);
            const msg = try std.fmt.allocPrint(ctx.arena, "update failed: {s}", .{why});
            try respondErr(request, ctx.arena, .internal_server_error, msg);
            return;
        };
        try respondValue(request, ctx.arena, .ok, .{ .name = p.?.name, .updated = true });
        return;
    }

    const managed = p.?.isManaged();
    const version = if (managed) git.shortHead(ctx.arena, ctx.io, p.?.root) catch "" else "";
    const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/project/{s}", .{p.?.name});
    if (dust.readMeta(ctx.arena, p.?.root)) |parsed| {
        try respondValue(request, ctx.arena, .ok, .{
            .project_name = p.?.name,
            .managed = managed,
            .version = version,
            .url = url,
            .meta_data = metaBody(parsed),
        });
    } else {
        try respondValue(request, ctx.arena, .ok, .{
            .project_name = p.?.name,
            .managed = managed,
            .version = version,
            .url = url,
        });
    }
}

fn handleProjectInstall(ctx: *const Ctx, request: *http.Server.Request, method: http.Method, query: []const u8) !void {
    if (method != .POST) {
        try respondErr(request, ctx.arena, .method_not_allowed, "method not allowed");
        return;
    }
    const url_enc = queryGet(query, "url") orelse {
        try respondErr(request, ctx.arena, .bad_request, "url query arg missing");
        return;
    };
    const src_url = urlx.percentDecode(ctx.arena, url_enc) catch {
        try respondErr(request, ctx.arena, .bad_request, "invalid url: parse error");
        return;
    };
    if (src_url.len == 0 or std.mem.eql(u8, src_url, "%")) {
        try respondErr(request, ctx.arena, .bad_request, "invalid url: parse \"%\": invalid URL escape \"%\"");
        return;
    }

    const project_name = dust.inferProjectNameFromURL(src_url);
    const entry = catalog.Entry{ .project_name = project_name };
    var detail: std.ArrayListUnmanaged(u8) = .empty;
    dust.install(ctx.arena, ctx.io, ctx.shared.cfg.dust_code, project_name, src_url, entry, &detail) catch |err| {
        const why = if (detail.items.len > 0) detail.items else @errorName(err);
        const msg = try std.fmt.allocPrint(ctx.arena, "install failed: {s}", .{why});
        try respondErr(request, ctx.arena, .internal_server_error, msg);
        return;
    };
    const url = try std.fmt.allocPrint(ctx.arena, "/api/v1/project/{s}", .{project_name});
    try respondValue(request, ctx.arena, .created, .{ .catalog_entry = entry, .url = url });
}
