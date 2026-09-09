// nanobrew — Homebrew tap formula/cask support
//
// Fetches and parses Ruby formula/cask files from third-party taps.
// Input: "user/tap/formula" (e.g. "steipete/tap/sag")
// Repo:  github.com/<user>/homebrew-<tap>/Formula/<name>.rb
//        github.com/<user>/homebrew-<tap>/Casks/<name>.rb

const std = @import("std");
const Formula = @import("formula.zig").Formula;
const BOTTLE_TAG = @import("formula.zig").BOTTLE_TAG;
const BOTTLE_FALLBACKS = @import("formula.zig").BOTTLE_FALLBACKS;
const Cask = @import("cask.zig").Cask;
const Artifact = @import("cask.zig").Artifact;
const fetch = @import("../net/fetch.zig");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Fetch a formula from a third-party tap.
/// name must be "user/tap/formula" format (exactly 2 slashes).
pub fn fetchTapFormula(alloc: std.mem.Allocator, client: ?*std.http.Client, name: []const u8) !Formula {
    const ref = parseTapRef(name) orelse return error.FormulaNotFound;

    const urls = try tapFormulaUrls(alloc, ref);
    defer for (urls) |u| alloc.free(u);

    var ruby_src: ?[]u8 = null;
    for (urls) |url| {
        ruby_src = if (client) |c|
            fetch.getWithClient(alloc, c, url) catch null
        else
            fetch.get(alloc, url) catch null;
        if (ruby_src != null) break;
    }

    const src = ruby_src orelse return error.FormulaNotFound;
    defer alloc.free(src);

    return parseRubyFormula(alloc, ref.formula, src);
}

/// Fetch a cask from a third-party tap.
/// name must be "user/tap/cask" format (exactly 2 slashes).
pub fn fetchTapCask(alloc: std.mem.Allocator, name: []const u8) !Cask {
    const ref = parseTapRef(name) orelse return error.CaskNotFound;

    const urls = try tapCaskUrls(alloc, ref);
    defer for (urls) |u| alloc.free(u);

    var ruby_src: ?[]u8 = null;
    for (urls) |url| {
        ruby_src = fetch.get(alloc, url) catch null;
        if (ruby_src != null) break;
    }

    const src = ruby_src orelse return error.CaskNotFound;
    defer alloc.free(src);

    return parseRubyCask(alloc, name, src);
}

/// Parse a Ruby cask file into a Cask struct.
/// Handles: version, sha256, url, name, desc, homepage, app, binary, pkg artifacts.
fn parseRubyCask(alloc: std.mem.Allocator, token: []const u8, src: []const u8) !Cask {
    var version: ?[]const u8 = null;
    var sha256: ?[]const u8 = null;
    var url_raw: ?[]const u8 = null;
    var cask_name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var homepage: ?[]const u8 = null;

    var artifacts: std.ArrayList(Artifact) = .empty;
    defer artifacts.deinit(alloc);

    var platform_skip: bool = false;
    var block_depth: u32 = 0;
    var platform_depth: u32 = 0;

    var line_iter = std.mem.splitScalar(u8, src, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (startsWith(line, "if Hardware::CPU.intel?")) {
            block_depth += 1;
            platform_depth = block_depth;
            platform_skip = (builtin.cpu.arch != .x86_64);
            continue;
        } else if (startsWith(line, "if Hardware::CPU.arm?")) {
            block_depth += 1;
            platform_depth = block_depth;
            platform_skip = (builtin.cpu.arch != .aarch64);
            continue;
        }

        if (std.mem.eql(u8, line, "else") and platform_depth > 0 and block_depth == platform_depth) {
            platform_skip = !platform_skip;
            if (!platform_skip) {
                url_raw = null;
                sha256 = null;
            }
            continue;
        }

        if (endsWith(line, " do") or std.mem.eql(u8, line, "do")) {
            block_depth += 1;

            if (startsWith(line, "on_macos")) {
                platform_depth = block_depth;
                platform_skip = !is_macos;
                continue;
            } else if (startsWith(line, "on_linux")) {
                platform_depth = block_depth;
                platform_skip = !is_linux;
                continue;
            } else if (startsWith(line, "on_arm")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .aarch64);
                continue;
            } else if (startsWith(line, "on_intel")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .x86_64);
                continue;
            }
        }

        if (std.mem.eql(u8, line, "end")) {
            if (block_depth == platform_depth and platform_depth > 0) {
                platform_skip = false;
                platform_depth = 0;
            }
            if (block_depth > 0) block_depth -= 1;
            continue;
        }

        if (platform_skip) continue;

        if (version == null) {
            if (extractQuotedAfter(line, "version ")) |v| {
                version = try allocDupe(alloc, v);
            } else if (extractSymbolAfter(line, "version ")) |v| {
                version = try allocDupe(alloc, v);
            }
        }
        if (sha256 == null) {
            if (extractQuotedAfter(line, "sha256 ")) |s| {
                sha256 = try allocDupe(alloc, s);
            } else if (std.mem.indexOf(u8, line, "sha256 :no_check") != null) {
                sha256 = try allocDupe(alloc, "no_check");
            }
        }
        if (url_raw == null) {
            if (extractQuotedAfter(line, "url ")) |u| {
                url_raw = try allocDupe(alloc, u);
            }
        }
        if (cask_name == null) {
            if (extractQuotedAfter(line, "name ")) |n| {
                cask_name = try allocDupe(alloc, n);
            }
        }
        if (desc == null) {
            if (extractQuotedAfter(line, "desc ")) |d| {
                desc = try allocDupe(alloc, d);
            }
        }
        if (homepage == null) {
            if (extractQuotedAfter(line, "homepage ")) |h| {
                homepage = try allocDupe(alloc, h);
            }
        }

        // Artifacts
        if (extractQuotedAfter(line, "app ")) |a| {
            try artifacts.append(alloc, .{ .app = try allocDupe(alloc, a) });
        }
        if (extractQuotedAfter(line, "pkg ")) |p| {
            try artifacts.append(alloc, .{ .pkg = try allocDupe(alloc, p) });
        }
        if (extractQuotedAfter(line, "binary ")) |b| {
            const target = if (extractQuotedAfter(line, "target: ")) |t|
                try allocDupe(alloc, t)
            else
                try allocDupe(alloc, std.fs.path.basename(b));
            try artifacts.append(alloc, .{ .binary = .{
                .source = try allocDupe(alloc, b),
                .target = target,
            } });
        }
    }

    const ver = version orelse return error.CaskNotFound;

    // Interpolate #{version} in URL
    const final_url = if (url_raw) |u|
        try interpolateVersion(alloc, u, ver)
    else
        return error.CaskNotFound;

    // Free the raw url since we have the interpolated one
    if (url_raw) |u| alloc.free(u);

    return Cask{
        .token = try allocDupe(alloc, token),
        .name = cask_name orelse try allocDupe(alloc, token),
        .version = ver,
        .url = final_url,
        .sha256 = sha256 orelse try allocDupe(alloc, "no_check"),
        .homepage = homepage orelse try allocDupe(alloc, ""),
        .desc = desc orelse try allocDupe(alloc, ""),
        .auto_updates = false,
        .artifacts = try artifacts.toOwnedSlice(alloc),
        .min_macos = null,
    };
}

