// nanobrew — Tar/gzip extraction
//
// Extracts Homebrew bottle tarballs into the content-addressable store.
// Fast path: native std.compress.flate.Decompress + std.tar.pipeToFileSystem.
// Fallback: our own native_tar parser, which handles GNU long-name / pax /
// hardlink entries that std.tar rejects (unzip, perl, postgresql@17 use these).

const std = @import("std");
const paths = @import("../platform/paths.zig");
const store = @import("../store/store.zig");
const native_tar = @import("native_tar.zig");

const STORE_DIR = paths.STORE_DIR;

/// Extract a gzipped tar blob into the store at store/<sha256>/.
/// `io` must be threadsafe when invoked from a parallel install worker —
/// see `native_tar.extractToDir`'s docs.
pub fn extractToStore(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, sha256: []const u8) !void {
    return extractToStoreAt(alloc, io, STORE_DIR, blob_path, sha256);
}

fn extractToStoreAt(alloc: std.mem.Allocator, io: std.Io, store_dir: []const u8, blob_path: []const u8, sha256: []const u8) !void {
    const lib_io = io;
    if (!store.isValidSha256(sha256)) return error.InvalidSha256;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ store_dir, sha256 }) catch return error.PathTooLong;

    // Skip if already extracted
    std.Io.Dir.accessAbsolute(lib_io, dest_dir, .{}) catch {
        // Callers trust any existing store/<sha> as complete, so extract into a
        // private sibling and publish it with one rename: a killed run or a
        // concurrent nb never sees a half-written entry.
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_dir = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}.{d}", .{
            dest_dir, std.c.getpid(), std.Thread.getCurrentId(),
        }) catch return error.PathTooLong;
        std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {}; // left by a killed run whose pid was reused
        try std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir);
        defer std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};

        extractTarGzNative(lib_io, blob_path, tmp_dir) catch {
            // std.tar rejected something it didn't support (typically hardlinks
            // or GNU long-name headers on bottles like unzip, perl,
            // postgresql@17). Retry with our own parser, which handles both.
            std.Io.Dir.cwd().deleteTree(lib_io, tmp_dir) catch {};
            try std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir);
            try extractTarGzOwnParser(alloc, lib_io, blob_path, tmp_dir);
        };
        std.Io.Dir.renameAbsolute(tmp_dir, dest_dir, lib_io) catch |err| switch (err) {
            error.DirNotEmpty => {}, // another nb published this entry first; use it
            else => return err,
        };
        return;
    };
}

/// Native in-process extraction: open blob → flate decompress → tar write.
/// No subprocess, no fork/exec overhead. Saves ~10-20ms per package.
fn extractTarGzNative(io: std.Io, blob_path: []const u8, dest_dir: []const u8) !void {
    const blob = try std.Io.Dir.openFileAbsolute(io, blob_path, .{});
    defer blob.close(io);

    var read_buf: [65536]u8 = undefined;
    var file_reader = blob.readerStreaming(io, &read_buf);

    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&file_reader.interface, .gzip, &window);

    var dest = try std.Io.Dir.openDirAbsolute(io, dest_dir, .{});
    defer dest.close(io);

    try std.tar.pipeToFileSystem(io, dest, &decomp.reader, .{
        .mode_mode = .executable_bit_only,
    });
}

/// Fallback extraction via nanobrew's own USTAR/GNU tar parser in
/// `native_tar.zig`. Handles hardlinks, GNU long-name headers, and pax entries
/// that `std.tar.pipeToFileSystem` currently rejects. Decompresses the blob
/// into a single buffer first, then walks the archive entries.
fn extractTarGzOwnParser(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, dest_dir: []const u8) !void {
    const blob = try std.Io.Dir.openFileAbsolute(io, blob_path, .{});
    defer blob.close(io);

    var read_buf: [65536]u8 = undefined;
    var file_reader = blob.readerStreaming(io, &read_buf);

    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&file_reader.interface, .gzip, &window);

    var tar_bytes: std.ArrayList(u8) = .empty;
    defer tar_bytes.deinit(alloc);

    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch |err| return err;
        if (n == 0) break;
        try tar_bytes.appendSlice(alloc, chunk[0..n]);
    }

    const files = try native_tar.extractToDir(alloc, io, tar_bytes.items, dest_dir);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
}

