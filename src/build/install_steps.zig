// Homebrew API post_install_steps are data, not executable instructions.
// Keep this interpreter allowlisted; it never starts a process or fetches a URL.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Value = std.json.Value;
const Object = std.json.ObjectMap;
const supported_os = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const Context = struct {
    name: []const u8,
    version: []const u8,
};

const Action = union(enum) {
    mkdir_p: []const u8,
    touch: []const u8,
    symlink: struct { source: []const u8, target: []const u8 },
    warn: []const u8,
};

pub fn run(alloc: Allocator, io: Io, prefix: []const u8, ctx: Context, json: []const u8, out: *Io.Writer) !void {
    if (!supported_os) return error.UnsupportedPlatform;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    if (parsed.value != .array) return error.ExpectedPostInstallArray;
    if (parsed.value.array.items.len == 0) return;
    if (!std.mem.startsWith(u8, prefix, "/")) return error.InvalidPrefix;
    const fs_root = try Dir.openDirAbsolute(io, "/", .{});
    defer fs_root.close(io);
    // Do not even follow a symlink in the configured prefix itself.
    const root = try walk(io, fs_root, prefix[1..], .open);
    defer root.close(io);
    try runAt(a, io, root, prefix, ctx, parsed.value.array.items, out);
}

fn runAt(a: Allocator, io: Io, root: Dir, prefix: []const u8, ctx: Context, steps: []const Value, out: *Io.Writer) !void {
    if (!validComponent(ctx.name) or !validComponent(ctx.version)) return error.InvalidFormulaPath;
    const keg = try std.fmt.allocPrint(a, "Cellar/{s}/{s}", .{ ctx.name, ctx.version });
    var plan: std.ArrayList(Action) = .empty;
    var rejected = false;
    // Plan all applicable steps before changing anything. For example, never
    // create a migration marker if another step in that migration is unsupported.
    for (steps, 1..) |step, i| {
        const action = (if (step == .object)
            planStep(a, io, root, prefix, ctx.name, keg, step.object)
        else
            error.ExpectedPostInstallObject) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try out.print("nb: {s}: post-install step {d} (", .{ ctx.name, i });
            try writePlain(out, if (step == .object) string(step.object, "type") orelse "unknown" else "unknown");
            try out.print(") skipped: {s}\n", .{@errorName(err)});
            rejected = true;
            continue;
        };
        if (action) |act| try plan.append(a, act);
    }
    if (rejected) {
        try out.print("nb: {s}: no structured post-install actions were applied\n", .{ctx.name});
        return;
    }
    // Runtime IO errors stop execution. This is not a filesystem transaction.
    for (plan.items) |action| switch (action) {
        .warn => |message| {
            try out.print("nb: {s}: post-install: ", .{ctx.name});
            try writePlain(out, message);
            try out.writeByte('\n');
        },
        .mkdir_p => |path| {
            if (within(path, keg)) {
                const keg_dir = try walk(io, root, keg, .open);
                defer keg_dir.close(io);
                (try walk(io, keg_dir, path[keg.len + 1 ..], .create)).close(io);
            } else {
                (try walk(io, root, path, .create)).close(io);
            }
        },
        .touch => |path| try touch(io, root, path),
        .symlink => |link| {
            try checkLink(io, root, prefix, link.source, link.target);
            const parent = try walk(io, root, std.fs.path.dirname(link.target).?, .open);
            defer parent.close(io);
            const leaf = std.fs.path.basename(link.target);
            const source = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, link.source });
            parent.symLink(io, source, leaf, .{}) catch |err| {
                if (err != error.PathAlreadyExists or !try sameLink(io, parent, leaf, prefix, link.source)) return err;
            };
        },
    };
}

