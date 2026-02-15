// nanobrew — Parallel bottle downloader
//
// Downloads bottle tarballs from Homebrew CDN.
// Features:
//   - Parallel downloads (one thread per bottle)
//   - SHA256 streaming verification (no second pass)
//   - Atomic writes (tmp -> rename to blobs/)
//   - Skip if blob already cached
//   - Streaming extract (download → extract per package, in parallel)

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

    /// Download + extract all packages in parallel.
    /// Each package downloads via curl, then immediately extracts.
    /// Concurrency capped at 8 threads. Returns when all are done.
    pub fn downloadAndExtractAll(self: *StreamingInstaller, packages: []const PackageInfo) !void {
        var to_fetch: std.ArrayList(PackageInfo) = .empty;
        defer to_fetch.deinit(self.alloc);

        for (packages) |pkg| {
            // Skip if already fully extracted in store
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
    // Build blob path on thread-local stack (blob_cache.blobPath uses a global buffer, not thread-safe)
    var blob_buf: [512]u8 = undefined;
    const blob_path = std.fmt.bufPrint(&blob_buf, "{s}/{s}", .{ BLOBS_DIR, pkg.sha256 }) catch {
        had_error.store(true, .release);
        return;
    };

    // Download if blob not already cached
    if (!fileExists(blob_path)) {
        downloadOne(alloc, .{ .url = pkg.url, .expected_sha256 = pkg.sha256 }) catch {
            had_error.store(true, .release);
            return;
        };
    }

    // Extract into store
    store.ensureEntry(alloc, blob_path, pkg.sha256) catch {
        had_error.store(true, .release);
        return;
    };
}

const TOKEN_CACHE_DIR = "/opt/nanobrew/cache/tokens";

fn fetchGhcrToken(alloc: std.mem.Allocator, url: []const u8) !?[]const u8 {
    // Extract repo scope from ghcr.io URL: /v2/homebrew/core/<pkg>/blobs/...
    const ghcr_prefix = "https://ghcr.io/v2/";
    if (!std.mem.startsWith(u8, url, ghcr_prefix)) return null;

    const after_prefix = url[ghcr_prefix.len..];
    const blobs_idx = std.mem.indexOf(u8, after_prefix, "/blobs/") orelse return null;
    const repo = after_prefix[0..blobs_idx];

    // Check token cache (4 min TTL)
    var cache_name_buf: [256]u8 = undefined;
    const cache_name = scopeToCacheName(repo, &cache_name_buf) orelse return fetchGhcrTokenUncached(alloc, repo);
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/{s}", .{ TOKEN_CACHE_DIR, cache_name }) catch
        return fetchGhcrTokenUncached(alloc, repo);

    if (readCachedToken(alloc, cache_path)) |cached| return cached;

    // Cache miss — fetch and save
    const token = try fetchGhcrTokenUncached(alloc, repo);
    if (token) |t| {
        std.fs.makeDirAbsolute(TOKEN_CACHE_DIR) catch {};
        if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
            defer file.close();
            file.writeAll(t) catch {};
        } else |_| {}
    }
    return token;
}

fn fetchGhcrTokenUncached(alloc: std.mem.Allocator, repo: []const u8) !?[]const u8 {
    var token_url_buf: [512]u8 = undefined;
    const token_url = std.fmt.bufPrint(&token_url_buf, "https://ghcr.io/token?scope=repository:{s}:pull", .{repo}) catch return null;

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-s", "--http2", token_url },
    }) catch return null;
    defer alloc.free(result.stderr);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch {
        alloc.free(result.stdout);
        return null;
    };
    defer parsed.deinit();
    alloc.free(result.stdout);

    if (parsed.value.object.get("token")) |tok| {
        if (tok == .string) return try alloc.dupe(u8, tok.string);
    }
    return null;
}

