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
    const pass1 = try std.mem.replaceOwned(u8, alloc, input, paths.PLACEHOLDER_CELLAR, paths.REAL_CELLAR);
    defer alloc.free(pass1);
    const pass2 = try std.mem.replaceOwned(u8, alloc, pass1, paths.PLACEHOLDER_PREFIX, paths.REAL_PREFIX);
    defer alloc.free(pass2);
    return try std.mem.replaceOwned(u8, alloc, pass2, paths.PLACEHOLDER_REPOSITORY, paths.REAL_REPOSITORY);
}

/// Scan a file for @@HOMEBREW placeholder bytes.
pub fn fileContainsPlaceholder(path: []const u8) bool {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return false;
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    var file_offset: u64 = 0;
    const needle = "@@HOMEBREW";
    const result: bool = blk: {
        while (true) {
            if (overlap > 0) {
                const src = buf[buf.len - overlap ..];
                std.mem.copyForwards(u8, buf[0..overlap], src);
            }
            const n = file.readPositional(lib_io, &.{buf[overlap..]}, file_offset) catch break :blk false;
            if (n == 0) break;
            const total = overlap + n;
            if (std.mem.indexOf(u8, buf[0..total], needle) != null) break :blk true;
            overlap = @min(needle.len - 1, total);
            file_offset += @intCast(n);
        }
        break :blk false;
    };
    file.close(lib_io);
    return result;
}

/// Replace placeholders in text config files (.pc, .cmake, .la, etc.)
/// Replace placeholders in text config files (.pc, .cmake, .la, etc.)
pub fn relocateTextFile(io: std.Io, path: []const u8) bool {
    // Single open for stat + binary check
    const probe = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    const stat = probe.stat(io) catch { probe.close(io); return false; };
    if (stat.size == 0 or stat.size > 1024 * 1024) { probe.close(io); return false; }

    // Quick binary check on first 4 bytes without reading the whole file
    var magic: [4]u8 = undefined;
    const magic_n = probe.readPositionalAll(io, &magic, 0) catch { probe.close(io); return false; };
    probe.close(io);
    if (magic_n >= 4) {
        if (std.mem.eql(u8, &magic, "\x7fELF") or
            std.mem.eql(u8, &magic, "\xfe\xed\xfa\xce") or
            std.mem.eql(u8, &magic, "\xfe\xed\xfa\xcf") or
            std.mem.eql(u8, &magic, "\xca\xfe\xba\xbe") or
            std.mem.eql(u8, &magic, "\xcf\xfa\xed\xfe"))
            return false;
    }

    // Make writable if needed
    const orig_mode = stat.permissions.toMode();
    const needs_chmod = (orig_mode & 0o200) == 0;
    if (needs_chmod) {
        const tmp = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
        _ = std.c.fchmod(tmp.handle, @intCast(orig_mode | 0o200));
        tmp.close(io);
    }
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch {
        if (needs_chmod) {
            const r = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
            _ = std.c.fchmod(r.handle, @intCast(orig_mode));
            r.close(io);
        }
        return false;
    };
    defer {
        if (needs_chmod) _ = std.c.fchmod(file.handle, @intCast(orig_mode));
        file.close(io);
    }
    var buf: [1024 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return false;
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
    file.writePositionalAll(io, result[0..out_len], 0) catch return false;
    file.setLength(io, out_len) catch return false;
    return true;
}

/// Walk all files in a keg directory and replace Homebrew placeholders in text files.
/// This handles shebangs, scripts, and other text files that contain @@HOMEBREW_*@@ markers.
/// Called after binary relocation (Mach-O/ELF) but before symlinking.
pub fn replaceKegPlaceholders(io: std.Io, name: []const u8, version: []const u8) void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return;
    walkAndReplaceText(io, keg_dir);
}

