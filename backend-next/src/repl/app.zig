const std = @import("std");
const zigtui = @import("zigtui");
const config = @import("../common/config.zig");
const fsx = @import("../common/fsx.zig");
const log = std.log.scoped(.repl);
const repl_api = @import("api.zig");
const repl_session = @import("session.zig");
const repl_scripts = @import("scripts.zig");
const Io = std.Io;

const scrollback_limit = 200;
const history_limit = 200;
const script_panel_width: u16 = 28;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_path: ?[]const u8 = null,
    /// When null, discovered from `{api_base}/maiden/repl-endpoints.json`.
    norns_url: ?[]const u8 = null,
    /// When null, discovered from `{api_base}/maiden/repl-endpoints.json`.
    sc_url: ?[]const u8 = null,
    api_base: []const u8 = "http://127.0.0.1/",
};

const Focus = enum { input, scripts };

const LayoutHit = struct {
    tabs: zigtui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scripts: zigtui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scripts_inner: zigtui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    output: zigtui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    output_inner: zigtui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    /// Lines scrolled up from the bottom; 0 means follow the end.
    offset_from_bottom: usize = 0,
    /// Last rendered viewport height; used to clamp page-up at the top.
    view_height: usize = 0,

    fn deinit(self: *Scrollback) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }

    fn maxOffset(self: *const Scrollback) usize {
        return self.lines.items.len -| self.view_height;
    }

    fn append(self: *Scrollback, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            // Websocket payloads are typically newline-terminated; splitting leaves a
            // trailing empty segment. The web UI collapses those empty rows, so skip
            // them here to avoid double-spaced output.
            if (line.len == 0) continue;
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            try self.lines.append(self.allocator, owned);
            while (self.lines.items.len > scrollback_limit) {
                const old = self.lines.orderedRemove(0);
                self.allocator.free(old);
            }
        }
        if (self.offset_from_bottom > self.maxOffset()) {
            self.offset_from_bottom = self.maxOffset();
        }
    }

    fn clear(self: *Scrollback) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.clearRetainingCapacity();
        self.offset_from_bottom = 0;
    }

    fn pageUp(self: *Scrollback, page: usize) void {
        self.offset_from_bottom = @min(self.maxOffset(), self.offset_from_bottom + page);
    }

    fn pageDown(self: *Scrollback, page: usize) void {
        if (self.offset_from_bottom <= page) {
            self.offset_from_bottom = 0;
        } else {
            self.offset_from_bottom -= page;
        }
    }

    fn visibleText(self: *Scrollback, allocator: std.mem.Allocator, height: usize) ![]u8 {
        self.view_height = height;
        if (height == 0 or self.lines.items.len == 0) return try allocator.dupe(u8, "");
        if (self.offset_from_bottom > self.maxOffset()) {
            self.offset_from_bottom = self.maxOffset();
        }
        const total = self.lines.items.len;
        const end = total - self.offset_from_bottom;
        const start = end -| height;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var i = start;
        while (i < end) : (i += 1) {
            if (i > start) try out.append(allocator, '\n');
            try out.appendSlice(allocator, self.lines.items[i]);
        }
        return try out.toOwnedSlice(allocator);
    }
};

const History = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]u8) = .empty,
    /// 0 means editing a new line; 1 is most recent.
    cursor: usize = 0,

    fn deinit(self: *History) void {
        for (self.items.items) |h| self.allocator.free(h);
        self.items.deinit(self.allocator);
    }

    fn push(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[0], line)) {
            self.cursor = 0;
            return;
        }
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        try self.items.insert(self.allocator, 0, owned);
        while (self.items.items.len > history_limit) {
            const old = self.items.pop().?;
            self.allocator.free(old);
        }
        self.cursor = 0;
    }

    fn older(self: *History) ?[]const u8 {
        if (self.items.items.len == 0) return null;
        if (self.cursor < self.items.items.len) self.cursor += 1;
        return self.items.items[self.cursor - 1];
    }

    fn newer(self: *History) ?[]const u8 {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        if (self.cursor == 0) return "";
        return self.items.items[self.cursor - 1];
    }
};

const HttpJobKind = enum { install, unit, update, remove };

const ConfirmKind = enum { update, delete };

const ConfirmDialog = struct {
    kind: ConfirmKind,
    project_name: []u8,
    selected_button: usize = 0,
};

const NamePrompt = struct {
    input: zigtui.TextInput(128) = .{ .focused = true, .placeholder = "project name" },
    error_msg: [80]u8 = undefined,
    error_len: usize = 0,

    fn setError(self: *NamePrompt, msg: []const u8) void {
        const n = @min(msg.len, self.error_msg.len);
        @memcpy(self.error_msg[0..n], msg[0..n]);
        self.error_len = n;
    }

    fn clearError(self: *NamePrompt) void {
        self.error_len = 0;
    }

    fn errorSlice(self: *const NamePrompt) []const u8 {
        return self.error_msg[0..self.error_len];
    }
};

const HttpJob = struct {
    allocator: std.mem.Allocator,
    io: Io,
    api_base: []const u8,
    kind: HttpJobKind,
    component: repl_api.Component,
    /// URL for install, or operation name for unit.
    arg: []u8,
    echo: []u8,
    results: *ResultQueue,
};