fn allocDupe(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return @constCast(try alloc.dupe(u8, s));
}

fn extractSymbolAfter(line: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    var rest = std.mem.trimStart(u8, line[start + prefix.len ..], " \t");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = rest[1..];

    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) break;
    }
    if (end == 0) return null;
    return rest[0..end];
}

const TapRef = struct {
    user: []const u8,
    tap: []const u8,
    formula: []const u8,
};

fn tapFormulaUrls(alloc: std.mem.Allocator, ref: TapRef) ![3][]const u8 {
    return .{
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/{s}.rb", .{ ref.user, ref.tap, ref.formula }),
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Formula/{s}.rb", .{ ref.user, ref.tap, ref.formula }),
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Formula/{c}/{s}.rb", .{ ref.user, ref.tap, ref.formula[0], ref.formula }),
    };
}

fn tapCaskUrls(alloc: std.mem.Allocator, ref: TapRef) ![2][]const u8 {
    return .{
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Casks/{s}.rb", .{ ref.user, ref.tap, ref.formula }),
        try std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/{s}/homebrew-{s}/HEAD/Casks/{c}/{s}.rb", .{ ref.user, ref.tap, ref.formula[0], ref.formula }),
    };
}

pub fn parseTapRef(name: []const u8) ?TapRef {
    var slash1: ?usize = null;
    var slash2: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '/') {
            if (slash1 == null) {
                slash1 = i;
            } else if (slash2 == null) {
                slash2 = i;
            } else {
                return null; // more than 2 slashes
            }
        }
    }
    const s1 = slash1 orelse return null;
    const s2 = slash2 orelse return null;
    if (s1 == 0 or s2 == s1 + 1 or s2 == name.len - 1) return null;
    return .{
        .user = name[0..s1],
        .tap = name[s1 + 1 .. s2],
        .formula = name[s2 + 1 ..],
    };
}

