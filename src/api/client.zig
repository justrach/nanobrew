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
const PostField = @import("cask.zig").PostField;
const tap = @import("tap.zig");
const search_api = @import("search.zig");
const fetch = @import("../net/fetch.zig");
const upstream_github = @import("../upstream/github.zig");
const upstream_registry = @import("../upstream/registry.zig");
const version_cmp = @import("../version.zig");

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
    if (std.c.getenv("NANOBREW_API_DOMAIN")) |_cv| {
        const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeFormulaApiPrefix(scratch, d);
    }
    if (std.c.getenv("HOMEBREW_API_DOMAIN")) |_cv| {
        const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeFormulaApiPrefix(scratch, d);
    }
    return API_BASE;
}

fn normalizedCaskApiBase(scratch: *[512]u8) []const u8 {
    if (std.c.getenv("NANOBREW_API_DOMAIN")) |_cv| {
        const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeCaskApiPrefix(scratch, d);
    }
    if (std.c.getenv("HOMEBREW_API_DOMAIN")) |_cv| {
        const d = std.mem.sliceTo(_cv, 0);
        if (isValidDomainOverride(d)) return normalizeCaskApiPrefix(scratch, d);
    }
    return CASK_API_BASE;
}
const paths = @import("../platform/paths.zig");
const API_CACHE_DIR = paths.API_CACHE_DIR;

pub fn fetchFormula(alloc: std.mem.Allocator, name: []const u8) !Formula {
    return fetchFormulaWithClient(alloc, null, name);
}

/// Resolve a formula name that might be an alias (e.g., "python" -> "python@3.14").
/// Returns the actual formula name if found, or null if not found or on network error.
/// Resolve a formula name that might be an alias (e.g., "python" -> "python@3.14").
/// Returns the actual formula name if found, or null if not found or on network error.
pub fn resolveFormulaAlias(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const formula_list_json = fetchFormulaList(alloc) catch return null;
    defer alloc.free(formula_list_json);

    var scanner = std.json.Scanner.initCompleteInput(alloc, formula_list_json);
    defer scanner.deinit();

    if ((scanner.next() catch return null) != .array_begin) return null;

    while (true) {
        const t = scanner.next() catch return null;
        switch (t) {
            .array_end => return null,
            .object_begin => {},
            else => return null,
        }

        var formula_name: []const u8 = "";
        var name_owned: ?[]u8 = null;
        var alias_match: bool = false;
        defer if (name_owned) |s| alloc.free(s);

        while (true) {
            const key_tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch return null;
            var key: []const u8 = "";
            var key_alloc: ?[]u8 = null;
            switch (key_tok) {
                .object_end => break,
                .string => |s| key = s,
                .allocated_string => |s| {
                    key = s;
                    key_alloc = s;
                },
                else => return null,
            }
            defer if (key_alloc) |s| alloc.free(s);

            if (std.mem.eql(u8, key, "name")) {
                const v = scanner.nextAlloc(alloc, .alloc_if_needed) catch return null;
                switch (v) {
                    .string => |s| formula_name = s,
                    .allocated_string => |s| {
                        formula_name = s;
                        name_owned = s;
                    },
                    else => {},
                }
            } else if (std.mem.eql(u8, key, "aliases")) {
                if ((scanner.next() catch return null) != .array_begin) {
                    scanner.skipValue() catch return null;
                    continue;
                }
                while (true) {
                    const a_tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch return null;
                    var a_alloc: ?[]u8 = null;
                    var a_str: []const u8 = "";
                    var done = false;
                    switch (a_tok) {
                        .array_end => done = true,
                        .string => |s| a_str = s,
                        .allocated_string => |s| {
                            a_str = s;
                            a_alloc = s;
                        },
                        else => return null,
                    }
                    defer if (a_alloc) |s| alloc.free(s);
                    if (done) break;
                    if (!alias_match and std.mem.eql(u8, a_str, name)) alias_match = true;
                }
            } else {
                scanner.skipValue() catch return null;
            }
        }

        if (formula_name.len == 0) continue;
        if (std.mem.eql(u8, formula_name, name)) return null;
        if (alias_match) return alloc.dupe(u8, formula_name) catch null;
    }
}

/// Fetch the cached formula list JSON (longer TTL since formulae don't change often).
fn fetchFormulaList(alloc: std.mem.Allocator) ![]u8 {
    const list_cache_path = API_CACHE_DIR ++ "/_formula_list.json";

    // Check cache with 24-hour TTL
    if (readCachedList(alloc, list_cache_path, 24 * 3600 * std.time.ns_per_s)) |data| return data;

    const body = fetch.get(alloc, "https://formulae.brew.sh/api/formula.json") catch return error.FetchFailed;

    // Write to cache
    const _lio_fl = paths.safe_io;
    std.Io.Dir.createDirAbsolute(_lio_fl, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(_lio_fl, list_cache_path, .{})) |file| {
        defer file.close(_lio_fl);
        file.writeStreamingAll(_lio_fl, body) catch {};
    } else |_| {}

    return body;
}

