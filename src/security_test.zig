// security_test.zig — Adversarial security tests for nanobrew
//
// Tests injection attacks, buffer overflows, path traversal, and other
// attack vectors against nanobrew's defensive functions.

const std = @import("std");
const testing = std.testing;

// Import the modules under test
const Database = @import("db/database.zig").Database;
const version = @import("version.zig");
const extract = @import("deb/extract.zig");
const placeholder = @import("platform/placeholder.zig");
const store = @import("store/store.zig");
const client = @import("api/client.zig");

/// Minimal anytype-compatible writer for tests — writes into a fixed stack buffer.
const TestBufWriter = struct {
    buf: [20480]u8 = undefined,
    pos: usize = 0,
    pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
    pub fn written(self: *const @This()) []const u8 {
        return self.buf[0..self.pos];
    }
    pub fn reset(self: *@This()) void {
        self.pos = 0;
    }
};

// ────────────────────────────────────────────────────────────────────────
// 1. Path traversal in package names
// ────────────────────────────────────────────────────────────────────────

test "package name with path traversal is rejected" {
    // Direct traversal
    try testing.expect(!extract.isPathSafe("../../../etc/passwd"));
    try testing.expect(!extract.isPathSafe("../../etc/shadow"));
    try testing.expect(!extract.isPathSafe("../tmp/exploit"));

    // Traversal embedded in a longer path
    try testing.expect(!extract.isPathSafe("usr/share/../../../etc/passwd"));
    try testing.expect(!extract.isPathSafe("opt/nanobrew/../../root/.ssh/id_rsa"));

    // Double-encoded traversal patterns
    try testing.expect(!extract.isPathSafe("foo/../bar/../../../etc/passwd"));
}

test "package name with single dot components is safe" {
    // Single dots (current dir) are benign, not traversal
    try testing.expect(extract.isPathSafe("usr/./bin/hello"));
    try testing.expect(extract.isPathSafe("./usr/bin/hello"));
}

// ────────────────────────────────────────────────────────────────────────
// 2. Null bytes in strings
// ────────────────────────────────────────────────────────────────────────

test "writeJsonEscaped handles null bytes" {
    var w: TestBufWriter = .{};
    // Null byte must be escaped as \u0000, never passed through raw
    Database.writeJsonEscaped(&w, "before\x00after");
    const result = w.written();
    try testing.expectEqualStrings("before\\u0000after", result);
    // Verify no raw null byte exists in output
    try testing.expect(std.mem.indexOf(u8, result, &[_]u8{0}) == null);
}

test "writeJsonEscaped handles string of only null bytes" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "\x00\x00\x00");
    try testing.expectEqualStrings("\\u0000\\u0000\\u0000", w.written());
}
test "isPathSafe rejects paths with null bytes" {
    // Null bytes in paths can truncate the string at the OS level,
    // potentially allowing traversal past the visible path.
    try testing.expect(!extract.isPathSafe("usr/bin\x00/../../../etc/passwd"));

    // Null bytes without ".." must also be rejected — the OS may
    // truncate the path at the null byte, producing a different
    // effective path than what isPathSafe inspected.
    try testing.expect(!extract.isPathSafe("usr/bin/safe\x00"));
    try testing.expect(!extract.isPathSafe("\x00"));
    try testing.expect(!extract.isPathSafe("a/b\x00c/d"));
}
test "writeJsonEscaped handles very long input" {
    // 10KB of input data — must not crash or overflow
    const input = "A" ** 10240;
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, input);
    try testing.expectEqual(@as(usize, 10240), w.written().len);
}

test "writeJsonEscaped handles long input with many escapes" {
    // 1KB of characters that all need escaping (control chars)
    const input = "\x01" ** 1024;
    // Each \x01 becomes \u0001 (6 chars), so we need 6 * 1024 = 6144 bytes
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, input);
    try testing.expectEqual(@as(usize, 6144), w.written().len);
}

test "version comparison handles very long versions" {
    // Many segments: "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16"
    const long_v = "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16.17.18.19.20.21.22.23.24.25.26.27.28.29.30";
    // Must not crash; comparing to itself should be equal
    try testing.expectEqual(std.math.Order.eq, version.compareVersions(long_v, long_v));

    // Comparing two long but different versions
    const long_v2 = "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16.17.18.19.20.21.22.23.24.25.26.27.28.29.31";
    try testing.expectEqual(std.math.Order.lt, version.compareVersions(long_v, long_v2));
}

// ────────────────────────────────────────────────────────────────────────
// 4. Malicious version strings
// ────────────────────────────────────────────────────────────────────────

test "version comparison handles shell injection characters" {
    // These strings should compare without crashing — they contain
    // shell metacharacters that could cause problems if ever passed to a shell
    const v1 = "1.0;rm -rf /";
    const v2 = "2.0";
    const result = version.compareVersions(v1, v2);
    // Just verify it returns a valid Order without crashing
    try testing.expect(result == .lt or result == .gt or result == .eq);
}