const HttpResult = struct {
    component: repl_api.Component,
    echo: []u8,
    message: []u8,
    ok: bool,
    kind: HttpJobKind,
    rescan: bool,
};

const ResultQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayListUnmanaged(HttpResult) = .empty,
    allocator: std.mem.Allocator,
    io: Io,

    fn push(self: *ResultQueue, item: HttpResult) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.allocator, item);
    }

    fn drain(self: *ResultQueue, out: *std.ArrayListUnmanaged(HttpResult)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(self.allocator, self.items.items) catch {
            for (self.items.items) |r| {
                self.allocator.free(r.echo);
                self.allocator.free(r.message);
            }
        };
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *ResultQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |r| {
            self.allocator.free(r.echo);
            self.allocator.free(r.message);
        }
        self.items.deinit(self.allocator);
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    api_base: []const u8,
    dust_code: []const u8,
    norns: *repl_session.Session,
    sc: *repl_session.Session,
    active: repl_api.Component = .norns,
    focus: Focus = .input,
    show_scripts: bool = true,
    scrollbacks: [2]Scrollback,
    histories: [2]History,
    input: zigtui.TextInput(512) = .{},
    catalog: repl_scripts.Catalog,
    tree_selected: ?usize = 0,
    tree_scroll: usize = 0,
    matron_tag: []const u8 = "",
    matron_tag_owned: ?[]u8 = null,
    status_msg: ?[]u8 = null,
    results: ResultQueue,
    confirm: ?ConfirmDialog = null,
    name_prompt: ?NamePrompt = null,
    layout: LayoutHit = .{},
    running: bool = true,
    backend: *zigtui.NativeBackend,
    terminal: *zigtui.Terminal,

    fn scrollback(self: *App, c: repl_api.Component) *Scrollback {
        return &self.scrollbacks[@intFromEnum(c)];
    }

    fn history(self: *App, c: repl_api.Component) *History {
        return &self.histories[@intFromEnum(c)];
    }

    fn session(self: *App, c: repl_api.Component) *repl_session.Session {
        return switch (c) {
            .norns => self.norns,
            .supercollider => self.sc,
        };
    }

    fn setStatus(self: *App, msg: []const u8) void {
        if (self.status_msg) |s| self.allocator.free(s);
        self.status_msg = self.allocator.dupe(u8, msg) catch null;
    }

    fn appendOutput(self: *App, c: repl_api.Component, text: []const u8) void {
        if (c == .norns) {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                const split = repl_api.splitStatusTag(line);
                if (split.tag != .none) {
                    if (self.matron_tag_owned) |o| self.allocator.free(o);
                    self.matron_tag_owned = self.allocator.dupe(u8, split.tag_text) catch null;
                    self.matron_tag = self.matron_tag_owned orelse split.tag_text;
                    const before = std.mem.trimEnd(u8, split.before, " \t");
                    if (before.len > 0) {
                        self.scrollback(c).append(before) catch {};
                    }
                    self.scrollback(c).append(split.tag_text) catch {};
                    continue;
                }
                self.scrollback(c).append(line) catch {};
            }
        } else {
            self.scrollback(c).append(text) catch {};
        }
    }

    fn sendToMatron(self: *App, line: []const u8) void {
        self.scrollback(.norns).append(line) catch {};
        self.history(.norns).push(line) catch {};
        self.norns.sendLine(line) catch |err| {
            self.setStatus(@errorName(err));
        };
        self.active = .norns;
    }

    fn submitInput(self: *App) void {
        const value = self.input.value();
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) {
            self.input.clear();
            return;
        }

        const owned = self.allocator.dupe(u8, trimmed) catch {
            self.input.clear();
            return;
        };
        defer self.allocator.free(owned);

        self.input.clear();
        self.history(self.active).push(owned) catch {};
        self.scrollback(self.active).append(owned) catch {};

        switch (repl_api.parseSemicolon(owned)) {
            .none => {
                self.session(self.active).sendLine(owned) catch |err| {
                    self.setStatus(@errorName(err));
                };
            },
            .install => |url| {
                self.scrollback(self.active).append("starting...") catch {};
                self.spawnHttp(.{
                    .kind = .install,
                    .arg = url,
                    .echo = owned,
                });
            },
            .unit => |op| {
                self.spawnHttp(.{
                    .kind = .unit,
                    .arg = op,
                    .echo = owned,
                });
            },
        }
    }

    fn spawnHttp(self: *App, args: struct {
        kind: HttpJobKind,
        arg: []const u8,
        echo: []const u8,
    }) void {
        const job = self.allocator.create(HttpJob) catch {
            self.setStatus("out of memory");
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .api_base = self.api_base,
            .kind = args.kind,
            .component = self.active,
            .arg = self.allocator.dupe(u8, args.arg) catch {
                self.allocator.destroy(job);
                self.setStatus("out of memory");
                return;
            },
            .echo = self.allocator.dupe(u8, args.echo) catch {
                self.allocator.free(job.arg);
                self.allocator.destroy(job);
                self.setStatus("out of memory");
                return;
            },
            .results = &self.results,
        };
        const thread = std.Thread.spawn(.{}, httpWorker, .{job}) catch |err| {
            self.allocator.free(job.arg);
            self.allocator.free(job.echo);
            self.allocator.destroy(job);
            self.setStatus(@errorName(err));
            return;
        };
        thread.detach();
    }

    fn playFocused(self: *App) void {
        const file = repl_scripts.scriptAtSelection(&self.catalog, self.tree_selected) orelse {
            self.setStatus("no script focused");
            return;
        };
        const cmd = repl_scripts.playCommand(self.allocator, file.load_path) catch {
            self.setStatus("out of memory");
            return;
        };
        defer self.allocator.free(cmd);
        self.sendToMatron(cmd);
    }

    fn stopScript(self: *App) void {
        self.sendToMatron(repl_scripts.stop_command);
    }

    fn rescanScripts(self: *App) void {
        self.rescanScriptsSelect(null);
        self.setStatus("scripts refreshed");
    }

    fn rescanScriptsSelect(self: *App, load_path: ?[]const u8) void {
        const next = repl_scripts.scan(self.allocator, self.dust_code) catch |err| {
            self.setStatus(@errorName(err));
            return;
        };
        self.catalog.deinit();
        self.catalog = next;
        if (load_path) |lp| {
            self.tree_selected = repl_scripts.selectionForLoadPath(&self.catalog, lp) orelse
                if (self.catalog.roots.len > 0) @as(?usize, 0) else null;
        } else {
            self.tree_selected = if (self.catalog.roots.len > 0) 0 else null;
        }
        self.tree_scroll = 0;
    }

    fn editFocused(self: *App) void {
        const file = repl_scripts.scriptAtSelection(&self.catalog, self.tree_selected) orelse {
            self.setStatus("no script focused");
            return;
        };
        self.suspendForEditor(file.abs_path);
    }

    fn suspendForEditor(self: *App, path: []const u8) void {
        const be = self.terminal.backend_impl;
        be.disableMouse() catch {};
        be.showCursor() catch {};
        be.disableAlternateScreen() catch {};
        be.exitRawMode() catch {};
        be.flush() catch {};

        const editor_env = fsx.getenv("EDITOR");
        const argv = repl_scripts.editorArgv(self.allocator, editor_env, path) catch {
            self.setStatus("failed to build editor argv");
            self.resumeTerminal();
            return;
        };
        defer repl_scripts.freeEditorArgv(self.allocator, argv);

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
            .environ_map = fsx.environ,
        }) catch |err| {
            self.setStatus(@errorName(err));
            self.resumeTerminal();
            return;
        };
        _ = child.wait(self.io) catch {};

        self.resumeTerminal();
    }

    fn resumeTerminal(self: *App) void {
        const be = self.terminal.backend_impl;
        be.enterRawMode() catch {};
        be.enableAlternateScreen() catch {};
        be.enableMouse() catch {};
        be.hideCursor() catch {};
        be.clearScreen() catch {};
        be.flush() catch {};
        self.terminal.invalidate();
    }

    fn focusedScriptLabel(self: *const App) []const u8 {
        if (repl_scripts.scriptAtSelection(&self.catalog, self.tree_selected)) |f| {
            return f.load_path;
        }
        return "-";
    }

    fn clearConfirm(self: *App) void {
        if (self.confirm) |c| {
            self.allocator.free(c.project_name);
        }
        self.confirm = null;
    }

    fn clearNamePrompt(self: *App) void {
        self.name_prompt = null;
    }

    fn beginConfirm(self: *App, kind: ConfirmKind) void {
        const name = repl_scripts.projectAtSelection(&self.catalog, self.tree_selected) orelse {
            self.setStatus(switch (kind) {
                .update => "select a project directory to update",
                .delete => "select a project directory to delete",
            });
            return;
        };
        self.clearNamePrompt();
        self.clearConfirm();
        const owned = self.allocator.dupe(u8, name) catch {
            self.setStatus("out of memory");
            return;
        };
        self.confirm = .{ .kind = kind, .project_name = owned, .selected_button = 0 };
    }

    fn beginNamePrompt(self: *App) void {
        self.clearConfirm();
        self.name_prompt = .{};
        self.name_prompt.?.input.focused = true;
    }

    fn acceptConfirm(self: *App) void {
        const c = self.confirm orelse return;
        const name = self.allocator.dupe(u8, c.project_name) catch {
            self.setStatus("out of memory");
            self.clearConfirm();
            return;
        };
        defer self.allocator.free(name);
        const kind = c.kind;
        self.clearConfirm();
        switch (kind) {
            .update => {
                self.setStatus("updating...");
                self.spawnHttp(.{ .kind = .update, .arg = name, .echo = name });
            },
            .delete => {
                self.setStatus("deleting...");
                self.spawnHttp(.{ .kind = .remove, .arg = name, .echo = name });
            },
        }
    }

    fn acceptNamePrompt(self: *App) void {
        if (self.name_prompt == null) return;
        const created = repl_scripts.createProjectScript(
            self.allocator,
            self.dust_code,
            self.name_prompt.?.input.value(),
        ) catch |err| {
            const msg: []const u8 = switch (err) {
                error.EmptyName => "name required",
                error.InvalidName => "invalid name",
                error.AlreadyExists => "name already in use",
                else => @errorName(err),
            };
            self.name_prompt.?.setError(msg);
            return;
        };
        self.clearNamePrompt();
        self.rescanScriptsSelect(created.load_path);
        self.setStatus("created script");
        const abs = created.abs_path;
        defer created.deinit(self.allocator);
        self.suspendForEditor(abs);
    }
};

