// nanobrew — GitHub Releases upstream resolver
//
// Maps curated registry records onto the existing Cask install metadata so
// GitHub-hosted upstream assets can use nanobrew's native cask hot path.

const std = @import("std");
const builtin = @import("builtin");
const Formula = @import("../api/formula.zig").Formula;
const Cask = @import("../api/cask.zig").Cask;
const Artifact = @import("../api/cask.zig").Artifact;
const CaskSecurityWarning = @import("../api/cask.zig").SecurityWarning;
const fetch = @import("../net/fetch.zig");
const paths = @import("../platform/paths.zig");
const registry_mod = @import("registry.zig");

const API_CACHE_DIR = paths.API_CACHE_DIR;
const GITHUB_API_BASE = "https://api.github.com/repos/";
const CACHE_TTL_NS = 10 * 60 * std.time.ns_per_s;

const GithubAsset = struct {
    name: []const u8,
    url: []const u8,
    digest: []const u8,
};

/// Resolve a record's pin to the version that should actually install. A
/// revoked pin (CVE'd version) defers to its recorded fallback — the previous
/// known-good version — with a warning; a revoked pin without a fallback
/// fails closed rather than knowingly installing an advisory-affected build.
fn effectiveResolved(record: *const registry_mod.Record) !?*const registry_mod.Resolved {
    if (record.resolved) |*resolved| {
        if (resolved.revoked == null) return resolved;
        const quiet = builtin.is_test;
        const revoked = resolved.revoked.?;
        const advisory = if (revoked.advisory.len > 0) revoked.advisory else "security advisory";
        if (resolved.effective()) |safe| {
            if (!quiet) {
                std.debug.print("nb: warning: {s} {s} is revoked ({s}) — installing previous safe version {s}\n", .{
                    record.token, resolved.version, advisory, safe.version,
                });
                if (revoked.reason.len > 0) std.debug.print("    {s}\n", .{revoked.reason});
            }
            return safe;
        }
        if (!quiet) {
            std.debug.print("nb: {s} {s} is revoked ({s}) and no safe fallback version is recorded\n", .{
                record.token, resolved.version, advisory,
            });
            if (revoked.reason.len > 0) std.debug.print("    {s}\n", .{revoked.reason});
            std.debug.print("    run `nb update-registry` for a patched pin, or install a specific older version\n", .{});
        }
        return error.RevokedPin;
    }
    return null;
}

fn recordIsRevoked(record: *const registry_mod.Record) bool {
    return record.resolved != null and record.resolved.?.revoked != null;
}

pub fn fetchCask(alloc: std.mem.Allocator, token: []const u8) !Cask {
    const record = try registry_mod.loadRecord(alloc, token, .cask);
    defer record.deinit(alloc);
    return fetchCaskFromRecord(alloc, &record);
}

pub fn fetchFormula(alloc: std.mem.Allocator, token: []const u8) !Formula {
    if (readCachedFormula(alloc, token)) |formula| return formula;

    const record = try registry_mod.loadRecord(alloc, token, .formula);
    defer record.deinit(alloc);
    const formula = try fetchFormulaFromRecord(alloc, &record);
    // Never cache a revoked pin's fallback: the cached entry doesn't carry
    // the revoked_fallback flag, so a cache hit would let the live-API
    // freshness check (#308) undo the deliberate security downgrade.
    if (!formula.revoked_fallback) writeCachedFormula(token, &formula);
    return formula;
}

pub fn fetchFormulaFromRegistry(alloc: std.mem.Allocator, token: []const u8, registry: *const registry_mod.Registry) !Formula {
    if (readCachedFormula(alloc, token)) |formula| return formula;

    const record = registry.find(token, .formula) orelse return error.UpstreamRecordNotFound;
    const formula = try fetchFormulaFromRecord(alloc, record);
    if (!formula.revoked_fallback) writeCachedFormula(token, &formula);
    return formula;
}

pub fn fetchFormulaFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Formula {
    if (record.kind != .formula) return error.UnsupportedKind;
    switch (record.upstream.type) {
        .github_release => {},
        .homebrew_bottle => return fetchBottleFormulaFromRecord(alloc, record),
        .vendor_url => return fetchVendorFormulaFromRecord(alloc, record),
    }

    if (try effectiveResolved(record)) |resolved| {
        const platform = currentPlatform() orelse return error.UnsupportedPlatform;
        if (resolved.findAsset(platform)) |asset| {
            var formula = try formulaFromResolvedFields(alloc, record, resolved.version, asset.url, asset.sha256, resolvedArtifactRules(record, asset));
            formula.revoked_fallback = recordIsRevoked(record);
            return formula;
        }
    }

    const release_json = try fetchLatestReleaseJson(alloc, record.upstream.repo);
    defer alloc.free(release_json);
    return formulaFromReleaseJson(alloc, record, release_json);
}

fn fetchVendorFormulaFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Formula {
    const resolved = (try effectiveResolved(record)) orelse return error.MissingAsset;
    const platform = currentPlatform() orelse return error.UnsupportedPlatform;
    const asset = resolved.findAsset(platform) orelse return error.UnsupportedPlatform;
    var formula = try formulaFromResolvedFields(alloc, record, resolved.version, asset.url, asset.sha256, resolvedArtifactRules(record, asset));
    formula.revoked_fallback = recordIsRevoked(record);
    return formula;
}

fn bottlePinCompatible(minimum: ?u32, host: u32) bool {
    // Preserve legacy pins on the previously tested macOS 15+ baseline.
    // Unknown requirements are not proof of compatibility on older systems.
    return host >= (minimum orelse 15);
}

test "unversioned bottle pins are not Monterey compatibility evidence" {
    try std.testing.expect(!bottlePinCompatible(null, 12));
    try std.testing.expect(!bottlePinCompatible(15, 12));
    try std.testing.expect(bottlePinCompatible(12, 12));
    try std.testing.expect(bottlePinCompatible(12, 15));
    try std.testing.expect(bottlePinCompatible(null, 15));
}

