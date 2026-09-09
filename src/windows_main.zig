// nanobrew — native Windows portable package manager
//
// This is not a winget/scoop/choco wrapper. It owns a small Windows Cellar in
// %LOCALAPPDATA%\nanobrew, downloads verified portable upstream assets,
// extracts/copies them into Cellar, and places runnable .exe files in bin.

const std = @import("std");

const VERSION = "0.1.209";

var g_io: std.Io = undefined;

const Package = struct {
    const Kind = enum { zip, exe };

    name: []const u8,
    version: []const u8,
    desc: []const u8,
    url: []const u8,
    sha256: []const u8,
    kind: Kind,
    bins: []const []const u8,
};

const embedded_windows_registry = @import("windows_registry").json;

const Dirs = struct { root: []u8, cellar: []u8, bin: []u8, cache: []u8, db: []u8, state: []u8 };

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const alloc = init.gpa;
    const args_raw = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try init.arena.allocator().alloc([]const u8, args_raw.len);
    for (args, args_raw) |*dst, src| dst.* = src;

    if (args.len < 2 or eql(args[1], "help") or eql(args[1], "--help") or eql(args[1], "-h")) {
        printUsage();
        std.process.exit(if (args.len < 2) 1 else 0);
    }

    const registry = try loadRegistry(alloc);
    const packages = registry.packages;

    const cmd = args[1];
    if (eql(cmd, "version")) {
        out("nanobrew {s} (native windows)\n", .{VERSION});
    } else if (eql(cmd, "init")) {
        const dirs = try getDirs(alloc);
        try ensureDirs(dirs);
        out("nanobrew initialized at {s}\n", .{dirs.root});
        out("Add to PATH: {s}\n", .{dirs.bin});
        out("PowerShell: [Environment]::SetEnvironmentVariable('Path', $env:Path + ';{s}', 'User')\n", .{dirs.bin});
    } else if (eql(cmd, "search")) {
        if (args.len < 3) die("nb: search query required\n", .{});
        var matches: usize = 0;
        for (packages) |p| {
            if (containsCaseless(p.name, args[2]) or containsCaseless(p.desc, args[2])) {
                out("{s} {s} — {s}\n", .{ p.name, p.version, p.desc });
                matches += 1;
            }
        }
        if (matches == 0) out("No packages found for '{s}'.\n", .{args[2]});
    } else if (eql(cmd, "info")) {
        if (args.len < 3) die("nb: package required\n", .{});
        const dirs = try getDirs(alloc);
        for (args[2..]) |name| try printPackageInfo(alloc, dirs, findPackage(packages, name) orelse {
            err("nb: package not found: {s}\n", .{name});
            std.process.exit(1);
        });
    } else if (eql(cmd, "install") or eql(cmd, "i")) {
        if (args.len < 3) die("nb: package required\n", .{});
        const dirs = try getDirs(alloc);
        try ensureDirs(dirs);
        for (args[2..]) |name| try installPackage(alloc, dirs, findPackage(packages, name) orelse {
            err("nb: package not found: {s}\n", .{name});
            std.process.exit(1);
        });
    } else if (eql(cmd, "remove") or eql(cmd, "rm") or eql(cmd, "uninstall")) {
        if (args.len < 3) die("nb: package required\n", .{});
        const dirs = try getDirs(alloc);
        for (args[2..]) |name| try removePackage(alloc, dirs, packages, name);
    } else if (eql(cmd, "list") or eql(cmd, "ls")) {
        const dirs = try getDirs(alloc);
        try listInstalled(alloc, dirs);
    } else if (eql(cmd, "upgrade")) {
        const dirs = try getDirs(alloc);
        if (args.len > 2) {
            for (args[2..]) |name| try installPackage(alloc, dirs, findPackage(packages, name) orelse {
                err("nb: package not found: {s}\n", .{name});
                std.process.exit(1);
            });
        } else {
            var installed = try readState(alloc, dirs);
            defer installed.deinit(alloc);
            for (installed.items) |rec| if (findPackage(packages, rec.name)) |p| try installPackage(alloc, dirs, p);
        }
    } else if (eql(cmd, "doctor")) {
        const dirs = try getDirs(alloc);
        out("root: {s}\n", .{dirs.root});
        out("bin:  {s}\n", .{dirs.bin});
        if (pathExists(dirs.bin)) out("  ✓ bin exists\n", .{}) else out("  ✗ bin missing (run nb init)\n", .{});
        if (pathContains(alloc, dirs.bin)) {
            out("  ✓ bin is on PATH\n", .{});
        } else {
            out("  ! bin is not on PATH for this shell\n", .{});
            out("    add it with: [Environment]::SetEnvironmentVariable('Path', $env:Path + ';{s}', 'User')\n", .{dirs.bin});
        }
    } else {
        die("nb: unknown command '{s}'\n", .{cmd});
    }
}

