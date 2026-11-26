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
const paths = @import("../platform/paths.zig");

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
    // Check 8 bytes at a time for speed. readInt performs unaligned loads,
    // so this is safe for caller-provided buffers of any alignment (the old
    // @alignCast to *const u64 panicked on align-1 tar data).
    var i: usize = 0;
    while (i < BLOCK_SIZE) : (i += 8) {
        if (std.mem.readInt(u64, block[i..][0..8], .little) != 0) return false;
    }
    return true;
}

/// Check that a symlink/hardlink target, when resolved relative to the
/// link's location within dest_dir, does not escape dest_dir.
pub fn isLinkTargetSafe(link_name: []const u8, link_target: []const u8, dest_dir: []const u8) bool {
    _ = dest_dir; // Only used conceptually; we track depth arithmetically
    // Absolute targets always escape
    if (link_target.len > 0 and link_target[0] == '/') return false;
    // Reject null bytes
    if (std.mem.indexOfScalar(u8, link_target, 0) != null) return false;

    // Compute the depth of the link's parent directory within dest_dir
    // link_name = "usr/bin/link" => parent has depth 2 (usr, bin)
    var depth: i32 = 0;
    var name_components = std.mem.splitScalar(u8, link_name, '/');
    while (name_components.next()) |_| {
        depth += 1;
    }
    depth -= 1; // subtract the filename itself — we want the directory depth

    // Walk the target components
    var target_components = std.mem.splitScalar(u8, link_target, '/');
    while (target_components.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) {
            depth -= 1;
            if (depth < 0) return false; // escaped dest_dir
        } else if (comp.len > 0 and !std.mem.eql(u8, comp, ".")) {
            depth += 1;
        }
    }
    return true;
}

/// Validate that a path is safe (no ".." traversal, no absolute escape).
/// Matches the existing isPathSafe() contract in deb/extract.zig.
pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    // Reject absolute paths that escape the destination
    if (path[0] == '/') return false;
    // Reject null bytes — OS-level path truncation can bypass component checks
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
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

