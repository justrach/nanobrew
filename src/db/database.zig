// nanobrew — Installation state database
//
// Lightweight file-based database (JSON for v0).
// Tracks installed kegs, store references, and linked files.
// File: /opt/nanobrew/db/state.json

const std = @import("std");

const DB_PATH = "/opt/nanobrew/db/state.json";

pub const Keg = struct {
    name: []const u8,
    version: []const u8,
    sha256: []const u8 = "",
    pinned: bool = false,
    installed_at: i64 = 0,
};

pub const CaskRecord = struct {
    token: []const u8,
    version: []const u8,
    apps: []const []const u8,
    binaries: []const []const u8,
};

pub const HistoryEntry = struct {
    version: []const u8,
    sha256: []const u8,
    installed_at: i64,
};

pub const Database = struct {
    alloc: std.mem.Allocator,
    kegs: std.ArrayList(Keg),
    casks: std.ArrayList(CaskRecord),
    history: std.StringHashMap(std.ArrayList(HistoryEntry)),

    pub fn open() !Database {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const alloc = gpa.allocator();

        var db = Database{
            .alloc = alloc,
            .kegs = .empty,
            .casks = .empty,
            .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(alloc),
        };

        const file = std.fs.openFileAbsolute(DB_PATH, .{}) catch return db;
        defer file.close();

        var buf: [1024 * 1024]u8 = undefined;
        const n = file.readAll(&buf) catch return db;
        if (n == 0) return db;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, buf[0..n], .{}) catch return db;
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("kegs")) |kegs_val| {
                if (kegs_val == .array) {
                    for (kegs_val.array.items) |item| {
                        if (item == .object) {
                            const kname = getStr(item.object, "name") orelse continue;
                            const kver = getStr(item.object, "version") orelse continue;
                            const ksha = getStr(item.object, "sha256") orelse "";
                            const kpinned = getBool(item.object, "pinned");
                            const kinst = getInt(item.object, "installed_at");
                            db.kegs.append(alloc, .{
                                .name = alloc.dupe(u8, kname) catch continue,
                                .version = alloc.dupe(u8, kver) catch continue,
                                .sha256 = alloc.dupe(u8, ksha) catch continue,
                                .pinned = kpinned,
                                .installed_at = kinst,
                            }) catch {};
                        }
                    }
                }
            }
            // Parse casks (backward compatible — missing key = empty list)
            if (parsed.value.object.get("casks")) |casks_val| {
                if (casks_val == .array) {
                    for (casks_val.array.items) |item| {
                        if (item != .object) continue;
                        const ctoken = getStr(item.object, "token") orelse continue;
                        const cver = getStr(item.object, "version") orelse continue;

                        var capps: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("apps")) |apps_val| {
                            if (apps_val == .array) {
                                for (apps_val.array.items) |a| {
                                    if (a == .string) {
                                        capps.append(alloc, alloc.dupe(u8, a.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        var cbins: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("binaries")) |bins_val| {
                            if (bins_val == .array) {
                                for (bins_val.array.items) |b| {
                                    if (b == .string) {
                                        cbins.append(alloc, alloc.dupe(u8, b.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        db.casks.append(alloc, .{
                            .token = alloc.dupe(u8, ctoken) catch continue,
                            .version = alloc.dupe(u8, cver) catch continue,
                            .apps = capps.toOwnedSlice(alloc) catch continue,
                            .binaries = cbins.toOwnedSlice(alloc) catch continue,
                        }) catch {};
                    }
                }
            }
            // Parse history (backward compatible — missing key = empty)
            if (parsed.value.object.get("history")) |hist_val| {
                if (hist_val == .object) {
                    var hist_iter = hist_val.object.iterator();
                    while (hist_iter.next()) |entry| {
                        const pkg_name = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                        var entries: std.ArrayList(HistoryEntry) = .empty;
                        if (entry.value_ptr.* == .array) {
                            for (entry.value_ptr.array.items) |h_item| {
                                if (h_item != .object) continue;
                                const hver = getStr(h_item.object, "version") orelse continue;
                                const hsha = getStr(h_item.object, "sha256") orelse "";
                                const hinst = getInt(h_item.object, "installed_at");
                                entries.append(alloc, .{
                                    .version = alloc.dupe(u8, hver) catch continue,
                                    .sha256 = alloc.dupe(u8, hsha) catch continue,
                                    .installed_at = hinst,
                                }) catch {};
                            }
                        }
                        db.history.put(pkg_name, entries) catch {};
                    }
                }
            }
        }

        return db;
    }

    pub fn close(self: *Database) void {
        self.save() catch {};
    }

    pub fn recordInstall(self: *Database, name: []const u8, version: []const u8, sha256: []const u8) !void {
        const now = std.time.timestamp();

        // Push old version to history before replacing
        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                const old = self.kegs.items[i];
                // Save to history (best-effort)
                self.pushHistory(name, old) catch {};
                _ = self.kegs.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        try self.kegs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .sha256 = try self.alloc.dupe(u8, sha256),
            .pinned = false,
            .installed_at = now,
        });
        try self.save();
    }

    fn pushHistory(self: *Database, name: []const u8, old: Keg) !void {
        const hist_name = try self.alloc.dupe(u8, name);
        var hist_list = self.history.get(name) orelse std.ArrayList(HistoryEntry).empty;
        try hist_list.append(self.alloc, .{
            .version = self.alloc.dupe(u8, old.version) catch "",
            .sha256 = self.alloc.dupe(u8, old.sha256) catch "",
            .installed_at = old.installed_at,
        });
        try self.history.put(hist_name, hist_list);
    }

    pub fn recordRemoval(self: *Database, name: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                _ = self.kegs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.save();
    }

    pub fn findKeg(self: *Database, name: []const u8) ?Keg {
        for (self.kegs.items) |keg| {
            if (std.mem.eql(u8, keg.name, name)) return keg;
        }
        return null;
    }

    pub fn listInstalled(self: *Database, alloc: std.mem.Allocator) ![]Keg {
        const result = try alloc.alloc(Keg, self.kegs.items.len);
        @memcpy(result, self.kegs.items);
        return result;
    }

    pub fn recordCaskInstall(self: *Database, token: []const u8, version: []const u8, apps: []const []const u8, binaries: []const []const u8) !void {
        // Remove existing entry for this token
        var i: usize = 0;
        while (i < self.casks.items.len) {
            if (std.mem.eql(u8, self.casks.items[i].token, token)) {
                _ = self.casks.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Dupe all strings
        const dapps = try self.alloc.alloc([]const u8, apps.len);
        for (apps, 0..) |a, idx| dapps[idx] = try self.alloc.dupe(u8, a);
        const dbins = try self.alloc.alloc([]const u8, binaries.len);
        for (binaries, 0..) |b, idx| dbins[idx] = try self.alloc.dupe(u8, b);

        try self.casks.append(self.alloc, .{
            .token = try self.alloc.dupe(u8, token),
            .version = try self.alloc.dupe(u8, version),
            .apps = dapps,
            .binaries = dbins,
        });
        try self.save();
    }

    pub fn recordCaskRemoval(self: *Database, token: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.casks.items.len) {
            if (std.mem.eql(u8, self.casks.items[i].token, token)) {
                _ = self.casks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.save();
    }

    pub fn findCask(self: *Database, token: []const u8) ?CaskRecord {
        for (self.casks.items) |c| {
            if (std.mem.eql(u8, c.token, token)) return c;
        }
        return null;
    }

    pub fn listInstalledCasks(self: *Database, alloc: std.mem.Allocator) ![]CaskRecord {
        const result = try alloc.alloc(CaskRecord, self.casks.items.len);
        @memcpy(result, self.casks.items);
        return result;
    }

    pub fn setPinned(self: *Database, name: []const u8, pinned: bool) !void {
        for (self.kegs.items) |*keg| {
            if (std.mem.eql(u8, keg.name, name)) {
                keg.pinned = pinned;
                try self.save();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn getHistory(self: *Database, name: []const u8) []const HistoryEntry {
        if (self.history.get(name)) |list| {
            return list.items;
        }
        return &.{};
    }

    fn save(self: *Database) !void {
        const file = try std.fs.createFileAbsolute(DB_PATH, .{});
        defer file.close();

        const writer = file.deprecatedWriter();
        writer.writeAll("{\"kegs\":[") catch return;
        for (self.kegs.items, 0..) |keg, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"sha256\":\"{s}\",\"pinned\":{s},\"installed_at\":{d}}}", .{
                keg.name, keg.version, keg.sha256, if (keg.pinned) "true" else "false", keg.installed_at,
            }) catch {};
        }
        writer.writeAll("],\"casks\":[") catch return;
        for (self.casks.items, 0..) |c, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.print("{{\"token\":\"{s}\",\"version\":\"{s}\",\"apps\":[", .{
                c.token, c.version,
            }) catch {};
            for (c.apps, 0..) |a, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writer.print("\"{s}\"", .{a}) catch {};
            }
            writer.writeAll("],\"binaries\":[") catch {};
            for (c.binaries, 0..) |b, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writer.print("\"{s}\"", .{b}) catch {};
            }
            writer.writeAll("]}") catch {};
        }
        // Serialize history
        writer.writeAll("],\"history\":{") catch return;
        var hist_iter = self.history.iterator();
        var hist_first = true;
        while (hist_iter.next()) |entry| {
            if (!hist_first) writer.writeAll(",") catch {};
            hist_first = false;
            writer.print("\"{s}\":[", .{entry.key_ptr.*}) catch {};
            for (entry.value_ptr.items, 0..) |h, hi| {
                if (hi > 0) writer.writeAll(",") catch {};
                writer.print("{{\"version\":\"{s}\",\"sha256\":\"{s}\",\"installed_at\":{d}}}", .{
                    h.version, h.sha256, h.installed_at,
                }) catch {};
            }
            writer.writeAll("]") catch {};
        }
        writer.writeAll("}}") catch {};
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    if (obj.get(key)) |val| {
        if (val == .bool) return val.bool;
    }
    return false;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |val| {
        if (val == .integer) return val.integer;
    }
    return 0;
}