const Registry = struct { packages: []Package };

fn loadRegistry(alloc: std.mem.Allocator) !Registry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, embedded_windows_registry, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRegistry;

    const root = parsed.value.object;
    const schema = root.get("schema_version") orelse return error.InvalidRegistry;
    if (schema != .integer or schema.integer != 1) return error.InvalidRegistry;
    const pkg_value = root.get("packages") orelse return error.InvalidRegistry;
    if (pkg_value != .array) return error.InvalidRegistry;

    var out_list: std.ArrayList(Package) = .empty;
    errdefer freePackages(alloc, out_list.items);

    for (pkg_value.array.items) |item| {
        const p = try parseRegistryPackage(alloc, item);
        for (out_list.items) |existing| {
            if (eql(existing.name, p.name)) return error.DuplicatePackage;
        }
        try out_list.append(alloc, p);
    }
    if (out_list.items.len == 0) return error.InvalidRegistry;
    return .{ .packages = try out_list.toOwnedSlice(alloc) };
}

fn parseRegistryPackage(alloc: std.mem.Allocator, value: std.json.Value) !Package {
    if (value != .object) return error.InvalidRegistry;
    const obj = value.object;
    const name = try dupRegistryString(alloc, obj, "name");
    errdefer alloc.free(name);
    const version = try dupRegistryString(alloc, obj, "version");
    errdefer alloc.free(version);
    const desc = try dupRegistryString(alloc, obj, "desc");
    errdefer alloc.free(desc);
    const url = try dupRegistryString(alloc, obj, "url");
    errdefer alloc.free(url);
    const sha256 = try dupRegistryString(alloc, obj, "sha256");
    errdefer alloc.free(sha256);
    const kind_raw = try dupRegistryString(alloc, obj, "kind");
    defer alloc.free(kind_raw);
    const bins = try parseRegistryBins(alloc, obj);
    errdefer freeStringSlice(alloc, bins);

    try validatePackageName(name);
    try validateHttpsUrl(url);
    try validateSha256(sha256);
    for (bins) |bin| try validateBinName(bin);

    const kind: Package.Kind = if (std.mem.eql(u8, kind_raw, "zip")) .zip else if (std.mem.eql(u8, kind_raw, "exe")) .exe else return error.InvalidRegistry;
    if (kind == .exe and bins.len != 1) return error.InvalidRegistry;

    return .{ .name = name, .version = version, .desc = desc, .url = url, .sha256 = sha256, .kind = kind, .bins = bins };
}

fn parseRegistryBins(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]const []const u8 {
    const value = obj.get("bins") orelse return error.InvalidRegistry;
    if (value != .array or value.array.items.len == 0) return error.InvalidRegistry;
    var out_list: std.ArrayList([]const u8) = .empty;
    errdefer freeStringSlice(alloc, out_list.items);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidRegistry;
        try out_list.append(alloc, try alloc.dupe(u8, item.string));
    }
    return out_list.toOwnedSlice(alloc);
}

fn dupRegistryString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.InvalidRegistry;
    if (value != .string or value.string.len == 0) return error.InvalidRegistry;
    return alloc.dupe(u8, value.string);
}

fn validatePackageName(name: []const u8) !void {
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return error.InvalidRegistry;
    }
}

fn validateHttpsUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidRegistry;
}

fn validateSha256(hex: []const u8) !void {
    if (hex.len != 64) return error.InvalidRegistry;
    for (hex) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.InvalidRegistry;
    }
}

fn validateBinName(bin: []const u8) !void {
    if (!std.mem.endsWith(u8, bin, ".exe")) return error.InvalidRegistry;
    if (std.mem.indexOfAny(u8, bin, "\\/") != null) return error.InvalidRegistry;
    if (std.mem.indexOf(u8, bin, "..") != null) return error.InvalidRegistry;
}

