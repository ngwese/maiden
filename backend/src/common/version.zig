const build_options = @import("build_options");

/// Build version, with the compile timestamp appended when one was provided.
/// The result is a comptime string.
pub fn versionString() []const u8 {
    if (build_options.compile_time.len > 0) {
        return build_options.version ++ " / " ++ build_options.compile_time;
    }
    return build_options.version;
}
