// nanobrew — Homebrew JSON API client
//
// Fetches formula metadata from https://formulae.brew.sh/api/formula/<name>.json
// Uses native Zig HTTP client (no curl dependency).
// Parses JSON to extract: name, version, dependencies, bottle URL + SHA256.
const std = @import("std");
const builtin = @import("builtin");
const Formula = @import("formula.zig").Formula;
const BOTTLE_TAG = @import("formula.zig").BOTTLE_TAG;
const BOTTLE_FALLBACKS = @import("formula.zig").BOTTLE_FALLBACKS;
const Cask = @import("cask.zig").Cask;
const Artifact = @import("cask.zig").Artifact;
const tap = @import("tap.zig");
const fetch = @import("../net/fetch.zig");

const API_BASE = "https://formulae.brew.sh/api/formula/";
const CASK_API_BASE = "https://formulae.brew.sh/api/cask/";

pub fn isValidDomainOverride(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len;
}

/// Append `/formula/` or `/cask/` when the mirror only gives `.../api` (#104).
fn normalizeFormulaApiPrefix(scratch: *[512]u8, e: []const u8) []const u8 {
    if (std.mem.indexOf(u8, e, "/formula/") != null) return e;
    const trimmed = std.mem.trimEnd(u8, e, "/");
    if (std.mem.endsWith(u8, trimmed, "/formula")) {
        return std.fmt.bufPrint(scratch, "{s}/", .{trimmed}) catch API_BASE;
    }
    if (std.mem.endsWith(u8, trimmed, "/api")) {
        return std.fmt.bufPrint(scratch, "{s}/formula/", .{trimmed}) catch API_BASE;
    }
    return std.fmt.bufPrint(scratch, "{s}/formula/", .{trimmed}) catch API_BASE;
}

fn normalizeCaskApiPrefix(scratch: *[512]u8, e: []const u8) []const u8 {
    if (std.mem.indexOf(u8, e, "/cask/") != null) return e;
    const trimmed = std.mem.trimEnd(u8, e, "/");
    if (std.mem.endsWith(u8, trimmed, "/cask")) {
        return std.fmt.bufPrint(scratch, "{s}/", .{trimmed}) catch CASK_API_BASE;
    }
    if (std.mem.endsWith(u8, trimmed, "/api")) {
        return std.fmt.bufPrint(scratch, "{s}/cask/", .{trimmed}) catch CASK_API_BASE;
    }
    return std.fmt.bufPrint(scratch, "{s}/cask/", .{trimmed}) catch CASK_API_BASE;
}

fn normalizedFormulaApiBase(scratch: *[512]u8) []const u8 {
    if (std.c.getenv("NANOBREW_API_DOMAIN")) |_cv| { const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeFormulaApiPrefix(scratch, d);
    }
    if (std.c.getenv("HOMEBREW_API_DOMAIN")) |_cv| { const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeFormulaApiPrefix(scratch, d);
    }
    return API_BASE;
}

fn normalizedCaskApiBase(scratch: *[512]u8) []const u8 {
    if (std.c.getenv("NANOBREW_API_DOMAIN")) |_cv| { const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeCaskApiPrefix(scratch, d);
    }
    if (std.c.getenv("HOMEBREW_API_DOMAIN")) |_cv| { const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeCaskApiPrefix(scratch, d);
    }
    return CASK_API_BASE;
}
const API_CACHE_DIR = @import("../platform/paths.zig").API_CACHE_DIR;


pub fn fetchFormula(alloc: std.mem.Allocator, name: []const u8) !Formula {
    return fetchFormulaWithClient(alloc, null, name);
}

/// Fetch formula using a shared HTTP client (avoids repeated TLS handshakes).
pub fn fetchFormulaWithClient(alloc: std.mem.Allocator, client: ?*std.http.Client, name: []const u8) !Formula {
    // Tap formula: "user/tap/formula" -> fetch from GitHub
    if (isTapRef(name)) {
        return tap.fetchTapFormula(alloc, client, name);
    }

    // Check cache first (5 minute TTL)
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/{s}.json", .{ API_CACHE_DIR, name }) catch return error.NameTooLong;

    if (readCached(alloc, cache_path)) |cached_json| {
        const formula = parseFormulaJson(alloc, cached_json) catch {
            alloc.free(cached_json);
            return fetchAndCache(alloc, client, name, cache_path);
        };
        alloc.free(cached_json);
        return formula;
    }

    return fetchAndCache(alloc, client, name, cache_path);
}

fn isTapRef(name: []const u8) bool {
    var count: usize = 0;
    for (name) |c| {
        if (c == '/') count += 1;
    }
    return count == 2;
}