fn freePackages(alloc: std.mem.Allocator, packages: []const Package) void {
    for (packages) |p| {
        alloc.free(p.name);
        alloc.free(p.version);
        alloc.free(p.desc);
        alloc.free(p.url);
        alloc.free(p.sha256);
        freeStringSlice(alloc, p.bins);
    }
}

fn freeStringSlice(alloc: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn printPackageInfo(alloc: std.mem.Allocator, dirs: Dirs, p: Package) !void {
    out("{s} {s}\n", .{ p.name, p.version });
    out("  desc:   {s}\n", .{p.desc});
    out("  kind:   {s}\n", .{@tagName(p.kind)});
    out("  url:    {s}\n", .{p.url});
    out("  sha256: {s}\n", .{p.sha256});
    out("  bins:  ", .{});
    for (p.bins, 0..) |bin, i| {
        if (i > 0) out(", ", .{});
        out("{s}", .{bin});
    }
    out("\n", .{});

    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    for (records.items) |r| {
        if (eql(r.name, p.name)) {
            out("  installed: yes ({s})\n", .{r.version});
            return;
        }
    }
    out("  installed: no\n", .{});
}

fn installPackage(alloc: std.mem.Allocator, dirs: Dirs, p: Package) !void {
    out("==> Installing {s} {s}\n", .{ p.name, p.version });
    var archive_name_buf: [256]u8 = undefined;
    const ext = if (p.kind == .zip) ".zip" else ".exe";
    const archive_name = try std.fmt.bufPrint(&archive_name_buf, "{s}-{s}{s}", .{ p.name, p.version, ext });
    const archive = try join(alloc, &.{ dirs.cache, archive_name });
    defer alloc.free(archive);
    if (!pathExists(archive)) try powershell(alloc, &.{ "Invoke-WebRequest", "-Uri", p.url, "-OutFile", archive });
    try verifySha256(alloc, archive, p.sha256);

    const pkg_root = try join(alloc, &.{ dirs.cellar, p.name });
    defer alloc.free(pkg_root);
    const pkg_dir = try join(alloc, &.{ pkg_root, p.version });
    defer alloc.free(pkg_dir);
    std.Io.Dir.cwd().deleteTree(io(), pkg_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io(), pkg_dir);

    switch (p.kind) {
        .zip => {
            try powershell(alloc, &.{ "Expand-Archive", "-LiteralPath", archive, "-DestinationPath", pkg_dir, "-Force" });
            for (p.bins) |bin| {
                const src = try findFileRecursive(alloc, pkg_dir, bin) orelse return error.BinaryNotFound;
                defer alloc.free(src);
                const dst_cellar = try join(alloc, &.{ pkg_dir, bin });
                defer alloc.free(dst_cellar);
                if (!eql(src, dst_cellar)) try copyFile(src, dst_cellar);
            }
        },
        .exe => {
            const dst_cellar = try join(alloc, &.{ pkg_dir, p.bins[0] });
            defer alloc.free(dst_cellar);
            try copyFile(archive, dst_cellar);
        },
    }

    for (p.bins) |bin| {
        const src = try join(alloc, &.{ pkg_dir, bin });
        defer alloc.free(src);
        const dst = try join(alloc, &.{ dirs.bin, bin });
        defer alloc.free(dst);
        try copyFile(src, dst);
        out("  linked {s}\n", .{dst});
    }
    try recordInstall(alloc, dirs, p);
    out("==> Installed {s} {s}\n", .{ p.name, p.version });
}

fn removePackage(alloc: std.mem.Allocator, dirs: Dirs, packages: []const Package, name: []const u8) !void {
    const p = findPackage(packages, name);
    if (p) |pkg| for (pkg.bins) |bin| {
        const dst = try join(alloc, &.{ dirs.bin, bin });
        defer alloc.free(dst);
        std.Io.Dir.cwd().deleteFile(io(), dst) catch {};
    };
    const root = try join(alloc, &.{ dirs.cellar, name });
    defer alloc.free(root);
    std.Io.Dir.cwd().deleteTree(io(), root) catch {};
    try removeState(alloc, dirs, name);
    out("==> Removed {s}\n", .{name});
}

const Record = struct { name: []u8, version: []u8 };
const State = struct {
    items: []Record,
    pub fn deinit(self: State, alloc: std.mem.Allocator) void {
        for (self.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        alloc.free(self.items);
    }
};

fn readState(alloc: std.mem.Allocator, dirs: Dirs) !std.ArrayList(Record) {
    var list: std.ArrayList(Record) = .empty;
    const data = readFileAlloc(alloc, dirs.state, 1024 * 1024) catch return list;
    defer alloc.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const n = parts.next() orelse continue;
        const v = parts.next() orelse continue;
        try list.append(alloc, .{ .name = try alloc.dupe(u8, n), .version = try alloc.dupe(u8, v) });
    }
    return list;
}

fn recordInstall(alloc: std.mem.Allocator, dirs: Dirs, p: Package) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    var found = false;
    for (records.items) |*r| if (eql(r.name, p.name)) {
        alloc.free(r.version);
        r.version = try alloc.dupe(u8, p.version);
        found = true;
    };
    if (!found) try records.append(alloc, .{ .name = try alloc.dupe(u8, p.name), .version = try alloc.dupe(u8, p.version) });
    try writeState(alloc, dirs, records.items);
}

