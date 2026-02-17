// nanobrew — Deb dependency resolver
//
// Parses Depends: field format and resolves transitive dependencies.
// Format: "pkg (>= ver), pkg2 | pkg3, ..."
// Handles alternatives (picks first available), virtual packages (via provides_map).

const std = @import("std");
const DebPackage = @import("index.zig").DebPackage;

/// Parsed dependency entry
pub const DepEntry = struct {
    name: []const u8,
    // version constraints stored but not enforced in v0
};

/// Parse a Depends: field into individual dependency names.
/// When an index is provided, alternatives are resolved by picking the first
/// that exists in the index or provides_map. Without an index, picks the first alternative.
pub fn parseDependsField(
    alloc: std.mem.Allocator,
    depends: []const u8,
    index: ?std.StringHashMap(DebPackage),
    provides_map: ?std.StringHashMap([]const u8),
) ![][]const u8 {
    if (depends.len == 0) return try alloc.alloc([]const u8, 0);

    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(alloc);

    // Split by comma
    var groups = std.mem.splitScalar(u8, depends, ',');
    while (groups.next()) |group| {
        const trimmed = std.mem.trim(u8, group, " \t");
        if (trimmed.len == 0) continue;

        // Handle alternatives: "pkg1 | pkg2" → pick first available in index
        var alternatives = std.mem.splitSequence(u8, trimmed, " | ");
        var picked: ?[]const u8 = null;

        while (alternatives.next()) |alt_raw| {
            const alt = std.mem.trim(u8, alt_raw, " \t");
            const name = extractPackageName(alt);
            if (name.len == 0) continue;

            if (index) |idx| {
                // Check if this alternative exists in the real package index
                if (idx.contains(name)) {
                    picked = name;
                    break;
                }
                // Check if it exists as a virtual package
                if (provides_map) |pmap| {
                    if (pmap.contains(name)) {
                        picked = name;
                        break;
                    }
                }
            } else {
                // No index available — pick first alternative
                picked = name;
                break;
            }
        }

        // Fall back to first alternative if none found in index
        if (picked == null) {
            var fallback = std.mem.splitSequence(u8, trimmed, " | ");
            if (fallback.next()) |first_alt| {
                const alt = std.mem.trim(u8, first_alt, " \t");
                picked = extractPackageName(alt);
            }
        }

        if (picked) |name| {
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
    provides_map: ?std.StringHashMap([]const u8),
) ![]DebPackage {
    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();
    var order: std.ArrayList(DebPackage) = .empty;
    defer order.deinit(alloc);

    for (requested) |name| {
        try resolveOne(alloc, name, index, provides_map, &visited, &order);
    }

    return order.toOwnedSlice(alloc);
}

fn resolveOne(
    alloc: std.mem.Allocator,
    name: []const u8,
    index: std.StringHashMap(DebPackage),
    provides_map: ?std.StringHashMap([]const u8),
    visited: *std.StringHashMap(void),
    order: *std.ArrayList(DebPackage),
) !void {
    if (visited.contains(name)) return;
    visited.put(name, {}) catch return;

    // Try direct lookup first, then virtual package lookup
    const pkg = index.get(name) orelse blk: {
        if (provides_map) |pmap| {
            if (pmap.get(name)) |real_name| {
                break :blk index.get(real_name);
            }
        }
        break :blk null;
    } orelse return; // truly missing — skip

    // Resolve deps first (DFS for topological order)
    const deps = parseDependsField(alloc, pkg.depends, index, provides_map) catch return;
    defer {
        for (deps) |d| alloc.free(d);
        alloc.free(deps);
    }

    for (deps) |dep| {
        resolveOne(alloc, dep, index, provides_map, visited, order) catch continue;
    }

    order.append(alloc, pkg) catch {};
}

const testing = std.testing;

test "parseDependsField - simple deps" {
    const deps = try parseDependsField(testing.allocator, "libc6 (>= 2.38), libcurl4t64, zlib1g", null, null);
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
    const deps = try parseDependsField(testing.allocator, "zlib1g | zlib1g-dev, libc6", null, null);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("zlib1g", deps[0]);
    try testing.expectEqualStrings("libc6", deps[1]);
}

test "parseDependsField - strips arch qualifier" {
    const deps = try parseDependsField(testing.allocator, "libc6:amd64 (>= 2.38)", null, null);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("libc6", deps[0]);
}

test "parseDependsField - empty string" {
    const deps = try parseDependsField(testing.allocator, "", null, null);
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractPackageName - version constraint" {
    try testing.expectEqualStrings("pkg", extractPackageName("pkg (>= 1.0)"));
}

test "extractPackageName - bare name" {
    try testing.expectEqualStrings("curl", extractPackageName("curl"));
}

test "parseDependsField - alternatives picks available in index" {
    const alloc = testing.allocator;
    const index_mod = @import("index.zig");

    // Build an index with only "zlib1g-dev" (not "zlib1g")
    var idx = std.StringHashMap(index_mod.DebPackage).init(alloc);
    defer idx.deinit();
    idx.put("zlib1g-dev", .{
        .name = "zlib1g-dev",
        .version = "1.3",
        .depends = "",
        .provides = "",
        .filename = "pool/main/z/zlib.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;
    idx.put("libc6", .{
        .name = "libc6",
        .version = "2.38",
        .depends = "",
        .provides = "",
        .filename = "pool/main/g/glibc.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;

    // "zlib1g | zlib1g-dev" should pick zlib1g-dev since zlib1g isn't in index
    const deps = try parseDependsField(alloc, "zlib1g | zlib1g-dev, libc6", idx, null);
    defer {
        for (deps) |d| alloc.free(d);
        alloc.free(deps);
    }
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("zlib1g-dev", deps[0]);
    try testing.expectEqualStrings("libc6", deps[1]);
}

test "parseDependsField - alternatives falls back to first when none in index" {
    const alloc = testing.allocator;
    const index_mod = @import("index.zig");

    // Empty index — neither alternative exists
    var idx = std.StringHashMap(index_mod.DebPackage).init(alloc);
    defer idx.deinit();

    const deps = try parseDependsField(alloc, "missing1 | missing2", idx, null);
    defer {
        for (deps) |d| alloc.free(d);
        alloc.free(deps);
    }
    // Falls back to first alternative
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("missing1", deps[0]);
}

test "parseDependsField - alternatives picks virtual package from provides_map" {
    const alloc = testing.allocator;
    const index_mod = @import("index.zig");

    // Index has "gcc-14" but not "c-compiler"
    var idx = std.StringHashMap(index_mod.DebPackage).init(alloc);
    defer idx.deinit();
    idx.put("gcc-14", .{
        .name = "gcc-14",
        .version = "14.2.0",
        .depends = "",
        .provides = "c-compiler",
        .filename = "pool/main/g/gcc-14.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;

    // Provides map: c-compiler → gcc-14
    var pmap = std.StringHashMap([]const u8).init(alloc);
    defer pmap.deinit();
    pmap.put("c-compiler", "gcc-14") catch unreachable;

    // "c-compiler | clang" — c-compiler is in provides_map, should be picked
    const deps = try parseDependsField(alloc, "c-compiler | clang", idx, pmap);
    defer {
        for (deps) |d| alloc.free(d);
        alloc.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("c-compiler", deps[0]);
}

test "resolveAll - resolves through provides_map" {
    const alloc = testing.allocator;
    const index_mod = @import("index.zig");

    // Build index: gcc-14 provides c-compiler, build-essential depends on c-compiler
    var idx = std.StringHashMap(index_mod.DebPackage).init(alloc);
    defer idx.deinit();

    idx.put("build-essential", .{
        .name = "build-essential",
        .version = "12.10",
        .depends = "c-compiler, make",
        .provides = "",
        .filename = "pool/main/b/build-essential.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;

    idx.put("gcc-14", .{
        .name = "gcc-14",
        .version = "14.2.0",
        .depends = "",
        .provides = "c-compiler",
        .filename = "pool/main/g/gcc-14.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;

    idx.put("make", .{
        .name = "make",
        .version = "4.3",
        .depends = "",
        .provides = "",
        .filename = "pool/main/m/make.deb",
        .sha256 = "",
        .size = 0,
        .description = "",
    }) catch unreachable;

    // Provides map: c-compiler → gcc-14
    var pmap = std.StringHashMap([]const u8).init(alloc);
    defer pmap.deinit();
    pmap.put("c-compiler", "gcc-14") catch unreachable;

    const order = try resolveAll(alloc, &.{"build-essential"}, idx, pmap);
    defer {
        alloc.free(order);
    }

    // Should resolve: gcc-14 (via c-compiler provides), make, build-essential
    // Order: deps first, then the requested package
    try testing.expect(order.len >= 2); // at least make + build-essential

    // build-essential should be last (deps resolved first)
    try testing.expectEqualStrings("build-essential", order[order.len - 1].name);

    // gcc-14 and make should appear before build-essential
    var found_gcc = false;
    var found_make = false;
    for (order[0 .. order.len - 1]) |pkg| {
        if (std.mem.eql(u8, pkg.name, "gcc-14")) found_gcc = true;
        if (std.mem.eql(u8, pkg.name, "make")) found_make = true;
    }
    try testing.expect(found_gcc);
    try testing.expect(found_make);
}