/// Read cached file with custom TTL.
fn readCachedList(alloc: std.mem.Allocator, path: []const u8, ttl_ns: u64) ?[]u8 {
    const lib_io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    const st = file.stat(lib_io) catch return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > @as(i96, @intCast(ttl_ns))) return null;
    const sz = @min(st.size, 64 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

/// Fetch formula using a shared HTTP client (avoids repeated TLS handshakes).
pub fn fetchFormulaWithClient(alloc: std.mem.Allocator, client: ?*std.http.Client, name: []const u8) !Formula {
    return fetchFormulaWithClientAndUpstreamRegistry(alloc, client, name, null);
}

/// Fetch formula using a shared HTTP client and, when available, a preloaded
/// upstream registry. Dependency resolution calls this to avoid reparsing the
/// generated registry once per dependency.
pub fn fetchFormulaWithClientAndUpstreamRegistry(
    alloc: std.mem.Allocator,
    client: ?*std.http.Client,
    name: []const u8,
    registry: ?*const upstream_registry.Registry,
) !Formula {
    const tap_ref = isTapRef(name);

    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM") == null) {
        const upstream_result = if (registry) |loaded_registry|
            upstream_github.fetchFormulaFromRegistry(alloc, name, loaded_registry)
        else
            upstream_github.fetchFormula(alloc, name);
        if (upstream_result) |upstream_formula| {
            // The verified-upstream registry pins a version that can lag behind
            // Homebrew's live API. Prefer the live bottle when it's strictly
            // newer so installs aren't stuck on a stale pin (#308). Best-effort:
            // tap refs have no core API and any live-fetch failure keeps the pin.
            // Exception: a revoked pin's fallback is a deliberate downgrade —
            // the registry is authoritative and freshness must not undo it.
            if (!tap_ref and !upstream_formula.revoked_fallback and upstreamFreshnessEnabled()) {
                if (fetchFormulaLive(alloc, client, name) catch null) |live| {
                    if (version_cmp.isNewer(live.version, upstream_formula.version)) {
                        upstream_formula.deinit(alloc);
                        return live;
                    }
                    live.deinit(alloc);
                }
            }
            return upstream_formula;
        } else |err| switch (err) {
            error.UpstreamRecordNotFound,
            error.UnsupportedPlatform,
            error.MissingAsset,
            error.FetchFailed,
            error.InvalidGithubRelease,
            => {},
            else => return err,
        }
    }

    // Tap formula: "user/tap/formula" -> fetch from GitHub when no verified
    // upstream record exists for the tap token.
    if (tap_ref) {
        return tap.fetchTapFormula(alloc, client, name);
    }

    return fetchFormulaLive(alloc, client, name) catch |err| {
        if (err == error.FormulaNotFound) {
            // Try to resolve as an alias (e.g., "python" -> "python@3.14")
            if (resolveFormulaAlias(alloc, name)) |resolved_name| {
                defer alloc.free(resolved_name);
                if (!std.mem.eql(u8, resolved_name, name)) {
                    return fetchFormulaWithClientAndUpstreamRegistry(alloc, client, resolved_name, registry) catch err;
                }
            }
        }
        return err;
    };
}

/// Fetch a formula directly from the live Homebrew API (cache → network),
/// bypassing the verified-upstream registry. Used both as the no-upstream path
/// and for the freshness comparison above.
/// Local-only formula lookup: per-name disk cache, then a slice out of the
/// fresh bulk list. No network and no upstream-registry resolution — callers
/// that only need metadata (version, dependencies) try this before paying
/// for a full fetch.
pub fn fetchFormulaLocal(alloc: std.mem.Allocator, name: []const u8) ?Formula {
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/{s}.json", .{ API_CACHE_DIR, name }) catch return null;

    if (readCached(alloc, cache_path)) |cached_json| {
        defer alloc.free(cached_json);
        if (parseFormulaJson(alloc, cached_json)) |formula| return formula else |_| {}
    }

    if (search_api.bulkFormulaEntryJson(alloc, name)) |entry_json| {
        defer alloc.free(entry_json);
        if (parseFormulaJson(alloc, entry_json)) |formula| {
            writeCacheFile(cache_path, entry_json);
            return formula;
        } else |_| {}
    }

    return null;
}

fn fetchFormulaLive(alloc: std.mem.Allocator, client: ?*std.http.Client, name: []const u8) !Formula {
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

    // Bulk-list fast path: a fresh `nb search`/`outdated` bulk cache already
    // holds this formula's full API object — slice it out locally instead of
    // making a network round trip, and warm the per-name cache so follow-up
    // commands hit the cheaper path above.
    if (search_api.bulkFormulaEntryJson(alloc, name)) |entry_json| {
        defer alloc.free(entry_json);
        if (parseFormulaJson(alloc, entry_json)) |formula| {
            writeCacheFile(cache_path, entry_json);
            return formula;
        } else |_| {}
    }

    return fetchAndCache(alloc, client, name, cache_path);
}

