// nanobrew — Homebrew `post_install_steps` (#493).
//
// The Homebrew API stopped setting `post_install_defined` and describes a
// formula's post-install actions as a JSON array instead, for example
//   {"type":"run","command":{"base":"bin","path":"fc-cache"},"args":["--force"]}
// This file runs a small, checked subset of those steps without a shell and
// without any Ruby: argv only, every path resolved from the step's `base` and
// `{{token}}` templates against nanobrew's own prefix.
//
// Supported: mkdir_p, touch, symlink, warn; run when the command is a file
// inside the formula's own keg or in an installed formula's
// `<prefix>/opt/<formula>/bin`; the cache rebuilds Homebrew defines as fixed
// tool calls (compile_gsettings_schemas, gio_querymodules,
// gdk_pixbuf_query_loaders, gtk_update_icon_cache, update_mime_database,
// update_desktop_database); and init_data_dir for postgresql/mysql/mariadb,
// which runs the keg's own initialiser once per data dir. Guards: `on` (macos/linux), if_exists
// and unless_exists (with `{a,b}` alternatives). Anything else — another
// step type, an unknown base or template, a glob, `..`, a write outside the
// prefix, or run options such as env/chdir/stdin_path/stdout_path/sudo — is
// not run. If any step that applies on this OS is not supported, none of
// the steps run (they are one sequence), and nanobrew says which and why.
//
// The JSON comes from the same formula metadata that names the bottle and
// its sha256, so it is trusted as much as the bottle is. `run` only executes
// files from that verified keg or from another installed keg (an opt link
// must resolve into the Cellar); writes stay under the prefix.

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
    /// A tool from an installed formula, `<prefix>/opt/<formula>/bin/<exe>`.
    /// The first candidate whose formula is installed is used; the last one
    /// is used otherwise (as brew does for gtk4 / gtk+3).
    tool: struct { candidates: []const Tool, args: []const []const u8 },
    init_data_dir: struct { path: []const u8, using: Initialiser, locale: []const u8, keg: []const u8, user: []const u8 },
};

pub const Tool = struct { formula: []const u8, exe: []const u8 };

pub const Initialiser = enum {
    postgresql_initdb,
    mysql_initialize,
    mariadb_install_db,

    /// File whose presence means the data dir is already set up.
    fn marker(self: Initialiser) []const u8 {
        return switch (self) {
            .postgresql_initdb => "PG_VERSION",
            .mysql_initialize => "mysql/general_log.CSM",
            .mariadb_install_db => "mysql/user.frm",
        };
    }
};

/// Cache rebuilds, from brew's install_steps.rb (`run_install_step`).
const Rebuild = struct { type_name: []const u8, candidates: []const Tool, args: []const []const u8, path: bool };
const rebuilds = [_]Rebuild{
    .{ .type_name = "compile_gsettings_schemas", .candidates = &.{.{ .formula = "glib", .exe = "glib-compile-schemas" }}, .args = &.{}, .path = true },
    .{ .type_name = "gio_querymodules", .candidates = &.{.{ .formula = "glib", .exe = "gio-querymodules" }}, .args = &.{}, .path = true },
    .{ .type_name = "gdk_pixbuf_query_loaders", .candidates = &.{.{ .formula = "gdk-pixbuf", .exe = "gdk-pixbuf-query-loaders" }}, .args = &.{"--update-cache"}, .path = false },
    .{ .type_name = "gtk_update_icon_cache", .candidates = &.{ .{ .formula = "gtk4", .exe = "gtk4-update-icon-cache" }, .{ .formula = "gtk+3", .exe = "gtk3-update-icon-cache" } }, .args = &.{ "-q", "-t", "-f" }, .path = true },
    .{ .type_name = "update_mime_database", .candidates = &.{.{ .formula = "shared-mime-info", .exe = "update-mime-database" }}, .args = &.{}, .path = true },
    .{ .type_name = "update_desktop_database", .candidates = &.{.{ .formula = "desktop-file-utils", .exe = "update-desktop-database" }}, .args = &.{}, .path = true },
};

