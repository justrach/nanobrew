// nanobrew — shared /opt/nb short-prefix symlink + in-place byte rewriter
//
// /opt/nb → <PREFIX> is a Nix-style short prefix: every @@HOMEBREW_*@@
// placeholder replacement routed through this symlink is strictly shorter
// than the placeholder token. That is what makes in-place byte patching of
// Mach-O and ELF binaries universally valid — a replacement never grows a
// string, so no byte offset in the file ever shifts and the only post-step
// is re-signing (macOS) / nothing (Linux).
//
// Used by both the ELF relocator (Linux) and the Mach-O relocator (macOS).
// Homebrew bottles bake literal /opt/homebrew/... and @@HOMEBREW_*@@
// tokens into .rodata / __DATA (compile-time defaults like OpenSSL's
// OPENSSLDIR, git's --html-path, GIT_CONFIG_SYSTEM) which install_name_tool
// and patchelf never touch — only a whole-file in-place byte pass can, and
// only when every replacement is no longer than its source. See #347.

const std = @import("std");
const paths = @import("paths.zig");

/// Short prefix symlink target: /opt/nb → <PREFIX>. Strictly shorter than
/// every @@HOMEBREW_*@@ placeholder, which is what makes in-place binary
/// patching universally valid (replacement never grows a string).
pub const SHORT_PREFIX = "/opt/nb";
pub const SHORT_CELLAR = SHORT_PREFIX ++ "/Cellar";

const ShortLinkState = enum(u8) { unknown, ok, unavailable };
var short_link_mutex: std.Io.Mutex = .init;
var short_link_state: ShortLinkState = .unknown;

comptime {
    if (SHORT_PREFIX.len > paths.PLACEHOLDER_PREFIX.len or
        SHORT_CELLAR.len > paths.PLACEHOLDER_CELLAR.len or
        paths.REAL_REPOSITORY.len > paths.PLACEHOLDER_REPOSITORY.len)
    {
        @compileError("in-place relocation requires every short replacement to be no longer than its placeholder");
    }
}

pub const ShortPrefixStatus = enum { ok, missing, wrong_target, not_symlink };

pub const ShortPrefixCheck = struct {
    status: ShortPrefixStatus,
    /// Length of the link's current target in `target_buf` (valid for .ok and .wrong_target).
    target_len: usize = 0,
};

/// Read-only classification of the short-prefix link at `link_path` against
/// `expected_target`. On .ok/.wrong_target the link's target is left in
/// `target_buf` (length in the returned struct's `target_len`).
pub fn statusAt(io: std.Io, link_path: []const u8, expected_target: []const u8, target_buf: *[std.fs.max_path_bytes]u8) ShortPrefixCheck {
    if (std.Io.Dir.readLinkAbsolute(io, link_path, target_buf)) |n| {
        return .{
            .status = if (std.mem.eql(u8, target_buf[0..n], expected_target)) .ok else .wrong_target,
            .target_len = n,
        };
    } else |_| {}

    // Exists but isn't a symlink (a real dir/file someone put there).
    if (std.Io.Dir.accessAbsolute(io, link_path, .{})) |_| {
        return .{ .status = .not_symlink };
    } else |_| {}

    return .{ .status = .missing };
}

/// Classify the /opt/nb link against the real prefix.
pub fn status(io: std.Io, target_buf: *[std.fs.max_path_bytes]u8) ShortPrefixCheck {
    return statusAt(io, SHORT_PREFIX, paths.PREFIX, target_buf);
}

/// Ensure /opt/nb → <PREFIX> exists. Memoized per process: one readlink/
/// symlink attempt shared across install workers. Returns false when it
/// can't be created (no permission on /opt and not already present) or
/// when /opt/nb exists but is not ours — callers must then skip the
/// short-prefix rewrites that can't shrink in place and fall back.
pub fn ensureShortPrefixLink(io: std.Io) bool {
    short_link_mutex.lockUncancelable(io);
    defer short_link_mutex.unlock(io);

    switch (short_link_state) {
        .ok => return true,
        .unavailable => return false,
        .unknown => {},
    }

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, SHORT_PREFIX, &target_buf)) |n| {
        short_link_state = if (std.mem.eql(u8, target_buf[0..n], paths.PREFIX)) .ok else .unavailable;
        return short_link_state == .ok;
    } else |_| {}

    // Exists but isn't a symlink (a real dir/file someone put there) — leave it alone.
    if (std.Io.Dir.accessAbsolute(io, SHORT_PREFIX, .{})) |_| {
        short_link_state = .unavailable;
        return false;
    } else |_| {}

    if (std.c.symlink(paths.PREFIX, SHORT_PREFIX) == 0) {
        short_link_state = .ok;
        return true;
    }

    // Lost a race with a concurrent nb process? Accept its link if correct.
    if (std.Io.Dir.readLinkAbsolute(io, SHORT_PREFIX, &target_buf)) |n| {
        if (std.mem.eql(u8, target_buf[0..n], paths.PREFIX)) {
            short_link_state = .ok;
            return true;
        }
    } else |_| {}

    short_link_state = .unavailable;
    return false;
}

