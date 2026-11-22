const std = @import("std");
const urlx = @import("../common/urlx.zig");
const Io = std.Io;

pub const Component = enum {
    norns,
    supercollider,

    pub fn unitName(self: Component) []const u8 {
        return switch (self) {
            .norns => "norns-main.service",
            .supercollider => "norns-sclang.service",
        };
    }

    pub fn label(self: Component) []const u8 {
        return switch (self) {
            .norns => "norns",
            .supercollider => "supercollider",
        };
    }
};

pub const ParsedCommand = union(enum) {
    install: []const u8,
    unit: []const u8,
    none,
};

/// Parse a trimmed REPL line. Leading `;` triggers special handling.
/// `install` borrows the URL substring from `line`. `unit` borrows the op name.
pub fn parseSemicolon(line: []const u8) ParsedCommand {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != ';') return .none;
    const rest = std.mem.trim(u8, trimmed[1..], " \t");
    if (rest.len == 0) return .none;

    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const op = it.next() orelse return .none;
    if (std.mem.eql(u8, op, "install")) {
        const url = it.rest();
        const url_trim = std.mem.trim(u8, url, " \t");
        if (url_trim.len == 0) return .{ .unit = op };
        return .{ .install = url_trim };
    }
    return .{ .unit = op };
}

pub const LineTerminator = enum { newline, escape };

pub fn terminatorFor(component: Component) LineTerminator {
    return switch (component) {
        .norns => .newline,
        .supercollider => .escape,
    };
}

/// Append the channel's evaluate delimiter into `buf` after `line`. Caller provides capacity.
pub fn frameLine(buf: []u8, line: []const u8, term: LineTerminator) ![]u8 {
    if (line.len + 1 > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0..line.len], line);
    buf[line.len] = switch (term) {
        .newline => '\n',
        .escape => 0x1b,
    };
    return buf[0 .. line.len + 1];
}

pub const StatusTag = enum { none, ok, incomplete };

/// Detect matron `<ok>` / `<incomplete>` tags. Returns the tag and a slice of
/// content before the tag (may be empty). `line` is not modified.
pub fn splitStatusTag(line: []const u8) struct { tag: StatusTag, before: []const u8, tag_text: []const u8 } {
    if (std.mem.indexOf(u8, line, "<ok>")) |i| {
        return .{ .tag = .ok, .before = line[0..i], .tag_text = "<ok>" };
    }
    if (std.mem.indexOf(u8, line, "<incomplete>")) |i| {
        return .{ .tag = .incomplete, .before = line[0..i], .tag_text = "<incomplete>" };
    }
    return .{ .tag = .none, .before = line, .tag_text = "" };
}

pub const ApiResult = struct {
    ok: bool,
    message: []u8,
    /// When true, the REPL should refresh the local script listing.
    refresh: bool = false,

    pub fn deinit(self: ApiResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// POST install and return a user-facing message. Caller frees `ApiResult.message`.
pub fn installFromUrl(allocator: std.mem.Allocator, io: Io, api_base: []const u8, url: []const u8) !ApiResult {
    const encoded = try urlx.percentEncode(allocator, url);
    defer allocator.free(encoded);
    const request_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/project/install?url={s}", .{
        stripTrailingSlash(api_base),
        encoded,
    });
    defer allocator.free(request_url);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .POST,
        .payload = "",
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, "install request failed: {s}", .{@errorName(err)}),
        };
    };

    const text = std.mem.trim(u8, body.written(), " \t\r\n");
    const parsed = parseBody(InstallBody, allocator, text);
    defer if (parsed) |p| p.deinit();
    if (result.status == .created or result.status == .ok) {
        if (parsed) |p| if (p.value.project_name.len > 0) {
            return .{
                .ok = true,
                .message = try std.fmt.allocPrint(allocator, "installed \"{s}\"!", .{p.value.project_name}),
                .refresh = true,
            };
        };
        return .{
            .ok = true,
            .message = try allocator.dupe(u8, "installed!"),
            .refresh = true,
        };
    }
    if (parsed) |p| if (p.value.@"error".len > 0) {
        return .{ .ok = false, .message = try allocator.dupe(u8, p.value.@"error") };
    };
    return .{
        .ok = false,
        .message = try std.fmt.allocPrint(allocator, "install failed (HTTP {d})", .{@backingInt(result.status)}),
    };
}

