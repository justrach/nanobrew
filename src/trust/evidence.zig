const std = @import("std");
const builtin = @import("builtin");
const paths = @import("../platform/paths.zig");
const fetch = @import("../net/fetch.zig");
const version_mod = @import("../version.zig");
const registry = @import("../upstream/registry.zig");
const Formula = @import("../api/formula.zig").Formula;
const Cask = @import("../api/cask.zig").Cask;
const owned = @import("owned.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Kind = enum { formula, cask };
pub const Result = enum { pass, fail };
pub const Source = enum { ci, attested, field };
pub const PROBE_SCHEMA: u32 = 3;
pub const MAX_AGE_SECONDS: i64 = 30 * 86400;
pub const CACHE_TTL_SECONDS: i64 = 6 * 3600;
pub const DEFAULT_URL = "https://raw.githubusercontent.com/justrach/nanobrew/main/registry/trust-evidence.json";
pub const DEFAULT_CACHE = paths.API_CACHE_DIR ++ "/trust-evidence.json";

pub fn platform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "macos_arm64" else "macos_x86_64",
        .linux => if (builtin.cpu.arch == .aarch64) "linux_aarch64" else "linux_x86_64",
        else => "unsupported",
    };
}

pub const Entry = struct {
    token: []const u8,
    kind: Kind,
    version: []const u8,
    platform: []const u8,
    sha256: []const u8,
    result: Result,
    source: Source,
    observed_at: i64,
    probe_schema: u32,
    nb_version: []const u8,
    run: []const u8 = "",
    source_verified: bool = false,
    distinct_successes: u32 = 0,
    distinct_failures: u32 = 0,
    formula: ?Formula = null,
    cask: ?Cask = null,

    pub fn usable(self: Entry, now: i64) bool {
        if (self.probe_schema != PROBE_SCHEMA or self.observed_at > now + 300 or now - self.observed_at > MAX_AGE_SECONDS) return false;
        if (self.source == .field) {
            const total: u64 = @as(u64, self.distinct_successes) + self.distinct_failures;
            if (self.result == .pass and (self.distinct_successes < 25 or @as(u64, self.distinct_failures) * 100 >= total * 2)) return false;
            if (self.result == .fail and (total < 25 or @as(u64, self.distinct_failures) * 100 < total * 2)) return false;
        }
        return true;
    }

    pub fn toFormula(self: Entry, a: std.mem.Allocator) !Formula {
        return owned.clone(Formula, a, self.formula orelse return error.MissingTrustMetadata);
    }
    pub fn toCask(self: Entry, a: std.mem.Allocator) !Cask {
        return owned.clone(Cask, a, self.cask orelse return error.MissingTrustMetadata);
    }
};

pub const Feed = struct {
    schema_version: u32,
    generated_at: i64,
    evidence: []const Entry,

    pub fn latest(self: Feed, token: []const u8, kind: Kind, ver: []const u8, plat: []const u8, sha: []const u8, now: i64) ?*const Entry {
        var best: ?*const Entry = null;
        for (self.evidence) |*e| {
            if (!e.usable(now) or e.kind != kind or !std.mem.eql(u8, e.token, token) or !std.mem.eql(u8, e.version, ver) or !std.mem.eql(u8, e.platform, plat) or !std.ascii.eqlIgnoreCase(e.sha256, sha)) continue;
            // A failure wins ties. Newer observations supersede older ones.
            if (best == null or e.observed_at > best.?.observed_at or (e.observed_at == best.?.observed_at and e.result == .fail)) best = e;
        }
        return best;
    }

    pub fn newestPassing(self: Feed, token: []const u8, kind: Kind, plat: []const u8, now: i64) ?*const Entry {
        var best: ?*const Entry = null;
        for (self.evidence) |*e| {
            if (e.kind != kind or !std.mem.eql(u8, e.token, token) or !std.mem.eql(u8, e.platform, plat)) continue;
            const current = self.latest(token, kind, e.version, plat, e.sha256, now) orelse continue;
            if (current.result != .pass or (kind == .formula and current.formula == null) or (kind == .cask and current.cask == null)) continue;
            if (best == null or version_mod.isNewer(current.version, best.?.version) or (std.mem.eql(u8, current.version, best.?.version) and current.observed_at > best.?.observed_at)) best = current;
        }
        return best;
    }
};