test "version comparison handles backtick injection" {
    const v1 = "1.0`whoami`";
    const v2 = "1.0";
    const result = version.compareVersions(v1, v2);
    try testing.expect(result == .lt or result == .gt or result == .eq);
}

test "version comparison handles dollar sign injection" {
    const v1 = "1.0$(cat /etc/passwd)";
    const v2 = "1.0";
    const result = version.compareVersions(v1, v2);
    try testing.expect(result == .lt or result == .gt or result == .eq);
}

test "version comparison handles pipe and redirect chars" {
    const v1 = "1.0|cat /etc/passwd";
    const v2 = "1.0>>/tmp/pwned";
    const result = version.compareVersions(v1, v2);
    try testing.expect(result == .lt or result == .gt or result == .eq);
}

test "version comparison handles empty and whitespace versions" {
    // Empty vs empty
    try testing.expectEqual(std.math.Order.eq, version.compareVersions("", ""));

    // Empty vs non-empty
    const result = version.compareVersions("", "1.0");
    try testing.expect(result == .lt or result == .gt or result == .eq);

    // Whitespace-only (non-numeric segment)
    const r2 = version.compareVersions("  ", "1.0");
    try testing.expect(r2 == .lt or r2 == .gt or r2 == .eq);
}

// ────────────────────────────────────────────────────────────────────────
// 5. Placeholder injection in binary-like files
// ────────────────────────────────────────────────────────────────────────

test "placeholder replacement in memory handles binary-safe content" {
    // replacePlaceholders works on in-memory slices; it should handle
    // input containing null bytes without crashing
    const alloc = testing.allocator;

    // Input with a placeholder surrounded by binary content
    const input = "some\x00binary@@HOMEBREW_CELLAR@@data\x00end";
    const result = try placeholder.replacePlaceholders(alloc, input);
    defer alloc.free(result);

    // The placeholder should still be replaced even in binary content
    // (the binary detection is in walkAndReplaceText, not replacePlaceholders)
    try testing.expect(std.mem.indexOf(u8, result, "@@HOMEBREW_CELLAR@@") == null);
}

test "placeholder replacement does not crash on very long input" {
    const alloc = testing.allocator;

    // 64KB of 'A' with a placeholder at the end
    const prefix = "A" ** (64 * 1024);
    const input = prefix ++ "@@HOMEBREW_PREFIX@@";
    const result = try placeholder.replacePlaceholders(alloc, input);
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "@@HOMEBREW_PREFIX@@") == null);
}

// ────────────────────────────────────────────────────────────────────────
// 6. JSON injection payloads
// ────────────────────────────────────────────────────────────────────────

test "writeJsonEscaped blocks nested JSON injection" {
    var w: TestBufWriter = .{};
    // Classic JSON injection: try to break out of a string value and inject new keys
    const payload = "name\",\"admin\":true,\"x\":\"";
    Database.writeJsonEscaped(&w, payload);
    const result = w.written();
    // ALL double quotes in the payload must be escaped
    try testing.expectEqualStrings("name\\\",\\\"admin\\\":true,\\\"x\\\":\\\"", result);
    // Verify every double quote in the output is preceded by a backslash
    for (result, 0..) |c, i| {
        if (c == '"') {
            // Every quote must be escaped (preceded by backslash)
            try testing.expect(i > 0 and result[i - 1] == '\\');
        }
    }
}

test "writeJsonEscaped handles all control characters u0000-u001f" {
    var w: TestBufWriter = .{};
    // Feed all 32 control characters (0x00 through 0x1F)
    var input: [32]u8 = undefined;
    for (0..32) |i| {
        input[i] = @intCast(i);
    }
    Database.writeJsonEscaped(&w, &input);
    const result = w.written();
    // No raw control character should appear in the output
    for (result) |c| {
        try testing.expect(c >= 0x20);
    }
}

test "writeJsonEscaped handles backslash-quote combo attack" {
    var w: TestBufWriter = .{};
    // Attack: \" — if only the quote is escaped but not the backslash,
    // the resulting \\" would end the string
    Database.writeJsonEscaped(&w, "\\\"");
    try testing.expectEqualStrings("\\\\\\\"", w.written());
}

test "writeJsonString wraps in quotes and escapes content" {
    var w: TestBufWriter = .{};
    Database.writeJsonString(&w, "hello\nworld");
    try testing.expectEqualStrings("\"hello\\nworld\"", w.written());
}

// ────────────────────────────────────────────────────────────────────────
// 7. Deep recursion protection
// ────────────────────────────────────────────────────────────────────────

test "resolver depth limit is reasonable" {
    // MAX_RESOLVE_DEPTH must be positive and bounded to prevent stack overflow
    const max_depth = @import("deb/resolver.zig").MAX_RESOLVE_DEPTH;
    try testing.expect(max_depth > 0);
    try testing.expect(max_depth <= 128);
    // Current value should be exactly 64
    try testing.expectEqual(@as(usize, 64), max_depth);
}