/// Per-thread count of files whose relocation was knowingly left incomplete
/// because /opt/nb was unavailable (.rodata fallback, skipped static
/// archives). Each install worker relocates its keg on one thread, so
/// main.zig brackets relocateKeg with reset/read to decide whether the keg
/// may be snapshot-cached or reported as successfully installed (#355/#356).
threadlocal var incomplete_file_count: usize = 0;

pub fn resetIncompleteCount() void {
    incomplete_file_count = 0;
}

pub fn incompleteCount() usize {
    return incomplete_file_count;
}

pub fn noteIncompleteFile() void {
    incomplete_file_count += 1;
}

/// Overwrite every occurrence of `needle` in `data` with `replacement`,
/// padding the freed tail bytes with '/' so the total byte length is
/// unchanged. `replacement.len` must be <= `needle.len`. The '/' padding is
/// benign for both NUL-terminated C strings (dylib IDs, rpaths, .rodata
/// compile-time defaults) and length-delimited consumers: the kernel and
/// dyld collapse consecutive slashes, and every byte offset in the binary
/// is left untouched — load-command cmdsize, section offsets, code-sign
/// code-directory hashes (re-computed by the subsequent codesign pass).
pub fn rewriteAllInPlace(data: []u8, needle: []const u8, replacement: []const u8) void {
    std.debug.assert(replacement.len <= needle.len);
    const pad = needle.len - replacement.len;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, needle)) |hit| {
        @memcpy(data[hit..][0..replacement.len], replacement);
        @memset(data[hit + replacement.len ..][0..pad], '/');
        i = hit + needle.len;
    }
}

/// Bottled payload sometimes ships without the owner-write bit (perl: 0555
/// bin/perl and libperl.dylib), so an eager read-write open fails EACCES and
/// the byte pass would silently skip exactly the files it must rewrite
/// (#347). fchmod on a read-only handle works for the owning user regardless
/// of mode, so lift the write bit for the duration of the pass. Returns true
/// when the caller must restore the original mode afterwards. Mirrors
/// platform/placeholder.zig's read-only text-file handling.
pub fn liftOwnerWrite(io: std.Io, path: []const u8, orig_mode: anytype) bool {
    if ((orig_mode & 0o200) != 0) return false;
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer f.close(io);
    return std.c.fchmod(f.handle, @intCast(orig_mode | 0o200)) == 0;
}

/// Undo liftOwnerWrite by path — the read-write handle may already be closed
/// by restore time (the install_name_tool / patchelf fallbacks rename fresh
/// files into place, so a handle's inode can be stale).
pub fn restoreMode(io: std.Io, path: []const u8, orig_mode: anytype) void {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer f.close(io);
    _ = std.c.fchmod(f.handle, @intCast(orig_mode));
}

const testing = std.testing;

test "statusAt - classifies short-prefix link states" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_n = tmp_dir.dir.realPathFile(testing.io, ".", &base_buf) catch unreachable;
    const base = base_buf[0..base_n];

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "{s}/link", .{base}) catch unreachable;
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "{s}/expected-prefix", .{base}) catch unreachable;
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other = std.fmt.bufPrint(&other_buf, "{s}/elsewhere", .{base}) catch unreachable;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Nothing at the path.
    try testing.expectEqual(ShortPrefixStatus.missing, statusAt(testing.io, link, expected, &target_buf).status);

    // Symlink to the expected target.
    std.Io.Dir.symLinkAbsolute(testing.io, expected, link, .{}) catch unreachable;
    var check = statusAt(testing.io, link, expected, &target_buf);
    try testing.expectEqual(ShortPrefixStatus.ok, check.status);
    try testing.expectEqualStrings(expected, target_buf[0..check.target_len]);

    // Symlink to a different target.
    std.Io.Dir.deleteFileAbsolute(testing.io, link) catch unreachable;
    std.Io.Dir.symLinkAbsolute(testing.io, other, link, .{}) catch unreachable;
    check = statusAt(testing.io, link, expected, &target_buf);
    try testing.expectEqual(ShortPrefixStatus.wrong_target, check.status);
    try testing.expectEqualStrings(other, target_buf[0..check.target_len]);

    // A real directory where the link belongs.
    std.Io.Dir.deleteFileAbsolute(testing.io, link) catch unreachable;
    std.Io.Dir.createDirAbsolute(testing.io, link, .default_dir) catch unreachable;
    check = statusAt(testing.io, link, expected, &target_buf);
    try testing.expectEqual(ShortPrefixStatus.not_symlink, check.status);
}