pub fn fetchCask(alloc: std.mem.Allocator, token: []const u8) !Cask {
    // Tap cask: "user/tap/cask" -> fetch from GitHub
    if (tap.parseTapRef(token) != null) {
        return tap.fetchTapCask(alloc, token);
    }

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
    var base_buf: [512]u8 = undefined;
    const base = normalizedCaskApiBase(&base_buf);
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ base, token }) catch return error.NameTooLong;

    const body = fetch.get(alloc, url) catch return error.CaskNotFound;

    std.Io.Dir.createDirAbsolute(std.Io.Threaded.global_single_threaded.io(), API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), cache_path, .{})) |file| {
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), body) catch {};
    } else |_| {}

    defer alloc.free(body);
    return parseCaskJson(alloc, body);
}

fn parseCaskJson(alloc: std.mem.Allocator, json_data: []const u8) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const token = try allocDupe(alloc, getStr(root, "token") orelse return error.MissingField);
    errdefer alloc.free(token);
    const version = try allocDupe(alloc, getStr(root, "version") orelse return error.MissingField);
    errdefer alloc.free(version);
    const url = try allocDupe(alloc, getStr(root, "url") orelse return error.MissingField);
    errdefer alloc.free(url);
    const sha256 = try allocDupe(alloc, getStr(root, "sha256") orelse "no_check");
    errdefer alloc.free(sha256);
    const homepage = try allocDupe(alloc, getStr(root, "homepage") orelse "");
    errdefer alloc.free(homepage);
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");
    errdefer alloc.free(desc);

    // name is an array, take first element
    var name = try allocDupe(alloc, token);
    errdefer alloc.free(name);
    if (root.get("name")) |name_val| {
        if (name_val == .array and name_val.array.items.len > 0) {
            if (name_val.array.items[0] == .string) {
                alloc.free(name);
                name = try allocDupe(alloc, name_val.array.items[0].string);
            }
        }
    }

    const auto_updates = if (root.get("auto_updates")) |au| au == .bool and au.bool else false;

    // Parse minimum macOS version from depends_on.macos.>=
    var min_macos: ?[]const u8 = null;
    errdefer if (min_macos) |m| alloc.free(m);
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
    errdefer {
        for (artifacts.items) |art| {
            switch (art) {
                .app => |a| alloc.free(a),
                .binary => |b| {
                    alloc.free(b.source);
                    alloc.free(b.target);
                },
                .pkg => |p| alloc.free(p),
                .uninstall => |u| {
                    alloc.free(u.quit);
                    alloc.free(u.pkgutil);
                },
            }
        }
    }

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
                            } else if (items[bi] == .object) {
                                const source_str = getStr(items[bi].object, "source") orelse continue;
                                const source = try allocDupe(alloc, source_str);
                                const target = try allocDupe(alloc, getStr(items[bi].object, "target") orelse std.fs.path.basename(source_str));
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

    const owned_artifacts = try artifacts.toOwnedSlice(alloc);
    errdefer alloc.free(owned_artifacts);

    return Cask{
        .token = token,
        .name = name,
        .version = version,
        .url = url,
        .sha256 = sha256,
        .homepage = homepage,
        .desc = desc,
        .auto_updates = auto_updates,
        .artifacts = owned_artifacts,
        .min_macos = min_macos,
    };
}

fn fetchAndCache(alloc: std.mem.Allocator, shared_client: ?*std.http.Client, name: []const u8, cache_path: []const u8) !Formula {
    var base_buf: [512]u8 = undefined;
    const base = normalizedFormulaApiBase(&base_buf);
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ base, name }) catch return error.NameTooLong;

    const body = if (shared_client) |c|
        fetch.getWithClient(alloc, c, url) catch return error.FormulaNotFound
    else
        fetch.get(alloc, url) catch return error.FormulaNotFound;

    // Write to cache
    std.Io.Dir.createDirAbsolute(std.Io.Threaded.global_single_threaded.io(), API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), cache_path, .{})) |file| {
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), body) catch {};
    } else |_| {}

    defer alloc.free(body);
    return parseFormulaJson(alloc, body);
}

