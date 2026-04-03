// nanobrew — Formula source cache and hash pinning
//
// Caches Homebrew formula source files (.rb) and pins their SHA256 hashes.
// First fetch stores content + hash. Subsequent fetches verify the hash matches,
// detecting supply-chain tampering of upstream formula sources.

const std = @import("std");
const fetch = @import("../net/fetch.zig");
const paths = @import("../platform/paths.zig");

const FORMULA_CACHE_DIR = paths.CACHE_DIR ++ "/formulas";

/// Returns the path to the SHA256 hash file for a cached formula.
/// Format: FORMULA_CACHE_DIR/<name>-<version>.rb.sha256
/// Rejects name/version containing ".." or "/" to prevent path traversal.
/// Returns "" on invalid input or buffer overflow.
pub fn hashPath(buf: []u8, name: []const u8, version: []const u8) []const u8 {
    if (containsTraversal(name) or containsTraversal(version)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}-{s}.rb.sha256", .{ FORMULA_CACHE_DIR, name, version }) catch return "";
}

/// Returns the path to the cached formula source file.
/// Format: FORMULA_CACHE_DIR/<name>-<version>.rb
/// Rejects name/version containing ".." or "/" to prevent path traversal.
/// Returns "" on invalid input or buffer overflow.
pub fn cachePath(buf: []u8, name: []const u8, version: []const u8) []const u8 {
    if (containsTraversal(name) or containsTraversal(version)) return "";
    return std.fmt.bufPrint(buf, "{s}/{s}-{s}.rb", .{ FORMULA_CACHE_DIR, name, version }) catch return "";
}

fn containsTraversal(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "..") != null or std.mem.indexOf(u8, s, "/") != null;
}

/// Compute the SHA256 hash of content and write the 64-char lowercase hex digest to out.
pub fn computeSha256Hex(content: []const u8, out: *[64]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, idx| {
        out[idx * 2] = charset[byte >> 4];
        out[idx * 2 + 1] = charset[byte & 0x0f];
    }
}

/// Fetch a formula source, verify its hash against the pinned value, and cache on first fetch.
///
/// On network failure: falls back to cached content if available.
/// On hash mismatch: returns error.FormulaSourceChanged (possible supply-chain attack).
/// On first fetch: caches content and pins the hash.
pub fn getVerifiedFormula(alloc: std.mem.Allocator, name: []const u8, version: []const u8, url: []const u8) ![]u8 {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var hash_buf: [512]u8 = undefined;
    const hash_path = hashPath(&hash_buf, name, version);
    if (hash_path.len == 0) return error.InvalidName;

    var cache_buf: [512]u8 = undefined;
    const cache_path = cachePath(&cache_buf, name, version);
    if (cache_path.len == 0) return error.InvalidName;

    // Try to download fresh content
    const fresh_content = fetch.get(alloc, url) catch |err| {
        // Network failure: try cached content
        const cached = std.fs.cwd().readFileAlloc(alloc, cache_path, 10 * 1024 * 1024) catch {
            return err;
        };
        stderr.print("nb: warning: network fetch failed for {s}, using cached formula\n", .{name}) catch {};
        return cached;
    };

    // Compute SHA256 of fresh content
    var fresh_hex: [64]u8 = undefined;
    computeSha256Hex(fresh_content, &fresh_hex);

    // Check for existing pinned hash
    var existing_hash: [64]u8 = undefined;
    if (std.fs.cwd().readFileAlloc(alloc, hash_path, 64)) |pinned| {
        defer alloc.free(pinned);
        if (pinned.len >= 64) {
            @memcpy(&existing_hash, pinned[0..64]);
            if (std.mem.eql(u8, &existing_hash, &fresh_hex)) {
                // Hash matches — content is authentic
                return fresh_content;
            } else {
                // Hash mismatch — possible supply-chain tampering
                stderr.print("nb: WARNING: formula source hash changed for {s}\n", .{name}) catch {};
                stderr.print("    pinned:  {s}\n", .{&existing_hash}) catch {};
                stderr.print("    current: {s}\n", .{&fresh_hex}) catch {};
                alloc.free(fresh_content);
                return error.FormulaSourceChanged;
            }
        }
    } else |_| {}

    // First fetch: create cache directory, write content and hash
    std.fs.makeDirAbsolute(FORMULA_CACHE_DIR) catch {};

    if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
        defer file.close();
        file.writeAll(fresh_content) catch {};
    } else |_| {}

    if (std.fs.createFileAbsolute(hash_path, .{})) |file| {
        defer file.close();
        file.writeAll(&fresh_hex) catch {};
    } else |_| {}

    return fresh_content;
}
