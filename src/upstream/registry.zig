// nanobrew — verified upstream release registry
//
// Parses the curated registry used by the future direct-upstream resolver.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const proxy = @import("../net/proxy.zig");
const flate = std.compress.flate;

pub const DEFAULT_REGISTRY_PATH = "registry/upstream.json";
pub const DEFAULT_REGISTRY_JSON = @embedFile("registry_default.json");
pub const DEFAULT_REMOTE_REGISTRY_URL = "https://raw.githubusercontent.com/justrach/nanobrew/main/registry/upstream.json";
pub const DEFAULT_REGISTRY_CACHE_PATH = "/opt/nanobrew/cache/api/upstream-registry.json";
pub const DEFAULT_REGISTRY_CACHE_TTL_NS: i96 = 6 * 3600 * std.time.ns_per_s;

const MAX_REGISTRY_JSON_BYTES = 8 * 1024 * 1024;

pub const LoadOptions = struct {
    cache_path: []const u8 = DEFAULT_REGISTRY_CACHE_PATH,
    remote_url: []const u8 = DEFAULT_REMOTE_REGISTRY_URL,
    allow_remote: bool = true,
    cache_ttl_ns: i96 = DEFAULT_REGISTRY_CACHE_TTL_NS,
};

const CachedRegistryJson = struct {
    data: []u8,
    fresh: bool,
};

pub const Kind = enum {
    formula,
    cask,
};

pub const UpstreamType = enum {
    github_release,
    vendor_url,
    homebrew_bottle,
};

pub const Platform = enum {
    macos_arm64,
    macos_x86_64,
    linux_x86_64,
    linux_aarch64,
};

pub const ArtifactKind = enum {
    app,
    pkg,
    binary,
    font,
    artifact,
    suite,
    installer_script,
};

pub const Sha256Mode = enum {
    asset_or_sidecar,
    asset_digest,
    required,
    required_or_no_check_with_reason,
    no_check,
};

pub const RequirementMode = enum {
    none,
    optional,
    required,
};

pub const Upstream = struct {
    type: UpstreamType,
    repo: []const u8,
    homepage: []const u8,
    release_feed: []const u8,
    allow_domains: []const []const u8,
    verified: bool,

    pub fn deinit(self: Upstream, alloc: std.mem.Allocator) void {
        alloc.free(self.repo);
        alloc.free(self.homepage);
        alloc.free(self.release_feed);
        for (self.allow_domains) |domain| alloc.free(domain);
        alloc.free(self.allow_domains);
    }
};

pub const AssetRule = struct {
    platform: Platform,
    pattern: []const u8,
    strip_components: u32,

    pub fn deinit(self: AssetRule, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
    }
};

pub const ArtifactRule = struct {
    type: ArtifactKind,
    path: []const u8,
    target: []const u8,
    args: []const []const u8,

    pub fn deinit(self: ArtifactRule, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.target);
        for (self.args) |arg| alloc.free(arg);
        alloc.free(self.args);
    }
};

pub const ResolvedAsset = struct {
    platform: Platform,
    url: []const u8,
    sha256: []const u8,
    artifacts: []const ArtifactRule,

    pub fn deinit(self: ResolvedAsset, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.sha256);
        for (self.artifacts) |artifact| artifact.deinit(alloc);
        alloc.free(self.artifacts);
    }
};

pub const SecurityWarning = struct {
    ghsa_id: []const u8,
    cve_id: []const u8,
    severity: []const u8,
    summary: []const u8,
    url: []const u8,
    affected_versions: []const u8,
    patched_versions: []const u8,

    pub fn deinit(self: SecurityWarning, alloc: std.mem.Allocator) void {
        alloc.free(self.ghsa_id);
        alloc.free(self.cve_id);
        alloc.free(self.severity);
        alloc.free(self.summary);
        alloc.free(self.url);
        alloc.free(self.affected_versions);
        alloc.free(self.patched_versions);
    }
};

pub const Revoked = struct {
    advisory: []const u8,
    reason: []const u8,

    pub fn deinit(self: Revoked, alloc: std.mem.Allocator) void {
        alloc.free(self.advisory);
        alloc.free(self.reason);
    }
};

pub const Resolved = struct {
    tag: []const u8,
    version: []const u8,
    revision: u32 = 0,
    rebuild: u32 = 0,
    assets: []const ResolvedAsset,
    security_warnings: []const SecurityWarning,
    revoked: ?Revoked = null,
    fallback: ?*Resolved = null,

    pub fn deinit(self: Resolved, alloc: std.mem.Allocator) void {
        alloc.free(self.tag);
        alloc.free(self.version);
        for (self.assets) |asset| asset.deinit(alloc);
        alloc.free(self.assets);
        for (self.security_warnings) |warning| warning.deinit(alloc);
        alloc.free(self.security_warnings);
        if (self.revoked) |revoked| revoked.deinit(alloc);
        if (self.fallback) |fallback| {
            fallback.deinit(alloc);
            alloc.destroy(fallback);
        }
    }

    pub fn findAsset(self: *const Resolved, platform: Platform) ?*const ResolvedAsset {
        for (self.assets, 0..) |asset, i| {
            if (asset.platform == platform) return &self.assets[i];
        }
        return null;
    }

    /// The pin that should actually be installed: a revoked pin defers to its
    /// fallback (the previous known-good version) when one is recorded.
    /// Returns null when the pin is revoked with no fallback — installing it
    /// would knowingly ship an advisory-affected version.
    pub fn effective(self: *const Resolved) ?*const Resolved {
        if (self.revoked == null) return self;
        if (self.fallback) |fallback| return fallback.effective();
        return null;
    }
};

pub const Verification = struct {
    sha256: Sha256Mode,
    signature: RequirementMode,
    attestation: RequirementMode,
    no_check_reason: []const u8,

    pub fn deinit(self: Verification, alloc: std.mem.Allocator) void {
        alloc.free(self.no_check_reason);
    }
};

pub const Record = struct {
    token: []const u8,
    name: []const u8,
    desc: []const u8,
    homepage: []const u8,
    auto_updates: bool,
    revision: u32,
    rebuild: u32,
    kind: Kind,
    upstream: Upstream,
    dependencies: []const []const u8,
    build_dependencies: []const []const u8,
    assets: []const AssetRule,
    artifacts: []const ArtifactRule,
    resolved: ?Resolved,
    verification: Verification,

    pub fn deinit(self: Record, alloc: std.mem.Allocator) void {
        alloc.free(self.token);
        alloc.free(self.name);
        alloc.free(self.desc);
        alloc.free(self.homepage);
        for (self.dependencies) |dep| alloc.free(dep);
        alloc.free(self.dependencies);
        for (self.build_dependencies) |dep| alloc.free(dep);
        alloc.free(self.build_dependencies);
        self.upstream.deinit(alloc);
        for (self.assets) |asset| asset.deinit(alloc);
        alloc.free(self.assets);
        for (self.artifacts) |artifact| artifact.deinit(alloc);
        alloc.free(self.artifacts);
        if (self.resolved) |resolved| resolved.deinit(alloc);
        self.verification.deinit(alloc);
    }
};

pub const Registry = struct {
    schema_version: u32,
    records: []const Record,

    pub fn deinit(self: Registry, alloc: std.mem.Allocator) void {
        for (self.records) |record| record.deinit(alloc);
        alloc.free(self.records);
    }

    pub fn find(self: *const Registry, token: []const u8, kind: Kind) ?*const Record {
        for (self.records, 0..) |record, i| {
            if (record.kind == kind and std.mem.eql(u8, record.token, token)) {
                return &self.records[i];
            }
        }
        return null;
    }
};

pub fn loadRegistry(alloc: std.mem.Allocator) !Registry {
    var options: LoadOptions = .{};
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_CACHE")) |cache_path| {
        if (cache_path.len > 0) options.cache_path = cache_path;
    }
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_URL")) |remote_url| {
        options.remote_url = remote_url;
    }
    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE") != null) {
        options.allow_remote = false;
    }
    if (options.remote_url.len == 0) {
        options.allow_remote = false;
    }
    return loadRegistryWithOptions(alloc, options);
}