fn readCached(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    // TTL: 1 hour (bottles don't change frequently)
    const st = file.stat(lib_io) catch return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > 3600 * std.time.ns_per_s) return null;
    const sz = @min(st.size, 2 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch { alloc.free(buf); return null; };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

fn parseFormulaJson(alloc: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const name = try allocDupe(alloc, getStr(root, "name") orelse return error.MissingField);
    errdefer alloc.free(name);
    const version_obj = root.get("versions") orelse return error.MissingField;
    const version = try allocDupe(alloc, getStr(version_obj.object, "stable") orelse return error.MissingField);
    errdefer alloc.free(version);
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");
    errdefer alloc.free(desc);

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
    errdefer for (deps.items) |dep| alloc.free(dep);
    if (root.get("dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep| {
                if (dep == .string) {
                    try deps.append(alloc, try allocDupe(alloc, dep.string));
                }
            }
        }
    }
    if (builtin.os.tag == .macos) {
        if (root.get("uses_from_macos")) |uses_val| {
            if (uses_val == .array) {
                for (uses_val.array.items) |dep| {
                    if (dep != .string) continue;
                    var present = false;
                    for (deps.items) |existing| {
                        if (std.mem.eql(u8, existing, dep.string)) {
                            present = true;
                            break;
                        }
                    }
                    if (!present) {
                        try deps.append(alloc, try allocDupe(alloc, dep.string));
                    }
                }
            }
        }
    }
    const dependencies = try deps.toOwnedSlice(alloc);
    errdefer {
        for (dependencies) |dep| alloc.free(dep);
        alloc.free(dependencies);
    }

    // Parse build_dependencies
    var bdeps: std.ArrayList([]const u8) = .empty;
    defer bdeps.deinit(alloc);
    errdefer for (bdeps.items) |dep| alloc.free(dep);
    if (root.get("build_dependencies")) |bdeps_val| {
        if (bdeps_val == .array) {
            for (bdeps_val.array.items) |dep| {
                if (dep == .string) {
                    try bdeps.append(alloc, try allocDupe(alloc, dep.string));
                }
            }
        }
    }
    const build_deps = try bdeps.toOwnedSlice(alloc);
    errdefer {
        for (build_deps) |dep| alloc.free(dep);
        alloc.free(build_deps);
    }

    // Parse source URL and checksum from urls.stable
    var source_url = try allocDupe(alloc, "");
    errdefer alloc.free(source_url);
    var source_sha256 = try allocDupe(alloc, "");
    errdefer alloc.free(source_sha256);
    if (root.get("urls")) |urls_val| {
        if (urls_val == .object) {
            if (urls_val.object.get("stable")) |stable_url| {
                if (stable_url == .object) {
                    alloc.free(source_url);
                    alloc.free(source_sha256);
                    source_url = try allocDupe(alloc, getStr(stable_url.object, "url") orelse "");
                    source_sha256 = try allocDupe(alloc, getStr(stable_url.object, "checksum") orelse "");
                }
            }
        }
    }

    // Parse caveats (string or null)
    const caveats = try allocDupe(alloc, getStr(root, "caveats") orelse "");
    errdefer alloc.free(caveats);

    // Parse post_install_defined (bool)
    const post_install_defined = if (root.get("post_install_defined")) |pid|
        pid == .bool and pid.bool
    else
        false;

    var bottle_url = try allocDupe(alloc, "");
    errdefer alloc.free(bottle_url);
    var bottle_sha256 = try allocDupe(alloc, "");
    errdefer alloc.free(bottle_sha256);
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
                            if (findBottleTag(files.object)) |tag| {
                                if (tag == .object) {
                                    alloc.free(bottle_url);
                                    alloc.free(bottle_sha256);
                                    bottle_url = try allocDupe(alloc, getStr(tag.object, "url") orelse "");
                                    bottle_sha256 = try allocDupe(alloc, getStr(tag.object, "sha256") orelse "");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Only error if BOTH bottle and source are missing
    if (bottle_url.len == 0 and source_url.len == 0) return error.NoArm64Bottle;

    return Formula{
        .name = name,
        .version = version,
        .revision = revision,
        .rebuild = rebuild,
        .desc = desc,
        .dependencies = dependencies,
        .bottle_url = bottle_url,
        .bottle_sha256 = bottle_sha256,
        .source_url = source_url,
        .source_sha256 = source_sha256,
        .build_deps = build_deps,
        .caveats = caveats,
        .post_install_defined = post_install_defined,
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
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/lame","sha256":"deadbeef"}}}}}
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
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/ffmpeg","sha256":"cafe"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.dependencies.len);
    try testing.expectEqualStrings("lame", f.dependencies[0]);
    try testing.expectEqualStrings("opus", f.dependencies[1]);
    try testing.expectEqualStrings("x265", f.dependencies[2]);
}

test "parseFormulaJson - includes uses_from_macos on macOS" {
    const json =
        \\{"name":"python@3.14","desc":"","versions":{"stable":"3.14.3"},"revision":0,
        \\"dependencies":["mpdecimal"],
        \\"uses_from_macos":["expat","libffi"],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/python","sha256":"cafe"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);

    if (builtin.os.tag == .macos) {
        try testing.expectEqual(@as(usize, 3), f.dependencies.len);
        try testing.expectEqualStrings("mpdecimal", f.dependencies[0]);
        try testing.expectEqualStrings("expat", f.dependencies[1]);
        try testing.expectEqualStrings("libffi", f.dependencies[2]);
    } else {
        try testing.expectEqual(@as(usize, 1), f.dependencies.len);
        try testing.expectEqualStrings("mpdecimal", f.dependencies[0]);
    }
}

test "parseFormulaJson - missing name returns error" {
    const json =
        \\{"desc":"","versions":{"stable":"1.0"},"dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"u","sha256":"s"}}}}}
    ;
    try testing.expectError(error.MissingField, parseFormulaJson(testing.allocator, json));
}

test "parseFormulaJson - missing versions returns error" {
    const json =
        \\{"name":"foo","desc":"","dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"u","sha256":"s"}}}}}
    ;
    try testing.expectError(error.MissingField, parseFormulaJson(testing.allocator, json));
}

test "parseFormulaJson - parses source fields and caveats" {
    const json =
        \\{"name":"hello","desc":"GNU Hello","versions":{"stable":"2.12.1"},"revision":0,
        \\"dependencies":[],"build_dependencies":["autoconf"],
        \\"urls":{"stable":{"url":"https://ftp.gnu.org/hello-2.12.1.tar.gz","checksum":"abc123"}},
        \\"caveats":"Run hello to see greeting\n","post_install_defined":true,
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/hello","sha256":"beef"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", f.name);
    try testing.expectEqualStrings("https://ftp.gnu.org/hello-2.12.1.tar.gz", f.source_url);
    try testing.expectEqualStrings("abc123", f.source_sha256);
    try testing.expectEqual(@as(usize, 1), f.build_deps.len);
    try testing.expectEqualStrings("autoconf", f.build_deps[0]);
    try testing.expectEqualStrings("Run hello to see greeting\n", f.caveats);
    try testing.expect(f.post_install_defined);
}

test "parseFormulaJson - source only formula succeeds" {
    const json =
        \\{"name":"srconly","desc":"","versions":{"stable":"1.0"},"revision":0,
        \\"dependencies":[],
        \\"urls":{"stable":{"url":"https://example.com/srconly-1.0.tar.gz","checksum":"deadbeef"}},
        \\"bottle":{}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("srconly", f.name);
    try testing.expectEqualStrings("", f.bottle_url);
    try testing.expectEqualStrings("https://example.com/srconly-1.0.tar.gz", f.source_url);
}

test "parseFormulaJson - no bottle no source returns error" {
    const json =
        \\{"name":"nothing","desc":"","versions":{"stable":"1.0"},"revision":0,
        \\"dependencies":[],"bottle":{}}
    ;
    try testing.expectError(error.NoArm64Bottle, parseFormulaJson(testing.allocator, json));
}

test "findBottleTag - primary tag found" {
    // Build a JSON object with the current platform's BOTTLE_TAG as a key
    var buf: [128]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{{\"{s}\":{{\"url\":\"u1\"}},\"all\":{{\"url\":\"u2\"}}}}", .{BOTTLE_TAG});
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

test "parseCaskJson - parses complete cask" {
    const json =
        \\{"token":"firefox","name":["Mozilla Firefox"],"version":"147.0.3",
        \\"url":"https://example.com/Firefox.dmg","sha256":"deadbeef",
        \\"homepage":"https://www.mozilla.org/firefox/",
        \\"desc":"Web browser","auto_updates":true,
        \\"artifacts":[{"app":["Firefox.app"]},{"binary":[{"source":"firefox","target":"firefox"}]}],
        \\"depends_on":{"macos":{">=":["ventura"]}}}
    ;
    const c = try parseCaskJson(testing.allocator, json);
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("firefox", c.token);
    try testing.expectEqualStrings("Mozilla Firefox", c.name);
    try testing.expectEqualStrings("147.0.3", c.version);
    try testing.expectEqualStrings("https://example.com/Firefox.dmg", c.url);
    try testing.expectEqualStrings("deadbeef", c.sha256);
    try testing.expectEqualStrings("https://www.mozilla.org/firefox/", c.homepage);
    try testing.expectEqualStrings("Web browser", c.desc);
    try testing.expect(c.auto_updates);
    try testing.expectEqual(@as(usize, 2), c.artifacts.len);
}

test "parseCaskJson - missing token returns error" {
    const json =
        \\{"name":["Test"],"version":"1.0","url":"https://example.com/t.dmg",
        \\"sha256":"abc","desc":"","artifacts":[]}
    ;
    try testing.expectError(error.MissingField, parseCaskJson(testing.allocator, json));
}

test "parseCaskJson - missing url returns error" {
    const json =
        \\{"token":"test","name":["Test"],"version":"1.0",
        \\"sha256":"abc","desc":"","artifacts":[]}
    ;
    try testing.expectError(error.MissingField, parseCaskJson(testing.allocator, json));
}
