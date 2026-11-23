const std = @import("std");
const httpz = @import("httpz");
const unit = @import("../../unit/unit.zig");
const respond = @import("../respond.zig");
const server = @import("../server.zig");

const App = server.App;

/// GET /api/v1/unit/:name — status or ?do= operation.
pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        try respond.err(res, .bad_request, "missing unit name");
        return;
    };
    const qs = try req.query();
    if (qs.get("do")) |op| {
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        unit.doOperation(res.arena, app.io, name, op, &detail) catch |e| switch (e) {
            error.NoDbusConnection => {
                try respond.err(res, .service_unavailable, "no dbus connection");
                return;
            },
            error.UnrecognizedOperation => {
                try respond.err(res, .bad_request, "unrecognized operation");
                return;
            },
            else => {
                const msg = if (detail.items.len > 0) detail.items else @errorName(e);
                try respond.err(res, .internal_server_error, msg);
                return;
            },
        };
        try respond.value(res, .ok, .{ .job_id = @as(i32, 0), .result = "done" });
        return;
    }

    const status = unit.getStatus(res.arena, app.io, name) catch |e| switch (e) {
        error.NoDbusConnection => {
            try respond.err(res, .service_unavailable, "no dbus connection");
            return;
        },
        error.UnitNotFound => {
            const msg = try std.fmt.allocPrint(res.arena, "unknown unit: {s}", .{name});
            try respond.err(res, .not_found, msg);
            return;
        },
        else => {
            try respond.err(res, .internal_server_error, @errorName(e));
            return;
        },
    };
    try respond.value(res, .ok, .{ .state = status.state, .sub_state = status.sub_state });
}
