// nanobrew — Homebrew JSON API client
//
// Fetches formula metadata from https://formulae.brew.sh/api/formula/<name>.json
// Uses curl for HTTP (Zig 0.15 std.http.Client API is still evolving).
// Parses JSON to extract: name, version, dependencies, bottle URL + SHA256.

const std = @import("std");
const Formula = @import("formula.zig").Formula;
const BOTTLE_TAG = @import("formula.zig").BOTTLE_TAG;
const BOTTLE_FALLBACKS = @import("formula.zig").BOTTLE_FALLBACKS;

const API_BASE = "https://formulae.brew.sh/api/formula/";

pub fn fetchFormula(alloc: std.mem.Allocator, name: []const u8) !Formula {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}.json", .{ API_BASE, name }) catch return error.NameTooLong;

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sL", url },
    });

    const run = result catch return error.CurlFailed;
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);

    if (run.term.Exited != 0 or run.stdout.len == 0) {
        return error.FormulaNotFound;
    }

    return parseFormulaJson(alloc, run.stdout);
}

fn parseFormulaJson(alloc: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const name = try allocDupe(alloc, getStr(root, "name") orelse return error.MissingField);
    const version_obj = root.get("versions") orelse return error.MissingField;
    const version = try allocDupe(alloc, getStr(version_obj.object, "stable") orelse return error.MissingField);
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");

    const revision: u32 = if (root.get("revision")) |rev|
        switch (rev) {
            .integer => @intCast(@max(0, rev.integer)),
            else => 0,
        }
    else
        0;

    // Parse dependencies (unmanaged ArrayList in 0.15)
    var deps: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(alloc);
    if (root.get("dependencies")) |deps_val| {
        if (deps_val == .array) {
            for (deps_val.array.items) |dep| {
                if (dep == .string) {
                    try deps.append(alloc, try allocDupe(alloc, dep.string));
                }
            }
        }
    }
    const dependencies = try deps.toOwnedSlice(alloc);

    var bottle_url: []const u8 = "";
    var bottle_sha256: []const u8 = "";
    var rebuild: u32 = 0;

    if (root.get("bottle")) |bottle_val| {
        if (bottle_val == .object) {
            if (bottle_val.object.get("stable")) |stable| {
                if (stable == .object) {
                    if (stable.object.get("rebuild")) |rb| {
                        if (rb == .integer) {
                            rebuild = @intCast(@max(0, rb.integer));
                        }
                    }

                    if (stable.object.get("files")) |files| {
                        if (files == .object) {
                            const tag = findBottleTag(files.object) orelse return error.NoArm64Bottle;
                            if (tag == .object) {
                                bottle_url = try allocDupe(alloc, getStr(tag.object, "url") orelse "");
                                bottle_sha256 = try allocDupe(alloc, getStr(tag.object, "sha256") orelse "");
                            }
                        }
                    }
                }
            }
        }
    }

    if (bottle_url.len == 0) return error.NoArm64Bottle;

    return Formula{
        .name = name,
        .version = version,
        .revision = revision,
        .rebuild = rebuild,
        .desc = desc,
        .dependencies = dependencies,
        .bottle_url = bottle_url,
        .bottle_sha256 = bottle_sha256,
    };
}

fn findBottleTag(files: std.json.ObjectMap) ?std.json.Value {
    if (files.get(BOTTLE_TAG)) |v| return v;
    for (BOTTLE_FALLBACKS) |tag| {
        if (files.get(tag)) |v| return v;
    }
    return null;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn allocDupe(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return alloc.dupe(u8, s);
}
