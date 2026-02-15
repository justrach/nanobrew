// nanobrew — Homebrew JSON API client
//
// Fetches formula metadata from https://formulae.brew.sh/api/formula/<name>.json
// Uses curl for HTTP (Zig 0.15 std.http.Client API is still evolving).
// Parses JSON to extract: name, version, dependencies, bottle URL + SHA256.

const std = @import("std");
const Formula = @import("formula.zig").Formula;
const BOTTLE_TAG = @import("formula.zig").BOTTLE_TAG;
const BOTTLE_FALLBACKS = @import("formula.zig").BOTTLE_FALLBACKS;
const Cask = @import("cask.zig").Cask;
const Artifact = @import("cask.zig").Artifact;

const API_BASE = "https://formulae.brew.sh/api/formula/";
const CASK_API_BASE = "https://formulae.brew.sh/api/cask/";
const API_CACHE_DIR = "/opt/nanobrew/cache/api";

pub fn fetchFormula(alloc: std.mem.Allocator, name: []const u8) !Formula {
    // Check cache first (5 minute TTL)
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/{s}.json", .{ API_CACHE_DIR, name }) catch return error.NameTooLong;

    if (readCached(alloc, cache_path)) |cached_json| {
        const formula = parseFormulaJson(alloc, cached_json) catch {
            alloc.free(cached_json);
            return fetchAndCache(alloc, name, cache_path);
        };
        alloc.free(cached_json);
        return formula;
    }

    return fetchAndCache(alloc, name, cache_path);
}

pub fn fetchCask(alloc: std.mem.Allocator, token: []const u8) !Cask {
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/cask-{s}.json", .{ API_CACHE_DIR, token }) catch return error.NameTooLong;

    if (readCached(alloc, cache_path)) |cached_json| {
        const cask = parseCaskJson(alloc, cached_json) catch {
            alloc.free(cached_json);
            return fetchAndCacheCask(alloc, token, cache_path);
        };
        alloc.free(cached_json);
        return cask;
    }

    return fetchAndCacheCask(alloc, token, cache_path);
}

fn fetchAndCacheCask(alloc: std.mem.Allocator, token: []const u8, cache_path: []const u8) !Cask {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ CASK_API_BASE, token }) catch return error.NameTooLong;

    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sL", "--http2", url },
    }) catch return error.CurlFailed;
    defer alloc.free(run.stderr);

    if (run.term.Exited != 0 or run.stdout.len == 0) {
        alloc.free(run.stdout);
        return error.CaskNotFound;
    }

    std.fs.makeDirAbsolute(API_CACHE_DIR) catch {};
    if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
        defer file.close();
        file.writeAll(run.stdout) catch {};
    } else |_| {}

    defer alloc.free(run.stdout);
    return parseCaskJson(alloc, run.stdout);
}

