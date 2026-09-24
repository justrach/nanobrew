// nanobrew — GHCR (GitHub Container Registry) version resolver
//
// Homebrew publishes every bottle it has ever built to
// `ghcr.io/v2/homebrew/core/<name>`. The formula JSON API only exposes the
// *current* version, but the OCI registry retains old version tags, so we can
// install a specific older version (`nb install hexyl@0.17.0`) by:
//
//   1. listing the available tags          GET .../tags/list
//   2. picking the tag for the requested version (exact, else highest rebuild)
//   3. fetching that tag's image-index     GET .../manifests/<tag>
//   4. matching this platform's bottle tag (arm64_tahoe, x86_64_linux, …)
//   5. reading the blob sha256 from the    sh.brew.bottle.digest annotation
//
// The blob is then downloaded + verified through the existing pipeline in
// net/downloader.zig (same host, same anonymous pull token, same sha256 check).
//
// Scope: homebrew-core formulae only. Taps live in a different GHCR org and
// casks have no version history, so neither is handled here.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const formula = @import("formula.zig");
const downloader = @import("../net/downloader.zig");

const BOTTLE_TAG = formula.BOTTLE_TAG;
const BOTTLE_FALLBACKS = formula.BOTTLE_FALLBACKS;

const GHCR_BASE = "https://ghcr.io/v2/homebrew/core/";

pub const ResolveError = error{
    BottleVersionNotFound,
    NoBottleForPlatform,
    RegistryError,
    OutOfMemory,
};

/// A resolved bottle for a specific version on this platform.
/// All fields are owned by the caller; free with `deinit`.
pub const VersionedBottle = struct {
    /// Cellar version (the OCI tag with any trailing `-<n>` line revision
    /// stripped, e.g. `0.10.0_1-1` → `0.10.0_1`).
    version: []const u8,
    url: []const u8,
    sha256: []const u8,

    pub fn deinit(self: VersionedBottle, alloc: std.mem.Allocator) void {
        alloc.free(self.version);
        alloc.free(self.url);
        alloc.free(self.sha256);
    }
};

// ── Tag selection ────────────────────────────────────────────────────────

/// Strip a trailing `-<digits>` bottle-line revision from an OCI tag.
/// `0.10.0_1-1` → `0.10.0_1`; `0.17.0` → `0.17.0`.
fn stripLineRev(tag: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, tag, '-') orelse return tag;
    if (dash + 1 >= tag.len) return tag;
    for (tag[dash + 1 ..]) |c| if (!std.ascii.isDigit(c)) return tag;
    return tag[0..dash];
}

fn lineRev(tag: []const u8) u32 {
    const dash = std.mem.lastIndexOfScalar(u8, tag, '-') orelse return 0;
    if (dash + 1 >= tag.len) return 0;
    for (tag[dash + 1 ..]) |c| if (!std.ascii.isDigit(c)) return 0;
    return std.fmt.parseInt(u32, tag[dash + 1 ..], 10) catch 0;
}

/// Version part before the `_<rebuild>` suffix. `0.10.0_1` → `0.10.0`.
fn coreOf(base: []const u8) []const u8 {
    const us = std.mem.indexOfScalar(u8, base, '_') orelse return base;
    return base[0..us];
}

fn rebuildOf(base: []const u8) u32 {
    const us = std.mem.indexOfScalar(u8, base, '_') orelse return 0;
    if (us + 1 >= base.len) return 0;
    return std.fmt.parseInt(u32, base[us + 1 ..], 10) catch 0;
}

/// Does `tag` satisfy a `requested` version string?
/// Accepts an exact match on the rebuild-qualified base (`0.10.0_1`) or on the
/// bare version core (`0.10.0`).
fn tagMatches(tag: []const u8, requested: []const u8) bool {
    const base = stripLineRev(tag);
    if (std.mem.eql(u8, base, requested)) return true;
    if (std.mem.eql(u8, coreOf(base), requested)) return true;
    return false;
}

/// Pick the best tag for `requested` among `tags`, preferring the highest
/// rebuild then the highest line revision. Returns the index into `tags`, or
/// null if nothing matches.
pub fn selectVersionTag(tags: []const []const u8, requested: []const u8) ?usize {
    var best: ?usize = null;
    var best_rebuild: u32 = 0;
    var best_line: u32 = 0;
    for (tags, 0..) |tag, i| {
        if (!tagMatches(tag, requested)) continue;
        const rb = rebuildOf(stripLineRev(tag));
        const ln = lineRev(tag);
        if (best == null or rb > best_rebuild or (rb == best_rebuild and ln > best_line)) {
            best = i;
            best_rebuild = rb;
            best_line = ln;
        }
    }
    return best;
}

// ── Platform / annotation matching ─────────────────────────────────────────

/// Rank a bottle tag suffix (e.g. `arm64_sequoia`) for this platform.
/// 0 = exact BOTTLE_TAG, then BOTTLE_FALLBACKS in order, else null (no match).
fn platformRank(tag: []const u8) ?usize {
    if (!formula.bottleTagCompatible(tag)) return null;
    if (std.mem.eql(u8, tag, BOTTLE_TAG)) return 0;
    for (BOTTLE_FALLBACKS, 0..) |fb, i| {
        if (std.mem.eql(u8, tag, fb)) return i + 1;
    }
    return null;
}