/// Parse a Ruby formula file into a Formula struct.
/// Handles: version, desc, url, sha256, depends_on, on_macos/on_linux blocks,
/// bottle blocks with root_url and per-tag sha256.
pub fn parseRubyFormula(alloc: std.mem.Allocator, name: []const u8, src: []const u8) !Formula {
    var version: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var source_url: ?[]const u8 = null;
    var source_sha256: ?[]const u8 = null;
    var bottle_root_url: ?[]const u8 = null;
    var bottle_sha256: ?[]const u8 = null;
    var bottle_tag: []const u8 = BOTTLE_TAG;
    var bottle_rank: usize = std.math.maxInt(usize);

    var deps: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(alloc);
    var build_deps: std.ArrayList([]const u8) = .empty;
    defer build_deps.deinit(alloc);
    // Binaries declared via `def install / bin.install "name"`. Tap formulas
    // that ship prebuilt tarballs rely on Homebrew's Ruby install DSL to move
    // the executable from the tarball root into `bin/`. nanobrew does not
    // execute Ruby, so without this extraction the binary lands in the keg
    // root and is never symlinked into `prefix/bin`. See #286.
    var install_bins: std.ArrayList([]const u8) = .empty;
    defer install_bins.deinit(alloc);
    // Set when any bin.install/sbin.install argument is not a plain string
    // literal. Partial capture is worse than none: source.zig only runs the
    // generic whole-payload copy when install_binaries is empty.
    var bin_install_unparseable: bool = false;
    // `bin.install Dir["<glob>"].first => "<dest>"` captures (#361).
    var bin_renames: std.ArrayList(Formula.BinRename) = .empty;
    defer {
        for (bin_renames.items) |r| {
            alloc.free(r.pattern);
            alloc.free(r.dest);
        }
        bin_renames.deinit(alloc);
    }
    // `url ..., using: :nounzip` — raw file download, no extraction (#361).
    var source_nounzip: bool = false;

    // Track block nesting for on_macos/on_linux/bottle/test
    var in_bottle: bool = false;
    var platform_skip: bool = false;
    var block_depth: u32 = 0;
    var platform_depth: u32 = 0;
    // `test do ... end` blocks contain arbitrary Ruby (assert_match,
    // shell_output, etc.) and must not be parsed as formula metadata.
    // See the extractQuotedAfter docs for the concrete failure mode.
    var test_depth: u32 = 0;
    // `def install ... end` is a Ruby method, not a `do` block — track its
    // own nesting so a nested `do ... end` inside the body doesn't confuse
    // the outer block_depth counter.
    var in_install_method: bool = false;
    var install_inner_depth: u32 = 0;

    var line_iter = std.mem.splitScalar(u8, src, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        // --- def install body: capture bin.install targets, skip everything else ---
        if (in_install_method) {
            if (endsWith(line, " do") or std.mem.eql(u8, line, "do")) {
                install_inner_depth += 1;
                continue;
            }
            if (std.mem.eql(u8, line, "end")) {
                if (install_inner_depth > 0) {
                    install_inner_depth -= 1;
                } else {
                    in_install_method = false;
                }
                continue;
            }
            if (isBinInstallLine(line)) {
                switch (extractBinInstallNames(line)) {
                    .names => |names| for (names) |maybe_name| {
                        const bin_name = maybe_name orelse break;
                        try install_bins.append(alloc, try alloc.dupe(u8, bin_name));
                    },
                    .glob_rename => |gr| try bin_renames.append(alloc, .{
                        .pattern = try alloc.dupe(u8, gr.pattern),
                        .dest = try alloc.dupe(u8, gr.dest),
                    }),
                    .unparseable => bin_install_unparseable = true,
                    .none => {},
                }
            }
            continue;
        }

        // Detect opening of a `def install` method — Ruby methods don't use
        // `do`, so the existing block_depth counter doesn't cover them.
        if (startsWith(line, "def install")) {
            const after = line["def install".len..];
            const is_method = after.len == 0 or after[0] == ' ' or after[0] == '\t' or after[0] == '(';
            if (is_method) {
                in_install_method = true;
                install_inner_depth = 0;
                continue;
            }
        }

        // Handle Ruby if/else/end for Hardware::CPU conditionals (#68)
        if (startsWith(line, "if Hardware::CPU.intel?")) {
            block_depth += 1;
            platform_depth = block_depth;
            platform_skip = (builtin.cpu.arch != .x86_64);
            continue;
        } else if (startsWith(line, "if Hardware::CPU.arm?")) {
            block_depth += 1;
            platform_depth = block_depth;
            platform_skip = (builtin.cpu.arch != .aarch64);
            continue;
        }

        // Handle "else" — flip platform skip if we're inside a platform block
        if (std.mem.eql(u8, line, "else") and platform_depth > 0 and block_depth == platform_depth) {
            platform_skip = !platform_skip;
            // Reset url/sha256 so the else branch can set them
            if (!platform_skip) {
                source_url = null;
                source_sha256 = null;
            }
            continue;
        }

        // Track do...end block nesting
        if (endsWith(line, " do") or std.mem.eql(u8, line, "do")) {
            block_depth += 1;

            // Detect platform blocks
            if (startsWith(line, "on_macos")) {
                platform_depth = block_depth;
                platform_skip = !is_macos;
                continue;
            } else if (startsWith(line, "on_linux")) {
                platform_depth = block_depth;
                platform_skip = !is_linux;
                continue;
            } else if (startsWith(line, "on_arm")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .aarch64);
                continue;
            } else if (startsWith(line, "on_intel")) {
                platform_depth = block_depth;
                platform_skip = (builtin.cpu.arch != .x86_64);
                continue;
            }

            // Detect bottle block
            if (startsWith(line, "bottle")) {
                in_bottle = true;
                continue;
            }

            // Detect test block — skip its contents wholesale.
            if (startsWith(line, "test")) {
                test_depth = block_depth;
                continue;
            }
        }

        if (std.mem.eql(u8, line, "end")) {
            if (block_depth == platform_depth and platform_depth > 0) {
                platform_skip = false;
                platform_depth = 0;
            }
            if (in_bottle and block_depth > 0) {
                in_bottle = false;
            }
            if (test_depth > 0 and block_depth == test_depth) {
                test_depth = 0;
            }
            if (block_depth > 0) block_depth -= 1;
            continue;
        }

        // Skip lines inside test blocks — they contain arbitrary Ruby
        // (shell_output, assert_match, etc.) that must not be scanned
        // for `version`/`url`/`sha256`/`depends_on`.
        if (test_depth > 0) continue;

        // Skip lines inside wrong-platform blocks
        if (platform_skip) continue;

        // --- Inside bottle block ---
        if (in_bottle) {
            if (extractQuotedAfter(line, "root_url")) |val| {
                bottle_root_url = val;
            } else if (startsWith(line, "sha256")) {
                const tags = [_][]const u8{BOTTLE_TAG} ++ BOTTLE_FALLBACKS;
                for (tags, 0..) |tag, rank| {
                    if (rank < bottle_rank) {
                        if (findTagInLine(line, tag)) |val| {
                            bottle_sha256 = val;
                            bottle_tag = tag;
                            bottle_rank = rank;
                        }
                    }
                }
            }
            continue;
        }

        // Support literal VERSION constants without executing Ruby.
        if (version == null and std.mem.startsWith(u8, line, "VERSION =")) {
            version = extractQuotedAfter(line, "VERSION =");
        }
        // --- Top-level fields ---
        if (version == null) {
            if (extractQuotedAfter(line, "version")) |val| {
                version = val;
            }
        }
        if (desc == null) {
            if (extractQuotedAfter(line, "desc")) |val| {
                desc = val;
            }
        }
        if (source_url == null) {
            if (extractQuotedAfter(line, "url")) |val| {
                source_url = val;
            }
        }
        if (source_sha256 == null and !in_bottle) {
            if (extractQuotedAfter(line, "sha256")) |val| {
                source_sha256 = val;
            }
        }

        // depends_on
        if (startsWith(line, "depends_on")) {
            if (extractQuotedAfter(line, "depends_on")) |dep_name| {
                // Skip optional and recommended deps — not strictly required (#68)
                if (std.mem.indexOf(u8, line, "=> :optional") != null or
                    std.mem.indexOf(u8, line, "=> :recommended") != null) continue;
                // Check if build-only
                if (std.mem.indexOf(u8, line, "=> :build") != null) {
                    try build_deps.append(alloc, try alloc.dupe(u8, dep_name));
                } else {
                    try deps.append(alloc, try alloc.dupe(u8, dep_name));
                }
            }
        }

        // bin.install / sbin.install
        if (isBinInstallLine(line)) {
            switch (extractBinInstallNames(line)) {
                .names => |names| for (names) |maybe_name| {
                    const bin_name = maybe_name orelse break;
                    try install_bins.append(alloc, try alloc.dupe(u8, bin_name));
                },
                .glob_rename => |gr| try bin_renames.append(alloc, .{
                    .pattern = try alloc.dupe(u8, gr.pattern),
                    .dest = try alloc.dupe(u8, gr.dest),
                }),
                .unparseable => bin_install_unparseable = true,
                .none => {},
            }
        }

        // `using: :nounzip` marks the source url as a raw file (#361). It can
        // sit on the url line itself or on a continuation line right below it.
        if (std.mem.indexOf(u8, line, "using: :nounzip") != null) {
            source_nounzip = true;
        }
    }

    // Extract version from URL if not found explicitly
    if (version == null) {
        if (source_url) |url| {
            version = extractVersionFromUrl(url);
        }
    }

    const ver = version orelse return error.FormulaNotFound;

    // Interpolate #{version} in source_url
    const resolved_url = if (source_url) |url|
        try interpolateVersion(alloc, url, ver)
    else
        try alloc.dupe(u8, "");

    const resolved_sha = if (source_sha256) |s|
        try alloc.dupe(u8, s)
    else
        try alloc.dupe(u8, "");

    // Construct bottle URL
    const b_url = if (bottle_root_url != null and bottle_sha256 != null)
        try constructBottleUrlForTag(alloc, bottle_root_url.?, name, ver, bottle_tag)
    else
        try alloc.dupe(u8, "");

    const b_sha = if (bottle_sha256) |s|
        try alloc.dupe(u8, s)
    else
        try alloc.dupe(u8, "");

    if (bin_install_unparseable) {
        for (install_bins.items) |b| alloc.free(b);
        install_bins.clearRetainingCapacity();
        for (bin_renames.items) |r| {
            alloc.free(r.pattern);
            alloc.free(r.dest);
        }
        bin_renames.clearRetainingCapacity();
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .version = try alloc.dupe(u8, ver),
        .desc = try alloc.dupe(u8, desc orelse ""),
        .source_url = resolved_url,
        .source_sha256 = resolved_sha,
        .source_nounzip = source_nounzip,
        .bottle_url = b_url,
        .bottle_sha256 = b_sha,
        .dependencies = try deps.toOwnedSlice(alloc),
        .build_deps = try build_deps.toOwnedSlice(alloc),
        .install_binaries = try install_bins.toOwnedSlice(alloc),
        .install_bin_renames = try bin_renames.toOwnedSlice(alloc),
    };
}

fn constructBottleUrl(alloc: std.mem.Allocator, root_url: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return constructBottleUrlForTag(alloc, root_url, name, version, BOTTLE_TAG);
}

