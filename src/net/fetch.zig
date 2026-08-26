// nanobrew — Native HTTP fetch (zero curl dependency)
//
// Replaces all curl subprocess spawns with Zig's std.http.Client.
// Follows redirects. Auto-decompresses gzip responses.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const proxy = @import("proxy.zig");
const flate = std.compress.flate;

const DOWNLOAD_STREAM_BUFFER_SIZE = 256 * 1024;

/// Split `extra_headers` into a User-Agent override (if present) and the
/// remaining headers. Required because std.http.Client otherwise *appends*
/// any User-Agent we add to extra_headers onto its built-in default,
/// producing a comma-joined value like
///   `User-Agent: zig/0.16.0 (std.http),Homebrew/4 (nanobrew)`
/// which UA-gated CDNs (e.g. app.warp.dev — see #258) reject with 404.
/// Lifting the UA into `request_options.headers.user_agent.override`
/// replaces the default cleanly.
fn splitUserAgent(
    alloc: std.mem.Allocator,
    extra_headers: []const std.http.Header,
) struct { ua: ?[]const u8, rest: []const std.http.Header } {
    var ua: ?[]const u8 = null;
    var rest_count: usize = 0;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) {
            ua = h.value;
        } else {
            rest_count += 1;
        }
    }
    if (ua == null) return .{ .ua = null, .rest = extra_headers };
    if (rest_count == 0) return .{ .ua = ua, .rest = &.{} };
    const rest = alloc.alloc(std.http.Header, rest_count) catch {
        // Allocation failure: fall back to the original slice. Worst case
        // we still send the appended UA, which is the pre-fix behavior.
        return .{ .ua = ua, .rest = extra_headers };
    };
    var i: usize = 0;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) continue;
        rest[i] = h;
        i += 1;
    }
    return .{ .ua = ua, .rest = rest };
}

fn requestOptions(
    ua: ?[]const u8,
    rest: []const std.http.Header,
    redirect_limit: u8,
) std.http.Client.RequestOptions {
    return .{
        // Reduced from 5; HTTPS-to-HTTP downgrade not yet detectable in std.http.
        // POST callers pass 0 and handle 301/302/303 themselves so std.http's
        // POST→GET conversion cannot leak the synthetic Content-Type header.
        .redirect_behavior = @enumFromInt(redirect_limit),
        .extra_headers = rest,
        .headers = if (ua) |v|
            .{ .user_agent = .{ .override = v } }
        else
            .{},
    };
}

/// Fetch a URL and return the response body as an owned slice.
/// Caller must free the returned slice with `alloc.free()`.
/// Follows up to 5 redirects. Auto-decompresses gzip. Returns error on non-200 status.
pub fn get(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = proxy.Client.init(alloc, paths.safe_io);
    defer client.deinit();
    return getWithClient(alloc, client.ptr(), url);
}

/// Fetch using an existing client (avoids repeated TLS setup).
pub fn getWithClient(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    return getWithClientHeaders(alloc, client, url, &.{});
}

/// Fetch a URL with additional headers and return the response body as an owned slice.
pub fn getWithHeaders(alloc: std.mem.Allocator, url: []const u8, extra_headers: []const std.http.Header) ![]u8 {
    var client = proxy.Client.init(alloc, paths.safe_io);
    defer client.deinit();
    return getWithClientHeaders(alloc, client.ptr(), url, extra_headers);
}

/// Fetch using an existing client plus additional headers.
pub fn getWithClientHeaders(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const split = splitUserAgent(alloc, extra_headers);
    defer if (split.rest.ptr != extra_headers.ptr and split.rest.len > 0) alloc.free(split.rest);
    var req = client.request(.GET, uri, requestOptions(split.ua, split.rest, 3)) catch return error.FetchFailed;

    req.sendBodiless() catch {
        req.deinit();
        return error.FetchFailed;
    };

    var head_buf: [32768]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        req.deinit();
        return error.FetchFailed;
    }

    // Stream raw response body to memory
    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch {
        out.deinit();
        req.deinit();
        return error.FetchFailed;
    };
    req.deinit();

    const raw = out.toOwnedSlice() catch {
        out.deinit();
        return error.OutOfMemory;
    };

    // Auto-decompress gzip if server sent compressed response
    if (response.head.content_encoding == .gzip) {
        defer alloc.free(raw);
        return decompressGzip(alloc, raw);
    }

    return raw;
}

