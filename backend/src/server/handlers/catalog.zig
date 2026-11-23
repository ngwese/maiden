const std = @import("std");
const httpz = @import("httpz");
const dust = @import("../../project/dust.zig");
const catalog = @import("../../catalog/catalog.zig");
const respond = @import("../respond.zig");
const server = @import("../server.zig");

const App = server.App;

/// GET /api/v1/catalogs
pub fn catalogs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    app.refreshCache();
    const sources = catalog.loadSources(res.arena, app.cfg) catch try res.arena.alloc(catalog.Source, 0);

    var cache_held = true;
    app.cache.lock(app.io);
    errdefer if (cache_held) app.cache.unlock(app.io);

    var out: std.Io.Writer.Allocating = .init(res.arena);
    var j: std.json.Stringify = .{ .writer = &out.writer };
    try j.beginObject();
    try j.objectField("catalogs");
    try j.beginArray();
    for (app.cache.items.items) |*c| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(c.name());
        try j.objectField("date");
        try j.write(c.dateText());
        try j.objectField("url");
        const url = try std.fmt.allocPrint(res.arena, "/api/v1/catalog/{s}", .{c.name()});
        try j.write(url);
        try j.endObject();
    }
    for (sources) |s| {
        var exists = false;
        for (app.cache.items.items) |*c| {
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
        const url = try std.fmt.allocPrint(res.arena, "/api/v1/catalog/{s}", .{s.name()});
        try j.write(url);
        try j.endObject();
    }
    try j.endArray();
    try j.objectField("url");
    try j.write(req.url.raw);
    try j.endObject();
    const body = try out.toOwnedSlice();
    app.cache.unlock(app.io);
    cache_held = false;
    respond.jsonBody(res, .ok, body);
}

/// GET /api/v1/catalog/:name
pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing catalog name");
        return;
    };
    app.refreshCache();
    const found = blk: {
        app.cache.lock(app.io);
        defer app.cache.unlock(app.io);
        break :blk if (app.cache.findCatalog(name)) |c|
            try formatCatalogContent(res.arena, c)
        else
            null;
    };
    if (found) |body| {
        respond.jsonBody(res, .ok, body);
        return;
    }
    const msg = try std.fmt.allocPrint(res.arena, "unknown catalog: {s}", .{name});
    try respond.value(res, .not_found, .{ .@"error" = msg, .name = name, .url = req.url.raw });
}

/// POST /api/v1/catalog/:name — create not implemented.
pub fn create(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try respond.err(res, .internal_server_error, "create not implemented");
}

/// DELETE /api/v1/catalog/:name — delete not implemented.
pub fn remove(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try respond.err(res, .internal_server_error, "delete not implemented");
}

/// POST /api/v1/catalog/:name/update
pub fn update(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing catalog name");
        return;
    };

    const sources = catalog.loadSources(res.arena, app.cfg) catch {
        try respond.err(res, .internal_server_error, "unable to load catalog sources");
        return;
    };
    for (sources) |src| {
        if (!std.mem.eql(u8, src.name(), name)) continue;
        if (src.method().len == 0) {
            try respond.err(res, .internal_server_error, "source method not specified");
            return;
        }
        if (!std.mem.eql(u8, src.method(), "download")) {
            try respond.err(res, .internal_server_error, "unhandled source method");
            return;
        }
        const fname = try std.fmt.allocPrint(res.arena, "{s}.json", .{src.name()});
        const out_path = try std.fs.path.join(res.arena, &.{ app.cfg.catalog_output_dir, fname });
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        catalog.downloadToFile(res.arena, app.io, src.url(), out_path, &detail) catch {
            const why = if (detail.items.len > 0) detail.items else "download failed";
            try respond.err(res, .internal_server_error, why);
            return;
        };
        break;
    }

    app.refreshCache();
    const updated = blk: {
        app.cache.lock(app.io);
        defer app.cache.unlock(app.io);
        break :blk if (app.cache.findCatalog(name)) |c|
            try formatCatalogContent(res.arena, c)
        else
            null;
    };
    if (updated) |body| {
        respond.jsonBody(res, .ok, body);
        return;
    }
    const msg = try std.fmt.allocPrint(res.arena, "unknown catalog: {s}", .{name});
    try respond.value(res, .not_found, .{ .@"error" = msg, .name = name, .url = req.url.raw });
}

/// POST /api/v1/catalog/:name/install/:project
pub fn install(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const cat_name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing catalog name");
        return;
    };
    const project = req.param("project") orelse {
        try respond.err(res, .bad_request, "missing project name");
        return;
    };

    app.refreshCache();
    app.cache.lock(app.io);
    const found = app.cache.findCatalog(cat_name);
    if (found == null) {
        app.cache.unlock(app.io);
        try respond.err(res, .not_found, "unable to find script catalog");
        return;
    }
    const entry = found.?.get(project);
    if (entry == null) {
        app.cache.unlock(app.io);
        try respond.err(res, .not_found, "cannot find in catalog");
        return;
    }
    const owned = try entry.?.clone(res.arena);
    app.cache.unlock(app.io);

    var detail: std.ArrayListUnmanaged(u8) = .empty;
    dust.install(res.arena, app.io, app.cfg.dust_code, owned.project_name, owned.project_url, owned, &detail) catch |e| {
        const why = if (detail.items.len > 0) detail.items else @errorName(e);
        const msg = try std.fmt.allocPrint(res.arena, "install failed: {s}", .{why});
        try respond.err(res, .internal_server_error, msg);
        return;
    };
    const url = try std.fmt.allocPrint(res.arena, "/api/v1/project/{s}", .{owned.project_name});
    try respond.value(res, .created, .{ .catalog_entry = owned, .url = url });
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
