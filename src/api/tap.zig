// nanobrew — Homebrew tap formula support
//
// Fetches and parses Ruby formula files from third-party taps.
// Input: "user/tap/formula" (e.g. "steipete/tap/sag")
// Repo:  github.com/<user>/homebrew-<tap>/Formula/<name>.rb

const std = @import("std");
const Formula = @import("formula.zig").Formula;
const BOTTLE_TAG = @import("formula.zig").BOTTLE_TAG;
const BOTTLE_FALLBACKS = @import("formula.zig").BOTTLE_FALLBACKS;
const fetch = @import("../net/fetch.zig");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Fetch a formula from a third-party tap.
/// name must be "user/tap/formula" format (exactly 2 slashes).
pub fn fetchTapFormula(alloc: std.mem.Allocator, client: ?*std.http.Client, name: []const u8) !Formula {
    const ref = parseTapRef(name) orelse return error.FormulaNotFound;

    // Try Formula/<name>.rb first, then Formula/<first_letter>/<name>.rb
    const urls = [_][]const u8{
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Formula/{s}.rb", .{ ref.user, ref.tap, ref.formula }),
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Formula/{c}/{s}.rb", .{ ref.user, ref.tap, ref.formula[0], ref.formula }),
    };
    defer for (urls) |u| alloc.free(u);

    var ruby_src: ?[]u8 = null;
    for (urls) |url| {
        ruby_src = if (client) |c|
            fetch.getWithClient(alloc, c, url) catch null
        else
            fetch.get(alloc, url) catch null;
        if (ruby_src != null) break;
    }

    const src = ruby_src orelse return error.FormulaNotFound;
    defer alloc.free(src);

    return parseRubyFormula(alloc, ref.formula, src);
}

const TapRef = struct {
    user: []const u8,
    tap: []const u8,
    formula: []const u8,
};

fn parseTapRef(name: []const u8) ?TapRef {
    var slash1: ?usize = null;
    var slash2: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '/') {
            if (slash1 == null) {
                slash1 = i;
            } else if (slash2 == null) {
                slash2 = i;
            } else {
                return null; // more than 2 slashes
            }
        }
    }
    const s1 = slash1 orelse return null;
    const s2 = slash2 orelse return null;
    if (s1 == 0 or s2 == s1 + 1 or s2 == name.len - 1) return null;
    return .{
        .user = name[0..s1],
        .tap = name[s1 + 1 .. s2],
        .formula = name[s2 + 1 ..],
    };
}

