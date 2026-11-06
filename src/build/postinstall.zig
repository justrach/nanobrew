// nanobrew — Post-install script runner and caveat display
//
// Handles two post-install concerns:
// 1. Caveats: text instructions displayed after install
// 2. post_install scripts: parsed from Ruby formula source and executed

const std = @import("std");
const Formula = @import("../api/formula.zig").Formula;
const fetch = @import("../net/fetch.zig");


const sandbox = @import("sandbox.zig");
const formula_cache = @import("formula_cache.zig");
const certs = @import("certs.zig");
const install_steps = @import("install_steps.zig");
const paths = @import("../platform/paths.zig");

pub const ParsedCommand = struct {
    argv: []const []const u8,

    pub fn deinit(self: ParsedCommand, alloc: std.mem.Allocator) void {
        for (self.argv) |arg| alloc.free(arg);
        alloc.free(self.argv);
    }
};

pub fn runPostInstall(alloc: std.mem.Allocator, io: std.Io, formula: Formula) !void {
    const lib_io = io;

    // Native post-install steps first: things Homebrew does in Ruby that
    // the heuristic script parser below can't execute (install_symlink,
    // keychain extraction). Runs even when post_install_defined is false
    // or the formula source can't be fetched — TLS trust wiring must not
    // depend on a network round trip to raw.githubusercontent.com.
    certs.nativePostInstall(lib_io, formula.name);

    // The API now lists post-install actions as `post_install_steps` and
    // sends post_install_defined = false for every formula (#493).
    if (formula.post_install_steps.len > 0 and !certs.handlesPostInstall(formula.name)) {
        ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "==> Running post-install for {s}...\n", .{formula.name}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stdout().writeStreamingAll(lib_io, _tmp) catch {}; });
        runPostInstallSteps(alloc, lib_io, formula, paths.PREFIX) catch |err| {
            ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: {s}: post-install steps failed: {}\n", .{ formula.name, err }) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stderr().writeStreamingAll(lib_io, _tmp) catch {}; });
        };
    } else if (formula.post_install_steps.len == 0 and formula.post_install_defined) {
        // Older API data (cache or a mirror): the Ruby `def post_install`.
        ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "==> Running post-install for {s}...\n", .{formula.name}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stdout().writeStreamingAll(lib_io, _tmp) catch {}; });
        runPostInstallScript(alloc, lib_io, formula) catch |err| {
            ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: {s}: post-install script failed: {}\n", .{ formula.name, err }) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stderr().writeStreamingAll(lib_io, _tmp) catch {}; });
        };
    }

    // Display caveats
    if (formula.caveats.len > 0) {
        ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "==> Caveats\n{s}", .{formula.caveats}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stdout().writeStreamingAll(lib_io, _tmp) catch {}; });
        // Ensure trailing newline
        if (formula.caveats[formula.caveats.len - 1] != '\n') {
            ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "\n", .{}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stdout().writeStreamingAll(lib_io, _tmp) catch {}; });
        }
    }
}

/// Run the API `post_install_steps` for `formula`, installed under `prefix`.
pub fn runPostInstallSteps(alloc: std.mem.Allocator, io: std.Io, formula: Formula, prefix: []const u8) !void {
    var ver_buf: [128]u8 = undefined;
    const eff_ver = formula.effectiveVersion(&ver_buf);
    // Templates use the version without the revision suffix.
    const plain = if (std.mem.lastIndexOfScalar(u8, eff_ver, '_')) |i| (if (formula.revision > 0) eff_ver[0..i] else eff_ver) else eff_ver;
    var cellar_buf: [512]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{prefix});
    var keg_buf: [768]u8 = undefined;
    const keg = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ cellar, formula.name, eff_ver });
    const user: ?[]const u8 = if (std.c.getenv("USER")) |u| std.mem.sliceTo(u, 0) else null;
    _ = try install_steps.runAll(alloc, io, formula.post_install_steps, .{
        .prefix = prefix,
        .cellar = cellar,
        .keg = keg,
        .name = formula.name,
        .version = plain,
        .user = user,
    }, install_steps.Stderr{ .io = io });
}