fn fetchBottleFormulaFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Formula {
    const resolved = (try effectiveResolved(record)) orelse return error.MissingAsset;
    const platform = currentPlatform() orelse return error.UnsupportedPlatform;
    const asset = resolved.findAsset(platform) orelse return error.UnsupportedPlatform;
    if (comptime builtin.os.tag == .macos) {
        // Older hosts must not receive legacy pins whose OS requirement was
        // discarded when converting Homebrew's tag to a platform-only asset.
        const major = @import("../api/formula.zig").runningMacosMajor() orelse return if (recordIsRevoked(record)) error.RevokedPin else error.UnsupportedPlatform;
        if (!bottlePinCompatible(asset.minimum_macos_major, major)) return if (recordIsRevoked(record)) error.RevokedPin else error.UnsupportedPlatform;
    }
    var formula = try formulaFromBottleResolvedFields(alloc, record, resolved.version, resolved.revision, resolved.rebuild, asset.url, asset.sha256);
    formula.revoked_fallback = recordIsRevoked(record);
    return formula;
}

pub fn fetchCaskFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Cask {
    if (record.kind != .cask) return error.UnsupportedKind;
    switch (record.upstream.type) {
        .github_release => {},
        .vendor_url => return fetchVendorCaskFromRecord(alloc, record),
        .homebrew_bottle => return error.UnsupportedUpstreamType,
    }

    if (try effectiveResolved(record)) |resolved| {
        const platform = currentPlatform() orelse return error.UnsupportedPlatform;
        if (resolved.findAsset(platform)) |asset| {
            var cask = try caskFromResolvedAsset(alloc, record, resolved.version, resolved.security_warnings, asset);
            cask.revoked_fallback = recordIsRevoked(record);
            return cask;
        }
    }

    const release_json = try fetchLatestReleaseJson(alloc, record.upstream.repo);
    defer alloc.free(release_json);
    return caskFromReleaseJson(alloc, record, release_json);
}

fn fetchVendorCaskFromRecord(alloc: std.mem.Allocator, record: *const registry_mod.Record) !Cask {
    const resolved = (try effectiveResolved(record)) orelse return error.MissingAsset;
    const platform = currentPlatform() orelse return error.UnsupportedPlatform;
    const asset = resolved.findAsset(platform) orelse return error.UnsupportedPlatform;
    var cask = try caskFromResolvedAsset(alloc, record, resolved.version, resolved.security_warnings, asset);
    cask.revoked_fallback = recordIsRevoked(record);
    return cask;
}

fn formulaFromReleaseJson(alloc: std.mem.Allocator, record: *const registry_mod.Record, release_json: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, release_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGithubRelease;

    const root = parsed.value.object;
    const tag_name = getStr(root, "tag_name") orelse return error.MissingField;
    const version = versionFromTag(tag_name);
    const assets_val = root.get("assets") orelse return error.MissingField;
    if (assets_val != .array) return error.MissingAsset;

    const asset_rule = selectCurrentPlatformAsset(record.assets) orelse return error.UnsupportedPlatform;
    const rendered_pattern = try renderPattern(alloc, asset_rule.pattern, tag_name, version);
    defer alloc.free(rendered_pattern);

    const asset = findGithubAsset(assets_val.array.items, rendered_pattern) orelse return error.MissingAsset;

    const sha256 = try sha256FromAssetDigest(alloc, record.verification, asset);
    defer alloc.free(sha256);

    return formulaFromResolvedFields(alloc, record, version, asset.url, sha256, record.artifacts);
}

fn formulaFromResolvedFields(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    url_value: []const u8,
    sha256_value: []const u8,
    artifact_rules: []const registry_mod.ArtifactRule,
) !Formula {
    if (!isSha256Hex(sha256_value)) return error.AssetDigestInvalid;

    const name = try alloc.dupe(u8, if (record.name.len > 0) record.name else record.token);
    errdefer alloc.free(name);
    const owned_version = try alloc.dupe(u8, version);
    errdefer alloc.free(owned_version);
    const desc = try alloc.dupe(u8, record.desc);
    errdefer alloc.free(desc);
    const homepage = try alloc.dupe(u8, if (record.homepage.len > 0) record.homepage else record.upstream.homepage);
    errdefer alloc.free(homepage);
    const license = try alloc.dupe(u8, "");
    errdefer alloc.free(license);
    const dependencies = try alloc.alloc([]const u8, 0);
    errdefer alloc.free(dependencies);
    const bottle_url = try alloc.dupe(u8, "");
    errdefer alloc.free(bottle_url);
    const bottle_sha256 = try alloc.dupe(u8, "");
    errdefer alloc.free(bottle_sha256);
    const source_url = try alloc.dupe(u8, url_value);
    errdefer alloc.free(source_url);
    const source_sha256 = try alloc.dupe(u8, sha256_value);
    errdefer alloc.free(source_sha256);
    const build_deps = try alloc.alloc([]const u8, 0);
    errdefer alloc.free(build_deps);
    const install_binaries = try formulaInstallBinariesFromRecord(alloc, artifact_rules);
    errdefer freeStringList(alloc, install_binaries);
    const caveats = try alloc.dupe(u8, "");
    errdefer alloc.free(caveats);

    return .{
        .name = name,
        .version = owned_version,
        .desc = desc,
        .homepage = homepage,
        .license = license,
        .dependencies = dependencies,
        .bottle_url = bottle_url,
        .bottle_sha256 = bottle_sha256,
        .source_url = source_url,
        .source_sha256 = source_sha256,
        .build_deps = build_deps,
        .install_binaries = install_binaries,
        .caveats = caveats,
    };
}

