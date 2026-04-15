// nanobrew — Native HTTP bottle downloader (zero curl subprocess spawns)
//
// Downloads bottle tarballs from Homebrew GHCR.
// Features:
//   - Native Zig HTTP client (no curl fork/exec overhead)
//   - Streaming SHA256 verification (hashed reader — single pass)
//   - Atomic writes (tmp -> rename to blobs/)
//   - Skip if blob already cached
//   - GHCR token caching (4 min TTL)
//   - Per-worker persistent HTTP client (1 TLS handshake per worker, not per download)
//   - Pre-fetched GHCR token shared across all workers (no per-download token race)

const std = @import("std");
const store = @import("../store/store.zig");
const paths = @import("../platform/paths.zig");

fn milliTimestamp() i64 {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Timestamp.now(lib_io, .real);
    return @as(i64, @truncate(@divTrunc(ts.nanoseconds, std.time.ns_per_ms)));
}

const CACHE_DIR = paths.CACHE_DIR;
const BLOBS_DIR = paths.BLOBS_DIR;
const TMP_DIR = paths.TMP_DIR;

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

    const WorkerContext = struct {
        gpa: std.mem.Allocator,
        items: []const DownloadRequest,
        next_index: *std.atomic.Value(usize),
        had_error: *std.atomic.Value(bool),
        /// Pre-fetched GHCR bearer token shared read-only by all workers.
        /// Eliminates N-1 redundant token fetches (one per download) on cold cache.
        preauth_token: ?[]const u8,
        bench: bool,
    };

    fn workerFn(ctx: WorkerContext) void {
        // One TLS client per worker — reused across all items this worker handles.
        // std.http.Client pools connections; successive requests to the same host
        // reuse the existing TLS session instead of a full handshake each time.
        var client: std.http.Client = .{ .allocator = ctx.gpa, .io = std.Io.Threaded.global_single_threaded.io() };
        defer client.deinit();

        // Per-download arena: zero GPA mutex calls per allocation; single deinit at exit.
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();

        while (true) {
            const idx = ctx.next_index.fetchAdd(1, .monotonic);
            if (idx >= ctx.items.len) break;
            defer _ = arena.reset(.retain_capacity);
            const t0 = if (ctx.bench) milliTimestamp() else @as(i64, 0);
            downloadOneWithClient(arena.allocator(), &client, ctx.items[idx], ctx.preauth_token) catch {
                ctx.had_error.store(true, .release);
            };
            if (ctx.bench) {
                const sha = ctx.items[idx].expected_sha256;
                std.debug.print("[nb-bench] pkg {s}…: {d}ms\n", .{ sha[0..@min(8, sha.len)], milliTimestamp() - t0 });
            }
        }
    }

    pub fn downloadAll(self: *ParallelDownloader) !void {
        if (self.queue.items.len == 0) return;

        const bench = std.c.getenv("NB_BENCH") != null;
        const t_start = milliTimestamp();

        // Pre-fetch the GHCR token once for the entire batch. All Homebrew core
        // bottles share the same repo ("homebrew/core") and therefore the same token.
        // This replaces N per-download token fetches (disk open + optional HTTP RTT)
        // with a single fetch that all workers share read-only.
        const preauth_token: ?[]const u8 = blk: {
            var tmp_client: std.http.Client = .{ .allocator = self.alloc };
            defer tmp_client.deinit();
            break :blk fetchGhcrToken(self.alloc, &tmp_client, self.queue.items[0].url) catch null;
        };
        defer if (preauth_token) |t| self.alloc.free(t);

        if (bench) std.debug.print("[nb-bench] token: {d}ms\n", .{milliTimestamp() - t_start});

        const num_threads = @min(self.queue.items.len, 8);
        var had_error = std.atomic.Value(bool).init(false);
        var next_index = std.atomic.Value(usize).init(0);

        const ctx = WorkerContext{
            .gpa = self.alloc,
            .items = self.queue.items,
            .next_index = &next_index,
            .had_error = &had_error,
            .preauth_token = preauth_token,
            .bench = bench,
        };

        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;

        for (0..num_threads) |_| {
            threads[spawned] = std.Thread.spawn(.{}, workerFn, .{ctx}) catch {
                had_error.store(true, .release);
                continue;
            };
            spawned += 1;
        }

        for (threads[0..spawned]) |t| {
            t.join();
        }

        if (bench) std.debug.print("[nb-bench] total: {d}ms ({d} pkgs, {d} threads)\n", .{
            milliTimestamp() - t_start,
            self.queue.items.len,
            num_threads,
        });

        if (had_error.load(.acquire)) {
            return error.DownloadFailed;
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

        const bench = std.c.getenv("NB_BENCH") != null;
        const t_start = milliTimestamp();

        // Pre-fetch the GHCR token once — same rationale as ParallelDownloader.
        const preauth_token: ?[]const u8 = blk: {
            var tmp_client: std.http.Client = .{ .allocator = self.alloc };
            defer tmp_client.deinit();
            break :blk fetchGhcrToken(self.alloc, &tmp_client, to_fetch.items[0].url) catch null;
        };
        defer if (preauth_token) |t| self.alloc.free(t);

        if (bench) std.debug.print("[nb-bench] token: {d}ms\n", .{milliTimestamp() - t_start});

        const num_threads = @min(to_fetch.items.len, 8);
        var had_error = std.atomic.Value(bool).init(false);
        var next_index = std.atomic.Value(usize).init(0);

        const Ctx = struct {
            gpa: std.mem.Allocator,
            items: []const PackageInfo,
            next: *std.atomic.Value(usize),
            err: *std.atomic.Value(bool),
            preauth_token: ?[]const u8,
            bench: bool,
        };
        const workerFn = struct {
            fn run(ctx: Ctx) void {
                // Persistent client: 1 TLS handshake per worker, reused across all downloads.
                var client: std.http.Client = .{ .allocator = ctx.gpa };
                defer client.deinit();

                // Per-download arena for temporaries.
                var arena = std.heap.ArenaAllocator.init(ctx.gpa);
                defer arena.deinit();

                while (true) {
                    const idx = ctx.next.fetchAdd(1, .monotonic);
                    if (idx >= ctx.items.len) break;
                    defer _ = arena.reset(.retain_capacity);
                    const t0 = if (ctx.bench) milliTimestamp() else @as(i64, 0);
                    downloadAndExtractOne(arena.allocator(), &client, ctx.items[idx], ctx.err, ctx.preauth_token);
                    if (ctx.bench) {
                        std.debug.print("[nb-bench] pkg {s}: {d}ms\n", .{ ctx.items[idx].name, milliTimestamp() - t0 });
                    }
                }
            }
        }.run;

        const ctx = Ctx{
            .gpa = self.alloc,
            .items = to_fetch.items,
            .next = &next_index,
            .err = &had_error,
            .preauth_token = preauth_token,
            .bench = bench,
        };

        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..num_threads) |_| {
            threads[spawned] = std.Thread.spawn(.{}, workerFn, .{ctx}) catch {
                had_error.store(true, .release);
                continue;
            };
            spawned += 1;
        }
        for (threads[0..spawned]) |t| t.join();

        if (bench) std.debug.print("[nb-bench] total: {d}ms ({d} pkgs, {d} threads)\n", .{
            milliTimestamp() - t_start,
            to_fetch.items.len,
            num_threads,
        });

        if (had_error.load(.acquire)) {
            return error.DownloadExtractFailed;
        }
    }
};