/// Whether to cross-check verified-upstream pins against the live Homebrew API.
/// On by default; set NANOBREW_DISABLE_UPSTREAM_FRESHNESS=1 to keep pins as-is
/// (e.g. fully offline use of the embedded registry).
fn upstreamFreshnessEnabled() bool {
    return std.c.getenv("NANOBREW_DISABLE_UPSTREAM_FRESHNESS") == null;
}

fn isTapRef(name: []const u8) bool {
    var count: usize = 0;
    for (name) |c| {
        if (c == '/') count += 1;
    }
    return count == 2;
}

pub fn fetchCask(alloc: std.mem.Allocator, token: []const u8) !Cask {
    const tap_ref = tap.parseTapRef(token) != null;

    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM") == null) {
        if (upstream_github.fetchCask(alloc, token)) |upstream_cask| {
            // Prefer the live Homebrew cask when it's strictly newer than the
            // pinned verified-upstream version (#310). Best-effort — tap refs and
            // any live-fetch failure keep the verified pin. A revoked pin's
            // fallback is a deliberate downgrade — freshness must not undo it.
            if (!tap_ref and !upstream_cask.revoked_fallback and upstreamFreshnessEnabled()) {
                if (fetchCaskLive(alloc, token) catch null) |live| {
                    if (version_cmp.isNewer(live.version, upstream_cask.version)) {
                        upstream_cask.deinit(alloc);
                        return live;
                    }
                    live.deinit(alloc);
                }
            }
            return upstream_cask;
        } else |err| switch (err) {
            error.UpstreamRecordNotFound,
            error.UnsupportedPlatform,
            error.UnsupportedUpstreamType,
            error.MissingAsset,
            error.FetchFailed,
            error.InvalidGithubRelease,
            => {},
            else => return err,
        }
    }

    // Tap cask: "user/tap/cask" -> fetch from GitHub when no verified
    // upstream record exists for the tap token.
    if (tap_ref) {
        return tap.fetchTapCask(alloc, token);
    }

    return fetchCaskLive(alloc, token);
}

/// Fetch a cask directly from the live Homebrew API (cache → network),
/// bypassing the verified-upstream registry.
fn fetchCaskLive(alloc: std.mem.Allocator, token: []const u8) !Cask {
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

    // Bulk-list fast path — see fetchFormulaLive. A fresh bulk cask cache
    // serves the token's full API object without a network round trip.
    if (search_api.bulkCaskEntryJson(alloc, token)) |entry_json| {
        defer alloc.free(entry_json);
        if (parseCaskJson(alloc, entry_json)) |cask| {
            writeCacheFile(cache_path, entry_json);
            return cask;
        } else |_| {}
    }

    return fetchAndCacheCask(alloc, token, cache_path);
}

fn fetchAndCacheCask(alloc: std.mem.Allocator, token: []const u8, cache_path: []const u8) !Cask {
    var base_buf: [512]u8 = undefined;
    const base = normalizedCaskApiBase(&base_buf);
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ base, token }) catch return error.NameTooLong;

    const body = fetch.get(alloc, url) catch return error.CaskNotFound;

    std.Io.Dir.createDirAbsolute(paths.safe_io, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, cache_path, .{})) |file| {
        defer file.close(paths.safe_io);
        file.writeStreamingAll(paths.safe_io, body) catch {};
    } else |_| {}

    defer alloc.free(body);
    return parseCaskJson(alloc, body);
}

/// Whether this build should select Intel (x86_64) cask `variations` blocks.
const target_is_intel = @import("builtin").cpu.arch == .x86_64;

fn parseCaskJson(alloc: std.mem.Allocator, json_data: []const u8) !Cask {
    return parseCaskJsonArch(alloc, json_data, target_is_intel);
}