pub fn loadRecord(alloc: std.mem.Allocator, token: []const u8, kind: Kind) !Record {
    var options: LoadOptions = .{};
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_CACHE")) |cache_path| {
        if (cache_path.len > 0) options.cache_path = cache_path;
    }
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_URL")) |remote_url| {
        options.remote_url = remote_url;
    }
    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE") != null) {
        options.allow_remote = false;
    }
    if (options.remote_url.len == 0) {
        options.allow_remote = false;
    }
    return loadRecordWithOptions(alloc, options, token, kind);
}

/// Process-wide memo of the cached registry snapshot. Every per-formula
/// upstream lookup used to open + read the ~650KB cache file and needle-scan
/// it end to end, so a resolve touching N formulae paid N file reads plus N
/// full scans — and a token absent from the registry (most formulae) re-paid
/// that miss path in every single process. The memo shares the snapshot bytes
/// plus a token -> record-range map built in one pass, making every later
/// lookup (hit or miss) O(1). Published slices are never freed; a changed
/// cache file (mtime) replaces the memo, leaking the old one — bounded and
/// fine for a short-lived CLI.
const RecordRange = struct { start: usize, end: usize };

const RegistryMemo = struct {
    cache_path: []const u8,
    mtime_ns: i96,
    data: []const u8,
    map: std.StringHashMap(RecordRange),
    /// Cache snapshot is byte-identical to the embedded registry, so a
    /// cache-map miss is definitive without consulting the embedded map.
    embedded_identical: bool,
    /// Last monotonic revalidation of the file's mtime. Stats are rate-limited:
    /// a resolve burst issues hundreds of lookups in a few milliseconds.
    last_validate_mono_ns: u64,
};

fn registryMonoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const REGISTRY_MEMO_REVALIDATE_NS: u64 = 20 * std.time.ns_per_ms;
var g_registry_memo_mutex: std.atomic.Mutex = .unlocked;
var g_registry_memo: ?*RegistryMemo = null;
var g_embedded_map: ?std.StringHashMap(RecordRange) = null;

const RegistryMemoHit = union(enum) { record: Record, miss, bypass };

fn registryMemoLock() void {
    while (!g_registry_memo_mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Textual `"<field>": "<value>"` extraction from one record object.
fn recordFieldValue(record_json: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{field}) catch return null;
    const k = std.mem.indexOf(u8, record_json, needle) orelse return null;
    var i = k + needle.len;
    while (i < record_json.len and (record_json[i] == ' ' or record_json[i] == ':' or record_json[i] == '\t' or record_json[i] == '\n' or record_json[i] == '\r')) i += 1;
    if (i >= record_json.len or record_json[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, record_json, start, '"') orelse return null;
    return record_json[start..end];
}

/// Textual `"token": "<value>"` extraction from one record object.
fn recordTokenValue(record_json: []const u8) ?[]const u8 {
    return recordFieldValue(record_json, "token");
}

/// One structural pass over a registry snapshot producing token -> byte range
/// for every record object. Keys point into `json`, which must outlive the map.
fn buildRecordRangeMap(pa: std.mem.Allocator, json: []const u8) ?std.StringHashMap(RecordRange) {
    var map = std.StringHashMap(RecordRange).init(pa);
    // Root object: record '{' appears at depth 1. Root array: depth 0.
    var rec_depth: usize = 1;
    for (json) |c| {
        if (c == '{') {
            rec_depth = 1;
            break;
        } else if (c == '[') {
            rec_depth = 0;
            break;
        } else if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var rec_start: usize = 0;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            if (depth == rec_depth) rec_start = i;
            depth += 1;
        } else if (c == '}') {
            if (depth == rec_depth + 1) {
                const range = RecordRange{ .start = rec_start, .end = i + 1 };
                const slice = json[range.start..range.end];
                if (recordTokenValue(slice)) |tok| {
                    // Key by kind as well as token: the same token can appear
                    // as both a formula and a cask, and a kind-mismatched hit
                    // used to fall back to a full snapshot scan.
                    const kind_str = recordFieldValue(slice, "kind") orelse "";
                    var key_buf: [320]u8 = undefined;
                    if (std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ kind_str, tok })) |key| {
                        if (pa.dupe(u8, key)) |key_owned| {
                            const gop = map.getOrPut(key_owned) catch {
                                pa.free(key_owned);
                                depth -= 1;
                                continue;
                            };
                            if (gop.found_existing) {
                                pa.free(key_owned);
                            } else {
                                gop.value_ptr.* = range;
                            }
                        } else |_| {}
                    } else |_| {}
                }
            }
            depth -= 1;
        }
    }
    if (map.count() == 0) {
        map.deinit();
        return null;
    }
    return map;
}

/// On-disk companion index for a registry snapshot: `kind:token\tstart\tend`
/// rows plus a validated row-count footer, written atomically. Rebuilding the
/// token map is a full structural pass over ~650KB of JSON; the sidecar lets
/// every later process load it in one small read. Rows point into the JSON
/// bytes, so the snapshot is still read (but not scanned) per process.
const REGISTRY_IDX_SUFFIX = ".idx.v1";
const REGISTRY_IDX_FOOTER_PREFIX = "#nanobrew-registry-index-v1\t";

fn registryIdxLoad(pa: std.mem.Allocator, idx_path: []const u8, json_mtime_ns: i96) ?std.StringHashMap(RecordRange) {
    const io = paths.safe_io;
    const file = openReadableFile(io, idx_path) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    // A sidecar older than the snapshot it indexes is stale: byte ranges no
    // longer line up (the per-record token check would catch it, but every
    // lookup would fall back to a full scan — rebuild instead).
    if (st.mtime.nanoseconds < json_mtime_ns) return null;
    const sz: usize = @intCast(st.size);
    if (sz == 0 or sz > 4 * 1024 * 1024) return null;
    const buf = pa.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        pa.free(buf);
        return null;
    };
    if (n != sz) {
        pa.free(buf);
        return null;
    }
    const tsv = buf;
    // Footer validation (SIMD row count), same contract as the search idx.
    if (tsv.len == 0 or tsv[tsv.len - 1] != '\n') {
        pa.free(tsv);
        return null;
    }
    const without_final = tsv[0 .. tsv.len - 1];
    const footer_start = if (std.mem.lastIndexOfScalar(u8, without_final, '\n')) |idx| idx + 1 else 0;
    const footer = without_final[footer_start..];
    if (!std.mem.startsWith(u8, footer, REGISTRY_IDX_FOOTER_PREFIX)) {
        pa.free(tsv);
        return null;
    }
    const expected = std.fmt.parseInt(usize, footer[REGISTRY_IDX_FOOTER_PREFIX.len..], 10) catch {
        pa.free(tsv);
        return null;
    };
    const body = tsv[0..footer_start];
    if (std.mem.count(u8, body, "\n") != expected) {
        pa.free(tsv);
        return null;
    }

    var map = std.StringHashMap(RecordRange).init(pa);
    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const key = cols.next() orelse continue;
        const start_s = cols.next() orelse continue;
        const end_s = cols.next() orelse continue;
        const start = std.fmt.parseInt(usize, start_s, 10) catch continue;
        const end = std.fmt.parseInt(usize, end_s, 10) catch continue;
        const key_owned = pa.dupe(u8, key) catch continue;
        map.put(key_owned, .{ .start = start, .end = end }) catch {
            pa.free(key_owned);
            continue;
        };
    }
    if (map.count() == 0) {
        map.deinit();
        pa.free(tsv);
        return null;
    }
    return map;
}

fn registryIdxWrite(idx_path: []const u8, map: *const std.StringHashMap(RecordRange)) void {
    const io = paths.safe_io;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    var it = map.iterator();
    while (it.next()) |entry| {
        buf.print(std.heap.page_allocator, "{s}\t{d}\t{d}\n", .{ entry.key_ptr.*, entry.value_ptr.start, entry.value_ptr.end }) catch return;
    }
    buf.print(std.heap.page_allocator, "{s}{d}\n", .{ REGISTRY_IDX_FOOTER_PREFIX, map.count() }) catch return;

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}.{d}", .{
        idx_path, std.c.getpid(), std.Thread.getCurrentId(),
    }) catch return;
    const file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    file.writeStreamingAll(io, buf.items) catch {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return;
    };
    file.sync(io) catch {};
    file.close(io);
    std.Io.Dir.renameAbsolute(tmp_path, idx_path, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    };
}

