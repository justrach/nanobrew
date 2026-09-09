// nanobrew — Formula metadata struct
//
// Represents a Homebrew formula with bottle info for macOS arm64.
// Parsed from https://formulae.brew.sh/api/formula/<name>.json

const std = @import("std");

pub const Formula = struct {
    /// Static capture of `bin.install Dir["<glob>"].first => "<dest>"` tap
    /// install lines (#361): the glob is applied to the staged payload at
    /// source-install time and the first match lands as bin/<dest>.
    pub const BinRename = struct {
        pattern: []const u8,
        dest: []const u8,
    };

    name: []const u8,
    version: []const u8,
    revision: u32 = 0,
    rebuild: u32 = 0,
    desc: []const u8 = "",
    homepage: []const u8 = "",
    license: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    bottle_url: []const u8 = "",
    bottle_sha256: []const u8 = "",
    source_url: []const u8 = "",
    source_sha256: []const u8 = "",
    /// Tap `url ..., using: :nounzip` (#361): the source download is a raw
    /// file (usually a prebuilt executable), not an archive — stage it under
    /// its upstream basename instead of extracting.
    source_nounzip: bool = false,
    build_deps: []const []const u8 = &.{},
    install_binaries: []const []const u8 = &.{},
    install_bin_renames: []const BinRename = &.{},
    caveats: []const u8 = "",
    post_install_defined: bool = false,
    /// True when this metadata came from a revoked registry pin's fallback
    /// (previous known-good version). The registry is authoritative here:
    /// live-API freshness checks must not override a security revocation.
    revoked_fallback: bool = false,

    /// Effective Cellar version including the formula revision suffix.
    /// Bottle rebuilds identify bottle artifacts but do not change the Cellar path.
    /// e.g. "3.1.0" or "3.1.0_1" if revision > 0
    /// Idempotent: some registry pins capture the keg version with the
    /// revision suffix already baked in (e.g. "1.29.0_2" with revision 2);
    /// appending again would name a keg dir the bottle does not contain (#354).
    pub fn effectiveVersion(self: *const Formula, buf: []u8) []const u8 {
        if (self.revision > 0) {
            var suffix_buf: [16]u8 = undefined;
            const suffix = std.fmt.bufPrint(&suffix_buf, "_{d}", .{self.revision}) catch return self.version;
            if (std.mem.endsWith(u8, self.version, suffix)) return self.version;
            return std.fmt.bufPrint(buf, "{s}_{d}", .{ self.version, self.revision }) catch self.version;
        }
        return self.version;
    }
    pub fn deinit(self: Formula, alloc: std.mem.Allocator) void {
        for (self.dependencies) |dep| alloc.free(dep);
        alloc.free(self.dependencies);
        for (self.build_deps) |dep| alloc.free(dep);
        alloc.free(self.build_deps);
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.desc);
        alloc.free(self.homepage);
        alloc.free(self.license);
        alloc.free(self.bottle_url);
        alloc.free(self.bottle_sha256);
        alloc.free(self.source_url);
        alloc.free(self.source_sha256);
        for (self.install_binaries) |bin| alloc.free(bin);
        if (self.install_binaries.len > 0) alloc.free(self.install_binaries);
        for (self.install_bin_renames) |r| {
            alloc.free(r.pattern);
            alloc.free(r.dest);
        }
        if (self.install_bin_renames.len > 0) alloc.free(self.install_bin_renames);
        alloc.free(self.caveats);
    }

    /// Build the bottle URL for this formula.
    /// Respects NANOBREW_BOTTLE_DOMAIN / HOMEBREW_BOTTLE_DOMAIN env vars (#74)
    pub fn bottleUrl(self: *const Formula) []const u8 {
        // If a custom bottle domain is set, the URL replacement happens at download time
        // (the URL from the API is used as-is here, rewritten in downloader.zig)
        return self.bottle_url;
    }

    /// Cellar path: prefix/Cellar/<name>/<version>
    pub fn cellarPath(self: *const Formula, buf: []u8) []const u8 {
        var ver_buf: [128]u8 = undefined;
        const ver = self.effectiveVersion(&ver_buf);
        return std.fmt.bufPrint(buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{ self.name, ver }) catch "";
    }
};

/// Bottle tag for the current platform
pub const BOTTLE_TAG = switch (@import("builtin").os.tag) {
    .macos => switch (@import("builtin").cpu.arch) {
        .aarch64 => "arm64_tahoe",
        .x86_64 => "tahoe",
        else => "all",
    },
    .linux => linuxBottleTag(@import("builtin").cpu.arch),
    else => "all",
};

/// Alternate tags to try if primary isn't available
pub const BOTTLE_FALLBACKS = switch (@import("builtin").os.tag) {
    .macos => switch (@import("builtin").cpu.arch) {
        .aarch64 => [_][]const u8{
            "arm64_sequoia",
            "arm64_sonoma",
            "arm64_ventura",
            "arm64_monterey",
            "all",
        },
        .x86_64 => [_][]const u8{
            "sequoia",
            "sonoma",
            "ventura",
            "monterey",
            "big_sur",
            "all",
        },
        else => [_][]const u8{"all"},
    },
    .linux => linuxBottleFallbacks(@import("builtin").cpu.arch),
    else => [_][]const u8{"all"},
};

