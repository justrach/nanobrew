// nanobrew — APT sources discovery
//
// Parses the user's actual APT configuration so that `nb install --deb`
// behaves like `apt` would on the same machine instead of pretending every
// Linux box is stock Ubuntu/Debian.
//
// We honour:
//   * /etc/apt/sources.list                  (legacy one-line format)
//   * /etc/apt/sources.list.d/*.list         (legacy one-line format)
//   * /etc/apt/sources.list.d/*.sources      (deb822 multi-line format)
//
// Pin priorities in /etc/apt/preferences[.d/*] are *not* parsed yet — when
// the same package appears in multiple sources, deb/index.zig `buildIndex`
// picks the newest version (apt's rule when every source has the default
// priority) and, on a tie, the first source listed. Pin-priority handling is
// a follow-up.

const std = @import("std");
const builtin = @import("builtin");

/// A single APT repository row, normalized to one (uri, suite, components)
/// triple so callers can iterate and fetch indices without re-implementing
/// the cartesian product of deb822 stanzas.
pub const Repository = struct {
    /// e.g. "http://archive.ubuntu.com/ubuntu"
    uri: []const u8,
    /// e.g. "noble", "bookworm", "noble-updates"
    suite: []const u8,
    /// e.g. ["main", "universe"]
    components: []const []const u8,
    /// Architectures this row applies to. Empty = applies to all.
    architectures: []const []const u8,
    /// Source file the row came from (for diagnostics / `nb deb sources`).
    origin: []const u8,
};

pub const Sources = struct {
    repositories: []Repository,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Sources) void {
        self.arena.deinit();
    }
};

/// Discover all enabled `deb` repositories on the system. Returns an empty
/// list (not an error) on non-Linux, on systems with no sources, or on parse
/// failure — callers fall back to the hardcoded distro defaults in that
/// case.
pub fn discover(parent_alloc: std.mem.Allocator) !Sources {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var repos: std.ArrayList(Repository) = .empty;

    if (comptime builtin.os.tag != .linux) {
        return .{
            .repositories = try repos.toOwnedSlice(a),
            .arena = arena,
        };
    }

    // Top-level /etc/apt/sources.list (legacy one-line format).
    parseLegacyFile(a, &repos, "/etc/apt/sources.list") catch {};

    // /etc/apt/sources.list.d/*.list (legacy) and *.sources (deb822).
    if (openIterableDir("/etc/apt/sources.list.d")) |dir_holder| {
        var holder = dir_holder;
        defer holder.close();
        var it = holder.dir.iterate();
        while (it.next(io()) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".list")) {
                var path_buf: [256]u8 = undefined;
                const p = std.fmt.bufPrint(&path_buf, "/etc/apt/sources.list.d/{s}", .{entry.name}) catch continue;
                parseLegacyFile(a, &repos, p) catch {};
            } else if (std.mem.endsWith(u8, entry.name, ".sources")) {
                var path_buf: [256]u8 = undefined;
                const p = std.fmt.bufPrint(&path_buf, "/etc/apt/sources.list.d/{s}", .{entry.name}) catch continue;
                parseDeb822File(a, &repos, p) catch {};
            }
        }
    }

    return .{
        .repositories = try repos.toOwnedSlice(a),
        .arena = arena,
    };
}

// ── legacy one-line format ──────────────────────────────────────────────────
//
// Each non-blank, non-comment line:
//
//   deb [opt1=val1 opt2=val2] http://uri suite comp1 comp2 ...
//
// We only ingest type `deb` (binary packages) and ignore `deb-src`. The
// optional `[...]` block carries options including `arch=` (which we honour
// as the architectures filter) and `signed-by=` (which we ignore — we trust
// HTTPS instead of the apt keyring for now).

fn parseLegacyFile(
    a: std.mem.Allocator,
    repos: *std.ArrayList(Repository),
    path: []const u8,
) !void {
    const data = readFileAll(a, path) catch return;
    defer a.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        try parseLegacyLine(a, repos, line, path);
    }
}

