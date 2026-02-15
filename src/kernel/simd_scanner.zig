// zigrep — Comptime SIMD Byte Scanner
//
// Generates a specialized scanner at compile time for each simd_width.
// Zero vtable overhead, fully unrolled inner loops.
//
// Key techniques:
//   - @Vector(N, u8) for parallel byte comparison (SIMD memchr)
//   - @reduce(.Or, ...) to check if ANY lane matched
//   - First+last byte filter for substring search (Mula's technique)
//   - Software prefetch to hide memory latency

const std = @import("std");

/// Detect best SIMD width for byte operations on current target.
pub fn bestSimdWidth(comptime target: std.Target) comptime_int {
    if (target.cpu.arch == .x86_64) {
        if (std.Target.x86.featureSetHas(target.cpu.features, .avx512bw)) return 64;
        if (std.Target.x86.featureSetHas(target.cpu.features, .avx2)) return 32;
        return 16; // SSE2
    }
    if (target.cpu.arch == .aarch64) {
        return 16; // NEON: 128-bit
    }
    return 16; // Fallback
}

/// Compile-time SIMD byte scanner.
///
/// Usage:
///   const Scanner = ByteScanner(16); // 16-byte SIMD width
///   const matches = Scanner.scanFirst(haystack, 'X');
///   Scanner.scanAll(haystack, needle, callback);
pub fn ByteScanner(comptime simd_w: comptime_int) type {
    const Vec = @Vector(simd_w, u8);
    const BoolVec = @Vector(simd_w, bool);

    return struct {
        const Self = @This();

        // ── Single-byte search (memchr equivalent) ──

        /// Find first occurrence of a single byte. Returns offset or null.
        /// This is the hot path for single-character patterns and newline scanning.
        pub inline fn findFirst(haystack: []const u8, needle: u8) ?usize {
            const splat: Vec = @splat(needle);
            var offset: usize = 0;

            // SIMD main loop
            while (offset + simd_w <= haystack.len) : (offset += simd_w) {
                // Prefetch next cache line
                if (offset + simd_w * 2 <= haystack.len) {
                    @prefetch(haystack.ptr + offset + simd_w, .{});
                }

                const chunk: Vec = haystack[offset..][0..simd_w].*;
                const eq: BoolVec = chunk == splat;

                if (@reduce(.Or, eq)) {
                    // At least one lane matched — find which one
                    const mask = toBitmask(eq);
                    return offset + @ctz(mask);
                }
            }

            // Scalar tail
            while (offset < haystack.len) : (offset += 1) {
                if (haystack[offset] == needle) return offset;
            }

            return null;
        }

        /// Count occurrences of a single byte. Used for line counting.
        pub inline fn countByte(haystack: []const u8, needle: u8) usize {
            const splat: Vec = @splat(needle);
            var count: usize = 0;
            var offset: usize = 0;

            while (offset + simd_w <= haystack.len) : (offset += simd_w) {
                const chunk: Vec = haystack[offset..][0..simd_w].*;
                const eq: BoolVec = chunk == splat;
                count += @popCount(toBitmask(eq));
            }

            // Scalar tail
            while (offset < haystack.len) : (offset += 1) {
                if (haystack[offset] == needle) count += 1;
            }

            return count;
        }

        /// Find all newlines and return line start offsets.
        /// Pre-allocates using arena for zero-malloc hot path.
        pub fn findLineStarts(haystack: []const u8, out: []usize) usize {
            var count: usize = 0;
            if (count < out.len) {
                out[count] = 0; // First line always starts at 0
                count += 1;
            }

            const splat: Vec = @splat('\n');
            var offset: usize = 0;

            while (offset + simd_w <= haystack.len) : (offset += simd_w) {
                const chunk: Vec = haystack[offset..][0..simd_w].*;
                const eq: BoolVec = chunk == splat;
                var mask = toBitmask(eq);

                while (mask != 0) {
                    const bit_pos = @ctz(mask);
                    const nl_offset = offset + bit_pos;
                    if (nl_offset + 1 < haystack.len and count < out.len) {
                        out[count] = nl_offset + 1;
                        count += 1;
                    }
                    mask &= mask - 1; // Clear lowest set bit
                }
            }

            // Scalar tail
            while (offset < haystack.len) : (offset += 1) {
                if (haystack[offset] == '\n' and offset + 1 < haystack.len and count < out.len) {
                    out[count] = offset + 1;
                    count += 1;
                }
            }

            return count;
        }

        // ── Multi-byte pattern search ──

        /// SIMD-accelerated substring search.
        /// Uses first-byte filter + verify strategy:
        ///   1. SIMD scan for first byte of needle
        ///   2. Verify full match at each candidate position
        pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
            if (needle.len == 0) return 0;
            if (needle.len > haystack.len) return null;
            if (needle.len == 1) return findFirst(haystack, needle[0]);

            const first_byte: Vec = @splat(needle[0]);
            const last_byte: Vec = @splat(needle[needle.len - 1]);
            var offset: usize = 0;
            const end = haystack.len - needle.len + 1;

            while (offset + simd_w <= end) : (offset += simd_w) {
                // Prefetch ahead
                if (offset + simd_w * 2 <= end) {
                    @prefetch(haystack.ptr + offset + simd_w, .{});
                }

                // Check first byte AND last byte simultaneously
                const chunk_first: Vec = haystack[offset..][0..simd_w].*;
                const chunk_last_ptr = haystack[offset + needle.len - 1 ..];
                const chunk_last: Vec = chunk_last_ptr[0..simd_w].*;

                const eq_first: BoolVec = chunk_first == first_byte;
                const eq_last: BoolVec = chunk_last == last_byte;

                // Combine: both first AND last byte must match
                const combined: BoolVec = @bitCast(toBitmask(eq_first) & toBitmask(eq_last));

                if (@reduce(.Or, combined)) {
                    var mask = toBitmask(combined);
                    while (mask != 0) {
                        const bit_pos = @ctz(mask);
                        const candidate = offset + bit_pos;

                        // Verify full match
                        if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                            return candidate;
                        }

                        mask &= mask - 1;
                    }
                }
            }

            // Scalar tail
            while (offset < end) : (offset += 1) {
                if (std.mem.eql(u8, haystack[offset..][0..needle.len], needle)) {
                    return offset;
                }
            }

            return null;
        }

        /// Find ALL occurrences of a substring. Calls callback for each match offset.
        pub fn findAllSubstring(
            haystack: []const u8,
            needle: []const u8,
            comptime callback: fn (usize) void,
        ) void {
            if (needle.len == 0 or needle.len > haystack.len) return;

            var pos: usize = 0;
            while (pos + needle.len <= haystack.len) {
                const remaining = haystack[pos..];
                if (findSubstring(remaining, needle)) |offset| {
                    callback(pos + offset);
                    pos += offset + 1; // advance past match start
                } else {
                    break;
                }
            }
        }

        // ── Case-insensitive search ──

        /// SIMD case-insensitive single-byte search.
        pub inline fn findFirstCaseInsensitive(haystack: []const u8, needle: u8) ?usize {
            const lower = toLower(needle);
            const upper = toUpper(needle);
            if (lower == upper) return findFirst(haystack, needle);

            const splat_lower: Vec = @splat(lower);
            const splat_upper: Vec = @splat(upper);
            var offset: usize = 0;

            while (offset + simd_w <= haystack.len) : (offset += simd_w) {
                const chunk: Vec = haystack[offset..][0..simd_w].*;
                const eq_lower: BoolVec = chunk == splat_lower;
                const eq_upper: BoolVec = chunk == splat_upper;
                const combined: BoolVec = @bitCast(toBitmask(eq_lower) | toBitmask(eq_upper));

                if (@reduce(.Or, combined)) {
                    const mask = toBitmask(combined);
                    return offset + @ctz(mask);
                }
            }

            while (offset < haystack.len) : (offset += 1) {
                const c = haystack[offset];
                if (c == lower or c == upper) return offset;
            }

            return null;
        }

        // ── Internal helpers ──

        /// Convert a bool vector to a bitmask for use with @ctz/@popCount.
        inline fn toBitmask(bools: BoolVec) std.meta.Int(.unsigned, simd_w) {
            return @bitCast(bools);
        }

        inline fn toLower(c: u8) u8 {
            return if (c >= 'A' and c <= 'Z') c + 32 else c;
        }

        inline fn toUpper(c: u8) u8 {
            return if (c >= 'a' and c <= 'z') c - 32 else c;
        }
    };
}

