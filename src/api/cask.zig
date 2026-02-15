// nanobrew — Cask metadata struct
//
// Represents a Homebrew cask (macOS .app/.dmg/.pkg bundle).
// Parsed from https://formulae.brew.sh/api/cask/<token>.json

const std = @import("std");

pub const DownloadFormat = enum {
    dmg,
    zip,
    pkg,
    tar_gz,
    unknown,
};

pub const Artifact = union(enum) {
    app: []const u8, // e.g. "Firefox.app"
    binary: struct { source: []const u8, target: []const u8 },
    pkg: []const u8, // pkg filename
    uninstall: struct { quit: []const u8, pkgutil: []const u8 },
};

pub const Cask = struct {
    token: []const u8, // "firefox"
    name: []const u8, // "Mozilla Firefox"
    version: []const u8, // "147.0.3"
    url: []const u8, // direct download URL
    sha256: []const u8, // or "no_check" for auto-updating apps
    desc: []const u8,
    auto_updates: bool,
    artifacts: []const Artifact,
    min_macos: ?[]const u8,

    pub fn downloadFormat(self: *const Cask) DownloadFormat {
        if (std.mem.endsWith(u8, self.url, ".dmg")) return .dmg;
        if (std.mem.endsWith(u8, self.url, ".zip")) return .zip;
        if (std.mem.endsWith(u8, self.url, ".pkg")) return .pkg;
        if (std.mem.endsWith(u8, self.url, ".tar.gz")) return .tar_gz;
        if (std.mem.endsWith(u8, self.url, ".tgz")) return .tar_gz;
        return .unknown;
    }

    pub fn shouldVerifySha(self: *const Cask) bool {
        return !std.mem.eql(u8, self.sha256, "no_check");
    }

    pub fn caskroomPath(self: *const Cask, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "/opt/nanobrew/prefix/Caskroom/{s}/{s}", .{ self.token, self.version }) catch "";
    }

    pub fn deinit(self: Cask, alloc: std.mem.Allocator) void {
        alloc.free(self.token);
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.url);
        alloc.free(self.sha256);
        alloc.free(self.desc);
        for (self.artifacts) |art| {
            switch (art) {
                .app => |a| alloc.free(a),
                .binary => |b| {
                    alloc.free(b.source);
                    alloc.free(b.target);
                },
                .pkg => |p| alloc.free(p),
                .uninstall => |u| {
                    alloc.free(u.quit);
                    alloc.free(u.pkgutil);
                },
            }
        }
        alloc.free(self.artifacts);
        if (self.min_macos) |m| alloc.free(m);
    }
};

const testing = std.testing;

test "downloadFormat - detects dmg" {
    const c = Cask{
        .token = "firefox",
        .name = "Mozilla Firefox",
        .version = "147.0.3",
        .url = "https://example.com/Firefox.dmg",
        .sha256 = "abc123",
        .desc = "Browser",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.dmg, c.downloadFormat());
}

test "downloadFormat - detects zip" {
    const c = Cask{
        .token = "vscode",
        .name = "Visual Studio Code",
        .version = "1.90",
        .url = "https://example.com/VSCode.zip",
        .sha256 = "abc123",
        .desc = "Editor",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.zip, c.downloadFormat());
}

test "downloadFormat - detects pkg" {
    const c = Cask{
        .token = "docker",
        .name = "Docker",
        .version = "4.30",
        .url = "https://example.com/Docker.pkg",
        .sha256 = "abc123",
        .desc = "Container runtime",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expectEqual(DownloadFormat.pkg, c.downloadFormat());
}

test "shouldVerifySha - returns true for normal sha" {
    const c = Cask{
        .token = "test",
        .name = "Test",
        .version = "1.0",
        .url = "https://example.com/test.dmg",
        .sha256 = "deadbeef",
        .desc = "",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expect(c.shouldVerifySha());
}

test "shouldVerifySha - returns false for no_check" {
    const c = Cask{
        .token = "test",
        .name = "Test",
        .version = "1.0",
        .url = "https://example.com/test.dmg",
        .sha256 = "no_check",
        .desc = "",
        .auto_updates = true,
        .artifacts = &.{},
        .min_macos = null,
    };
    try testing.expect(!c.shouldVerifySha());
}

test "caskroomPath - formats token and version" {
    const c = Cask{
        .token = "firefox",
        .name = "Firefox",
        .version = "147.0.3",
        .url = "",
        .sha256 = "",
        .desc = "",
        .auto_updates = false,
        .artifacts = &.{},
        .min_macos = null,
    };
    var buf: [512]u8 = undefined;
    const p = c.caskroomPath(&buf);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Caskroom/firefox/147.0.3", p);
}
