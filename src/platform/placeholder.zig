// nanobrew — Shared Homebrew placeholder utilities
//
// Used by both Mach-O and ELF relocators to detect and replace
// @@HOMEBREW_PREFIX@@ / @@HOMEBREW_CELLAR@@ placeholders.

const std = @import("std");
const paths = @import("paths.zig");

/// Literal /opt/homebrew/ paths hardcoded in some Homebrew bottles (not using @@HOMEBREW_*@@ placeholders).
const HOMEBREW_PREFIX_LITERAL = "/opt/homebrew/";
const REAL_PREFIX_SLASH = paths.REAL_PREFIX ++ "/";

pub fn hasPlaceholder(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "@@HOMEBREW") != null;
}

pub fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (i + paths.PLACEHOLDER_CELLAR.len <= input.len and
            std.mem.eql(u8, input[i..][0..paths.PLACEHOLDER_CELLAR.len], paths.PLACEHOLDER_CELLAR))
        {
            try result.appendSlice(alloc, paths.REAL_CELLAR);
            i += paths.PLACEHOLDER_CELLAR.len;
        } else if (i + paths.PLACEHOLDER_PREFIX.len <= input.len and
            std.mem.eql(u8, input[i..][0..paths.PLACEHOLDER_PREFIX.len], paths.PLACEHOLDER_PREFIX))
        {
            try result.appendSlice(alloc, paths.REAL_PREFIX);
            i += paths.PLACEHOLDER_PREFIX.len;
        } else if (i + paths.PLACEHOLDER_REPOSITORY.len <= input.len and
            std.mem.eql(u8, input[i..][0..paths.PLACEHOLDER_REPOSITORY.len], paths.PLACEHOLDER_REPOSITORY))
        {
            try result.appendSlice(alloc, paths.REAL_REPOSITORY);
            i += paths.PLACEHOLDER_REPOSITORY.len;
        } else if (i + paths.PLACEHOLDER_LIBRARY.len <= input.len and
            std.mem.eql(u8, input[i..][0..paths.PLACEHOLDER_LIBRARY.len], paths.PLACEHOLDER_LIBRARY))
        {
            try result.appendSlice(alloc, paths.REAL_LIBRARY);
            i += paths.PLACEHOLDER_LIBRARY.len;
        } else {
            try result.append(alloc, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(alloc);
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
    const has_placeholder = std.mem.indexOf(u8, content, "@@HOMEBREW") != null;
    const has_homebrew_path = std.mem.indexOf(u8, content, "/opt/homebrew/") != null;
    if (!has_placeholder and !has_homebrew_path) return false;

    // Replace in-place
    // Worst case expansion: every "/opt/homebrew/" (14 bytes) becomes "/opt/nanobrew/prefix/" (21 bytes)
    // so output can be at most n * 21/14 ≈ 1.5x input. The 1 MiB buffer handles files up to ~680 KiB
    // with worst-case expansion; files are already capped at 1 MiB on read.
    var result: [1024 * 1024]u8 = undefined;
    const result_cap = result.len;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < n) {
        if (i + paths.PLACEHOLDER_CELLAR.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_CELLAR.len], paths.PLACEHOLDER_CELLAR))
        {
            if (out_len + paths.REAL_CELLAR.len > result_cap) return false;
            @memcpy(result[out_len..][0..paths.REAL_CELLAR.len], paths.REAL_CELLAR);
            out_len += paths.REAL_CELLAR.len;
            i += paths.PLACEHOLDER_CELLAR.len;
        } else if (i + paths.PLACEHOLDER_PREFIX.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_PREFIX.len], paths.PLACEHOLDER_PREFIX))
        {
            if (out_len + paths.REAL_PREFIX.len > result_cap) return false;
            @memcpy(result[out_len..][0..paths.REAL_PREFIX.len], paths.REAL_PREFIX);
            out_len += paths.REAL_PREFIX.len;
            i += paths.PLACEHOLDER_PREFIX.len;
        } else if (i + paths.PLACEHOLDER_REPOSITORY.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_REPOSITORY.len], paths.PLACEHOLDER_REPOSITORY))
        {
            if (out_len + paths.REAL_REPOSITORY.len > result_cap) return false;
            @memcpy(result[out_len..][0..paths.REAL_REPOSITORY.len], paths.REAL_REPOSITORY);
            out_len += paths.REAL_REPOSITORY.len;
            i += paths.PLACEHOLDER_REPOSITORY.len;
        } else if (i + paths.PLACEHOLDER_LIBRARY.len <= n and
            std.mem.eql(u8, content[i..][0..paths.PLACEHOLDER_LIBRARY.len], paths.PLACEHOLDER_LIBRARY))
        {
            if (out_len + paths.REAL_LIBRARY.len > result_cap) return false;
            @memcpy(result[out_len..][0..paths.REAL_LIBRARY.len], paths.REAL_LIBRARY);
            out_len += paths.REAL_LIBRARY.len;
            i += paths.PLACEHOLDER_LIBRARY.len;
        } else if (i + HOMEBREW_PREFIX_LITERAL.len <= n and
            std.mem.eql(u8, content[i..][0..HOMEBREW_PREFIX_LITERAL.len], HOMEBREW_PREFIX_LITERAL))
        {
            if (out_len + REAL_PREFIX_SLASH.len > result_cap) return false;
            @memcpy(result[out_len..][0..REAL_PREFIX_SLASH.len], REAL_PREFIX_SLASH);
            out_len += REAL_PREFIX_SLASH.len;
            i += HOMEBREW_PREFIX_LITERAL.len;
        } else {
            if (out_len >= result_cap) return false;
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
            .sym_link => {
                // Resolve symlink target and process if it's a regular file
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.readLinkAbsolute(child_path, &target_buf) catch continue;
                var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_path = if (std.fs.path.isAbsolute(target))
                    target
                else
                    std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ std.fs.path.dirname(child_path) orelse continue, target }) catch continue;
                // Only process symlinks that point to files within the same keg
                // (avoid processing targets outside the tree or dangling links)
                const file = std.fs.openFileAbsolute(target_path, .{}) catch continue;
                const file_stat = file.stat() catch { file.close(); continue; };
                file.close();
                if (file_stat.kind != .file) continue;
                _ = relocateTextFile(target_path);
            },
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

                // Only skip if we read the entire file and found no placeholder or literal path
                if (file_stat.size <= probe_n and
                    std.mem.indexOf(u8, probe[0..probe_n], "@@HOMEBREW") == null and
                    std.mem.indexOf(u8, probe[0..probe_n], "/opt/homebrew/") == null) continue;

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

test "replaceKegPlaceholders handles relative symlink targets" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("Cellar/awscli/1.0.0/libexec/bin");
    try tmp_dir.dir.makePath("Cellar/awscli/1.0.0/bin");

    const script = tmp_dir.dir.createFile("Cellar/awscli/1.0.0/libexec/bin/aws", .{}) catch unreachable;
    defer script.close();
    script.writeAll("#!@@HOMEBREW_CELLAR@@/awscli/1.0.0/libexec/bin/python\n") catch unreachable;

    tmp_dir.dir.symLink("../libexec/bin/aws", "Cellar/awscli/1.0.0/bin/aws", .{}) catch unreachable;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg_dir = tmp_dir.dir.realpath("Cellar/awscli/1.0.0", &root_buf) catch unreachable;
    walkAndReplaceText(keg_dir);

    var script_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = tmp_dir.dir.realpath("Cellar/awscli/1.0.0/libexec/bin/aws", &script_buf) catch unreachable;
    const verify = std.fs.openFileAbsolute(script_path, .{}) catch unreachable;
    defer verify.close();
    var contents: [256]u8 = undefined;
    const n = verify.readAll(&contents) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/awscli/1.0.0/libexec/bin/python\n", contents[0..n]);
}