fn constructBottleUrlForTag(alloc: std.mem.Allocator, raw_root: []const u8, name: []const u8, version: []const u8, tag: []const u8) ![]const u8 {
    const root_url = try interpolateVersion(alloc, raw_root, version);
    defer alloc.free(root_url);
    // GHCR URLs use blob digest format
    if (std.mem.indexOf(u8, root_url, "ghcr.io") != null) {
        // For GHCR, bottle URL needs different format — leave as root_url for now,
        // actual download handled by existing GHCR auth path
        return std.fmt.allocPrint(alloc, "{s}", .{root_url});
    }
    // GitHub Releases: root_url/<name>-<version>.<TAG>.bottle.tar.gz
    return std.fmt.allocPrint(alloc, "{s}/{s}-{s}.{s}.bottle.tar.gz", .{
        root_url,
        name,
        version,
        tag,
    });
}

/// Interpolate #{version} references in a string.
fn interpolateVersion(alloc: std.mem.Allocator, s: []const u8, version: []const u8) ![]const u8 {
    const marker = "\x23{version}"; // #{version}
    if (std.mem.indexOf(u8, s, marker) == null and std.mem.indexOf(u8, s, "#{VERSION}") == null) {
        return alloc.dupe(u8, s);
    }
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + marker.len <= s.len and (std.mem.eql(u8, s[i..][0..marker.len], marker) or std.mem.eql(u8, s[i..][0..marker.len], "#{VERSION}"))) {
            try result.appendSlice(alloc, version);
            i += marker.len;
        } else {
            try result.append(alloc, s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(alloc);
}

/// Extract quoted string after a keyword, e.g. `version "1.0"` -> "1.0".
/// NOTE: This intentionally matches the keyword anywhere in the line —
/// callers like `parseRubyCask` rely on it to read mid-line `target:` /
/// `as: "..."` etc. parameters. The cost is that it would also match
/// the substring `version` inside `--version` flags within Ruby `test do`
/// blocks; those are handled at the caller level by skipping
/// `test do … end` block contents (see #279 / formula version bug).
fn extractQuotedAfter(line: []const u8, keyword: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, keyword) orelse return null;
    const after = line[idx + keyword.len ..];
    // Find opening quote
    const q1 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const rest = after[q1 + 1 ..];
    // Find closing quote
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

/// True for a `bin.install` / `sbin.install` directive. The boundary check
/// matters: a bare prefix match also catches `bin.install_symlink`, whose
/// argument is keg-rooted (e.g. `libexec/"tool"`), not a payload-rooted file —
/// capturing it would make source.zig skip the generic whole-payload copy and
/// then fail (or install a launcher without its payload).
fn isBinInstallLine(line: []const u8) bool {
    for ([_][]const u8{ "bin.install", "sbin.install" }) |kw| {
        if (startsWith(line, kw)) {
            if (line.len == kw.len) return false; // no arguments
            const c = line[kw.len];
            return c == ' ' or c == '\t' or c == '(';
        }
    }
    return false;
}

const BinInstallParse = union(enum) {
    /// No binary names on the line.
    none,
    /// Plain string-literal names, in order; trailing entries are null.
    names: [8]?[]const u8,
    /// `bin.install Dir["<glob>"].first => "<dest>"` — a payload-rooted glob
    /// whose first match is installed under a new name (#361). Resolved at
    /// source-install time against the staged files.
    glob_rename: struct {
        pattern: []const u8,
        dest: []const u8,
    },
    /// The directive has arguments we cannot resolve statically
    /// (`#{version}` interpolation, unsupported `Dir[...]` shapes, keg-path
    /// prefixes like `libexec/"x"`). The caller must NOT trust any partial
    /// capture — the safe behavior is to drop all declared binaries for the
    /// formula so the source-build path keeps its generic whole-payload copy.
    unparseable,
};

/// Extract binary names from `bin.install` / `sbin.install` Ruby directives.
/// Handles: `bin.install "a"`, `bin.install "a", "b"`, `bin.install "src" => "dst"`,
/// `bin.install("tool")`. For rename syntax, only the source name is returned.
/// Strict: every argument must be a plain string literal — anything else
/// (Ruby expressions, interpolation, globs) yields `.unparseable`.
fn extractBinInstallNames(line: []const u8) BinInstallParse {
    const install_idx = std.mem.indexOf(u8, line, ".install") orelse return .none;
    var rest = std.mem.trimStart(u8, line[install_idx + ".install".len ..], " \t");
    if (rest.len > 0 and rest[0] == '(') rest = std.mem.trimStart(u8, rest[1..], " \t");

    // `bin.install Dir["<glob>"].first => "<dest>"` (#361): raw-asset tap
    // formulas rename the single downloaded file. Only this exact shape is
    // resolved; any other Dir[...] expression stays unparseable.
    if (std.mem.startsWith(u8, rest, "Dir[")) {
        var r = rest["Dir[".len..];
        if (r.len == 0 or (r[0] != '"' and r[0] != '\'')) return .unparseable;
        const gq = r[0];
        const gclose = std.mem.indexOfScalar(u8, r[1..], gq) orelse return .unparseable;
        const pattern = r[1 .. 1 + gclose];
        if (pattern.len == 0 or std.mem.indexOf(u8, pattern, "#{") != null) return .unparseable;
        r = std.mem.trimStart(u8, r[1 + gclose + 1 ..], " \t");
        if (!std.mem.startsWith(u8, r, "]")) return .unparseable;
        r = std.mem.trimStart(u8, r[1..], " \t");
        if (!std.mem.startsWith(u8, r, ".first")) return .unparseable;
        r = std.mem.trimStart(u8, r[".first".len..], " \t");
        if (!std.mem.startsWith(u8, r, "=>")) return .unparseable;
        r = std.mem.trimStart(u8, r[2..], " \t");
        if (r.len == 0 or (r[0] != '"' and r[0] != '\'')) return .unparseable;
        const dq = r[0];
        const dclose = std.mem.indexOfScalar(u8, r[1..], dq) orelse return .unparseable;
        const dest = r[1 .. 1 + dclose];
        if (dest.len == 0 or std.mem.indexOf(u8, dest, "#{") != null) return .unparseable;
        if (std.mem.indexOfScalar(u8, dest, '*') != null) return .unparseable;
        r = std.mem.trimStart(u8, r[1 + dclose + 1 ..], " \t");
        if (r.len > 0 and r[0] == ')') r = std.mem.trimStart(u8, r[1..], " \t");
        if (r.len > 0 and r[0] != '#') return .unparseable;
        return .{ .glob_rename = .{ .pattern = pattern, .dest = dest } };
    }

    var result: [8]?[]const u8 = @splat(null);
    var count: usize = 0;

    while (rest.len > 0) {
        if (rest[0] == '#') break; // trailing Ruby comment
        const quote_char = rest[0];
        if (quote_char != '"' and quote_char != '\'') return .unparseable;
        const close = std.mem.indexOfScalar(u8, rest[1..], quote_char) orelse return .unparseable;
        const name = rest[1 .. 1 + close];
        if (name.len == 0) return .unparseable;
        if (std.mem.indexOf(u8, name, "#{") != null) return .unparseable; // interpolation
        if (std.mem.indexOfScalar(u8, name, '*') != null) return .unparseable; // glob
        if (count >= result.len) return .unparseable; // don't truncate silently
        result[count] = name;
        count += 1;
        rest = std.mem.trimStart(u8, rest[1 + close + 1 ..], " \t");

        // Rename syntax: `"src" => "dst"` — keep src, require dst be a literal.
        if (std.mem.startsWith(u8, rest, "=>")) {
            rest = std.mem.trimStart(u8, rest[2..], " \t");
            if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return .unparseable;
            const tq = rest[0];
            const tclose = std.mem.indexOfScalar(u8, rest[1..], tq) orelse return .unparseable;
            rest = std.mem.trimStart(u8, rest[1 + tclose + 1 ..], " \t");
        }

        if (rest.len == 0) break;
        if (rest[0] == ')') {
            rest = std.mem.trimStart(u8, rest[1..], " \t");
            continue;
        }
        if (rest[0] == ',') {
            rest = std.mem.trimStart(u8, rest[1..], " \t");
            if (rest.len == 0) return .unparseable; // dangling comma
            continue;
        }
        if (rest[0] == '#') break;
        return .unparseable;
    }

    if (count == 0) return .none;
    return .{ .names = result };
}

/// Find bottle sha256 matching our platform tag.
/// Format: `sha256 cellar: :any_skip_relocation, arm64_sonoma: "abc123"`
/// or: `sha256 arm64_sonoma: "abc123"`
fn findBottleSha256(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!startsWith(trimmed, "sha256")) return null;

    // Try primary tag first, then fallbacks
    if (findTagInLine(trimmed, BOTTLE_TAG)) |sha| return sha;
    for (BOTTLE_FALLBACKS) |tag| {
        if (findTagInLine(trimmed, tag)) |sha| return sha;
    }
    return null;
}