pub const Document = std.json.Parsed(Feed);
pub fn parse(a: std.mem.Allocator, bytes: []const u8, now: i64) !Document {
    var doc = try std.json.parseFromSlice(Feed, a, bytes, .{ .allocate = .alloc_always });
    errdefer doc.deinit();
    if (doc.value.schema_version != 1 or doc.value.generated_at > now + 300 or now - doc.value.generated_at > MAX_AGE_SECONDS or doc.value.evidence.len > 50000) return error.InvalidTrustEvidence;
    for (doc.value.evidence) |e| {
        if (!safeToken(e.token) or !safeVersion(e.version) or !validSha(e.sha256)) return error.InvalidTrustEvidence;
        if (!std.mem.eql(u8, e.platform, "macos_arm64") and !std.mem.eql(u8, e.platform, "macos_x86_64") and !std.mem.eql(u8, e.platform, "linux_x86_64") and !std.mem.eql(u8, e.platform, "linux_aarch64")) return error.InvalidTrustEvidence;
        if (e.observed_at > doc.value.generated_at + 300) return error.InvalidTrustEvidence;
        if (e.formula) |f| {
            var ver: [256]u8 = undefined;
            if (e.kind != .formula or !std.mem.eql(u8, f.name, e.token) or !std.mem.eql(u8, f.effectiveVersion(&ver), e.version) or !std.ascii.eqlIgnoreCase(formulaSha(f), e.sha256)) return error.InvalidTrustMetadata;
            if (!validUrl(if (f.bottle_url.len > 0) f.bottle_url else f.source_url)) return error.InvalidTrustMetadata;
            for (f.dependencies) |dep| if (!safeToken(dep)) return error.InvalidTrustMetadata;
        }
        if (e.cask) |c| {
            if (e.kind != .cask or !std.mem.eql(u8, c.token, e.token) or !std.mem.eql(u8, c.version, e.version) or !std.ascii.eqlIgnoreCase(c.sha256, e.sha256) or !validUrl(c.url)) return error.InvalidTrustMetadata;
        }
    }
    return doc;
}

pub fn formulaSha(f: Formula) []const u8 {
    return if (f.bottle_url.len > 0) f.bottle_sha256 else f.source_sha256;
}
pub fn validSha(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
fn validUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}
pub fn safeToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 120 or s[0] == '/' or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "@+_.-/", c) == null) return false;
    return true;
}
pub fn safeVersion(s: []const u8) bool {
    if (s.len == 0 or s.len > 128 or std.mem.eql(u8, s, ".") or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "+_.-,", c) == null) return false;
    return true;
}

pub fn verify(bytes: []const u8, signature_hex: []const u8, public_key_hex: []const u8) !void {
    var key: [32]u8 = undefined;
    var signature: [64]u8 = undefined;
    const key_text = std.mem.trim(u8, public_key_hex, " \n\r\t");
    const sig_text = std.mem.trim(u8, signature_hex, " \n\r\t");
    if (key_text.len != 64 or sig_text.len != 128) return error.InvalidTrustSignature;
    _ = std.fmt.hexToBytes(&key, key_text) catch return error.InvalidTrustSignature;
    _ = std.fmt.hexToBytes(&signature, sig_text) catch return error.InvalidTrustSignature;
    const pk = Ed25519.PublicKey.fromBytes(key) catch return error.InvalidTrustSignature;
    Ed25519.Signature.fromBytes(signature).verify(bytes, pk) catch return error.InvalidTrustSignature;
}