/// Arch-parameterized cask parser. `prefer_intel` selects Intel `variations`
/// blocks and uses the x86_64 #{arch} substitution. Split out from parseCaskJson
/// (which passes the build arch) so the Intel path has unit-test coverage even
/// when tests run on Apple Silicon (#307).
fn parseCaskJsonArch(alloc: std.mem.Allocator, json_data: []const u8, prefer_intel: bool) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const token = try allocDupe(alloc, getStr(root, "token") orelse return error.MissingField);
    errdefer alloc.free(token);
    // Resolve #{arch} in URL — Homebrew's cask DSL uses this for arch-specific downloads.
    // The API returns the arm64-resolved URL by default; on x86_64 we need to substitute.
    const cask_arch: []const u8 = if (prefer_intel) "x86_64" else "arm64";
    const raw_url = getStr(root, "url") orelse return error.MissingField;

    // On x86_64, select a SINGLE matching `variations` block (newest macOS key
    // first) and read url/sha256/version consistently from it. Reading each field
    // independently meant arch-specific casks (e.g. `on_arm`/`on_intel` blocks like
    // gcc-arm-embedded) downloaded the Intel URL but kept the arm64 root version,
    // producing broken Caskroom paths and symlinks (#307, builds on #174).
    const selected_var: ?std.json.ObjectMap = blk: {
        if (prefer_intel) {
            if (root.get("variations")) |vars| {
                if (vars == .object) {
                    const intel_keys = [_][]const u8{
                        "tahoe",   "sequoia",  "sonoma", "ventura",     "monterey",
                        "big_sur", "catalina", "mojave", "high_sierra", "x86_64",
                    };
                    for (intel_keys) |key| {
                        if (vars.object.get(key)) |v| {
                            if (v == .object) break :blk v.object;
                        }
                    }
                }
            }
        }
        break :blk null;
    };

    // The arm64/default version baked into the API's pre-rendered artifact paths.
    const root_version = getStr(root, "version") orelse return error.MissingField;
    const version = try allocDupe(alloc, blk: {
        if (selected_var) |sv| {
            if (getStr(sv, "version")) |vver| break :blk vver;
        }
        break :blk root_version;
    });
    errdefer alloc.free(version);

    const url = blk: {
        // Prefer the variation URL when one was selected; otherwise the root URL.
        const base_url = if (selected_var) |sv| (getStr(sv, "url") orelse raw_url) else raw_url;
        if (std.mem.indexOf(u8, base_url, "#{arch}") != null) {
            break :blk try std.mem.replaceOwned(u8, alloc, base_url, "#{arch}", cask_arch);
        }
        break :blk try allocDupe(alloc, base_url);
    };
    errdefer alloc.free(url);

    // sha256 must come from the same source as the URL/version above.
    const sha256 = try allocDupe(alloc, blk: {
        if (selected_var) |sv| {
            if (getStr(sv, "sha256")) |vsha| break :blk vsha;
        }
        break :blk getStr(root, "sha256") orelse "no_check";
    });
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
                .font => |f| alloc.free(f),
                .artifact => |a| {
                    alloc.free(a.source);
                    alloc.free(a.target);
                },
                .suite => |s| {
                    alloc.free(s.source);
                    alloc.free(s.target);
                },
                .installer_script => |script| {
                    alloc.free(script.executable);
                    for (script.args) |arg| alloc.free(arg);
                    alloc.free(script.args);
                },
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
                                try artifacts.append(alloc, .{ .app = try rewriteVersion(alloc, a.string, root_version, version) });
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
                                const source = try rewriteVersion(alloc, items[bi].string, root_version, version);
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
                                const source = try rewriteVersion(alloc, source_str, root_version, version);
                                const target = try allocDupe(alloc, getStr(items[bi].object, "target") orelse std.fs.path.basename(source_str));
                                try artifacts.append(alloc, .{ .binary = .{ .source = source, .target = target } });
                            }
                        }
                    }
                } else if (obj.get("pkg")) |pkg_val| {
                    if (pkg_val == .array) {
                        for (pkg_val.array.items) |p| {
                            if (p == .string) {
                                try artifacts.append(alloc, .{ .pkg = try rewriteVersion(alloc, p.string, root_version, version) });
                            }
                        }
                    }
                } else if (obj.get("uninstall")) |uninst_val| {
                    if (uninst_val == .array) {
                        for (uninst_val.array.items) |u| {
                            if (u == .object) {
                                const quit = try allocDupe(alloc, getStr(u.object, "quit") orelse "");
                                const pkgutil = try rewriteVersion(alloc, getStr(u.object, "pkgutil") orelse "", root_version, version);
                                try artifacts.append(alloc, .{ .uninstall = .{ .quit = quit, .pkgutil = pkgutil } });
                            }
                        }
                    }
                } else if (obj.get("suite")) |suite_val| {
                    // Homebrew shape: {"suite": ["Dir"], "target": "/Applications/Dir"}
                    if (suite_val == .array) {
                        const suite_target = getStr(obj, "target") orelse "";
                        if (suite_target.len > 0) {
                            for (suite_val.array.items) |s| {
                                if (s == .string) {
                                    try artifacts.append(alloc, .{ .suite = .{
                                        .source = try rewriteVersion(alloc, s.string, root_version, version),
                                        .target = try rewriteVersion(alloc, suite_target, root_version, version),
                                    } });
                                }
                            }
                        }
                    }
                } else if (obj.get("artifact")) |art_val| {
                    // Homebrew shape: {"artifact": ["src", {"target": "/path"}]}
                    // (target may also be a sibling key of the artifact object).
                    if (art_val == .array and art_val.array.items.len > 0 and art_val.array.items[0] == .string) {
                        const art_items = art_val.array.items;
                        var art_target: []const u8 = "";
                        if (art_items.len > 1 and art_items[art_items.len - 1] == .object) {
                            art_target = getStr(art_items[art_items.len - 1].object, "target") orelse "";
                        }
                        if (art_target.len == 0) art_target = getStr(obj, "target") orelse "";
                        if (art_target.len > 0) {
                            try artifacts.append(alloc, .{ .artifact = .{
                                .source = try rewriteVersion(alloc, art_items[0].string, root_version, version),
                                .target = try rewriteVersion(alloc, art_target, root_version, version),
                            } });
                        }
                    }
                } else if (obj.get("font")) |font_val| {
                    if (font_val == .array) {
                        for (font_val.array.items) |f| {
                            if (f == .string) {
                                try artifacts.append(alloc, .{ .font = try rewriteVersion(alloc, f.string, root_version, version) });
                            }
                        }
                    }
                }
            }
        }
    }

    const owned_artifacts = try artifacts.toOwnedSlice(alloc);
    errdefer alloc.free(owned_artifacts);

    // Parse `url_specs` (Homebrew's `using:`/`data:` download spec). When a POST
    // method + form data is present we must replay it on download, otherwise the
    // server returns a license/landing page instead of the payload (#305). Prefer
    // the selected variation's url_specs so arch-specific POST bodies are honored.
    var download_using: ?[]const u8 = null;
    errdefer if (download_using) |u| alloc.free(u);
    var post_data: std.ArrayList(PostField) = .empty;
    defer post_data.deinit(alloc);
    errdefer {
        for (post_data.items) |field| {
            alloc.free(field.key);
            alloc.free(field.value);
        }
    }
    // Extra request modifiers some casks need to reach the real download
    // (license/CDN gating): referer, user_agent, cookies, header (#305 follow-up).
    var referer: ?[]const u8 = null;
    errdefer if (referer) |r| alloc.free(r);
    var user_agent: ?[]const u8 = null;
    errdefer if (user_agent) |u| alloc.free(u);
    var cookies: std.ArrayList(PostField) = .empty;
    defer cookies.deinit(alloc);
    errdefer {
        for (cookies.items) |c| {
            alloc.free(c.key);
            alloc.free(c.value);
        }
    }
    var headers_list: std.ArrayList([]const u8) = .empty;
    defer headers_list.deinit(alloc);
    errdefer for (headers_list.items) |h| alloc.free(h);
    {
        const specs: ?std.json.ObjectMap = blk: {
            if (selected_var) |sv| {
                if (sv.get("url_specs")) |us| {
                    if (us == .object) break :blk us.object;
                }
            }
            if (root.get("url_specs")) |us| {
                if (us == .object) break :blk us.object;
            }
            break :blk null;
        };
        if (specs) |s| {
            if (getStr(s, "using")) |u| download_using = try allocDupe(alloc, u);
            if (s.get("data")) |data_val| {
                if (data_val == .object) {
                    var it = data_val.object.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            try post_data.append(alloc, .{
                                .key = try allocDupe(alloc, entry.key_ptr.*),
                                .value = try allocDupe(alloc, entry.value_ptr.*.string),
                            });
                        }
                    }
                }
            }
            if (getStr(s, "referer")) |r| referer = try allocDupe(alloc, r);
            if (getStr(s, "user_agent")) |ua| {
                if (resolveUserAgent(ua)) |resolved| user_agent = try allocDupe(alloc, resolved);
            }
            if (s.get("cookies")) |ck_val| {
                if (ck_val == .object) {
                    var it = ck_val.object.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            try cookies.append(alloc, .{
                                .key = try allocDupe(alloc, entry.key_ptr.*),
                                .value = try allocDupe(alloc, entry.value_ptr.*.string),
                            });
                        }
                    }
                }
            }
            // `header` may be a single "Name: Value" string or an array of them.
            if (s.get("header")) |hv| {
                switch (hv) {
                    .string => try headers_list.append(alloc, try allocDupe(alloc, hv.string)),
                    .array => for (hv.array.items) |h| {
                        if (h == .string) try headers_list.append(alloc, try allocDupe(alloc, h.string));
                    },
                    else => {},
                }
            }
        }
    }
    const owned_post_data = try post_data.toOwnedSlice(alloc);
    errdefer alloc.free(owned_post_data);
    const owned_cookies = try cookies.toOwnedSlice(alloc);
    errdefer alloc.free(owned_cookies);
    const owned_headers = try headers_list.toOwnedSlice(alloc);
    errdefer alloc.free(owned_headers);

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
        .download_using = download_using,
        .post_data = owned_post_data,
        .referer = referer,
        .user_agent = user_agent,
        .cookies = owned_cookies,
        .headers = owned_headers,
    };
}