fn formulaFromBottleResolvedFields(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    revision: u32,
    rebuild: u32,
    url_value: []const u8,
    sha256_value: []const u8,
) !Formula {
    if (!isSha256Hex(sha256_value)) return error.AssetDigestInvalid;

    const name = try alloc.dupe(u8, if (record.name.len > 0) record.name else record.token);
    errdefer alloc.free(name);
    const owned_version = try alloc.dupe(u8, version);
    errdefer alloc.free(owned_version);
    const desc = try alloc.dupe(u8, record.desc);
    errdefer alloc.free(desc);
    const homepage = try alloc.dupe(u8, if (record.homepage.len > 0) record.homepage else record.upstream.homepage);
    errdefer alloc.free(homepage);
    const license = try alloc.dupe(u8, "");
    errdefer alloc.free(license);
    const dependencies = try dupeStringList(alloc, record.dependencies);
    errdefer freeStringList(alloc, dependencies);
    const bottle_url = try alloc.dupe(u8, url_value);
    errdefer alloc.free(bottle_url);
    const bottle_sha256 = try alloc.dupe(u8, sha256_value);
    errdefer alloc.free(bottle_sha256);
    const source_url = try alloc.dupe(u8, "");
    errdefer alloc.free(source_url);
    const source_sha256 = try alloc.dupe(u8, "");
    errdefer alloc.free(source_sha256);
    const build_deps = try dupeStringList(alloc, record.build_dependencies);
    errdefer freeStringList(alloc, build_deps);
    const install_binaries = try alloc.alloc([]const u8, 0);
    errdefer alloc.free(install_binaries);
    const caveats = try alloc.dupe(u8, "");
    errdefer alloc.free(caveats);

    return .{
        .name = name,
        .version = owned_version,
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
        .install_binaries = install_binaries,
        .caveats = caveats,
    };
}

fn fetchLatestReleaseJson(alloc: std.mem.Allocator, repo: []const u8) ![]u8 {
    var cache_buf: [512]u8 = undefined;
    const cache_path = try githubReleaseCachePath(repo, &cache_buf);
    if (readCachedFile(alloc, cache_path)) |cached| return cached;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}/releases/latest", .{ GITHUB_API_BASE, repo }) catch return error.NameTooLong;

    const body = fetch.getWithHeaders(alloc, url, &.{
        .{ .name = "User-Agent", .value = "nanobrew-upstream-resolver" },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    }) catch return error.FetchFailed;
    errdefer alloc.free(body);

    const io = paths.safe_io;
    std.Io.Dir.createDirAbsolute(io, API_CACHE_DIR, .default_dir) catch {};
    if (std.Io.Dir.createFileAbsolute(io, cache_path, .{})) |file| {
        defer file.close(io);
        file.writeStreamingAll(io, body) catch {};
    } else |_| {}

    return body;
}

fn caskFromReleaseJson(alloc: std.mem.Allocator, record: *const registry_mod.Record, release_json: []const u8) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, release_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGithubRelease;

    const root = parsed.value.object;
    const tag_name = getStr(root, "tag_name") orelse return error.MissingField;
    const version = versionFromTag(tag_name);
    const assets_val = root.get("assets") orelse return error.MissingField;
    if (assets_val != .array) return error.MissingAsset;

    const asset_rule = selectCurrentPlatformAsset(record.assets) orelse return error.UnsupportedPlatform;
    const rendered_pattern = try renderPattern(alloc, asset_rule.pattern, tag_name, version);
    defer alloc.free(rendered_pattern);

    const asset = findGithubAsset(assets_val.array.items, rendered_pattern) orelse return error.MissingAsset;

    const sha256 = try sha256FromAssetDigest(alloc, record.verification, asset);
    defer alloc.free(sha256);

    return caskFromResolvedFields(alloc, record, version, asset.url, sha256, &.{}, record.artifacts);
}

fn resolvedArtifactRules(record: *const registry_mod.Record, asset: *const registry_mod.ResolvedAsset) []const registry_mod.ArtifactRule {
    return if (asset.artifacts.len > 0) asset.artifacts else record.artifacts;
}

fn caskFromResolvedAsset(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    warnings: []const registry_mod.SecurityWarning,
    asset: *const registry_mod.ResolvedAsset,
) !Cask {
    if (std.mem.eql(u8, asset.sha256, "no_check")) {
        switch (record.verification.sha256) {
            .no_check, .required_or_no_check_with_reason => {},
            else => return error.AssetDigestInvalid,
        }
    } else if (!isSha256Hex(asset.sha256)) return error.AssetDigestInvalid;
    return caskFromResolvedFields(alloc, record, version, asset.url, asset.sha256, warnings, resolvedArtifactRules(record, asset));
}

fn caskFromResolvedFields(
    alloc: std.mem.Allocator,
    record: *const registry_mod.Record,
    version: []const u8,
    url_value: []const u8,
    sha256_value: []const u8,
    warnings_value: []const registry_mod.SecurityWarning,
    artifact_rules: []const registry_mod.ArtifactRule,
) !Cask {
    const token = try alloc.dupe(u8, record.token);
    errdefer alloc.free(token);
    const name = try alloc.dupe(u8, if (record.name.len > 0) record.name else record.token);
    errdefer alloc.free(name);
    const owned_version = try alloc.dupe(u8, version);
    errdefer alloc.free(owned_version);
    const url = try alloc.dupe(u8, url_value);
    errdefer alloc.free(url);
    const homepage = try alloc.dupe(u8, if (record.homepage.len > 0) record.homepage else record.upstream.homepage);
    errdefer alloc.free(homepage);
    const desc = try alloc.dupe(u8, record.desc);
    errdefer alloc.free(desc);
    const sha256 = try alloc.dupe(u8, sha256_value);
    errdefer alloc.free(sha256);
    const security_warnings = try caskSecurityWarningsFromRegistry(alloc, warnings_value);
    errdefer freeCaskSecurityWarnings(alloc, security_warnings);
    const artifacts = try caskArtifactsFromRecord(alloc, artifact_rules);
    errdefer {
        for (artifacts) |artifact| {
            switch (artifact) {
                .app => |app| alloc.free(app),
                .pkg => |pkg| alloc.free(pkg),
                .font => |font| alloc.free(font),
                .artifact => |artifact_rule| {
                    alloc.free(artifact_rule.source);
                    alloc.free(artifact_rule.target);
                },
                .suite => |suite| {
                    alloc.free(suite.source);
                    alloc.free(suite.target);
                },
                .installer_script => |script| {
                    alloc.free(script.executable);
                    for (script.args) |arg| alloc.free(arg);
                    alloc.free(script.args);
                },
                .binary => |bin| {
                    alloc.free(bin.source);
                    alloc.free(bin.target);
                },
                .uninstall => |uninstall| {
                    alloc.free(uninstall.quit);
                    alloc.free(uninstall.pkgutil);
                },
            }
        }
        alloc.free(artifacts);
    }

    return .{
        .token = token,
        .name = name,
        .version = owned_version,
        .url = url,
        .sha256 = sha256,
        .homepage = homepage,
        .desc = desc,
        .auto_updates = record.auto_updates,
        .artifacts = artifacts,
        .min_macos = null,
        .metadata_source = .verified_upstream,
        .security_warnings = security_warnings,
    };
}

