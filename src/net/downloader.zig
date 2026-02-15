// nanobrew — Native HTTP bottle downloader (zero curl subprocess spawns)
//
// Downloads bottle tarballs from Homebrew GHCR.
// Features:
//   - Native Zig HTTP client (no curl fork/exec overhead)
//   - Streaming SHA256 verification (hashed reader — single pass)
//   - Atomic writes (tmp -> rename to blobs/)
//   - Skip if blob already cached
//   - GHCR token caching (4 min TTL)

const std = @import("std");
const store = @import("../store/store.zig");

const CACHE_DIR = "/opt/nanobrew/cache";
const BLOBS_DIR = CACHE_DIR ++ "/blobs";
const TMP_DIR = CACHE_DIR ++ "/tmp";

pub const DownloadRequest = struct {
    url: []const u8,
    expected_sha256: []const u8,
};

pub const PackageInfo = struct {
    url: []const u8,
    sha256: []const u8,
    name: []const u8,
    version: []const u8,
};

pub const ParallelDownloader = struct {
    alloc: std.mem.Allocator,
    queue: std.ArrayList(DownloadRequest),

    pub fn init(alloc: std.mem.Allocator) ParallelDownloader {
        return .{
            .alloc = alloc,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *ParallelDownloader) void {
        self.queue.deinit(self.alloc);
    }

    pub fn enqueue(self: *ParallelDownloader, url: []const u8, sha256: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const blob_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ BLOBS_DIR, sha256 }) catch return error.PathTooLong;
        if (fileExists(blob_path)) return;

        try self.queue.append(self.alloc, .{ .url = url, .expected_sha256 = sha256 });
    }

    pub fn downloadAll(self: *ParallelDownloader) !void {
        if (self.queue.items.len == 0) return;

        for (self.queue.items) |req| {
            try downloadOne(self.alloc, req);
        }
    }
};

pub const StreamingInstaller = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) StreamingInstaller {
        return .{ .alloc = alloc };
    }

    pub fn downloadAndExtractAll(self: *StreamingInstaller, packages: []const PackageInfo) !void {
        var to_fetch: std.ArrayList(PackageInfo) = .empty;
        defer to_fetch.deinit(self.alloc);

        for (packages) |pkg| {
            if (store.hasEntry(pkg.sha256)) continue;
            try to_fetch.append(self.alloc, pkg);
        }

        if (to_fetch.items.len == 0) return;

        var had_error = std.atomic.Value(bool).init(false);
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(self.alloc);

        for (to_fetch.items) |pkg| {
            const t = std.Thread.spawn(.{}, downloadAndExtractOne, .{ self.alloc, pkg, &had_error }) catch {
                had_error.store(true, .release);
                continue;
            };
            threads.append(self.alloc, t) catch continue;
        }
        for (threads.items) |t| {
            t.join();
        }

        if (had_error.load(.acquire)) {
            return error.DownloadExtractFailed;
        }
    }
};

fn downloadAndExtractOne(alloc: std.mem.Allocator, pkg: PackageInfo, had_error: *std.atomic.Value(bool)) void {
    var blob_buf: [512]u8 = undefined;
    const blob_path = std.fmt.bufPrint(&blob_buf, "{s}/{s}", .{ BLOBS_DIR, pkg.sha256 }) catch {
        had_error.store(true, .release);
        return;
    };

    if (!fileExists(blob_path)) {
        downloadOne(alloc, .{ .url = pkg.url, .expected_sha256 = pkg.sha256 }) catch {
            had_error.store(true, .release);
            return;
        };
    }

    store.ensureEntry(alloc, blob_path, pkg.sha256) catch {
        had_error.store(true, .release);
        return;
    };
}

const TOKEN_CACHE_DIR = "/opt/nanobrew/cache/tokens";

fn fetchGhcrToken(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) !?[]const u8 {
    const ghcr_prefix = "https://ghcr.io/v2/";
    if (!std.mem.startsWith(u8, url, ghcr_prefix)) return null;

    const after_prefix = url[ghcr_prefix.len..];
    const blobs_idx = std.mem.indexOf(u8, after_prefix, "/blobs/") orelse return null;
    const repo = after_prefix[0..blobs_idx];

    // Check token cache (4 min TTL)
    var cache_name_buf: [256]u8 = undefined;
    const cache_name = scopeToCacheName(repo, &cache_name_buf) orelse return fetchGhcrTokenUncached(alloc, client, repo);
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/{s}", .{ TOKEN_CACHE_DIR, cache_name }) catch
        return fetchGhcrTokenUncached(alloc, client, repo);

    if (readCachedToken(alloc, cache_path)) |cached| return cached;

    const token = try fetchGhcrTokenUncached(alloc, client, repo);
    if (token) |t| {
        std.fs.makeDirAbsolute(TOKEN_CACHE_DIR) catch {};
        if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
            defer file.close();
            file.writeAll(t) catch {};
        } else |_| {}
    }
    return token;
}

