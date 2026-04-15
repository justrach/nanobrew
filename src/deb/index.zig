// nanobrew — Deb Packages.gz index parser
//
// Parses the APT Packages index format (RFC 822-style key-value blocks).
// Each block describes one .deb package with: Package, Version, Depends,
// Filename, SHA256, Size fields.
//
// Uses ArenaAllocator for all string allocations — a single deinit() frees
// all parsed package data at once.

const std = @import("std");

pub const DebPackage = struct {
    name: []const u8,
    version: []const u8,
    depends: []const u8, // raw Depends: field (parsed later by resolver)
    provides: []const u8, // raw Provides: field (virtual packages this package provides)
    filename: []const u8, // e.g. "pool/main/c/curl/curl_8.5.0-2_amd64.deb"
    sha256: []const u8,
    size: u64,
    description: []const u8,

    /// Legacy per-field deinit — only needed when packages were NOT parsed via arena.
    pub fn deinit(self: DebPackage, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.depends);
        alloc.free(self.provides);
        alloc.free(self.filename);
        alloc.free(self.sha256);
        alloc.free(self.description);
    }
};

/// Result of parsing a Packages index. Owns an ArenaAllocator that backs
/// all DebPackage string fields. Call deinit() to free everything at once.
pub const ParsedIndex = struct {
    packages: []DebPackage,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedIndex) void {
        self.arena.deinit();
    }
};

/// Parse a Packages index (uncompressed text) into a list of DebPackage.
/// All string data is allocated from an internal ArenaAllocator — call
/// result.deinit() to free everything at once.
pub fn parsePackagesIndex(alloc: std.mem.Allocator, data: []const u8) !ParsedIndex {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var packages: std.ArrayList(DebPackage) = .empty;

    // Split by double newline (paragraph separator)
    var blocks = std.mem.splitSequence(u8, data, "\n\n");
    while (blocks.next()) |block| {
        if (block.len == 0) continue;
        if (parseOnePackage(arena_alloc, block)) |pkg| {
            packages.append(arena_alloc, pkg) catch continue;
        }
    }

    return .{
        .packages = packages.toOwnedSlice(arena_alloc) catch &.{},
        .arena = arena,
    };
}

fn parseOnePackage(alloc: std.mem.Allocator, block: []const u8) ?DebPackage {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var depends: []const u8 = "";
    var provides: []const u8 = "";
    var filename: ?[]const u8 = null;
    var sha256: []const u8 = "";
    var size: u64 = 0;
    var description: []const u8 = "";

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        // Skip continuation lines (start with space/tab)
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;

        if (fieldValue(line, "Package: ")) |v| {
            name = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "Version: ")) |v| {
            version = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "Depends: ")) |v| {
            depends = alloc.dupe(u8, v) catch "";
        } else if (fieldValue(line, "Provides: ")) |v| {
            provides = alloc.dupe(u8, v) catch "";
        } else if (fieldValue(line, "Filename: ")) |v| {
            filename = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "SHA256: ")) |v| {
            sha256 = alloc.dupe(u8, v) catch "";
        } else if (fieldValue(line, "Size: ")) |v| {
            size = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (fieldValue(line, "Description: ")) |v| {
            description = alloc.dupe(u8, v) catch "";
        }
    }

    const pkg_name = name orelse return null;
    const pkg_version = version orelse {
        alloc.free(pkg_name);
        return null;
    };
    const pkg_filename = filename orelse {
        alloc.free(pkg_name);
        alloc.free(pkg_version);
        return null;
    };

    return DebPackage{
        .name = pkg_name,
        .version = pkg_version,
        .depends = depends,
        .provides = provides,
        .filename = pkg_filename,
        .sha256 = sha256,
        .size = size,
        .description = description,
    };
}

fn fieldValue(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, prefix)) {
        return std.mem.trim(u8, line[prefix.len..], " \t\r");
    }
    return null;
}

/// Build the full URL for a .deb package from a mirror base URL.
pub fn debUrl(base_url: []const u8, filename: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base_url, filename }) catch "";
}

/// Build a package index into a name → DebPackage lookup map.
pub fn buildIndex(alloc: std.mem.Allocator, packages: []const DebPackage) !std.StringHashMap(DebPackage) {
    var map = std.StringHashMap(DebPackage).init(alloc);
    for (packages) |pkg| {
        map.put(pkg.name, pkg) catch continue;
    }
    return map;
}