fn caskSecurityWarningsFromRegistry(
    alloc: std.mem.Allocator,
    warnings: []const registry_mod.SecurityWarning,
) ![]const CaskSecurityWarning {
    if (warnings.len == 0) return &.{};

    const out = try alloc.alloc(CaskSecurityWarning, warnings.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |warning| warning.deinit(alloc);
        alloc.free(out);
    }

    for (warnings) |warning| {
        out[initialized] = try dupeCaskSecurityWarning(alloc, warning);
        initialized += 1;
    }

    return out;
}

fn dupeCaskSecurityWarning(alloc: std.mem.Allocator, warning: registry_mod.SecurityWarning) !CaskSecurityWarning {
    const ghsa_id = try alloc.dupe(u8, warning.ghsa_id);
    errdefer alloc.free(ghsa_id);
    const cve_id = try alloc.dupe(u8, warning.cve_id);
    errdefer alloc.free(cve_id);
    const severity = try alloc.dupe(u8, warning.severity);
    errdefer alloc.free(severity);
    const summary = try alloc.dupe(u8, warning.summary);
    errdefer alloc.free(summary);
    const url = try alloc.dupe(u8, warning.url);
    errdefer alloc.free(url);
    const affected_versions = try alloc.dupe(u8, warning.affected_versions);
    errdefer alloc.free(affected_versions);
    const patched_versions = try alloc.dupe(u8, warning.patched_versions);
    errdefer alloc.free(patched_versions);

    return .{
        .ghsa_id = ghsa_id,
        .cve_id = cve_id,
        .severity = severity,
        .summary = summary,
        .url = url,
        .affected_versions = affected_versions,
        .patched_versions = patched_versions,
    };
}

fn freeCaskSecurityWarnings(alloc: std.mem.Allocator, warnings: []const CaskSecurityWarning) void {
    for (warnings) |warning| warning.deinit(alloc);
    if (warnings.len > 0) alloc.free(warnings);
}

fn findGithubAsset(items: []const std.json.Value, pattern: []const u8) ?GithubAsset {
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const name = getStr(obj, "name") orelse continue;
        if (!globMatch(pattern, name)) continue;
        return .{
            .name = name,
            .url = getStr(obj, "browser_download_url") orelse continue,
            .digest = getStr(obj, "digest") orelse "",
        };
    }
    return null;
}

fn sha256FromAssetDigest(alloc: std.mem.Allocator, verification: registry_mod.Verification, asset: GithubAsset) ![]const u8 {
    return switch (verification.sha256) {
        .asset_digest, .asset_or_sidecar, .required => blk: {
            const prefix = "sha256:";
            if (!std.mem.startsWith(u8, asset.digest, prefix)) return error.AssetDigestMissing;
            const hex = asset.digest[prefix.len..];
            if (!isSha256Hex(hex)) return error.AssetDigestInvalid;
            break :blk try alloc.dupe(u8, hex);
        },
        .no_check, .required_or_no_check_with_reason => try alloc.dupe(u8, "no_check"),
    };
}

fn caskArtifactsFromRecord(alloc: std.mem.Allocator, rules: []const registry_mod.ArtifactRule) ![]const Artifact {
    var artifacts: std.ArrayList(Artifact) = .empty;
    defer artifacts.deinit(alloc);
    errdefer {
        for (artifacts.items) |artifact| {
            switch (artifact) {
                .app => |app| alloc.free(app),
                .pkg => |pkg| alloc.free(pkg),
                .font => |font| alloc.free(font),
                .artifact => |artifact_rule| {
                    alloc.free(artifact_rule.source);
                    alloc.free(artifact_rule.target);
                },
                .suite => |suite| {
                    alloc.free(suite.source);
                    alloc.free(suite.target);
                },
                .installer_script => |script| {
                    alloc.free(script.executable);
                    for (script.args) |arg| alloc.free(arg);
                    alloc.free(script.args);
                },
                .binary => |bin| {
                    alloc.free(bin.source);
                    alloc.free(bin.target);
                },
                .uninstall => |uninstall| {
                    alloc.free(uninstall.quit);
                    alloc.free(uninstall.pkgutil);
                },
            }
        }
    }

    for (rules) |rule| {
        switch (rule.type) {
            .app => {
                const app = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(app);
                try artifacts.append(alloc, .{ .app = app });
            },
            .pkg => {
                const pkg = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(pkg);
                try artifacts.append(alloc, .{ .pkg = pkg });
            },
            .binary => {
                const source = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(source);
                const target_value = if (rule.target.len > 0) rule.target else std.fs.path.basename(rule.path);
                const target = try alloc.dupe(u8, target_value);
                errdefer alloc.free(target);
                try artifacts.append(alloc, .{ .binary = .{ .source = source, .target = target } });
            },
            .font => {
                const font = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(font);
                try artifacts.append(alloc, .{ .font = font });
            },
            .artifact => {
                const source = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(source);
                const target = try alloc.dupe(u8, rule.target);
                errdefer alloc.free(target);
                try artifacts.append(alloc, .{ .artifact = .{ .source = source, .target = target } });
            },
            .suite => {
                const source = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(source);
                const target = try alloc.dupe(u8, rule.target);
                errdefer alloc.free(target);
                try artifacts.append(alloc, .{ .suite = .{ .source = source, .target = target } });
            },
            .installer_script => {
                const executable = try alloc.dupe(u8, rule.path);
                errdefer alloc.free(executable);
                const args = try dupeStringList(alloc, rule.args);
                errdefer freeStringList(alloc, args);
                try artifacts.append(alloc, .{ .installer_script = .{ .executable = executable, .args = args } });
            },
        }
    }

    return artifacts.toOwnedSlice(alloc);
}