fn recordFromRangeMap(alloc: std.mem.Allocator, data: []const u8, map: *const std.StringHashMap(RecordRange), token: []const u8, kind: Kind) ?Record {
    var key_buf: [320]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ @tagName(kind), token }) catch return null;
    const range = map.get(key) orelse return null;
    var record = parseRecordJson(alloc, data[range.start..range.end]) catch return null;
    if (record.kind == kind and std.mem.eql(u8, record.token, token)) return record;
    record.deinit(alloc);
    // Defensive: a kind-keyed hit should always validate; keep the old
    // full-scan behavior as the safety net.
    return parseRecordFromRegistryJson(alloc, data, token, kind) catch null;
}

fn registryMemoFastPath(alloc: std.mem.Allocator, options: LoadOptions, token: []const u8, kind: Kind) RegistryMemoHit {
    const io = paths.safe_io;
    if (options.cache_path.len == 0) return .bypass;

    // Memo bookkeeping under the lock; the memo and maps are immutable once
    // published, so all lookups after the first run lock-free. The file's
    // mtime is re-statted at most once every 20ms — a resolve burst issues
    // hundreds of lookups in less time than that.
    const m: *RegistryMemo = blk: {
        if (g_registry_memo) |old| {
            if (std.mem.eql(u8, old.cache_path, options.cache_path) and
                registryMonoNs() - old.last_validate_mono_ns < REGISTRY_MEMO_REVALIDATE_NS)
            {
                break :blk old;
            }
        }

        registryMemoLock();
        defer g_registry_memo_mutex.unlock();

        // Stat the cache file; a missing/unreadable file cannot be memoized.
        const file = openReadableFile(io, options.cache_path) catch {
            g_registry_memo = null;
            return .bypass;
        };
        const st = file.stat(io) catch {
            file.close(io);
            return .bypass;
        };
        file.close(io);
        if (st.size == 0 or st.size > MAX_REGISTRY_JSON_BYTES) {
            g_registry_memo = null;
            return .bypass;
        }
        const mtime_ns = st.mtime.nanoseconds;

        if (g_registry_memo) |old| {
            if (std.mem.eql(u8, old.cache_path, options.cache_path) and old.mtime_ns == mtime_ns) {
                old.last_validate_mono_ns = registryMonoNs();
                break :blk old;
            }
            g_registry_memo = null; // stale memo: leak, a thread may still read it
        }
        if (g_registry_memo == null) {
            const pa = std.heap.page_allocator;
            const data = data_blk: {
                const f = openReadableFile(io, options.cache_path) catch return .bypass;
                defer f.close(io);
                const sz: usize = @intCast(st.size);
                const buf = pa.alloc(u8, sz) catch return .bypass;
                const n = f.readPositionalAll(io, buf, 0) catch {
                    pa.free(buf);
                    return .bypass;
                };
                if (n != sz) {
                    pa.free(buf);
                    return .bypass;
                }
                break :data_blk buf;
            };
            // Prefer the sidecar index (one small read) over a full structural
            // pass; it must be at least as new as the snapshot it indexes.
            var idx_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const idx_path = std.fmt.bufPrint(&idx_path_buf, "{s}{s}", .{ options.cache_path, REGISTRY_IDX_SUFFIX }) catch "";
            var map: ?std.StringHashMap(RecordRange) = null;
            if (idx_path.len > 0) {
                if (registryIdxLoad(pa, idx_path, mtime_ns)) |loaded| {
                    map = loaded;
                }
            }
            if (map == null) {
                map = buildRecordRangeMap(pa, data);
                if (map != null and idx_path.len > 0) {
                    // Publish for later processes; a stale sidecar is only
                    // refreshed when at least as new as the snapshot (write
                    // the sidecar then bump nothing — mtime ordering vs the
                    // snapshot is the reader's guard).
                    registryIdxWrite(idx_path, &map.?);
                }
            }
            if (map == null) {
                pa.free(data);
                return .bypass;
            }
            const path_copy = pa.dupe(u8, options.cache_path) catch {
                pa.free(data);
                return .bypass;
            };
            const memo = pa.create(RegistryMemo) catch {
                pa.free(data);
                pa.free(path_copy);
                return .bypass;
            };
            memo.* = .{
                .cache_path = path_copy,
                .mtime_ns = mtime_ns,
                .data = data,
                .map = map.?,
                .embedded_identical = std.mem.eql(u8, data, DEFAULT_REGISTRY_JSON),
                .last_validate_mono_ns = registryMonoNs(),
            };
            g_registry_memo = memo;
        }
        break :blk g_registry_memo.?;
    };

    // Freshness is per-call (time advances); a stale cache must run the
    // caller's remote-refresh flow, so stay out of the way.
    const now_ts = std.Io.Timestamp.now(io, .real);
    const fresh = options.cache_ttl_ns < 0 or (now_ts.nanoseconds - m.mtime_ns) <= options.cache_ttl_ns;
    if (!fresh) return .bypass;

    if (recordFromRangeMap(alloc, m.data, &m.map, token, kind)) |record| {
        return .{ .record = record };
    }
    // Embedded fallback, preserving cache ∪ embedded union semantics. When the
    // cached snapshot is byte-identical to the embedded one (the common case:
    // the cache is a refresh of this same registry), a cache-map miss is
    // already definitive — skip the embedded map entirely.
    if (!m.embedded_identical) {
        registryMemoLock();
        const have_map = g_embedded_map != null;
        if (!have_map) {
            g_embedded_map = buildRecordRangeMap(std.heap.page_allocator, DEFAULT_REGISTRY_JSON);
        }
        const emap_opt = g_embedded_map;
        g_registry_memo_mutex.unlock();
        if (emap_opt) |*emap| {
            if (recordFromRangeMap(alloc, DEFAULT_REGISTRY_JSON, emap, token, kind)) |record| {
                return .{ .record = record };
            }
        }
    }
    // Absent from both snapshots: within the TTL a remote refetch returns this
    // same registry, so the miss is authoritative.
    return .miss;
}

/// Read-only view over the memoized registry snapshot for callers that scan
/// many records (e.g. doctor's revocation sweep). Null when no fresh cache
/// snapshot is available.
pub const RegistrySnapshot = struct {
    data: []const u8,
    map: *const std.StringHashMap(RecordRange),
};

pub fn registrySnapshot() ?RegistrySnapshot {
    var options: LoadOptions = .{};
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_CACHE")) |cache_path| {
        if (cache_path.len > 0) options.cache_path = cache_path;
    }
    const m: *RegistryMemo = blk: {
        // Reuse registryMemoFastPath's ensure logic by probing a token that
        // cannot exist; the memo is built as a side effect.
        _ = registryMemoFastPath(std.heap.page_allocator, options, "\x00", .formula);
        registryMemoLock();
        defer g_registry_memo_mutex.unlock();
        break :blk g_registry_memo orelse return null;
    };
    return .{ .data = m.data, .map = &m.map };
}

/// Every formula record whose slice mentions "revoked" (present or null), so
/// callers checking installed versions against revocations parse only the
/// handful of candidate records instead of the whole registry.
pub fn revokedCandidateFormulaRecords(alloc: std.mem.Allocator) ![]Record {
    var out: std.ArrayList(Record) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit(alloc);
        out.deinit(alloc);
    }
    const snap = registrySnapshot() orelse return out.toOwnedSlice(alloc);
    var it = snap.map.iterator();
    while (it.next()) |entry| {
        const range = entry.value_ptr.*;
        const slice = snap.data[range.start..range.end];
        if (std.mem.indexOf(u8, slice, "\"revoked\"") == null) continue;
        var record = parseRecordJson(alloc, slice) catch continue;
        if (record.kind != .formula) {
            record.deinit(alloc);
            continue;
        }
        if (record.resolved == null or record.resolved.?.revoked == null) {
            record.deinit(alloc);
            continue;
        }
        out.append(alloc, record) catch {
            record.deinit(alloc);
            continue;
        };
    }
    return out.toOwnedSlice(alloc);
}