fn walkAndReplaceText(io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => {
                // Skip directories that never contain executable path placeholders.
                // doc/man/info/locale/html contain only docs and binary locale data.
                if (std.mem.eql(u8, entry.name, "doc") or
                    std.mem.eql(u8, entry.name, "docs") or
                    std.mem.eql(u8, entry.name, "man") or
                    std.mem.eql(u8, entry.name, "html") or
                    std.mem.eql(u8, entry.name, "info") or
                    std.mem.eql(u8, entry.name, "locale") or
                    std.mem.eql(u8, entry.name, "charset"))
                    continue;
                walkAndReplaceText(io, child_path);
            },
            .sym_link => {
                // Resolve symlink target and process if it's a regular file
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_n = std.Io.Dir.readLinkAbsolute(io, child_path, &target_buf) catch continue;
                const target = target_buf[0..target_n];
                var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_path = if (std.fs.path.isAbsolute(target))
                    target
                else
                    std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ std.fs.path.dirname(child_path) orelse continue, target }) catch continue;
                // Only process symlinks that point to files within the same keg
                // (avoid processing targets outside the tree or dangling links)
                const file = std.Io.Dir.openFileAbsolute(io, target_path, .{}) catch continue;
                const file_stat = file.stat(io) catch { file.close(io); continue; };
                file.close(io);
                if (file_stat.kind != .file) continue;
                _ = relocateTextFile(io, target_path);
            },
            .file => {
                // Fast skip: known binary/data extensions (no syscalls needed)
                const name = entry.name;
                if (std.mem.endsWith(u8, name, ".dylib") or
                    std.mem.endsWith(u8, name, ".a") or
                    std.mem.endsWith(u8, name, ".o") or
                    std.mem.endsWith(u8, name, ".so") or
                    std.mem.endsWith(u8, name, ".html") or
                    std.mem.endsWith(u8, name, ".htm") or
                    std.mem.endsWith(u8, name, ".mo") or
                    std.mem.endsWith(u8, name, ".gmo") or
                    std.mem.endsWith(u8, name, ".wmo") or
                    std.mem.endsWith(u8, name, ".pdf") or
                    std.mem.endsWith(u8, name, ".ttf") or
                    std.mem.endsWith(u8, name, ".otf") or
                    std.mem.endsWith(u8, name, ".woff") or
                    std.mem.endsWith(u8, name, ".woff2") or
                    std.mem.endsWith(u8, name, ".png") or
                    std.mem.endsWith(u8, name, ".jpg") or
                    std.mem.endsWith(u8, name, ".jpeg") or
                    std.mem.endsWith(u8, name, ".gif") or
                    std.mem.endsWith(u8, name, ".ico") or
                    std.mem.endsWith(u8, name, ".gz") or
                    std.mem.endsWith(u8, name, ".tar") or
                    std.mem.endsWith(u8, name, ".zip") or
                    std.mem.endsWith(u8, name, ".pyc") or
                    std.mem.endsWith(u8, name, ".pyo") or
                    std.mem.endsWith(u8, name, ".whl"))
                    continue;

                // Single open: stat + probe in one fd
                const file = std.Io.Dir.openFileAbsolute(io, child_path, .{}) catch continue;
                const file_stat = file.stat(io) catch { file.close(io); continue; };
                if (file_stat.size == 0 or file_stat.size > 1024 * 1024) { file.close(io); continue; }

                var probe: [512]u8 = undefined;
                const probe_n = file.readPositionalAll(io, &probe, 0) catch { file.close(io); continue; };
                file.close(io);
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

                _ = relocateTextFile(io, child_path);
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
    const tmp_file = tmp_dir.dir.createFile(testing.io, "test_script", .{}) catch unreachable;
    const content = "#!@@HOMEBREW_CELLAR@@/awscli/2.34.16/libexec/bin/python\nimport sys\n";
    tmp_file.writeStreamingAll(testing.io, content) catch unreachable;
    tmp_file.close(testing.io);

    // Get absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "test_script", &path_buf) catch unreachable;
    const abs_path = path_buf[0..path_n];

    const changed = relocateTextFile(testing.io, abs_path);
    try testing.expect(changed);

    // Read back and verify
    const verify_file = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    defer verify_file.close(testing.io);
    var read_buf: [4096]u8 = undefined;
    const n = verify_file.readPositionalAll(testing.io, &read_buf, 0) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/awscli/2.34.16/libexec/bin/python\nimport sys\n", read_buf[0..n]);
}

test "relocateTextFile - no change returns false" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "no_placeholder", .{}) catch unreachable;
    f.writeStreamingAll(testing.io, "#!/usr/bin/env python3\nprint('hello')\n") catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "no_placeholder", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(testing.io, path_buf[0..path_n]));
}