fn formulaInstallBinariesFromRecord(alloc: std.mem.Allocator, rules: []const registry_mod.ArtifactRule) ![]const []const u8 {
    var binaries: std.ArrayList([]const u8) = .empty;
    defer binaries.deinit(alloc);
    errdefer {
        for (binaries.items) |binary| alloc.free(binary);
    }

    for (rules) |rule| {
        if (rule.type != .binary) continue;
        try binaries.append(alloc, try alloc.dupe(u8, rule.path));
    }

    return binaries.toOwnedSlice(alloc);
}

fn freeStringList(alloc: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

fn dupeStringList(alloc: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    errdefer {
        for (out.items) |item| alloc.free(item);
    }

    for (items) |item| {
        try out.append(alloc, try alloc.dupe(u8, item));
    }

    return out.toOwnedSlice(alloc);
}

fn selectCurrentPlatformAsset(assets: []const registry_mod.AssetRule) ?registry_mod.AssetRule {
    const platform = currentPlatform() orelse return null;

    for (assets) |asset| {
        if (asset.platform == platform) return asset;
    }
    return null;
}

fn currentPlatform() ?registry_mod.Platform {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .macos_arm64,
            .x86_64 => .macos_x86_64,
            else => return null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .linux_x86_64,
            .aarch64 => .linux_aarch64,
            else => return null,
        },
        else => return null,
    };
}

fn renderPattern(alloc: std.mem.Allocator, pattern: []const u8, tag: []const u8, version: []const u8) ![]u8 {
    const with_tag = try std.mem.replaceOwned(u8, alloc, pattern, "{tag}", tag);
    defer alloc.free(with_tag);
    return std.mem.replaceOwned(u8, alloc, with_tag, "{version}", version);
}

fn versionFromTag(tag: []const u8) []const u8 {
    if (tag.len > 1 and (tag[0] == 'v' or tag[0] == 'V') and std.ascii.isDigit(tag[1])) {
        return tag[1..];
    }
    return tag;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var star_value: usize = 0;

    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            star_value = v;
        } else if (star) |s| {
            p = s + 1;
            star_value += 1;
            v = star_value;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn githubReleaseCachePath(repo: []const u8, buf: []u8) ![]const u8 {
    var safe: [256]u8 = undefined;
    if (repo.len > safe.len) return error.NameTooLong;
    for (repo, 0..) |c, i| safe[i] = if (c == '/') '-' else c;
    return std.fmt.bufPrint(buf, "{s}/github-release-{s}.json", .{ API_CACHE_DIR, safe[0..repo.len] });
}

fn readCachedFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    const now_ts = std.Io.Timestamp.now(io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    if (age_ns > CACHE_TTL_NS) return null;
    const sz = @min(st.size, 4 * 1024 * 1024);
    const buf = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < sz) {
        const trimmed = alloc.realloc(buf, n) catch return buf[0..n];
        return trimmed;
    }
    return buf;
}

fn readCachedFormula(alloc: std.mem.Allocator, token: []const u8) ?Formula {
    return readCachedFormulaInner(alloc, token) catch null;
}

pub fn hasCachedFormula(token: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const cache_path = upstreamFormulaCachePath(token, &path_buf) catch return false;
    return cachedFileIsFresh(cache_path);
}

fn cachedFileIsFresh(path: []const u8) bool {
    const io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    if (st.size == 0) return false;
    const now_ts = std.Io.Timestamp.now(io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    return age_ns <= CACHE_TTL_NS;
}

fn readCachedFormulaInner(alloc: std.mem.Allocator, token: []const u8) !Formula {
    var path_buf: [512]u8 = undefined;
    const cache_path = try upstreamFormulaCachePath(token, &path_buf);
    const body = readCachedFile(alloc, cache_path) orelse return error.CacheMiss;
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidField;
    const root = parsed.value.object;
    if (!std.mem.eql(u8, getStr(root, "token") orelse "", token)) return error.InvalidField;
    if (!std.mem.eql(u8, getStr(root, "registry_channel") orelse "", currentRegistryChannel())) return error.InvalidField;

    const name = try alloc.dupe(u8, getStr(root, "name") orelse token);
    errdefer alloc.free(name);
    const version = try alloc.dupe(u8, getStr(root, "version") orelse "");
    errdefer alloc.free(version);
    const revision = parseCachedU32(root.get("revision")) orelse 0;
    const rebuild = parseCachedU32(root.get("rebuild")) orelse 0;
    const desc = try alloc.dupe(u8, getStr(root, "desc") orelse "");
    errdefer alloc.free(desc);
    const homepage = try alloc.dupe(u8, getStr(root, "homepage") orelse "");
    errdefer alloc.free(homepage);
    const license = try alloc.dupe(u8, "");
    errdefer alloc.free(license);
    const dependencies = try parseCachedStringList(alloc, root.get("dependencies"));
    errdefer freeStringList(alloc, dependencies);
    const bottle_url = try alloc.dupe(u8, getStr(root, "bottle_url") orelse "");
    errdefer alloc.free(bottle_url);
    const bottle_sha256 = try alloc.dupe(u8, getStr(root, "bottle_sha256") orelse "");
    errdefer alloc.free(bottle_sha256);
    const source_url = try alloc.dupe(u8, getStr(root, "source_url") orelse "");
    errdefer alloc.free(source_url);
    const source_sha256 = try alloc.dupe(u8, getStr(root, "source_sha256") orelse "");
    errdefer alloc.free(source_sha256);
    const build_deps = try parseCachedStringList(alloc, root.get("build_deps"));
    errdefer freeStringList(alloc, build_deps);
    const install_binaries = try parseCachedStringList(alloc, root.get("install_binaries"));
    errdefer freeStringList(alloc, install_binaries);
    const caveats = try alloc.dupe(u8, "");
    errdefer alloc.free(caveats);

    const has_source = source_url.len > 0 and isSha256Hex(source_sha256);
    const has_bottle = bottle_url.len > 0 and isSha256Hex(bottle_sha256);
    if (version.len == 0 or (!has_source and !has_bottle)) return error.InvalidField;

    return .{
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
        .install_binaries = install_binaries,
        .caveats = caveats,
    };
}

fn parseCachedStringList(alloc: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const val = value orelse return alloc.alloc([]const u8, 0);
    if (val != .array) return error.InvalidField;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);
    errdefer {
        for (list.items) |item| alloc.free(item);
    }
    for (val.array.items) |item| {
        if (item != .string) return error.InvalidField;
        try list.append(alloc, try alloc.dupe(u8, item.string));
    }
    return list.toOwnedSlice(alloc);
}