/// Parse a Ruby formula file into a Formula struct.
/// Handles: version, desc, url, sha256, depends_on, on_macos/on_linux blocks,
/// bottle blocks with root_url and per-tag sha256.
pub fn parseRubyFormula(alloc: std.mem.Allocator, name: []const u8, src: []const u8) !Formula {
    var version: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var source_url: ?[]const u8 = null;
    var source_sha256: ?[]const u8 = null;
    var bottle_root_url: ?[]const u8 = null;
    var bottle_sha256: ?[]const u8 = null;

    var deps: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(alloc);
    var build_deps: std.ArrayList([]const u8) = .empty;
    defer build_deps.deinit(alloc);

    // Track block nesting for on_macos/on_linux/bottle
    var in_bottle: bool = false;
    var platform_skip: bool = false;
    var block_depth: u32 = 0;
    var platform_depth: u32 = 0;

    var line_iter = std.mem.splitScalar(u8, src, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // Track do...end block nesting
        if (endsWith(line, " do") or std.mem.eql(u8, line, "do")) {
            block_depth += 1;

            // Detect platform blocks
            if (startsWith(line, "on_macos")) {
                platform_depth = block_depth;
                platform_skip = !is_macos;
                continue;
            } else if (startsWith(line, "on_linux")) {
                platform_depth = block_depth;
                platform_skip = !is_linux;
                continue;
            } else if (startsWith(line, "on_arm")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .aarch64);
                continue;
            } else if (startsWith(line, "on_intel")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .x86_64);
                continue;
            }

            // Detect bottle block
            if (startsWith(line, "bottle")) {
                in_bottle = true;
                continue;
            }
        }

        if (std.mem.eql(u8, line, "end")) {
            if (block_depth == platform_depth and platform_depth > 0) {
                platform_skip = false;
                platform_depth = 0;
            }
            if (in_bottle and block_depth > 0) {
                in_bottle = false;
            }
            if (block_depth > 0) block_depth -= 1;
            continue;
        }

        // Skip lines inside wrong-platform blocks
        if (platform_skip) continue;

        // --- Inside bottle block ---
        if (in_bottle) {
            if (extractQuotedAfter(line, "root_url")) |val| {
                bottle_root_url = val;
            } else if (findBottleSha256(line)) |val| {
                bottle_sha256 = val;
            }
            continue;
        }

        // --- Top-level fields ---
        if (version == null) {
            if (extractQuotedAfter(line, "version")) |val| {
                version = val;
            }
        }
        if (desc == null) {
            if (extractQuotedAfter(line, "desc")) |val| {
                desc = val;
            }
        }
        if (source_url == null) {
            if (extractQuotedAfter(line, "url")) |val| {
                source_url = val;
            }
        }
        if (source_sha256 == null and !in_bottle) {
            if (extractQuotedAfter(line, "sha256")) |val| {
                source_sha256 = val;
            }
        }

        // depends_on
        if (startsWith(line, "depends_on")) {
            if (extractQuotedAfter(line, "depends_on")) |dep_name| {
                // Check if build-only
                if (std.mem.indexOf(u8, line, "=> :build") != null) {
                    try build_deps.append(alloc, try alloc.dupe(u8, dep_name));
                } else {
                    try deps.append(alloc, try alloc.dupe(u8, dep_name));
                }
            }
        }
    }

    // Extract version from URL if not found explicitly
    if (version == null) {
        if (source_url) |url| {
            version = extractVersionFromUrl(url);
        }
    }

    const ver = version orelse return error.FormulaNotFound;

    // Interpolate #{version} in source_url
    const resolved_url = if (source_url) |url|
        try interpolateVersion(alloc, url, ver)
    else
        try alloc.dupe(u8, "");

    const resolved_sha = if (source_sha256) |s|
        try alloc.dupe(u8, s)
    else
        try alloc.dupe(u8, "");

    // Construct bottle URL
    const b_url = if (bottle_root_url != null and bottle_sha256 != null)
        try constructBottleUrl(alloc, bottle_root_url.?, name, ver)
    else
        try alloc.dupe(u8, "");

    const b_sha = if (bottle_sha256) |s|
        try alloc.dupe(u8, s)
    else
        try alloc.dupe(u8, "");

    return .{
        .name = try alloc.dupe(u8, name),
        .version = try alloc.dupe(u8, ver),
        .desc = try alloc.dupe(u8, desc orelse ""),
        .source_url = resolved_url,
        .source_sha256 = resolved_sha,
        .bottle_url = b_url,
        .bottle_sha256 = b_sha,
        .dependencies = try deps.toOwnedSlice(alloc),
        .build_deps = try build_deps.toOwnedSlice(alloc),
    };
}

fn constructBottleUrl(alloc: std.mem.Allocator, root_url: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    // GHCR URLs use blob digest format
    if (std.mem.indexOf(u8, root_url, "ghcr.io") != null) {
        // For GHCR, bottle URL needs different format — leave as root_url for now,
        // actual download handled by existing GHCR auth path
        return std.fmt.allocPrint(alloc, "{s}", .{root_url});
    }
    // GitHub Releases: root_url/<name>-<version>.<TAG>.bottle.tar.gz
    return std.fmt.allocPrint(alloc, "{s}/{s}-{s}.{s}.bottle.tar.gz", .{
        root_url,
        name,
        version,
        BOTTLE_TAG,
    });
}