// ── Runtime scanner (unknown SIMD width at compile time) ──

/// Fallback scanner using a conservative 16-byte SIMD width.
pub const DefaultScanner = ByteScanner(16);

// ── Tests ──

test "findFirst - basic" {
    const S = ByteScanner(16);
    const hay = "Hello, World!";
    try std.testing.expectEqual(@as(?usize, 7), S.findFirst(hay, 'W'));
    try std.testing.expectEqual(@as(?usize, 0), S.findFirst(hay, 'H'));
    try std.testing.expectEqual(@as(?usize, null), S.findFirst(hay, 'X'));
}

test "findFirst - long string" {
    const S = ByteScanner(16);
    const hay = "a" ** 100 ++ "X" ++ "b" ** 100;
    try std.testing.expectEqual(@as(?usize, 100), S.findFirst(hay, 'X'));
}

test "countByte - newlines" {
    const S = ByteScanner(16);
    const text = "line1\nline2\nline3\nline4\n";
    try std.testing.expectEqual(@as(usize, 4), S.countByte(text, '\n'));
}

test "findSubstring - basic" {
    const S = ByteScanner(16);
    try std.testing.expectEqual(@as(?usize, 7), S.findSubstring("Hello, World!", "World"));
    try std.testing.expectEqual(@as(?usize, 0), S.findSubstring("Hello", "Hello"));
    try std.testing.expectEqual(@as(?usize, null), S.findSubstring("Hello", "Worlds"));
}

test "findSubstring - repeated pattern" {
    const S = ByteScanner(16);
    const hay = "abcabcabcXYZabc";
    try std.testing.expectEqual(@as(?usize, 9), S.findSubstring(hay, "XYZ"));
}

test "findFirstCaseInsensitive" {
    const S = ByteScanner(16);
    try std.testing.expectEqual(@as(?usize, 0), S.findFirstCaseInsensitive("Hello", 'h'));
    try std.testing.expectEqual(@as(?usize, 0), S.findFirstCaseInsensitive("hello", 'H'));
}

test "findLineStarts" {
    const S = ByteScanner(16);
    var buf: [64]usize = undefined;
    const text = "line1\nline2\nline3\n";
    const count = S.findLineStarts(text, &buf);
    try std.testing.expectEqual(@as(usize, 0), buf[0]); // First line
    try std.testing.expectEqual(@as(usize, 6), buf[1]); // "line2\n"
    try std.testing.expectEqual(@as(usize, 12), buf[2]); // "line3\n"
    try std.testing.expect(count >= 3);
}