pub fn buildProvidesMap(alloc: std.mem.Allocator, packages: []const DebPackage) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(alloc);
    for (packages) |pkg| {
        if (pkg.provides.len == 0) continue;
        // Provides: field format: "virtual1 (= ver), virtual2, ..."
        var entries = std.mem.splitScalar(u8, pkg.provides, ',');
        while (entries.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t");
            if (trimmed.len == 0) continue;
            // Strip version constraint and arch qualifier
            var vname = trimmed;
            if (std.mem.indexOf(u8, vname, " (")) |paren| {
                vname = vname[0..paren];
            }
            if (std.mem.indexOf(u8, vname, ":")) |colon| {
                vname = vname[0..colon];
            }
            vname = std.mem.trim(u8, vname, " \t");
            if (vname.len > 0) {
                // First provider wins (don't overwrite)
                if (!map.contains(vname)) {
                    map.put(vname, pkg.name) catch continue;
                }
            }
        }
    }
    return map;
}

// --- Binary index cache ---
// Serializes parsed DebPackage arrays to a compact binary format (NBIX)
// for instant deserialization on warm installs, bypassing gzip decompression
// and text parsing entirely.

const paths = @import("../platform/paths.zig");
const cache_max_age_ns: i128 = 3600 * std.time.ns_per_s; // 1 hour
const NBIX_MAGIC = [4]u8{ 'N', 'B', 'I', 'X' };
const NBIX_VERSION: u32 = 2; // v2: u32 field lengths (v1 used u16, could overflow)

fn binaryCachePath(buf: []u8, distro_id: []const u8, codename: []const u8, component: []const u8, arch: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}-{s}-{s}-{s}.nbix", .{
        paths.APT_CACHE_DIR, distro_id, codename, component, arch,
    }) catch null;
}

fn ensureCacheDir() void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.createDirAbsolute(lib_io, paths.APT_CACHE_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.Io.Dir.createDirAbsolute(lib_io, paths.CACHE_DIR, .default_dir) catch {};
            std.Io.Dir.createDirAbsolute(lib_io, paths.APT_CACHE_DIR, .default_dir) catch {};
        },
    };
}

/// Serialize a list of DebPackages to a compact binary format.
pub fn serializeIndex(alloc: std.mem.Allocator, packages: []const DebPackage) ![]u8 {
    // Calculate total size (u32 field lengths instead of u16 to avoid overflow)
    var total: usize = 4 + 4 + 4; // magic + version + count
    for (packages) |pkg| {
        total += 4 + pkg.name.len;
        total += 4 + pkg.version.len;
        total += 4 + pkg.depends.len;
        total += 4 + pkg.provides.len;
        total += 4 + pkg.filename.len;
        total += 4 + pkg.sha256.len;
        total += 8; // size u64
        total += 4 + pkg.description.len;
    }

    const buf = try alloc.alloc(u8, total);
    var pos: usize = 0;

    // Header
    @memcpy(buf[pos..][0..4], &NBIX_MAGIC);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], NBIX_VERSION, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(packages.len), .little);
    pos += 4;

    // Packages
    for (packages) |pkg| {
        inline for (.{ pkg.name, pkg.version, pkg.depends, pkg.provides, pkg.filename, pkg.sha256 }) |field| {
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(field.len), .little);
            pos += 4;
            @memcpy(buf[pos..][0..field.len], field);
            pos += field.len;
        }
        std.mem.writeInt(u64, buf[pos..][0..8], pkg.size, .little);
        pos += 8;
        // description
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(pkg.description.len), .little);
        pos += 4;
        @memcpy(buf[pos..][0..pkg.description.len], pkg.description);
        pos += pkg.description.len;
    }

    return buf;
}

/// Deserialize a binary index into a ParsedIndex. All strings are arena-owned.
/// Deserialize a binary index into a ParsedIndex. Zero-copy: strings point
/// directly into `data`. Caller transfers ownership of `data` to the returned
/// ParsedIndex — it will be freed when ParsedIndex.deinit() is called.
pub fn deserializeIndex(alloc: std.mem.Allocator, data: []const u8) !ParsedIndex {
    if (data.len < 12) return error.InvalidFormat;

    if (!std.mem.eql(u8, data[0..4], &NBIX_MAGIC)) return error.InvalidFormat;
    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version != NBIX_VERSION) return error.InvalidFormat;
    const count = std.mem.readInt(u32, data[8..12], .little);

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const packages = try a.alloc(DebPackage, count);
    var pos: usize = 12;

    for (0..count) |i| {
        var pkg: DebPackage = undefined;

        // u32 length prefix, arena-owned string copies
        inline for (.{ "name", "version", "depends", "provides", "filename", "sha256" }) |field_name| {
            if (pos + 4 > data.len) return error.InvalidFormat;
            const len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + len > data.len) return error.InvalidFormat;
            @field(pkg, field_name) = try a.dupe(u8, data[pos..][0..len]);
            pos += len;
        }

        if (pos + 8 > data.len) return error.InvalidFormat;
        pkg.size = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        if (pos + 4 > data.len) return error.InvalidFormat;
        const desc_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + desc_len > data.len) return error.InvalidFormat;
        pkg.description = try a.dupe(u8, data[pos..][0..desc_len]);
        pos += desc_len;

        packages[i] = pkg;
    }

    return .{ .packages = packages, .arena = arena };
}