/// Extract the platform suffix from an OCI `ref.name` like `0.17.0.arm64_sequoia`.
/// The version itself may contain dots, so the suffix is everything after the
/// LAST dot — but bottle tags never contain dots, so this is unambiguous.
fn refNameSuffix(ref: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, ref, '.') orelse return ref;
    if (dot + 1 >= ref.len) return ref;
    return ref[dot + 1 ..];
}

// ── HTTP helpers ───────────────────────────────────────────────────────────

/// Owned anonymous GHCR pull token for `homebrew/core/<name>`. Routed through
/// the shared disk-cached helper in net/downloader.zig so a `pkg@version`
/// install fetches the token once (and the bottle download right after reuses
/// the same cached token) instead of once per registry request.
fn repoToken(alloc: std.mem.Allocator, client: *std.http.Client, name: []const u8) ?[]const u8 {
    var repo_buf: [256]u8 = undefined;
    const repo = std.fmt.bufPrint(&repo_buf, "homebrew/core/{s}", .{name}) catch return null;
    return downloader.cachedRepoToken(alloc, client, repo);
}

/// GET `url`, returning an owned body on HTTP 200, else `error.RegistryError`.
fn httpGet(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    accept: ?[]const u8,
    token: ?[]const u8,
) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.RegistryError;

    var auth_buf: [4096]u8 = undefined;
    var headers: [2]std.http.Header = undefined;
    var n: usize = 0;
    if (accept) |a| {
        headers[n] = .{ .name = "Accept", .value = a };
        n += 1;
    }
    if (token) |t| {
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch return error.RegistryError;
        headers[n] = .{ .name = "Authorization", .value = auth };
        n += 1;
    }

    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = headers[0..n],
    }) catch return error.RegistryError;
    defer req.deinit();

    req.sendBodiless() catch return error.RegistryError;
    var head_buf: [32768]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch return error.RegistryError;
    if (response.head.status != .ok) return error.RegistryError;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var reader = response.reader(&.{});
    reader.appendRemainingUnlimited(alloc, &out) catch return error.RegistryError;
    return out.toOwnedSlice(alloc);
}

// ── Public API ─────────────────────────────────────────────────────────────

/// List all available version tags for a homebrew-core formula.
/// Caller owns the returned slice and each string.
pub fn listTags(alloc: std.mem.Allocator, client: *std.http.Client, name: []const u8) ![][]const u8 {
    const token = repoToken(alloc, client, name);
    defer if (token) |t| alloc.free(t);
    return listTagsWithToken(alloc, client, name, token);
}

/// As `listTags`, but reuses a caller-provided token to avoid a redundant
/// token fetch when the manifest lookup needs the same token.
fn listTagsWithToken(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    name: []const u8,
    token: ?[]const u8,
) ![][]const u8 {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}/tags/list", .{ GHCR_BASE, name }) catch return error.RegistryError;
    const body = try httpGet(alloc, client, url, null, token);
    defer alloc.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.RegistryError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.RegistryError;
    const tags_val = parsed.value.object.get("tags") orelse return error.RegistryError;
    if (tags_val != .array) return error.RegistryError;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |t| alloc.free(t);
        list.deinit(alloc);
    }
    for (tags_val.array.items) |item| {
        if (item != .string) continue;
        try list.append(alloc, try alloc.dupe(u8, item.string));
    }
    return list.toOwnedSlice(alloc);
}

/// Resolve a specific version of a homebrew-core formula to a downloadable
/// bottle for the current platform.
pub fn resolveBottle(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    name: []const u8,
    requested_version: []const u8,
) ResolveError!VersionedBottle {
    // One token for the whole resolve (tags/list + manifest); the bottle
    // download immediately after reuses it from the shared disk cache too.
    const token = repoToken(alloc, client, name);
    defer if (token) |t| alloc.free(t);

    const tags = listTagsWithToken(alloc, client, name, token) catch return error.RegistryError;
    defer {
        for (tags) |t| alloc.free(t);
        alloc.free(tags);
    }

    const idx = selectVersionTag(tags, requested_version) orelse return error.BottleVersionNotFound;
    const tag = tags[idx];

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}/manifests/{s}", .{ GHCR_BASE, name, tag }) catch return error.RegistryError;
    const body = httpGet(alloc, client, url, "application/vnd.oci.image.index.v1+json", token) catch return error.RegistryError;
    defer alloc.free(body);

    const maybe_digest = pickBottleDigest(alloc, body) catch return error.RegistryError;
    const digest = maybe_digest orelse return error.NoBottleForPlatform;
    defer alloc.free(digest);

    const cellar_ver = stripLineRev(tag);
    const out_url = std.fmt.allocPrint(alloc, "{s}{s}/blobs/sha256:{s}", .{ GHCR_BASE, name, digest }) catch return error.OutOfMemory;
    errdefer alloc.free(out_url);
    const out_ver = alloc.dupe(u8, cellar_ver) catch return error.OutOfMemory;
    errdefer alloc.free(out_ver);
    const out_sha = alloc.dupe(u8, digest) catch return error.OutOfMemory;

    return .{ .version = out_ver, .url = out_url, .sha256 = out_sha };
}