fn findTagInLine(line: []const u8, tag: []const u8) ?[]const u8 {
    // Look for `tag: "hex"`
    const needle_buf = comptime blk: {
        // Can't do runtime concat in comptime search, so we do it at call site
        break :blk {};
    };
    _ = needle_buf;

    // Search for tag followed by colon
    var i: usize = 0;
    while (i + tag.len < line.len) : (i += 1) {
        if (std.mem.eql(u8, line[i..][0..tag.len], tag)) {
            const after_tag = line[i + tag.len ..];
            if (after_tag.len > 0 and after_tag[0] == ':') {
                // Found "tag:", now extract quoted string
                const q1 = std.mem.indexOfScalar(u8, after_tag, '"') orelse return null;
                const rest = after_tag[q1 + 1 ..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
                return rest[0..q2];
            }
        }
    }
    return null;
}

/// Try to extract version from URL patterns like /v1.3.0/ or /1.3.0/
fn extractVersionFromUrl(url: []const u8) ?[]const u8 {
    // Look for /vX.Y.Z/ or /X.Y.Z/ in URL path segments
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '/') {
            const start = i + 1;
            if (start >= url.len) break;
            // Skip optional 'v' prefix
            const num_start = if (url[start] == 'v') start + 1 else start;
            if (num_start >= url.len) continue;
            // Check if it looks like a version (digit.digit...)
            if (!std.ascii.isDigit(url[num_start])) continue;
            // Find end of version segment
            var end = num_start;
            var has_dot = false;
            while (end < url.len) : (end += 1) {
                const c = url[end];
                if (c == '.' and end + 1 < url.len and std.ascii.isDigit(url[end + 1])) {
                    has_dot = true;
                    continue;
                }
                if (!std.ascii.isDigit(c)) break;
            }
            if (has_dot and end > num_start + 1) {
                return url[num_start..end];
            }
        }
    }

    // Fallback: look for -X.Y.Z. pattern in the filename (e.g. "tool-arm64-8.2.6.tgz")
    // Scan backwards for the last hyphen followed by a digit
    var j: usize = url.len;
    while (j > 0) : (j -= 1) {
        if (url[j - 1] == '-' and j < url.len and std.ascii.isDigit(url[j])) {
            const ver_start = j;
            // Find end: stop at known archive extensions or end of string
            var ver_end = ver_start;
            var dot_count: u32 = 0;
            while (ver_end < url.len) : (ver_end += 1) {
                const c = url[ver_end];
                if (c == '.') {
                    // Check if this dot starts an extension like .tgz, .tar, .zip
                    const rest = url[ver_end..];
                    if (std.mem.startsWith(u8, rest, ".tgz") or
                        std.mem.startsWith(u8, rest, ".tar") or
                        std.mem.startsWith(u8, rest, ".zip") or
                        std.mem.startsWith(u8, rest, ".dmg") or
                        std.mem.startsWith(u8, rest, ".pkg"))
                    {
                        break;
                    }
                    dot_count += 1;
                } else if (!std.ascii.isDigit(c)) {
                    break;
                }
            }
            if (dot_count >= 1 and ver_end > ver_start + 1) {
                return url[ver_start..ver_end];
            }
        }
    }

    return null;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseTapRef - valid user/tap/formula" {
    const ref = parseTapRef("steipete/tap/sag").?;
    try testing.expectEqualStrings("steipete", ref.user);
    try testing.expectEqualStrings("tap", ref.tap);
    try testing.expectEqualStrings("sag", ref.formula);
}

test "parseTapRef - rejects simple name" {
    try testing.expect(parseTapRef("tree") == null);
}

test "parseTapRef - rejects single slash" {
    try testing.expect(parseTapRef("user/formula") == null);
}

test "parseTapRef - rejects triple slash" {
    try testing.expect(parseTapRef("a/b/c/d") == null);
}

test "tapFormulaUrls includes root-level fallback before Formula paths" {
    const ref = parseTapRef("J-x-Z/tap/cocoa-way").?;
    const urls = try tapFormulaUrls(testing.allocator, ref);
    defer for (urls) |url| testing.allocator.free(url);

    try testing.expectEqual(@as(usize, 3), urls.len);
    try testing.expectEqualStrings("https://raw.githubusercontent.com/J-x-Z/homebrew-tap/HEAD/cocoa-way.rb", urls[0]);
    try testing.expectEqualStrings("https://raw.githubusercontent.com/J-x-Z/homebrew-tap/HEAD/Formula/cocoa-way.rb", urls[1]);
    try testing.expectEqualStrings("https://raw.githubusercontent.com/J-x-Z/homebrew-tap/HEAD/Formula/c/cocoa-way.rb", urls[2]);
}

test "tapCaskUrls keeps Casks lookup order" {
    const ref = parseTapRef("farion1231/ccswitch/cc-switch").?;
    const urls = try tapCaskUrls(testing.allocator, ref);
    defer for (urls) |url| testing.allocator.free(url);

    try testing.expectEqual(@as(usize, 2), urls.len);
    try testing.expectEqualStrings("https://raw.githubusercontent.com/farion1231/homebrew-ccswitch/HEAD/Casks/cc-switch.rb", urls[0]);
    try testing.expectEqualStrings("https://raw.githubusercontent.com/farion1231/homebrew-ccswitch/HEAD/Casks/c/cc-switch.rb", urls[1]);
}

