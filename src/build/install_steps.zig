// nanobrew — Homebrew `post_install_steps` (#493).
//
// The Homebrew API stopped setting `post_install_defined` and describes a
// formula's post-install actions as a JSON array instead, for example
//   {"type":"run","command":{"base":"bin","path":"fc-cache"},"args":["--force"]}
// This file runs a small, checked subset of those steps without a shell and
// without any Ruby: argv only, every path resolved from the step's `base` and
// `{{token}}` templates against nanobrew's own prefix.
//
// Supported: mkdir_p, touch, symlink, warn, and run when the command is a
// file inside the formula's own keg. Guards: `on` (macos/linux), if_exists
// and unless_exists (with `{a,b}` alternatives). Anything else — another
// step type, an unknown base or template, a glob, `..`, a write outside the
// prefix, or run options such as env/chdir/stdin_path/stdout_path/sudo — is
// not run. If any step that applies on this OS is not supported, none of
// the steps run (they are one sequence), and nanobrew says which and why.
//
// The JSON comes from the same formula metadata that names the bottle and
// its sha256, so it is trusted as much as the bottle is. `run` only executes
// files from that verified keg; writes stay under the prefix.

const std = @import("std");
const builtin = @import("builtin");

pub const Env = struct {
    /// HOMEBREW_PREFIX, e.g. /opt/nanobrew/prefix.
    prefix: []const u8,
    /// HOMEBREW_CELLAR.
    cellar: []const u8,
    /// This keg, <cellar>/<name>/<version>[_<revision>].
    keg: []const u8,
    name: []const u8,
    /// Formula version without the revision suffix.
    version: []const u8,
    user: ?[]const u8 = null,
    os: Os = native_os,
};

pub const Os = enum { macos, linux, other };
pub const native_os: Os = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    else => .other,
};

pub const Action = union(enum) {
    mkdir_p: []const u8,
    touch: []const u8,
    symlink: struct { source: []const u8, target: []const u8, force: bool },
    warn: []const u8,
    run: struct { argv: []const []const u8, allow_failure: bool },
};

pub const Step = struct {
    type_name: []const u8,
    guards: []const std.json.Value,
    /// The action, or why the step is not run.
    plan: union(enum) { action: Action, unsupported: []const u8 },
};

/// Resolve every step. Allocations live in `arena`.
pub fn plan(arena: std.mem.Allocator, steps_json: []const u8, env: Env) ![]Step {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, steps_json, .{});
    if (parsed != .array) return error.InvalidSteps;
    var out: std.ArrayList(Step) = .empty;
    for (parsed.array.items) |item| {
        try out.append(arena, planStep(arena, item, env));
    }
    return out.toOwnedSlice(arena);
}

fn planStep(arena: std.mem.Allocator, item: std.json.Value, env: Env) Step {
    var step: Step = .{ .type_name = "?", .guards = &.{}, .plan = .{ .unsupported = "not an object" } };
    if (item != .object) return step;
    const obj = item.object;
    step.type_name = str(obj, "type") orelse return step;
    if (obj.get("guards")) |g| {
        if (g != .array) {
            step.plan = .{ .unsupported = "guards is not a list" };
            return step;
        }
        step.guards = g.array.items;
        for (step.guards) |guard| {
            if (guardProblem(guard)) |why| {
                step.plan = .{ .unsupported = why };
                return step;
            }
        }
    }
    step.plan = if (resolveAction(arena, obj, step.type_name, env)) |a| .{ .action = a } else |err| .{ .unsupported = reason(err) };
    return step;
}

const PlanError = error{
    OutOfMemory,
    UnsupportedType,
    UnsupportedOption,
    UnknownBase,
    UnknownTemplate,
    RelativePath,
    ParentComponent,
    Glob,
    OutsidePrefix,
    OutsideKeg,
    BadStep,
    NoUser,
};

fn reason(err: PlanError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.UnsupportedType => "step type is not supported by nanobrew yet",
        error.UnsupportedOption => "step uses an option nanobrew does not support",
        error.UnknownBase => "unknown path base",
        error.UnknownTemplate => "unknown {{template}}",
        error.RelativePath => "path is not absolute",
        error.ParentComponent => "path contains '..'",
        error.Glob => "path globs are not supported",
        error.OutsidePrefix => "writes outside the nanobrew prefix",
        error.OutsideKeg => "command is not inside the formula's keg",
        error.BadStep => "malformed step",
        error.NoUser => "{{user}} needs $USER",
    };
}