fn downloadAndExtractOne(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    pkg: PackageInfo,
    had_error: *std.atomic.Value(bool),
    preauth_token: ?[]const u8,
) void {
    var blob_buf: [512]u8 = undefined;
    const blob_path = std.fmt.bufPrint(&blob_buf, "{s}/{s}", .{ BLOBS_DIR, pkg.sha256 }) catch {
        had_error.store(true, .release);
        return;
    };

    if (!fileExists(blob_path)) {
        downloadOneWithClient(alloc, client, .{ .url = pkg.url, .expected_sha256 = pkg.sha256 }, preauth_token) catch {
            had_error.store(true, .release);
            return;
        };
    }

    store.ensureEntry(alloc, blob_path, pkg.sha256) catch {
        had_error.store(true, .release);
        return;
    };
}

const TOKEN_CACHE_DIR = paths.TOKEN_CACHE_DIR;

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
        const _lio = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.createDirAbsolute(_lio, TOKEN_CACHE_DIR, .default_dir) catch {};
        if (std.Io.Dir.createFileAbsolute(_lio, cache_path, .{})) |file| {
            file.writeStreamingAll(_lio, t) catch {};
            file.close(_lio);
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

    var redirect_buf: [32768]u8 = undefined;
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
    const _lio = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(_lio, path, .{}) catch return null;
    const stat = file.stat(_lio) catch { file.close(_lio); return null; };
    const now_ns = std.Io.Timestamp.now(_lio, .real).nanoseconds;
    const age_ns = now_ns - stat.mtime.nanoseconds;
    if (age_ns > 240 * std.time.ns_per_s) { file.close(_lio); return null; }
    var tmp_buf: [4096]u8 = undefined;
    const n = file.readPositionalAll(_lio, &tmp_buf, 0) catch { file.close(_lio); return null; };
    file.close(_lio);
    if (n == 0) return null;
    const result = alloc.dupe(u8, tmp_buf[0..n]) catch return null;
    return result;
}

