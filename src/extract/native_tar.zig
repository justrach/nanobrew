// nanobrew — Native USTAR/GNU tar parser
//
// Parses tar archives in memory (already decompressed) and extracts
// files directly to the filesystem. Replaces subprocess `tar xf`/`tar tf`.
//
// Supports:
//   - USTAR and GNU tar formats
//   - Regular files (type '0' or '\0')
//   - Directories (type '5')
//   - Symlinks (type '2') and hardlinks (type '1')
//   - GNU long name extensions (type 'L') for paths > 100 chars
//   - Path traversal protection (rejects ".." components and absolute paths)

const std = @import("std");

const BLOCK_SIZE = 512;

/// Tar header — 512-byte USTAR/GNU block
const TarHeader = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    chksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    pad: [12]u8,
};

comptime {
    if (@sizeOf(TarHeader) != BLOCK_SIZE) @compileError("TarHeader must be 512 bytes");
}

const TypeFlag = struct {
    const regular: u8 = '0';
    const regular_alt: u8 = 0; // '\0' — old tar format for regular files
    const hardlink: u8 = '1';
    const symlink: u8 = '2';
    const directory: u8 = '5';
    const gnu_long_name: u8 = 'L';
    const gnu_long_link: u8 = 'K';
    const pax_global: u8 = 'g';
    const pax_extended: u8 = 'x';
};

/// Parse an octal field from a tar header, handling NUL and space terminators.
fn parseOctal(field: []const u8) u64 {
    var result: u64 = 0;
    for (field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') break;
        result = result *% 8 +% (c - '0');
    }
    return result;
}

/// Extract a NUL-terminated string from a fixed-size field.
fn fieldStr(field: []const u8) []const u8 {
    for (field, 0..) |c, i| {
        if (c == 0) return field[0..i];
    }
    return field;
}

/// Check if a header block is all zeros (end-of-archive marker).
fn isZeroBlock(block: *const [BLOCK_SIZE]u8) bool {
    // Check 8 bytes at a time for speed
    const words: *const [BLOCK_SIZE / 8]u64 = @ptrCast(@alignCast(block));
    for (words) |w| {
        if (w != 0) return false;
    }
    return true;
}

/// Validate that a path is safe (no ".." traversal, no absolute escape).
/// Matches the existing isPathSafe() contract in deb/extract.zig.
pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    // Reject absolute paths that escape the destination
    if (path[0] == '/') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// Normalize a tar entry path: strip leading "./" prefix.
fn normalizePath(raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw, "./")) {
        const stripped = raw[2..];
        if (stripped.len == 0) return ".";
        return stripped;
    }
    return raw;
}

/// Build the full entry name from header, handling USTAR prefix field.
fn buildFullName(header: *const TarHeader, buf: *[512]u8) []const u8 {
    const prefix = fieldStr(&header.prefix);
    const name = fieldStr(&header.name);
    if (prefix.len > 0) {
        const total = std.fmt.bufPrint(buf, "{s}/{s}", .{ prefix, name }) catch return name;
        return total;
    }
    return name;
}

/// Result of listing tar contents.
pub const TarListResult = struct {
    files: [][]const u8,
    rejected: usize,
};