fn decompressGzip(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var fixed_reader = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fixed_reader, .gzip, &window);

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    _ = decomp.reader.streamRemaining(&result.writer) catch return error.FetchFailed;
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

/// Optional HTTP POST form body. When present, the request is sent as a POST
/// with `Content-Type: application/x-www-form-urlencoded` and `body` as the
/// payload. Used for casks whose download declares `using: :post, data: {...}`
/// (e.g. segger-jlink's license acceptance) — see #305. `body` must be mutable
/// because std.http's `sendBodyComplete` requires `[]u8`.
pub const PostBody = ?[]u8;

/// Shared implementation behind all download* helpers. Streams the response to
/// `dest_path`, optionally verifying SHA256, optionally issuing a POST with a
/// form body instead of a bodiless GET.
fn downloadCore(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: ?[]const u8,
    extra_headers: []const std.http.Header,
    body: PostBody,
) !void {
    if (expected_sha256) |sha| {
        if (sha.len < 64) return error.ChecksumMismatch;
    }

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const split = splitUserAgent(client.allocator, extra_headers);
    defer if (split.rest.ptr != extra_headers.ptr and split.rest.len > 0) client.allocator.free(split.rest);

    // For POST we must advertise the form content type. Build a combined header
    // slice so we don't mutate the caller's headers.
    var post_headers: ?[]std.http.Header = null;
    defer if (post_headers) |ph| client.allocator.free(ph);
    const effective_rest: []const std.http.Header = if (body != null) blk: {
        const combined = client.allocator.alloc(std.http.Header, split.rest.len + 1) catch break :blk split.rest;
        @memcpy(combined[0..split.rest.len], split.rest);
        combined[split.rest.len] = .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" };
        post_headers = combined;
        break :blk combined;
    } else split.rest;

    const method: std.http.Method = if (body != null) .POST else .GET;
    const redirect_limit: u8 = if (body != null) 0 else 3;
    var req = client.request(method, uri, requestOptions(split.ua, effective_rest, redirect_limit)) catch return error.FetchFailed;

    if (body) |b| {
        req.sendBodyComplete(b) catch {
            req.deinit();
            return error.FetchFailed;
        };
    } else {
        req.sendBodiless() catch {
            req.deinit();
            return error.FetchFailed;
        };
    }

    var head_buf: [32768]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        if (body != null) switch (response.head.status) {
            .moved_permanently, .found, .see_other => {
                const location = response.head.location orelse {
                    req.deinit();
                    return error.FetchFailed;
                };
                const redirect_url = client.allocator.dupe(u8, location) catch {
                    req.deinit();
                    return error.OutOfMemory;
                };
                req.deinit();
                defer client.allocator.free(redirect_url);
                return downloadCore(client, redirect_url, dest_path, expected_sha256, extra_headers, null);
            },
            .temporary_redirect, .permanent_redirect => {
                req.deinit();
                return error.PostRedirectUnsupported;
            },
            else => {},
        };
        req.deinit();
        return error.FetchFailed;
    }

    const _dl_io = paths.safe_io;
    var file = std.Io.Dir.createFileAbsolute(_dl_io, dest_path, .{}) catch {
        req.deinit();
        return error.FetchFailed;
    };
    var file_writer_buf: [DOWNLOAD_STREAM_BUFFER_SIZE]u8 = undefined;
    var file_writer = file.writer(_dl_io, &file_writer_buf);
    var reader = response.reader(&.{});

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hash_buf: [DOWNLOAD_STREAM_BUFFER_SIZE]u8 = undefined;
    var hashed = reader.hashed(&hasher, &hash_buf);
    // Stream through the hashing reader only when verification is requested.
    const stream_src: *std.Io.Reader = if (expected_sha256 != null) &hashed.reader else reader;

    _ = stream_src.streamRemaining(&file_writer.interface) catch {
        file.close(_dl_io);
        req.deinit();
        std.Io.Dir.deleteFileAbsolute(_dl_io, dest_path) catch {};
        return error.FetchFailed;
    };
    file_writer.interface.flush() catch {
        file.close(_dl_io);
        req.deinit();
        std.Io.Dir.deleteFileAbsolute(_dl_io, dest_path) catch {};
        return error.FetchFailed;
    };
    file.close(_dl_io);
    req.deinit();

    if (expected_sha256) |sha| {
        const digest = hasher.finalResult();
        const charset = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            hex[idx * 2] = charset[byte >> 4];
            hex[idx * 2 + 1] = charset[byte & 0x0f];
        }
        if (!std.mem.eql(u8, &hex, sha[0..64])) {
            std.Io.Dir.deleteFileAbsolute(_dl_io, dest_path) catch {};
            return error.ChecksumMismatch;
        }
    }
}