fn parseLegacyLine(
    a: std.mem.Allocator,
    repos: *std.ArrayList(Repository),
    line: []const u8,
    origin: []const u8,
) !void {
    // First token is the type: "deb" / "deb-src".
    var rest = line;
    const kind = nextToken(&rest) orelse return;
    if (!std.mem.eql(u8, kind, "deb")) return;

    var arch_list: std.ArrayList([]const u8) = .empty;

    // Optional [option=value option=value] block.
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return;
        const opts = rest[1..close];
        rest = rest[close + 1 ..];

        var opts_iter = std.mem.tokenizeScalar(u8, opts, ' ');
        while (opts_iter.next()) |opt| {
            const eq = std.mem.indexOfScalar(u8, opt, '=') orelse continue;
            const key = opt[0..eq];
            const val = opt[eq + 1 ..];
            if (std.mem.eql(u8, key, "arch")) {
                var av = std.mem.tokenizeScalar(u8, val, ',');
                while (av.next()) |arch| try arch_list.append(a, try a.dupe(u8, arch));
            }
            // signed-by, trusted, etc. — ignored.
        }
    }

    const uri = nextToken(&rest) orelse return;
    const suite = nextToken(&rest) orelse return;

    var comps: std.ArrayList([]const u8) = .empty;
    while (nextToken(&rest)) |c| try comps.append(a, try a.dupe(u8, c));
    if (comps.items.len == 0) return; // suite without components — unusual; skip.

    try repos.append(a, .{
        .uri = trimTrailingSlash(try a.dupe(u8, uri)),
        .suite = try a.dupe(u8, suite),
        .components = try comps.toOwnedSlice(a),
        .architectures = try arch_list.toOwnedSlice(a),
        .origin = try a.dupe(u8, origin),
    });
}

fn nextToken(rest: *[]const u8) ?[]const u8 {
    rest.* = std.mem.trimStart(u8, rest.*, " \t");
    if (rest.len == 0) return null;
    const end = std.mem.indexOfAny(u8, rest.*, " \t") orelse rest.len;
    const tok = rest.*[0..end];
    rest.* = rest.*[end..];
    return tok;
}

// ── deb822 format ──────────────────────────────────────────────────────────
//
// Stanzas separated by blank lines; each stanza is a set of multi-line
// fields. We care about Types, URIs, Suites, Components, Architectures,
// Enabled. Continuation lines start with whitespace and accumulate.

fn parseDeb822File(
    a: std.mem.Allocator,
    repos: *std.ArrayList(Repository),
    path: []const u8,
) !void {
    const data = readFileAll(a, path) catch return;
    defer a.free(data);

    var stanza_start: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        // Find a blank line that terminates a stanza, or EOF.
        if (data[i] == '\n') {
            // Detect blank line: either current is "\n\n" or this newline
            // ends the file.
            const next_is_blank = (i + 1 < data.len and (data[i + 1] == '\n' or data[i + 1] == '\r'));
            if (next_is_blank or i + 1 >= data.len) {
                const stanza = data[stanza_start..i];
                if (stanza.len > 0) try parseDeb822Stanza(a, repos, stanza, path);
                stanza_start = i + 1;
            }
        }
        i += 1;
    }
    if (stanza_start < data.len) {
        const stanza = data[stanza_start..data.len];
        if (stanza.len > 0) try parseDeb822Stanza(a, repos, stanza, path);
    }
}