pub fn loadRecordWithOptions(alloc: std.mem.Allocator, options: LoadOptions, token: []const u8, kind: Kind) !Record {
    switch (registryMemoFastPath(alloc, options, token, kind)) {
        .record => |record| return record,
        .miss => return error.UpstreamRecordNotFound,
        .bypass => {},
    }

    var stale_record: ?Record = null;
    errdefer if (stale_record) |record| record.deinit(alloc);

    // A fresh cache is authoritative for misses as well as hits: within the
    // TTL a remote refetch returns the same snapshot we already have, so a
    // token that isn't in the cached registry (most formulae) must not pay a
    // ~650KB network round trip on every resolve — that made a warm
    // single-package install ~150ms instead of ~2ms. The embedded-registry
    // fallback below still runs on a miss, preserving the cache∪embedded
    // union semantics.
    var cache_fresh = false;
    if (readRegistryCache(alloc, options.cache_path, options.cache_ttl_ns)) |cached_json| {
        defer alloc.free(cached_json.data);
        cache_fresh = cached_json.fresh;
        if (parseRecordFromRegistryJson(alloc, cached_json.data, token, kind)) |record| {
            if (cached_json.fresh) return record;
            stale_record = record;
        } else |_| {}
    }

    if (!cache_fresh and options.allow_remote and options.remote_url.len > 0) {
        if (fetchRemoteRegistryJson(alloc, options.remote_url)) |remote_json| {
            defer alloc.free(remote_json);
            // Refresh the cache whenever the payload is a valid registry,
            // even when this token isn't in it. Caching only on a token hit
            // left the cache permanently stale for non-registry tokens, which
            // re-paid the remote fetch on every resolve after TTL expiry.
            if (parseRegistry(alloc, remote_json)) |parsed_registry| {
                parsed_registry.deinit(alloc);
                writeRegistryCache(options.cache_path, remote_json) catch {};
            } else |_| {}
            if (parseRecordFromRegistryJson(alloc, remote_json, token, kind)) |record| {
                if (stale_record) |old_record| old_record.deinit(alloc);
                stale_record = null;
                return record;
            } else |_| {}
        } else |_| {}
    }

    if (stale_record) |record| {
        stale_record = null;
        return record;
    }

    return parseRecordFromRegistryJson(alloc, DEFAULT_REGISTRY_JSON, token, kind);
}

pub fn loadRegistryWithOptions(alloc: std.mem.Allocator, options: LoadOptions) !Registry {
    var stale_registry: ?Registry = null;
    errdefer if (stale_registry) |registry| registry.deinit(alloc);

    if (readRegistryCache(alloc, options.cache_path, options.cache_ttl_ns)) |cached_json| {
        defer alloc.free(cached_json.data);
        if (parseRegistry(alloc, cached_json.data)) |registry| {
            if (cached_json.fresh) return registry;
            stale_registry = registry;
        } else |_| {}
    }

    if (options.allow_remote and options.remote_url.len > 0) {
        if (fetchRemoteRegistryJson(alloc, options.remote_url)) |remote_json| {
            defer alloc.free(remote_json);
            if (parseRegistry(alloc, remote_json)) |registry| {
                writeRegistryCache(options.cache_path, remote_json) catch {};
                if (stale_registry) |old_registry| old_registry.deinit(alloc);
                stale_registry = null;
                return registry;
            } else |_| {}
        } else |_| {}
    }

    if (stale_registry) |registry| {
        stale_registry = null;
        return registry;
    }

    return parseRegistry(alloc, DEFAULT_REGISTRY_JSON);
}

/// Force-fetch the remote registry and overwrite the local cache, ignoring the
/// TTL. Validates that the payload parses before writing so a bad response
/// can't poison the cache. Returns the number of records cached. Lets `nb
/// update` / `nb update-registry` refresh pinned versions without rebuilding
/// the binary (#308/#310 follow-up).
pub fn refreshCache(alloc: std.mem.Allocator) !usize {
    var options: LoadOptions = .{};
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_CACHE")) |cache_path| {
        if (cache_path.len > 0) options.cache_path = cache_path;
    }
    if (envSlice("NANOBREW_UPSTREAM_REGISTRY_URL")) |remote_url| {
        options.remote_url = remote_url;
    }
    if (options.remote_url.len == 0) return error.RemoteRegistryDisabled;
    if (std.c.getenv("NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE") != null) {
        return error.RemoteRegistryDisabled;
    }

    const remote_json = try fetchRemoteRegistryJson(alloc, options.remote_url);
    defer alloc.free(remote_json);

    var registry = try parseRegistry(alloc, remote_json);
    defer registry.deinit(alloc);

    try writeRegistryCache(options.cache_path, remote_json);
    return registry.records.len;
}

pub fn parseRecordJson(alloc: std.mem.Allocator, json_data: []const u8) !Record {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidField;
    return parseRecord(alloc, parsed.value.object);
}

pub fn parseRecordFromRegistryJson(alloc: std.mem.Allocator, json_data: []const u8, token: []const u8, kind: Kind) !Record {
    const needle_spaced = try std.fmt.allocPrint(alloc, "\"token\": \"{s}\"", .{token});
    defer alloc.free(needle_spaced);
    const needle_compact = try std.fmt.allocPrint(alloc, "\"token\":\"{s}\"", .{token});
    defer alloc.free(needle_compact);

    var search_start: usize = 0;
    while (nextNeedleIndex(json_data, search_start, needle_spaced, needle_compact)) |token_idx| {
        search_start = token_idx + 1;
        const start = findRecordObjectStart(json_data, token_idx) orelse continue;
        const end = findObjectEnd(json_data, start) orelse continue;
        var record = parseRecordJson(alloc, json_data[start..end]) catch continue;
        if (record.kind == kind and std.mem.eql(u8, record.token, token)) {
            return record;
        }
        record.deinit(alloc);
    }
    return error.UpstreamRecordNotFound;
}

fn nextNeedleIndex(data: []const u8, start: usize, needle_a: []const u8, needle_b: []const u8) ?usize {
    const a = std.mem.indexOfPos(u8, data, start, needle_a);
    const b = std.mem.indexOfPos(u8, data, start, needle_b);
    if (a) |ai| {
        if (b) |bi| return @min(ai, bi);
        return ai;
    }
    return b;
}

fn findRecordObjectStart(data: []const u8, token_idx: usize) ?usize {
    var i = token_idx;
    while (i > 0) {
        i -= 1;
        if (data[i] == '{') return i;
    }
    return null;
}

fn findObjectEnd(data: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    var i = start;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

pub fn parseRegistry(alloc: std.mem.Allocator, json_data: []const u8) !Registry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRegistryRoot;
    const root = parsed.value.object;

    const schema_version = parseU32(root.get("schema_version") orelse return error.MissingField) orelse return error.InvalidField;
    if (schema_version != 1) return error.UnsupportedSchemaVersion;

    const records_val = root.get("records") orelse return error.MissingField;
    if (records_val != .array) return error.InvalidField;

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(alloc);
    errdefer {
        for (records.items) |record| record.deinit(alloc);
    }

    for (records_val.array.items) |record_val| {
        if (record_val != .object) return error.InvalidField;
        const record = try parseRecord(alloc, record_val.object);
        errdefer record.deinit(alloc);
        try records.append(alloc, record);
    }

    return .{
        .schema_version = schema_version,
        .records = try records.toOwnedSlice(alloc),
    };
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

fn fetchRemoteRegistryJson(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = proxy.Client.init(alloc, paths.safe_io);
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = client.ptr().request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "nanobrew-upstream-registry" },
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch return error.FetchFailed;

    req.sendBodiless() catch {
        req.deinit();
        return error.FetchFailed;
    };

    var head_buf: [32768]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        req.deinit();
        return error.FetchFailed;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch {
        out.deinit();
        req.deinit();
        return error.FetchFailed;
    };
    req.deinit();

    const raw = out.toOwnedSlice() catch {
        out.deinit();
        return error.OutOfMemory;
    };

    if (response.head.content_encoding == .gzip) {
        defer alloc.free(raw);
        return decompressGzip(alloc, raw);
    }

    return raw;
}