fn planStep(a: Allocator, io: Io, root: Dir, prefix: []const u8, name: []const u8, keg: []const u8, step: Object) !?Action {
    if (step.get("guards")) |guards| {
        if (guards != .array) return error.InvalidGuard;
        var applies = true;
        for (guards.array.items) |guard| {
            if (!try evaluateGuard(a, io, root, name, keg, guard)) applies = false;
        }
        if (!applies) return null;
    }
    const kind = string(step, "type") orelse return error.MissingStepType;
    if (eql(kind, "warn")) {
        try onlyKeys(step, &.{ "type", "guards", "message" });
        return .{ .warn = string(step, "message") orelse return error.InvalidWarning };
    }
    if (eql(kind, "mkdir_p") or eql(kind, "touch")) {
        try onlyKeys(step, &.{ "type", "guards", "path" });
        const path = try resolveObject(a, name, keg, step.get("path"));
        if (within(path, keg)) (try walk(io, root, keg, .open)).close(io);
        if (eql(kind, "mkdir_p")) {
            if (!within(path, keg) and !sharedPath(path, true)) return error.PathOutsideAllowedRoots;
            // In plan mode the first missing component ends the read-only check.
            if (walk(io, root, path, .open)) |dir| dir.close(io) else |err| if (err != error.FileNotFound) return err;
            return .{ .mkdir_p = path };
        }
        if (!within(path, keg) and !sharedPath(path, false)) return error.PathOutsideAllowedRoots;
        if (try statAt(io, root, path)) |st| try checkTouch(st);
        return .{ .touch = path };
    }
    if (eql(kind, "symlink")) {
        try onlyKeys(step, &.{ "type", "guards", "source", "target", "force" });
        if (step.get("force")) |force| if (force != .bool) return error.InvalidForce;
        const source = try resolveObject(a, name, keg, step.get("source"));
        const target = try resolveObject(a, name, keg, step.get("target"));
        // Never plant links in executable/package-manager directories. Even
        // with force:true, we only create a new link or retain an identical one.
        if (!sharedPath(target, false) or (!within(source, keg) and !sharedPath(source, false)))
            return error.PathOutsideAllowedRoots;
        try checkLink(io, root, prefix, source, target);
        return .{ .symlink = .{ .source = source, .target = target } };
    }
    return error.UnsupportedStepType;
}

fn evaluateGuard(a: Allocator, io: Io, root: Dir, name: []const u8, keg: []const u8, value: Value) !bool {
    const g = if (value == .object) value.object else return error.InvalidGuard;
    if (g.get("id")) |id| if (id != .string) return error.InvalidGuard;
    const condition = string(g, "condition") orelse return error.InvalidGuard;
    if (eql(condition, "on")) {
        try onlyKeys(g, &.{ "condition", "value", "id" });
        const os = string(g, "value") orelse return error.InvalidGuard;
        if (eql(os, "macos")) return builtin.os.tag == .macos;
        if (eql(os, "linux")) return builtin.os.tag == .linux;
        return error.UnsupportedGuardPlatform;
    }
    if (eql(condition, "if_exists") or eql(condition, "unless_exists")) {
        try onlyKeys(g, &.{ "condition", "base", "path", "id" });
        const path = try resolve(a, name, keg, g);
        if (!within(path, keg) and !sharedPath(path, true)) return error.PathOutsideAllowedRoots;
        // All guards read pre-install state. A symlink is not a usable guard:
        // refusing it avoids both following it and treating it as missing.
        const stat = try statAt(io, root, path);
        if (stat) |st| if (st.kind == .sym_link) return error.SymlinkNotAllowed;
        return (stat != null) == eql(condition, "if_exists");
    }
    return error.UnsupportedGuard;
}

fn resolveObject(a: Allocator, name: []const u8, keg: []const u8, value: ?Value) ![]const u8 {
    const v = value orelse return error.ExpectedPathObject;
    if (v != .object) return error.ExpectedPathObject;
    try onlyKeys(v.object, &.{ "base", "path" });
    return resolve(a, name, keg, v.object);
}

