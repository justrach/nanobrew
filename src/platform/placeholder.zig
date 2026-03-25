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
    const pass2 = try std.mem.replaceOwned(u8, alloc, pass1, paths.PLACEHOLDER_PREFIX, paths.REAL_PREFIX);
    defer alloc.free(pass2);
    return try std.mem.replaceOwned(u8, alloc, pass2, paths.PLACEHOLDER_REPOSITORY, paths.REAL_REPOSITORY);
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
    // Single open for stat + binary check
    const probe = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return false;
    const stat = probe.stat() catch { probe.close(); return false; };
    if (stat.size == 0 or stat.size > 1024 * 1024) { probe.close(); return false; }

    // Quick binary check on first 4 bytes without reading the whole file
    var magic: [4]u8 = undefined;
    const magic_n = probe.read(&magic) catch { probe.close(); return false; };
    probe.close();
    if (magic_n >= 4) {
        if (std.mem.eql(u8, &magic, "\x7fELF") or
            std.mem.eql(u8, &magic, "\xfe\xed\xfa\xce") or
            std.mem.eql(u8, &magic, "\xfe\xed\xfa\xcf") or
            std.mem.eql(u8, &magic, "\xca\xfe\xba\xbe") or
            std.mem.eql(u8, &magic, "\xcf\xfa\xed\xfe"))
            return false;
    }

    // Make writable if needed
    const orig_mode = stat.mode;
    const needs_chmod = (orig_mode & 0o200) == 0;
    if (needs_chmod) {
        const tmp = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return false;
        std.posix.fchmod(tmp.handle, orig_mode | 0o200) catch { tmp.close(); return false; };
        tmp.close();
    }
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch {
        if (needs_chmod) {
            const r = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return false;
            std.posix.fchmod(r.handle, orig_mode) catch {};
            r.close();
        }
        return false;
    };
    defer {
        if (needs_chmod) std.posix.fchmod(file.handle, orig_mode) catch {};
        file.close();
    }
    var buf: [1024 * 1024]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    if (n == 0) return false;
    const content = buf[0..n];

    // Defense-in-depth: check for binary content even though walker should have filtered
    if (n >= 4) {
        const hdr = buf[0..4];
        if (std.mem.eql(u8, hdr, "\x7fELF") or
            std.mem.eql(u8, hdr, "\xfe\xed\xfa\xce") or
            std.mem.eql(u8, hdr, "\xfe\xed\xfa\xcf") or
            std.mem.eql(u8, hdr, "\xca\xfe\xba\xbe") or
            std.mem.eql(u8, hdr, "\xcf\xfa\xed\xfe"))
            return false;
    }
    if (std.mem.indexOf(u8, content[0..@min(n, 512)], &[_]u8{0}) != null) return false;
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
        } else if (i + paths.PLACEHOLDER_REPOSITORY.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_REPOSITORY.len], paths.PLACEHOLDER_REPOSITORY))
        {
            @memcpy(result[out_len..][0..paths.REAL_REPOSITORY.len], paths.REAL_REPOSITORY);
            out_len += paths.REAL_REPOSITORY.len;
            i += paths.PLACEHOLDER_REPOSITORY.len;
        } else if (i + paths.PLACEHOLDER_LIBRARY.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_LIBRARY.len], paths.PLACEHOLDER_LIBRARY))
        {
            @memcpy(result[out_len..][0..paths.REAL_LIBRARY.len], paths.REAL_LIBRARY);
            out_len += paths.REAL_LIBRARY.len;
            i += paths.PLACEHOLDER_LIBRARY.len;
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

/// Walk all files in a keg directory and replace Homebrew placeholders in text files.
/// This handles shebangs, scripts, and other text files that contain @@HOMEBREW_*@@ markers.
/// Called after binary relocation (Mach-O/ELF) but before symlinking.
pub fn replaceKegPlaceholders(name: []const u8, version: []const u8) void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return;
    walkAndReplaceText(keg_dir);
}

fn walkAndReplaceText(dir_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndReplaceText(child_path),
            .file => {
                // Fast skip: known binary extensions (no syscalls needed)
                const name = entry.name;
                if (std.mem.endsWith(u8, name, ".dylib") or
                    std.mem.endsWith(u8, name, ".a") or
                    std.mem.endsWith(u8, name, ".o") or
                    std.mem.endsWith(u8, name, ".so") or
                    std.mem.endsWith(u8, name, ".png") or
                    std.mem.endsWith(u8, name, ".jpg") or
                    std.mem.endsWith(u8, name, ".gz") or
                    std.mem.endsWith(u8, name, ".tar") or
                    std.mem.endsWith(u8, name, ".zip") or
                    std.mem.endsWith(u8, name, ".pyc") or
                    std.mem.endsWith(u8, name, ".pyo") or
                    std.mem.endsWith(u8, name, ".whl"))
                    continue;

                // Single open: stat + probe in one fd
                const file = std.fs.openFileAbsolute(child_path, .{}) catch continue;
                const file_stat = file.stat() catch { file.close(); continue; };
                if (file_stat.size == 0 or file_stat.size > 1024 * 1024) { file.close(); continue; }

                var probe: [512]u8 = undefined;
                const probe_n = file.read(&probe) catch { file.close(); continue; };
                file.close();
                if (probe_n == 0) continue;

                // Binary checks
                if (std.mem.indexOf(u8, probe[0..probe_n], &[_]u8{0}) != null) continue;
                if (probe_n >= 4) {
                    const magic = probe[0..4];
                    if (std.mem.eql(u8, magic, "\x7fELF") or
                        std.mem.eql(u8, magic, "\xfe\xed\xfa\xce") or
                        std.mem.eql(u8, magic, "\xfe\xed\xfa\xcf") or
                        std.mem.eql(u8, magic, "\xca\xfe\xba\xbe") or
                        std.mem.eql(u8, magic, "\xcf\xfa\xed\xfe"))
                        continue;
                }

                // Early exit: small files without @@HOMEBREW in first 512 bytes
                if (file_stat.size <= 512 and std.mem.indexOf(u8, probe[0..probe_n], "@@HOMEBREW") == null) continue;

                _ = relocateTextFile(child_path);
            },
            else => {},
        }
    }
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

