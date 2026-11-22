pub const Project = @import("project/dust.zig").Project;
pub const Meta = @import("project/dust.zig").Meta;
pub const MetaFile = @import("project/dust.zig").MetaFile;
pub const FileInfo = @import("project/dust.zig").FileInfo;

pub const devicePath = @import("project/dust.zig").devicePath;
pub const resourcePath = @import("project/dust.zig").resourcePath;
pub const listDir = @import("project/dust.zig").listDir;
pub const getProjects = @import("project/dust.zig").getProjects;
pub const searchProjects = @import("project/dust.zig").searchProjects;
pub const inferProjectNameFromURL = @import("project/dust.zig").inferProjectNameFromURL;
pub const readMeta = @import("project/dust.zig").readMeta;
pub const noteUpdated = @import("project/dust.zig").noteUpdated;
pub const install = @import("project/dust.zig").install;
pub const replaceProject = @import("project/dust.zig").replaceProject;

pub const cli = @import("project/cli.zig");
