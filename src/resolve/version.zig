// nanobrew — Semantic version comparison
//
// Compares Homebrew version strings like "1.2.3", "10.47_1", "0.1.067".
// Handles numeric components, underscore-separated revision suffixes,
// and varying-length version segments correctly.

const std = @import("std");

/// Compare two version strings. Returns:
///   .gt if a > b, .lt if a < b, .eq if equal.
///
/// Rules:
///   1. Split on '.' to get segments
///   2. Each segment may have a '_' suffix (e.g. "47_1") — the part before '_'
///      is the primary, the part after is the revision (default 0)
///   3. Compare segments left-to-right numerically
///   4. A version with more segments is greater if all preceding match
///      (e.g. "0.1.067" > "0.1.06")
pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    var a_iter = std.mem.splitScalar(u8, a, '.');
    var b_iter = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const a_seg = a_iter.next();
        const b_seg = b_iter.next();

        if (a_seg == null and b_seg == null) return .eq;
        if (a_seg == null) return .lt;
        if (b_seg == null) return .gt;

        const ord = compareSegment(a_seg.?, b_seg.?);
        if (ord != .eq) return ord;
    }
}

fn compareSegment(a: []const u8, b: []const u8) std.math.Order {
    const a_parts = splitRevision(a);
    const b_parts = splitRevision(b);

    const a_num = std.fmt.parseInt(u64, a_parts.primary, 10) catch 0;
    const b_num = std.fmt.parseInt(u64, b_parts.primary, 10) catch 0;

    if (a_num != b_num) return std.math.order(a_num, b_num);

    return std.math.order(a_parts.revision, b_parts.revision);
}

const SegmentParts = struct {
    primary: []const u8,
    revision: u32,
};

fn splitRevision(seg: []const u8) SegmentParts {
    if (std.mem.indexOfScalar(u8, seg, '_')) |idx| {
        return .{
            .primary = seg[0..idx],
            .revision = std.fmt.parseInt(u32, seg[idx + 1 ..], 10) catch 0,
        };
    }
    return .{ .primary = seg, .revision = 0 };
}

/// Returns true if `available` is strictly newer than `installed`.
pub fn isNewer(installed: []const u8, available: []const u8) bool {
    return compare(available, installed) == .gt;
}

// ── Tests ──

const testing = std.testing;

test "equal versions" {
    try testing.expectEqual(std.math.Order.eq, compare("1.2.3", "1.2.3"));
    try testing.expectEqual(std.math.Order.eq, compare("0", "0"));
    try testing.expectEqual(std.math.Order.eq, compare("10.47_1", "10.47_1"));
}

test "simple numeric comparison" {
    try testing.expectEqual(std.math.Order.gt, compare("2.0", "1.0"));
    try testing.expectEqual(std.math.Order.lt, compare("1.0", "2.0"));
    try testing.expectEqual(std.math.Order.gt, compare("1.10", "1.9"));
    try testing.expectEqual(std.math.Order.gt, compare("10.0", "9.99"));
}

test "issue #7: 0.1.067 vs 0.1.06 — more segments means greater" {
    // 067 (=67) > 06 (=6), so 0.1.067 > 0.1.06
    try testing.expectEqual(std.math.Order.gt, compare("0.1.067", "0.1.06"));
    try testing.expect(!isNewer("0.1.067", "0.1.06"));
}

test "issue #7: underscore revision — 10.47_1 vs 10.47" {
    // 10.47_1 > 10.47 (revision 1 > revision 0)
    try testing.expectEqual(std.math.Order.gt, compare("10.47_1", "10.47"));
    try testing.expect(!isNewer("10.47_1", "10.47"));
}

test "underscore revision ordering" {
    try testing.expectEqual(std.math.Order.lt, compare("10.47", "10.47_1"));
    try testing.expectEqual(std.math.Order.lt, compare("10.47_1", "10.47_2"));
    try testing.expectEqual(std.math.Order.gt, compare("10.47_3", "10.47_2"));
}

test "different segment counts" {
    // More segments = greater when prefix matches
    try testing.expectEqual(std.math.Order.gt, compare("1.2.3", "1.2"));
    try testing.expectEqual(std.math.Order.lt, compare("1.2", "1.2.3"));
    // But earlier segment wins
    try testing.expectEqual(std.math.Order.gt, compare("2.0", "1.9.9"));
}

test "isNewer convenience function" {
    try testing.expect(isNewer("1.0", "2.0"));
    try testing.expect(!isNewer("2.0", "1.0"));
    try testing.expect(!isNewer("1.0", "1.0"));
    try testing.expect(isNewer("3.1.0", "3.1.0_1"));
    try testing.expect(!isNewer("3.1.0_1", "3.1.0"));
}

test "real-world homebrew versions" {
    // python 3.12.2 -> 3.13.0
    try testing.expect(isNewer("3.12.2", "3.13.0"));
    // node 21.6.1 -> 21.6.2
    try testing.expect(isNewer("21.6.1", "21.6.2"));
    // pcre2 10.42 -> 10.43
    try testing.expect(isNewer("10.42", "10.43"));
    // same version is not newer
    try testing.expect(!isNewer("14.2.1", "14.2.1"));
}

test "leading zeros treated as numeric" {
    // "067" parses as 67, "06" as 6
    try testing.expectEqual(std.math.Order.gt, compare("067", "06"));
    try testing.expectEqual(std.math.Order.eq, compare("06", "6"));
    try testing.expectEqual(std.math.Order.eq, compare("007", "7"));
}