fn removeState(alloc: std.mem.Allocator, dirs: Dirs, name: []const u8) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    var kept: std.ArrayList(Record) = .empty;
    defer kept.deinit(alloc);
    for (records.items) |r| if (!eql(r.name, name)) try kept.append(alloc, r);
    try writeState(alloc, dirs, kept.items);
}

fn writeState(alloc: std.mem.Allocator, dirs: Dirs, records: []const Record) !void {
    var outw: std.Io.Writer.Allocating = .init(alloc);
    defer outw.deinit();
    for (records) |r| try outw.writer.print("{s}\t{s}\n", .{ r.name, r.version });
    const data = try outw.toOwnedSlice();
    defer alloc.free(data);
    try writeFile(dirs.state, data);
}

fn listInstalled(alloc: std.mem.Allocator, dirs: Dirs) !void {
    var records = try readState(alloc, dirs);
    defer {
        for (records.items) |r| {
            alloc.free(r.name);
            alloc.free(r.version);
        }
        records.deinit(alloc);
    }
    for (records.items) |r| out("{s} {s}\n", .{ r.name, r.version });
}

fn verifySha256(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const data = try readFileAlloc(alloc, path, 128 * 1024 * 1024);
    defer alloc.free(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var hex: [64]u8 = undefined;
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = charset[byte >> 4];
        hex[idx * 2 + 1] = charset[byte & 0x0f];
    }
    if (!std.mem.eql(u8, &hex, expected)) return error.ChecksumMismatch;
}

fn powershell(alloc: std.mem.Allocator, words: []const []const u8) !void {
    var script: std.Io.Writer.Allocating = .init(alloc);
    defer script.deinit();
    for (words, 0..) |w, i| {
        if (i > 0) try script.writer.writeByte(' ');
        if (i == 0 or std.mem.startsWith(u8, w, "-")) {
            try script.writer.writeAll(w);
        } else {
            try script.writer.writeByte('\'');
            for (w) |c| {
                if (c == '\'') try script.writer.writeAll("''") else try script.writer.writeByte(c);
            }
            try script.writer.writeByte('\'');
        }
    }
    const s = try script.toOwnedSlice();
    defer alloc.free(s);
    const result = std.process.run(std.heap.smp_allocator, io(), .{ .argv = &.{ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", s }, .stdout_limit = .unlimited, .stderr_limit = .unlimited }) catch |err_| {
        err("powershell launch failed: {}\n", .{err_});
        return error.PowerShellFailed;
    };
    defer std.heap.smp_allocator.free(result.stdout);
    defer std.heap.smp_allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.Io.File.stdout().writeStreamingAll(io(), result.stdout) catch {};
        std.Io.File.stdout().writeStreamingAll(io(), result.stderr) catch {};
        return error.PowerShellFailed;
    }
}

fn findFileRecursive(alloc: std.mem.Allocator, root: []const u8, basename: []const u8) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io(), root, .{ .iterate = true }) catch return null;
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |e| {
        const p = try join(alloc, &.{ root, e.name });
        if (e.kind == .file and eql(e.name, basename)) return p;
        if (e.kind == .directory) {
            if (try findFileRecursive(alloc, p, basename)) |found| {
                alloc.free(p);
                return found;
            }
        }
        alloc.free(p);
    }
    return null;
}