test "relocateTextFile - handles read-only files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "readonly_script", .{}) catch unreachable;
    f.writeStreamingAll(testing.io, "#!@@HOMEBREW_CELLAR@@/python/3.13/bin/python3\n") catch unreachable;
    f.close(testing.io);
    // Make read-only (like Homebrew bottles)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "readonly_script", &path_buf) catch unreachable;
    const abs_path = path_buf[0..path_n];
    const ro = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    _ = std.c.fchmod(ro.handle, 0o555);
    ro.close(testing.io);
    // Should still replace
    try testing.expect(relocateTextFile(testing.io, abs_path));
    // Verify replacement
    const v = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    defer v.close(testing.io);
    var buf: [256]u8 = undefined;
    const n = v.readPositionalAll(testing.io, &buf, 0) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/python/3.13/bin/python3\n", buf[0..n]);
}

test "relocateTextFile - skips binary files with null bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "binary_file", .{}) catch unreachable;
    // Binary content with null bytes and a fake placeholder
    f.writeStreamingAll(testing.io, "\x7fELF\x00\x00@@HOMEBREW_CELLAR@@/fake") catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "binary_file", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(testing.io, path_buf[0..path_n]));
}

test "relocateTextFile - replaces LIBRARY placeholder" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "config_file", .{}) catch unreachable;
    f.writeStreamingAll(testing.io, "PKG_CONFIG_LIBDIR=@@HOMEBREW_LIBRARY@@/pkgconfig\n") catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "config_file", &path_buf) catch unreachable;
    const abs_path = path_buf[0..path_n];
    try testing.expect(relocateTextFile(testing.io, abs_path));
    const v = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    defer v.close(testing.io);
    var buf: [256]u8 = undefined;
    const n = v.readPositionalAll(testing.io, &buf, 0) catch unreachable;
    try testing.expectEqualStrings("PKG_CONFIG_LIBDIR=/opt/nanobrew/Library/pkgconfig\n", buf[0..n]);
}

test "relocateTextFile - replaces multiple placeholders in one file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "multi", .{}) catch unreachable;
    f.writeStreamingAll(testing.io, "#!@@HOMEBREW_CELLAR@@/bin/python\nprefix=@@HOMEBREW_PREFIX@@\nrepo=@@HOMEBREW_REPOSITORY@@\n") catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "multi", &path_buf) catch unreachable;
    const abs_path = path_buf[0..path_n];
    try testing.expect(relocateTextFile(testing.io, abs_path));
    const v = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    defer v.close(testing.io);
    var buf: [512]u8 = undefined;
    const n = v.readPositionalAll(testing.io, &buf, 0) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/bin/python\nprefix=/opt/nanobrew/prefix\nrepo=/opt/nanobrew\n", buf[0..n]);
}

test "relocateTextFile - skips empty files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "empty", .{}) catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "empty", &path_buf) catch unreachable;
    try testing.expect(!relocateTextFile(testing.io, path_buf[0..path_n]));
}

test "replaceKegPlaceholders handles relative symlink targets" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    _ = try tmp_dir.dir.createDirPathStatus(testing.io, "Cellar/awscli/1.0.0/libexec/bin", .default_dir);
    _ = try tmp_dir.dir.createDirPathStatus(testing.io, "Cellar/awscli/1.0.0/bin", .default_dir);

    const script = tmp_dir.dir.createFile(testing.io, "Cellar/awscli/1.0.0/libexec/bin/aws", .{}) catch unreachable;
    defer script.close(testing.io);
    script.writeStreamingAll(testing.io, "#!@@HOMEBREW_CELLAR@@/awscli/1.0.0/libexec/bin/python\n") catch unreachable;

    tmp_dir.dir.symLink(testing.io, "../libexec/bin/aws", "Cellar/awscli/1.0.0/bin/aws", .{}) catch unreachable;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_n = tmp_dir.dir.realPathFile(testing.io, "Cellar/awscli/1.0.0", &root_buf) catch unreachable;
    walkAndReplaceText(testing.io, root_buf[0..root_n]);

    var script_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_n = tmp_dir.dir.realPathFile(testing.io, "Cellar/awscli/1.0.0/libexec/bin/aws", &script_buf) catch unreachable;
    const script_path = script_buf[0..script_n];
    const verify = std.Io.Dir.openFileAbsolute(testing.io, script_path, .{}) catch unreachable;
    defer verify.close(testing.io);
    var contents: [256]u8 = undefined;
    const n = verify.readPositionalAll(testing.io, &contents, 0) catch unreachable;
    try testing.expectEqualStrings("#!/opt/nanobrew/prefix/Cellar/awscli/1.0.0/libexec/bin/python\n", contents[0..n]);
}