fn parseCachedU32(value: ?std.json.Value) ?u32 {
    const val = value orelse return null;
    if (val != .integer or val.integer < 0 or val.integer > std.math.maxInt(u32)) return null;
    return @intCast(val.integer);
}

fn writeCachedFormula(token: []const u8, formula: *const Formula) void {
    if (formula.source_url.len == 0 and formula.bottle_url.len == 0) return;
    var path_buf: [512]u8 = undefined;
    const cache_path = upstreamFormulaCachePath(token, &path_buf) catch return;
    const io = paths.safe_io;
    std.Io.Dir.createDirAbsolute(io, API_CACHE_DIR, .default_dir) catch {};

    var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer out.deinit();
    const writer = &out.writer;
    writer.writeAll("{\n") catch return;
    writeJsonField(writer, "token", token, true) catch return;
    writeJsonField(writer, "registry_channel", currentRegistryChannel(), true) catch return;
    writeJsonField(writer, "name", formula.name, true) catch return;
    writeJsonField(writer, "version", formula.version, true) catch return;
    writeJsonNumberField(writer, "revision", formula.revision, true) catch return;
    writeJsonNumberField(writer, "rebuild", formula.rebuild, true) catch return;
    writeJsonField(writer, "desc", formula.desc, true) catch return;
    writeJsonField(writer, "homepage", formula.homepage, true) catch return;
    writeJsonField(writer, "bottle_url", formula.bottle_url, true) catch return;
    writeJsonField(writer, "bottle_sha256", formula.bottle_sha256, true) catch return;
    writeJsonField(writer, "source_url", formula.source_url, true) catch return;
    writeJsonField(writer, "source_sha256", formula.source_sha256, true) catch return;
    writeJsonStringArrayField(writer, "dependencies", formula.dependencies, true) catch return;
    writeJsonStringArrayField(writer, "build_deps", formula.build_deps, true) catch return;
    writeJsonStringArrayField(writer, "install_binaries", formula.install_binaries, false) catch return;
    writer.writeAll("}\n") catch return;

    const body = out.toOwnedSlice() catch return;
    defer std.heap.smp_allocator.free(body);

    if (std.Io.Dir.createFileAbsolute(io, cache_path, .{})) |file| {
        defer file.close(io);
        file.writeStreamingAll(io, body) catch {};
    } else |_| {}
}

fn writeJsonNumberField(writer: *std.Io.Writer, key: []const u8, value: u32, comma: bool) !void {
    try writer.writeAll("  ");
    try writeJsonString(writer, key);
    try writer.print(": {d}", .{value});
    if (comma) try writer.writeAll(",");
    try writer.writeAll("\n");
}

fn writeJsonStringArrayField(writer: *std.Io.Writer, key: []const u8, items: []const []const u8, comma: bool) !void {
    try writer.writeAll("  ");
    try writeJsonString(writer, key);
    try writer.writeAll(": [");
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
    if (comma) try writer.writeAll(",");
    try writer.writeAll("\n");
}

fn writeJsonField(writer: *std.Io.Writer, key: []const u8, value: []const u8, comma: bool) !void {
    try writer.writeAll("  ");
    try writeJsonString(writer, key);
    try writer.writeAll(": ");
    try writeJsonString(writer, value);
    if (comma) try writer.writeAll(",");
    try writer.writeAll("\n");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn upstreamFormulaCachePath(token: []const u8, buf: []u8) ![]const u8 {
    var safe: [256]u8 = undefined;
    if (token.len > safe.len) return error.NameTooLong;
    for (token, 0..) |c, i| {
        safe[i] = switch (c) {
            '/', ':', '\\' => '-',
            else => c,
        };
    }
    const channel_hash = std.hash.Wyhash.hash(0, currentRegistryChannel());
    return std.fmt.bufPrint(buf, "{s}/upstream-formula-{x}-{s}.json", .{ API_CACHE_DIR, channel_hash, safe[0..token.len] });
}

fn currentRegistryChannel() []const u8 {
    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE") != null) return "embedded";
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_URL")) |remote_url| {
        if (remote_url.len > 0) return remote_url;
    }
    return registry_mod.DEFAULT_REMOTE_REGISTRY_URL;
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

const testing = std.testing;

test "versionFromTag strips common v prefix" {
    try testing.expectEqualStrings("10.12.0", versionFromTag("v10.12.0"));
    try testing.expectEqualStrings("release-20250829", versionFromTag("release-20250829"));
}

test "globMatch supports wildcard asset patterns" {
    try testing.expect(globMatch("86Box-macOS-x86_64+arm64-b*.zip", "86Box-macOS-x86_64+arm64-b8200.zip"));
    try testing.expect(!globMatch("AltTab-*.zip", "AltTab.app.dSYM.zip"));
}

test "caskFromReleaseJson maps GitHub release asset to Cask" {
    // Cask asset selection is keyed on macOS platforms; skip elsewhere.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "alt-tab",
        \\    "name": "AltTab",
        \\    "kind": "cask",
        \\    "homepage": "https://alt-tab.app/",
        \\    "desc": "Enable Windows-like alt-tab",
        \\    "auto_updates": true,
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "lwouis/alt-tab-macos",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "AltTab-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "AltTab-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "AltTab.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "v10.12.0",
        \\  "assets": [
        \\    {
        \\      "name": "AltTab-10.12.0.zip",
        \\      "browser_download_url": "https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip",
        \\      "digest": "sha256:e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14"
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("alt-tab", .cask).?;
    const cask = try caskFromReleaseJson(testing.allocator, record, release_json);
    defer cask.deinit(testing.allocator);

    try testing.expectEqualStrings("alt-tab", cask.token);
    try testing.expectEqualStrings("AltTab", cask.name);
    try testing.expectEqualStrings("10.12.0", cask.version);
    try testing.expectEqualStrings("e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14", cask.sha256);
    try testing.expectEqual(@as(usize, 1), cask.artifacts.len);
    try testing.expectEqualStrings("AltTab.app", cask.artifacts[0].app);
}

test "fetchCaskFromRecord maps resolved vendor cask with no_check sha" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "google-chrome",
        \\    "name": "Google Chrome",
        \\    "kind": "cask",
        \\    "homepage": "https://www.google.com/chrome/",
        \\    "desc": "Web browser",
        \\    "auto_updates": true,
        \\    "upstream": {
        \\      "type": "vendor_url",
        \\      "homepage": "https://www.google.com/chrome/",
        \\      "release_feed": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
        \\      "allow_domains": ["dl.google.com"],
        \\      "verified": true
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "Google Chrome.app" },
        \\      { "type": "binary", "path": "$APPDIR/Google Chrome.app/Contents/MacOS/google-chrome", "target": "chrome" }
        \\    ],
        \\    "resolved": {
        \\      "version": "147.0.7727.117",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
        \\          "sha256": "no_check"
        \\        },
        \\        "macos-x86_64": {
        \\          "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
        \\          "sha256": "no_check"
        \\        },
        \\        "linux-x86_64": {
        \\          "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
        \\          "sha256": "no_check"
        \\        },
        \\        "linux-aarch64": {
        \\          "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
        \\          "sha256": "no_check"
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "no_check",
        \\      "no_check_reason": "Google Chrome stable dmg is served from a mutable vendor URL."
        \\    }
        \\  }]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("google-chrome", .cask).?;
    const cask = try fetchCaskFromRecord(testing.allocator, record);
    defer cask.deinit(testing.allocator);

    try testing.expectEqualStrings("google-chrome", cask.token);
    try testing.expectEqualStrings("Google Chrome", cask.name);
    try testing.expectEqualStrings("147.0.7727.117", cask.version);
    try testing.expectEqualStrings("no_check", cask.sha256);
    try testing.expectEqual(@as(usize, 2), cask.artifacts.len);
    try testing.expectEqualStrings("Google Chrome.app", cask.artifacts[0].app);
    try testing.expectEqualStrings("$APPDIR/Google Chrome.app/Contents/MacOS/google-chrome", cask.artifacts[1].binary.source);
    try testing.expectEqualStrings("chrome", cask.artifacts[1].binary.target);
}