/// Keys each supported type may carry. Any other key is refused, so a new
/// option Homebrew adds is never silently ignored.
fn allowedKeys(type_name: []const u8) ?[]const []const u8 {
    const t = std.mem.eql;
    if (t(u8, type_name, "mkdir_p") or t(u8, type_name, "touch")) return &.{ "type", "guards", "path" };
    if (t(u8, type_name, "symlink")) return &.{ "type", "guards", "source", "target", "force", "overwrite" };
    if (t(u8, type_name, "warn")) return &.{ "type", "guards", "message" };
    if (t(u8, type_name, "run")) return &.{ "type", "guards", "command", "args", "allow_failure", "print_stdout", "suppress_stderr", "network_access", "sudo" };
    return null;
}

fn resolveAction(arena: std.mem.Allocator, obj: std.json.ObjectMap, type_name: []const u8, env: Env) PlanError!Action {
    const allowed = allowedKeys(type_name) orelse return error.UnsupportedType;
    var it = obj.iterator();
    while (it.next()) |entry| {
        for (allowed) |k| {
            if (std.mem.eql(u8, k, entry.key_ptr.*)) break;
        } else return error.UnsupportedOption;
    }
    if (std.mem.eql(u8, type_name, "mkdir_p")) {
        return .{ .mkdir_p = try writablePath(arena, obj.get("path") orelse return error.BadStep, env) };
    }
    if (std.mem.eql(u8, type_name, "touch")) {
        return .{ .touch = try writablePath(arena, obj.get("path") orelse return error.BadStep, env) };
    }
    if (std.mem.eql(u8, type_name, "warn")) {
        const msg = str(obj, "message") orelse return error.BadStep;
        return .{ .warn = try expand(arena, msg, env) };
    }
    if (std.mem.eql(u8, type_name, "symlink")) {
        const source_spec = obj.get("source") orelse return error.BadStep;
        const source = if (specBase(source_spec)) |b| blk: {
            if (std.mem.eql(u8, b, "relative")) {
                // A relative link text is stored as is; it is not a write.
                const p = try expand(arena, specPath(source_spec) orelse return error.BadStep, env);
                if (hasGlob(p)) return error.Glob;
                break :blk p;
            }
            break :blk try resolvePath(arena, source_spec, env);
        } else try resolvePath(arena, source_spec, env);
        return .{ .symlink = .{
            .source = source,
            .target = try writablePath(arena, obj.get("target") orelse return error.BadStep, env),
            .force = boolean(obj, "force") or boolean(obj, "overwrite"),
        } };
    }
    // run
    if (obj.get("sudo")) |s| if (!(s == .bool and !s.bool)) return error.UnsupportedOption;
    if (obj.get("network_access")) |n| if (n != .bool) return error.BadStep;
    const command = try resolvePath(arena, obj.get("command") orelse return error.BadStep, env);
    if (!under(command, env.keg)) return error.OutsideKeg;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, command);
    if (obj.get("args")) |args| {
        if (args != .array) return error.BadStep;
        for (args.array.items) |a| {
            if (a != .string) return error.BadStep;
            try argv.append(arena, try expand(arena, a.string, env));
        }
    }
    return .{ .run = .{ .argv = try argv.toOwnedSlice(arena), .allow_failure = boolean(obj, "allow_failure") } };
}

fn writablePath(arena: std.mem.Allocator, spec: std.json.Value, env: Env) PlanError![]const u8 {
    const p = try resolvePath(arena, spec, env);
    if (!under(p, env.prefix)) return error.OutsidePrefix;
    return p;
}

fn specBase(spec: std.json.Value) ?[]const u8 {
    if (spec != .object) return null;
    const b = str(spec.object, "base") orelse return null;
    return if (b.len == 0) null else b;
}

fn specPath(spec: std.json.Value) ?[]const u8 {
    if (spec != .object) return null;
    return str(spec.object, "path");
}