test "parseRubyCask - binary target defaults to basename and honors target override" {
    const src =
        \\cask "demo" do
        \\  version "1.2.3"
        \\  sha256 "abc123"
        \\  url "https://example.com/demo-#{version}.zip"
        \\  binary "bin/demo"
        \\  binary "Demo.app/Contents/MacOS/demo", target: "demo-cli"
        \\end
    ;
    const c = try parseRubyCask(testing.allocator, "demo", src);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), c.artifacts.len);
    try testing.expectEqualStrings("bin/demo", c.artifacts[0].binary.source);
    try testing.expectEqualStrings("demo", c.artifacts[0].binary.target);
    try testing.expectEqualStrings("Demo.app/Contents/MacOS/demo", c.artifacts[1].binary.source);
    try testing.expectEqualStrings("demo-cli", c.artifacts[1].binary.target);
}

test "parseRubyCask - supports version latest with no_check sha" {
    const src =
        \\cask "demo-latest" do
        \\  version :latest
        \\  sha256 :no_check
        \\  url "https://example.com/demo-latest.zip"
        \\  name "Demo Latest"
        \\end
    ;
    const c = try parseRubyCask(testing.allocator, "demo-latest", src);
    defer c.deinit(testing.allocator);

    try testing.expectEqualStrings("latest", c.version);
    try testing.expectEqualStrings("no_check", c.sha256);
    try testing.expectEqualStrings("https://example.com/demo-latest.zip", c.url);
}

test "parseRubyCask - preserves full tap token" {
    const src =
        \\cask "cc-switch" do
        \\  version "1.0.0"
        \\  sha256 "abc123"
        \\  url "https://example.com/cc-switch.zip"
        \\end
    ;
    const c = try parseRubyCask(testing.allocator, "farion1231/ccswitch/cc-switch", src);
    defer c.deinit(testing.allocator);

    try testing.expectEqualStrings("farion1231/ccswitch/cc-switch", c.token);
}

test "parseRubyCask - respects on_arm branch for url and sha256" {
    const src =
        \\cask "demo-arch" do
        \\  version "2.0.0"
        \\  on_arm do
        \\    url "https://example.com/arm/demo.zip"
        \\    sha256 "armsha"
        \\  end
        \\  on_intel do
        \\    url "https://example.com/intel/demo.zip"
        \\    sha256 "intelsha"
        \\  end
        \\end
    ;
    const c = try parseRubyCask(testing.allocator, "demo-arch", src);
    defer c.deinit(testing.allocator);

    if (builtin.cpu.arch == .aarch64) {
        try testing.expectEqualStrings("https://example.com/arm/demo.zip", c.url);
        try testing.expectEqualStrings("armsha", c.sha256);
    } else if (builtin.cpu.arch == .x86_64) {
        try testing.expectEqualStrings("https://example.com/intel/demo.zip", c.url);
        try testing.expectEqualStrings("intelsha", c.sha256);
    }
}

test "parseRubyFormula - simple formula with version and url" {
    const src =
        \\class Sag < Formula
        \\  desc "Command-line ElevenLabs TTS"
        \\  version "0.2.2"
        \\  url "https://github.com/steipete/sag/releases/download/v0.2.2/sag.tar.gz"
        \\  sha256 "abc123"
        \\  def install
        \\    bin.install "sag"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "sag", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("sag", f.name);
    try testing.expectEqualStrings("0.2.2", f.version);
    try testing.expectEqualStrings("Command-line ElevenLabs TTS", f.desc);
    try testing.expectEqualStrings("https://github.com/steipete/sag/releases/download/v0.2.2/sag.tar.gz", f.source_url);
    try testing.expectEqualStrings("abc123", f.source_sha256);
    // Regression: tap formulas with a custom `def install / bin.install`
    // must surface the binary name so source_builder.installDeclaredBinaries
    // can place it under keg/bin/. See #286.
    try testing.expectEqual(@as(usize, 1), f.install_binaries.len);
    try testing.expectEqualStrings("sag", f.install_binaries[0]);
}

test "parseRubyFormula - def install bin.install populates install_binaries (#286)" {
    // Shape mirrors neurosnap/tap/zmx — prebuilt tarball with on_macos/on_arm
    // platform blocks and a custom `def install` containing `bin.install`.
    const src =
        \\class Zmx < Formula
        \\  desc "Session persistence for terminal processes"
        \\  version "0.5.0"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://zmx.sh/a/zmx-0.5.0-macos-aarch64.tar.gz"
        \\      sha256 "deadbeef"
        \\    end
        \\  end
        \\  def install
        \\    bin.install "zmx"
        \\    generate_completions_from_executable(bin/"zmx", "completions")
        \\  end
        \\  test do
        \\    assert_match "Usage: zmx", shell_output("#{bin}/zmx help")
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "zmx", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("zmx", f.name);
    try testing.expectEqualStrings("0.5.0", f.version);
    try testing.expectEqual(@as(usize, 1), f.install_binaries.len);
    try testing.expectEqualStrings("zmx", f.install_binaries[0]);
}

test "parseRubyFormula - bin.install with multiple binaries" {
    const src =
        \\class Multi < Formula
        \\  version "1.0"
        \\  url "https://example.com/multi.tar.gz"
        \\  sha256 "abc"
        \\  def install
        \\    bin.install "foo", "bar", "baz"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "multi", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.install_binaries.len);
    try testing.expectEqualStrings("foo", f.install_binaries[0]);
    try testing.expectEqualStrings("bar", f.install_binaries[1]);
    try testing.expectEqualStrings("baz", f.install_binaries[2]);
}

test "parseRubyFormula - def install absent yields empty install_binaries" {
    // Bottle-style formula that never lists explicit binaries.
    const src =
        \\class Hello < Formula
        \\  version "2.12.1"
        \\  url "https://example.com/hello.tar.gz"
        \\  sha256 "abc"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "hello", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), f.install_binaries.len);
}

test "parseRubyFormula - version interpolation in url" {
    const src =
        \\class Foo < Formula
        \\  version "1.5.0"
        \\  url "https://example.com/v#{version}/foo-#{version}.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "foo", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("1.5.0", f.version);
    try testing.expectEqualStrings("https://example.com/v1.5.0/foo-1.5.0.tar.gz", f.source_url);
}

test "parseRubyFormula - dependencies" {
    const src =
        \\class Bar < Formula
        \\  version "2.0"
        \\  url "https://example.com/bar.tar.gz"
        \\  sha256 "aaa"
        \\  depends_on "openssl"
        \\  depends_on "zlib"
        \\  depends_on "rust" => :build
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "bar", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), f.dependencies.len);
    try testing.expectEqualStrings("openssl", f.dependencies[0]);
    try testing.expectEqualStrings("zlib", f.dependencies[1]);
    try testing.expectEqual(@as(usize, 1), f.build_deps.len);
    try testing.expectEqualStrings("rust", f.build_deps[0]);
}