fn resolve(a: Allocator, name: []const u8, keg: []const u8, obj: Object) ![]const u8 {
    var path = string(obj, "path") orelse return error.InvalidPath;
    const base = if (obj.get("base")) |v| b: {
        if (v != .string) return error.InvalidPathBase;
        break :b v.string;
    } else b: {
        if (!std.mem.startsWith(u8, path, "{{")) return error.InvalidPath;
        const end = std.mem.indexOf(u8, path, "}}") orelse return error.InvalidPath;
        const token = path[2..end];
        path = path[end + 2 ..];
        if (path.len != 0) {
            if (path[0] != '/' or path.len == 1) return error.InvalidPath;
            path = path[1..];
        }
        break :b if (eql(token, "HOMEBREW_PREFIX")) "homebrew_prefix" else token;
    };
    if (path.len == 0 and obj.contains("base")) return error.InvalidPath;
    if (path.len > Dir.max_path_bytes) return error.InvalidPath;
    if (path.len != 0) {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| if (!validComponent(part)) return error.InvalidPath;
    }
    const dir = if (eql(base, "homebrew_prefix")) "" else if (eql(base, "prefix")) keg else if (eql(base, "etc") or eql(base, "var")) base else if (eql(base, "pkgetc"))
        try std.fmt.allocPrint(a, "etc/{s}", .{name})
    else if (eql(base, "pkgshare"))
        try std.fmt.allocPrint(a, "{s}/share/{s}", .{ keg, name })
    else if (oneOf(base, &.{ "bin", "sbin", "lib", "libexec", "share", "frameworks", "include" }))
        try std.fmt.allocPrint(a, "{s}/{s}", .{ keg, if (eql(base, "frameworks")) "Frameworks" else base })
    else
        return error.UnsupportedPathBase;
    if (dir.len == 0) return path;
    if (path.len == 0) return dir;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, path });
}

fn within(path: []const u8, base: []const u8) bool {
    return path.len > base.len and path[base.len] == '/' and std.mem.startsWith(u8, path, base);
}

fn sharedPath(path: []const u8, allow_lib_share: bool) bool {
    return within(path, "etc") or within(path, "var") or (allow_lib_share and (within(path, "lib") or within(path, "share")));
}

fn validComponent(part: []const u8) bool {
    if (part.len == 0 or part.len > 255 or eql(part, ".") or eql(part, "..")) return false;
    for (part) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._+@-", c) == null) return false;
    }
    return true;
}

fn walk(io: Io, root: Dir, path: []const u8, mode: enum { open, create }) !Dir {
    // Every open receives exactly one validated component. Never check a
    // path and then resolve it again through a multi-component pathname.
    var current = try root.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (!validComponent(part)) return error.InvalidPath;
        const next = current.openDir(io, part, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or mode != .create) return err;
            current.createDir(io, part, .default_dir) catch |mkdir_err| if (mkdir_err != error.PathAlreadyExists) return mkdir_err;
            break :blk try current.openDir(io, part, .{ .follow_symlinks = false });
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn statAt(io: Io, root: Dir, path: []const u8) !?Io.File.Stat {
    const parent = walk(io, root, std.fs.path.dirname(path).?, .open) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer parent.close(io);
    return parent.statFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
}

fn checkTouch(st: Io.File.Stat) !void {
    if (st.kind != .file or st.nlink != 1) return error.UnsafeTouchTarget;
}

fn touch(io: Io, root: Dir, path: []const u8) !void {
    if (!supported_os) return error.UnsupportedPlatform;
    const parent = try walk(io, root, std.fs.path.dirname(path).?, .open);
    defer parent.close(io);
    const leaf = std.fs.path.basename(path);
    if (parent.createFile(io, leaf, .{ .exclusive = true, .truncate = false })) |created| {
        created.close(io);
        return;
    } else |err| if (err != error.PathAlreadyExists) return err;
    try checkTouch(try parent.statFile(io, leaf, .{ .follow_symlinks = false }));
    // Nonblocking and nofollow even if the leaf changed since stat; verify the
    // opened inode, not the pathname, before changing its timestamps.
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..leaf.len], leaf);
    buf[leaf.len] = 0;
    const fd = std.c.openat(parent.handle, buf[0..leaf.len :0].ptr, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true });
    if (fd < 0) return error.CannotOpenTouchTarget;
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    try checkTouch(try file.stat(io));
    try file.setTimestampsNow(io);
}