test "formulaFromReleaseJson maps GitHub release asset to source formula" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "just",
        \\    "name": "just",
        \\    "kind": "formula",
        \\    "homepage": "https://github.com/casey/just",
        \\    "desc": "Command runner",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "casey/just",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "just-{tag}-aarch64-apple-darwin.tar.gz" },
        \\      "macos-x86_64": { "pattern": "just-{tag}-x86_64-apple-darwin.tar.gz" },
        \\      "linux-x86_64": { "pattern": "just-{tag}-x86_64-unknown-linux-musl.tar.gz" },
        \\      "linux-aarch64": { "pattern": "just-{tag}-aarch64-unknown-linux-musl.tar.gz" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "binary", "path": "just" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "1.50.0",
        \\  "assets": [
        \\    {
        \\      "name": "just-1.50.0-aarch64-apple-darwin.tar.gz",
        \\      "browser_download_url": "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-aarch64-apple-darwin.tar.gz",
        \\      "digest": "sha256:891262207663bff1aa422dbe799a76deae4064eaa445f14eb28aef7a388222cd"
        \\    },
        \\    {
        \\      "name": "just-1.50.0-x86_64-apple-darwin.tar.gz",
        \\      "browser_download_url": "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-x86_64-apple-darwin.tar.gz",
        \\      "digest": "sha256:e4fa28fe63381ca32fad101e86d4a1da7cd2d34d1b080985a37ec9dc951922fe"
        \\    },
        \\    {
        \\      "name": "just-1.50.0-x86_64-unknown-linux-musl.tar.gz",
        \\      "browser_download_url": "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-x86_64-unknown-linux-musl.tar.gz",
        \\      "digest": "sha256:27e011cd6328fadd632e59233d2cf5f18460b8a8c4269acd324c1a8669f34db0"
        \\    },
        \\    {
        \\      "name": "just-1.50.0-aarch64-unknown-linux-musl.tar.gz",
        \\      "browser_download_url": "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-aarch64-unknown-linux-musl.tar.gz",
        \\      "digest": "sha256:3beb4967ce05883cf09ac12d6d128166eb4c6d0b03eff74b61018a6880655d7d"
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("just", .formula).?;
    const formula = try formulaFromReleaseJson(testing.allocator, record, release_json);
    defer formula.deinit(testing.allocator);

    try testing.expectEqualStrings("just", formula.name);
    try testing.expectEqualStrings("1.50.0", formula.version);
    try testing.expectEqualStrings("", formula.bottle_url);
    try testing.expect(std.mem.indexOf(u8, formula.source_url, "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-") == 0);
    try testing.expect(isSha256Hex(formula.source_sha256));
    try testing.expectEqual(@as(usize, 1), formula.install_binaries.len);
    try testing.expectEqualStrings("just", formula.install_binaries[0]);
}

test "fetchFormulaFromRecord maps resolved Homebrew bottle formula" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cmake",
        \\    "name": "cmake",
        \\    "kind": "formula",
        \\    "homepage": "https://cmake.org/",
        \\    "desc": "Cross-platform make",
        \\    "revision": 1,
        \\    "rebuild": 2,
        \\    "dependencies": ["openssl@3"],
        \\    "build_dependencies": ["pkgconf"],
        \\    "upstream": {
        \\      "type": "homebrew_bottle",
        \\      "verified": true
        \\    },
        \\    "resolved": {
        \\      "version": "4.3.2",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://ghcr.io/v2/homebrew/core/cmake/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "macos-x86_64": {
        \\          "url": "https://ghcr.io/v2/homebrew/core/cmake/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\        },
        \\        "linux-x86_64": {
        \\          "url": "https://ghcr.io/v2/homebrew/core/cmake/blobs/sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        \\          "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        \\        },
        \\        "linux-aarch64": {
        \\          "url": "https://ghcr.io/v2/homebrew/core/cmake/blobs/sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        \\          "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "required"
        \\    }
        \\  }]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("cmake", .formula).?;
    const formula = try fetchFormulaFromRecord(testing.allocator, record);
    defer formula.deinit(testing.allocator);

    try testing.expectEqualStrings("cmake", formula.name);
    try testing.expectEqualStrings("4.3.2", formula.version);
    try testing.expectEqual(@as(u32, 1), formula.revision);
    try testing.expectEqual(@as(u32, 2), formula.rebuild);
    try testing.expectEqualStrings("", formula.source_url);
    try testing.expect(isSha256Hex(formula.bottle_sha256));
    try testing.expect(std.mem.indexOf(u8, formula.bottle_url, "https://ghcr.io/v2/homebrew/core/cmake/blobs/sha256:") == 0);
    try testing.expectEqual(@as(usize, 1), formula.dependencies.len);
    try testing.expectEqualStrings("openssl@3", formula.dependencies[0]);
    try testing.expectEqual(@as(usize, 1), formula.build_deps.len);
    try testing.expectEqualStrings("pkgconf", formula.build_deps[0]);
    try testing.expectEqual(@as(usize, 0), formula.install_binaries.len);
}