/// Fetch a URL and write the response body directly to a file.
pub fn download(alloc: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    var client = proxy.Client.init(alloc, paths.safe_io);
    defer client.deinit();
    return downloadWithClient(client.ptr(), url, dest_path);
}

/// Download using an existing client.
pub fn downloadWithClient(client: *std.http.Client, url: []const u8, dest_path: []const u8) !void {
    return downloadWithClientHeaders(client, url, dest_path, &.{});
}

/// Download using an existing client plus additional headers.
pub fn downloadWithClientHeaders(client: *std.http.Client, url: []const u8, dest_path: []const u8, extra_headers: []const std.http.Header) !void {
    return downloadCore(client, url, dest_path, null, extra_headers, null);
}

/// Download (no SHA) with optional POST form body.
pub fn downloadWithClientHeadersBody(client: *std.http.Client, url: []const u8, dest_path: []const u8, extra_headers: []const std.http.Header, body: PostBody) !void {
    return downloadCore(client, url, dest_path, null, extra_headers, body);
}

/// Download using an existing client while computing SHA256 in the same pass.
pub fn downloadWithClientSha256(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8,
) !void {
    return downloadWithClientSha256Headers(client, url, dest_path, expected_sha256, &.{});
}

/// Download with additional headers while computing SHA256 in the same pass.
pub fn downloadWithClientSha256Headers(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8,
    extra_headers: []const std.http.Header,
) !void {
    return downloadCore(client, url, dest_path, expected_sha256, extra_headers, null);
}

/// Verifying download with optional POST form body.
pub fn downloadWithClientSha256HeadersBody(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8,
    extra_headers: []const std.http.Header,
    body: PostBody,
) !void {
    return downloadCore(client, url, dest_path, expected_sha256, extra_headers, body);
}

// ============================================================
// Tests
// ============================================================

test "splitUserAgent: lifts User-Agent and preserves other headers (#258)" {
    const alloc = std.testing.allocator;
    const headers: []const std.http.Header = &.{
        .{ .name = "User-Agent", .value = "Homebrew/4 (nanobrew)" },
        .{ .name = "Accept", .value = "*/*" },
    };
    const split = splitUserAgent(alloc, headers);
    defer if (split.rest.ptr != headers.ptr and split.rest.len > 0) alloc.free(split.rest);
    try std.testing.expect(split.ua != null);
    try std.testing.expectEqualStrings("Homebrew/4 (nanobrew)", split.ua.?);
    try std.testing.expectEqual(@as(usize, 1), split.rest.len);
    try std.testing.expectEqualStrings("Accept", split.rest[0].name);
}

test "splitUserAgent: case-insensitive match" {
    const alloc = std.testing.allocator;
    const headers: []const std.http.Header = &.{
        .{ .name = "user-agent", .value = "lower" },
    };
    const split = splitUserAgent(alloc, headers);
    defer if (split.rest.ptr != headers.ptr and split.rest.len > 0) alloc.free(split.rest);
    try std.testing.expect(split.ua != null);
    try std.testing.expectEqualStrings("lower", split.ua.?);
    try std.testing.expectEqual(@as(usize, 0), split.rest.len);
}

test "splitUserAgent: passes through when no UA present" {
    const alloc = std.testing.allocator;
    const headers: []const std.http.Header = &.{
        .{ .name = "Accept", .value = "*/*" },
    };
    const split = splitUserAgent(alloc, headers);
    try std.testing.expect(split.ua == null);
    try std.testing.expectEqual(headers.ptr, split.rest.ptr);
}

test "requestOptions: omits user_agent override when UA absent" {
    const opts = requestOptions(null, &.{}, 3);
    try std.testing.expectEqual(std.http.Client.Request.Headers.Value.default, opts.headers.user_agent);
}

test "requestOptions: sets user_agent override when UA present" {
    const opts = requestOptions("Homebrew/4 (nanobrew)", &.{}, 3);
    switch (opts.headers.user_agent) {
        .override => |v| try std.testing.expectEqualStrings("Homebrew/4 (nanobrew)", v),
        else => try std.testing.expect(false),
    }
}