/// Try to read a cached binary index. Returns ParsedIndex on hit, null on miss/stale.
pub fn readCachedBinaryIndex(alloc: std.mem.Allocator, distro_id: []const u8, codename: []const u8, component: []const u8, arch: []const u8) ?ParsedIndex {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [512]u8 = undefined;
    const cache_file = binaryCachePath(&path_buf, distro_id, codename, component, arch) orelse return null;

    const file = std.Io.Dir.openFileAbsolute(lib_io, cache_file, .{}) catch return null;
    defer file.close(lib_io);

    const stat = file.stat(lib_io) catch return null;
    const size = stat.size;
    if (size < 12 or size > 100 * 1024 * 1024) return null;

    const data = alloc.alloc(u8, @intCast(size)) catch return null;
    defer alloc.free(data);

    var offset: usize = 0;
    while (offset < data.len) {
        const n = file.readPositional(lib_io, &.{data[offset..]}, @intCast(offset)) catch return null;
        if (n == 0) break;
        offset += n;
    }
    if (offset != @as(usize, @intCast(size))) return null;

    return deserializeIndex(alloc, data) catch null;
}

/// Write a binary index cache for a given component.
pub fn writeCachedBinaryIndex(distro_id: []const u8, codename: []const u8, component: []const u8, arch: []const u8, alloc: std.mem.Allocator, packages: []const DebPackage) void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    ensureCacheDir();

    var path_buf: [512]u8 = undefined;
    const cache_file = binaryCachePath(&path_buf, distro_id, codename, component, arch) orelse return;

    const serialized = serializeIndex(alloc, packages) catch return;
    defer alloc.free(serialized);

    const file = std.Io.Dir.createFileAbsolute(lib_io, cache_file, .{}) catch return;
    defer file.close(lib_io);
    file.writeStreamingAll(lib_io, serialized) catch {};
}

/// Invalidate (delete) all cached APT index files.
pub fn invalidateCache() void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(lib_io, paths.APT_CACHE_DIR, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);

    var iter = dir.iterate();
    while (iter.next(lib_io) catch null) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(lib_io, entry.name) catch {};
        }
    }
}

const testing = std.testing;

test "buildProvidesMap - first provider wins" {
    const alloc = testing.allocator;

    var pkgs_list = [_]DebPackage{
        .{
            .name = "gcc-14",
            .version = "14.2.0",
            .depends = "",
            .provides = "c-compiler",
            .filename = "pool/main/g/gcc-14.deb",
            .sha256 = "",
            .size = 0,
            .description = "",
        },
        .{
            .name = "clang-18",
            .version = "18.1.0",
            .depends = "",
            .provides = "c-compiler",
            .filename = "pool/main/c/clang-18.deb",
            .sha256 = "",
            .size = 0,
            .description = "",
        },
    };

    var pmap = try buildProvidesMap(alloc, &pkgs_list);
    defer pmap.deinit();

    // First provider (gcc-14) should win
    try testing.expectEqualStrings("gcc-14", pmap.get("c-compiler").?);
}

test "buildProvidesMap - strips arch qualifier from provides" {
    const alloc = testing.allocator;

    var pkgs_list = [_]DebPackage{
        .{
            .name = "zlib1g",
            .version = "1.3",
            .depends = "",
            .provides = "libz1:amd64 (= 1.3)",
            .filename = "pool/main/z/zlib.deb",
            .sha256 = "",
            .size = 0,
            .description = "",
        },
    };

    var pmap = try buildProvidesMap(alloc, &pkgs_list);
    defer pmap.deinit();

    try testing.expectEqualStrings("zlib1g", pmap.get("libz1").?);
}