fn httpWorker(job: *HttpJob) void {
    defer {
        job.allocator.free(job.arg);
        job.allocator.destroy(job);
    }

    const result: repl_api.ApiResult = switch (job.kind) {
        .install => repl_api.installFromUrl(job.allocator, job.io, job.api_base, job.arg) catch |err| repl_api.ApiResult{
            .ok = false,
            .message = job.allocator.dupe(u8, @errorName(err)) catch {
                job.allocator.free(job.echo);
                return;
            },
        },
        .unit => repl_api.unitOperation(job.allocator, job.io, job.api_base, job.component, job.arg) catch |err| repl_api.ApiResult{
            .ok = false,
            .message = job.allocator.dupe(u8, @errorName(err)) catch {
                job.allocator.free(job.echo);
                return;
            },
        },
        .update => repl_api.updateProject(job.allocator, job.io, job.api_base, job.arg) catch |err| repl_api.ApiResult{
            .ok = false,
            .message = job.allocator.dupe(u8, @errorName(err)) catch {
                job.allocator.free(job.echo);
                return;
            },
        },
        .remove => repl_api.removeProject(job.allocator, job.io, job.api_base, job.arg) catch |err| repl_api.ApiResult{
            .ok = false,
            .message = job.allocator.dupe(u8, @errorName(err)) catch {
                job.allocator.free(job.echo);
                return;
            },
        },
    };

    job.results.push(.{
        .component = job.component,
        .echo = job.echo,
        .message = result.message,
        .ok = result.ok,
        .kind = job.kind,
        .rescan = result.refresh,
    }) catch {
        job.allocator.free(job.echo);
        job.allocator.free(result.message);
    };
}

