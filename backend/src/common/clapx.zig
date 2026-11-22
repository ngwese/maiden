const std = @import("std");
const clap = @import("clap");

/// One row under Available Commands or Arguments.
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
};

/// Cobra-like help layout. Flag lines come from clap; command/arg lists are explicit.
pub const Options = struct {
    summary: []const u8,
    usage: []const u8,
    commands: []const Entry = &.{},
    args: []const Entry = &.{},
    /// Clap params for this command; only named params are printed under Flags.
    params: []const clap.Param(clap.Help),
    /// When true, also print Global Flags from `global_params`.
    global_flags: bool = false,
    more: ?[]const u8 = null,
};

/// Root-level flags that appear as Global Flags on nested help.
pub const global_params = clap.parseParamsComptime(
    \\    --config <str>   use specific config file
    \\    --debug          enable debug logging
    \\
);

const flag_help_options: clap.HelpOptions = .{
    .description_on_new_line = false,
    .spacing_between_parameters = 0,
    .indent = 2,
    .description_indent = 3,
};

/// Print cobra-style help to stderr.
pub fn print(io: std.Io, comptime opt: Options) !void {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    const w = &writer.interface;

    try w.writeAll(opt.summary);
    try w.writeAll("\n\nUsage:\n  ");
    try w.writeAll(opt.usage);
    try w.writeAll("\n");

    if (opt.commands.len > 0) {
        try w.writeAll("\nAvailable Commands:\n");
        try writeEntries(w, opt.commands);
    }

    if (opt.args.len > 0) {
        try w.writeAll("\nArguments:\n");
        try writeEntries(w, opt.args);
    }

    const flags = comptime flagParamsOnly(opt.params);
    if (flags.len > 0) {
        try w.writeAll("\nFlags:\n");
        try clap.help(w, clap.Help, flags, flag_help_options);
        try w.writeAll("\n");
    }

    if (opt.global_flags) {
        try w.writeAll("\nGlobal Flags:\n");
        try clap.help(w, clap.Help, &global_params, flag_help_options);
        try w.writeAll("\n");
    }

    if (opt.more) |more| {
        try w.writeAll("\n");
        try w.writeAll(more);
        if (more.len == 0 or more[more.len - 1] != '\n')
            try w.writeAll("\n");
    }

    try w.flush();
}

fn writeEntries(w: *std.Io.Writer, entries: []const Entry) !void {
    var width: usize = 0;
    for (entries) |e| width = @max(width, e.name.len);
    for (entries) |e| {
        try w.writeAll("  ");
        try w.writeAll(e.name);
        try w.splatByteAll(' ', width - e.name.len + 3);
        try w.writeAll(e.description);
        try w.writeAll("\n");
    }
}

fn flagParamsOnly(comptime params: []const clap.Param(clap.Help)) []const clap.Param(clap.Help) {
    return comptime blk: {
        var count: usize = 0;
        for (params) |p| {
            if (p.names.short != null or p.names.long != null) count += 1;
        }
        var out: [count]clap.Param(clap.Help) = undefined;
        var i: usize = 0;
        for (params) |p| {
            if (p.names.short != null or p.names.long != null) {
                out[i] = p;
                i += 1;
            }
        }
        const frozen = out;
        break :blk &frozen;
    };
}

/// Report a clap parse error and exit.
pub fn fail(io: std.Io, diag: *clap.Diagnostic, err: anyerror) noreturn {
    diag.reportToFile(io, .stderr(), err) catch {};
    std.process.exit(1);
}