test "parseRubyFormula - bottle block with root_url" {
    // Carry a sha for every CI platform so findBottleSha256 resolves the
    // current BOTTLE_TAG on macOS and Linux alike.
    const src =
        \\class Bpb < Formula
        \\  version "1.3.0"
        \\  url "https://github.com/indirect/bpb/archive/refs/tags/v1.3.0.zip"
        \\  sha256 "709445fe"
        \\  bottle do
        \\    root_url "https://github.com/indirect/homebrew-tap/releases/download/bpb-v1.3.0"
        \\    sha256 cellar: :any_skip_relocation, arm64_sonoma: "32aab73b"
        \\    sha256 cellar: :any_skip_relocation, x86_64_linux: "32aab73b"
        \\    sha256 cellar: :any_skip_relocation, aarch64_linux: "32aab73b"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "bpb", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("1.3.0", f.version);
    // Bottle URL should be constructed
    try testing.expect(f.bottle_url.len > 0);
    try testing.expect(std.mem.indexOf(u8, f.bottle_url, "bpb-1.3.0") != null);
    try testing.expectEqualStrings("32aab73b", f.bottle_sha256);
    // Source should also be populated as fallback
    try testing.expectEqualStrings("709445fe", f.source_sha256);
}

test "parseRubyFormula - version extracted from url" {
    const src =
        \\class Xyz < Formula
        \\  url "https://github.com/user/xyz/archive/refs/tags/v3.2.1.tar.gz"
        \\  sha256 "fff"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "xyz", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("3.2.1", f.version);
}

test "parseRubyFormula - no version returns error" {
    const src =
        \\class Bad < Formula
        \\  url "https://example.com/no-version"
        \\  sha256 "aaa"
        \\end
    ;
    try testing.expectError(error.FormulaNotFound, parseRubyFormula(testing.allocator, "bad", src));
}

test "parseRubyFormula - test do block does not pollute version (#279)" {
    // Regression: a `test do` block whose `shell_output(...)` argument
    // contains the substring "version" (e.g. `--version`) used to leak
    // into the formula's version field. The corrupted state seen in
    // #279 had version = `#{bin}/sag --version` because the parser
    // matched the substring `version` inside `--version` and grabbed
    // the next quoted span.
    const src =
        \\class Sag < Formula
        \\  desc "sag"
        \\  url "https://example.com/sag-1.0.tar.gz"
        \\  version "1.0"
        \\  sha256 "deadbeef"
        \\
        \\  def install
        \\    bin.install "sag"
        \\  end
        \\
        \\  test do
        \\    assert_match "1.0", shell_output("#{bin}/sag --version")
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "sag", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("1.0", f.version);
    try testing.expectEqualStrings("sag", f.name);
}

test "parseRubyFormula - test do block before version line still finds version" {
    // If the `test do` block were not properly closed, subsequent
    // top-level lines (including a real `version "..."`) would be
    // skipped. Confirm `end` correctly exits the test scope.
    const src =
        \\class Foo < Formula
        \\  url "https://example.com/foo.tar.gz"
        \\  sha256 "aa"
        \\
        \\  test do
        \\    assert_match "v0.0.1", shell_output("#{bin}/foo --version")
        \\  end
        \\
        \\  version "9.9.9"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "foo", src);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("9.9.9", f.version);
}

test "extractQuotedAfter - basic" {
    const val = extractQuotedAfter("  version \"1.2.3\"", "version").?;
    try testing.expectEqualStrings("1.2.3", val);
}

test "extractQuotedAfter - not found" {
    try testing.expect(extractQuotedAfter("url \"x\"", "version") == null);
}

test "interpolateVersion - replaces marker" {
    const result = try interpolateVersion(testing.allocator, "v\x23{version}/file", "2.0");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("v2.0/file", result);
}

test "interpolateVersion - no marker returns copy" {
    const result = try interpolateVersion(testing.allocator, "plain-url", "1.0");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("plain-url", result);
}

test "extractVersionFromUrl - with v prefix" {
    const v = extractVersionFromUrl("https://github.com/user/repo/archive/refs/tags/v1.3.0.zip").?;
    try testing.expectEqualStrings("1.3.0", v);
}

test "extractVersionFromUrl - no version" {
    try testing.expect(extractVersionFromUrl("https://example.com/latest") == null);
}

test "findBottleSha256 - matching tag" {
    const line = "    sha256 cellar: :any_skip_relocation, arm64_sonoma: \"abcdef\"";
    const sha = findBottleSha256(line);
    if (is_macos and builtin.cpu.arch == .aarch64) {
        try testing.expectEqualStrings("abcdef", sha.?);
    }
}

test "extractBinInstallNames - single binary" {
    const result = extractBinInstallNames("bin.install \"crush\"").names;
    try testing.expectEqualStrings("crush", result[0].?);
    try testing.expect(result[1] == null);
}

test "extractBinInstallNames - multiple binaries" {
    const result = extractBinInstallNames("bin.install \"a\", \"b\", \"c\"").names;
    try testing.expectEqualStrings("a", result[0].?);
    try testing.expectEqualStrings("b", result[1].?);
    try testing.expectEqualStrings("c", result[2].?);
    try testing.expect(result[3] == null);
}

test "extractBinInstallNames - rename syntax" {
    const result = extractBinInstallNames("bin.install \"crush\" => \"crush-cli\"").names;
    try testing.expectEqualStrings("crush", result[0].?);
    try testing.expect(result[1] == null);
}

test "extractBinInstallNames - sbin" {
    const result = extractBinInstallNames("sbin.install \"daemon\"").names;
    try testing.expectEqualStrings("daemon", result[0].?);
}

test "extractBinInstallNames - parenthesized call" {
    const result = extractBinInstallNames("bin.install(\"tool\")").names;
    try testing.expectEqualStrings("tool", result[0].?);
}

test "isBinInstallLine - rejects bin.install_symlink (review follow-up)" {
    try testing.expect(isBinInstallLine("bin.install \"x\""));
    try testing.expect(isBinInstallLine("sbin.install(\"d\")"));
    try testing.expect(!isBinInstallLine("bin.install_symlink libexec/\"tool/bin/tool\""));
    try testing.expect(!isBinInstallLine("sbin.install_symlink \"x\""));
    try testing.expect(!isBinInstallLine("generate_completions_from_executable(bin/\"zmx\")"));
}

test "extractBinInstallNames - non-literal args are unparseable, not partially captured" {
    // Ruby interpolation
    try testing.expect(extractBinInstallNames("bin.install \"tool-#{version}\"") == .unparseable);
    // glob
    try testing.expect(extractBinInstallNames("bin.install Dir[\"scripts/*\"]") == .unparseable);
    // keg-path-rooted argument
    try testing.expect(extractBinInstallNames("bin.install libexec/\"x\"") == .unparseable);
    // bare expression
    try testing.expect(extractBinInstallNames("bin.install some_var") == .unparseable);
}