/// Parse a pax extended-header data block: repeated
/// "<decimal len> <key>=<value>\n" records where len counts the whole record
/// (digits, space, key=value and newline). `path` fills `pax_path` and
/// `linkpath` fills `pax_link` (owned by the caller; previous values freed).
/// Other keys are ignored. bsdtar emits these for paths that do not fit the
/// ustar name/prefix fields.
fn parsePaxRecords(alloc: std.mem.Allocator, data: []const u8, pax_path: *?[]u8, pax_link: *?[]u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const sp = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.MalformedPaxHeader;
        const len = std.fmt.parseUnsigned(usize, data[pos..sp], 10) catch return error.MalformedPaxHeader;
        if (len < 2 or len > data.len - pos) return error.MalformedPaxHeader;
        if (data[pos + len - 1] != '\n') return error.MalformedPaxHeader;
        const record = data[sp + 1 .. pos + len - 1];
        const eq = std.mem.indexOfScalar(u8, record, '=') orelse return error.MalformedPaxHeader;
        const key = record[0..eq];
        const value = record[eq + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            if (pax_path.*) |old| alloc.free(old);
            pax_path.* = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "linkpath")) {
            if (pax_link.*) |old| alloc.free(old);
            pax_link.* = try alloc.dupe(u8, value);
        }
        pos += len;
    }
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
    var pax_path: ?[]u8 = null;
    var pax_link: ?[]u8 = null;
    defer if (gnu_long_name) |n| alloc.free(n);
    defer if (pax_path) |n| alloc.free(n);
    defer if (pax_link) |n| alloc.free(n);

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
            const raw_name = tar_data[pos .. pos + file_size];
            const name_end = std.mem.indexOfScalar(u8, raw_name, 0) orelse file_size;
            if (gnu_long_name) |old| alloc.free(old);
            gnu_long_name = try alloc.dupe(u8, raw_name[0..name_end]);
            pos += name_blocks;
            continue;
        }

        // pax extended headers carry the next entry's real path/linkpath
        if (typeflag == TypeFlag.pax_extended) {
            pos += BLOCK_SIZE;
            if (pos + file_size > tar_data.len) return error.TruncatedArchive;
            try parsePaxRecords(alloc, tar_data[pos .. pos + file_size], &pax_path, &pax_link);
            pos += alignToBlock(file_size);
            continue;
        }

        // Skip pax global headers and GNU long link names
        if (typeflag == TypeFlag.pax_global or typeflag == TypeFlag.gnu_long_link) {
            pos += BLOCK_SIZE;
            pos += alignToBlock(file_size);
            if (gnu_long_name) |old| {
                alloc.free(old);
                gnu_long_name = null;
            }
            continue;
        }

        // Resolve entry name: pax path > GNU long name > ustar prefix+name
        var name_buf: [512]u8 = undefined;
        const raw_name = if (pax_path) |pp| pp else if (gnu_long_name) |ln| ln else buildFullName(header, &name_buf);
        const entry_name = normalizePath(raw_name);

        pos += BLOCK_SIZE;

        // Consume long names / pax records once the entry is handled —
        // entry_name may slice into them (testing.allocator poisons freed
        // memory, so freeing before use corrupts the path).
        {
            defer {
                if (gnu_long_name) |old| {
                    alloc.free(old);
                    gnu_long_name = null;
                }
                if (pax_path) |old| {
                    alloc.free(old);
                    pax_path = null;
                }
                if (pax_link) |old| {
                    alloc.free(old);
                    pax_link = null;
                }
            }

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
///
/// `io` must be threadsafe — when this is called from a parallel extract
/// worker pool (e.g. `nb install --deb` fanning out 8 workers), every
/// thread shares this `io` to do its createFile/writeStreaming/delete
/// calls. Earlier versions used `paths.safe_io`
/// here and the singleton's vtable + pipe-aggregation state would corrupt
/// under concurrent use, surfacing as `nb install --deb cowsay` SIGSEGV.
/// Always thread the caller's `g_io` through.
pub fn extractToDir(alloc: std.mem.Allocator, io: std.Io, tar_data: []const u8, dest_dir: []const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }
    var rejected: usize = 0;
    const lib_io = io;
    var pos: usize = 0;
    var gnu_long_name: ?[]const u8 = null;
    var gnu_long_link: ?[]const u8 = null;
    var pax_path: ?[]u8 = null;
    var pax_link: ?[]u8 = null;
    defer if (gnu_long_name) |n| alloc.free(n);
    defer if (gnu_long_link) |n| alloc.free(n);
    defer if (pax_path) |n| alloc.free(n);
    defer if (pax_link) |n| alloc.free(n);

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
            const raw_name = tar_data[pos .. pos + file_size];
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
            const raw_link = tar_data[pos .. pos + file_size];
            const link_end = std.mem.indexOfScalar(u8, raw_link, 0) orelse file_size;
            if (gnu_long_link) |old| alloc.free(old);
            gnu_long_link = try alloc.dupe(u8, raw_link[0..link_end]);
            pos += name_blocks;
            continue;
        }

        // pax extended headers carry the next entry's real path/linkpath
        if (typeflag == TypeFlag.pax_extended) {
            pos += BLOCK_SIZE;
            if (pos + file_size > tar_data.len) return error.TruncatedArchive;
            try parsePaxRecords(alloc, tar_data[pos .. pos + file_size], &pax_path, &pax_link);
            pos += alignToBlock(file_size);
            continue;
        }

        // Skip pax global headers (they apply to no single entry)
        if (typeflag == TypeFlag.pax_global) {
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

        // Resolve entry name and link target: pax records > GNU long > ustar
        var name_buf: [512]u8 = undefined;
        const raw_name = if (pax_path) |pp| pp else if (gnu_long_name) |ln| ln else buildFullName(header, &name_buf);
        const entry_name = normalizePath(raw_name);
        const link_target = if (pax_link) |pl| pl else if (gnu_long_link) |ll| ll else fieldStr(&header.linkname);

        pos += BLOCK_SIZE;

        // Consume long names/links / pax records once the entry is handled —
        // entry_name/link_target may slice into them.
        entry: {
            defer {
                if (gnu_long_name) |old| {
                    alloc.free(old);
                    gnu_long_name = null;
                }
                if (gnu_long_link) |old| {
                    alloc.free(old);
                    gnu_long_link = null;
                }
                if (pax_path) |old| {
                    alloc.free(old);
                    pax_path = null;
                }
                if (pax_link) |old| {
                    alloc.free(old);
                    pax_link = null;
                }
            }

            // Path safety check
            if (!isPathSafe(entry_name)) {
                rejected += 1;
                break :entry;
            }

            // Build absolute destination path
            var path_buf: [4096]u8 = undefined;
            const abs_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dest_dir, entry_name }) catch {
                break :entry;
            };

            switch (typeflag) {
                TypeFlag.directory => {
                    try makeDirRecursive(lib_io, abs_path);
                },
                TypeFlag.regular, TypeFlag.regular_alt => {
                    // Ensure parent directory exists
                    if (std.fs.path.dirname(abs_path)) |parent| {
                        try makeDirRecursive(lib_io, parent);
                    }

                    const data_end = pos + file_size;
                    if (data_end > tar_data.len) return error.TruncatedArchive;

                    // Extract file mode from header
                    const mode_val = parseOctal(&header.mode);
                    const mode: std.posix.mode_t = @intCast(mode_val & 0o0777);

                    try writeFile(lib_io, abs_path, tar_data[pos..data_end], mode);

                    try files.append(alloc, try alloc.dupe(u8, entry_name));
                },
                TypeFlag.symlink => {
                    if (!isLinkTargetSafe(entry_name, link_target, dest_dir)) {
                        break :entry; // skip unsafe symlink
                    }

                    if (std.fs.path.dirname(abs_path)) |parent| {
                        try makeDirRecursive(lib_io, parent);
                    }

                    // Remove existing file/symlink before creating
                    std.Io.Dir.deleteFileAbsolute(lib_io, abs_path) catch {};

                    // Null-terminate both strings for the C symlink call
                    path_buf[abs_path.len] = 0;
                    const abs_path_z: [*:0]const u8 = @ptrCast(abs_path.ptr);
                    var lt_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                    const lt_len = @min(link_target.len, std.fs.max_path_bytes);
                    @memcpy(lt_buf[0..lt_len], link_target[0..lt_len]);
                    lt_buf[lt_len] = 0;
                    const link_target_z: [*:0]const u8 = @ptrCast(&lt_buf);
                    if (std.c.symlink(link_target_z, abs_path_z) != 0) {
                        return error.LinkFailed;
                    }
                    try files.append(alloc, try alloc.dupe(u8, entry_name));
                },
                TypeFlag.hardlink => {
                    if (std.fs.path.dirname(abs_path)) |parent| {
                        try makeDirRecursive(lib_io, parent);
                    }

                    // Resolve the link target relative to dest_dir
                    const normalized_target = normalizePath(link_target);
                    if (!isPathSafe(normalized_target)) {
                        break :entry; // skip unsafe hardlink
                    }
                    var target_buf: [4096]u8 = undefined;
                    const abs_target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ dest_dir, normalized_target }) catch {
                        break :entry;
                    };

                    std.Io.Dir.deleteFileAbsolute(lib_io, abs_path) catch {};
                    target_buf[abs_target.len] = 0;
                    path_buf[abs_path.len] = 0;
                    const abs_target_z: [*:0]const u8 = @ptrCast(abs_target.ptr);
                    const abs_path_z2: [*:0]const u8 = @ptrCast(abs_path.ptr);
                    if (std.c.link(abs_target_z, abs_path_z2) != 0) {
                        return error.LinkFailed;
                    }
                    try files.append(alloc, try alloc.dupe(u8, entry_name));
                },
                else => {
                    // Unknown type flag — skip
                },
            }
        }

        pos += alignToBlock(file_size);
    }

    if (rejected > 0) {
        const lib_io2 = io;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "    warning: rejected {d} unsafe paths from archive\n", .{rejected}) catch msg_buf[0..0];
        std.Io.File.stderr().writeStreamingAll(lib_io2, msg) catch {};
    }

    return try files.toOwnedSlice(alloc);
}

