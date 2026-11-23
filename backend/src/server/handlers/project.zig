const std = @import("std");
const httpz = @import("httpz");
const dust = @import("../../project/dust.zig");
const catalog = @import("../../catalog/catalog.zig");
const git = @import("../../common/git.zig");
const fsx = @import("../../common/fsx.zig");
const jsonx = @import("../../common/jsonx.zig");
const respond = @import("../respond.zig");
const server = @import("../server.zig");

const App = server.App;
const log = std.log.scoped(.server);

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

/// GET /api/v1/projects
pub fn list(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const projects = dust.getProjects(res.arena, app.cfg.dust_code) catch {
        try respond.err(res, .internal_server_error, "failed loading projects");
        return;
    };

    var out: std.Io.Writer.Allocating = .init(res.arena);
    var j: std.json.Stringify = .{ .writer = &out.writer, .options = jsonx.omit_null };
    try j.beginObject();
    try j.objectField("projects");
    try j.beginArray();
    for (projects) |p| {
        const managed = p.isManaged();
        const version = if (managed) git.shortHead(res.arena, app.io, p.root) catch "" else "";
        const url = try std.fmt.allocPrint(res.arena, "/api/v1/project/{s}", .{p.name});
        try j.beginObject();
        try j.objectField("project_name");
        try j.write(p.name);
        try j.objectField("managed");
        try j.write(managed);
        try j.objectField("version");
        try j.write(version);
        try j.objectField("url");
        try j.write(url);
        if (dust.readMeta(res.arena, p.root)) |parsed| {
            try j.objectField("meta_data");
            try j.write(metaBody(parsed));
        }
        try j.endObject();
    }
    try j.endArray();
    try j.objectField("url");
    try j.write(req.url.raw);
    try j.endObject();
    respond.jsonBody(res, .ok, out.written());
}

/// GET /api/v1/project/:name — detail or ?update
pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing project name");
        return;
    };
    const projects = dust.getProjects(res.arena, app.cfg.dust_code) catch {
        try respond.err(res, .internal_server_error, "failed loading projects");
        return;
    };
    const p = dust.searchProjects(projects, name);
    if (p == null) {
        const msg = try std.fmt.allocPrint(res.arena, "unknown project: {s}", .{name});
        try respond.err(res, .not_found, msg);
        return;
    }

    const qs = try req.query();
    if (qs.get("update") != null) {
        if (p.?.isManaged()) {
            app.refreshCache();
            app.cache.lock(app.io);
            const entry_copy: ?catalog.Entry = if (app.cache.findEntry(p.?.name)) |e| try e.clone(res.arena) else null;
            app.cache.unlock(app.io);

            const pulled = git.pull(res.arena, app.io, p.?.root) catch |e| {
                const msg = try std.fmt.allocPrint(res.arena, "update failed: {s}", .{@errorName(e)});
                try respond.err(res, .internal_server_error, msg);
                return;
            };
            switch (pulled) {
                .failed => |msg| {
                    const text = try std.fmt.allocPrint(res.arena, "update failed: {s}", .{msg});
                    try respond.err(res, .internal_server_error, text);
                    return;
                },
                .updated => {
                    dust.noteUpdated(res.arena, app.io, p.?.root, entry_copy) catch |e| {
                        log.warn("metadata update failed: {s}", .{@errorName(e)});
                    };
                    try respond.value(res, .ok, .{ .name = p.?.name, .updated = true });
                    return;
                },
                .up_to_date => {
                    try respond.value(res, .ok, .{ .name = p.?.name, .updated = false });
                    return;
                },
            }
        }

        app.refreshCache();
        app.cache.lock(app.io);
        const entry_copy: ?catalog.Entry = if (app.cache.findEntry(p.?.name)) |e| try e.clone(res.arena) else null;
        app.cache.unlock(app.io);
        const entry = entry_copy orelse {
            try respond.err(res, .not_found, "cannot find in catalog");
            return;
        };
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        dust.replaceProject(res.arena, app.io, app.cfg.dust_code, p.?.name, entry.project_url, entry, &detail) catch |e| {
            const why = if (detail.items.len > 0) detail.items else @errorName(e);
            const msg = try std.fmt.allocPrint(res.arena, "update failed: {s}", .{why});
            try respond.err(res, .internal_server_error, msg);
            return;
        };
        try respond.value(res, .ok, .{ .name = p.?.name, .updated = true });
        return;
    }

    const managed = p.?.isManaged();
    const version = if (managed) git.shortHead(res.arena, app.io, p.?.root) catch "" else "";
    const url = try std.fmt.allocPrint(res.arena, "/api/v1/project/{s}", .{p.?.name});
    if (dust.readMeta(res.arena, p.?.root)) |parsed| {
        try respond.value(res, .ok, .{
            .project_name = p.?.name,
            .managed = managed,
            .version = version,
            .url = url,
            .meta_data = metaBody(parsed),
        });
    } else {
        try respond.value(res, .ok, .{
            .project_name = p.?.name,
            .managed = managed,
            .version = version,
            .url = url,
        });
    }
}

/// DELETE /api/v1/project/:name
pub fn delete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing project name");
        return;
    };
    const projects = dust.getProjects(res.arena, app.cfg.dust_code) catch {
        try respond.err(res, .internal_server_error, "failed loading projects");
        return;
    };
    const p = dust.searchProjects(projects, name);
    if (p == null) {
        const msg = try std.fmt.allocPrint(res.arena, "unknown project: {s}", .{name});
        try respond.err(res, .not_found, msg);
        return;
    }
    fsx.deleteTree(p.?.root) catch |e| {
        try respond.err(res, .internal_server_error, @errorName(e));
        return;
    };
    const msg = try std.fmt.allocPrint(res.arena, "removed {s}", .{name});
    try respond.msg(res, .ok, msg);
}

/// POST /api/v1/project/install?url=
pub fn install(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    // httpz already percent-decodes query values — do not decode again.
    const src_url = qs.get("url") orelse {
        try respond.err(res, .bad_request, "url query arg missing");
        return;
    };
    if (src_url.len == 0 or std.mem.eql(u8, src_url, "%")) {
        try respond.err(res, .bad_request, "invalid url: parse \"%\": invalid URL escape \"%\"");
        return;
    }

    const project_name = dust.inferProjectNameFromURL(src_url);
    const entry = catalog.Entry{ .project_name = project_name };
    var detail: std.ArrayListUnmanaged(u8) = .empty;
    dust.install(res.arena, app.io, app.cfg.dust_code, project_name, src_url, entry, &detail) catch |e| {
        const why = if (detail.items.len > 0) detail.items else @errorName(e);
        const msg = try std.fmt.allocPrint(res.arena, "install failed: {s}", .{why});
        try respond.err(res, .internal_server_error, msg);
        return;
    };
    const url = try std.fmt.allocPrint(res.arena, "/api/v1/project/{s}", .{project_name});
    try respond.value(res, .created, .{ .catalog_entry = entry, .url = url });
}
