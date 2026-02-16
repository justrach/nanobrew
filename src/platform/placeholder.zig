// nanobrew — Shared Homebrew placeholder utilities
//
// Used by both Mach-O and ELF relocators to detect and replace
// @@HOMEBREW_PREFIX@@ / @@HOMEBREW_CELLAR@@ placeholders.

const std = @import("std");
const paths = @import("paths.zig");

pub fn hasPlaceholder(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "@@HOMEBREW") != null;
}

pub fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const pass1 = try std.mem.replaceOwned(u8, alloc, input, paths.PLACEHOLDER_CELLAR, paths.REAL_CELLAR);
    defer alloc.free(pass1);
    return try std.mem.replaceOwned(u8, alloc, pass1, paths.PLACEHOLDER_PREFIX, paths.REAL_PREFIX);
}

/// Scan a file for @@HOMEBREW placeholder bytes.
pub fn fileContainsPlaceholder(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    const needle = "@@HOMEBREW";
    while (true) {
        if (overlap > 0) {
            const src = buf[buf.len - overlap ..];
            std.mem.copyForwards(u8, buf[0..overlap], src);
        }
        const n = file.read(buf[overlap..]) catch return false;
        if (n == 0) break;
        const total = overlap + n;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) return true;
        overlap = @min(needle.len - 1, total);
    }
    return false;
}

/// Replace placeholders in text config files (.pc, .cmake, .la, etc.)
pub fn relocateTextFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return false;
    defer file.close();
    var buf: [1024 * 1024]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    if (n == 0) return false;
    const content = buf[0..n];

    if (std.mem.indexOf(u8, content, "@@HOMEBREW") == null) return false;

    // Replace in-place
    var result: [1024 * 1024]u8 = undefined;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < n) {
        if (i + paths.PLACEHOLDER_CELLAR.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_CELLAR.len], paths.PLACEHOLDER_CELLAR))
        {
            @memcpy(result[out_len..][0..paths.REAL_CELLAR.len], paths.REAL_CELLAR);
            out_len += paths.REAL_CELLAR.len;
            i += paths.PLACEHOLDER_CELLAR.len;
        } else if (i + paths.PLACEHOLDER_PREFIX.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_PREFIX.len], paths.PLACEHOLDER_PREFIX))
        {
            @memcpy(result[out_len..][0..paths.REAL_PREFIX.len], paths.REAL_PREFIX);
            out_len += paths.REAL_PREFIX.len;
            i += paths.PLACEHOLDER_PREFIX.len;
        } else {
            result[out_len] = content[i];
            out_len += 1;
            i += 1;
        }
    }

    // Rewrite file
    file.seekTo(0) catch return false;
    file.writeAll(result[0..out_len]) catch return false;
    file.setEndPos(out_len) catch return false;
    return true;
}

const testing = std.testing;

test "hasPlaceholder - detects HOMEBREW prefix" {
    try testing.expect(hasPlaceholder("@@HOMEBREW_PREFIX@@/lib/libfoo.dylib"));
    try testing.expect(hasPlaceholder("@@HOMEBREW_CELLAR@@/ffmpeg/7.1/lib/libavcodec.dylib"));
}

test "hasPlaceholder - rejects normal paths" {
    try testing.expect(!hasPlaceholder("/usr/lib/libSystem.B.dylib"));
    try testing.expect(!hasPlaceholder("/opt/nanobrew/prefix/lib/libfoo.dylib"));
    try testing.expect(!hasPlaceholder(""));
}

test "replacePlaceholders - PREFIX" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_PREFIX@@/lib/libz.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/lib/libz.dylib", result);
}

test "replacePlaceholders - CELLAR" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_CELLAR@@/ffmpeg/7.1/lib/libavcodec.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/ffmpeg/7.1/lib/libavcodec.dylib", result);
}

test "replacePlaceholders - both in one string" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_CELLAR@@/x265/4.0/lib:@@HOMEBREW_PREFIX@@/lib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/x265/4.0/lib:/opt/nanobrew/prefix/lib", result);
}