fn scopeToCacheName(repo: []const u8, buf: *[256]u8) ?[]const u8 {
    if (repo.len > buf.len) return null;
    @memcpy(buf[0..repo.len], repo);
    for (buf[0..repo.len]) |*c| {
        if (c.* == '/') c.* = '_';
    }
    return buf[0..repo.len];
}

/// Internal: download using an existing HTTP client and optional pre-fetched token.
/// `preauth_token` is a read-only slice owned by the caller — not freed here.
fn downloadOneWithClient(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    req: DownloadRequest,
    preauth_token: ?[]const u8,
) !void {
    const bench: bool = std.c.getenv("NB_BENCH") != null;
    const t_dl = if (bench) milliTimestamp() else @as(i64, 0);
    var dest_path_buf: [512]u8 = undefined;
    const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ BLOBS_DIR, req.expected_sha256 }) catch return error.PathTooLong;

    // Rewrite bottle URL if NANOBREW_BOTTLE_DOMAIN or HOMEBREW_BOTTLE_DOMAIN is set (#74)
    const bottle_domain: ?[]const u8 = blk: {
        if (std.c.getenv("NANOBREW_BOTTLE_DOMAIN")) |d| {
            const ds = std.mem.sliceTo(d, 0);
            if (std.mem.startsWith(u8, ds, "https://") and ds.len > "https://".len) break :blk ds;
        }
        if (std.c.getenv("HOMEBREW_BOTTLE_DOMAIN")) |d| {
            const ds = std.mem.sliceTo(d, 0);
            if (std.mem.startsWith(u8, ds, "https://") and ds.len > "https://".len) break :blk ds;
        }
        break :blk null;
    };
    var rewritten_url_buf: [2048]u8 = undefined;
    const effective_url = if (bottle_domain) |domain| blk: {
        const ghcr_prefix = "https://ghcr.io/v2/homebrew/core/";
        if (std.mem.startsWith(u8, req.url, ghcr_prefix)) {
            const rest = req.url[ghcr_prefix.len..];
            break :blk std.fmt.bufPrint(&rewritten_url_buf, "{s}/{s}", .{ domain, rest }) catch req.url;
        }
        break :blk req.url;
    } else req.url;

    // Determine auth token:
    //   1. preauth_token if URL is ghcr.io (caller pre-fetched for the batch)
    //   2. null if custom bottle domain that is not ghcr.io (no auth required)
    //   3. fresh fetch (disk-cached with 4-min TTL) otherwise
    const is_ghcr = std.mem.startsWith(u8, effective_url, "https://ghcr.io");
    const skip_auth = bottle_domain != null and !is_ghcr;
    const fresh_token: ?[]const u8 = if (!skip_auth and preauth_token == null)
        try fetchGhcrToken(alloc, client, effective_url)
    else
        null;
    defer if (fresh_token) |t| alloc.free(t);
    const token: ?[]const u8 = if (skip_auth) null else (preauth_token orelse fresh_token);

    // Build auth header
    var auth_buf: [4096]u8 = undefined;
    const extra_headers: []const std.http.Header = if (token) |t| blk: {
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch break :blk &.{};
        break :blk &.{.{ .name = "Authorization", .value = auth }};
    } else &.{};

    // Download with native HTTP + streaming SHA256
    const uri = std.Uri.parse(effective_url) catch return error.DownloadFailed;
    var http_req = client.request(.GET, uri, .{
        // Reduced from 5; HTTPS-to-HTTP downgrade not yet detectable in std.http
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = extra_headers,
    }) catch return error.DownloadFailed;
    defer http_req.deinit();

    http_req.sendBodiless() catch return error.DownloadFailed;

    var redirect_buf: [32768]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;

    // Stream body to tmp file with SHA256 hashing in single pass
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/{s}.dl", .{ TMP_DIR, req.expected_sha256 }) catch return error.PathTooLong;

    {
        const _lio_dl = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.createFileAbsolute(_lio_dl, tmp_path, .{}) catch return error.DownloadFailed;
        var file_writer_buf: [65536]u8 = undefined;
        var file_writer = file.writer(_lio_dl, &file_writer_buf);

        var reader = response.reader(&.{});
        var hash_buf: [65536]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var hashed = reader.hashed(&hasher, &hash_buf);

        _ = hashed.reader.streamRemaining(&file_writer.interface) catch {
            file.close(_lio_dl);
            std.Io.Dir.deleteFileAbsolute(_lio_dl, tmp_path) catch {};
            return error.DownloadFailed;
        };
        file_writer.interface.flush() catch {
            file.close(_lio_dl);
            std.Io.Dir.deleteFileAbsolute(_lio_dl, tmp_path) catch {};
            return error.DownloadFailed;
        };
        file.close(_lio_dl);

        // Verify SHA256
        const digest = hasher.finalResult();
        const charset = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            hex[idx * 2] = charset[byte >> 4];
            hex[idx * 2 + 1] = charset[byte & 0x0f];
        }
        if (req.expected_sha256.len < 64 or !std.mem.eql(u8, &hex, req.expected_sha256[0..64])) {
            std.Io.Dir.deleteFileAbsolute(_lio_dl, tmp_path) catch {};
            return error.ChecksumMismatch;
        }
    }

    // Atomic rename to final path
    std.Io.Dir.renameAbsolute(tmp_path, dest_path, std.Io.Threaded.global_single_threaded.io()) catch |err| {
        if (err == error.PathAlreadyExists) {
            if (bench) {
                const sha = req.expected_sha256;
                std.debug.print("[nb-bench] dl {s}…: {d}ms (cached blob)\n", .{ sha[0..@min(8, sha.len)], milliTimestamp() - t_dl });
            }
            return;
        }
        return err;
    };
    if (bench) {
        const sha = req.expected_sha256;
        std.debug.print("[nb-bench] dl {s}…: {d}ms\n", .{ sha[0..@min(8, sha.len)], milliTimestamp() - t_dl });
    }
}

/// Public single-download entry point for callers without a persistent client.
/// Workers should call downloadOneWithClient directly for connection reuse.
pub fn downloadOne(alloc: std.mem.Allocator, req: DownloadRequest) !void {
    var client: std.http.Client = .{ .allocator = alloc, .io = std.Io.Threaded.global_single_threaded.io() };
    defer client.deinit();
    return downloadOneWithClient(alloc, &client, req, null);
}

fn fileExists(path: []const u8) bool {
    const _lio_fe = std.Io.Threaded.global_single_threaded.io();
    const f = std.Io.Dir.openFileAbsolute(_lio_fe, path, .{}) catch return false;
    f.close(_lio_fe);
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