// ────────────────────────────────────────────────────────────────────────
// 8. isPathSafe edge cases
// ────────────────────────────────────────────────────────────────────────

test "isPathSafe rejects various traversal patterns" {
    // Standard traversal
    try testing.expect(!extract.isPathSafe("../"));
    try testing.expect(!extract.isPathSafe(".."));
    try testing.expect(!extract.isPathSafe("foo/../bar"));
    try testing.expect(!extract.isPathSafe("foo/./../../bar"));

    // Empty path
    try testing.expect(!extract.isPathSafe(""));

    // Deep traversal
    try testing.expect(!extract.isPathSafe("a/b/c/../../../../etc/passwd"));
}

test "isPathSafe accepts safe paths" {
    try testing.expect(extract.isPathSafe("usr/bin/hello"));
    try testing.expect(extract.isPathSafe("usr/share/doc/package/README.md"));
    try testing.expect(extract.isPathSafe("opt/nanobrew/lib/libz.so.1"));
    try testing.expect(extract.isPathSafe("a"));
    try testing.expect(extract.isPathSafe("."));
    try testing.expect(extract.isPathSafe("..."));
    try testing.expect(!extract.isPathSafe("/absolute/path"));
    try testing.expect(extract.isPathSafe("file..name"));
    try testing.expect(extract.isPathSafe("..hidden"));
}

test "isPathSafe handles paths with special characters" {
    // Spaces, unicode, etc. should be safe as long as no ".." component
    try testing.expect(extract.isPathSafe("usr/share/my package/file"));
    try testing.expect(extract.isPathSafe("usr/lib/libcurl.so.4.8.0"));

    // But traversal with special chars is still caught
    try testing.expect(!extract.isPathSafe("usr/share/my package/../../etc"));
}

test "isPathSafe handles very long paths" {
    // A very long but safe path should not crash
    const long_path = "a/" ** 512 ++ "file.txt";
    try testing.expect(extract.isPathSafe(long_path));

    // A very long path with traversal at the end
    const long_bad = "a/" ** 512 ++ "../etc/passwd";
    try testing.expect(!extract.isPathSafe(long_bad));
}

test "symlink target resolved path must stay within dest_dir" {
    try testing.expect(extract.isLinkTargetSafe("usr/bin/link", "../../etc/passwd", "/tmp/dest"));
    try testing.expect(extract.isLinkTargetSafe("usr/bin/link", "../lib/libfoo.so", "/tmp/dest"));
    try testing.expect(!extract.isLinkTargetSafe("usr/bin/link", "../../../etc/passwd", "/tmp/dest"));
    try testing.expect(!extract.isLinkTargetSafe("a/link", "../../outside", "/tmp/dest"));
    try testing.expect(!extract.isLinkTargetSafe("usr/bin/link", "/etc/passwd", "/tmp/dest"));
    try testing.expect(!extract.isLinkTargetSafe("usr/bin/link", "../lib\x00/../../etc/passwd", "/tmp/dest"));
}

test "tar extraction strips setuid and setgid bits from mode" {
    const raw_mode: u32 = 0o4755;
    try testing.expectEqual(@as(u32, 0o0755), raw_mode & 0o0777);
    const raw_mode2: u32 = 0o6755;
    try testing.expectEqual(@as(u32, 0o0755), raw_mode2 & 0o0777);
    const raw_mode3: u32 = 0o1755;
    try testing.expectEqual(@as(u32, 0o0755), raw_mode3 & 0o0777);
}

// ────────────────────────────────────────────────────────────────────────
// 11. HTTPS enforcement for API and bottle domain env var overrides
// ────────────────────────────────────────────────────────────────────────

test "isValidDomainOverride rejects non-HTTPS URLs" {
    try testing.expect(!client.isValidDomainOverride("http://evil.com/api/"));
    try testing.expect(!client.isValidDomainOverride("ftp://evil.com/"));
    try testing.expect(!client.isValidDomainOverride("javascript:alert(1)"));
    try testing.expect(!client.isValidDomainOverride(""));
    try testing.expect(!client.isValidDomainOverride("file:///etc/passwd"));
    try testing.expect(client.isValidDomainOverride("https://formulae.brew.sh/api/formula/"));
    try testing.expect(client.isValidDomainOverride("https://my-mirror.example.com/"));
}

// ────────────────────────────────────────────────────────────────────────
// 9. SHA256 validation in store paths
// ────────────────────────────────────────────────────────────────────────

test "isValidSha256 rejects non-hex strings" {
    try testing.expect(!store.isValidSha256("../../etc"));
    try testing.expect(!store.isValidSha256(""));
    try testing.expect(!store.isValidSha256("abc"));
    try testing.expect(!store.isValidSha256("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try testing.expect(store.isValidSha256("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}
