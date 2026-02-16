// nanobrew — Search API
//
// Fetches formula and cask lists from Homebrew API and performs
// case-insensitive substring matching on name and description.

const std = @import("std");

const FORMULA_LIST_URL = "https://formulae.brew.sh/api/formula.json";
const CASK_LIST_URL = "https://formulae.brew.sh/api/cask.json";
const CACHE_DIR = "/opt/nanobrew/cache/api";
const FORMULA_CACHE = CACHE_DIR ++ "/_formula_list.json";
const CASK_CACHE = CACHE_DIR ++ "/_cask_list.json";
const CACHE_TTL_NS = 3600 * std.time.ns_per_s; // 1 hour

pub const SearchResult = struct {
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    is_cask: bool,

    pub fn deinit(self: SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.desc);
    }
};

pub fn search(alloc: std.mem.Allocator, query: []const u8) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    defer results.deinit(alloc); // only the list, not items — caller owns items

    // Lowercase the query for case-insensitive matching
    const lower_query = try toLower(alloc, query);
    defer alloc.free(lower_query);

    // Search formulae
    const formula_json = try fetchCachedList(alloc, FORMULA_LIST_URL, FORMULA_CACHE);
    defer alloc.free(formula_json);
    try searchFormulaList(alloc, formula_json, lower_query, &results);

    // Search casks
    const cask_json = try fetchCachedList(alloc, CASK_LIST_URL, CASK_CACHE);
    defer alloc.free(cask_json);
    try searchCaskList(alloc, cask_json, lower_query, &results);

    return results.toOwnedSlice(alloc);
}

fn fetchCachedList(alloc: std.mem.Allocator, url: []const u8, cache_path: []const u8) ![]u8 {
    // Check cache with 1-hour TTL
    if (readCachedFile(alloc, cache_path)) |data| return data;

    // Fetch from network
    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sL", "--http2", url },
        .max_output_bytes = 64 * 1024 * 1024, // 64MB max
    }) catch return error.CurlFailed;
    defer alloc.free(run.stderr);

    if (run.term.Exited != 0 or run.stdout.len == 0) {
        alloc.free(run.stdout);
        return error.FetchFailed;
    }

    // Write to cache
    std.fs.makeDirAbsolute(CACHE_DIR) catch {};
    if (std.fs.createFileAbsolute(cache_path, .{})) |file| {
        defer file.close();
        file.writeAll(run.stdout) catch {};
    } else |_| {}

    return run.stdout;
}

fn readCachedFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    if (age_ns > CACHE_TTL_NS) return null;
    return file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch null;
}

fn searchFormulaList(alloc: std.mem.Allocator, json_data: []const u8, lower_query: []const u8, results: *std.ArrayList(SearchResult)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const name = getStr(obj, "name") orelse continue;
        const desc = getStr(obj, "desc") orelse "";

        // Get version from versions.stable
        var version: []const u8 = "";
        if (obj.get("versions")) |ver_obj| {
            if (ver_obj == .object) {
                version = getStr(ver_obj.object, "stable") orelse "";
            }
        }

        // Case-insensitive match on name or desc
        const lower_name = toLower(alloc, name) catch continue;
        defer alloc.free(lower_name);
        const lower_desc = toLower(alloc, desc) catch continue;
        defer alloc.free(lower_desc);

        if (std.mem.indexOf(u8, lower_name, lower_query) != null or
            std.mem.indexOf(u8, lower_desc, lower_query) != null)
        {
            try results.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .version = try alloc.dupe(u8, version),
                .desc = try alloc.dupe(u8, desc),
                .is_cask = false,
            });
        }
    }
}

fn searchCaskList(alloc: std.mem.Allocator, json_data: []const u8, lower_query: []const u8, results: *std.ArrayList(SearchResult)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const token = getStr(obj, "token") orelse continue;
        const desc = getStr(obj, "desc") orelse "";
        const version = getStr(obj, "version") orelse "";

        const lower_token = toLower(alloc, token) catch continue;
        defer alloc.free(lower_token);
        const lower_desc = toLower(alloc, desc) catch continue;
        defer alloc.free(lower_desc);

        if (std.mem.indexOf(u8, lower_token, lower_query) != null or
            std.mem.indexOf(u8, lower_desc, lower_query) != null)
        {
            try results.append(alloc, .{
                .name = try alloc.dupe(u8, token),
                .version = try alloc.dupe(u8, version),
                .desc = try alloc.dupe(u8, desc),
                .is_cask = true,
            });
        }
    }
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn toLower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}