test "replacePlaceholders - REPOSITORY" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_REPOSITORY@@/Library/Taps");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/Library/Taps", result);
}

test "relocateTextFile - replaces shebangs in text files" {
    // Create a temp file with a placeholder shebang
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = tmp_dir.dir.createFile("test_script", .{}) catch unreachable;
    const content = "#!@@HOMEBREW_CELLAR@@/awscli/2.34.16/libexec/bin/python\nimport sys\n";
    tmp_file.writeAll(content) catch unreachable;
    tmp_file.close();

    // Get absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("test_script", &path_buf) catch unreachable;

    const changed = relocateTextFile(abs_path);
    try testing.expect(changed);

    // Read back and verify
    const verify_file = std.fs.openFileAbsolute(abs_path, .{}) catch unreachable;
    defer verify_file.close();
    var read_buf: [4096]u8 = undefined;
    const n = verify_file.readAll(&read_buf) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/awscli/2.34.16/libexec/bin/python\nimport sys\n", read_buf[0..n]);
}

test "relocateTextFile - no change returns false" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("no_placeholder", .{}) catch unreachable;
    f.writeAll("#!/usr/bin/env python3\nprint('hello')\n") catch unreachable;
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("no_placeholder", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(abs_path));
}

test "relocateTextFile - handles read-only files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("readonly_script", .{}) catch unreachable;
    f.writeAll("#!@@HOMEBREW_CELLAR@@/python/3.13/bin/python3\n") catch unreachable;
    f.close();
    // Make read-only (like Homebrew bottles)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("readonly_script", &path_buf) catch unreachable;
    const ro = std.fs.openFileAbsolute(abs_path, .{}) catch unreachable;
    std.posix.fchmod(ro.handle, 0o555) catch unreachable;
    ro.close();
    // Should still replace
    try testing.expect(relocateTextFile(abs_path));
    // Verify replacement
    const v = std.fs.openFileAbsolute(abs_path, .{}) catch unreachable;
    defer v.close();
    var buf: [256]u8 = undefined;
    const n = v.readAll(&buf) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/python/3.13/bin/python3\n", buf[0..n]);
}

test "relocateTextFile - skips binary files with null bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("binary_file", .{}) catch unreachable;
    // Binary content with null bytes and a fake placeholder
    f.writeAll("\x7fELF\x00\x00@@HOMEBREW_CELLAR@@/fake") catch unreachable;
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("binary_file", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(abs_path));
}

test "relocateTextFile - replaces LIBRARY placeholder" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("config_file", .{}) catch unreachable;
    f.writeAll("PKG_CONFIG_LIBDIR=@@HOMEBREW_LIBRARY@@/pkgconfig\n") catch unreachable;
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("config_file", &path_buf) catch unreachable;
    try testing.expect(relocateTextFile(abs_path));
    const v = std.fs.openFileAbsolute(abs_path, .{}) catch unreachable;
    defer v.close();
    var buf: [256]u8 = undefined;
    const n = v.readAll(&buf) catch unreachable;
    try testing.expectEqualStrings("PKG_CONFIG_LIBDIR=/opt/nanobrew/Library/pkgconfig\n", buf[0..n]);
}

test "relocateTextFile - replaces multiple placeholders in one file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("multi", .{}) catch unreachable;
    f.writeAll("#!@@HOMEBREW_CELLAR@@/bin/python\nprefix=@@HOMEBREW_PREFIX@@\nrepo=@@HOMEBREW_REPOSITORY@@\n") catch unreachable;
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("multi", &path_buf) catch unreachable;
    try testing.expect(relocateTextFile(abs_path));
    const v = std.fs.openFileAbsolute(abs_path, .{}) catch unreachable;
    defer v.close();
    var buf: [512]u8 = undefined;
    const n = v.readAll(&buf) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/bin/python\nprefix=/opt/nanobrew/prefix\nrepo=/opt/nanobrew\n", buf[0..n]);
}

test "relocateTextFile - skips empty files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile("empty", .{}) catch unreachable;
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("empty", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(abs_path));
}