/// Streaming variant of `extractToDir`: consumes tar bytes incrementally
/// from `reader` (already decompressed) instead of requiring the whole
/// archive in memory. Regular-file payloads stream straight to disk in
/// 64 KiB chunks, so peak memory stays bounded no matter how large the
/// unpacked archive is (perl / postgresql@17 bottles are 100s of MiB —
/// the in-memory path used to buffer all of it before writing anything).
/// Same entry semantics and path-safety rules as `extractToDir`, except
/// that no file list is returned (callers of the fallback path discarded
/// it anyway — this also drops a per-file dupe/append from the hot loop).
/// `io` must be threadsafe; see `extractToDir`'s docs.
pub fn extractFromReader(alloc: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, dest_dir: []const u8) !void {
    const lib_io = io;
    var rejected: usize = 0;
    var gnu_long_name: ?[]const u8 = null;
    var gnu_long_link: ?[]const u8 = null;
    var pax_path: ?[]u8 = null;
    var pax_link: ?[]u8 = null;
    defer if (gnu_long_name) |n| alloc.free(n);
    defer if (gnu_long_link) |n| alloc.free(n);
    defer if (pax_path) |n| alloc.free(n);
    defer if (pax_link) |n| alloc.free(n);

    var block: [BLOCK_SIZE]u8 = undefined;
    while (true) {
        const hdr_n = try reader.readSliceShort(&block);
        // Clean EOF or trailing partial block — tolerated, same as
        // extractToDir's `pos + BLOCK_SIZE <= tar_data.len` loop condition.
        if (hdr_n < BLOCK_SIZE) break;
        if (isZeroBlock(&block)) break;

        const header: *const TarHeader = @ptrCast(&block);
        const file_size = parseOctal(&header.size);
        const typeflag = header.typeflag;
        const payload_padded: u64 = (file_size + BLOCK_SIZE - 1) & ~@as(u64, BLOCK_SIZE - 1);

        // Handle GNU long name extension
        if (typeflag == TypeFlag.gnu_long_name) {
            if (file_size > 1 << 20) return error.CorruptArchive;
            const fsz: usize = @intCast(file_size);
            const raw = try alloc.alloc(u8, fsz);
            defer alloc.free(raw);
            try reader.readSliceAll(raw);
            try reader.discardAll64(payload_padded - file_size);
            const name_end = std.mem.indexOfScalar(u8, raw, 0) orelse fsz;
            if (gnu_long_name) |old| alloc.free(old);
            gnu_long_name = try alloc.dupe(u8, raw[0..name_end]);
            continue;
        }

        // Handle GNU long link name extension
        if (typeflag == TypeFlag.gnu_long_link) {
            if (file_size > 1 << 20) return error.CorruptArchive;
            const fsz: usize = @intCast(file_size);
            const raw = try alloc.alloc(u8, fsz);
            defer alloc.free(raw);
            try reader.readSliceAll(raw);
            try reader.discardAll64(payload_padded - file_size);
            const link_end = std.mem.indexOfScalar(u8, raw, 0) orelse fsz;
            if (gnu_long_link) |old| alloc.free(old);
            gnu_long_link = try alloc.dupe(u8, raw[0..link_end]);
            continue;
        }

        // pax extended headers carry the next entry's real path/linkpath
        if (typeflag == TypeFlag.pax_extended) {
            if (file_size > 1 << 20) return error.CorruptArchive;
            const fsz: usize = @intCast(file_size);
            const raw = try alloc.alloc(u8, fsz);
            defer alloc.free(raw);
            try reader.readSliceAll(raw);
            try reader.discardAll64(payload_padded - file_size);
            try parsePaxRecords(alloc, raw, &pax_path, &pax_link);
            continue;
        }

        // Skip pax global headers (they apply to no single entry)
        if (typeflag == TypeFlag.pax_global) {
            try reader.discardAll64(payload_padded);
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

        // Resolve entry name and link target: pax records > GNU long > ustar
        var name_buf: [512]u8 = undefined;
        const raw_name = if (pax_path) |pp| pp else if (gnu_long_name) |ln| ln else buildFullName(header, &name_buf);
        const entry_name = normalizePath(raw_name);
        const link_target = if (pax_link) |pl| pl else if (gnu_long_link) |ll| ll else fieldStr(&header.linkname);

        // Bytes the stream still has to skip past after this entry's
        // handler runs. Regular files consume their payload by streaming;
        // everything else leaves the full padded payload to discard.
        var payload_remaining: u64 = payload_padded;

        // Consume long names/links / pax records once the entry is handled —
        // entry_name/link_target may slice into them.
        entry: {
            defer {
                if (gnu_long_name) |old| {
                    alloc.free(old);
                    gnu_long_name = null;
                }
                if (gnu_long_link) |old| {
                    alloc.free(old);
                    gnu_long_link = null;
                }
                if (pax_path) |old| {
                    alloc.free(old);
                    pax_path = null;
                }
                if (pax_link) |old| {
                    alloc.free(old);
                    pax_link = null;
                }
            }

            // Path safety check
            if (!isPathSafe(entry_name)) {
                rejected += 1;
                break :entry;
            }

            // Build absolute destination path
            var path_buf: [4096]u8 = undefined;
            const abs_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dest_dir, entry_name }) catch {
                break :entry;
            };

            switch (typeflag) {
                TypeFlag.directory => {
                    makeDirRecursive(lib_io, abs_path) catch {};
                },
                TypeFlag.regular, TypeFlag.regular_alt => {
                    // Ensure parent directory exists
                    if (std.fs.path.dirname(abs_path)) |parent| {
                        makeDirRecursive(lib_io, parent) catch {};
                    }

                    // Extract file mode from header
                    const mode_val = parseOctal(&header.mode);
                    const mode: std.posix.mode_t = @intCast(mode_val & 0o0777);

                    // Stream the payload straight to disk. A create failure
                    // (permissions, etc.) leaves the stream untouched at the
                    // payload start so we can skip the entry exactly like
                    // extractToDir does; a mid-stream failure is fatal — the
                    // archive and filesystem are out of sync either way.
                    const wrote = try writeFileStreaming(lib_io, abs_path, reader, file_size, mode);
                    payload_remaining = if (wrote) payload_padded - file_size else payload_padded;
                },
                TypeFlag.symlink => {
                    if (isLinkTargetSafe(entry_name, link_target, dest_dir)) {
                        if (std.fs.path.dirname(abs_path)) |parent| {
                            makeDirRecursive(lib_io, parent) catch {};
                        }

                        // Remove existing file/symlink before creating
                        std.Io.Dir.deleteFileAbsolute(lib_io, abs_path) catch {};

                        // Null-terminate both strings for the C symlink call
                        path_buf[abs_path.len] = 0;
                        const abs_path_z: [*:0]const u8 = @ptrCast(abs_path.ptr);
                        var lt_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                        const lt_len = @min(link_target.len, std.fs.max_path_bytes);
                        @memcpy(lt_buf[0..lt_len], link_target[0..lt_len]);
                        lt_buf[lt_len] = 0;
                        const link_target_z: [*:0]const u8 = @ptrCast(&lt_buf);
                        _ = std.c.symlink(link_target_z, abs_path_z);
                    }
                },
                TypeFlag.hardlink => {
                    if (std.fs.path.dirname(abs_path)) |parent| {
                        makeDirRecursive(lib_io, parent) catch {};
                    }

                    // Resolve the link target relative to dest_dir
                    const normalized_target = normalizePath(link_target);
                    if (isPathSafe(normalized_target)) {
                        var target_buf: [4096]u8 = undefined;
                        if (std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ dest_dir, normalized_target })) |abs_target| {
                            std.Io.Dir.deleteFileAbsolute(lib_io, abs_path) catch {};
                            target_buf[abs_target.len] = 0;
                            path_buf[abs_path.len] = 0;
                            const abs_target_z: [*:0]const u8 = @ptrCast(abs_target.ptr);
                            const abs_path_z2: [*:0]const u8 = @ptrCast(abs_path.ptr);
                            _ = std.c.link(abs_target_z, abs_path_z2);
                        } else |_| {}
                    }
                },
                else => {
                    // Unknown type flag — skip
                },
            }
        }

        if (payload_remaining > 0) try reader.discardAll64(payload_remaining);
    }

    if (rejected > 0) {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "    warning: rejected {d} unsafe paths from archive\n", .{rejected}) catch msg_buf[0..0];
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
    }
}