const testing = std.testing;

test "effectiveVersion - no revision returns base version" {
    const f = Formula{ .name = "ffmpeg", .version = "7.1", .revision = 0 };
    var buf: [128]u8 = undefined;
    const v = f.effectiveVersion(&buf);
    try testing.expectEqualStrings("7.1", v);
}

test "effectiveVersion - revision appends suffix" {
    const f = Formula{ .name = "aalib", .version = "1.4rc5", .revision = 2 };
    var buf: [128]u8 = undefined;
    const v = f.effectiveVersion(&buf);
    try testing.expectEqualStrings("1.4rc5_2", v);
}

test "effectiveVersion - pre-suffixed version is not doubled (#354)" {
    // Registry pins like rustup store resolved.version "1.29.0_2" while also
    // carrying revision 2; the keg dir inside the bottle is "1.29.0_2".
    const f = Formula{ .name = "rustup", .version = "1.29.0_2", .revision = 2 };
    var buf: [128]u8 = undefined;
    const v = f.effectiveVersion(&buf);
    try testing.expectEqualStrings("1.29.0_2", v);
}

test "effectiveVersion - dotted tail is not mistaken for a revision suffix" {
    const f = Formula{ .name = "example", .version = "1.2", .revision = 2 };
    var buf: [128]u8 = undefined;
    const v = f.effectiveVersion(&buf);
    try testing.expectEqualStrings("1.2_2", v);
}

test "effectiveVersion - bottle rebuild does not change Cellar version" {
    const f = Formula{ .name = "aamath", .version = "0.3", .rebuild = 1 };
    var buf: [128]u8 = undefined;
    const v = f.effectiveVersion(&buf);
    try testing.expectEqualStrings("0.3", v);
}

test "cellarPath - formats name and version" {
    const f = Formula{ .name = "lame", .version = "3.100" };
    var buf: [512]u8 = undefined;
    const p = f.cellarPath(&buf);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/lame/3.100", p);
}

test "cellarPath - includes formula revision suffix" {
    const f = Formula{ .name = "aalib", .version = "1.4rc5", .revision = 2 };
    var buf: [512]u8 = undefined;
    const p = f.cellarPath(&buf);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/aalib/1.4rc5_2", p);
}

test "BOTTLE_FALLBACKS - x86_64 macOS never falls back to arm64 tags (regression #226/#227)" {
    // Past regression: on Intel Mac the fallback chain was arm64_sequoia → arm64_sonoma …,
    // so when "tahoe" was missing (always, since Intel has no Tahoe bottles) the
    // resolver silently picked an arm64 bottle. Guard against it.
    if (comptime @import("builtin").os.tag != .macos) return;
    if (comptime @import("builtin").cpu.arch != .x86_64) return;
    for (BOTTLE_FALLBACKS) |tag| {
        try testing.expect(!std.mem.startsWith(u8, tag, "arm64_"));
    }
}

test "BOTTLE_FALLBACKS - arm64 macOS only uses arm64 or generic tags" {
    if (comptime @import("builtin").os.tag != .macos) return;
    if (comptime @import("builtin").cpu.arch != .aarch64) return;
    for (BOTTLE_FALLBACKS) |tag| {
        const ok = std.mem.startsWith(u8, tag, "arm64_") or std.mem.eql(u8, tag, "all");
        try testing.expect(ok);
    }
}

test "BOTTLE_TAG - matches arch family on macOS" {
    if (comptime @import("builtin").os.tag != .macos) return;
    switch (comptime @import("builtin").cpu.arch) {
        .aarch64 => try testing.expect(std.mem.startsWith(u8, BOTTLE_TAG, "arm64_")),
        .x86_64 => try testing.expect(!std.mem.startsWith(u8, BOTTLE_TAG, "arm64_")),
        else => {},
    }
}

// Homebrew uses arm64_linux for native ARM bottles. Never use Intel as an
// ARM fallback: it can install successfully while every executable fails.
fn linuxBottleTag(comptime arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64_linux",
        .aarch64 => "arm64_linux",
        else => "all",
    };
}

fn linuxBottleFallbacks(comptime arch: std.Target.Cpu.Arch) []const []const u8 {
    return switch (arch) {
        .aarch64 => &.{ "aarch64_linux", "all" }, // legacy third-party tap spelling
        else => &.{"all"},
    };
}

test "Linux bottle tags keep ARM and Intel artifacts separate" {
    try testing.expectEqualStrings("arm64_linux", linuxBottleTag(.aarch64));
    try testing.expectEqualStrings("x86_64_linux", linuxBottleTag(.x86_64));
    for (linuxBottleFallbacks(.aarch64)) |tag| {
        try testing.expect(!std.mem.eql(u8, tag, "x86_64_linux"));
    }
    for (linuxBottleFallbacks(.x86_64)) |tag| {
        try testing.expect(!std.mem.eql(u8, tag, "arm64_linux"));
        try testing.expect(!std.mem.eql(u8, tag, "aarch64_linux"));
    }
    try testing.expectEqualStrings("all", linuxBottleTag(.riscv64));
}