fn fetchGhcrTokenUncached(alloc: std.mem.Allocator, client: *std.http.Client, repo: []const u8) !?[]const u8 {
    var token_url_buf: [512]u8 = undefined;
    const token_url = std.fmt.bufPrint(&token_url_buf, "https://ghcr.io/token?scope=repository:{s}:pull", .{repo}) catch return null;

    const uri = std.Uri.parse(token_url) catch return null;
    var req = client.request(.GET, uri, .{}) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return null;
    if (response.head.status != .ok) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var reader = response.reader(&.{});
    reader.appendRemainingUnlimited(alloc, &body) catch return null;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body.items, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get("token")) |tok| {
        if (tok == .string) return alloc.dupe(u8, tok.string) catch null;
    }
    return null;
}

fn readCachedToken(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    if (age_ns > 240 * std.time.ns_per_s) return null;
    return file.readToEndAlloc(alloc, 64 * 1024) catch null;
}

fn scopeToCacheName(repo: []const u8, buf: *[256]u8) ?[]const u8 {
    if (repo.len > buf.len) return null;
    @memcpy(buf[0..repo.len], repo);
    for (buf[0..repo.len]) |*c| {
        if (c.* == '/') c.* = '_';
    }
    return buf[0..repo.len];
}

pub fn downloadOne(alloc: std.mem.Allocator, req: DownloadRequest) !void {
    var dest_path_buf: [512]u8 = undefined;
    const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ BLOBS_DIR, req.expected_sha256 }) catch return error.PathTooLong;

    // Each thread gets its own HTTP client (thread-local connections)
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    // Fetch GHCR bearer token if needed
    const token = try fetchGhcrToken(alloc, &client, req.url);
    defer if (token) |t| alloc.free(t);

    // Build auth header
    var auth_buf: [4096]u8 = undefined;
    const extra_headers: []const std.http.Header = if (token) |t| blk: {
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch break :blk &.{};
        break :blk &.{.{ .name = "Authorization", .value = auth }};
    } else &.{};

    // Download with native HTTP + streaming SHA256
    const uri = std.Uri.parse(req.url) catch return error.DownloadFailed;
    var http_req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = extra_headers,
    }) catch return error.DownloadFailed;
    defer http_req.deinit();

    http_req.sendBodiless() catch return error.DownloadFailed;

    var redirect_buf: [8192]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;

    // Stream body to tmp file with SHA256 hashing in single pass
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/{s}.dl", .{ TMP_DIR, req.expected_sha256 }) catch return error.PathTooLong;

    {
        var file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.DownloadFailed;
        var file_writer_buf: [65536]u8 = undefined;
        var file_writer = file.writer(&file_writer_buf);

        var reader = response.reader(&.{});
        var hash_buf: [65536]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var hashed = reader.hashed(&hasher, &hash_buf);

        _ = hashed.reader.streamRemaining(&file_writer.interface) catch {
            file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.DownloadFailed;
        };
        file_writer.interface.flush() catch {
            file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.DownloadFailed;
        };
        file.close();

        // Verify SHA256
        const digest = hasher.finalResult();
        const charset = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            hex[idx * 2] = charset[byte >> 4];
            hex[idx * 2 + 1] = charset[byte & 0x0f];
        }
        if (req.expected_sha256.len < 64 or !std.mem.eql(u8, &hex, req.expected_sha256[0..64])) {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.ChecksumMismatch;
        }
    }

    // Atomic rename to final path
    std.fs.renameAbsolute(tmp_path, dest_path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

const testing = std.testing;

test "scopeToCacheName - replaces slashes with underscores" {
    var buf: [256]u8 = undefined;
    const name = scopeToCacheName("homebrew/core/ffmpeg", &buf).?;
    try testing.expectEqualStrings("homebrew_core_ffmpeg", name);
}

test "scopeToCacheName - single segment unchanged" {
    var buf: [256]u8 = undefined;
    const name = scopeToCacheName("homebrew", &buf).?;
    try testing.expectEqualStrings("homebrew", name);
}

test "scopeToCacheName - repo too long returns null" {
    var buf: [256]u8 = undefined;
    const long = "a" ** 257;
    try testing.expectEqual(@as(?[]const u8, null), scopeToCacheName(long, &buf));
}