fn handleConfirmKey(app: *App, key: zigtui.KeyEvent) void {
    if (app.confirm == null) return;
    if (key.modifiers.ctrl and (key.isChar('c') or key.isChar('q'))) {
        app.clearConfirm();
        return;
    }
    switch (key.code) {
        .esc => app.clearConfirm(),
        .left, .right, .tab => {
            const cur = app.confirm.?.selected_button;
            app.confirm.?.selected_button = if (cur == 0) 1 else 0;
        },
        .enter => {
            if (app.confirm.?.selected_button == 1) {
                app.acceptConfirm();
            } else {
                app.clearConfirm();
            }
        },
        .char => |ch| {
            if (ch == 'y' or ch == 'Y') {
                app.acceptConfirm();
            } else if (ch == 'n' or ch == 'N') {
                app.clearConfirm();
            }
        },
        else => {},
    }
}

fn handleNamePromptKey(app: *App, key: zigtui.KeyEvent) void {
    if (app.name_prompt == null) return;
    if (key.modifiers.ctrl and (key.isChar('c') or key.isChar('q'))) {
        app.clearNamePrompt();
        return;
    }
    switch (key.code) {
        .esc => app.clearNamePrompt(),
        .enter => app.acceptNamePrompt(),
        .backspace => {
            app.name_prompt.?.clearError();
            app.name_prompt.?.input.deleteBackward();
        },
        .delete => {
            app.name_prompt.?.clearError();
            app.name_prompt.?.input.deleteForward();
        },
        .left => app.name_prompt.?.input.moveCursorLeft(),
        .right => app.name_prompt.?.input.moveCursorRight(),
        .home => app.name_prompt.?.input.moveCursorHome(),
        .end => app.name_prompt.?.input.moveCursorEnd(),
        .char => |ch| {
            if (key.modifiers.ctrl or key.modifiers.alt) return;
            if (ch == '/' or ch == '\\') {
                app.name_prompt.?.setError("character not allowed");
                return;
            }
            app.name_prompt.?.clearError();
            app.name_prompt.?.input.insertCodepoint(ch);
        },
        else => {},
    }
}

