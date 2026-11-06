// nanobrew — Content-addressable store
//
// Extracted bottle contents live at:
//   /opt/nanobrew/store/<sha256>/
//
// Each entry contains the full unpacked Homebrew keg.
// The store is deduplicated: same SHA256 = same content.

const std = @import("std");
const tar = @import("../extract/tar.zig");
const paths = @import("../platform/paths.zig");

const STORE_DIR = paths.STORE_DIR;
const STORE_RELOCATED_DIR = paths.STORE_RELOCATED_DIR;
const CELLAR_DIR = paths.CELLAR_DIR;

/// Validate that sha256 is exactly 64 lowercase hex characters.
/// This prevents path traversal attacks when sha256 is used as a path component.
pub fn isValidSha256(sha256: []const u8) bool {
    if (sha256.len != 64) return false;
    for (sha256) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// Ensure a store entry exists for the given SHA256.
/// If not, extract the blob tarball into the store.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn ensureEntry(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, sha256: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    var dir_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Already extracted?
    std.Io.Dir.accessAbsolute(io, store_path, .{}) catch {
        // Need to extract
        try tar.extractToStore(alloc, io, blob_path, sha256);
        return;
    };
}

/// Check if a store entry exists.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn hasEntry(io: std.Io, sha256: []const u8) bool {
    if (!isValidSha256(sha256)) return false;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return false;
    std.Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    return true;
}

/// Get the store path for an entry.
pub fn entryPath(sha256: []const u8, buf: []u8) []const u8 {
    if (!isValidSha256(sha256)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch "";
}

/// Find the version directory contained in a raw store entry.
/// `io` must be threadsafe when called from a parallel install worker.
pub fn detectEntryVersion(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    if (!isValidSha256(sha256)) return null;

    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ STORE_DIR, sha256, name }) catch return null;

    const lib_io = io;
    var exact_buf: [512]u8 = undefined;
    const exact = std.fmt.bufPrint(&exact_buf, "{s}/{s}", .{ name_dir, version }) catch return null;
    if (std.Io.Dir.openDirAbsolute(lib_io, exact, .{})) |d| {
        var dir = d;
        dir.close(lib_io);
        return version;
    } else |_| {}

    if (std.Io.Dir.openDirAbsolute(lib_io, name_dir, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, version)) {
                if (entry.name.len == version.len or
                    (entry.name.len > version.len and entry.name[version.len] == '_'))
                {
                    if (entry.name.len <= result_buf.len) {
                        @memcpy(result_buf[0..entry.name.len], entry.name);
                        dir.close(lib_io);
                        return result_buf[0..entry.name.len];
                    }
                }
            }
        }
        dir.close(lib_io);
    } else |_| {}

    return null;
}

/// Remove a store entry (when refcount drops to 0).
pub fn removeEntry(io: std.Io, sha256: []const u8) void {
    if (!isValidSha256(sha256)) return;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return;
    std.Io.Dir.cwd().deleteTree(io, p) catch {};
}

// ── Relocated store ───────────────────────────────────────────────────────────
// After the first install of a package, the Cellar keg has all @@HOMEBREW_*@@
// placeholders replaced and Mach-O load commands fixed. We clonefile that
// already-processed tree into store-relocated/<sha256>/ so subsequent reinstalls
// can skip both text-scan and install_name_tool entirely.

/// Relocation schema stamped into every snapshot. Bump when the relocation
/// pipeline changes in a way that invalidates previously saved snapshots.
/// v2: /opt/nb whole-file byte pass required, completeness-gated saves,
/// static-archive relocation (#355/#356/#357) — pre-v2 snapshots (no marker)
/// may contain foreign-prefix payloads and are treated as absent, so the
/// next reinstall re-relocates and re-snapshots.
const RELOCATED_SCHEMA = "2";
pub const RELOCATED_SCHEMA_FILE = ".nb-relocated-schema";

/// Check if a *valid* post-relocation snapshot exists for this blob: the
/// directory must exist and carry the current relocation schema marker.
pub fn hasRelocatedEntry(io: std.Io, sha256: []const u8) bool {
    if (!isValidSha256(sha256)) return false;

    var buf: [600]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ STORE_RELOCATED_DIR, sha256, RELOCATED_SCHEMA_FILE }) catch return false;
    const file = std.Io.Dir.openFileAbsolute(io, marker, .{}) catch return false;
    var content: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &content, 0) catch {
        file.close(io);
        return false;
    };
    file.close(io);
    const schema = std.mem.trim(u8, content[0..n], " \t\r\n");
    return std.mem.eql(u8, schema, RELOCATED_SCHEMA);
}