/// `{"base": B, "path": P}` or `{"path": "/abs/{{token}}/x"}` to an absolute
/// path. Refuses globs and `..`.
pub fn resolvePath(arena: std.mem.Allocator, spec: std.json.Value, env: Env) PlanError![]const u8 {
    if (spec != .object) return error.BadStep;
    var keys = spec.object.iterator();
    while (keys.next()) |e| {
        const k = e.key_ptr.*;
        if (!std.mem.eql(u8, k, "path") and !std.mem.eql(u8, k, "base")) return error.UnsupportedOption;
    }
    const raw = specPath(spec) orelse return error.BadStep;
    return resolveExpanded(arena, specBase(spec), try expand(arena, raw, env), env);
}

fn resolveExpanded(arena: std.mem.Allocator, base: ?[]const u8, path: []const u8, env: Env) PlanError![]const u8 {
    if (hasGlob(path)) return error.Glob;
    const full = if (base) |b| blk: {
        if (std.mem.eql(u8, b, "absolute")) break :blk path;
        const root = (try baseDir(arena, b, env)) orelse return error.UnknownBase;
        if (path.len == 0) break :blk root;
        if (path[0] == '/') return error.BadStep;
        break :blk try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, path });
    } else path;
    if (full.len == 0 or full[0] != '/') return error.RelativePath;
    var parts = std.mem.splitScalar(u8, full, '/');
    while (parts.next()) |c| if (std.mem.eql(u8, c, "..")) return error.ParentComponent;
    return full;
}

/// Formula path methods, as in Homebrew's formula.rb. etc and var are the
/// prefix's, the rest are the keg's.
fn baseDir(arena: std.mem.Allocator, b: []const u8, env: Env) !?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, b, "homebrew_prefix") or eq(u8, b, "HOMEBREW_PREFIX")) return env.prefix;
    if (eq(u8, b, "HOMEBREW_CELLAR")) return env.cellar;
    if (eq(u8, b, "prefix")) return env.keg;
    if (eq(u8, b, "opt_prefix")) return try std.fmt.allocPrint(arena, "{s}/opt/{s}", .{ env.prefix, env.name });
    if (eq(u8, b, "etc")) return try std.fmt.allocPrint(arena, "{s}/etc", .{env.prefix});
    if (eq(u8, b, "var")) return try std.fmt.allocPrint(arena, "{s}/var", .{env.prefix});
    if (eq(u8, b, "pkgetc")) return try std.fmt.allocPrint(arena, "{s}/etc/{s}", .{ env.prefix, env.name });
    if (eq(u8, b, "pkgshare")) return try std.fmt.allocPrint(arena, "{s}/share/{s}", .{ env.keg, env.name });
    if (eq(u8, b, "frameworks")) return try std.fmt.allocPrint(arena, "{s}/Frameworks", .{env.keg});
    if (eq(u8, b, "bash_completion")) return try std.fmt.allocPrint(arena, "{s}/etc/bash_completion.d", .{env.keg});
    if (eq(u8, b, "zsh_completion")) return try std.fmt.allocPrint(arena, "{s}/share/zsh/site-functions", .{env.keg});
    if (eq(u8, b, "fish_completion")) return try std.fmt.allocPrint(arena, "{s}/share/fish/vendor_completions.d", .{env.keg});
    if (eq(u8, b, "pwsh_completion")) return try std.fmt.allocPrint(arena, "{s}/share/pwsh/completions", .{env.keg});
    inline for (.{ "bin", "sbin", "lib", "libexec", "share", "include" }) |sub| {
        if (eq(u8, b, sub)) return try std.fmt.allocPrint(arena, "{s}/" ++ sub, .{env.keg});
    }
    return null;
}

/// Replace `{{token}}`. An unknown token is an error, not left in place.
pub fn expand(arena: std.mem.Allocator, s: []const u8, env: Env) PlanError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, s, open + 2, "}}") orelse return error.UnknownTemplate;
        try out.appendSlice(arena, s[i..open]);
        try out.appendSlice(arena, try token(arena, s[open + 2 .. close], env));
        i = close + 2;
    }
    try out.appendSlice(arena, s[i..]);
    return out.toOwnedSlice(arena);
}

fn token(arena: std.mem.Allocator, t: []const u8, env: Env) PlanError![]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, t, "formula_name") or eq(u8, t, "name")) return env.name;
    if (eq(u8, t, "version")) return env.version;
    if (eq(u8, t, "version.major")) return versionPrefix(env.version, 1);
    if (eq(u8, t, "version.major_minor")) return versionPrefix(env.version, 2);
    if (eq(u8, t, "user")) return env.user orelse error.NoUser;
    if (eq(u8, t, "homebrew_prefix")) return error.UnknownTemplate;
    return (try baseDir(arena, t, env)) orelse error.UnknownTemplate;
}