/// Interpolate #{version} references in a string.
fn interpolateVersion(alloc: std.mem.Allocator, s: []const u8, version: []const u8) ![]const u8 {
    const marker = "\x23{version}"; // #{version}
    if (std.mem.indexOf(u8, s, marker) == null) {
        return alloc.dupe(u8, s);
    }
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + marker.len <= s.len and std.mem.eql(u8, s[i..][0..marker.len], marker)) {
            try result.appendSlice(alloc, version);
            i += marker.len;
        } else {
            try result.append(alloc, s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(alloc);
}

/// Extract quoted string after a keyword, e.g. `version "1.0"` -> "1.0"
fn extractQuotedAfter(line: []const u8, keyword: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, keyword) orelse return null;
    const after = line[idx + keyword.len ..];
    // Find opening quote
    const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const rest = after[q1 + 1 ..];
    // Find closing quote
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

/// Find bottle sha256 matching our platform tag.
/// Format: `sha256 cellar: :any_skip_relocation, arm64_sonoma: "abc123"`
/// or: `sha256 arm64_sonoma: "abc123"`
fn findBottleSha256(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "sha256")) return null;

    // Try primary tag first, then fallbacks
    if (findTagInLine(line, BOTTLE_TAG)) |sha| return sha;
    for (BOTTLE_FALLBACKS) |tag| {
        if (findTagInLine(line, tag)) |sha| return sha;
    }
    return null;
}

fn findTagInLine(line: []const u8, tag: []const u8) ?[]const u8 {
    // Look for `tag: "hex"`
    const needle_buf = comptime blk: {
        // Can't do runtime concat in comptime search, so we do it at call site
        break :blk {};
    };
    _ = needle_buf;

    // Search for tag followed by colon
    var i: usize = 0;
    while (i + tag.len < line.len) : (i += 1) {
        if (std.mem.eql(u8, line[i..][0..tag.len], tag)) {
            const after_tag = line[i + tag.len ..];
            if (after_tag.len > 0 and after_tag[0] == ':') {
                // Found "tag:", now extract quoted string
                const q1 = std.mem.indexOfScalar(u8, after_tag, '"') orelse return null;
                const rest = after_tag[q1 + 1 ..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
                return rest[0..q2];
            }
        }
    }
    return null;
}

/// Try to extract version from URL patterns like /v1.3.0/ or /1.3.0/
fn extractVersionFromUrl(url: []const u8) ?[]const u8 {
    // Look for /vX.Y.Z/ or /X.Y.Z/ in URL
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '/') {
            const start = i + 1;
            if (start >= url.len) break;
            // Skip optional 'v' prefix
            const num_start = if (url[start] == 'v') start + 1 else start;
            if (num_start >= url.len) continue;
            // Check if it looks like a version (digit.digit...)
            if (!std.ascii.isDigit(url[num_start])) continue;
            // Find end of version segment
            var end = num_start;
            var has_dot = false;
            while (end < url.len and url[end] != '/' and url[end] != '?' and url[end] != '#') : (end += 1) {
                if (url[end] == '.') has_dot = true;
            }
            if (has_dot and end > num_start + 1) {
                return url[num_start..end];
            }
        }
    }
    return null;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseTapRef - valid user/tap/formula" {
    const ref = parseTapRef("steipete/tap/sag").?;
    try testing.expectEqualStrings("steipete", ref.user);
    try testing.expectEqualStrings("tap", ref.tap);
    try testing.expectEqualStrings("sag", ref.formula);
}

test "parseTapRef - rejects simple name" {
    try testing.expect(parseTapRef("tree") == null);
}

test "parseTapRef - rejects single slash" {
    try testing.expect(parseTapRef("user/formula") == null);
}

test "parseTapRef - rejects triple slash" {
    try testing.expect(parseTapRef("a/b/c/d") == null);
}

test "parseRubyFormula - simple formula with version and url" {
    const src =
        \\class Sag < Formula
        \\  desc "Command-line ElevenLabs TTS"
        \\  version "0.2.2"
        \\  url "https://github.com/steipete/sag/releases/download/v0.2.2/sag.tar.gz"
        \\  sha256 "abc123"
        \\  def install
        \\    bin.install "sag"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "sag", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("sag", f.name);
    try testing.expectEqualStrings("0.2.2", f.version);
    try testing.expectEqualStrings("Command-line ElevenLabs TTS", f.desc);
    try testing.expectEqualStrings("https://github.com/steipete/sag/releases/download/v0.2.2/sag.tar.gz", f.source_url);
    try testing.expectEqualStrings("abc123", f.source_sha256);
}