fn decompressGzip(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var fixed_reader = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fixed_reader, .gzip, &window);

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    _ = decomp.reader.streamRemaining(&result.writer) catch return error.FetchFailed;
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn readRegistryCache(alloc: std.mem.Allocator, path: []const u8, ttl_ns: i96) ?CachedRegistryJson {
    if (path.len == 0) return null;
    const io = paths.safe_io;
    const file = openReadableFile(io, path) catch return null;
    defer file.close(io);

    const st = file.stat(io) catch return null;
    if (st.size == 0 or st.size > MAX_REGISTRY_JSON_BYTES) return null;
    const sz: usize = @intCast(st.size);

    const data = alloc.alloc(u8, sz) catch return null;
    const n = file.readPositionalAll(io, data, 0) catch {
        alloc.free(data);
        return null;
    };
    if (n != sz) {
        alloc.free(data);
        return null;
    }

    const now_ts = std.Io.Timestamp.now(io, .real);
    const age_ns: i96 = now_ts.nanoseconds - st.mtime.nanoseconds;
    return .{
        .data = data,
        .fresh = ttl_ns < 0 or age_ns <= ttl_ns,
    };
}

fn writeRegistryCache(path: []const u8, data: []const u8) !void {
    if (path.len == 0) return;
    const io = paths.safe_io;
    if (std.fs.path.dirname(path)) |dir_path| {
        if (std.fs.path.isAbsolute(dir_path)) {
            std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        } else {
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    const file = try createWritableFile(io, path);
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn openReadableFile(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn createWritableFile(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

fn parseRecord(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Record {
    const token = try dupRequiredString(alloc, obj, "token");
    errdefer alloc.free(token);
    const name = try dupOptionalString(alloc, obj, "name");
    errdefer alloc.free(name);
    const desc = try dupOptionalString(alloc, obj, "desc");
    errdefer alloc.free(desc);
    const homepage = try dupOptionalString(alloc, obj, "homepage");
    errdefer alloc.free(homepage);
    const auto_updates = getBool(obj, "auto_updates") orelse false;
    const revision = if (obj.get("revision")) |v| parseU32(v) orelse return error.InvalidField else 0;
    const rebuild = if (obj.get("rebuild")) |v| parseU32(v) orelse return error.InvalidField else 0;
    const dependencies = try parseOptionalStringArray(alloc, obj, "dependencies");
    errdefer {
        for (dependencies) |dep| alloc.free(dep);
        alloc.free(dependencies);
    }
    const build_dependencies = try parseOptionalStringArray(alloc, obj, "build_dependencies");
    errdefer {
        for (build_dependencies) |dep| alloc.free(dep);
        alloc.free(build_dependencies);
    }

    const kind = try parseKind(getString(obj, "kind") orelse return error.MissingField);

    const upstream_val = obj.get("upstream") orelse return error.MissingField;
    if (upstream_val != .object) return error.InvalidField;
    const upstream = try parseUpstream(alloc, upstream_val.object);
    errdefer upstream.deinit(alloc);

    const verification_val = obj.get("verification") orelse return error.MissingField;
    if (verification_val != .object) return error.InvalidField;
    const verification = try parseVerification(alloc, kind, verification_val.object);
    errdefer verification.deinit(alloc);

    var assets = try alloc.alloc(AssetRule, 0);
    errdefer freeAssets(alloc, assets);
    var artifacts = try alloc.alloc(ArtifactRule, 0);
    errdefer freeArtifacts(alloc, artifacts);
    var resolved: ?Resolved = null;
    errdefer if (resolved) |r| r.deinit(alloc);

    switch (kind) {
        .formula => {
            if (obj.get("assets")) |assets_val| {
                alloc.free(assets);
                if (assets_val != .object) return error.InvalidField;
                assets = try parseAssets(alloc, assets_val.object);
                if (upstream.type == .github_release and assets.len == 0) return error.MissingAssets;
            } else if (upstream.type == .github_release) {
                return error.MissingAssets;
            }

            if (obj.get("artifacts")) |artifacts_val| {
                alloc.free(artifacts);
                if (artifacts_val != .array) return error.InvalidField;
                artifacts = try parseArtifacts(alloc, artifacts_val.array.items);
                for (artifacts) |artifact| {
                    if (artifact.type != .binary) return error.UnsupportedArtifactType;
                }
            }
        },
        .cask => {
            if (obj.get("assets")) |assets_val| {
                alloc.free(assets);
                if (assets_val != .object) return error.InvalidField;
                assets = try parseAssets(alloc, assets_val.object);
                if (upstream.type == .github_release and assets.len == 0) return error.MissingAssets;
            } else if (upstream.type == .github_release) {
                return error.MissingAssets;
            }

            alloc.free(artifacts);
            const artifacts_val = obj.get("artifacts") orelse return error.MissingField;
            if (artifacts_val != .array) return error.InvalidField;
            artifacts = try parseArtifacts(alloc, artifacts_val.array.items);
            if (artifacts.len == 0) return error.MissingArtifacts;
        },
    }

    if (obj.get("resolved")) |resolved_val| {
        if (resolved_val != .object) return error.InvalidField;
        var parsed_resolved = try parseResolved(alloc, resolved_val.object);
        // Existing registries store the current pin's package identity at the
        // record level. Nested fallbacks keep their own optional identity.
        if (resolved_val.object.get("revision") == null) parsed_resolved.revision = revision;
        if (resolved_val.object.get("rebuild") == null) parsed_resolved.rebuild = rebuild;
        resolved = parsed_resolved;
    }

    return .{
        .token = token,
        .name = name,
        .desc = desc,
        .homepage = homepage,
        .auto_updates = auto_updates,
        .revision = revision,
        .rebuild = rebuild,
        .kind = kind,
        .upstream = upstream,
        .dependencies = dependencies,
        .build_dependencies = build_dependencies,
        .assets = assets,
        .artifacts = artifacts,
        .resolved = resolved,
        .verification = verification,
    };
}

fn parseUpstream(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Upstream {
    const upstream_type = try parseUpstreamType(getString(obj, "type") orelse return error.MissingField);
    const verified = getBool(obj, "verified") orelse return error.MissingField;
    if (!verified) return error.UnverifiedUpstream;

    const repo = try dupOptionalString(alloc, obj, "repo");
    errdefer alloc.free(repo);
    const homepage = try dupOptionalString(alloc, obj, "homepage");
    errdefer alloc.free(homepage);
    const release_feed = try dupOptionalString(alloc, obj, "release_feed");
    errdefer alloc.free(release_feed);
    const allow_domains = try parseOptionalStringArray(alloc, obj, "allow_domains");
    errdefer {
        for (allow_domains) |domain| alloc.free(domain);
        alloc.free(allow_domains);
    }

    switch (upstream_type) {
        .github_release => {
            if (repo.len == 0) return error.MissingUpstreamAllowlist;
        },
        .vendor_url => {
            if (allow_domains.len == 0) return error.MissingUpstreamAllowlist;
        },
        .homebrew_bottle => {},
    }

    return .{
        .type = upstream_type,
        .repo = repo,
        .homepage = homepage,
        .release_feed = release_feed,
        .allow_domains = allow_domains,
        .verified = verified,
    };
}

fn parseAssets(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]AssetRule {
    var assets: std.ArrayList(AssetRule) = .empty;
    defer assets.deinit(alloc);
    errdefer for (assets.items) |asset| asset.deinit(alloc);

    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidField;
        const platform = try parsePlatform(entry.key_ptr.*);
        const pattern = try dupRequiredString(alloc, entry.value_ptr.*.object, "pattern");
        errdefer alloc.free(pattern);
        const strip_components = if (entry.value_ptr.*.object.get("strip_components")) |v|
            parseU32(v) orelse return error.InvalidField
        else
            0;

        try assets.append(alloc, .{
            .platform = platform,
            .pattern = pattern,
            .strip_components = strip_components,
        });
    }

    return assets.toOwnedSlice(alloc);
}

fn parseArtifacts(alloc: std.mem.Allocator, items: []const std.json.Value) ![]ArtifactRule {
    var artifacts: std.ArrayList(ArtifactRule) = .empty;
    defer artifacts.deinit(alloc);
    errdefer for (artifacts.items) |artifact| artifact.deinit(alloc);

    for (items) |item| {
        if (item != .object) return error.InvalidField;
        const artifact_type = try parseArtifactKind(getString(item.object, "type") orelse return error.MissingField);
        const path = try dupRequiredString(alloc, item.object, "path");
        errdefer alloc.free(path);
        const target = try dupOptionalString(alloc, item.object, "target");
        errdefer alloc.free(target);
        const args = try parseOptionalStringArray(alloc, item.object, "args");
        errdefer {
            for (args) |arg| alloc.free(arg);
            alloc.free(args);
        }
        try artifacts.append(alloc, .{ .type = artifact_type, .path = path, .target = target, .args = args });
    }

    return artifacts.toOwnedSlice(alloc);
}

fn parseResolved(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !Resolved {
    const tag = try dupOptionalString(alloc, obj, "tag");
    errdefer alloc.free(tag);
    const version = try dupRequiredString(alloc, obj, "version");
    errdefer alloc.free(version);
    const revision = if (obj.get("revision")) |v| parseU32(v) orelse return error.InvalidField else 0;
    const rebuild = if (obj.get("rebuild")) |v| parseU32(v) orelse return error.InvalidField else 0;

    const assets_val = obj.get("assets") orelse return error.MissingField;
    if (assets_val != .object) return error.InvalidField;

    var assets: std.ArrayList(ResolvedAsset) = .empty;
    defer assets.deinit(alloc);
    errdefer for (assets.items) |asset| asset.deinit(alloc);

    var it = assets_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidField;
        const platform = try parsePlatform(entry.key_ptr.*);
        const url = try dupRequiredString(alloc, entry.value_ptr.*.object, "url");
        errdefer alloc.free(url);
        const sha256 = try dupRequiredString(alloc, entry.value_ptr.*.object, "sha256");
        errdefer alloc.free(sha256);
        if (!isSha256Hex(sha256) and !std.mem.eql(u8, sha256, "no_check")) return error.InvalidField;
        const artifact_rules = if (entry.value_ptr.*.object.get("artifacts")) |artifacts_val| blk: {
            if (artifacts_val != .array) return error.InvalidField;
            break :blk try parseArtifacts(alloc, artifacts_val.array.items);
        } else try alloc.alloc(ArtifactRule, 0);
        errdefer {
            for (artifact_rules) |artifact| artifact.deinit(alloc);
            alloc.free(artifact_rules);
        }
        try assets.append(alloc, .{
            .platform = platform,
            .url = url,
            .sha256 = sha256,
            .artifacts = artifact_rules,
        });
    }
    if (assets.items.len == 0) return error.MissingAssets;

    const security_warnings = try parseSecurityWarnings(alloc, obj);
    errdefer freeSecurityWarnings(alloc, security_warnings);

    var revoked: ?Revoked = null;
    errdefer if (revoked) |r| r.deinit(alloc);
    if (obj.get("revoked")) |revoked_val| {
        if (revoked_val != .object) return error.InvalidField;
        const advisory = try dupOptionalString(alloc, revoked_val.object, "advisory");
        errdefer alloc.free(advisory);
        const reason = try dupOptionalString(alloc, revoked_val.object, "reason");
        errdefer alloc.free(reason);
        if (advisory.len == 0 and reason.len == 0) return error.InvalidField;
        revoked = .{ .advisory = advisory, .reason = reason };
    }

    var fallback: ?*Resolved = null;
    errdefer if (fallback) |f| {
        f.deinit(alloc);
        alloc.destroy(f);
    };
    if (obj.get("fallback")) |fallback_val| {
        if (fallback_val != .object) return error.InvalidField;
        const inner = try parseResolved(alloc, fallback_val.object);
        errdefer inner.deinit(alloc);
        const boxed = try alloc.create(Resolved);
        boxed.* = inner;
        fallback = boxed;
    }

    return .{
        .tag = tag,
        .version = version,
        .revision = revision,
        .rebuild = rebuild,
        .assets = try assets.toOwnedSlice(alloc),
        .security_warnings = security_warnings,
        .revoked = revoked,
        .fallback = fallback,
    };
}

fn parseSecurityWarnings(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]SecurityWarning {
    const warnings_val = obj.get("security_warnings") orelse return alloc.alloc(SecurityWarning, 0);
    if (warnings_val != .array) return error.InvalidField;

    var warnings: std.ArrayList(SecurityWarning) = .empty;
    defer warnings.deinit(alloc);
    errdefer for (warnings.items) |warning| warning.deinit(alloc);

    for (warnings_val.array.items) |item| {
        if (item != .object) return error.InvalidField;
        const ghsa_id = try dupOptionalString(alloc, item.object, "ghsa_id");
        errdefer alloc.free(ghsa_id);
        const cve_id = try dupOptionalString(alloc, item.object, "cve_id");
        errdefer alloc.free(cve_id);
        const severity = try dupOptionalString(alloc, item.object, "severity");
        errdefer alloc.free(severity);
        const summary = try dupRequiredString(alloc, item.object, "summary");
        errdefer alloc.free(summary);
        const url = try dupOptionalString(alloc, item.object, "url");
        errdefer alloc.free(url);
        const affected_versions = try dupOptionalString(alloc, item.object, "affected_versions");
        errdefer alloc.free(affected_versions);
        const patched_versions = try dupOptionalString(alloc, item.object, "patched_versions");
        errdefer alloc.free(patched_versions);

        if (ghsa_id.len == 0 and cve_id.len == 0) return error.InvalidField;

        try warnings.append(alloc, .{
            .ghsa_id = ghsa_id,
            .cve_id = cve_id,
            .severity = severity,
            .summary = summary,
            .url = url,
            .affected_versions = affected_versions,
            .patched_versions = patched_versions,
        });
    }

    return warnings.toOwnedSlice(alloc);
}

fn parseVerification(alloc: std.mem.Allocator, kind: Kind, obj: std.json.ObjectMap) !Verification {
    const sha256 = try parseSha256Mode(getString(obj, "sha256") orelse return error.MissingField);
    const signature = if (getString(obj, "signature")) |v| try parseRequirementMode(v) else .none;
    const attestation = if (getString(obj, "attestation")) |v| try parseRequirementMode(v) else .none;
    const no_check_reason = try dupOptionalString(alloc, obj, "no_check_reason");
    errdefer alloc.free(no_check_reason);

    if (kind == .formula and sha256 == .no_check and signature != .required and attestation != .required) {
        return error.InvalidFormulaVerification;
    }
    if (sha256 == .no_check and no_check_reason.len == 0) {
        return error.MissingNoCheckReason;
    }

    return .{
        .sha256 = sha256,
        .signature = signature,
        .attestation = attestation,
        .no_check_reason = no_check_reason,
    };
}

fn freeAssets(alloc: std.mem.Allocator, assets: []const AssetRule) void {
    for (assets) |asset| asset.deinit(alloc);
    alloc.free(assets);
}

fn freeArtifacts(alloc: std.mem.Allocator, artifacts: []const ArtifactRule) void {
    for (artifacts) |artifact| artifact.deinit(alloc);
    alloc.free(artifacts);
}

fn freeResolvedAssets(alloc: std.mem.Allocator, assets: []const ResolvedAsset) void {
    for (assets) |asset| asset.deinit(alloc);
    alloc.free(assets);
}

fn freeSecurityWarnings(alloc: std.mem.Allocator, warnings: []const SecurityWarning) void {
    for (warnings) |warning| warning.deinit(alloc);
    alloc.free(warnings);
}

fn parseKind(value: []const u8) !Kind {
    if (std.mem.eql(u8, value, "formula")) return .formula;
    if (std.mem.eql(u8, value, "cask")) return .cask;
    return error.UnsupportedKind;
}

fn parseUpstreamType(value: []const u8) !UpstreamType {
    if (std.mem.eql(u8, value, "github_release")) return .github_release;
    if (std.mem.eql(u8, value, "vendor_url")) return .vendor_url;
    if (std.mem.eql(u8, value, "homebrew_bottle")) return .homebrew_bottle;
    return error.UnsupportedUpstreamType;
}

fn parsePlatform(value: []const u8) !Platform {
    if (std.mem.eql(u8, value, "macos-arm64")) return .macos_arm64;
    if (std.mem.eql(u8, value, "macos-x86_64")) return .macos_x86_64;
    if (std.mem.eql(u8, value, "linux-x86_64")) return .linux_x86_64;
    if (std.mem.eql(u8, value, "linux-aarch64")) return .linux_aarch64;
    return error.UnsupportedPlatform;
}

fn parseArtifactKind(value: []const u8) !ArtifactKind {
    if (std.mem.eql(u8, value, "app")) return .app;
    if (std.mem.eql(u8, value, "pkg")) return .pkg;
    if (std.mem.eql(u8, value, "binary")) return .binary;
    if (std.mem.eql(u8, value, "font")) return .font;
    if (std.mem.eql(u8, value, "artifact")) return .artifact;
    if (std.mem.eql(u8, value, "suite")) return .suite;
    if (std.mem.eql(u8, value, "installer_script")) return .installer_script;
    return error.UnsupportedArtifactType;
}

fn parseSha256Mode(value: []const u8) !Sha256Mode {
    if (std.mem.eql(u8, value, "asset_or_sidecar")) return .asset_or_sidecar;
    if (std.mem.eql(u8, value, "asset_digest")) return .asset_digest;
    if (std.mem.eql(u8, value, "required")) return .required;
    if (std.mem.eql(u8, value, "required_or_no_check_with_reason")) return .required_or_no_check_with_reason;
    if (std.mem.eql(u8, value, "no_check")) return .no_check;
    return error.UnsupportedVerificationMode;
}

fn parseRequirementMode(value: []const u8) !RequirementMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "optional")) return .optional;
    if (std.mem.eql(u8, value, "required")) return .required;
    return error.UnsupportedVerificationMode;
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

fn parseU32(value: std.json.Value) ?u32 {
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |value| {
        if (value == .bool) return value.bool;
    }
    return null;
}

fn dupRequiredString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return alloc.dupe(u8, getString(obj, key) orelse return error.MissingField);
}

fn dupOptionalString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return alloc.dupe(u8, getString(obj, key) orelse "");
}

fn parseOptionalStringArray(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return alloc.alloc([]const u8, 0);
    if (value != .array) return error.InvalidField;

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    errdefer {
        for (out.items) |item| alloc.free(item);
    }

    for (value.array.items) |item| {
        if (item != .string) return error.InvalidField;
        try out.append(alloc, try alloc.dupe(u8, item.string));
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

fn writeTempCacheFile(tmp_dir: *testing.TmpDir, name: []const u8, data: []const u8) ![]u8 {
    var file = try tmp_dir.dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, data);
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path[0..], name });
}

test "loadRegistryWithOptions uses valid local cache registry" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cache-only",
        \\    "name": "Cache Only",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/cache-only",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "CacheOnly-{version}.zip" },
        \\      "macos-x86_64": { "pattern": "CacheOnly-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "CacheOnly.app" }
        \\    ],
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const cache_path = try writeTempCacheFile(&tmp_dir, "upstream.json", json);
    defer testing.allocator.free(cache_path);

    const registry = try loadRegistryWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = false,
    });
    defer registry.deinit(testing.allocator);

    try testing.expect(registry.find("cache-only", .cask) != null);
    try testing.expect(registry.find("alt-tab", .cask) == null);
}