fn parseCaskJson(alloc: std.mem.Allocator, json_data: []const u8) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const token = try allocDupe(alloc, getStr(root, "token") orelse return error.MissingField);
    const version = try allocDupe(alloc, getStr(root, "version") orelse return error.MissingField);
    const url = try allocDupe(alloc, getStr(root, "url") orelse return error.MissingField);
    const sha256 = try allocDupe(alloc, getStr(root, "sha256") orelse "no_check");
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");

    // name is an array, take first element
    var name: []const u8 = token;
    if (root.get("name")) |name_val| {
        if (name_val == .array and name_val.array.items.len > 0) {
            if (name_val.array.items[0] == .string) {
                name = try allocDupe(alloc, name_val.array.items[0].string);
            }
        }
    }
    if (std.mem.eql(u8, name, token)) {
        name = try allocDupe(alloc, token);
    }

    const auto_updates = if (root.get("auto_updates")) |au| au == .bool and au.bool else false;

    // Parse minimum macOS version from depends_on.macos.>=
    var min_macos: ?[]const u8 = null;
    if (root.get("depends_on")) |dep_on| {
        if (dep_on == .object) {
            if (dep_on.object.get("macos")) |macos_val| {
                if (macos_val == .object) {
                    if (macos_val.object.get(">=")) |min_val| {
                        if (min_val == .array and min_val.array.items.len > 0) {
                            if (min_val.array.items[0] == .string) {
                                min_macos = try allocDupe(alloc, min_val.array.items[0].string);
                            }
                        }
                    }
                }
            }
        }
    }

    // Parse artifacts array
    var artifacts: std.ArrayList(Artifact) = .empty;
    defer artifacts.deinit(alloc);

    if (root.get("artifacts")) |arts_val| {
        if (arts_val == .array) {
            for (arts_val.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;

                if (obj.get("app")) |app_val| {
                    if (app_val == .array) {
                        for (app_val.array.items) |a| {
                            if (a == .string) {
                                try artifacts.append(alloc, .{ .app = try allocDupe(alloc, a.string) });
                            }
                        }
                    }
                } else if (obj.get("binary")) |bin_val| {
                    if (bin_val == .array) {
                        // Homebrew binary format: ["source-path", {"target": "name"}]
                        // First string is the source, optional following object has target override
                        const items = bin_val.array.items;
                        var bi: usize = 0;
                        while (bi < items.len) : (bi += 1) {
                            if (items[bi] == .string) {
                                const source = try allocDupe(alloc, items[bi].string);
                                // Check if next element is an object with target
                                var target: []const u8 = undefined;
                                if (bi + 1 < items.len and items[bi + 1] == .object) {
                                    target = try allocDupe(alloc, getStr(items[bi + 1].object, "target") orelse std.fs.path.basename(items[bi].string));
                                    bi += 1; // skip the object
                                } else {
                                    target = try allocDupe(alloc, std.fs.path.basename(items[bi].string));
                                }
                                try artifacts.append(alloc, .{ .binary = .{ .source = source, .target = target } });
                            }
                        }
                    }
                } else if (obj.get("pkg")) |pkg_val| {
                    if (pkg_val == .array) {
                        for (pkg_val.array.items) |p| {
                            if (p == .string) {
                                try artifacts.append(alloc, .{ .pkg = try allocDupe(alloc, p.string) });
                            }
                        }
                    }
                } else if (obj.get("uninstall")) |uninst_val| {
                    if (uninst_val == .array) {
                        for (uninst_val.array.items) |u| {
                            if (u == .object) {
                                const quit = try allocDupe(alloc, getStr(u.object, "quit") orelse "");
                                const pkgutil = try allocDupe(alloc, getStr(u.object, "pkgutil") orelse "");
                                try artifacts.append(alloc, .{ .uninstall = .{ .quit = quit, .pkgutil = pkgutil } });
                            }
                        }
                    }
                }
            }
        }
    }

    return Cask{
        .token = token,
        .name = name,
        .version = version,
        .url = url,
        .sha256 = sha256,
        .desc = desc,
        .auto_updates = auto_updates,
        .artifacts = try artifacts.toOwnedSlice(alloc),
        .min_macos = min_macos,
    };
}

fn fetchAndCache(alloc: std.mem.Allocator, name: []const u8, cache_path: []const u8) !Formula {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ API_BASE, name }) catch return error.NameTooLong;

    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sL", "--http2", url },
    }) catch return error.CurlFailed;
    defer alloc.free(run.stderr);

    if (run.term.Exited != 0 or run.stdout.len == 0) {
        alloc.free(run.stdout);
        return error.FormulaNotFound;
    }

    // Write to cache
    std.fs.makeDirAbsolute(API_CACHE_DIR) catch {};
    if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
        defer file.close();
        file.writeAll(run.stdout) catch {};
    } else |_| {}

    defer alloc.free(run.stdout);
    return parseFormulaJson(alloc, run.stdout);
}

fn readCached(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    // TTL: 5 minutes
    const stat = file.stat() catch return null;
    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    if (age_ns > 300 * std.time.ns_per_s) return null;
    return file.readToEndAlloc(alloc, 2 * 1024 * 1024) catch null;
}