fn parseDeb822Stanza(
    a: std.mem.Allocator,
    repos: *std.ArrayList(Repository),
    stanza: []const u8,
    origin: []const u8,
) !void {
    var types: ?[]const u8 = null;
    var uris: ?[]const u8 = null;
    var suites: ?[]const u8 = null;
    var components: ?[]const u8 = null;
    var architectures: ?[]const u8 = null;
    var enabled = true;

    var current_key: ?[]const u8 = null;
    var current_val: std.ArrayList(u8) = .empty;
    defer current_val.deinit(a);

    var lines = std.mem.splitScalar(u8, stanza, '\n');
    while (lines.next()) |raw_with_cr| {
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        if (raw.len == 0) {
            try flushDeb822Field(a, &current_key, &current_val, &types, &uris, &suites, &components, &architectures, &enabled);
            continue;
        }
        if (std.mem.startsWith(u8, raw, "#")) continue;

        if (raw[0] == ' ' or raw[0] == '\t') {
            // Continuation of the previous field.
            if (current_key != null) {
                try current_val.append(a, ' ');
                try current_val.appendSlice(a, std.mem.trim(u8, raw, " \t"));
            }
            continue;
        }

        // New field — flush previous.
        try flushDeb822Field(a, &current_key, &current_val, &types, &uris, &suites, &components, &architectures, &enabled);
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        current_key = std.mem.trim(u8, raw[0..colon], " \t");
        try current_val.appendSlice(a, std.mem.trim(u8, raw[colon + 1 ..], " \t"));
    }
    try flushDeb822Field(a, &current_key, &current_val, &types, &uris, &suites, &components, &architectures, &enabled);

    if (!enabled) return;

    const types_str = types orelse return;
    const uris_str = uris orelse return;
    const suites_str = suites orelse return;
    const comps_str = components orelse return;

    if (!whitespaceListContains(types_str, "deb")) return;

    const arch_slice: []const []const u8 = if (architectures) |a_str|
        try splitWhitespaceDup(a, a_str)
    else
        &.{};

    const comps_slice = try splitWhitespaceDup(a, comps_str);

    // Cartesian product over URIs × Suites.
    var uri_iter = std.mem.tokenizeAny(u8, uris_str, " \t");
    while (uri_iter.next()) |uri| {
        var suite_iter = std.mem.tokenizeAny(u8, suites_str, " \t");
        while (suite_iter.next()) |suite| {
            try repos.append(a, .{
                .uri = trimTrailingSlash(try a.dupe(u8, uri)),
                .suite = try a.dupe(u8, suite),
                .components = comps_slice,
                .architectures = arch_slice,
                .origin = try a.dupe(u8, origin),
            });
        }
    }
}

fn flushDeb822Field(
    a: std.mem.Allocator,
    current_key: *?[]const u8,
    current_val: *std.ArrayList(u8),
    types: *?[]const u8,
    uris: *?[]const u8,
    suites: *?[]const u8,
    components: *?[]const u8,
    architectures: *?[]const u8,
    enabled: *bool,
) !void {
    const key = current_key.* orelse return;
    const val = try a.dupe(u8, current_val.items);
    current_val.clearRetainingCapacity();
    current_key.* = null;

    if (eqi(key, "Types")) {
        types.* = val;
    } else if (eqi(key, "URIs")) {
        uris.* = val;
    } else if (eqi(key, "Suites")) {
        suites.* = val;
    } else if (eqi(key, "Components")) {
        components.* = val;
    } else if (eqi(key, "Architectures")) {
        architectures.* = val;
    } else if (eqi(key, "Enabled")) {
        enabled.* = !std.ascii.eqlIgnoreCase(val, "no");
    }
    // Signed-By, X-Repolib-Name, etc. — ignored.
}

// ── helpers ────────────────────────────────────────────────────────────────

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn whitespaceListContains(list: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, needle)) return true;
    }
    return false;
}