test "extractBinInstallNames - Dir glob rename resolves statically (#361)" {
    const r = extractBinInstallNames("bin.install Dir[\"omp-*\"].first => \"omp\"");
    try testing.expect(r == .glob_rename);
    try testing.expectEqualStrings("omp-*", r.glob_rename.pattern);
    try testing.expectEqualStrings("omp", r.glob_rename.dest);
}

test "extractBinInstallNames - Dir glob without .first rename stays unparseable (#361)" {
    try testing.expect(extractBinInstallNames("bin.install Dir[\"omp-*\"]") == .unparseable);
    try testing.expect(extractBinInstallNames("bin.install Dir[\"omp-*\"].first") == .unparseable);
    try testing.expect(extractBinInstallNames("bin.install Dir[\"omp-#{version}-*\"].first => \"omp\"") == .unparseable);
}

test "parseRubyFormula - using: :nounzip with Dir glob rename (#361)" {
    const src =
        \\class Omp < Formula
        \\  desc "Oh My Posh fork"
        \\  version "17.1.6"
        \\  url "https://github.com/can1357/oh-my-pi/releases/download/v#{version}/omp-darwin-arm64",
        \\      using: :nounzip
        \\  sha256 "6c0c45af6c8c566ce28370c8570d9a709713277fad5420b44161e26a3d07be5d"
        \\
        \\  def install
        \\    bin.install Dir["omp-*"].first => "omp"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "omp", src);
    defer f.deinit(testing.allocator);
    try testing.expect(f.source_nounzip);
    try testing.expectEqualStrings(
        "https://github.com/can1357/oh-my-pi/releases/download/v17.1.6/omp-darwin-arm64",
        f.source_url,
    );
    try testing.expectEqual(@as(usize, 0), f.install_binaries.len);
    try testing.expectEqual(@as(usize, 1), f.install_bin_renames.len);
    try testing.expectEqualStrings("omp-*", f.install_bin_renames[0].pattern);
    try testing.expectEqualStrings("omp", f.install_bin_renames[0].dest);
}

test "parseRubyFormula - archive formulas keep source_nounzip false" {
    const src =
        \\class Plain < Formula
        \\  version "1.0"
        \\  url "https://example.com/plain-1.0.tar.gz"
        \\  sha256 "abc"
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "plain", src);
    defer f.deinit(testing.allocator);
    try testing.expect(!f.source_nounzip);
    try testing.expectEqual(@as(usize, 0), f.install_bin_renames.len);
}

test "parseRubyFormula - unparseable bin.install clears install_binaries so generic copy runs" {
    const src =
        \\class Mixed < Formula
        \\  version "1.0"
        \\  url "https://example.com/mixed.tar.gz"
        \\  sha256 "abc"
        \\  def install
        \\    bin.install "good"
        \\    bin.install "tool-#{version}"
        \\  end
        \\end
    ;
    const f = try parseRubyFormula(testing.allocator, "mixed", src);
    defer f.deinit(testing.allocator);
    // Partial capture ("good" without the interpolated one) would break the
    // install — the whole list must be dropped.
    try testing.expectEqual(@as(usize, 0), f.install_binaries.len);
}

test "parseRubyFormula - extracts install_binaries" {
    const src =
        \\class Zmx < Formula
        \\  version "0.5.0"
        \\  url "https://example.com/zmx-0.5.0.tar.gz"
        \\  sha256 "abc123"
        \\  def install
        \\    bin.install "zmx"
        \\  end
        \\end
    ;
    const formula = try parseRubyFormula(testing.allocator, "zmx", src);
    defer formula.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), formula.install_binaries.len);
    try testing.expectEqualStrings("zmx", formula.install_binaries[0]);
}

test "parseRubyFormula - extracts install_binaries with rename" {
    const src =
        \\class Crush < Formula
        \\  version "1.0.0"
        \\  url "https://example.com/crush-1.0.0.tar.gz"
        \\  sha256 "def456"
        \\  def install
        \\    bin.install "crush" => "crush-cli"
        \\    sbin.install "crushd"
        \\  end
        \\end
    ;
    const formula = try parseRubyFormula(testing.allocator, "crush", src);
    defer formula.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), formula.install_binaries.len);
    try testing.expectEqualStrings("crush", formula.install_binaries[0]);
    try testing.expectEqualStrings("crushd", formula.install_binaries[1]);
}

test "tap VERSION constants interpolate source and selected bottle URL (#370)" {
    const src =
        \\class Anylinuxfs < Formula
        \\  VERSION = "0.19.0".freeze
        \\  url "https://example.test/v#{VERSION}.tar.gz"
        \\  sha256 "source"
        \\  bottle do
        \\    root_url "https://example.test/releases/v#{VERSION}"
    ;
    const full = try std.fmt.allocPrint(testing.allocator, "{s}\n    sha256 {s}: \"bottle\"\n  end\nend\n", .{ src, BOTTLE_TAG });
    defer testing.allocator.free(full);
    var f = try parseRubyFormula(testing.allocator, "anylinuxfs", full);
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("0.19.0", f.version);
    try testing.expectEqualStrings("https://example.test/v0.19.0.tar.gz", f.source_url);
    const expected = try std.fmt.allocPrint(testing.allocator, "https://example.test/releases/v0.19.0/anylinuxfs-0.19.0.{s}.bottle.tar.gz", .{BOTTLE_TAG});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, f.bottle_url);
    try testing.expectEqualStrings("bottle", f.bottle_sha256);
}

test "tap bottle digest and URL select the same best platform regardless of order (#370)" {
    const a = testing.allocator;
    const fallback = BOTTLE_FALLBACKS[BOTTLE_FALLBACKS.len - 1];
    const src = try std.fmt.allocPrint(a, "version \"1.0\"\nbottle do\nroot_url \"https://example.test\"\nsha256 {s}: \"primary\"\nsha256 {s}: \"fallback\"\nend\n", .{ BOTTLE_TAG, fallback });
    defer a.free(src);
    var f = try parseRubyFormula(a, "demo", src);
    defer f.deinit(a);
    try testing.expectEqualStrings("primary", f.bottle_sha256);
    const fallback_src = try std.fmt.allocPrint(a, "version \"1.0\"\nbottle do\nroot_url \"https://example.test\"\nsha256 {s}: \"fallback\"\nend\n", .{fallback});
    defer a.free(fallback_src);
    var g = try parseRubyFormula(a, "demo", fallback_src);
    defer g.deinit(a);
    const url = try std.fmt.allocPrint(a, "https://example.test/demo-1.0.{s}.bottle.tar.gz", .{fallback});
    defer a.free(url);
    try testing.expectEqualStrings(url, g.bottle_url);
    try testing.expectEqualStrings("fallback", g.bottle_sha256);
}
