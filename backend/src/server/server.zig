const std = @import("std");
const httpz = @import("httpz");
const Io = std.Io;
const log = std.log.scoped(.server);
const config = @import("../common/config.zig");
const catalog = @import("../catalog.zig");
const respond = @import("respond.zig");
const static = @import("static.zig");
const handlers = @import("handlers.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    port: u16 = 5000,
    fd: i32 = 0,
    version: []const u8,
};

/// Shared application state passed to every httpz handler.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    version: []const u8,
    cache: catalog.Cache,

    pub fn deinit(self: *App) void {
        self.cache.deinit();
    }

    /// Refresh the in-memory catalog cache from disk.
    pub fn refreshCache(self: *App) void {
        self.cache.lock(self.io);
        defer self.cache.unlock(self.io);
        _ = self.cache.refresh(self.cfg) catch |err| blk: {
            log.warn("catalog refresh: {s}", .{@errorName(err)});
            break :blk false;
        };
    }

    pub fn notFound(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
        try respond.err(res, .not_found, "not found");
    }

    pub fn uncaughtError(_: *App, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        log.err("serve '{s}': {s}", .{ req.url.raw, @errorName(err) });
        respond.err(res, .internal_server_error, @errorName(err)) catch {
            res.setStatus(.internal_server_error);
            res.header("Cache-Control", "no-store");
            res.content_type = .JSON;
            res.body = "{\"error\":\"internal server error\"}";
        };
    }
};

/// Serve HTTP until the process exits. Listens on `opts.port`, or on `opts.fd` when it is non-zero.
pub fn run(opts: Options) !void {
    const io = opts.io;
    var app = App{
        .allocator = opts.allocator,
        .io = io,
        .cfg = opts.cfg,
        .version = opts.version,
        .cache = .{ .allocator = opts.allocator },
    };
    defer app.deinit();

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

    app.cache.lock(io);
    _ = app.cache.refresh(app.cfg) catch |err| blk: {
        log.warn("initial catalog load: {s}", .{@errorName(err)});
        break :blk false;
    };
    app.cache.unlock(io);

    var bg = try io.concurrent(backgroundCatalogUpdate, .{&app});
    defer bg.cancel(io);

    var http_config: httpz.Config = .{
        .address = .all(opts.port),
        .workers = .{
            .count = 1,
            .max_conn = 64,
            .min_conn = 8,
        },
        .thread_pool = .{
            .count = 4,
        },
        .request = .{
            .lazy_read_size = 64 * 1024,
            .max_multiform_count = 0,
        },
        .timeout = .{
            .keepalive = 75,
        },
    };
    if (opts.fd > 0) {
        http_config.listen_fd = opts.fd;
    }

    var server = try httpz.Server(*App).init(io, opts.allocator, http_config, &app);
    defer server.deinit();

    const router = try server.router(.{});
    registerRoutes(router);

    try server.listen();
}

fn backgroundCatalogUpdate(app: *App) void {
    const io = app.io;
    io.sleep(Io.Duration.fromSeconds(15), .awake) catch {};
    var attempts: usize = 5;
    while (attempts > 0) {
        log.debug("attempting to update catalogs", .{});
        catalog.updateConfiguredCatalogs(app.allocator, io, app.cfg) catch |err| {
            log.debug("catalog update error: {s}", .{@errorName(err)});
        };
        app.cache.lock(io);
        const changed = app.cache.refresh(app.cfg) catch false;
        app.cache.unlock(io);
        if (changed) {
            log.debug("catalogs updated", .{});
            break;
        }
        attempts -= 1;
        log.debug("catalog update, no change, sleeping, {d} more attempts", .{attempts});
        io.sleep(Io.Duration.fromSeconds(60), .awake) catch {};
    }
}

fn methodNotAllowed(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try respond.err(res, .method_not_allowed, "method not allowed");
}

fn apiVersion(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try respond.value(res, .ok, .{ .api = "maiden", .version = app.version });
}

fn registerRoutes(router: anytype) void {
    // Root redirect
    router.all("/", methodNotAllowed, .{});
    router.get("/", static.redirectRoot, .{});

    // Static app UI — exact /maiden redirects inside the handler
    router.all("/maiden", methodNotAllowed, .{});
    router.all("/maiden/*", methodNotAllowed, .{});
    router.get("/maiden", static.maiden, .{});
    router.get("/maiden/*", static.maiden, .{});

    // Docs
    router.all("/doc", methodNotAllowed, .{});
    router.all("/doc/*", methodNotAllowed, .{});
    router.get("/doc", static.doc, .{});
    router.get("/doc/*", static.doc, .{});

    // API version
    router.all("/api/v1", methodNotAllowed, .{});
    router.get("/api/v1", apiVersion, .{});

    // Dust
    router.all("/api/v1/dust", methodNotAllowed, .{});
    router.all("/api/v1/dust/*", methodNotAllowed, .{});
    router.get("/api/v1/dust", handlers.dust.get, .{});
    router.get("/api/v1/dust/*", handlers.dust.get, .{});
    router.head("/api/v1/dust", handlers.dust.get, .{});
    router.head("/api/v1/dust/*", handlers.dust.get, .{});
    router.put("/api/v1/dust", handlers.dust.put, .{});
    router.put("/api/v1/dust/*", handlers.dust.put, .{});
    router.patch("/api/v1/dust", handlers.dust.patch, .{});
    router.patch("/api/v1/dust/*", handlers.dust.patch, .{});
    router.delete("/api/v1/dust", handlers.dust.delete, .{});
    router.delete("/api/v1/dust/*", handlers.dust.delete, .{});

    // Units
    router.all("/api/v1/unit/:name", methodNotAllowed, .{});
    router.get("/api/v1/unit/:name", handlers.unit.get, .{});

    // Catalogs list
    router.all("/api/v1/catalogs", methodNotAllowed, .{});
    router.get("/api/v1/catalogs", handlers.catalog.catalogs, .{});

    // Catalog by name
    router.all("/api/v1/catalog/:name", methodNotAllowed, .{});
    router.get("/api/v1/catalog/:name", handlers.catalog.get, .{});
    router.post("/api/v1/catalog/:name", handlers.catalog.create, .{});
    router.delete("/api/v1/catalog/:name", handlers.catalog.remove, .{});

    // Catalog update / install
    router.all("/api/v1/catalog/:name/update", methodNotAllowed, .{});
    router.post("/api/v1/catalog/:name/update", handlers.catalog.update, .{});

    router.all("/api/v1/catalog/:name/install/:project", methodNotAllowed, .{});
    router.post("/api/v1/catalog/:name/install/:project", handlers.catalog.install, .{});

    // Projects
    router.all("/api/v1/projects", methodNotAllowed, .{});
    router.get("/api/v1/projects", handlers.project.list, .{});

    router.all("/api/v1/project/install", methodNotAllowed, .{});
    router.post("/api/v1/project/install", handlers.project.install, .{});

    router.all("/api/v1/project/:name", methodNotAllowed, .{});
    router.get("/api/v1/project/:name", handlers.project.get, .{});
    router.delete("/api/v1/project/:name", handlers.project.delete, .{});
}