fn checkLink(io: Io, root: Dir, prefix: []const u8, source: []const u8, target: []const u8) !void {
    const st = try statAt(io, root, source) orelse return error.LinkSourceMissing;
    if (st.kind != .file and st.kind != .directory) return error.UnsafeLinkSource;
    if (try statAt(io, root, target)) |dst| {
        if (dst.kind != .sym_link) return error.LinkReplacementUnsupported;
        const parent = try walk(io, root, std.fs.path.dirname(target).?, .open);
        defer parent.close(io);
        if (!try sameLink(io, parent, std.fs.path.basename(target), prefix, source)) return error.LinkReplacementUnsupported;
    }
}

fn sameLink(io: Io, parent: Dir, leaf: []const u8, prefix: []const u8, source: []const u8) !bool {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const n = try parent.readLink(io, leaf, &buf);
    return n == prefix.len + 1 + source.len and eql(buf[0..prefix.len], prefix) and buf[prefix.len] == '/' and eql(buf[prefix.len + 1 .. n], source);
}

fn onlyKeys(obj: Object, keys: []const []const u8) !void {
    for (obj.keys()) |key| if (!oneOf(key, keys)) return error.UnsupportedStepField;
}

fn string(obj: Object, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn oneOf(s: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (eql(s, choice)) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writePlain(out: *Io.Writer, text: []const u8) !void {
    for (text[0..@min(text.len, 1024)]) |byte| try out.writeByte(if (std.ascii.isPrint(byte)) byte else '?');
    if (text.len > 1024) try out.writeAll("...");
}

const testing = std.testing;
const test_context: Context = .{ .name = "demo", .version = "1.0_2" };

fn runFixture(dir: Dir, json: []const u8, out: *Io.Writer) !void {
    var prefix: [Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(testing.io, &prefix);
    try run(testing.allocator, testing.io, prefix[0..n], test_context, json, out);
}

test "structured native steps use confined paths and evaluate guards before writes" {
    if (!supported_os) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "Cellar/demo/1.0_2/share/demo");
    (try tmp.dir.createFile(io, "Cellar/demo/1.0_2/share/demo/conf", .{})).close(io);
    var log: Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const steps =
        \\[
        \\ {"type":"mkdir_p","path":{"base":"var","path":"lib/demo"}},
        \\ {"type":"touch","path":{"path":"{{var}}/lib/demo/marker"},"guards":[{"condition":"unless_exists","base":"var","path":"lib/demo/marker","id":"1"}]},
        \\ {"type":"symlink","source":{"path":"{{pkgshare}}/conf"},"target":{"path":"{{var}}/lib/demo/conf"},"force":true},
        \\ {"type":"mkdir_p","path":{"path":"{{HOMEBREW_PREFIX}}/lib/demo/modules"}},
        \\ {"type":"warn","message":"created\u001b[31m","guards":[{"condition":"unless_exists","base":"var","path":"lib/demo/marker","id":"1"}]},
        \\ {"type":"warn","message":"pre-existing","guards":[{"condition":"if_exists","path":"{{pkgshare}}/conf","id":"2"}]}
        \\]
    ;
    try runFixture(tmp.dir, steps, &log.writer);
    try testing.expectEqualStrings("nb: demo: post-install: created?[31m\nnb: demo: post-install: pre-existing\n", log.written());
    const marker = try tmp.dir.statFile(io, "var/lib/demo/marker", .{});
    try testing.expectEqual(Io.File.Kind.file, marker.kind);
    const link = try tmp.dir.statFile(io, "var/lib/demo/conf", .{ .follow_symlinks = false });
    try testing.expectEqual(Io.File.Kind.sym_link, link.kind);
    try tmp.dir.access(io, "var/lib/demo/conf", .{});
    try tmp.dir.access(io, "lib/demo/modules", .{});
    try runFixture(tmp.dir, steps, &log.writer); // does not replace an identical link
    try testing.expectEqualStrings("nb: demo: post-install: created?[31m\nnb: demo: post-install: pre-existing\nnb: demo: post-install: pre-existing\n", log.written());
    // Also exercise the existing regular-file path: touch does not truncate.
    try tmp.dir.writeFile(io, .{ .sub_path = "var/lib/demo/marker", .data = "existing" });
    try runFixture(tmp.dir,
        \\[{"type":"touch","path":{"base":"var","path":"lib/demo/marker"}}]
    , &log.writer);
    try testing.expectEqual(@as(u64, 8), (try tmp.dir.statFile(io, "var/lib/demo/marker", .{})).size);
}

test "structured unknown actions and malformed paths reject the whole applicable batch" {
    if (!supported_os) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const steps =
        \\[
        \\ {"type":"mkdir_p","path":{"base":"var","path":"not-created"}},
        \\ {"type":"run","command":{"base":"bin","path":"tool"},"args":["https://example.invalid"]},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"../../elsewhere"}},
        \\ {"type":"mkdir_p","path":{"path":"/etc/no"}},
        \\ {"type":"mkdir_p","path":{"path":"{{HOMEBREW_PREFIX}}/Cellar/another/1.0/conf"}},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"bad\u0000name"}},
        \\ {"type":"mkdir_p","path":{"path":"{{opt_prefix}}/test"}},
        \\ {"type":"touch","path":{"base":"var","path":"other"},"unknown":false}
        \\]
    ;
    try runFixture(tmp.dir, steps, &log.writer);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "var", .{}));
    try testing.expect(std.mem.indexOf(u8, log.written(), "(run) skipped: UnsupportedStepType") != null);
    try testing.expect(std.mem.indexOf(u8, log.written(), "no structured post-install actions were applied") != null);
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, log.written(), "\n"));
    try testing.expectError(error.ExpectedPostInstallArray, runFixture(tmp.dir, "null", &log.writer));
    try runFixture(tmp.dir, "[]", &log.writer);
}

