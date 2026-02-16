// nanobrew — Deb dependency resolver
//
// Parses Depends: field format and resolves transitive dependencies.
// Format: "pkg (>= ver), pkg2 | pkg3, ..."
// Handles alternatives (picks first), virtual packages (skips).

const std = @import("std");
const DebPackage = @import("index.zig").DebPackage;

/// Parsed dependency entry
pub const DepEntry = struct {
    name: []const u8,
    // version constraints stored but not enforced in v0
};

/// Parse a Depends: field into individual dependency names.
/// "libc6 (>= 2.38), libcurl4t64 (= 8.5.0), zlib1g | zlib1g-dev"
/// → ["libc6", "libcurl4t64", "zlib1g"]
pub fn parseDependsField(alloc: std.mem.Allocator, depends: []const u8) ![][]const u8 {
    if (depends.len == 0) return try alloc.alloc([]const u8, 0);

    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(alloc);

    // Split by comma
    var groups = std.mem.splitScalar(u8, depends, ',');
    while (groups.next()) |group| {
        const trimmed = std.mem.trim(u8, group, " \t");
        if (trimmed.len == 0) continue;

        // Handle alternatives: "pkg1 | pkg2" → pick first
        var alternatives = std.mem.splitSequence(u8, trimmed, " | ");
        if (alternatives.next()) |first_alt| {
            const alt = std.mem.trim(u8, first_alt, " \t");
            // Strip version constraint: "pkg (>= ver)" → "pkg"
            const name = extractPackageName(alt);
            if (name.len > 0) {
                result.append(alloc, try alloc.dupe(u8, name)) catch continue;
            }
        }
    }

    return result.toOwnedSlice(alloc);
}

fn extractPackageName(s: []const u8) []const u8 {
    // "pkg (>= 1.0)" → "pkg"
    // "pkg:amd64" → "pkg" (strip arch qualifier)
    var name = s;
    if (std.mem.indexOf(u8, name, " (")) |paren| {
        name = name[0..paren];
    }
    if (std.mem.indexOf(u8, name, ":")) |colon| {
        name = name[0..colon];
    }
    return std.mem.trim(u8, name, " \t");
}

/// Resolve transitive dependencies for a list of requested packages.
/// Returns packages in topological install order (leaves first).
pub fn resolveAll(
    alloc: std.mem.Allocator,
    requested: []const []const u8,
    index: std.StringHashMap(DebPackage),
) ![]DebPackage {
    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();
    var order: std.ArrayList(DebPackage) = .empty;
    defer order.deinit(alloc);

    for (requested) |name| {
        try resolveOne(alloc, name, index, &visited, &order);
    }

    return order.toOwnedSlice(alloc);
}

fn resolveOne(
    alloc: std.mem.Allocator,
    name: []const u8,
    index: std.StringHashMap(DebPackage),
    visited: *std.StringHashMap(void),
    order: *std.ArrayList(DebPackage),
) !void {
    if (visited.contains(name)) return;
    visited.put(name, {}) catch return;

    const pkg = index.get(name) orelse return; // virtual or missing — skip

    // Resolve deps first (DFS for topological order)
    const deps = parseDependsField(alloc, pkg.depends) catch return;
    defer {
        for (deps) |d| alloc.free(d);
        alloc.free(deps);
    }

    for (deps) |dep| {
        resolveOne(alloc, dep, index, visited, order) catch continue;
    }

    order.append(alloc, pkg) catch {};
}

const testing = std.testing;

test "parseDependsField - simple deps" {
    const deps = try parseDependsField(testing.allocator, "libc6 (>= 2.38), libcurl4t64, zlib1g");
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 3), deps.len);
    try testing.expectEqualStrings("libc6", deps[0]);
    try testing.expectEqualStrings("libcurl4t64", deps[1]);
    try testing.expectEqualStrings("zlib1g", deps[2]);
}

test "parseDependsField - alternatives picks first" {
    const deps = try parseDependsField(testing.allocator, "zlib1g | zlib1g-dev, libc6");
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("zlib1g", deps[0]);
    try testing.expectEqualStrings("libc6", deps[1]);
}

test "parseDependsField - strips arch qualifier" {
    const deps = try parseDependsField(testing.allocator, "libc6:amd64 (>= 2.38)");
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("libc6", deps[0]);
}

test "parseDependsField - empty string" {
    const deps = try parseDependsField(testing.allocator, "");
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractPackageName - version constraint" {
    try testing.expectEqualStrings("pkg", extractPackageName("pkg (>= 1.0)"));
}

test "extractPackageName - bare name" {
    try testing.expectEqualStrings("curl", extractPackageName("curl"));
}