fn findRebuild(type_name: []const u8) ?Rebuild {
    for (rebuilds) |r| if (std.mem.eql(u8, r.type_name, type_name)) return r;
    return null;
}

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
    if (t(u8, type_name, "init_data_dir")) return &.{ "type", "guards", "path", "using", "locale" };
    if (findRebuild(type_name)) |r| return if (r.path) &.{ "type", "guards", "path" } else &.{ "type", "guards" };
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
    if (findRebuild(type_name)) |r| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, r.args);
        if (r.path) try args.append(arena, try writablePath(arena, obj.get("path") orelse return error.BadStep, env));
        return .{ .tool = .{ .candidates = r.candidates, .args = try args.toOwnedSlice(arena) } };
    }
    if (std.mem.eql(u8, type_name, "init_data_dir")) {
        const using = std.meta.stringToEnum(Initialiser, str(obj, "using") orelse return error.BadStep) orelse return error.UnsupportedOption;
        const locale = if (obj.get("locale")) |l| switch (l) {
            .string => |v| v,
            .null => "en_US.UTF-8",
            else => return error.BadStep,
        } else "en_US.UTF-8";
        const user = if (using == .postgresql_initdb) (env.user orelse "") else (env.user orelse return error.NoUser);
        return .{ .init_data_dir = .{
            .path = try writablePath(arena, obj.get("path") orelse return error.BadStep, env),
            .using = using,
            .locale = locale,
            .keg = env.keg,
            .user = user,
        } };
    }
    // run
    if (obj.get("sudo")) |s| if (!(s == .bool and !s.bool)) return error.UnsupportedOption;
    if (obj.get("network_access")) |n| if (n != .bool) return error.BadStep;
    const command = try resolvePath(arena, obj.get("command") orelse return error.BadStep, env);
    if (!under(command, env.keg) and optBinTool(command, env) == null) return error.OutsideKeg;
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

/// `<prefix>/opt/<formula>/bin/<exe>` (one component each) to its parts.
fn optBinTool(command: []const u8, env: Env) ?Tool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt = std.fmt.bufPrint(&buf, "{s}/opt/", .{env.prefix}) catch return null;
    if (!std.mem.startsWith(u8, command, opt)) return null;
    var parts = std.mem.splitScalar(u8, command[opt.len..], '/');
    const formula = parts.next() orelse return null;
    const bin = parts.next() orelse return null;
    const exe = parts.next() orelse return null;
    if (parts.next() != null or formula.len == 0 or exe.len == 0 or !std.mem.eql(u8, bin, "bin")) return null;
    return .{ .formula = formula, .exe = exe };
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
        const ok = execute(arena, io, action, env, out);
        if (ok) result.ran += 1 else {
            result.failed += 1;
            out.print("nb: {s}: post-install step {d} ({s}) failed\n", .{ env.name, idx + 1, step.type_name }) catch {};
        }
    }
    return result;
}