test "loadRegistryWithOptions falls back to embedded registry when cache is invalid" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cache_path = try writeTempCacheFile(&tmp_dir, "upstream.json", "{ invalid json");
    defer testing.allocator.free(cache_path);

    const registry = try loadRegistryWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = false,
    });
    defer registry.deinit(testing.allocator);

    try testing.expect(registry.find("alt-tab", .cask) != null);
    try testing.expect(registry.find("cache-only", .cask) == null);
}

test "loadRecordWithOptions fresh-cache miss skips remote and still unions embedded registry" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Fresh cache that does NOT contain 'gh'. The remote URL points at a
    // closed local port so an (incorrect) remote attempt can never succeed;
    // with the fresh-cache-miss short-circuit it isn't attempted at all.
    const json =
        \\{ "schema_version": 1, "records": [] }
    ;
    const cache_path = try writeTempCacheFile(&tmp_dir, "upstream.json", json);
    defer testing.allocator.free(cache_path);

    // 'gh' is in the embedded default registry — a fresh-cache miss must
    // still fall through to it.
    const record = try loadRecordWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = true,
        .remote_url = "http://127.0.0.1:1/upstream.json",
    }, "gh", .formula);
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings("gh", record.token);

    // A token in neither the fresh cache nor the embedded registry is a
    // clean miss — no remote refetch within the TTL.
    try testing.expectError(error.UpstreamRecordNotFound, loadRecordWithOptions(testing.allocator, .{
        .cache_path = cache_path,
        .allow_remote = true,
        .remote_url = "http://127.0.0.1:1/upstream.json",
    }, "definitely-not-a-real-token", .formula));
}