/// Snapshot the already-relocated keg from Cellar into store-relocated/<sha256>/.
/// Called once after a successful relocate+placeholder pass.
/// Uses APFS clonefile so this is near-instantaneous and zero marginal disk cost.
/// Layout: store-relocated/<sha256>/ contains the full keg tree directly.
pub fn saveRelocatedEntry(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    // src = Cellar/<name>/<version>/  (already fully relocated)
    var src_buf: [512:0]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;
    src_buf[src_dir.len] = 0;

    // dest = store-relocated/<sha256>/
    var dest_buf: [512:0]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return error.PathTooLong;
    dest_buf[dest_dir.len] = 0;

    // Already saved (concurrent installs, or we're upgrading)
    if (std.Io.Dir.accessAbsolute(io, dest_dir, .{})) {
        // Valid current-schema snapshot: nothing to do. A marker-less or
        // old-schema snapshot may hold foreign-prefix payload — replace it
        // with the freshly relocated keg instead of keeping it forever (#356).
        if (hasRelocatedEntry(io, sha256)) return;
        std.Io.Dir.cwd().deleteTree(io, dest_dir) catch return error.StaleSnapshotRemovalFailed;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    std.Io.Dir.createDirAbsolute(io, STORE_RELOCATED_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // cloneTree from Cellar → store-relocated (APFS copy-on-write, ~0ms on APFS)
    const copy = @import("../platform/copy.zig");
    if (!copy.cloneTree(&src_buf, &dest_buf)) {
        // Fallback path uses std.process.run; passing the caller's io is
        // required under Zig 0.16 (see issue #276).
        try copy.cpFallback(io, src_dir, dest_dir);
    }

    // Stamp the relocation schema so hasRelocatedEntry can reject snapshots
    // produced by older/incompatible relocation pipelines (#356). A snapshot
    // without a readable marker is worse than none, so delete it on failure.
    writeSchemaMarker(io, dest_dir) catch |err| {
        std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};
        return err;
    };
}

fn writeSchemaMarker(io: std.Io, dest_dir: []const u8) !void {
    var marker_buf: [600]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{ dest_dir, RELOCATED_SCHEMA_FILE }) catch return error.PathTooLong;
    const file = try std.Io.Dir.createFileAbsolute(io, marker, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, RELOCATED_SCHEMA ++ "\n");
}

/// Materialize a package from store-relocated/<sha256>/ into Cellar/<name>/<version>/.
/// This is the fast reinstall path: no relocation needed.
pub fn materializeFromRelocated(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    return materializeFromRelocatedAt(io, STORE_RELOCATED_DIR, CELLAR_DIR, sha256, name, version);
}

fn materializeFromRelocatedAt(io: std.Io, relocated_dir: []const u8, cellar_dir: []const u8, sha256: []const u8, name: []const u8, version: []const u8) !void {
    if (!isValidSha256(sha256)) return error.InvalidSha256;

    // src = store-relocated/<sha256>/
    var src_buf: [512]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ relocated_dir, sha256 }) catch return error.PathTooLong;

    // dest = Cellar/<name>/<version>/
    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ cellar_dir, name, version }) catch return error.PathTooLong;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ cellar_dir, name }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Fresh reinstall: the existing keg is parked, not deleted, until the
    // install is done (cellar.settlePrevious).
    try @import("../cellar/cellar.zig").replaceKeg(io, src_dir, dest_dir);

    // The schema marker is snapshot bookkeeping — keep it out of the keg.
    var marker_buf: [600]u8 = undefined;
    if (std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{ dest_dir, RELOCATED_SCHEMA_FILE })) |marker| {
        std.Io.Dir.deleteFileAbsolute(io, marker) catch {};
    } else |_| {}
}

/// Return store-relocated path for an entry.
pub fn relocatedEntryPath(sha256: []const u8, buf: []u8) []const u8 {
    if (!isValidSha256(sha256)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch "";
}

/// Remove the post-relocation snapshot for a sha256.
pub fn removeRelocatedEntry(io: std.Io, sha256: []const u8) void {
    if (!isValidSha256(sha256)) return;

    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_RELOCATED_DIR, sha256 }) catch return;
    std.Io.Dir.cwd().deleteTree(io, p) catch {};
}

const testing = std.testing;

test "entryPath - formats store path correctly" {
    var buf: [512]u8 = undefined;
    const valid_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const p = entryPath(valid_sha, &buf);
    try testing.expectEqualStrings("/opt/nanobrew/store/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", p);
}

test "entryPath - invalid sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("", &buf);
    try testing.expectEqualStrings("", p);
}

test "entryPath - path traversal sha returns empty string" {
    var buf: [512]u8 = undefined;
    const p = entryPath("../../etc/passwd", &buf);
    try testing.expectEqualStrings("", p);
}

test "materializeFromRelocated - failed copy keeps the existing same-version keg" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "Cellar/foo/1.0/bin");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "Cellar/foo/1.0/bin/foo", .data = "old" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp_dir.dir.realPathFile(io, ".", &base_buf)];
    var reloc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const reloc_dir = try std.fmt.bufPrint(&reloc_buf, "{s}/store-relocated", .{base});
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cellar_dir = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{base});

    // The snapshot is missing, so the clone and the cp fallback both fail.
    const sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try testing.expectError(error.CopyFailed, materializeFromRelocatedAt(io, reloc_dir, cellar_dir, sha, "foo", "1.0"));

    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("old", try tmp_dir.dir.readFile(io, "Cellar/foo/1.0/bin/foo", &out));
}