fn execute(arena: std.mem.Allocator, io: std.Io, action: Action, env: Env, out: anytype) bool {
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
        .run => |r| {
            // A tool from another keg runs only when its opt link really
            // leads into the Cellar, i.e. nanobrew installed that formula.
            if (!under(r.argv[0], env.keg)) {
                if (!installedTool(arena, io, r.argv[0], env)) {
                    out.print("nb: {s}: {s} is not an installed formula's tool\n", .{ env.name, r.argv[0] }) catch {};
                    return r.allow_failure;
                }
            }
            return runArgv(arena, io, r.argv, true) or r.allow_failure;
        },
        .tool => |t| {
            const chosen = for (t.candidates, 0..) |c, i| {
                if (i + 1 == t.candidates.len) break c;
                const keg_dir = std.fmt.allocPrint(arena, "{s}/{s}", .{ env.cellar, c.formula }) catch return false;
                if (std.Io.Dir.accessAbsolute(io, keg_dir, .{})) |_| break c else |_| {}
            } else unreachable;
            const tool = std.fmt.allocPrint(arena, "{s}/opt/{s}/bin/{s}", .{ env.prefix, chosen.formula, chosen.exe }) catch return false;
            if (!installedTool(arena, io, tool, env)) {
                // brew fails the step the same way: the tool's formula is missing.
                out.print("nb: {s}: needs {s} from {s}, which is not installed\n", .{ env.name, chosen.exe, chosen.formula }) catch {};
                return false;
            }
            var argv: std.ArrayList([]const u8) = .empty;
            argv.append(arena, tool) catch return false;
            argv.appendSlice(arena, t.args) catch return false;
            return runArgv(arena, io, argv.items, true);
        },
        .init_data_dir => |d| {
            if (!runArgv(arena, io, &.{ "mkdir", "-p", d.path }, false)) return false;
            const marker = std.fmt.allocPrint(arena, "{s}/{s}", .{ d.path, d.using.marker() }) catch return false;
            // Already initialised: leave existing data alone.
            if (std.Io.Dir.accessAbsolute(io, marker, .{})) |_| return true else |_| {}
            const datadir = std.fmt.allocPrint(arena, "--datadir={s}", .{d.path}) catch return false;
            const basedir = std.fmt.allocPrint(arena, "--basedir={s}", .{d.keg}) catch return false;
            const user = std.fmt.allocPrint(arena, "--user={s}", .{d.user}) catch return false;
            const argv: []const []const u8 = switch (d.using) {
                .postgresql_initdb => &.{
                    std.fmt.allocPrint(arena, "{s}/bin/initdb", .{d.keg}) catch return false,
                    std.fmt.allocPrint(arena, "--locale={s}", .{d.locale}) catch return false,
                    "-E",
                    "UTF-8",
                    d.path,
                },
                // brew clears TMPDIR for these two; env(1) does it without a shell.
                .mysql_initialize => &.{ "env", "-u", "TMPDIR", std.fmt.allocPrint(arena, "{s}/bin/mysqld", .{d.keg}) catch return false, "--initialize-insecure", user, basedir, datadir, "--tmpdir=/tmp" },
                .mariadb_install_db => &.{ "env", "-u", "TMPDIR", std.fmt.allocPrint(arena, "{s}/bin/mysql_install_db", .{d.keg}) catch return false, "--verbose", user, basedir, datadir, "--tmpdir=/tmp" },
            };
            return runArgv(arena, io, argv, true);
        },
    }
}