/// Parse an OCI image-index manifest body and return the best-matching
/// platform's bottle blob digest (owned), or null if no platform matches.
fn pickBottleDigest(alloc: std.mem.Allocator, body: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const manifests = parsed.value.object.get("manifests") orelse return null;
    if (manifests != .array) return null;

    var best_digest: ?[]const u8 = null;
    var best_rank: usize = std.math.maxInt(usize);
    for (manifests.array.items) |m| {
        if (m != .object) continue;
        const ann = m.object.get("annotations") orelse continue;
        if (ann != .object) continue;
        const ref = getStr(ann.object, "org.opencontainers.image.ref.name") orelse continue;
        const bottle_digest = getStr(ann.object, "sh.brew.bottle.digest") orelse continue;
        const rank = platformRank(refNameSuffix(ref)) orelse continue;
        if (rank < best_rank) {
            best_rank = rank;
            best_digest = bottle_digest;
        }
    }
    if (best_digest) |d| return try alloc.dupe(u8, d);
    return null;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stripLineRev removes trailing -N only" {
    try testing.expectEqualStrings("0.10.0_1", stripLineRev("0.10.0_1-1"));
    try testing.expectEqualStrings("0.17.0", stripLineRev("0.17.0"));
    try testing.expectEqualStrings("0.10.0_1", stripLineRev("0.10.0_1"));
    // a dash followed by non-digits is part of the version, not a line rev
    try testing.expectEqualStrings("1.0-rc", stripLineRev("1.0-rc"));
}

test "coreOf / rebuildOf / lineRev" {
    try testing.expectEqualStrings("0.10.0", coreOf("0.10.0_1"));
    try testing.expectEqualStrings("0.17.0", coreOf("0.17.0"));
    try testing.expectEqual(@as(u32, 1), rebuildOf("0.10.0_1"));
    try testing.expectEqual(@as(u32, 0), rebuildOf("0.17.0"));
    try testing.expectEqual(@as(u32, 1), lineRev("0.10.0_1-1"));
    try testing.expectEqual(@as(u32, 0), lineRev("0.10.0_1"));
}

test "tagMatches: exact core, rebuild-qualified, and line revisions" {
    try testing.expect(tagMatches("0.17.0", "0.17.0"));
    try testing.expect(tagMatches("0.10.0_1", "0.10.0")); // core match
    try testing.expect(tagMatches("0.10.0_1-1", "0.10.0")); // core match across line rev
    try testing.expect(tagMatches("0.10.0_1", "0.10.0_1")); // exact rebuild-qualified
    try testing.expect(!tagMatches("0.16.0", "0.17.0"));
    try testing.expect(!tagMatches("10.17.0", "0.17.0"));
}

test "selectVersionTag picks highest rebuild then line revision" {
    const tags = [_][]const u8{ "0.8.0", "0.10.0", "0.10.0_1", "0.10.0_1-1", "0.17.0" };
    // exact bare version
    {
        const i = selectVersionTag(&tags, "0.17.0").?;
        try testing.expectEqualStrings("0.17.0", tags[i]);
    }
    // requesting 0.10.0 should prefer the highest rebuild + line rev
    {
        const i = selectVersionTag(&tags, "0.10.0").?;
        try testing.expectEqualStrings("0.10.0_1-1", tags[i]);
    }
    // unknown version
    try testing.expect(selectVersionTag(&tags, "9.9.9") == null);
}

test "refNameSuffix extracts platform tag after last dot" {
    try testing.expectEqualStrings("arm64_sequoia", refNameSuffix("0.17.0.arm64_sequoia"));
    try testing.expectEqualStrings("x86_64_linux", refNameSuffix("0.17.0.x86_64_linux"));
}

test "pickBottleDigest selects this platform's bottle" {
    // Build a manifest index that always includes the current BOTTLE_TAG.
    var buf: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf,
        \\{{"manifests":[
        \\{{"annotations":{{"org.opencontainers.image.ref.name":"1.2.3.{s}","sh.brew.bottle.digest":"deadbeef"}}}}
        \\]}}
    , .{@import("formula.zig").preferredCompatibleBottleTag()});
    const digest = try pickBottleDigest(testing.allocator, json);
    defer if (digest) |d| testing.allocator.free(d);
    try testing.expect(digest != null);
    try testing.expectEqualStrings("deadbeef", digest.?);
}

test "pickBottleDigest returns null when no platform matches" {
    const json =
        \\{"manifests":[
        \\{"annotations":{"org.opencontainers.image.ref.name":"1.2.3.some_unknown_os","sh.brew.bottle.digest":"x"}}
        \\]}
    ;
    const digest = try pickBottleDigest(testing.allocator, json);
    defer if (digest) |d| testing.allocator.free(d);
    try testing.expect(digest == null);
}