/// "3.13.1" -> "3" (n=1) or "3.13" (n=2).
fn versionPrefix(v: []const u8, n: usize) []const u8 {
    var dots: usize = 0;
    for (v, 0..) |c, i| {
        if (c == '.') {
            dots += 1;
            if (dots == n) return v[0..i];
        }
    }
    return v;
}

fn hasGlob(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "*?[{") != null;
}

fn under(p: []const u8, root: []const u8) bool {
    return p.len > root.len and std.mem.startsWith(u8, p, root) and p[root.len] == '/';
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolean(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn guardProblem(guard: std.json.Value) ?[]const u8 {
    if (guard != .object) return "malformed guard";
    const cond = str(guard.object, "condition") orelse return "malformed guard";
    if (std.mem.eql(u8, cond, "on")) {
        const v = str(guard.object, "value") orelse return "malformed guard";
        if (!std.mem.eql(u8, v, "macos") and !std.mem.eql(u8, v, "linux")) return "unknown 'on' guard";
        return null;
    }
    if (std.mem.eql(u8, cond, "if_exists") or std.mem.eql(u8, cond, "unless_exists")) return null;
    return "unknown guard condition";
}

/// Evaluate a guard. Paths may use `{a,b}` alternatives (one group).
pub fn guardMatches(arena: std.mem.Allocator, io: std.Io, guard: std.json.Value, env: Env) PlanError!bool {
    const obj = guard.object;
    const cond = str(obj, "condition").?;
    if (std.mem.eql(u8, cond, "on")) {
        const v = str(obj, "value").?;
        return (env.os == .macos and std.mem.eql(u8, v, "macos")) or (env.os == .linux and std.mem.eql(u8, v, "linux"));
    }
    const raw = str(obj, "path") orelse return error.BadStep;
    const expanded = try expand(arena, raw, env);
    var exists = false;
    var alternatives: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, expanded, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, expanded, open, '}') orelse return error.Glob;
        if (std.mem.indexOfAny(u8, expanded[close + 1 ..], "{}") != null) return error.Glob;
        var opts = std.mem.splitScalar(u8, expanded[open + 1 .. close], ',');
        while (opts.next()) |o| try alternatives.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ expanded[0..open], o, expanded[close + 1 ..] }));
    } else try alternatives.append(arena, expanded);
    const base: ?[]const u8 = if (str(obj, "base")) |b| (if (b.len == 0) null else b) else null;
    for (alternatives.items) |alt| {
        const p = try resolveExpanded(arena, base, alt, env);
        if (std.Io.Dir.accessAbsolute(io, p, .{})) |_| {
            exists = true;
        } else |_| {}
    }
    return if (std.mem.eql(u8, cond, "if_exists")) exists else !exists;
}

/// True when an `on` guard says the step is for another OS.
pub fn excludedOnThisOs(step: Step, env: Env) bool {
    for (step.guards) |g| {
        if (g != .object) continue;
        const cond = str(g.object, "condition") orelse continue;
        if (!std.mem.eql(u8, cond, "on")) continue;
        const v = str(g.object, "value") orelse continue;
        const match = (env.os == .macos and std.mem.eql(u8, v, "macos")) or (env.os == .linux and std.mem.eql(u8, v, "linux"));
        if (!match) return true;
    }
    return false;
}

pub const Outcome = struct { ran: usize = 0, skipped: usize = 0, failed: usize = 0 };