/// An executable whose real path is inside the Cellar.
fn installedTool(arena: std.mem.Allocator, io: std.Io, tool: []const u8, env: Env) bool {
    var tool_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, tool, &tool_buf) catch return false;
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c = std.Io.Dir.cwd().realPathFile(io, env.cellar, &cellar_buf) catch return false;
    if (!under(tool_buf[0..n], cellar_buf[0..c])) return false;
    std.Io.Dir.accessAbsolute(io, tool, .{ .execute = true }) catch return false;
    _ = arena;
    return true;
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
    // A command elsewhere in another formula's tree, or not under opt/<f>/bin.
    try expectUnsupported(
        \\[{"command":{"path":"{{HOMEBREW_PREFIX}}/opt/glib/libexec/tool"},"type":"run"}]
    , "command is not inside the formula's keg");
    try expectUnsupported(
        \\[{"command":{"path":"/usr/bin/true"},"type":"run"}]
    , "command is not inside the formula's keg");
    try expectUnsupported(
        \\[{"type":"init_data_dir","path":{"base":"var","path":"db"},"using":"sqlite_magic"}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"type":"gdk_pixbuf_query_loaders","path":{"base":"homebrew_prefix","path":"lib"}}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"type":"update_mime_database","path":{"path":"/usr/share/mime"}}]
    , "writes outside the nanobrew prefix");
    // janet: env and chdir.
    try expectUnsupported(
        \\[{"command":{"base":"bin","path":"janet"},"chdir":{"path":"{{libexec}}/jpm"},"type":"run","args":["bootstrap.janet"],"env":{"PREFIX":"{{prefix}}"}}]
    , "step uses an option nanobrew does not support");
    // gtk+3: stdout_path.
    try expectUnsupported(
        \\[{"command":{"base":"bin","path":"gtk-query-immodules-3.0"},"stdout_path":{"path":"{{HOMEBREW_PREFIX}}/lib/gtk-3.0/3.0.0/immodules.cache"},"type":"run"}]
    , "step uses an option nanobrew does not support");
    try expectUnsupported(
        \\[{"type":"bootstrap_cpython"}]
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

test "post_install_steps: cache rebuilds, opt tools and data dirs plan like brew (#493)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 29 formulae (e.g. gsettings-desktop-schemas)
    const gs = try planOne(a,
        \\[{"path":{"base":"homebrew_prefix","path":"share/glib-2.0/schemas"},"type":"compile_gsettings_schemas"}]
    , test_env);
    try testing.expectEqualStrings("glib", gs.plan.action.tool.candidates[0].formula);
    try testing.expectEqualStrings("glib-compile-schemas", gs.plan.action.tool.candidates[0].exe);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/share/glib-2.0/schemas", gs.plan.action.tool.args[0]);
    // 24 formulae (e.g. adwaita-icon-theme): gtk4 when installed, else gtk+3.
    const icons = try planOne(a,
        \\[{"path":{"base":"homebrew_prefix","path":"share/icons/hicolor"},"type":"gtk_update_icon_cache"}]
    , test_env);
    try testing.expectEqual(@as(usize, 2), icons.plan.action.tool.candidates.len);
    try testing.expectEqualStrings("gtk4-update-icon-cache", icons.plan.action.tool.candidates[0].exe);
    try testing.expectEqualStrings("gtk3-update-icon-cache", icons.plan.action.tool.candidates[1].exe);
    try testing.expectEqualStrings("-q", icons.plan.action.tool.args[0]);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/share/icons/hicolor", icons.plan.action.tool.args[3]);
    const pixbuf = try planOne(a,
        \\[{"type":"gdk_pixbuf_query_loaders"}]
    , test_env);
    try testing.expectEqualStrings("--update-cache", pixbuf.plan.action.tool.args[0]);
    // glib-networking: another formula's tool, through its opt link.
    const gio = try planOne(a,
        \\[{"command":{"path":"{{HOMEBREW_PREFIX}}/opt/glib/bin/gio-querymodules"},"type":"run","args":["{{HOMEBREW_PREFIX}}/lib/gio/modules"]}]
    , test_env);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/opt/glib/bin/gio-querymodules", gio.plan.action.run.argv[0]);
    // postgresql@16 / mysql
    const pg = try planOne(a,
        \\[{"path":{"base":"var","path":"postgresql@16"},"type":"init_data_dir","using":"postgresql_initdb"}]
    , test_env);
    try testing.expectEqual(Initialiser.postgresql_initdb, pg.plan.action.init_data_dir.using);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/var/postgresql@16", pg.plan.action.init_data_dir.path);
    try testing.expectEqualStrings("en_US.UTF-8", pg.plan.action.init_data_dir.locale);
    const pg12 = try planOne(a,
        \\[{"locale":"C","path":{"base":"var","path":"postgresql@12"},"type":"init_data_dir","using":"postgresql_initdb"}]
    , test_env);
    try testing.expectEqualStrings("C", pg12.plan.action.init_data_dir.locale);
    const my = try planOne(a,
        \\[{"path":{"base":"var","path":"mysql"},"type":"init_data_dir","using":"mysql_initialize"}]
    , test_env);
    try testing.expectEqualStrings("rach", my.plan.action.init_data_dir.user);
    var no_user = test_env;
    no_user.user = null;
    const my_no_user = try planOne(a,
        \\[{"path":{"base":"var","path":"mysql"},"type":"init_data_dir","using":"mysql_initialize"}]
    , no_user);
    try testing.expectEqualStrings("{{user}} needs $USER", my_no_user.plan.unsupported);
}