fn runPostInstallScript(alloc: std.mem.Allocator, io: std.Io, formula: Formula) !void {
    const lib_io = io;

    // Compute effective version early (needed for cache key)
    var ver_buf: [128]u8 = undefined;
    const eff_ver = formula.effectiveVersion(&ver_buf);

    // Fetch Ruby formula source
    if (formula.name.len == 0) return;
    const url = coreFormulaUrl(alloc, formula.name) catch return error.OutOfMemory;
    defer alloc.free(url);

    const ruby_src = try formula_cache.getVerifiedFormula(alloc, formula.name, eff_ver, url);
    defer alloc.free(ruby_src);

    if (ruby_src.len == 0) return;

    // Extract post_install block
    const block = extractPostInstallBlock(ruby_src) orelse return;

    // Parse and execute commands
    var keg_buf: [512]u8 = undefined;
    const keg_path = std.fmt.bufPrint(&keg_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{
        formula.name, eff_ver,
    }) catch return;

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (parseRubyCommand(alloc, trimmed, formula.name, keg_path)) |cmd| {
            defer cmd.deinit(alloc);
            const result = std.process.run(alloc, lib_io, .{
                .argv = cmd.argv,
            }) catch continue;
            alloc.free(result.stdout);
            alloc.free(result.stderr);
            if (result.term == .exited and result.term.exited != 0) {
                ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: {s}: post-install command failed (exit {d})\n", .{ formula.name, result.term.exited }) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stderr().writeStreamingAll(lib_io, _tmp) catch {}; });
            }
        }
    }
}

/// homebrew-core shards Formula/ by first letter, except that every "lib*"
/// formula lives in Formula/lib/ (Formula/lib/libpng.rb, not Formula/l/).
fn coreFormulaUrl(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const shard: []const u8 = if (std.mem.startsWith(u8, name, "lib")) "lib" else name[0..1];
    return std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/{s}/{s}.rb", .{ shard, name });
}

test "coreFormulaUrl - homebrew-core shard paths" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "libpng", "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/lib/libpng.rb" },
        .{ "jq", "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/j/jq.rb" },
        .{ "lima", "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/l/lima.rb" },
    };
    for (cases) |c| {
        const url = try coreFormulaUrl(a, c[0]);
        defer a.free(url);
        try std.testing.expectEqualStrings(c[1], url);
    }
}

fn extractPostInstallBlock(source: []const u8) ?[]const u8 {
    // Find "def post_install"
    const marker = "def post_install";
    const start_idx = std.mem.indexOf(u8, source, marker) orelse return null;

    // Find the line after marker
    const after_marker = start_idx + marker.len;
    if (after_marker >= source.len) return null;

    // Find matching end — track nesting of def/do/if/unless...end
    var depth: u32 = 1;
    var pos = after_marker;
    while (pos < source.len) {
        // Find next newline
        const nl = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[pos..nl], " \t\r");

        // Check for nesting keywords at start of line
        if (startsWithKeyword(line, "def ") or
            startsWithKeyword(line, "do") or
            startsWithKeyword(line, "if ") or
            startsWithKeyword(line, "unless ") or
            startsWithKeyword(line, "begin"))
        {
            depth += 1;
        }

        if (std.mem.eql(u8, line, "end")) {
            depth -= 1;
            if (depth == 0) {
                return source[after_marker..pos];
            }
        }

        pos = if (nl < source.len) nl + 1 else source.len;
    }
    return null;
}

fn startsWithKeyword(line: []const u8, keyword: []const u8) bool {
    if (line.len < keyword.len) return false;
    if (!std.mem.startsWith(u8, line, keyword)) return false;
    // If keyword ends with space, it's a prefix check
    if (keyword[keyword.len - 1] == ' ') return true;
    // Otherwise must be exact match or followed by space/newline
    if (line.len == keyword.len) return true;
    const next = line[keyword.len];
    return next == ' ' or next == '\t' or next == '\n';
}

fn parseRubyCommand(alloc: std.mem.Allocator, line: []const u8, name: []const u8, keg_path: []const u8) ?ParsedCommand {
    _ = name;
    // system "cmd", "arg1", "arg2" → run cmd directly with args (no shell)
    if (std.mem.startsWith(u8, line, "system ")) {
        return parseSystemCall(alloc, line["system ".len..], keg_path);
    }

    // (prefix/"path").mkpath → mkdir -p prefix/path
    if (std.mem.indexOf(u8, line, ".mkpath")) |_| {
        if (extractPathExpr(line)) |path_expr| {
            const resolved = resolvePath(alloc, path_expr, keg_path) catch return null;
            const argv = alloc.dupe([]const u8, &.{ "mkdir", "-p", resolved }) catch { alloc.free(resolved); return null; };
            return ParsedCommand{ .argv = argv };
        }
    }

    // mkdir_p "path" → mkdir -p path
    if (std.mem.startsWith(u8, line, "mkdir_p ")) {
        if (extractQuotedString(line["mkdir_p ".len..])) |path| {
            const resolved = resolvePath(alloc, path, keg_path) catch return null;
            const argv = alloc.dupe([]const u8, &.{ "mkdir", "-p", resolved }) catch { alloc.free(resolved); return null; };
            return ParsedCommand{ .argv = argv };
        }
    }

    // ln_sf source, target → ln -sf source target (no shell)
    if (std.mem.startsWith(u8, line, "ln_sf ")) {
        return parseLnSf(alloc, line["ln_sf ".len..], keg_path);
    }

    return null;
}