const testing = std.testing;

test "extractToStore rejects invalid sha256" {
    const lib_io = paths.safe_io;
    try testing.expectError(error.InvalidSha256, extractToStore(testing.allocator, lib_io, "/tmp/blob", "invalid"));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// Extract `gz` into `root/<sha>` through a FIFO blob, which holds the
/// extractor mid-run (where a kill or a second nb would catch it). Returns
/// whether `root/<sha>` was visible then. With `rival`, another nb publishes
/// `root/<sha>` while this extraction still runs.
fn extractThroughFifo(root: []const u8, sha: []const u8, gz: []const u8, rival: bool) !bool {
    const io = testing.io;
    var fifo_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&fifo_buf, "{s}/{s}.blob", .{ root, sha });
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo.ptr, 0o600));
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    const final = try std.fmt.bufPrint(&final_buf, "{s}/{s}", .{ root, sha });
    var winner_buf: [std.fs.max_path_bytes]u8 = undefined;
    const winner = try std.fmt.bufPrint(&winner_buf, "{s}/winner", .{final});

    const Worker = struct {
        fn run(store_dir: []const u8, blob: []const u8, digest: []const u8, result: *anyerror!void) void {
            result.* = extractToStoreAt(testing.allocator, testing.io, store_dir, blob, digest);
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ root, fifo, sha, &result });
    // Opening the write end returns only once the extractor has opened the blob.
    const writer = try std.Io.Dir.openFileAbsolute(io, fifo, .{ .mode = .write_only });
    const visible = if (std.Io.Dir.accessAbsolute(io, final, .{})) |_| true else |_| false;
    const rival_result = if (rival) std.Io.Dir.cwd().createDirPath(io, winner) else {};
    const write_result = writer.writeStreamingAll(io, gz);
    writer.close(io);
    thread.join();
    try rival_result;
    try write_result;
    try result;
    return visible;
}

test "extractToStore publishes store/<sha> only after extraction completes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // Blob: gzip (one stored deflate block) around a one-file tar.
    var tar_buf: [2048]u8 = undefined;
    var tar_w: std.Io.Writer = .fixed(&tar_buf);
    var tw: std.tar.Writer = .{ .underlying_writer = &tar_w };
    try tw.writeFileBytes("pkg/1.0/hello", "hello", .{});
    try tw.finishPedantically();
    const tar_bytes = tar_w.buffered();
    var gz: [tar_buf.len + 23]u8 = undefined; // 10 header + 5 block header + 8 trailer
    @memcpy(gz[0..10], &[_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff });
    gz[10] = 1; // final stored block
    std.mem.writeInt(u16, gz[11..13], @intCast(tar_bytes.len), .little);
    std.mem.writeInt(u16, gz[13..15], ~@as(u16, @intCast(tar_bytes.len)), .little);
    @memcpy(gz[15..][0..tar_bytes.len], tar_bytes);
    const end = 15 + tar_bytes.len;
    std.mem.writeInt(u32, gz[end..][0..4], std.hash.Crc32.hash(tar_bytes), .little);
    std.mem.writeInt(u32, gz[end + 4 ..][0..4], @intCast(tar_bytes.len), .little);
    const blob = gz[0 .. end + 8];

    const sha = "ab" ** 32;
    try testing.expect(!try extractThroughFifo(root, sha, blob, false));
    try tmp.dir.access(io, sha ++ "/pkg/1.0/hello", .{});

    // A rival nb that published first wins; our copy is dropped, not merged.
    const raced = "cd" ** 32;
    try testing.expect(!try extractThroughFifo(root, raced, blob, true));
    try tmp.dir.access(io, raced ++ "/winner", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, raced ++ "/pkg", .{}));

    // No staging dir is left behind.
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp.") == null);
}