/// List all file paths in a tar archive (in memory).
/// Returns owned slice of owned strings. Caller frees with allocator.
/// Skips directories. Normalizes paths (strips "./").
/// Rejects paths with ".." traversal components.
pub fn listFiles(alloc: std.mem.Allocator, tar_data: []const u8) !TarListResult {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }
    var rejected: usize = 0;
    var pos: usize = 0;
    var gnu_long_name: ?[]const u8 = null;
    defer if (gnu_long_name) |n| alloc.free(n);

    while (pos + BLOCK_SIZE <= tar_data.len) {
        const block: *const [BLOCK_SIZE]u8 = @ptrCast(tar_data[pos..][0..BLOCK_SIZE]);

        // End-of-archive: two consecutive zero blocks
        if (isZeroBlock(block)) break;

        const header: *const TarHeader = @ptrCast(block);
        const file_size = parseOctal(&header.size);
        const typeflag = header.typeflag;

        // Handle GNU long name extension
        if (typeflag == TypeFlag.gnu_long_name) {
            pos += BLOCK_SIZE;
            const name_blocks = alignToBlock(file_size);
            if (pos + name_blocks > tar_data.len) return error.TruncatedArchive;
            // The long name is NUL-terminated in the data blocks
            const raw_name = tar_data[pos..pos + file_size];
            const name_end = std.mem.indexOfScalar(u8, raw_name, 0) orelse file_size;
            if (gnu_long_name) |old| alloc.free(old);
            gnu_long_name = try alloc.dupe(u8, raw_name[0..name_end]);
            pos += name_blocks;
            continue;
        }

        // Skip pax headers and GNU long link names
        if (typeflag == TypeFlag.pax_global or typeflag == TypeFlag.pax_extended or typeflag == TypeFlag.gnu_long_link) {
            pos += BLOCK_SIZE;
            pos += alignToBlock(file_size);
            if (gnu_long_name) |old| {
                alloc.free(old);
                gnu_long_name = null;
            }
            continue;
        }

        // Resolve entry name
        var name_buf: [512]u8 = undefined;
        const raw_name = if (gnu_long_name) |ln| ln else buildFullName(header, &name_buf);
        const entry_name = normalizePath(raw_name);

        // Consume the long name
        if (gnu_long_name) |old| {
            alloc.free(old);
            gnu_long_name = null;
        }

        pos += BLOCK_SIZE;

        // Only collect regular files and symlinks/hardlinks (skip dirs)
        switch (typeflag) {
            TypeFlag.regular, TypeFlag.regular_alt, TypeFlag.symlink, TypeFlag.hardlink => {
                if (isPathSafe(entry_name)) {
                    try files.append(alloc, try alloc.dupe(u8, entry_name));
                } else {
                    rejected += 1;
                }
            },
            else => {},
        }

        // Advance past file data blocks
        pos += alignToBlock(file_size);
    }

    return .{
        .files = try files.toOwnedSlice(alloc),
        .rejected = rejected,
    };
}