/// Resolve a cask `url_specs.user_agent` value. Homebrew uses Ruby symbols for
/// presets: `:fake` is a browser UA, `:default`/`:curl` mean "use the tool's
/// own UA" (we return null to keep our built-in one). A literal string is used
/// verbatim.
fn resolveUserAgent(ua: []const u8) ?[]const u8 {
    if (ua.len == 0) return null;
    if (std.mem.eql(u8, ua, ":default") or std.mem.eql(u8, ua, ":curl")) return null;
    if (std.mem.eql(u8, ua, ":fake") or std.mem.eql(u8, ua, ":browser")) {
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15";
    }
    return ua;
}

fn writeCacheFile(cache_path: []const u8, data: []const u8) void {
    std.Io.Dir.createDirAbsolute(paths.safe_io, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, cache_path, .{})) |file| {
        defer file.close(paths.safe_io);
        file.writeStreamingAll(paths.safe_io, data) catch {};
    } else |_| {}
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
    std.Io.Dir.createDirAbsolute(paths.safe_io, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(paths.safe_io, cache_path, .{})) |file| {
        defer file.close(paths.safe_io);
        file.writeStreamingAll(paths.safe_io, body) catch {};
    } else |_| {}

    defer alloc.free(body);
    return parseFormulaJson(alloc, body);
}