/// DELETE `/api/v1/project/{name}`. Caller frees `ApiResult.message`.
pub fn removeProject(allocator: std.mem.Allocator, io: Io, api_base: []const u8, name: []const u8) !ApiResult {
    const encoded = try urlx.percentEncode(allocator, name);
    defer allocator.free(encoded);
    const request_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/project/{s}", .{
        stripTrailingSlash(api_base),
        encoded,
    });
    defer allocator.free(request_url);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .DELETE,
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, "delete request failed: {s}", .{@errorName(err)}),
        };
    };

    const text = std.mem.trim(u8, body.written(), " \t\r\n");
    const parsed = parseBody(MessageBody, allocator, text);
    defer if (parsed) |p| p.deinit();
    if (result.status == .ok) {
        return .{
            .ok = true,
            .message = try std.fmt.allocPrint(allocator, "deleted \"{s}\"", .{name}),
            .refresh = true,
        };
    }
    if (parsed) |p| {
        if (p.value.@"error".len > 0) {
            return .{ .ok = false, .message = try allocator.dupe(u8, p.value.@"error") };
        }
        if (p.value.message.len > 0) {
            return .{ .ok = false, .message = try allocator.dupe(u8, p.value.message) };
        }
    }
    return .{
        .ok = false,
        .message = try std.fmt.allocPrint(allocator, "delete failed (HTTP {d})", .{@backingInt(result.status)}),
    };
}

/// GET `/api/v1/project/{name}?update=`. Caller frees `ApiResult.message`.
pub fn updateProject(allocator: std.mem.Allocator, io: Io, api_base: []const u8, name: []const u8) !ApiResult {
    const encoded = try urlx.percentEncode(allocator, name);
    defer allocator.free(encoded);
    const request_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/project/{s}?update=", .{
        stripTrailingSlash(api_base),
        encoded,
    });
    defer allocator.free(request_url);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .GET,
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, "update request failed: {s}", .{@errorName(err)}),
        };
    };

    const text = std.mem.trim(u8, body.written(), " \t\r\n");
    const parsed = parseBody(UpdateBody, allocator, text);
    defer if (parsed) |p| p.deinit();
    if (result.status == .ok) {
        if (parsed) |p| if (p.value.updated) |updated| {
            if (updated) {
                return .{
                    .ok = true,
                    .message = try std.fmt.allocPrint(allocator, "updated \"{s}\"!", .{name}),
                    .refresh = true,
                };
            }
            return .{
                .ok = true,
                .message = try std.fmt.allocPrint(allocator, "no updates for \"{s}\"", .{name}),
            };
        };
        return .{
            .ok = true,
            .message = try std.fmt.allocPrint(allocator, "updated \"{s}\"!", .{name}),
            .refresh = true,
        };
    }
    if (parsed) |p| if (p.value.@"error".len > 0) {
        return .{ .ok = false, .message = try allocator.dupe(u8, p.value.@"error") };
    };
    return .{
        .ok = false,
        .message = try std.fmt.allocPrint(allocator, "update failed (HTTP {d})", .{@backingInt(result.status)}),
    };
}

/// GET unit operation. Caller frees `ApiResult.message`.
pub fn unitOperation(allocator: std.mem.Allocator, io: Io, api_base: []const u8, component: Component, operation: []const u8) !ApiResult {
    const request_url = try std.fmt.allocPrint(allocator, "{s}/api/v1/unit/{s}?do={s}", .{
        stripTrailingSlash(api_base),
        component.unitName(),
        operation,
    });
    defer allocator.free(request_url);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .GET,
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, "unit request failed: {s}", .{@errorName(err)}),
        };
    };

    const text = std.mem.trim(u8, body.written(), " \t\r\n");
    const parsed = parseBody(UnitBody, allocator, text);
    defer if (parsed) |p| p.deinit();
    if (result.status == .ok) {
        if (parsed) |p| if (p.value.result.len > 0) {
            return .{
                .ok = true,
                .message = try std.fmt.allocPrint(allocator, ";{s} => {s}", .{ operation, p.value.result }),
            };
        };
        return .{
            .ok = true,
            .message = try std.fmt.allocPrint(allocator, ";{s} => done", .{operation}),
        };
    }
    if (parsed) |p| if (p.value.@"error".len > 0) {
        return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, ";{s} => {s}", .{ operation, p.value.@"error" }),
        };
    };
    return .{
        .ok = false,
        .message = try std.fmt.allocPrint(allocator, ";{s} => HTTP {d}", .{ operation, @backingInt(result.status) }),
    };
}

fn stripTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

pub const ReplEndpoints = struct {
    norns: []u8,
    supercollider: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplEndpoints) void {
        self.allocator.free(self.norns);
        self.allocator.free(self.supercollider);
    }
};

/// Host from the API base URL used to fetch `repl-endpoints.json`.
/// `localhost` becomes `127.0.0.1`.
pub fn authorityHostFromApiBase(allocator: std.mem.Allocator, api_base: []const u8) ![]u8 {
    const uri = try std.Uri.parse(api_base);
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try std.Io.net.HostName.fromUri(uri, &host_buf);
    if (std.mem.eql(u8, host_name.bytes, "localhost")) {
        return try allocator.dupe(u8, "127.0.0.1");
    }
    return try allocator.dupe(u8, host_name.bytes);
}