/// Run the steps and print one line per skipped or failed step.
pub fn runAll(alloc: std.mem.Allocator, io: std.Io, steps_json: []const u8, env: Env, out: anytype) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const steps = try plan(arena, steps_json, env);
    var result: Outcome = .{};
    // All or nothing: the steps are one sequence (back up, then migrate,
    // then mark done), so running only the supported part could leave a
    // half-done state that the guards later treat as finished. A step that
    // an `on` guard rules out on this OS does not count.
    for (steps, 0..) |step, idx| {
        switch (step.plan) {
            .action => {},
            .unsupported => |why| if (!excludedOnThisOs(step, env)) {
                result.skipped += 1;
                out.print("nb: {s}: post-install step {d} ({s}) is not supported: {s}\n", .{ env.name, idx + 1, step.type_name, why }) catch {};
            },
        }
    }
    if (result.skipped > 0) {
        out.print("nb: {s}: post-install not run, because nanobrew cannot run all of its steps yet; the formula may need them done by hand\n", .{env.name}) catch {};
        return result;
    }
    var guard_cache: std.StringHashMapUnmanaged(bool) = .empty;
    steps: for (steps, 0..) |step, idx| {
        const action = switch (step.plan) {
            .action => |a| a,
            .unsupported => continue, // ruled out on this OS
        };
        for (step.guards) |guard| {
            // Homebrew evaluates each distinct guard once per run.
            const key = std.json.Stringify.valueAlloc(arena, guard, .{}) catch return error.OutOfMemory;
            const ok = guard_cache.get(key) orelse blk: {
                const m = guardMatches(arena, io, guard, env) catch |err| {
                    result.skipped += 1;
                    out.print("nb: {s}: post-install step {d} ({s}) not run: {s}\n", .{ env.name, idx + 1, step.type_name, reason(err) }) catch {};
                    continue :steps;
                };
                try guard_cache.put(arena, key, m);
                break :blk m;
            };
            if (!ok) continue :steps;
        }
        const ok = execute(arena, io, action, out);
        if (ok) result.ran += 1 else {
            result.failed += 1;
            out.print("nb: {s}: post-install step {d} ({s}) failed\n", .{ env.name, idx + 1, step.type_name }) catch {};
        }
    }
    return result;
}

fn execute(arena: std.mem.Allocator, io: std.Io, action: Action, out: anytype) bool {
    switch (action) {
        .warn => |msg| {
            out.print("Warning: {s}\n", .{msg}) catch {};
            return true;
        },
        .mkdir_p => |p| return runArgv(arena, io, &.{ "mkdir", "-p", p }, false),
        .touch => |p| return runArgv(arena, io, &.{ "touch", p }, false),
        .symlink => |l| {
            const dir = std.fs.path.dirname(l.target) orelse return false;
            if (!runArgv(arena, io, &.{ "mkdir", "-p", dir }, false)) return false;
            // -n: replace a link to a directory instead of linking inside it.
            const flags: []const u8 = if (l.force) "-sfn" else "-s";
            return runArgv(arena, io, &.{ "ln", flags, l.source, l.target }, false);
        },
        .run => |r| return runArgv(arena, io, r.argv, true) or r.allow_failure,
    }
}

fn runArgv(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, show_stderr: bool) bool {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return false;
    const ok = result.term == .exited and result.term.exited == 0;
    if (!ok and show_stderr and result.stderr.len > 0) {
        std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
    }
    return ok;
}

/// Line printer for `runAll` that writes to stderr.
pub const Stderr = struct {
    io: std.Io,
    pub fn print(self: Stderr, comptime fmt: []const u8, args: anytype) !void {
        var buf: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, line) catch {};
    }
};

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const test_env: Env = .{
    .prefix = "/opt/nanobrew/prefix",
    .cellar = "/opt/nanobrew/prefix/Cellar",
    .keg = "/opt/nanobrew/prefix/Cellar/demo/3.13.1_2",
    .name = "demo",
    .version = "3.13.1",
    .user = "rach",
    .os = .linux,
};

fn planOne(arena: std.mem.Allocator, json: []const u8, env: Env) !Step {
    const steps = try plan(arena, json, env);
    try testing.expectEqual(@as(usize, 1), steps.len);
    return steps[0];
}

fn expectUnsupported(json: []const u8, why: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const step = try planOne(arena.allocator(), json, test_env);
    try testing.expectEqualStrings(why, step.plan.unsupported);
}

// Step JSON below is copied from formulae.brew.sh/api/formula.json (6 Nov 2026).