fn handleKey(app: *App, key: zigtui.KeyEvent) void {
    if (app.name_prompt != null) {
        handleNamePromptKey(app, key);
        return;
    }
    if (app.confirm != null) {
        handleConfirmKey(app, key);
        return;
    }

    if (key.modifiers.ctrl) {
        if (key.isChar('c') or key.isChar('q')) {
            app.running = false;
            return;
        }
        if (key.isChar('l')) {
            app.terminal.invalidate();
            return;
        }
        if (key.isChar('b') or key.isChar('B')) {
            if (key.modifiers.shift) {
                app.show_scripts = !app.show_scripts;
                if (!app.show_scripts and app.focus == .scripts) {
                    app.focus = .input;
                    app.input.focused = true;
                }
                return;
            }
            if (!app.show_scripts) {
                app.show_scripts = true;
            }
            app.focus = if (app.focus == .input) .scripts else .input;
            app.input.focused = app.focus == .input;
            return;
        }
        if (key.isChar('p')) {
            app.playFocused();
            return;
        }
        if (key.isChar('x')) {
            app.stopScript();
            return;
        }
        if (key.isChar('e')) {
            app.editFocused();
            return;
        }
        if (key.isChar('u')) {
            app.beginConfirm(.update);
            return;
        }
        if (key.isChar('n')) {
            if (app.focus == .scripts) {
                app.beginNamePrompt();
            } else {
                app.setStatus("focus script pane to create");
            }
            return;
        }
        // Many terminals encode Ctrl+Backspace as Ctrl+H.
        if (key.isChar('h') and app.focus == .scripts) {
            app.beginConfirm(.delete);
            return;
        }
    }

    switch (key.code) {
        .tab => {
            app.active = if (app.active == .norns) .supercollider else .norns;
            return;
        },
        .esc => {
            app.focus = .input;
            app.input.focused = true;
            return;
        },
        .page_up => {
            app.scrollback(app.active).pageUp(10);
            return;
        },
        .page_down => {
            app.scrollback(app.active).pageDown(10);
            return;
        },
        .backspace => {
            if (key.modifiers.ctrl) {
                app.beginConfirm(.delete);
                return;
            }
        },
        else => {},
    }

    if (app.focus == .scripts) {
        handleScriptKey(app, key);
        return;
    }

    switch (key.code) {
        .enter => app.submitInput(),
        .backspace => app.input.deleteBackward(),
        .delete => app.input.deleteForward(),
        .left => app.input.moveCursorLeft(),
        .right => app.input.moveCursorRight(),
        .home => app.input.moveCursorHome(),
        .end => app.input.moveCursorEnd(),
        .up => {
            if (app.history(app.active).older()) |line| {
                app.input.clear();
                app.input.insertBytes(line);
            }
        },
        .down => {
            if (app.history(app.active).newer()) |line| {
                app.input.clear();
                if (line.len > 0) app.input.insertBytes(line);
            } else {
                app.input.clear();
            }
        },
        .char => |c| {
            if (!key.modifiers.ctrl and !key.modifiers.alt) {
                app.input.insertCodepoint(c);
            }
        },
        else => {},
    }
}

fn scrollTree(app: *App, lines: isize) void {
    if (lines == 0 or app.layout.scripts_inner.height == 0) return;
    const height = app.layout.scripts_inner.height;
    const total = (zigtui.Tree{ .roots = app.catalog.roots }).visibleCount();
    const max_scroll = total -| height;
    if (lines < 0) {
        app.tree_scroll = app.tree_scroll -| @as(usize, @intCast(-lines));
    } else {
        app.tree_scroll = @min(max_scroll, app.tree_scroll + @as(usize, @intCast(lines)));
    }
}

fn handleMouse(app: *App, mouse: zigtui.MouseEvent) void {
    if (app.confirm != null or app.name_prompt != null) return;

    switch (mouse.kind) {
        .scroll_up => {
            if (app.show_scripts and app.layout.scripts.contains(mouse.x, mouse.y)) {
                scrollTree(app, -3);
            } else {
                app.scrollback(app.active).pageUp(3);
            }
            return;
        },
        .scroll_down => {
            if (app.show_scripts and app.layout.scripts.contains(mouse.x, mouse.y)) {
                scrollTree(app, 3);
            } else {
                app.scrollback(app.active).pageDown(3);
            }
            return;
        },
        .down => {
            if (mouse.button != .left) return;
            handleMouseClick(app, mouse.x, mouse.y);
        },
        else => {},
    }
}

fn handleMouseClick(app: *App, x: u16, y: u16) void {
    if (app.layout.tabs.contains(x, y)) {
        const titles = [_][]const u8{ "norns", "supercollider" };
        const tabs = zigtui.Tabs{ .titles = &titles, .selected = @intFromEnum(app.active) };
        if (tabs.hitTest(app.layout.tabs, x, y)) |idx| {
            if (idx == 0) {
                app.active = .norns;
            } else if (idx == 1) {
                app.active = .supercollider;
            }
        }
        return;
    }

    if (app.show_scripts and app.layout.scripts.contains(x, y)) {
        app.focus = .scripts;
        app.input.focused = false;
        if (app.layout.scripts_inner.contains(x, y)) {
            const tree = zigtui.Tree{
                .roots = app.catalog.roots,
                .selected = app.tree_selected,
                .scroll_offset = app.tree_scroll,
                .highlight_symbol = "▶ ",
            };
            if (tree.hitTest(app.layout.scripts_inner, x, y)) |hit| {
                app.tree_selected = hit.index;
                if (hit.on_disclosure) {
                    toggleTreeAtSelection(app);
                }
                var ensure = zigtui.Tree{
                    .roots = app.catalog.roots,
                    .selected = app.tree_selected,
                    .scroll_offset = app.tree_scroll,
                };
                ensure.ensureSelectedVisible(app.layout.scripts_inner.height);
                app.tree_scroll = ensure.scroll_offset;
            }
        }
        return;
    }

    if (app.layout.output.contains(x, y)) {
        app.focus = .input;
        app.input.focused = true;
        return;
    }
}