/// Extract all entries from a tar archive (in memory) into dest_dir.
/// Returns list of extracted file paths (relative, without leading /).
/// The tar data must already be decompressed.
pub fn extractToDir(alloc: std.mem.Allocator, tar_data: []const u8, dest_dir: []const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }
    var rejected: usize = 0;
    var pos: usize = 0;
    var gnu_long_name: ?[]const u8 = null;
    var gnu_long_link: ?[]const u8 = null;
    defer if (gnu_long_name) |n| alloc.free(n);
    defer if (gnu_long_link) |n| alloc.free(n);

    while (pos + BLOCK_SIZE <= tar_data.len) {
        const block: *const [BLOCK_SIZE]u8 = @ptrCast(tar_data[pos..][0..BLOCK_SIZE]);
        if (isZeroBlock(block)) break;

        const header: *const TarHeader = @ptrCast(block);
        const file_size = parseOctal(&header.size);
        const typeflag = header.typeflag;

        // Handle GNU long name extension
        if (typeflag == TypeFlag.gnu_long_name) {
            pos += BLOCK_SIZE;
            const name_blocks = alignToBlock(file_size);
            if (pos + name_blocks > tar_data.len) return error.TruncatedArchive;
            const raw_name = tar_data[pos..pos + file_size];
            const name_end = std.mem.indexOfScalar(u8, raw_name, 0) orelse file_size;
            if (gnu_long_name) |old| alloc.free(old);
            gnu_long_name = try alloc.dupe(u8, raw_name[0..name_end]);
            pos += name_blocks;
            continue;
        }

        // Handle GNU long link name extension
        if (typeflag == TypeFlag.gnu_long_link) {
            pos += BLOCK_SIZE;
            const name_blocks = alignToBlock(file_size);
            if (pos + name_blocks > tar_data.len) return error.TruncatedArchive;
            const raw_link = tar_data[pos..pos + file_size];
            const link_end = std.mem.indexOfScalar(u8, raw_link, 0) orelse file_size;
            if (gnu_long_link) |old| alloc.free(old);
            gnu_long_link = try alloc.dupe(u8, raw_link[0..link_end]);
            pos += name_blocks;
            continue;
        }

        // Skip pax headers
        if (typeflag == TypeFlag.pax_global or typeflag == TypeFlag.pax_extended) {
            pos += BLOCK_SIZE;
            pos += alignToBlock(file_size);
            if (gnu_long_name) |old| {
                alloc.free(old);
                gnu_long_name = null;
            }
            if (gnu_long_link) |old| {
                alloc.free(old);
                gnu_long_link = null;
            }
            continue;
        }

        // Resolve entry name and link target
        var name_buf: [512]u8 = undefined;
        const raw_name = if (gnu_long_name) |ln| ln else buildFullName(header, &name_buf);
        const entry_name = normalizePath(raw_name);
        const link_target = if (gnu_long_link) |ll| ll else fieldStr(&header.linkname);

        // Consume long name/link
        if (gnu_long_name) |old| {
            alloc.free(old);
            gnu_long_name = null;
        }
        if (gnu_long_link) |old| {
            alloc.free(old);
            gnu_long_link = null;
        }

        pos += BLOCK_SIZE;

        // Path safety check
        if (!isPathSafe(entry_name)) {
            rejected += 1;
            pos += alignToBlock(file_size);
            continue;
        }

        // Build absolute destination path
        var path_buf: [4096]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dest_dir, entry_name }) catch {
            pos += alignToBlock(file_size);
            continue;
        };

        switch (typeflag) {
            TypeFlag.directory => {
                makeDirRecursive(abs_path) catch {};
            },
            TypeFlag.regular, TypeFlag.regular_alt => {
                // Ensure parent directory exists
                if (std.fs.path.dirname(abs_path)) |parent| {
                    makeDirRecursive(parent) catch {};
                }

                const data_end = pos + file_size;
                if (data_end > tar_data.len) return error.TruncatedArchive;

                // Extract file mode from header
                const mode_val = parseOctal(&header.mode);
                const mode: std.posix.mode_t = @intCast(mode_val & 0o7777);

                writeFile(abs_path, tar_data[pos..data_end], mode) catch {
                    // Skip files we can't write (permission errors, etc.)
                    pos += alignToBlock(file_size);
                    continue;
                };

                try files.append(alloc, try alloc.dupe(u8, entry_name));
            },
            TypeFlag.symlink => {
                if (std.fs.path.dirname(abs_path)) |parent| {
                    makeDirRecursive(parent) catch {};
                }

                // Remove existing file/symlink before creating
                std.fs.deleteFileAbsolute(abs_path) catch {};

                std.posix.symlinkat(link_target, std.fs.cwd().fd, abs_path) catch {
                    pos += alignToBlock(file_size);
                    continue;
                };
                try files.append(alloc, try alloc.dupe(u8, entry_name));
            },
            TypeFlag.hardlink => {
                if (std.fs.path.dirname(abs_path)) |parent| {
                    makeDirRecursive(parent) catch {};
                }

                // Resolve the link target relative to dest_dir
                const normalized_target = normalizePath(link_target);
                var target_buf: [4096]u8 = undefined;
                const abs_target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ dest_dir, normalized_target }) catch {
                    pos += alignToBlock(file_size);
                    continue;
                };

                std.fs.deleteFileAbsolute(abs_path) catch {};
                std.posix.linkat(std.fs.cwd().fd, abs_target, std.fs.cwd().fd, abs_path, 0) catch {
                    pos += alignToBlock(file_size);
                    continue;
                };
                try files.append(alloc, try alloc.dupe(u8, entry_name));
            },
            else => {
                // Unknown type flag — skip
            },
        }

        pos += alignToBlock(file_size);
    }

    if (rejected > 0) {
        const stderr_writer = std.fs.File.stderr().deprecatedWriter();
        stderr_writer.print("    warning: rejected {d} unsafe paths from archive\n", .{rejected}) catch {};
    }

    return try files.toOwnedSlice(alloc);
}

/// Create a file with the given content and mode.
fn writeFile(path: []const u8, data: []const u8, mode: std.posix.mode_t) !void {
    const file = try std.fs.cwd().createFile(path, .{ .mode = mode });
    defer file.close();
    try file.writeAll(data);
}