fn splitWhitespaceDup(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| try out.append(a, try a.dupe(u8, tok));
    return out.toOwnedSlice(a);
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return std.mem.trim(u8, line[0..i], " \t");
    return line;
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    var v = s;
    while (v.len > 0 and v[v.len - 1] == '/') v = v[0 .. v.len - 1];
    return v;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readFileAll(a: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    const f = try std.Io.Dir.openFileAbsolute(io(), abs_path, .{});
    defer f.close(io());
    const stat = try f.stat(io());
    const cap: usize = @intCast(stat.size);
    if (cap == 0) return try a.alloc(u8, 0);
    const buf = try a.alloc(u8, cap);
    var read: usize = 0;
    while (read < cap) {
        const n = try f.readPositional(io(), &.{buf[read..]}, @intCast(read));
        if (n == 0) break;
        read += n;
    }
    return buf[0..read];
}

const DirHolder = struct {
    dir: std.Io.Dir,
    pub fn close(self: *DirHolder) void {
        self.dir.close(io());
    }
};

fn openIterableDir(abs_path: []const u8) ?DirHolder {
    const d = std.Io.Dir.openDirAbsolute(io(), abs_path, .{ .iterate = true }) catch return null;
    return .{ .dir = d };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseLegacyLine: simple deb line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;

    try parseLegacyLine(a, &repos, "deb http://archive.ubuntu.com/ubuntu noble main universe", "test");
    try testing.expectEqual(@as(usize, 1), repos.items.len);
    const r = repos.items[0];
    try testing.expectEqualStrings("http://archive.ubuntu.com/ubuntu", r.uri);
    try testing.expectEqualStrings("noble", r.suite);
    try testing.expectEqual(@as(usize, 2), r.components.len);
    try testing.expectEqualStrings("main", r.components[0]);
    try testing.expectEqualStrings("universe", r.components[1]);
}

test "parseLegacyLine: arch + signed-by options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;

    try parseLegacyLine(
        a,
        &repos,
        "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/k.gpg] http://example.com/r bookworm main contrib",
        "test",
    );
    try testing.expectEqual(@as(usize, 1), repos.items.len);
    const r = repos.items[0];
    try testing.expectEqualStrings("http://example.com/r", r.uri);
    try testing.expectEqualStrings("bookworm", r.suite);
    try testing.expectEqual(@as(usize, 2), r.architectures.len);
    try testing.expectEqualStrings("amd64", r.architectures[0]);
    try testing.expectEqualStrings("arm64", r.architectures[1]);
}

test "parseLegacyLine: deb-src is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;
    try parseLegacyLine(a, &repos, "deb-src http://archive.ubuntu.com/ubuntu noble main", "test");
    try testing.expectEqual(@as(usize, 0), repos.items.len);
}

test "parseDeb822Stanza: full stanza with multiple URIs and Suites" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;

    const stanza =
        \\Types: deb deb-src
        \\URIs: http://archive.ubuntu.com/ubuntu http://security.ubuntu.com/ubuntu
        \\Suites: noble noble-updates
        \\Components: main universe
        \\Architectures: amd64
        \\Enabled: yes
    ;

    try parseDeb822Stanza(a, &repos, stanza, "test.sources");
    // 2 URIs × 2 Suites = 4 rows
    try testing.expectEqual(@as(usize, 4), repos.items.len);
    try testing.expectEqualStrings("http://archive.ubuntu.com/ubuntu", repos.items[0].uri);
    try testing.expectEqualStrings("noble", repos.items[0].suite);
    try testing.expectEqualStrings("http://security.ubuntu.com/ubuntu", repos.items[3].uri);
    try testing.expectEqualStrings("noble-updates", repos.items[3].suite);
}

test "parseDeb822Stanza: Enabled=no skips the stanza" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;

    const stanza =
        \\Types: deb
        \\URIs: http://example.com/r
        \\Suites: bookworm
        \\Components: main
        \\Enabled: no
    ;
    try parseDeb822Stanza(a, &repos, stanza, "test.sources");
    try testing.expectEqual(@as(usize, 0), repos.items.len);
}

test "parseDeb822Stanza: deb-only types are required" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repos: std.ArrayList(Repository) = .empty;

    const stanza =
        \\Types: deb-src
        \\URIs: http://example.com/r
        \\Suites: bookworm
        \\Components: main
    ;
    try parseDeb822Stanza(a, &repos, stanza, "test.sources");
    try testing.expectEqual(@as(usize, 0), repos.items.len);
}

test "parseLegacyFile via stripComment: end-of-line comment" {
    try testing.expectEqualStrings("deb http://x noble main", stripComment("deb http://x noble main # comment"));
    try testing.expectEqualStrings("", stripComment("# pure comment"));
    try testing.expectEqualStrings("deb http://x noble main", stripComment("deb http://x noble main"));
}