fn handleScriptKey(app: *App, key: zigtui.KeyEvent) void {
    var tree = zigtui.Tree{
        .roots = app.catalog.roots,
        .selected = app.tree_selected,
    };
    switch (key.code) {
        .up => {
            tree.selectPrevious();
            app.tree_selected = tree.selected;
        },
        .down => {
            tree.selectNext();
            app.tree_selected = tree.selected;
        },
        .enter => app.playFocused(),
        .left, .right => toggleTreeAtSelection(app),
        .char => |c| {
            if (c == 'k') {
                tree.selectPrevious();
                app.tree_selected = tree.selected;
            } else if (c == 'j') {
                tree.selectNext();
                app.tree_selected = tree.selected;
            } else if (c == 'r') {
                app.rescanScripts();
            } else if (c == 'e') {
                app.editFocused();
            } else if (c == ' ' or c == 'o') {
                toggleTreeAtSelection(app);
            }
        },
        else => {},
    }
}

fn toggleTreeAtSelection(app: *App) void {
    const sel = app.tree_selected orelse return;
    var idx: usize = 0;
    for (app.catalog.roots) |*root| {
        if (idx == sel) {
            root.expanded = !root.expanded;
            return;
        }
        idx += 1;
        if (root.expanded) idx += root.children.len;
    }
}

fn drainSessions(app: *App) void {
    var buf: std.ArrayListUnmanaged([]u8) = .empty;
    defer buf.deinit(app.allocator);

    const components = [_]repl_api.Component{ .norns, .supercollider };
    for (components) |c| {
        app.session(c).drainInbound(&buf);
        for (buf.items) |msg| {
            app.appendOutput(c, msg);
            app.allocator.free(msg);
        }
        buf.clearRetainingCapacity();
        if (app.session(c).takeError()) |e| {
            defer app.allocator.free(e);
            if (std.fmt.allocPrint(app.allocator, "{s}: {s}", .{ c.label(), e })) |note| {
                defer app.allocator.free(note);
                app.appendOutput(c, note);
            } else |_| {}
        }
    }

    var results: std.ArrayListUnmanaged(HttpResult) = .empty;
    defer results.deinit(app.allocator);
    app.results.drain(&results);
    for (results.items) |r| {
        defer {
            app.allocator.free(r.echo);
            app.allocator.free(r.message);
        }
        app.appendOutput(r.component, r.message);
        if (r.kind == .unit and r.ok) {
            repl_session.reconnectWithRetries(app.session(r.component), 4);
        }
        if (r.rescan) app.rescanScripts();
    }
    results.clearRetainingCapacity();
}