test "parseRubyFormula - version interpolation in url" {
    const src =
        \\class Foo < Formula
        \\  version "1.5.0"
        \\  url "https://example.com/v#{version}/foo-#{version}.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "foo", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("1.5.0", f.version);
    try testing.expectEqualStrings("https://example.com/v1.5.0/foo-1.5.0.tar.gz", f.source_url);
}

test "parseRubyFormula - dependencies" {
    const src =
        \\class Bar < Formula
        \\  version "2.0"
        \\  url "https://example.com/bar.tar.gz"
        \\  sha256 "aaa"
        \\  depends_on "openssl"
        \\  depends_on "zlib"
        \\  depends_on "rust" => :build
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "bar", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), f.dependencies.len);
    try testing.expectEqualStrings("openssl", f.dependencies[0]);
    try testing.expectEqualStrings("zlib", f.dependencies[1]);
    try testing.expectEqual(@as(usize, 1), f.build_deps.len);
    try testing.expectEqualStrings("rust", f.build_deps[0]);
}

test "parseRubyFormula - bottle block with root_url" {
    const src =
        \\class Bpb < Formula
        \\  version "1.3.0"
        \\  url "https://github.com/indirect/bpb/archive/refs/tags/v1.3.0.zip"
        \\  sha256 "709445fe"
        \\  bottle do
        \\    root_url "https://github.com/indirect/homebrew-tap/releases/download/bpb-v1.3.0"
        \\    sha256 cellar: :any_skip_relocation, arm64_sonoma: "32aab73b"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "bpb", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("1.3.0", f.version);
    // Bottle URL should be constructed
    try testing.expect(f.bottle_url.len > 0);
    try testing.expect(std.mem.indexOf(u8, f.bottle_url, "bpb-1.3.0") != null);
    try testing.expectEqualStrings("32aab73b", f.bottle_sha256);
    // Source should also be populated as fallback
    try testing.expectEqualStrings("709445fe", f.source_sha256);
}

test "parseRubyFormula - version extracted from url" {
    const src =
        \\class Xyz < Formula
        \\  url "https://github.com/user/xyz/archive/refs/tags/v3.2.1.tar.gz"
        \\  sha256 "fff"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "xyz", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("3.2.1", f.version);
}

test "parseRubyFormula - no version returns error" {
    const src =
        \\class Bad < Formula
        \\  url "https://example.com/no-version"
        \\  sha256 "aaa"
        \\end
    ;
    try testing.expectError(error.FormulaNotFound, parseRubyFormula(testing.allocator, "bad", src));
}

test "extractQuotedAfter - basic" {
    const val = extractQuotedAfter("  version \"1.2.3\"", "version").?;
    try testing.expectEqualStrings("1.2.3", val);
}

test "extractQuotedAfter - not found" {
    try testing.expect(extractQuotedAfter("url \"x\"", "version") == null);
}

test "interpolateVersion - replaces marker" {
    const result = try interpolateVersion(testing.allocator, "v\x23{version}/file", "2.0");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2.0/file", result);
}

test "interpolateVersion - no marker returns copy" {
    const result = try interpolateVersion(testing.allocator, "plain-url", "1.0");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("plain-url", result);
}

test "extractVersionFromUrl - with v prefix" {
    const v = extractVersionFromUrl("https://github.com/user/repo/archive/refs/tags/v1.3.0.zip").?;
    try testing.expectEqualStrings("1.3.0", v);
}

test "extractVersionFromUrl - no version" {
    try testing.expect(extractVersionFromUrl("https://example.com/latest") == null);
}

test "findBottleSha256 - matching tag" {
    const line = "    sha256 cellar: :any_skip_relocation, arm64_sonoma: \"abcdef\"";
    const sha = findBottleSha256(line);
    if (is_macos and builtin.cpu.arch == .aarch64) {
        try testing.expectEqualStrings("abcdef", sha.?);
    }
}