/// Replace `maiden_app_location` in a websocket URL with `authority_host`.
pub fn resolveEndpoint(allocator: std.mem.Allocator, template: []const u8, authority_host: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, template, "maiden_app_location") == null) {
        return try allocator.dupe(u8, template);
    }
    return try std.mem.replaceOwned(u8, allocator, template, "maiden_app_location", authority_host);
}

/// GET `{api_base}/maiden/repl-endpoints.json`, parse, and substitute authority host.
pub fn fetchReplEndpoints(allocator: std.mem.Allocator, io: Io, api_base: []const u8) !ReplEndpoints {
    const request_url = try std.fmt.allocPrint(allocator, "{s}/maiden/repl-endpoints.json", .{
        stripTrailingSlash(api_base),
    });
    defer allocator.free(request_url);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .GET,
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch return error.ReplEndpointsFetchFailed;

    if (result.status != .ok) return error.ReplEndpointsFetchFailed;

    const EndpointsJson = struct {
        norns: []const u8,
        supercollider: []const u8,
    };
    const parsed = std.json.parseFromSlice(EndpointsJson, allocator, body.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.ReplEndpointsParseFailed;
    defer parsed.deinit();

    const host = try authorityHostFromApiBase(allocator, api_base);
    defer allocator.free(host);

    const norns = try resolveEndpoint(allocator, parsed.value.norns, host);
    errdefer allocator.free(norns);
    const supercollider = try resolveEndpoint(allocator, parsed.value.supercollider, host);
    errdefer allocator.free(supercollider);

    return .{
        .norns = norns,
        .supercollider = supercollider,
        .allocator = allocator,
    };
}

const InstallBody = struct {
    project_name: []const u8 = "",
    @"error": []const u8 = "",
};

const MessageBody = struct {
    message: []const u8 = "",
    @"error": []const u8 = "",
};

const UpdateBody = struct {
    updated: ?bool = null,
    @"error": []const u8 = "",
};

const UnitBody = struct {
    result: []const u8 = "",
    @"error": []const u8 = "",
};

fn parseBody(comptime T: type, allocator: std.mem.Allocator, text: []const u8) ?std.json.Parsed(T) {
    if (text.len == 0) return null;
    return std.json.parseFromSlice(T, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

test "parseBody unescapes strings" {
    const parsed = parseBody(InstallBody, std.testing.allocator, "{\"project_name\":\"a\\\"b\"}").?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b", parsed.value.project_name);
}

test "parseSemicolon install" {
    const p = parseSemicolon(";install https://example.com/a.zip");
    try std.testing.expect(p == .install);
    try std.testing.expectEqualStrings("https://example.com/a.zip", p.install);
}

test "parseSemicolon unit" {
    const p = parseSemicolon(";restart");
    try std.testing.expect(p == .unit);
    try std.testing.expectEqualStrings("restart", p.unit);
}

test "parseSemicolon none" {
    try std.testing.expect(parseSemicolon("print(1)") == .none);
}

test "frameLine terminators" {
    var buf: [32]u8 = undefined;
    const norns = try frameLine(&buf, "hi", .newline);
    try std.testing.expectEqualSlices(u8, "hi\n", norns);
    const sc = try frameLine(&buf, "hi", .escape);
    try std.testing.expectEqual(@as(u8, 0x1b), sc[sc.len - 1]);
}

test "splitStatusTag" {
    const a = splitStatusTag("hello\n<ok>");
    try std.testing.expect(a.tag == .ok);
    try std.testing.expectEqualStrings("hello\n", a.before);
    const b = splitStatusTag("x <incomplete>");
    try std.testing.expect(b.tag == .incomplete);
    const c = splitStatusTag("plain");
    try std.testing.expect(c.tag == .none);
}

test "resolveEndpoint substitutes maiden_app_location" {
    const resolved = try resolveEndpoint(
        std.testing.allocator,
        "ws://maiden_app_location:5555",
        "127.0.0.1",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("ws://127.0.0.1:5555", resolved);
}

test "resolveEndpoint leaves concrete host alone" {
    const resolved = try resolveEndpoint(
        std.testing.allocator,
        "ws://192.168.1.10:5555/",
        "127.0.0.1",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("ws://192.168.1.10:5555/", resolved);
}

test "authorityHostFromApiBase" {
    const a = try authorityHostFromApiBase(std.testing.allocator, "http://127.0.0.1:5000");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("127.0.0.1", a);

    const b = try authorityHostFromApiBase(std.testing.allocator, "http://localhost:5000/");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("127.0.0.1", b);

    const c = try authorityHostFromApiBase(std.testing.allocator, "http://norns.local:5000");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("norns.local", c);
}
