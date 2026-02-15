// nanobrew — Formula metadata struct
//
// Represents a Homebrew formula with bottle info for macOS arm64.
// Parsed from https://formulae.brew.sh/api/formula/<name>.json

const std = @import("std");

pub const Formula = struct {
    name: []const u8,
    version: []const u8,
    revision: u32 = 0,
    rebuild: u32 = 0,
    desc: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    bottle_url: []const u8 = "",
    bottle_sha256: []const u8 = "",

    /// Effective version string including rebuild suffix for bottle paths.
    /// e.g. "3.1.0" or "3.1.0_1" if rebuild > 0
    pub fn effectiveVersion(self: *const Formula, buf: []u8) []const u8 {
        if (self.rebuild > 0) {
            return std.fmt.bufPrint(buf, "{s}_{d}", .{ self.version, self.rebuild }) catch self.version;
        }
        return self.version;
    }
    pub fn deinit(self: Formula, alloc: std.mem.Allocator) void {
        for (self.dependencies) |dep| alloc.free(dep);
        alloc.free(self.dependencies);
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.desc);
        alloc.free(self.bottle_url);
        alloc.free(self.bottle_sha256);
    }


    /// Build the bottle URL for this formula.
    pub fn bottleUrl(self: *const Formula) []const u8 {
        return self.bottle_url;
    }

    /// Cellar path: prefix/Cellar/<name>/<version>
    pub fn cellarPath(self: *const Formula, buf: []u8) []const u8 {
        var ver_buf: [128]u8 = undefined;
        const ver = self.effectiveVersion(&ver_buf);
        return std.fmt.bufPrint(buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{ self.name, ver }) catch "";
    }
};

/// macOS bottle tag for arm64
pub const BOTTLE_TAG = "arm64_sonoma";

/// Alternate tags to try if primary isn't available
pub const BOTTLE_FALLBACKS = [_][]const u8{
    "arm64_sequoia",
    "arm64_ventura",
    "arm64_monterey",
    "all",
};