test "post_install_steps: rebuild tools and initialisers run from installed kegs only (#493)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const recorder = "#!/bin/sh\necho \"$(basename \"$0\") $*\" >> \"$(dirname \"$0\")/../../../../calls\"\n";
    // glib 2.0 installed, linked through opt like nanobrew does.
    try tmp.dir.createDirPath(io, "Cellar/glib/2.0/bin");
    try tmp.dir.createDirPath(io, "Cellar/gtk+3/3.0/bin");
    try tmp.dir.createDirPath(io, "Cellar/demo/16.1/bin");
    try tmp.dir.createDirPath(io, "opt");
    try tmp.dir.createDirPath(io, "elsewhere/bin");
    inline for (.{ "Cellar/glib/2.0/bin/glib-compile-schemas", "Cellar/glib/2.0/bin/gio-querymodules", "Cellar/gtk+3/3.0/bin/gtk3-update-icon-cache", "elsewhere/bin/update-mime-database" }) |path| {
        var f = try tmp.dir.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, recorder);
        try f.setPermissions(io, .executable_file);
    }
    {
        // initdb: creates the marker, records the call.
        var f = try tmp.dir.createFile(io, "Cellar/demo/16.1/bin/initdb", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\nfor last; do :; done\necho \"initdb $*\" >> \"$(dirname \"$0\")/../../../../calls\"\ntouch \"$last/PG_VERSION\"\n");
        try f.setPermissions(io, .executable_file);
    }
    try tmp.dir.symLink(io, "../Cellar/glib/2.0", "opt/glib", .{});
    try tmp.dir.symLink(io, "../Cellar/gtk+3/3.0", "opt/gtk+3", .{});
    // An opt link that leads outside the Cellar is not an installed formula.
    try tmp.dir.symLink(io, "../elsewhere", "opt/shared-mime-info", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env: Env = .{
        .prefix = root,
        .cellar = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{root}),
        .keg = try std.fmt.bufPrint(&keg_buf, "{s}/Cellar/demo/16.1", .{root}),
        .name = "demo",
        .version = "16.1",
    };
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
    const good =
        \\[{"path":{"base":"homebrew_prefix","path":"share/glib-2.0/schemas"},"type":"compile_gsettings_schemas"},
        \\ {"path":{"base":"homebrew_prefix","path":"share/icons/hicolor"},"type":"gtk_update_icon_cache"},
        \\ {"command":{"path":"{{HOMEBREW_PREFIX}}/opt/glib/bin/gio-querymodules"},"type":"run","args":["{{HOMEBREW_PREFIX}}/lib/gio/modules"]},
        \\ {"path":{"base":"var","path":"{{formula_name}}"},"type":"init_data_dir","using":"postgresql_initdb"}]
    ;
    var outcome = try runAll(testing.allocator, io, good, env, Collect{ .list = &lines });
    try testing.expectEqual(@as(usize, 4), outcome.ran);
    try testing.expectEqual(@as(usize, 0), outcome.failed);
    // A second run leaves the initialised data dir alone (marker present).
    outcome = try runAll(testing.allocator, io, good, env, Collect{ .list = &lines });
    try testing.expectEqual(@as(usize, 4), outcome.ran);
    try testing.expectEqualStrings("", lines.items);
    var buf: [2048]u8 = undefined;
    const calls = try tmp.dir.readFile(io, "calls", &buf);
    var expect_buf: [2048]u8 = undefined;
    const once = try std.fmt.bufPrint(&expect_buf,
        \\glib-compile-schemas {0s}/share/glib-2.0/schemas
        \\gtk3-update-icon-cache -q -t -f {0s}/share/icons/hicolor
        \\gio-querymodules {0s}/lib/gio/modules
        \\initdb --locale=en_US.UTF-8 -E UTF-8 {0s}/var/demo
        \\glib-compile-schemas {0s}/share/glib-2.0/schemas
        \\gtk3-update-icon-cache -q -t -f {0s}/share/icons/hicolor
        \\gio-querymodules {0s}/lib/gio/modules
        \\
    , .{root});
    try testing.expectEqualStrings(once, calls);

    // Missing formula, and an opt link outside the Cellar: the step fails
    // with a message and nothing outside the Cellar runs.
    const bad =
        \\[{"type":"gdk_pixbuf_query_loaders"},
        \\ {"path":{"base":"homebrew_prefix","path":"share/mime"},"type":"update_mime_database"}]
    ;
    lines.clearRetainingCapacity();
    outcome = try runAll(testing.allocator, io, bad, env, Collect{ .list = &lines });
    try testing.expectEqual(@as(usize, 0), outcome.ran);
    try testing.expectEqual(@as(usize, 2), outcome.failed);
    try testing.expect(std.mem.indexOf(u8, lines.items, "needs gdk-pixbuf-query-loaders from gdk-pixbuf, which is not installed") != null);
    try testing.expect(std.mem.indexOf(u8, lines.items, "needs update-mime-database from shared-mime-info, which is not installed") != null);
    const after = try tmp.dir.readFile(io, "calls", &buf);
    try testing.expectEqual(once.len, after.len);
}