fn readCached(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const lib_io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;
    defer file.close(lib_io);
    // TTL: 1 hour (bottles don't change frequently)
    const st = file.stat(lib_io) catch return null;
    const now_ts = std.Io.Timestamp.now(lib_io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > 3600 * std.time.ns_per_s) return null;
    const sz = @min(st.size, 2 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(lib_io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
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
    const homepage = try allocDupe(alloc, getStr(root, "homepage") orelse "");
    errdefer alloc.free(homepage);
    // license may be a string, an object (SPDX expression), or null; only capture strings.
    const license = try allocDupe(alloc, getStr(root, "license") orelse "");
    errdefer alloc.free(license);

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
        .homepage = homepage,
        .license = license,
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

/// Dupe `s`, substituting occurrences of `from` with `to`. Used to rewrite
/// the arm64 (root) cask version baked into the API's artifact paths with the
/// architecture-specific version when an Intel `variations` block was selected,
/// so binary/uninstall paths point at the directory the Intel pkg actually
/// creates (#307). No-op when `from`/`to` are equal or `from` is absent.
/// Only token-bounded occurrences are replaced: a `from` of "1.2" must not
/// match inside "11.2" or "1.25" (neighbors may not be alphanumeric or '.').
fn rewriteVersion(alloc: std.mem.Allocator, s: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (from.len == 0 or std.mem.eql(u8, from, to) or std.mem.indexOf(u8, s, from) == null) {
        return allocDupe(alloc, s);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], from)) {
            const before_ok = i == 0 or !isVersionTokenChar(s[i - 1]);
            const after_idx = i + from.len;
            const after_ok = after_idx >= s.len or !isVersionTokenChar(s[after_idx]);
            if (before_ok and after_ok) {
                try out.appendSlice(alloc, to);
                i += from.len;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn isVersionTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.';
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

// Regression test for #235: when `nb info <alias>` resolves (e.g. "python" ->
// "python@3.14") and the underlying formula is parsed from a cached JSON,
// the returned Formula owns every duped field (name/version/desc/bottle_url/
// bottle_sha256/source_url/source_sha256/dependencies/build_deps/caveats).
// The caller MUST call deinit to avoid leaks reported under DebugAllocator.
// This test verifies parseFormulaJson + deinit round-trips cleanly under
// testing.allocator (a leak-detecting allocator), simulating the cache-hit
// branch taken by fetchFormulaWithClient for an alias-resolved name.
test "parseFormulaJson - alias target round-trips deinit (issue #235)" {
    const json =
        \\{"name":"python@3.14","desc":"Interpreted, interactive, object-oriented programming language",
        \\"versions":{"stable":"3.14.0"},"revision":1,
        \\"dependencies":["mpdecimal","openssl@3","sqlite","xz"],
        \\"build_dependencies":["pkg-config"],
        \\"uses_from_macos":["bzip2","expat","libffi","libxcrypt","ncurses","unzip","zlib"],
        \\"urls":{"stable":{"url":"https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tar.xz","checksum":"abcdef"}},
        \\"caveats":"Python has been installed as\n  python3.14\n",
        \\"post_install_defined":true,
        \\"bottle":{"stable":{"rebuild":1,"files":{"all":{"url":"https://ghcr.io/v2/homebrew/core/python/3.14","sha256":"cafebabe"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("python@3.14", f.name);
    try testing.expectEqualStrings("3.14.0", f.version);
    try testing.expectEqual(@as(u32, 1), f.revision);
    try testing.expectEqual(@as(u32, 1), f.rebuild);
    try testing.expect(f.bottle_sha256.len > 0);
    try testing.expect(f.bottle_url.len > 0);
    try testing.expect(f.caveats.len > 0);
    try testing.expect(f.dependencies.len >= 4);
    try testing.expect(f.build_deps.len >= 1);
}

// Regression test for #235: exercising the alias-resolution cache hit path
// twice in a row — the failure mode pre-fix was that multiple alias calls
// would repeatedly parse (and dup) all formula fields, and callers holding
// references but never calling deinit would leak one Formula per call.
// With deinit called in the caller, testing.allocator reports zero leaks.
test "parseFormulaJson - repeated parses do not accumulate leaks (issue #235)" {
    const json =
        \\{"name":"python@3.14","desc":"Python","versions":{"stable":"3.14.0"},"revision":0,
        \\"dependencies":["mpdecimal"],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/python","sha256":"deadbeef"}}}}}
    ;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const f = try parseFormulaJson(testing.allocator, json);
        defer f.deinit(testing.allocator);
        try testing.expectEqualStrings("python@3.14", f.name);
    }
}

test "parseFormulaJson - extracts homepage and license (issue #230)" {
    // Regression test for the v0.1.191 `nb info` rich-output feature:
    // Formula now parses `homepage` and `license` (both optional strings) out
    // of the Homebrew API response, and the struct owns + frees them.
    const json =
        \\{"name":"hello","desc":"GNU hello","versions":{"stable":"2.12.3"},"revision":0,
        \\"homepage":"https://www.gnu.org/software/hello/","license":"GPL-3.0-or-later",
        \\"dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"https://ghcr.io/bottle/hello","sha256":"deadbeef"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("https://www.gnu.org/software/hello/", f.homepage);
    try testing.expectEqualStrings("GPL-3.0-or-later", f.license);
}

test "parseFormulaJson - missing/non-string homepage+license are empty (issue #230)" {
    // The Homebrew API ships `license: null` or an SPDX object expression on
    // many formulae. The parser must not choke — it should leave both fields
    // as empty strings and the Formula must still deinit cleanly.
    const json =
        \\{"name":"x","versions":{"stable":"1"},"revision":0,
        \\"license":{"all_of":["MIT","Apache-2.0"]},
        \\"dependencies":[],
        \\"bottle":{"stable":{"rebuild":0,"files":{"all":{"url":"u","sha256":"s"}}}}}
    ;
    const f = try parseFormulaJson(testing.allocator, json);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("", f.homepage);
    try testing.expectEqualStrings("", f.license);
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
    // Use a tag that is not BOTTLE_TAG on any supported platform — the old
    // fixture used x86_64_linux, which *matches* when the tests run on Linux.
    const json =
        \\{"riscv64_solaris":{"url":"u1"}}
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

test "parseCaskJson - parses url_specs POST data (#305)" {
    const json =
        \\{"token":"segger-jlink","name":["SEGGER JLink"],"version":"9.48",
        \\"url":"https://example.com/JLink.pkg","sha256":"abc","desc":"","artifacts":[],
        \\"url_specs":{"using":"post","data":{"accept_license_agreement":"accepted","submit":"Download software"}}}
    ;
    const c = try parseCaskJson(testing.allocator, json);
    defer c.deinit(testing.allocator);
    try testing.expect(c.isPostDownload());
    try testing.expectEqual(@as(usize, 2), c.post_data.len);
    // Order follows JSON object iteration; assert by lookup instead of index.
    var saw_accept = false;
    var saw_submit = false;
    for (c.post_data) |f| {
        if (std.mem.eql(u8, f.key, "accept_license_agreement")) {
            saw_accept = true;
            try testing.expectEqualStrings("accepted", f.value);
        } else if (std.mem.eql(u8, f.key, "submit")) {
            saw_submit = true;
            try testing.expectEqualStrings("Download software", f.value);
        }
    }
    try testing.expect(saw_accept and saw_submit);
}

test "parseCaskJson - parses referer/user_agent/cookies/header url_specs (#305)" {
    const json =
        \\{"token":"x","name":["X"],"version":"1.0","url":"https://e.com/x.dmg",
        \\"sha256":"abc","desc":"","artifacts":[],
        \\"url_specs":{"referer":"https://e.com/dl","user_agent":":fake",
        \\"cookies":{"sid":"123"},"header":["X-A: 1","X-B: 2"]}}
    ;
    const c = try parseCaskJson(testing.allocator, json);
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("https://e.com/dl", c.referer.?);
    try testing.expect(c.user_agent != null);
    try testing.expect(std.mem.indexOf(u8, c.user_agent.?, "Safari") != null); // :fake resolved
    try testing.expectEqual(@as(usize, 1), c.cookies.len);
    try testing.expectEqualStrings("sid", c.cookies[0].key);
    try testing.expectEqual(@as(usize, 2), c.headers.len);
}

test "resolveUserAgent - maps Homebrew symbols" {
    try testing.expect(resolveUserAgent(":default") == null);
    try testing.expect(resolveUserAgent(":curl") == null);
    try testing.expect(resolveUserAgent(":fake") != null);
    try testing.expectEqualStrings("MyApp/1.0", resolveUserAgent("MyApp/1.0").?);
}

test "parseCaskJson - no url_specs means GET (no post data)" {
    const json =
        \\{"token":"firefox","name":["Firefox"],"version":"1.0",
        \\"url":"https://example.com/f.dmg","sha256":"abc","desc":"","artifacts":[]}
    ;
    const c = try parseCaskJson(testing.allocator, json);
    defer c.deinit(testing.allocator);
    try testing.expect(!c.isPostDownload());
    try testing.expectEqual(@as(usize, 0), c.post_data.len);
}

test "parseCaskJsonArch - Intel variation drives version, url, sha AND artifact paths (#307)" {
    // Shape mirrors gcc-arm-embedded: root is arm64 15.2.rel1, the Intel
    // variation is 14.2.rel1, and artifact paths bake in the root version.
    const json =
        \\{"token":"gcc-arm-embedded","name":["GCC ARM Embedded"],
        \\"version":"15.2.rel1","sha256":"armsha",
        \\"url":"https://ex.com/arm-gnu-toolchain-15.2.rel1-darwin-arm64.pkg",
        \\"artifacts":[
        \\  {"binary":["/Applications/ArmGNUToolchain/15.2.rel1/bin/arm-none-eabi-gcc"]},
        \\  {"pkg":["arm-gnu-toolchain-15.2.rel1-darwin-arm64.pkg"]}
        \\],
        \\"variations":{"ventura":{
        \\  "version":"14.2.rel1","sha256":"intelsha",
        \\  "url":"https://ex.com/arm-gnu-toolchain-14.2.rel1-darwin-x86_64.pkg"}}}
    ;

    // Intel build: everything must come from the variation.
    const intel = try parseCaskJsonArch(testing.allocator, json, true);
    defer intel.deinit(testing.allocator);
    try testing.expectEqualStrings("14.2.rel1", intel.version);
    try testing.expectEqualStrings("intelsha", intel.sha256);
    try testing.expectEqualStrings("https://ex.com/arm-gnu-toolchain-14.2.rel1-darwin-x86_64.pkg", intel.url);
    var saw_binary = false;
    for (intel.artifacts) |art| {
        if (art == .binary) {
            saw_binary = true;
            // Path version rewritten from the root 15.2.rel1 to 14.2.rel1.
            try testing.expectEqualStrings("/Applications/ArmGNUToolchain/14.2.rel1/bin/arm-none-eabi-gcc", art.binary.source);
        }
    }
    try testing.expect(saw_binary);

    // arm64 build: the root values are used unchanged (no variation, no rewrite).
    const arm = try parseCaskJsonArch(testing.allocator, json, false);
    defer arm.deinit(testing.allocator);
    try testing.expectEqualStrings("15.2.rel1", arm.version);
    try testing.expectEqualStrings("armsha", arm.sha256);
    try testing.expect(std.mem.indexOf(u8, arm.url, "arm64") != null);
}

test "rewriteVersion - substitutes arch version in artifact paths (#307)" {
    const out = try rewriteVersion(testing.allocator, "/Applications/Tool/15.2.rel1/bin/x", "15.2.rel1", "14.2.rel1");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/Applications/Tool/14.2.rel1/bin/x", out);

    // No-op when versions match.
    const same = try rewriteVersion(testing.allocator, "/a/15.2.rel1", "15.2.rel1", "15.2.rel1");
    defer testing.allocator.free(same);
    try testing.expectEqualStrings("/a/15.2.rel1", same);
}

test "parseCaskJson - parses suite and artifact stanzas (KiCad shape)" {
    const json =
        \\{"token":"kicad","version":"10.0.3","url":"https://example.com/kicad.dmg","artifacts":[
        \\{"suite":["KiCad"],"target":"/Applications/KiCad"},
        \\{"artifact":["demos",{"target":"/Library/Application Support/kicad/demos"}]},
        \\{"binary":["$APPDIR/KiCad/KiCad.app/Contents/MacOS/kicad-cli"]},
        \\{"uninstall":[{"quit":"org.kicad.kicad"}]}
        \\]}
    ;
    const cask = try parseCaskJson(testing.allocator, json);
    defer cask.deinit(testing.allocator);

    var saw_suite = false;
    var saw_artifact = false;
    var saw_binary = false;
    for (cask.artifacts) |art| {
        switch (art) {
            .suite => |s| {
                saw_suite = true;
                try testing.expectEqualStrings("KiCad", s.source);
                try testing.expectEqualStrings("/Applications/KiCad", s.target);
            },
            .artifact => |a| {
                saw_artifact = true;
                try testing.expectEqualStrings("demos", a.source);
                try testing.expectEqualStrings("/Library/Application Support/kicad/demos", a.target);
            },
            .binary => |b| {
                saw_binary = true;
                try testing.expectEqualStrings("kicad-cli", b.target);
            },
            else => {},
        }
    }
    try testing.expect(saw_suite);
    try testing.expect(saw_artifact);
    try testing.expect(saw_binary);
}

test "parseCaskJson - parses font stanzas" {
    const json =
        \\{"token":"font-fira-code","version":"6.2","url":"https://example.com/fira.zip",
        \\"sha256":"abc123","homepage":"","desc":"",
        \\"artifacts":[
        \\  {"font":["ttf/FiraCode-Bold.ttf"],"target":"/$HOME/Library/Fonts/FiraCode-Bold.ttf"},
        \\  {"font":["ttf/FiraCode-Regular.ttf"],"target":"/$HOME/Library/Fonts/FiraCode-Regular.ttf"},
        \\  {"font":["variable_ttf/FiraCode-VF.ttf"],"target":"/$HOME/Library/Fonts/FiraCode-VF.ttf"}
        \\]}
    ;
    const cask = try parseCaskJson(testing.allocator, json);
    defer cask.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), cask.artifacts.len);
    try testing.expectEqualStrings("ttf/FiraCode-Bold.ttf", cask.artifacts[0].font);
    try testing.expectEqualStrings("ttf/FiraCode-Regular.ttf", cask.artifacts[1].font);
    try testing.expectEqualStrings("variable_ttf/FiraCode-VF.ttf", cask.artifacts[2].font);
}
