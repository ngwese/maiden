const std = @import("std");
const http = std.http;
const httpz = @import("httpz");
const fsx = @import("../common/fsx.zig");
const jsonx = @import("../common/jsonx.zig");

/// Canonial HTTP date example from RFCs, here just to establish length.
pub const http_date_len = "Sun, 06 Nov 1994 08:49:37 GMT".len;

/// Day and month names for HTTP dates per RFCs, not locale-specific.
const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Write JSON `value` with status and `Cache-Control: no-store`.
pub fn value(res: *httpz.Response, status: http.Status, val: anytype) !void {
    res.setStatus(status);
    res.header("Cache-Control", "no-store");
    try res.json(val, jsonx.omit_null);
}

/// Write `{"error": message}` JSON.
pub fn err(res: *httpz.Response, status: http.Status, message: []const u8) !void {
    try value(res, status, .{ .@"error" = message });
}

/// 404 with JSON body for GET, empty body for HEAD (api-tests expect no HEAD body).
pub fn notFound(req: *httpz.Request, res: *httpz.Response, message: []const u8) !void {
    if (req.method == .HEAD) {
        res.setStatus(.not_found);
        res.header("Cache-Control", "no-store");
        return;
    }
    try err(res, .not_found, message);
}

/// Write `{"message": message}` JSON.
pub fn msg(res: *httpz.Response, status: http.Status, message: []const u8) !void {
    try value(res, status, .{ .message = message });
}

/// Write a pre-encoded JSON body with status and `Cache-Control: no-store`.
pub fn jsonBody(res: *httpz.Response, status: http.Status, body: []const u8) void {
    res.setStatus(status);
    res.header("Cache-Control", "no-store");
    res.content_type = .JSON;
    res.body = body;
}

/// Format Unix seconds as IMF-fix HTTP-date into `buf`.
pub fn formatHttpDate(buf: *[http_date_len]u8, secs: i64) []const u8 {
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

/// Format file mtime as IMF-fix HTTP-date into `buf`.
pub fn formatHttpDateFromStat(buf: *[http_date_len]u8, st: std.Io.File.Stat) []const u8 {
    return formatHttpDate(buf, st.mtime.toSeconds());
}

fn parseMonthName(name: []const u8) ?u4 {
    for (month_names, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, name)) return @intCast(i + 1);
    }
    return null;
}

/// Parse IMF-fix HTTP-date (`Sun, 06 Nov 1994 08:49:37 GMT`) to Unix seconds.
/// Requires exact length 29 — trailing junk is rejected.
pub fn parseHttpDate(raw_value: []const u8) ?i64 {
    const v = std.mem.trim(u8, raw_value, " \t");
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
    // Require an exact IMF-fix date. fetch() joins duplicate headers with ", ",
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
        days += epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month_i)));
    }
    if (day == 0 or day > epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return null;
    days += day - 1;
    return @intCast(days * epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second);
}

/// True when an existing resource is newer than `If-Unmodified-Since` (precondition failed).
pub fn ifUnmodifiedSinceFailed(req: *httpz.Request, abs: []const u8) bool {
    const raw = req.header("if-unmodified-since") orelse return false;
    const since = parseHttpDate(raw) orelse return false;
    const st = fsx.statFile(abs) catch return false;
    return st.mtime.toSeconds() > since;
}