test "structured steps refuse symlink traversal, hardlinked touch, and link replacement" {
    if (!supported_os) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "prefix/var");
    try tmp.dir.createDirPath(io, "outside");
    var prefix = try tmp.dir.openDir(io, "prefix", .{});
    defer prefix.close(io);
    (try tmp.dir.createFile(io, "outside/existing", .{})).close(io);
    (try prefix.createFile(io, "var/source", .{})).close(io);
    try prefix.symLink(io, "../../outside", "var/jump", .{ .is_directory = true });
    try prefix.symLink(io, "../../outside/existing", "var/leaf", .{});
    try tmp.dir.hardLink("outside/existing", prefix, "var/hard", io, .{});
    var log: Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const steps =
        \\[
        \\ {"type":"touch","path":{"base":"var","path":"marker"}},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"jump/escaped"}},
        \\ {"type":"touch","path":{"base":"var","path":"leaf"}},
        \\ {"type":"touch","path":{"base":"var","path":"hard"}},
        \\ {"type":"symlink","source":{"base":"var","path":"jump/existing"},"target":{"base":"var","path":"escaped-link"}},
        \\ {"type":"symlink","source":{"base":"var","path":"source"},"target":{"base":"var","path":"jump/outside-link"}},
        \\ {"type":"symlink","source":{"base":"var","path":"source"},"target":{"base":"var","path":"leaf"},"force":true},
        \\ {"type":"warn","message":"bad guard","guards":[{"condition":"unless_exists","base":"var","path":"leaf"}]}
        \\]
    ;
    try runFixture(prefix, steps, &log.writer);
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, log.written(), "\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, log.written(), "UnsafeTouchTarget"));
    try testing.expect(std.mem.indexOf(u8, log.written(), "LinkReplacementUnsupported") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "outside/escaped", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "outside/outside-link", .{}));
    try testing.expectError(error.FileNotFound, prefix.access(io, "var/marker", .{}));
    try testing.expectError(error.FileNotFound, prefix.access(io, "var/escaped-link", .{}));
    try testing.expectEqual(Io.File.Kind.sym_link, (try prefix.statFile(io, "var/leaf", .{ .follow_symlinks = false })).kind);
}

test "structured steps skip actions guarded for a different OS" {
    if (!supported_os) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const other = if (builtin.os.tag == .macos) "linux" else "macos";
    var log: Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    try runFixture(tmp.dir,
        \\[{"type":"run","guards":[{"condition":"on","value":"
    ++ other ++
        \\"}]},{"type":"mkdir_p","path":{"base":"var","path":"foo"}}]
    , &log.writer);
    try testing.expectEqualStrings("", log.written());
    try tmp.dir.access(testing.io, "var/foo", .{});
}