fn renderApp(app: *App, buf: *zigtui.Buffer) !void {
    const area = buf.getArea();
    var rows: [4]zigtui.Rect = undefined;
    const row_layout = zigtui.Layout{
        .direction = .vertical,
        .constraints = &.{
            .{ .fixed = 1 },
            .{ .fill = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
    };
    _ = row_layout.splitInto(area, &rows);

    const titles = [_][]const u8{ "norns", "supercollider" };
    const tabs = zigtui.Tabs{
        .titles = &titles,
        .selected = @intFromEnum(app.active),
        .selected_style = .{ .fg = .black, .bg = .cyan },
        .unselected_style = .{ .fg = .white },
    };
    app.layout.tabs = rows[0];
    tabs.render(rows[0], buf);

    var body_cols: [2]zigtui.Rect = undefined;
    const body_areas = if (app.show_scripts) blk: {
        const body_layout = zigtui.Layout{
            .direction = .horizontal,
            .constraints = &.{
                .{ .fixed = script_panel_width },
                .{ .fill = 1 },
            },
        };
        _ = body_layout.splitInto(rows[1], &body_cols);
        break :blk body_cols;
    } else blk: {
        body_cols[1] = rows[1];
        break :blk [_]zigtui.Rect{ .{ .x = 0, .y = 0, .width = 0, .height = 0 }, rows[1] };
    };

    app.layout.scripts = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    app.layout.scripts_inner = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (app.show_scripts and body_areas[0].width > 0) {
        const script_block = zigtui.Block{
            .title = if (app.focus == .scripts) " scripts * " else " scripts ",
            .borders = zigtui.Borders.all(),
            .border_style = .{ .fg = if (app.focus == .scripts) .cyan else .dark_gray },
            .border_symbols = zigtui.BorderSymbols.line(),
        };
        script_block.render(body_areas[0], buf);
        const inner = script_block.inner(body_areas[0]);
        app.layout.scripts = body_areas[0];
        app.layout.scripts_inner = inner;
        var tree = zigtui.Tree{
            .roots = app.catalog.roots,
            .selected = app.tree_selected,
            .scroll_offset = app.tree_scroll,
            .highlight_style = .{ .fg = .black, .bg = .yellow },
            .highlight_symbol = "▶ ",
        };
        tree.ensureSelectedVisible(inner.height);
        app.tree_scroll = tree.scroll_offset;
        tree.render(inner, buf);
    }

    {
        const title = if (app.active == .norns) " norns " else " supercollider ";
        const out_block = zigtui.Block{
            .title = title,
            .borders = zigtui.Borders.all(),
            .border_style = .{ .fg = .green },
            .border_symbols = zigtui.BorderSymbols.line(),
        };
        out_block.render(body_areas[1], buf);
        const inner = out_block.inner(body_areas[1]);
        app.layout.output = body_areas[1];
        app.layout.output_inner = inner;
        const text = try app.scrollback(app.active).visibleText(app.allocator, inner.height);
        defer app.allocator.free(text);
        const para = zigtui.Paragraph{ .text = text, .wrap = false };
        para.render(inner, buf);
    }

    // status
    {
        var status_buf: [256]u8 = undefined;
        const norns_state = if (app.norns.isConnected()) "up" else "down";
        const sc_state = if (app.sc.isConnected()) "up" else "down";
        const tag = if (app.matron_tag.len > 0) app.matron_tag else "-";
        const msg = if (app.status_msg) |s| s else "";
        const status = std.fmt.bufPrint(&status_buf, " norns:{s} sc:{s} {s}  focus:{s}  {s}", .{
            norns_state,
            sc_state,
            tag,
            app.focusedScriptLabel(),
            msg,
        }) catch " status ";
        const status_para = zigtui.Paragraph{
            .text = status,
            .style = .{ .fg = .black, .bg = .white },
            .wrap = false,
        };
        status_para.render(rows[2], buf);
    }

    // input
    {
        var input_cols: [2]zigtui.Rect = undefined;
        const input_layout = zigtui.Layout{
            .direction = .horizontal,
            .constraints = &.{ .{ .fixed = 3 }, .{ .fill = 1 } },
        };
        _ = input_layout.splitInto(rows[3], &input_cols);
        const prompt = zigtui.Paragraph{ .text = ">>", .style = .{ .fg = .yellow } };
        prompt.render(input_cols[0], buf);
        app.input.focused = app.focus == .input and app.confirm == null and app.name_prompt == null;
        app.input.cursor_style = .{ .bg = .cyan, .fg = .black };
        app.input.render(input_cols[1], buf);
    }

    if (app.confirm) |c| {
        var msg_buf: [256]u8 = undefined;
        const msg = switch (c.kind) {
            .update => std.fmt.bufPrint(
                &msg_buf,
                "Update project \"{s}\"?\n\nLocal modifications will be overwritten",
                .{c.project_name},
            ) catch "Update project?\n\nLocal modifications will be overwritten",
            .delete => std.fmt.bufPrint(
                &msg_buf,
                "Delete \"{s}\"?\n\nThis operation cannot be undone.",
                .{c.project_name},
            ) catch "Delete project?\n\nThis operation cannot be undone.",
        };
        const action_label: []const u8 = switch (c.kind) {
            .update => "Update",
            .delete => "Delete",
        };
        const buttons = [_][]const u8{ "Cancel", action_label };
        const dialog = zigtui.Dialog{
            .title = " confirm ",
            .message = msg,
            .buttons = &buttons,
            .selected_button = c.selected_button,
            .border_style = .{ .fg = .yellow },
            .title_style = .{ .fg = .yellow },
            .selected_button_style = .{ .fg = .black, .bg = .yellow },
            .show_backdrop = true,
        };
        const dlg_area = zigtui.Dialog.dialogArea(area, 56, 9);
        dialog.render(dlg_area, buf);
    }

    if (app.name_prompt) |*prompt| {
        const dlg_area = zigtui.Dialog.dialogArea(area, 48, 8);
        const popup = zigtui.Popup{
            .title = " new script ",
            .border_style = .{ .fg = .cyan },
            .title_style = .{ .fg = .cyan },
            .show_backdrop = true,
        };
        popup.render(dlg_area, buf);
        const inner = zigtui.Popup.innerArea(dlg_area);
        if (inner.height >= 3 and inner.width > 0) {
            const hint = zigtui.Paragraph{
                .text = "Name:",
                .style = .{ .fg = .white },
                .wrap = false,
            };
            hint.render(.{ .x = inner.x, .y = inner.y, .width = inner.width, .height = 1 }, buf);

            prompt.input.focused = true;
            prompt.input.cursor_style = .{ .bg = .cyan, .fg = .black };
            prompt.input.render(.{
                .x = inner.x,
                .y = inner.y + 1,
                .width = inner.width,
                .height = 1,
            }, buf);

            const err = prompt.errorSlice();
            if (err.len > 0) {
                const err_para = zigtui.Paragraph{
                    .text = err,
                    .style = .{ .fg = .red },
                    .wrap = false,
                };
                err_para.render(.{
                    .x = inner.x,
                    .y = inner.y + 2,
                    .width = inner.width,
                    .height = 1,
                }, buf);
            } else {
                const help = zigtui.Paragraph{
                    .text = "enter create · esc cancel",
                    .style = .{ .fg = .dark_gray },
                    .wrap = false,
                };
                help.render(.{
                    .x = inner.x,
                    .y = inner.y + 2,
                    .width = inner.width,
                    .height = 1,
                }, buf);
            }
        }
    }
}

/// Run the interactive REPL until quit.
pub fn run(opts: Options) !void {
    var cfg = try config.load(opts.allocator, opts.config_path);
    defer cfg.deinit();

    var discovered: ?repl_api.ReplEndpoints = null;
    defer if (discovered) |*eps| eps.deinit();

    const norns_url = opts.norns_url orelse blk: {
        if (discovered == null) {
            discovered = repl_api.fetchReplEndpoints(opts.allocator, opts.io, opts.api_base) catch |err| {
                log.err("failed to fetch repl-endpoints.json from {s}: {s}", .{ opts.api_base, @errorName(err) });
                return err;
            };
        }
        break :blk discovered.?.norns;
    };
    const sc_url = opts.sc_url orelse blk: {
        if (discovered == null) {
            discovered = repl_api.fetchReplEndpoints(opts.allocator, opts.io, opts.api_base) catch |err| {
                log.err("failed to fetch repl-endpoints.json from {s}: {s}", .{ opts.api_base, @errorName(err) });
                return err;
            };
        }
        break :blk discovered.?.supercollider;
    };

    const norns = try repl_session.Session.create(opts.allocator, opts.io, .norns, norns_url);
    errdefer norns.destroy();
    const sc = try repl_session.Session.create(opts.allocator, opts.io, .supercollider, sc_url);
    errdefer sc.destroy();

    var catalog = try repl_scripts.scan(opts.allocator, cfg.dust_code);
    errdefer catalog.deinit();

    var backend = try zigtui.init(opts.allocator, opts.io);
    defer backend.deinit();

    var terminal = try zigtui.Terminal.init(opts.allocator, backend.interface());
    defer terminal.deinit();
    try terminal.hideCursor();
    try terminal.enableMouse();
    defer terminal.disableMouse() catch {};

    var app: App = .{
        .allocator = opts.allocator,
        .io = opts.io,
        .api_base = opts.api_base,
        .dust_code = cfg.dust_code,
        .norns = norns,
        .sc = sc,
        .scrollbacks = .{
            .{ .allocator = opts.allocator },
            .{ .allocator = opts.allocator },
        },
        .histories = .{
            .{ .allocator = opts.allocator },
            .{ .allocator = opts.allocator },
        },
        .catalog = catalog,
        .results = .{ .allocator = opts.allocator, .io = opts.io },
        .backend = &backend,
        .terminal = &terminal,
        .tree_selected = if (catalog.roots.len > 0) @as(?usize, 0) else null,
    };
    catalog = .{ .allocator = opts.allocator };

    defer {
        app.norns.destroy();
        app.sc.destroy();
        app.scrollbacks[0].deinit();
        app.scrollbacks[1].deinit();
        app.histories[0].deinit();
        app.histories[1].deinit();
        app.catalog.deinit();
        app.results.deinit();
        if (app.matron_tag_owned) |o| app.allocator.free(o);
        if (app.status_msg) |s| app.allocator.free(s);
        app.clearConfirm();
        app.clearNamePrompt();
    }

    try app.norns.start();
    try app.sc.start();

    app.scrollback(.norns).append("MAIDEN") catch {};
    app.scrollback(.norns).append("tab: switch  ctrl-b: scripts  ctrl-shift-b: show/hide scripts  ctrl-p: play  ctrl-x: stop  ctrl-e: edit  ctrl-u: update  ctrl-n: new  ctrl-backspace: delete  ctrl-q: quit") catch {};

    while (app.running) {
        drainSessions(&app);

        const event = try app.backend.interface().pollEvent(50);
        switch (event) {
            .key => |key| handleKey(&app, key),
            .mouse => |mouse| handleMouse(&app, mouse),
            .resize => |size| {
                try app.terminal.resize(.{ .width = size.width, .height = size.height });
            },
            else => {},
        }

        try app.terminal.draw(&app, struct {
            fn render(a: *App, buf: *zigtui.Buffer) !void {
                try renderApp(a, buf);
            }
        }.render);
    }
}

test "Scrollback skips empty lines from trailing newlines" {
    var sb: Scrollback = .{ .allocator = std.testing.allocator };
    defer sb.deinit();
    try sb.append("hello\n");
    try sb.append("world\n\n");
    try std.testing.expectEqual(@as(usize, 2), sb.lines.items.len);
    try std.testing.expectEqualStrings("hello", sb.lines.items[0]);
    try std.testing.expectEqualStrings("world", sb.lines.items[1]);
}

test "Scrollback pageUp stops at top of buffer" {
    var sb: Scrollback = .{ .allocator = std.testing.allocator };
    defer sb.deinit();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line{d}", .{i});
        try sb.append(line);
    }
    sb.view_height = 10;
    sb.pageUp(10);
    try std.testing.expectEqual(@as(usize, 10), sb.offset_from_bottom);
    sb.pageUp(10);
    try std.testing.expectEqual(@as(usize, 20), sb.offset_from_bottom);
    sb.pageUp(10);
    try std.testing.expectEqual(@as(usize, 20), sb.offset_from_bottom);
    sb.pageUp(10);
    try std.testing.expectEqual(@as(usize, 20), sb.offset_from_bottom);

    const text = try sb.visibleText(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9", text);
}

test {
    _ = repl_api;
    _ = repl_scripts;
    _ = repl_session;
}