/// Create a file and stream `size` bytes from `reader` into it. Returns
/// `false` (with the reader untouched) if the file could not be created;
/// mid-stream failures are errors since the payload can no longer be
/// skipped cleanly.
fn writeFileStreaming(io: std.Io, path: []const u8, reader: *std.Io.Reader, size: u64, mode: std.posix.mode_t) !bool {
    const lib_io = io;
    const perms: std.Io.File.Permissions = std.Io.File.Permissions.fromMode(mode);
    const file = std.Io.Dir.createFileAbsolute(lib_io, path, .{ .permissions = perms }) catch return false;
    defer file.close(lib_io);
    var buf: [65536]u8 = undefined;
    var file_writer = file.writer(lib_io, &buf);
    reader.streamExact64(&file_writer.interface, size) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedArchive,
        else => |e| return e,
    };
    try file_writer.interface.flush();
    return true;
}

/// Create a file with the given content and mode.
/// `io` must be threadsafe; see `extractToDir`'s docs.
fn writeFile(io: std.Io, path: []const u8, data: []const u8, mode: std.posix.mode_t) !void {
    const lib_io = io;
    const perms: std.Io.File.Permissions = std.Io.File.Permissions.fromMode(mode);
    const file = try std.Io.Dir.createFileAbsolute(lib_io, path, .{ .permissions = perms });
    defer file.close(lib_io);
    try file.writeStreamingAll(lib_io, data);
}