pub fn timestamp() i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(paths.safe_io, .real).nanoseconds, std.time.ns_per_s));
}
pub fn env(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}
pub fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = paths.safe_io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > 32 * 1024 * 1024) return error.TrustFileTooLarge;
    const data = try a.alloc(u8, @intCast(size));
    errdefer a.free(data);
    if (try file.readPositionalAll(io, data, 0) != size) return error.TruncatedTrustFile;
    return data;
}
pub fn write(path: []const u8, data: []const u8) !void {
    const io = paths.safe_io;
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
const Envelope = struct { payload: []const u8, signature: []const u8 };
fn verified(a: std.mem.Allocator, bytes: []const u8) !Document {
    const wrapper = try std.json.parseFromSlice(Envelope, a, bytes, .{});
    defer wrapper.deinit();
    try verify(wrapper.value.payload, wrapper.value.signature, env("NANOBREW_TRUST_PUBLIC_KEY") orelse @embedFile("public-key.txt"));
    return parse(a, wrapper.value.payload, timestamp());
}
/// Signed envelope cache. Verification precedes parsing and every cache write.
/// An invalid/unavailable feed cannot grant trust or trigger a downgrade.
pub fn load(a: std.mem.Allocator) !Document {
    const cache = env("NANOBREW_TRUST_EVIDENCE_CACHE") orelse DEFAULT_CACHE;
    var stale: ?Document = null;
    if (read(a, cache)) |bytes| {
        defer a.free(bytes);
        if (verified(a, bytes)) |doc| {
            const file = try std.Io.Dir.cwd().openFile(paths.safe_io, cache, .{});
            defer file.close(paths.safe_io);
            const stat = try file.stat(paths.safe_io);
            const age = std.Io.Timestamp.now(paths.safe_io, .real).nanoseconds - stat.mtime.nanoseconds;
            if (age >= 0 and age <= CACHE_TTL_SECONDS * std.time.ns_per_s) return doc;
            stale = doc;
        } else |_| {}
    } else |_| {}
    defer if (stale) |*d| d.deinit();
    const url = env("NANOBREW_TRUST_EVIDENCE_URL") orelse DEFAULT_URL;
    const bytes = fetch.get(a, url) catch |err| {
        if (stale) |doc| {
            stale = null;
            return doc;
        }
        return err;
    };
    defer a.free(bytes);
    const doc = try verified(a, bytes);
    // A torn cache write is rejected by the signature on the next read.
    write(cache, bytes) catch {};
    return doc;
}

pub fn formulaTier(feed: ?Feed, f: Formula, observed: i64) u8 {
    var buf: [256]u8 = undefined;
    const sha = formulaSha(f);
    if (!validSha(sha)) return 0;
    if (feed) |d| if (d.latest(f.name, .formula, f.effectiveVersion(&buf), platform(), sha, observed)) |e| {
        if (e.result == .pass) return 3;
    };
    return 1;
}

/// Applied before dependency discovery, so fallback metadata brings its own deps.
pub fn chooseFormula(a: std.mem.Allocator, feed: Feed, current: Formula) !Formula {
    if (current.revoked_fallback) return current;
    var buf: [256]u8 = undefined;
    const e = feed.latest(current.name, .formula, current.effectiveVersion(&buf), platform(), formulaSha(current), timestamp()) orelse return current;
    if (e.result != .fail) return current;
    const good = feed.newestPassing(current.name, .formula, platform(), timestamp()) orelse return current;
    try rejectRevoked(a, good.*);
    const replacement = try good.toFormula(a);
    const message = try std.fmt.allocPrint(a, "nb: {s} {s} has failing install evidence; using verified-working {s}\n", .{ current.name, current.effectiveVersion(&buf), good.version });
    defer a.free(message);
    std.Io.File.stderr().writeStreamingAll(paths.safe_io, message) catch {};
    current.deinit(a);
    return replacement;
}

pub fn parseMinTrust(bytes: []const u8) !u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var tier: u8 = 0;
    while (lines.next()) |line| {
        const value = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        if (value.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, value[0..eq], " \t"), "min_trust")) continue;
        tier = std.fmt.parseInt(u8, std.mem.trim(u8, value[eq + 1 ..], " \t"), 10) catch return error.InvalidMinTrust;
        if (tier > 3) return error.InvalidMinTrust;
    }
    return tier;
}
pub fn minTrust(a: std.mem.Allocator) !u8 {
    if (env("NANOBREW_MIN_TRUST")) |v| {
        const tier = try std.fmt.parseInt(u8, v, 10);
        if (tier > 3) return error.InvalidMinTrust;
        return tier;
    }
    const data = read(a, env("NANOBREW_CONFIG") orelse paths.CONFIG_DIR ++ "/config.toml") catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer a.free(data);
    return parseMinTrust(data);
}