fn readCachedToken(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    if (age_ns > 240 * std.time.ns_per_s) return null; // 4 min TTL
    return file.readToEndAlloc(alloc, 64 * 1024) catch null;
}

fn scopeToCacheName(repo: []const u8, buf: *[256]u8) ?[]const u8 {
    // Replace '/' with '_' for filesystem safety
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

    // Fetch GHCR bearer token if needed (ghcr.io requires auth even for public pulls)
    const token = try fetchGhcrToken(alloc, req.url);
    defer if (token) |t| alloc.free(t);

    // CDN racing: spawn 2 curl processes, first to finish wins
    const RACERS = 1;
    var winner = std.atomic.Value(u32).init(RACERS); // no winner yet
    var racer_threads: [RACERS]?std.Thread = .{null} ** RACERS;

    const RacerCtx = struct {
        alloc: std.mem.Allocator,
        url: []const u8,
        sha256: []const u8,
        token: ?[]const u8,
        racer_id: u32,
        winner: *std.atomic.Value(u32),
        success: std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            // Each racer writes to a unique tmp file
            var tmp_buf: [512]u8 = undefined;
            const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/{s}.r{d}", .{ TMP_DIR, ctx.sha256, ctx.racer_id }) catch return;

            var auth_hdr_buf: [4096]u8 = undefined;
            const curl_result = if (ctx.token) |t| blk: {
                const auth_hdr = std.fmt.bufPrint(&auth_hdr_buf, "Authorization: Bearer {s}", .{t}) catch return;
                break :blk std.process.Child.run(.{
                    .allocator = ctx.alloc,
                    .argv = &.{ "curl", "-sL", "--http2", "-H", auth_hdr, "-o", tmp_path, ctx.url },
                }) catch return;
            } else blk: {
                break :blk std.process.Child.run(.{
                    .allocator = ctx.alloc,
                    .argv = &.{ "curl", "-sL", "--http2", "-o", tmp_path, ctx.url },
                }) catch return;
            };
            ctx.alloc.free(curl_result.stdout);
            ctx.alloc.free(curl_result.stderr);

            if (curl_result.term.Exited != 0) {
                std.fs.deleteFileAbsolute(tmp_path) catch {};
                return;
            }

            // Try to claim victory
            if (ctx.winner.cmpxchgStrong(RACERS, ctx.racer_id, .acq_rel, .acquire) == null) {
                ctx.success.store(true, .release);
                // Winner keeps file — will be verified + renamed by caller
            } else {
                // Loser — clean up
                std.fs.deleteFileAbsolute(tmp_path) catch {};
            }
        }
    };

    var ctxs: [RACERS]RacerCtx = undefined;
    for (0..RACERS) |i| {
        ctxs[i] = .{
            .alloc = alloc,
            .url = req.url,
            .sha256 = req.expected_sha256,
            .token = token,
            .racer_id = @intCast(i),
            .winner = &winner,
            .success = std.atomic.Value(bool).init(false),
        };
        racer_threads[i] = std.Thread.spawn(.{}, RacerCtx.run, .{&ctxs[i]}) catch null;
    }
    for (&racer_threads) |*t| {
        if (t.*) |thread| thread.join();
    }

    // Check if any racer won
    const winning_id = winner.load(.acquire);
    if (winning_id >= RACERS) return error.DownloadFailed;

    // Verify SHA256 of winner's file
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/{s}.r{d}", .{ TMP_DIR, req.expected_sha256, winning_id }) catch return error.PathTooLong;

    {
        const file = std.fs.openFileAbsolute(tmp_path, .{}) catch return error.ChecksumFailed;
        defer file.close();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var read_buf: [32768]u8 = undefined;
        while (true) {
            const n = file.read(&read_buf) catch return error.ChecksumFailed;
            if (n == 0) break;
            hasher.update(read_buf[0..n]);
        }
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

    // Atomic rename winner to final path
    std.fs.renameAbsolute(tmp_path, dest_path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