/// Recursively create directories (like mkdir -p).
/// `io` must be threadsafe; see `extractToDir`'s docs.
fn makeDirRecursive(io: std.Io, path: []const u8) !void {
    const lib_io = io;
    std.Io.Dir.createDirAbsolute(lib_io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist — create it first
            if (std.fs.path.dirname(path)) |parent| {
                try makeDirRecursive(io, parent);
                std.Io.Dir.createDirAbsolute(lib_io, path, .default_dir) catch |e| switch (e) {
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
    var tar_data: [BLOCK_SIZE * 4]u8 = @splat(0);

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
    @memcpy(tar_data[BLOCK_SIZE .. BLOCK_SIZE + 5], "hello");

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

// Helper — write a single 512-byte USTAR header for `name` with the given
// typeflag, size, and linkname, computing the checksum. Pads `buf` to a
// full block. Used by the hardlink regression test below.
fn writeHeader(buf: *[BLOCK_SIZE]u8, name: []const u8, mode: []const u8, size: u64, typeflag: u8, linkname: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..name.len], name);
    @memcpy(buf[100 .. 100 + mode.len], mode);
    _ = std.fmt.bufPrint(buf[124..136], "{o:0>11}", .{size}) catch unreachable;
    buf[156] = typeflag;
    @memcpy(buf[157 .. 157 + linkname.len], linkname);

    // USTAR magic + version
    @memcpy(buf[257..263], "ustar\x00");
    @memcpy(buf[263..265], "00");

    // Checksum: sum of all bytes in header with the chksum field treated as spaces
    var cksum: u32 = 0;
    for (buf[0..BLOCK_SIZE], 0..) |b, i| {
        cksum += if (i >= 148 and i < 156) @as(u32, ' ') else @as(u32, b);
    }
    var cksum_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&cksum_buf, "{o:0>6}\x00 ", .{cksum}) catch unreachable;
    @memcpy(buf[148..156], &cksum_buf);
}

test "extractToDir - hardlink entry creates a link to an earlier regular file (issue #221 follow-up)" {
    // Regression test for the v0.1.191 hotfix: Homebrew bottles like unzip
    // and perl carry hardlink entries (typeflag '1') in their tarballs. The
    // previous subprocess fallback hit std.process.run OOM; now native_tar
    // is the fallback, so it must handle hardlinks correctly end-to-end.
    const alloc = testing.allocator;

    // Build a tar with: directory "bin/", regular file "bin/a" (5 bytes),
    // hardlink "bin/b" -> "bin/a", and two zero-terminator blocks.
    var tar_data: [BLOCK_SIZE * 6]u8 = @splat(0);
    writeHeader(tar_data[0..BLOCK_SIZE], "bin/", "0000755", 0, TypeFlag.directory, "");
    writeHeader(tar_data[BLOCK_SIZE .. BLOCK_SIZE * 2], "bin/a", "0000755", 5, TypeFlag.regular, "");
    @memcpy(tar_data[BLOCK_SIZE * 2 .. BLOCK_SIZE * 2 + 5], "AAAAA");
    writeHeader(tar_data[BLOCK_SIZE * 3 .. BLOCK_SIZE * 4], "bin/b", "0000755", 0, TypeFlag.hardlink, "bin/a");
    // tar_data[BLOCK_SIZE * 4 ..] already zeroed — end-of-archive marker

    // Extract into a unique temp dir
    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_buf, "/tmp/nb-test-hardlink-{d}", .{std.c.getpid()}) catch unreachable;
    // Test path: single-threaded use, the singleton is fine. The hot
    // path uses `paths.safe_io` (initialized in main) instead.
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};

    const files = try extractToDir(alloc, lib_io, &tar_data, tmp_dir);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }

    // Both bin/a (regular) and bin/b (hardlink) should be reported as extracted.
    var saw_a = false;
    var saw_b = false;
    for (files) |f| {
        if (std.mem.eql(u8, f, "bin/a")) saw_a = true;
        if (std.mem.eql(u8, f, "bin/b")) saw_b = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);

    // bin/b's contents must match bin/a (that's what a hardlink guarantees).
    var path_buf: [256]u8 = undefined;
    const b_path = std.fmt.bufPrint(&path_buf, "{s}/bin/b", .{tmp_dir}) catch unreachable;
    const b_file = try std.Io.Dir.openFileAbsolute(lib_io, b_path, .{});
    defer b_file.close(lib_io);
    var b_contents: [16]u8 = undefined;
    const n = try b_file.readPositionalAll(lib_io, &b_contents, 0);
    try testing.expectEqualStrings("AAAAA", b_contents[0..n]);
}