/// Recursively create directories (like mkdir -p).
fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist — create it first
            if (std.fs.path.dirname(path)) |parent| {
                try makeDirRecursive(parent);
                std.fs.makeDirAbsolute(path) catch |e| switch (e) {
                    error.PathAlreadyExists => return,
                    else => return e,
                };
            } else {
                return err;
            }
        },
        else => return err,
    };
}

/// Round a size up to the next multiple of BLOCK_SIZE.
inline fn alignToBlock(size: u64) usize {
    const s: usize = @intCast(size);
    return (s + BLOCK_SIZE - 1) & ~@as(usize, BLOCK_SIZE - 1);
}

// ── Tests ──

const testing = std.testing;

test "parseOctal handles standard fields" {
    try testing.expectEqual(@as(u64, 0o644), parseOctal("0000644\x00"));
    try testing.expectEqual(@as(u64, 0o755), parseOctal("0000755\x00"));
    try testing.expectEqual(@as(u64, 0), parseOctal("0000000\x00"));
    try testing.expectEqual(@as(u64, 1234), parseOctal("00002322\x00")); // octal 2322 = 1234
}

test "parseOctal handles space-terminated fields" {
    try testing.expectEqual(@as(u64, 0o100), parseOctal("000100 \x00"));
}

test "isPathSafe rejects traversal" {
    try testing.expect(!isPathSafe("../etc/passwd"));
    try testing.expect(!isPathSafe("usr/../../../etc/shadow"));
    try testing.expect(!isPathSafe(".."));
    try testing.expect(!isPathSafe("foo/../../bar"));
    try testing.expect(!isPathSafe(""));
    try testing.expect(!isPathSafe("/absolute/path"));
}

test "isPathSafe allows normal paths" {
    try testing.expect(isPathSafe("usr/bin/hello"));
    try testing.expect(isPathSafe("usr/share/doc/package/README"));
    try testing.expect(isPathSafe("etc/ld.so.conf.d/package.conf"));
}

test "normalizePath strips leading dot-slash" {
    try testing.expectEqualStrings("usr/bin/hello", normalizePath("./usr/bin/hello"));
    try testing.expectEqualStrings(".", normalizePath("./"));
    try testing.expectEqualStrings("foo", normalizePath("foo"));
}

test "alignToBlock rounds up correctly" {
    try testing.expectEqual(@as(usize, 0), alignToBlock(0));
    try testing.expectEqual(@as(usize, 512), alignToBlock(1));
    try testing.expectEqual(@as(usize, 512), alignToBlock(512));
    try testing.expectEqual(@as(usize, 1024), alignToBlock(513));
}

test "listFiles parses minimal tar" {
    // Build a minimal tar with one regular file entry
    var tar_data: [BLOCK_SIZE * 4]u8 = .{0} ** (BLOCK_SIZE * 4);

    // Header block for "hello.txt", 5 bytes, regular file
    const name = "hello.txt";
    @memcpy(tar_data[0..name.len], name);
    // mode
    @memcpy(tar_data[100..107], "0000644");
    // size = 5 (octal "0000005")
    @memcpy(tar_data[124..135], "00000000005");
    // typeflag = '0' (regular)
    tar_data[156] = '0';

    // Compute checksum: sum of all bytes in header, treating chksum field as spaces
    var cksum: u32 = 0;
    for (tar_data[0..BLOCK_SIZE], 0..) |b, i| {
        if (i >= 148 and i < 156) {
            cksum += ' ';
        } else {
            cksum += b;
        }
    }
    var cksum_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&cksum_buf, "{o:0>6}\x00 ", .{cksum}) catch unreachable;
    @memcpy(tar_data[148..156], &cksum_buf);

    // Data block: "hello"
    @memcpy(tar_data[BLOCK_SIZE..BLOCK_SIZE + 5], "hello");

    // Two zero blocks for end-of-archive
    // (already zeroed)

    const alloc = testing.allocator;
    const result = try listFiles(alloc, &tar_data);
    defer {
        for (result.files) |f| alloc.free(f);
        alloc.free(result.files);
    }
    try testing.expectEqual(@as(usize, 1), result.files.len);
    try testing.expectEqualStrings("hello.txt", result.files[0]);
    try testing.expectEqual(@as(usize, 0), result.rejected);
}