test "signed evidence rejects altered payloads" {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const sig = try pair.sign("payload", null);
    const key_hex = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
    try verify("payload", &sig_hex, &key_hex);
    try std.testing.expectError(error.InvalidTrustSignature, verify("changed", &sig_hex, &key_hex));
}
test "trust config fails closed" {
    try std.testing.expectEqual(@as(u8, 3), try parseMinTrust("min_trust = 3 # required\n"));
    try std.testing.expectError(error.InvalidMinTrust, parseMinTrust("min_trust=4"));
}

test "evidence is artifact scoped and newest failures supersede passes" {
    const t: i64 = 1800000000;
    const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const base = Entry{ .token = "jq", .kind = .formula, .version = "1.0", .platform = "linux_x86_64", .sha256 = sha, .result = .pass, .source = .ci, .observed_at = t - 10, .probe_schema = PROBE_SCHEMA, .nb_version = "test", .formula = .{ .name = "jq", .version = "1.0", .bottle_sha256 = sha, .bottle_url = "https://example.org/jq.tar.gz" } };
    var entries = [_]Entry{ base, base, base };
    entries[1].result = .fail;
    entries[1].observed_at = t;
    entries[2].version = "0.9";
    entries[2].formula.?.version = "0.9";
    const feed = Feed{ .schema_version = 1, .generated_at = t, .evidence = &entries };
    try std.testing.expectEqual(Result.fail, feed.latest("jq", .formula, "1.0", "linux_x86_64", sha, t).?.result);
    try std.testing.expect(feed.latest("jq", .formula, "1.0", "macos_arm64", sha, t) == null);
    try std.testing.expect(feed.latest("jq", .formula, "1.0", "linux_x86_64", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", t) == null);
    try std.testing.expectEqualStrings("0.9", feed.newestPassing("jq", .formula, "linux_x86_64", t).?.version);
    try std.testing.expect(feed.newestPassing("jq", .formula, "linux_x86_64", t + MAX_AGE_SECONDS + 1) == null);
    const cloned = try entries[2].toFormula(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0.9", cloned.version);
}
test "field promotion requires distinct successes and less than two percent failures" {
    var e = Entry{ .token = "jq", .kind = .formula, .version = "1", .platform = "linux_x86_64", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .result = .pass, .source = .field, .observed_at = 100, .probe_schema = PROBE_SCHEMA, .nb_version = "test" };
    e.distinct_successes = 24;
    try std.testing.expect(!e.usable(100));
    e.distinct_successes = 25;
    try std.testing.expect(e.usable(100));
    e.distinct_successes = 49;
    e.distinct_failures = 1;
    try std.testing.expect(!e.usable(100));
    e.distinct_successes = 50;
    try std.testing.expect(e.usable(100));
}

/// Published install evidence never overrides an explicit artifact revocation.
pub fn rejectRevoked(a: std.mem.Allocator, e: Entry) !void {
    const kind: registry.Kind = if (e.kind == .formula) .formula else .cask;
    const record = registry.loadRecord(a, e.token, kind) catch return;
    defer record.deinit(a);
    const resolved = record.resolved orelse return;
    const plat = std.meta.stringToEnum(registry.Platform, e.platform) orelse return error.InvalidTrustEvidence;
    var current: ?*const registry.Resolved = &resolved;
    while (current) |r| : (current = r.fallback) {
        if (r.revoked != null) {
            if (r.findAsset(plat)) |asset| {
                if (std.ascii.eqlIgnoreCase(asset.sha256, e.sha256)) return error.ArtifactRevoked;
            }
        }
    }
}