test "extractToDir propagates payload write failures (#367)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    // A directory at a regular-file destination fails even when tests run as root.
    try tmp.dir.createDir(io, "payload", .default_dir);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    var tar_data: [BLOCK_SIZE * 4]u8 = @splat(0);
    writeHeader(tar_data[0..BLOCK_SIZE], "payload", "0000644", 1, TypeFlag.regular, "");
    tar_data[BLOCK_SIZE] = 'x';
    if (extractToDir(testing.allocator, io, &tar_data, root_buf[0..n])) |files| {
        defer testing.allocator.free(files);
        for (files) |f| testing.allocator.free(f);
        return error.TestExpectedError;
    } else |_| {}
}

// Helper — write a pax "<len> <key>=<value>\n" record into buf, returning its
// length. len counts the whole record including the decimal digits.
fn writePaxRecord(buf: []u8, key: []const u8, value: []const u8) usize {
    var len = key.len + value.len + 3; // ' ', '=' and '\n'; digits added below
    while (true) {
        const total = key.len + value.len + 3 + std.fmt.count("{d}", .{len});
        if (total == len) break;
        len = total;
    }
    return (std.fmt.bufPrint(buf, "{d} {s}={s}\n", .{ len, key, value }) catch unreachable).len;
}

test "parsePaxRecords reads path and linkpath, rejects malformed records" {
    const alloc = testing.allocator;
    var buf: [256]u8 = undefined;
    const n = writePaxRecord(&buf, "path", "dir/some/file");
    var pax_path: ?[]u8 = null;
    var pax_link: ?[]u8 = null;
    defer if (pax_path) |p| alloc.free(p);
    defer if (pax_link) |p| alloc.free(p);
    try parsePaxRecords(alloc, buf[0..n], &pax_path, &pax_link);
    try testing.expectEqualStrings("dir/some/file", pax_path.?);
    try testing.expect(pax_link == null);

    const n2 = writePaxRecord(buf[n..], "linkpath", "other/target");
    try parsePaxRecords(alloc, buf[n .. n + n2], &pax_path, &pax_link);
    try testing.expectEqualStrings("other/target", pax_link.?);

    try testing.expectError(error.MalformedPaxHeader, parsePaxRecords(alloc, "abc", &pax_path, &pax_link));
    try testing.expectError(error.MalformedPaxHeader, parsePaxRecords(alloc, "5 x", &pax_path, &pax_link));
    try testing.expectError(error.MalformedPaxHeader, parsePaxRecords(alloc, "9 noeq\n", &pax_path, &pax_link));
    try testing.expectError(error.MalformedPaxHeader, parsePaxRecords(alloc, "99 path=x\n", &pax_path, &pax_link));
    try testing.expectError(error.MalformedPaxHeader, parsePaxRecords(alloc, "6 x=\n\n18446744073709551615 path=x\n", &pax_path, &pax_link));
}

