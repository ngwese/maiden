const std = @import("std");

pub const omit_null: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

pub fn stringify(allocator: std.mem.Allocator, value: anytype, options: std.json.Stringify.Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer, .options = options };
    try j.write(value);
    return try out.toOwnedSlice();
}

pub fn stringifyOmitNull(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return stringify(allocator, value, omit_null);
}
