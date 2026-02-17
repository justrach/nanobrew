// nanobrew — Linux distro detection for .deb support
//
// Parses /etc/os-release to detect distribution ID and version codename.
// Used to select the correct APT mirror and release codename.

const std = @import("std");
const builtin = @import("builtin");

pub const DistroInfo = struct {
    id: []const u8, // "ubuntu" or "debian"
    codename: []const u8, // "noble", "bookworm", etc.
    mirror: []const u8, // full mirror URL
};

/// Default fallback for unknown distros
const DEFAULT_ID = "ubuntu";
const DEFAULT_CODENAME = "noble";
const DEFAULT_MIRROR_AMD64 = "http://archive.ubuntu.com/ubuntu";
const DEFAULT_MIRROR_ARM64 = "http://ports.ubuntu.com/ubuntu-ports";

/// Detect the running Linux distribution from /etc/os-release.
/// Returns sensible defaults if detection fails (Docker images always have os-release).
pub fn detect(alloc: std.mem.Allocator) DistroInfo {
    if (comptime builtin.os.tag != .linux) {
        return .{
            .id = DEFAULT_ID,
            .codename = DEFAULT_CODENAME,
            .mirror = DEFAULT_MIRROR_AMD64,
        };
    }

    const data = readOsRelease(alloc) orelse return defaultInfo();
    defer alloc.free(data);

    var id: []const u8 = DEFAULT_ID;
    var codename: []const u8 = DEFAULT_CODENAME;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (parseField(line, "ID=")) |v| {
            id = stripQuotes(v);
        } else if (parseField(line, "VERSION_CODENAME=")) |v| {
            codename = stripQuotes(v);
        }
    }

    return .{
        .id = id,
        .codename = codename,
        .mirror = getMirror(id),
    };
}

/// Get the default APT mirror for a distribution.
pub fn getMirror(id: []const u8) []const u8 {
    const platform = @import("../platform/platform.zig");

    if (std.mem.eql(u8, id, "debian")) {
        return "http://deb.debian.org/debian";
    }
    // Ubuntu: different mirrors for amd64 vs arm64
    if (comptime std.mem.eql(u8, platform.deb_arch, "arm64")) {
        return DEFAULT_MIRROR_ARM64;
    }
    return DEFAULT_MIRROR_AMD64;
}

/// Get the default components for a distribution.
pub fn getComponents(id: []const u8) []const []const u8 {
    if (std.mem.eql(u8, id, "debian")) {
        return &.{ "main", "contrib" };
    }
    return &.{ "main", "universe" };
}

fn readOsRelease(alloc: std.mem.Allocator) ?[]u8 {
    const file = std.fs.openFileAbsolute("/etc/os-release", .{}) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;
    return alloc.dupe(u8, buf[0..n]) catch null;
}

fn parseField(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, prefix)) {
        return line[prefix.len..];
    }
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    var v = s;
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
        v = v[1 .. v.len - 1];
    }
    return std.mem.trim(u8, v, " \t\r");
}

fn defaultInfo() DistroInfo {
    return .{
        .id = DEFAULT_ID,
        .codename = DEFAULT_CODENAME,
        .mirror = DEFAULT_MIRROR_AMD64,
    };
}

const testing = std.testing;

test "parseField - matches prefix" {
    try testing.expectEqualStrings("ubuntu", parseField("ID=ubuntu", "ID=").?);
}

test "parseField - no match" {
    try testing.expect(parseField("VERSION=24.04", "ID=") == null);
}

test "stripQuotes - removes double quotes" {
    try testing.expectEqualStrings("noble", stripQuotes("\"noble\""));
}

test "stripQuotes - no quotes" {
    try testing.expectEqualStrings("noble", stripQuotes("noble"));
}

test "getMirror - debian" {
    try testing.expectEqualStrings("http://deb.debian.org/debian", getMirror("debian"));
}

test "getMirror - ubuntu" {
    const m = getMirror("ubuntu");
    try testing.expect(m.len > 0);
}

test "getComponents - debian" {
    const comps = getComponents("debian");
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqualStrings("main", comps[0]);
    try testing.expectEqualStrings("contrib", comps[1]);
}

test "getComponents - ubuntu" {
    const comps = getComponents("ubuntu");
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqualStrings("main", comps[0]);
    try testing.expectEqualStrings("universe", comps[1]);
}
