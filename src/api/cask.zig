// nanobrew — Homebrew Cask API client
//
// Fetches cask metadata from https://formulae.brew.sh/api/cask/<name>.json
// Casks are macOS GUI applications (e.g. firefox, vscode, slack).

const std = @import("std");

const API_BASE = "https://formulae.brew.sh/api/cask/";

pub const Cask = struct {
    token: []const u8,
    name: []const u8,
    version: []const u8,
    desc: []const u8 = "",
    homepage: []const u8 = "",
};

pub fn fetchCask(alloc: std.mem.Allocator, name: []const u8) !Cask {
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
        return error.CaskNotFound;
    }

    return parseCaskJson(alloc, run.stdout);
}

fn parseCaskJson(alloc: std.mem.Allocator, json_data: []const u8) !Cask {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const token = try allocDupe(alloc, getStr(root, "token") orelse return error.MissingField);
    const version = try allocDupe(alloc, getStr(root, "version") orelse return error.MissingField);
    const desc = try allocDupe(alloc, getStr(root, "desc") orelse "");
    const homepage = try allocDupe(alloc, getStr(root, "homepage") orelse "");

    // "name" is an array of strings in cask JSON; take the first
    var name_str: []const u8 = token;
    if (root.get("name")) |name_val| {
        if (name_val == .array and name_val.array.items.len > 0) {
            if (name_val.array.items[0] == .string) {
                name_str = try allocDupe(alloc, name_val.array.items[0].string);
            }
        }
    }

    return Cask{
        .token = token,
        .name = name_str,
        .version = version,
        .desc = desc,
        .homepage = homepage,
    };
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
