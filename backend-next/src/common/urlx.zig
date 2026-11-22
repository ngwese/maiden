const std = @import("std");

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Percent-encode bytes that are not unreserved (RFC 3986). Caller frees the result.
pub fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try percentEncodeWrite(&out.writer, input);
    return try out.toOwnedSlice();
}

/// Percent-encode `input` into `w`.
pub fn percentEncodeWrite(w: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
    try std.Uri.Component.percentEncode(w, input, isUnreserved);
}

/// Decode `%XX`. `+` becomes a space, matching query and form decoding.
/// A `%` not followed by two hex digits returns `error.InvalidEscape`.
/// Caller frees the result.
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) error{ InvalidEscape, OutOfMemory }![]u8 {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '%') continue;
        if (i + 2 >= input.len) return error.InvalidEscape;
        _ = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch return error.InvalidEscape;
        i += 2;
    }

    const buf = try allocator.dupe(u8, input);
    errdefer allocator.free(buf);
    for (buf) |*c| {
        if (c.* == '+') c.* = ' ';
    }
    const decoded = std.Uri.percentDecodeInPlace(buf);
    if (decoded.ptr != buf.ptr) std.mem.copyForwards(u8, buf[0..decoded.len], decoded);
    return try allocator.realloc(buf, decoded.len);
}

test "percentEncode leaves unreserved bytes" {
    const encoded = try percentEncode(std.testing.allocator, "a-b_c.d~");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a-b_c.d~", encoded);
}

test "percentEncode escapes space and slash" {
    const encoded = try percentEncode(std.testing.allocator, "a b/c");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%2Fc", encoded);
}

test "percentDecode converts plus and rejects a bare percent" {
    const decoded = try percentDecode(std.testing.allocator, "a+b%2Fc");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a b/c", decoded);
    try std.testing.expectError(error.InvalidEscape, percentDecode(std.testing.allocator, "%"));
    try std.testing.expectError(error.InvalidEscape, percentDecode(std.testing.allocator, "%zz"));
}