test "parseRegistry parses default registry file" {
    const registry = try parseRegistry(testing.allocator, DEFAULT_REGISTRY_JSON);
    defer registry.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), registry.schema_version);
    try testing.expect(registry.find("alt-tab", .cask) != null);
    const gh = registry.find("gh", .formula) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(usize, 1), gh.artifacts.len);
    try testing.expectEqual(ArtifactKind.binary, gh.artifacts[0].type);
    try testing.expectEqualStrings("bin/gh", gh.artifacts[0].path);
}

fn parseRegistryAllocationProbe(alloc: std.mem.Allocator) !void {
    const json =
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
        \\    "resolved": {
        \\      "tag": "v10.12.0",
        \\      "version": "10.12.0",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip",
        \\          "sha256": "e7aea75cf1dd30dba6b5a9ef50da03f389bc5db74089e67af9112938a4192c14"
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;

    const registry = try parseRegistry(alloc, json);
    defer registry.deinit(alloc);
}

test "parseRegistry handles allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, parseRegistryAllocationProbe, .{});
}

test "parseRegistry parses formula asset rules" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "ripgrep",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "BurntSushi/ripgrep",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": {
        \\        "pattern": "ripgrep-{version}-aarch64-apple-darwin.tar.gz",
        \\        "strip_components": 1
        \\      },
        \\      "linux-x86_64": {
        \\        "pattern": "ripgrep-{version}-x86_64-unknown-linux-musl.tar.gz"
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "asset_or_sidecar",
        \\      "signature": "optional",
        \\      "attestation": "optional"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), registry.records.len);
    const record = registry.find("ripgrep", .formula).?;
    try testing.expectEqual(Kind.formula, record.kind);
    try testing.expectEqual(UpstreamType.github_release, record.upstream.type);
    try testing.expectEqualStrings("BurntSushi/ripgrep", record.upstream.repo);
    try testing.expectEqual(@as(usize, 2), record.assets.len);
    try testing.expectEqual(Platform.macos_arm64, record.assets[0].platform);
    try testing.expectEqualStrings("ripgrep-{version}-aarch64-apple-darwin.tar.gz", record.assets[0].pattern);
    try testing.expectEqual(@as(u32, 1), record.assets[0].strip_components);
    try testing.expectEqual(Sha256Mode.asset_or_sidecar, record.verification.sha256);
}