const pax_long_component: [100]u8 = @splat('a');
const pax_long_1 = "dir/" ++ pax_long_component ++ "-enums.def";
const pax_long_2 = "dir/" ++ pax_long_component ++ "-flags.def";

// Append a pax 'x' header + record data + following entry header + payload to
// tar_data at `pos`, returning the next free offset. The entry gets `name`'s
// first 100 bytes in its ustar name field like bsdtar's truncation.
fn appendPaxEntry(tar_data: []u8, pos: usize, pax_buf: []u8, pax_path: []const u8, mode: []const u8, typeflag: u8, linkname: []const u8, payload: []const u8) usize {
    const rec_len = writePaxRecord(pax_buf, "path", pax_path);
    writeHeader(tar_data[pos..][0..BLOCK_SIZE], "PaxHeader", "0000644", rec_len, TypeFlag.pax_extended, "");
    @memcpy(tar_data[pos + BLOCK_SIZE ..][0..rec_len], pax_buf[0..rec_len]);
    var next = pos + BLOCK_SIZE + alignToBlock(rec_len);
    writeHeader(tar_data[next..][0..BLOCK_SIZE], pax_path[0..100], mode, payload.len, typeflag, linkname);
    @memcpy(tar_data[next + BLOCK_SIZE ..][0..payload.len], payload);
    next += BLOCK_SIZE + alignToBlock(payload.len);
    return next;
}