fn parseSystemCall(alloc: std.mem.Allocator, args_str: []const u8, keg_path: []const u8) ?ParsedCommand {
    // Parse "cmd", "arg1", "arg2" into an argv array — no shell involved
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }

    var rest = args_str;
    while (rest.len > 0) {
        rest = std.mem.trim(u8, rest, " \t,");
        if (rest.len == 0) break;

        if (extractQuotedString(rest)) |quoted| {
            const resolved = resolvePath(alloc, quoted, keg_path) catch return null;
            parts.append(alloc, resolved) catch { alloc.free(resolved); return null; };
            // Advance past the quoted string + quotes + comma
            const skip = std.mem.indexOf(u8, rest[1..], &[_]u8{rest[0]});
            if (skip) |s| {
                rest = rest[s + 2..];
            } else break;
        } else break;
    }

    if (parts.items.len == 0) return null;

    const argv = parts.toOwnedSlice(alloc) catch return null;
    return ParsedCommand{ .argv = argv };
}

fn parseLnSf(alloc: std.mem.Allocator, args_str: []const u8, keg_path: []const u8) ?ParsedCommand {
    // Parse: "source", "target" → argv ["ln", "-sf", source, target] — no shell
    var rest = std.mem.trim(u8, args_str, " \t");
    const src = extractQuotedString(rest) orelse return null;
    // Skip past first quoted string
    const skip = std.mem.indexOf(u8, rest[1..], &[_]u8{rest[0]});
    if (skip == null) return null;
    rest = std.mem.trim(u8, rest[skip.? + 2..], " \t,");
    const tgt = extractQuotedString(rest) orelse return null;

    const rsrc = resolvePath(alloc, src, keg_path) catch return null;
    errdefer alloc.free(rsrc);
    const rtgt = resolvePath(alloc, tgt, keg_path) catch { alloc.free(rsrc); return null; };
    errdefer alloc.free(rtgt);

    const ln = alloc.dupe(u8, "ln") catch { alloc.free(rsrc); alloc.free(rtgt); return null; };
    errdefer alloc.free(ln);
    const flag = alloc.dupe(u8, "-sf") catch { alloc.free(rsrc); alloc.free(rtgt); alloc.free(ln); return null; };

    const argv = alloc.dupe([]const u8, &.{ ln, flag, rsrc, rtgt }) catch {
        alloc.free(rsrc); alloc.free(rtgt); alloc.free(ln); alloc.free(flag);
        return null;
    };
    return ParsedCommand{ .argv = argv };
}

fn extractQuotedString(s: []const u8) ?[]const u8 {
    if (s.len < 2) return null;
    const quote = s[0];
    if (quote != '"' and quote != '\'') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, quote) orelse return null;
    return s[1..end];
}

fn extractPathExpr(line: []const u8) ?[]const u8 {
    // Match patterns like (prefix/"path") or prefix/"path"
    if (std.mem.indexOf(u8, line, "\"")) |q1| {
        if (std.mem.indexOfScalarPos(u8, line, q1 + 1, '"')) |q2| {
            return line[q1 + 1 .. q2];
        }
    }
    return null;
}

fn resolvePath(alloc: std.mem.Allocator, path: []const u8, keg_path: []const u8) ![]const u8 {
    // Replace #{prefix} or similar with keg_path
    if (std.mem.indexOf(u8, path, "#{")) |_| {
        // Simple replacement of common interpolations
        const result = try alloc.dupe(u8, path);
        // This is a best-effort — complex Ruby interpolation won't be handled
        return result;
    }
    // If path starts with /, it's absolute
    if (path.len > 0 and path[0] == '/') {
        return alloc.dupe(u8, path);
    }
    // Otherwise relative to keg
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ keg_path, path });
}