test "post_install_steps: real run steps resolve to argv in the keg (#493)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // fontconfig
    const fc = try planOne(a,
        \\[{"command":{"base":"bin","path":"fc-cache"},"type":"run","args":["--force","--really-force","--verbose"]}]
    , test_env);
    const argv = fc.plan.action.run.argv;
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/demo/3.13.1_2/bin/fc-cache", argv[0]);
    try testing.expectEqualStrings("--really-force", argv[2]);
    // ca-certificates: pkgshare is the keg's, pkgetc the prefix's.
    const ca = try planOne(a,
        \\[{"command":{"base":"libexec","path":"post-install"},"type":"run","args":["{{pkgshare}}/cacert.pem","{{pkgetc}}/cert.pem"]}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/demo/3.13.1_2/libexec/post-install", ca.plan.action.run.argv[0]);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/demo/3.13.1_2/share/demo/cacert.pem", ca.plan.action.run.argv[1]);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/etc/demo/cert.pem", ca.plan.action.run.argv[2]);
    // tzdb: {{etc}} in an argument.
    const tz = try planOne(a,
        \\[{"command":{"base":"sbin","path":"zic"},"type":"run","args":["-l","Factory","-p","-","-t","{{etc}}/localtime"]}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/etc/localtime", tz.plan.action.run.argv[6]);
}

test "post_install_steps: real path steps and templates (#493)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // openssl@3 / gnutls / libressl
    const link = try planOne(a,
        \\[{"source":{"path":"{{etc}}/ca-certificates/cert.pem"},"target":{"path":"{{pkgetc}}/cert.pem"},"force":true,"type":"symlink"}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/etc/ca-certificates/cert.pem", link.plan.action.symlink.source);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/etc/demo/cert.pem", link.plan.action.symlink.target);
    try testing.expect(link.plan.action.symlink.force);
    // openssh
    const touch = try planOne(a,
        \\[{"path":{"base":"var","path":"lib/openssh/host-keys-migrated-v1"},"guards":[{"base":"var","path":"lib/openssh/host-keys-migrated-v1","condition":"unless_exists","id":"1"}],"type":"touch"}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/var/lib/openssh/host-keys-migrated-v1", touch.plan.action.touch);
    try testing.expectEqual(@as(usize, 1), touch.guards.len);
    // python-style version templates
    const mk = try planOne(a,
        \\[{"path":{"base":"homebrew_prefix","path":"lib/python{{version.major_minor}}/site-packages"},"type":"mkdir_p"}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/lib/python3.13/site-packages", mk.plan.action.mkdir_p);
}

test "post_install_steps: unsupported forms are refused, not guessed (#493)" {
    // glib-networking: a command from another formula.
    try expectUnsupported(
        \\[{"command":{"path":"{{HOMEBREW_PREFIX}}/opt/glib/bin/gio-querymodules"},"type":"run","args":["{{HOMEBREW_PREFIX}}/lib/gio/modules"]}]
    , "command is not inside the formula's keg");
    // janet: env and chdir.
    try expectUnsupported(
        \\[{"command":{"base":"bin","path":"janet"},"chdir":{"path":"{{libexec}}/jpm"},"type":"run","args":["bootstrap.janet"],"env":{"PREFIX":"{{prefix}}"}}]
    , "step uses an option nanobrew does not support");
    // gtk+3: stdout_path.
    try expectUnsupported(
        \\[{"command":{"base":"bin","path":"gtk-query-immodules-3.0"},"stdout_path":{"path":"{{HOMEBREW_PREFIX}}/lib/gtk-3.0/3.0.0/immodules.cache"},"type":"run"}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"type":"compile_gsettings_schemas","path":{"base":"homebrew_prefix","path":"share/glib-2.0/schemas"}}]
    , "step type is not supported by nanobrew yet");
    try expectUnsupported(
        \\[{"source":{"base":"prefix","path":"lib/*.dylib"},"target":{"base":"homebrew_prefix","path":"lib"},"force":true,"source_glob":true,"type":"symlink"}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"path":{"path":"{{HOMEBREW_PREFIX}}/share/{{mystery}}/x"},"type":"touch"}]
    , "unknown {{template}}");
    try expectUnsupported(
        \\[{"path":{"base":"var","path":"../../../../etc/passwd"},"type":"touch"}]
    , "path contains '..'");
    try expectUnsupported(
        \\[{"path":{"path":"/etc/demo.conf"},"type":"touch"}]
    , "writes outside the nanobrew prefix");
    try expectUnsupported(
        \\[{"path":{"base":"nowhere","path":"x"},"type":"mkdir_p"}]
    , "unknown path base");
    try expectUnsupported(
        \\[{"command":{"base":"bin","path":"tool"},"type":"run","sudo":true}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"message":"x","guards":[{"condition":"on","value":"windows"}],"type":"warn"}]
    , "unknown 'on' guard");
}

test "post_install_steps: run in a scratch prefix, with guards (#493)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Cellar/demo/1.0/bin");
    {
        // The keg's tool records its arguments.
        var f = try tmp.dir.createFile(io, "Cellar/demo/1.0/bin/tool", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\necho \"$@\" > \"$1\"\n");
        try f.setPermissions(io, .executable_file);
    }
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env: Env = .{
        .prefix = root,
        .cellar = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{root}),
        .keg = try std.fmt.bufPrint(&keg_buf, "{s}/Cellar/demo/1.0", .{root}),
        .name = "demo",
        .version = "1.0",
    };
    const steps =
        \\[{"path":{"base":"var","path":"demo/db"},"type":"mkdir_p"},
        \\ {"path":{"base":"var","path":"demo/db/stamp"},"guards":[{"base":"var","path":"demo/db/stamp","condition":"unless_exists","id":"1"}],"type":"touch"},
        \\ {"path":{"base":"var","path":"demo/db/second"},"guards":[{"base":"var","path":"demo/db/stamp","condition":"unless_exists","id":"1"}],"type":"touch"},
        \\ {"path":{"base":"var","path":"demo/never"},"guards":[{"base":"var","path":"demo/db/{nope,stamp}","condition":"if_exists","id":"2"}],"type":"mkdir_p"},
        \\ {"source":{"base":"var","path":"demo/db"},"target":{"base":"pkgetc","path":"db"},"force":true,"type":"symlink"},
        \\ {"command":{"base":"bin","path":"tool"},"type":"run","args":["{{var}}/demo/ran","{{version.major}}"]},
        \\ {"type":"gdk_pixbuf_query_loaders","guards":[{"condition":"on","value":"OTHER_OS"}]}]
    ;
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    const Collect = struct {
        list: *std.ArrayList(u8),
        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(testing.allocator, fmt, args);
            defer testing.allocator.free(s);
            try self.list.appendSlice(testing.allocator, s);
        }
    };
    // The unsupported step is guarded to the other OS, so it does not block.
    const other = if (native_os == .macos) "linux" else "macos";
    const steps_here = try std.mem.replaceOwned(u8, testing.allocator, steps, "OTHER_OS", other);
    defer testing.allocator.free(steps_here);
    const outcome = try runAll(testing.allocator, io, steps_here, env, Collect{ .list = &lines });
    try testing.expectEqual(@as(usize, 6), outcome.ran);
    try testing.expectEqual(@as(usize, 0), outcome.skipped);
    try testing.expectEqual(@as(usize, 0), outcome.failed);
    try testing.expectEqualStrings("", lines.items);
    try tmp.dir.access(io, "var/demo/db/stamp", .{});
    // The guard is evaluated once per run, as in Homebrew: the second touch
    // still runs although the first one created the guarded path.
    try tmp.dir.access(io, "var/demo/db/second", .{});
    // `{nope,stamp}`: one alternative exists, so the if_exists step ran.
    try tmp.dir.access(io, "var/demo/never", .{});
    try tmp.dir.access(io, "etc/demo/db/stamp", .{});
    var buf: [256]u8 = undefined;
    const ran = try tmp.dir.readFile(io, "var/demo/ran", &buf);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, ran, "\n"), " 1"));
}

test "post_install_steps: one unsupported step means none run (#493)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env: Env = .{ .prefix = root, .cellar = root, .keg = try std.fmt.bufPrint(&keg_buf, "{s}/Cellar/demo/1", .{root}), .name = "demo", .version = "1" };
    // Shaped like openssh: back up (move), then mark done (touch).
    const steps =
        \\[{"type":"move","source":{"base":"etc","path":"ssh/key"},"target":{"base":"var","path":"backup/key"}},
        \\ {"path":{"base":"homebrew_prefix","path":"migrated"},"type":"touch"}]
    ;
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    const Collect = struct {
        list: *std.ArrayList(u8),
        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(testing.allocator, fmt, args);
            defer testing.allocator.free(s);
            try self.list.appendSlice(testing.allocator, s);
        }
    };
    const outcome = try runAll(testing.allocator, io, steps, env, Collect{ .list = &lines });
    try testing.expectEqual(@as(usize, 0), outcome.ran);
    try testing.expectEqual(@as(usize, 1), outcome.skipped);
    try testing.expect(std.mem.indexOf(u8, lines.items, "step 1 (move) is not supported") != null);
    try testing.expect(std.mem.indexOf(u8, lines.items, "post-install not run") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "migrated", .{}));
}