test "extractToDir - pax path header overrides truncated ustar name (issue #403)" {
    const alloc = testing.allocator;
    var pax_buf: [256]u8 = undefined;
    var tar_data: [BLOCK_SIZE * 10]u8 = @splat(0);
    // Two entries whose ustar names truncate to the SAME 100 bytes — the gcc
    // bottle's aarch64-tuning-* collision that produced AccessDenied (#403).
    const next = appendPaxEntry(&tar_data, 0, &pax_buf, pax_long_1, "0000644", TypeFlag.regular, "", "ENUMS");
    _ = appendPaxEntry(&tar_data, next, &pax_buf, pax_long_2, "0000444", TypeFlag.regular, "", "FLAGS");

    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_buf, "/tmp/nb-test-pax-{d}", .{std.c.getpid()}) catch unreachable;
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};

    const files = try extractToDir(alloc, lib_io, &tar_data, tmp_dir);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
    try testing.expectEqual(@as(usize, 2), files.len);

    var path_buf: [4096]u8 = undefined;
    var contents: [16]u8 = undefined;
    for ([_][]const u8{ pax_long_1, pax_long_2 }, [_][]const u8{ "ENUMS", "FLAGS" }) |rel, expected| {
        const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, rel }) catch unreachable;
        const f = try std.Io.Dir.openFileAbsolute(lib_io, abs, .{});
        defer f.close(lib_io);
        const n = try f.readPositionalAll(lib_io, &contents, 0);
        try testing.expectEqualStrings(expected, contents[0..n]);
    }

    // The shared 100-byte truncated name must not appear.
    const truncated = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, pax_long_1[0..100] }) catch unreachable;
    if (std.Io.Dir.accessAbsolute(lib_io, truncated, .{})) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "listFiles honors pax path" {
    const alloc = testing.allocator;
    var pax_buf: [256]u8 = undefined;
    var tar_data: [BLOCK_SIZE * 5]u8 = @splat(0);
    _ = appendPaxEntry(&tar_data, 0, &pax_buf, pax_long_1, "0000644", TypeFlag.regular, "", "X");

    const result = try listFiles(alloc, &tar_data);
    defer {
        for (result.files) |f| alloc.free(f);
        alloc.free(result.files);
    }
    try testing.expectEqual(@as(usize, 1), result.files.len);
    try testing.expectEqualStrings(pax_long_1, result.files[0]);
}

test "extractFromReader honors pax path" {
    const alloc = testing.allocator;
    var pax_buf: [256]u8 = undefined;
    var tar_data: [BLOCK_SIZE * 5]u8 = @splat(0);
    _ = appendPaxEntry(&tar_data, 0, &pax_buf, pax_long_1, "0000644", TypeFlag.regular, "", "ENUMS");

    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_buf, "/tmp/nb-test-pax-rdr-{d}", .{std.c.getpid()}) catch unreachable;
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};

    var reader = std.Io.Reader.fixed(&tar_data);
    try extractFromReader(alloc, lib_io, &reader, tmp_dir);

    var path_buf: [4096]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, pax_long_1 }) catch unreachable;
    const f = try std.Io.Dir.openFileAbsolute(lib_io, abs, .{});
    defer f.close(lib_io);
}

test "extractToDir - pax linkpath overrides header linkname for symlink" {
    const alloc = testing.allocator;
    var pax_buf: [256]u8 = undefined;
    var tar_data: [BLOCK_SIZE * 8]u8 = @splat(0);
    writeHeader(tar_data[0..BLOCK_SIZE], "lib/real.so", "0000644", 3, TypeFlag.regular, "");
    @memcpy(tar_data[BLOCK_SIZE .. BLOCK_SIZE + 3], "SO!");
    const link_path = "lib/alias.so";
    const rec_len = writePaxRecord(&pax_buf, "linkpath", "lib/real.so");
    var pos: usize = BLOCK_SIZE * 2;
    writeHeader(tar_data[pos..][0..BLOCK_SIZE], "PaxHeader", "0000644", rec_len, TypeFlag.pax_extended, "");
    @memcpy(tar_data[pos + BLOCK_SIZE ..][0..rec_len], pax_buf[0..rec_len]);
    pos += BLOCK_SIZE + alignToBlock(rec_len);
    writeHeader(tar_data[pos..][0..BLOCK_SIZE], link_path, "0000777", 0, TypeFlag.symlink, "wrong/target");

    var tmp_buf: [128]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_buf, "/tmp/nb-test-paxlink-{d}", .{std.c.getpid()}) catch unreachable;
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};

    const files = try extractToDir(alloc, lib_io, &tar_data, tmp_dir);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }

    var path_buf: [4096]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, link_path }) catch unreachable;
    const n = try std.Io.Dir.readLinkAbsolute(lib_io, abs, &link_buf);
    try testing.expectEqualStrings("lib/real.so", link_buf[0..n]);
}
