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
