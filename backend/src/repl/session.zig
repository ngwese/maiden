const std = @import("std");
const websocket = @import("websocket");
const repl_api = @import("api.zig");
const Io = std.Io;

pub const WsUrl = struct {
    host: []u8,
    port: u16,
    path: []u8,
    tls: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WsUrl) void {
        self.allocator.free(self.host);
        self.allocator.free(self.path);
    }
};

/// Parse `ws://host:port/path`. `localhost` becomes `127.0.0.1`.
pub fn parseWsUrl(allocator: std.mem.Allocator, url: []const u8) !WsUrl {
    const uri = try std.Uri.parse(url);
    const scheme = uri.scheme;
    const tls = std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https");
    if (!tls and !std.mem.eql(u8, scheme, "ws") and !std.mem.eql(u8, scheme, "http")) {
        return error.UnsupportedUriScheme;
    }

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try std.Io.net.HostName.fromUri(uri, &host_buf);
    var host = try allocator.dupe(u8, host_name.bytes);
    errdefer allocator.free(host);
    if (std.mem.eql(u8, host, "localhost")) {
        allocator.free(host);
        host = try allocator.dupe(u8, "127.0.0.1");
    }

    const port: u16 = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80);

    const path_src: []const u8 = if (uri.path.isEmpty())
        "/"
    else switch (uri.path) {
        .raw, .percent_encoded => |s| s,
    };
    const path = try allocator.dupe(u8, path_src);
    errdefer allocator.free(path);

    return .{
        .host = host,
        .port = port,
        .path = path,
        .tls = tls,
        .allocator = allocator,
    };
}

const MessageQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayListUnmanaged([]u8) = .empty,
    allocator: std.mem.Allocator,
    io: Io,

    fn push(self: *MessageQueue, data: []const u8) !void {
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.allocator, owned);
    }

    fn drainInto(self: *MessageQueue, out: *std.ArrayListUnmanaged([]u8)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(self.allocator, self.items.items) catch {
            for (self.items.items) |m| self.allocator.free(m);
        };
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *MessageQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |m| self.allocator.free(m);
        self.items.deinit(self.allocator);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: Io,
    component: repl_api.Component,
    url: WsUrl,
    inbound: MessageQueue,
    outbound: MessageQueue,
    connected: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    reconnect: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    status_note: std.Io.Mutex = .init,
    last_error: ?[]u8 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: Io,
        component: repl_api.Component,
        url_str: []const u8,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .component = component,
            .url = try parseWsUrl(allocator, url_str),
            .inbound = .{ .allocator = allocator, .io = io },
            .outbound = .{ .allocator = allocator, .io = io },
        };
        errdefer self.url.deinit();
        return self;
    }

    pub fn start(self: *Session) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn requestReconnect(self: *Session) void {
        self.reconnect.store(true, .release);
    }

    pub fn sendLine(self: *Session, line: []const u8) !void {
        try self.outbound.push(line);
    }

    pub fn drainInbound(self: *Session, out: *std.ArrayListUnmanaged([]u8)) void {
        self.inbound.drainInto(out);
    }

    pub fn isConnected(self: *const Session) bool {
        return self.connected.load(.acquire);
    }

    pub fn takeError(self: *Session) ?[]u8 {
        self.status_note.lockUncancelable(self.io);
        defer self.status_note.unlock(self.io);
        const e = self.last_error;
        self.last_error = null;
        return e;
    }

    pub fn shutdown(self: *Session) void {
        self.stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn destroy(self: *Session) void {
        self.shutdown();
        self.inbound.deinit();
        self.outbound.deinit();
        self.url.deinit();
        if (self.last_error) |e| self.allocator.free(e);
        self.allocator.destroy(self);
    }

    fn setError(self: *Session, msg: []const u8) void {
        self.status_note.lockUncancelable(self.io);
        defer self.status_note.unlock(self.io);
        if (self.last_error) |e| self.allocator.free(e);
        self.last_error = self.allocator.dupe(u8, msg) catch null;
    }

    fn threadMain(self: *Session) void {
        while (!self.stop.load(.acquire)) {
            self.runOnce() catch {
                self.connected.store(false, .release);
                // runOnce already recorded a phase-specific error when possible
                self.io.sleep(Io.Duration.fromMilliseconds(250), .awake) catch {};
                continue;
            };
        }
        self.connected.store(false, .release);
    }

    fn failPhase(self: *Session, phase: []const u8, err: anyerror) anyerror {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ phase, @errorName(err) }) catch @errorName(err);
        self.setError(msg);
        return err;
    }

    fn runOnce(self: *Session) !void {
        var client = websocket.Client.init(self.io, self.allocator, .{
            .host = self.url.host,
            .port = self.url.port,
            .tls = self.url.tls,
            .max_size = 65536,
            .buffer_size = 4096,
            .connect_timeout_ms = 3000,
        }) catch |err| return self.failPhase("connect", err);
        defer client.deinit();

        const host_header = try std.fmt.allocPrint(
            self.allocator,
            "Host: {s}:{d}\r\nSec-WebSocket-Protocol: bus.sp.nanomsg.org",
            .{ self.url.host, self.url.port },
        );
        defer self.allocator.free(host_header);

        client.handshake(self.url.path, .{
            .timeout_ms = 3000,
            .headers = host_header,
        }) catch |err| return self.failPhase("handshake", err);
        client.readTimeout(50) catch |err| return self.failPhase("readTimeout", err);
        self.connected.store(true, .release);
        self.reconnect.store(false, .release);

        while (!self.stop.load(.acquire)) {
            if (self.reconnect.load(.acquire)) {
                self.connected.store(false, .release);
                client.close(.{}) catch {};
                return;
            }

            // Flush outbound
            var pending: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (pending.items) |m| self.allocator.free(m);
                pending.deinit(self.allocator);
            }
            self.outbound.drainInto(&pending);
            for (pending.items) |line| {
                var frame_buf: [8192]u8 = undefined;
                const framed = repl_api.frameLine(&frame_buf, line, repl_api.terminatorFor(self.component)) catch {
                    self.setError("line too long");
                    continue;
                };
                client.write(framed) catch |err| {
                    self.connected.store(false, .release);
                    return err;
                };
            }

            const message = client.read() catch |err| switch (err) {
                error.Closed => {
                    self.connected.store(false, .release);
                    return error.Closed;
                },
                else => {
                    self.connected.store(false, .release);
                    return err;
                },
            } orelse continue;

            defer client.done(message);
            switch (message.type) {
                .text, .binary => {
                    try self.inbound.push(message.data);
                },
                .ping => {
                    client.writePong(@constCast(message.data)) catch {};
                },
                .pong => {},
                .close => {
                    self.connected.store(false, .release);
                    return error.Closed;
                },
            }
        }
        self.connected.store(false, .release);
        client.close(.{}) catch {};
    }
};

/// After a successful unit op, ask `session` to reconnect up to `attempts` times.
pub fn reconnectWithRetries(session: *Session, attempts: u32) void {
    session.requestReconnect();
    var i: u32 = 0;
    while (i < attempts) : (i += 1) {
        session.io.sleep(Io.Duration.fromMilliseconds(250), .awake) catch {};
        if (session.isConnected()) return;
    }
}

test "parseWsUrl localhost to ipv4" {
    var u = try parseWsUrl(std.testing.allocator, "ws://localhost:5555/");
    defer u.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 5555), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}