fn getDirs(alloc: std.mem.Allocator) !Dirs {
    const local_raw = getEnvValue(alloc, "LOCALAPPDATA") catch try getEnvValue(alloc, "USERPROFILE");
    defer alloc.free(local_raw);
    const local = std.mem.trim(u8, local_raw, " \r\n\t");
    const root = try join(alloc, &.{ local, "nanobrew" });
    const cellar = try join(alloc, &.{ root, "Cellar" });
    const bin = try join(alloc, &.{ root, "bin" });
    const cache = try join(alloc, &.{ root, "cache" });
    const db = try join(alloc, &.{ root, "db" });
    const state = try join(alloc, &.{ db, "state.tsv" });
    return .{ .root = root, .cellar = cellar, .bin = bin, .cache = cache, .db = db, .state = state };
}

fn io() std.Io {
    return g_io;
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io(), path, .{});
    defer file.close(io());
    const st = try file.stat(io());
    if (st.size > max) return error.FileTooBig;
    const buf = try alloc.alloc(u8, @intCast(st.size));
    const n = try file.readPositionalAll(io(), buf, 0);
    return buf[0..n];
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io(), path, .{});
    defer file.close(io());
    try file.writeStreamingAll(io(), data);
}

fn getEnvValue(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var name_buf: [64:0]u8 = undefined;
    if (name.len >= name_buf.len) return error.EnvMissing;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return error.EnvMissing;
    return alloc.dupe(u8, std.mem.span(raw));
}

fn ensureDirs(dirs: Dirs) !void {
    try std.Io.Dir.cwd().createDirPath(io(), dirs.cellar);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.bin);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.cache);
    try std.Io.Dir.cwd().createDirPath(io(), dirs.db);
}
fn copyFile(src: []const u8, dst: []const u8) !void {
    try powershell(std.heap.smp_allocator, &.{ "Copy-Item", "-LiteralPath", src, "-Destination", dst, "-Force" });
}
fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}
fn join(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(alloc, parts);
}
fn findPackage(packages: []const Package, name: []const u8) ?Package {
    for (packages) |p| if (eql(p.name, name)) return p;
    return null;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn containsCaseless(haystack: []const u8, needle: []const u8) bool {
    var hb: [256]u8 = undefined;
    var nb: [128]u8 = undefined;
    const h = lower(&hb, haystack);
    const n = lower(&nb, needle);
    return std.mem.indexOf(u8, h, n) != null;
}
fn pathContains(alloc: std.mem.Allocator, bin: []const u8) bool {
    const path = getEnvValue(alloc, "PATH") catch getEnvValue(alloc, "Path") catch return false;
    defer alloc.free(path);
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |entry| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, entry, " \""), bin)) return true;
    return false;
}

fn lower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}
fn out(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
    defer std.heap.smp_allocator.free(msg);
    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}
fn err(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
    defer std.heap.smp_allocator.free(msg);
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}
fn die(comptime fmt: []const u8, args: anytype) noreturn {
    err(fmt, args);
    std.process.exit(1);
}

fn printUsage() void {
    out(
        \\nanobrew {s} — native Windows portable package manager
        \\
        \\USAGE:
        \\  nb <command> [arguments]
        \\
        \\COMMANDS:
        \\  init                    Create %LOCALAPPDATA%\\nanobrew
        \\  search <query>          Search nanobrew's Windows registry
        \\  install <package>       Download, verify, extract, and link a package
        \\  upgrade [package]       Reinstall one package or all installed packages
        \\  remove <package>        Remove package files and linked executables
        \\  list                    List installed packages
        \\  doctor                  Show nanobrew Windows paths
        \\  version                 Show version
        \\
        \\AVAILABLE NOW:
        \\  ripgrep, fd, bat, jq, uv, yq, just, hyperfine, fzf, starship
        \\  eza, delta, dust, bottom, zoxide, sd, hexyl, dua, procs
        \\  bun, deno, gh, watchexec, pastel, xsv, yazi, oh-my-posh
        \\  kubectl, terraform, helm, k9s, lazygit, lazydocker, rclone
        \\  age, sops, hugo, neovim
        \\
    , .{VERSION});
}