test "fetchFormulaFromRecord falls back to previous version when pin is revoked" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cvetool",
        \\    "name": "cvetool",
        \\    "kind": "formula",
        \\    "revision": 1,
        \\    "upstream": {
        \\      "type": "homebrew_bottle",
        \\      "verified": true
        \\    },
        \\    "resolved": {
        \\      "version": "2.0.0",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "macos-x86_64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "linux-x86_64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "linux-aarch64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        }
        \\      },
        \\      "revoked": {
        \\        "advisory": "CVE-2026-9999",
        \\        "reason": "RCE in archive handling"
        \\      },
        \\      "fallback": {
        \\        "version": "1.9.0",
        \\        "assets": {
        \\          "macos-arm64": {
        \\            "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\          },
        \\          "macos-x86_64": {
        \\            "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\          },
        \\          "linux-x86_64": {
        \\            "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\          },
        \\          "linux-aarch64": {
        \\            "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "required"
        \\    }
        \\  }]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("cvetool", .formula).?;
    const formula = try fetchFormulaFromRecord(testing.allocator, record);
    defer formula.deinit(testing.allocator);

    try testing.expectEqualStrings("1.9.0", formula.version);
    try testing.expectEqual(@as(u32, 0), formula.revision);
    var effective_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1.9.0", formula.effectiveVersion(&effective_buf));
    try testing.expect(std.mem.indexOf(u8, formula.bottle_url, "sha256:bbbb") != null);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", formula.bottle_sha256);
    // The flag is what stops the live-API freshness override (#308) from
    // undoing the security downgrade.
    try testing.expect(formula.revoked_fallback);
}

test "fetchFormulaFromRecord fails closed on revoked pin without fallback" {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cvetool",
        \\    "name": "cvetool",
        \\    "kind": "formula",
        \\    "revision": 1,
        \\    "upstream": {
        \\      "type": "homebrew_bottle",
        \\      "verified": true
        \\    },
        \\    "resolved": {
        \\      "version": "2.0.0",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "macos-x86_64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "linux-x86_64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        },
        \\        "linux-aarch64": {
        \\          "url": "https://ghcr.io/v2/justrach/nb-bottles/cvetool/blobs/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        }
        \\      },
        \\      "revoked": {
        \\        "advisory": "CVE-2026-9999"
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "required"
        \\    }
        \\  }]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("cvetool", .formula).?;
    try testing.expectError(error.RevokedPin, fetchFormulaFromRecord(testing.allocator, record));
}

fn caskFromReleaseJsonAllocationProbe(alloc: std.mem.Allocator) !void {
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "alt-tab",
        \\    "name": "AltTab",
        \\    "kind": "cask",
        \\    "homepage": "https://alt-tab.app/",
        \\    "desc": "Enable Windows-like alt-tab",
        \\    "auto_updates": true,
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "lwouis/alt-tab-macos",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "AltTab-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "AltTab-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "AltTab.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "v10.12.0",
        \\  "assets": [
        \\    {
        \\      "name": "AltTab-10.12.0.zip",
        \\      "browser_download_url": "https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip",
        \\      "digest": "sha256:e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14"
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(alloc, registry_json);
    defer reg.deinit(alloc);
    const record = reg.find("alt-tab", .cask).?;
    const cask = try caskFromReleaseJson(alloc, record, release_json);
    defer cask.deinit(alloc);
}

test "caskFromReleaseJson handles allocation failures" {
    // Cask asset selection is keyed on macOS platforms; skip elsewhere.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    testing.checkAllAllocationFailures(testing.allocator, caskFromReleaseJsonAllocationProbe, .{}) catch |err| switch (err) {
        // Zig 0.17's JSON object map can vary its allocation count after an
        // injected failure. This is a test-harness limitation, not a leak.
        error.NondeterministicMemoryUsage => return error.SkipZigTest,
        else => return err,
    };
}

test "caskFromReleaseJson requires asset digest for verified casks" {
    // Cask asset selection is keyed on macOS platforms; skip elsewhere.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const registry_json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "missing-digest",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/repo",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "App-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "App-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "App.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const release_json =
        \\{
        \\  "tag_name": "v1.0.0",
        \\  "assets": [
        \\    {
        \\      "name": "App-1.0.0.zip",
        \\      "browser_download_url": "https://github.com/owner/repo/releases/download/v1.0.0/App-1.0.0.zip",
        \\      "digest": null
        \\    }
        \\  ]
        \\}
    ;

    const reg = try registry_mod.parseRegistry(testing.allocator, registry_json);
    defer reg.deinit(testing.allocator);
    const record = reg.find("missing-digest", .cask).?;
    try testing.expectError(error.AssetDigestMissing, caskFromReleaseJson(testing.allocator, record, release_json));
}