test "parseRegistry parses Homebrew bottle formula locks" {
    const json =
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
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "required"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const record = registry.find("cmake", .formula).?;
    try testing.expectEqual(UpstreamType.homebrew_bottle, record.upstream.type);
    try testing.expectEqual(@as(u32, 1), record.revision);
    try testing.expectEqual(@as(u32, 2), record.rebuild);
    try testing.expectEqual(@as(usize, 1), record.dependencies.len);
    try testing.expectEqualStrings("openssl@3", record.dependencies[0]);
    try testing.expectEqual(@as(usize, 1), record.build_dependencies.len);
    try testing.expectEqualStrings("pkgconf", record.build_dependencies[0]);
    try testing.expectEqual(@as(usize, 0), record.assets.len);
    try testing.expect(record.resolved != null);
    try testing.expectEqualStrings("4.3.2", record.resolved.?.version);
    try testing.expectEqual(@as(u32, 1), record.resolved.?.revision);
    try testing.expectEqual(@as(u32, 2), record.resolved.?.rebuild);
}

test "parseRecordFromRegistryJson extracts a single matching record" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "shared",
        \\    "name": "Shared App",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "vendor_url",
        \\      "allow_domains": ["example.test"],
        \\      "verified": true
        \\    },
        \\    "artifacts": [{ "type": "app", "path": "Shared.app" }],
        \\    "resolved": {
        \\      "version": "1.0.0",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://example.test/shared.dmg",
        \\          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\        }
        \\      }
        \\    },
        \\    "verification": { "sha256": "required" }
        \\  }, {
        \\    "token": "shared",
        \\    "name": "shared",
        \\    "kind": "formula",
        \\    "homepage": "https://example.test/shared",
        \\    "desc": "Shared formula",
        \\    "upstream": {
        \\      "type": "homebrew_bottle",
        \\      "verified": true
        \\    },
        \\    "resolved": {
        \\      "version": "2.0.0",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://ghcr.io/v2/homebrew/core/shared/blobs/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\        }
        \\      }
        \\    },
        \\    "verification": { "sha256": "required" }
        \\  }]
        \\}
    ;

    const record = try parseRecordFromRegistryJson(testing.allocator, json, "shared", .formula);
    defer record.deinit(testing.allocator);

    try testing.expectEqual(Kind.formula, record.kind);
    try testing.expectEqual(UpstreamType.homebrew_bottle, record.upstream.type);
    try testing.expectEqualStrings("2.0.0", record.resolved.?.version);
}

test "parseRegistry parses cask artifacts and vendor allowlist" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "raycast",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "vendor_url",
        \\      "homepage": "https://www.raycast.com/",
        \\      "release_feed": "https://releases.raycast.com/releases/latest/download?build={arch}",
        \\      "allow_domains": ["releases.raycast.com"],
        \\      "verified": true
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "Raycast.app" },
        \\      { "type": "binary", "path": "$APPDIR/Raycast.app/Contents/MacOS/raycast", "target": "raycast" }
        \\    ],
        \\    "resolved": {
        \\      "version": "1.2.3",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://releases.raycast.com/releases/1.2.3/Raycast.dmg",
        \\          "sha256": "no_check"
        \\        }
        \\      }
        \\    },
        \\    "verification": {
        \\      "sha256": "required_or_no_check_with_reason"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const record = registry.find("raycast", .cask).?;
    try testing.expectEqual(Kind.cask, record.kind);
    try testing.expectEqual(UpstreamType.vendor_url, record.upstream.type);
    try testing.expectEqualStrings("releases.raycast.com", record.upstream.allow_domains[0]);
    try testing.expectEqual(@as(usize, 2), record.artifacts.len);
    try testing.expectEqual(ArtifactKind.app, record.artifacts[0].type);
    try testing.expectEqualStrings("Raycast.app", record.artifacts[0].path);
    try testing.expectEqualStrings("", record.artifacts[0].target);
    try testing.expectEqual(ArtifactKind.binary, record.artifacts[1].type);
    try testing.expectEqualStrings("$APPDIR/Raycast.app/Contents/MacOS/raycast", record.artifacts[1].path);
    try testing.expectEqualStrings("raycast", record.artifacts[1].target);
    try testing.expect(record.resolved != null);
    try testing.expectEqualStrings("no_check", record.resolved.?.assets[0].sha256);
}

test "parseRegistry parses resolved security warnings" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "app-with-advisory",
        \\    "name": "App With Advisory",
        \\    "kind": "cask",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/app-with-advisory",
        \\      "verified": true
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "App-{version}.zip" }
        \\    },
        \\    "artifacts": [
        \\      { "type": "app", "path": "App.app" }
        \\    ],
        \\    "resolved": {
        \\      "tag": "v1.2.3",
        \\      "version": "1.2.3",
        \\      "assets": {
        \\        "macos-arm64": {
        \\          "url": "https://github.com/owner/app-with-advisory/releases/download/v1.2.3/App-1.2.3.zip",
        \\          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\        }
        \\      },
        \\      "security_warnings": [{
        \\        "ghsa_id": "GHSA-xxxx-yyyy-zzzz",
        \\        "cve_id": "CVE-2026-0001",
        \\        "severity": "high",
        \\        "summary": "Example advisory affecting old releases",
        \\        "url": "https://github.com/owner/app-with-advisory/security/advisories/GHSA-xxxx-yyyy-zzzz",
        \\        "affected_versions": "< 1.2.4",
        \\        "patched_versions": ">= 1.2.4"
        \\      }]
        \\    },
        \\    "verification": {
        \\      "sha256": "asset_digest"
        \\    }
        \\  }]
        \\}
    ;
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const record = registry.find("app-with-advisory", .cask).?;
    const warning = record.resolved.?.security_warnings[0];
    try testing.expectEqualStrings("GHSA-xxxx-yyyy-zzzz", warning.ghsa_id);
    try testing.expectEqualStrings("CVE-2026-0001", warning.cve_id);
    try testing.expectEqualStrings("high", warning.severity);
    try testing.expectEqualStrings("< 1.2.4", warning.affected_versions);
    try testing.expectEqualStrings(">= 1.2.4", warning.patched_versions);
}

test "parseRegistry parses revoked pin with fallback" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "cvetool",
        \\    "name": "cvetool",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "homebrew_bottle",
        \\      "verified": true
        \\    },
        \\    "resolved": {
        \\      "version": "2.0.0",
        \\      "assets": {
        \\        "linux-x86_64": {
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
        \\          "linux-x86_64": {
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
    const registry = try parseRegistry(testing.allocator, json);
    defer registry.deinit(testing.allocator);

    const resolved = &registry.find("cvetool", .formula).?.resolved.?;
    try testing.expectEqualStrings("CVE-2026-9999", resolved.revoked.?.advisory);
    try testing.expectEqualStrings("RCE in archive handling", resolved.revoked.?.reason);
    try testing.expectEqualStrings("1.9.0", resolved.fallback.?.version);

    const safe = resolved.effective().?;
    try testing.expectEqualStrings("1.9.0", safe.version);

    // A revoked pin without a fallback must not resolve to anything.
    var no_fallback = resolved.*;
    no_fallback.fallback = null;
    try testing.expect(no_fallback.effective() == null);
}

test "parseRegistry rejects unverified upstreams" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "unsafe",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/unsafe",
        \\      "verified": false
        \\    },
        \\    "assets": {
        \\      "macos-arm64": { "pattern": "unsafe-{version}.tar.gz" }
        \\    },
        \\    "verification": { "sha256": "asset_or_sidecar" }
        \\  }]
        \\}
    ;
    try testing.expectError(error.UnverifiedUpstream, parseRegistry(testing.allocator, json));
}

test "parseRegistry rejects formula records without assets" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "records": [{
        \\    "token": "empty",
        \\    "kind": "formula",
        \\    "upstream": {
        \\      "type": "github_release",
        \\      "repo": "owner/empty",
        \\      "verified": true
        \\    },
        \\    "assets": {},
        \\    "verification": { "sha256": "asset_or_sidecar" }
        \\  }]
        \\}
    ;
    try testing.expectError(error.MissingAssets, parseRegistry(testing.allocator, json));
}