fn parseFormulaJson(alloc: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const name = try allocDupe(alloc, getStr(root, "name") orelse return error.MissingField);
    const version_obj = root.get("versions") orelse return error.MissingField;
    const version = try allocDupe(alloc, getStr(version_obj.object, "stable") orelse return error.MissingField);
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");

    const revision: u32 = if (root.get("revision")) |rev|
        switch (rev) {
            .integer => @intCast(@max(0, rev.integer)),
            else => 0,
        }
    else
        0;

    // Parse dependencies (unmanaged ArrayList in 0.15)
    var deps: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(alloc);
    if (root.get("dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep| {
                if (dep == .string) {
                    try deps.append(alloc, try allocDupe(alloc, dep.string));
                }
            }
        }
    }
    const dependencies = try deps.toOwnedSlice(alloc);

    var bottle_url: []const u8 = "";
    var bottle_sha256: []const u8 = "";
    var rebuild: u32 = 0;

    if (root.get("bottle")) |bottle_val| {
        if (bottle_val == .object) {
            if (bottle_val.object.get("stable")) |stable| {
                if (stable == .object) {
                    if (stable.object.get("rebuild")) |rb| {
                        if (rb == .integer) {
                            rebuild = @intCast(@max(0, rb.integer));
                        }
                    }

                    if (stable.object.get("files")) |files| {
                        if (files == .object) {
                            const tag = findBottleTag(files.object) orelse return error.NoArm64Bottle;
                            if (tag == .object) {
                                bottle_url = try allocDupe(alloc, getStr(tag.object, "url") orelse "");
                                bottle_sha256 = try allocDupe(alloc, getStr(tag.object, "sha256") orelse "");
                            }
                        }
                    }
                }
            }
        }
    }

    if (bottle_url.len == 0) return error.NoArm64Bottle;

    return Formula{
        .name = name,
        .version = version,
        .revision = revision,
        .rebuild = rebuild,
        .desc = desc,
        .dependencies = dependencies,
        .bottle_url = bottle_url,
        .bottle_sha256 = bottle_sha256,
    };
}

fn findBottleTag(files: std.json.ObjectMap) ?std.json.Value {
    if (files.get(BOTTLE_TAG)) |v| return v;
    for (BOTTLE_FALLBACKS) |tag| {
        if (files.get(tag)) |v| return v;
    }
    return null;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn allocDupe(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return alloc.dupe(u8, s);
}

const testing = std.testing;

test "parseFormulaJson - parses complete formula" {
    const json =
        \\{"name":"lame","desc":"MP3 encoder","versions":{"stable":"3.100"},"revision":0,
        \\"dependencies":["gcc"],
        \\"bottle":{"stable":{"rebuild":0,"files":{"arm64_sonoma":{"url":"https://ghcr.io/bottle/lame","sha256":"deadbeef"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("lame", f.name);
    try testing.expectEqualStrings("3.100", f.version);
    try testing.expectEqualStrings("MP3 encoder", f.desc);
    try testing.expectEqual(@as(u32, 0), f.revision);
    try testing.expectEqual(@as(u32, 0), f.rebuild);
    try testing.expectEqualStrings("https://ghcr.io/bottle/lame", f.bottle_url);
    try testing.expectEqualStrings("deadbeef", f.bottle_sha256);
}

test "parseFormulaJson - parses dependencies array" {
    const json =
        \\{"name":"ffmpeg","desc":"","versions":{"stable":"7.1"},"revision":0,
        \\"dependencies":["lame","opus","x265"],
        \\"bottle":{"stable":{"rebuild":0,"files":{"arm64_sonoma":{"url":"https://ghcr.io/bottle/ffmpeg","sha256":"cafe"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.dependencies.len);
    try testing.expectEqualStrings("lame", f.dependencies[0]);
    try testing.expectEqualStrings("opus", f.dependencies[1]);
    try testing.expectEqualStrings("x265", f.dependencies[2]);
}

test "parseFormulaJson - missing name returns error" {
    const json =
        \\{"desc":"","versions":{"stable":"1.0"},"dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"arm64_sonoma":{"url":"u","sha256":"s"}}}}}
    ;
    try testing.expectError(error.MissingField, parseFormulaJson(testing.allocator, json));
}

test "parseFormulaJson - missing versions returns error" {
    const json =
        \\{"name":"foo","desc":"","dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"arm64_sonoma":{"url":"u","sha256":"s"}}}}}
    ;
    try testing.expectError(error.MissingField, parseFormulaJson(testing.allocator, json));
}

test "findBottleTag - primary tag found" {
    const json =
        \\{"arm64_sonoma":{"url":"u1"},"all":{"url":"u2"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const result = findBottleTag(parsed.value.object);
    try testing.expect(result != null);
}

test "findBottleTag - fallback to all" {
    const json =
        \\{"x86_64_linux":{"url":"u1"},"all":{"url":"u2"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const result = findBottleTag(parsed.value.object);
    try testing.expect(result != null);
}

test "findBottleTag - no matching tag returns null" {
    const json =
        \\{"x86_64_linux":{"url":"u1"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const result = findBottleTag(parsed.value.object);
    try testing.expectEqual(@as(?std.json.Value, null), result);
}
