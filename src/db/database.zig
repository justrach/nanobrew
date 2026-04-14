// nanobrew — Installation state database
//
// Lightweight file-based database (JSON for v0).
// Tracks installed kegs, store references, and linked files.
// File: /opt/nanobrew/db/state.json

const std = @import("std");
const paths = @import("../platform/paths.zig");

const DB_PATH = paths.DB_PATH;

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

pub const DebRecord = struct {
    name: []const u8,
    version: []const u8,
    files: []const []const u8, // installed file paths (from data.tar)
    sha256: []const u8 = "",
    installed_at: i64 = 0,
};

pub const Database = struct {
    alloc: std.mem.Allocator,
    kegs: std.ArrayList(Keg),
    casks: std.ArrayList(CaskRecord),
    debs: std.ArrayList(DebRecord),
    history: std.StringHashMap(std.ArrayList(HistoryEntry)),

    pub fn open(alloc: std.mem.Allocator) !Database {
        var db = Database{
            .alloc = alloc,
            .kegs = .empty,
            .casks = .empty,
            .debs = .empty,
            .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(alloc),
        };

        const file = std.fs.openFileAbsolute(DB_PATH, .{}) catch return db;
        defer file.close();

        const max_state_bytes = 16 * 1024 * 1024;
        const contents = file.readToEndAlloc(alloc, max_state_bytes) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("warning: nanobrew database read failed ({}): {s}\n", .{ err, DB_PATH }) catch {};
            return db;
        };
        defer alloc.free(contents);
        if (contents.len == 0) return db;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, contents, .{}) catch {
            std.fs.File.stderr().deprecatedWriter().writeAll("warning: nanobrew database parse failed; returning empty database. File may be corrupted: " ++ DB_PATH ++ "\n") catch {};
            return db;
        };
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
            // Parse deb packages (backward compatible — missing key = empty)
            if (parsed.value.object.get("deb_packages")) |debs_val| {
                if (debs_val == .array) {
                    for (debs_val.array.items) |item| {
                        if (item != .object) continue;
                        const dname = getStr(item.object, "name") orelse continue;
                        const dver = getStr(item.object, "version") orelse continue;
                        const dsha = getStr(item.object, "sha256") orelse "";
                        const dinst = getInt(item.object, "installed_at");

                        var dfiles: std.ArrayList([]const u8) = .empty;
                        if (item.object.get("files")) |files_val| {
                            if (files_val == .array) {
                                for (files_val.array.items) |f| {
                                    if (f == .string) {
                                        dfiles.append(alloc, alloc.dupe(u8, f.string) catch continue) catch {};
                                    }
                                }
                            }
                        }

                        db.debs.append(alloc, .{
                            .name = alloc.dupe(u8, dname) catch continue,
                            .version = alloc.dupe(u8, dver) catch continue,
                            .files = dfiles.toOwnedSlice(alloc) catch continue,
                            .sha256 = alloc.dupe(u8, dsha) catch continue,
                            .installed_at = dinst,
                        }) catch {};
                    }
                }
            }
        }

        return db;
    }

    pub fn close(self: *Database) void {
        self.save() catch {};
        // Free all allocated keg strings
        for (self.kegs.items) |keg| {
            self.alloc.free(keg.name);
            self.alloc.free(keg.version);
            self.alloc.free(keg.sha256);
        }
        self.kegs.deinit(self.alloc);
        // Free all allocated cask strings
        for (self.casks.items) |c| {
            self.alloc.free(c.token);
            self.alloc.free(c.version);
            for (c.apps) |a| self.alloc.free(a);
            self.alloc.free(c.apps);
            for (c.binaries) |b| self.alloc.free(b);
            self.alloc.free(c.binaries);
        }
        self.casks.deinit(self.alloc);
        // Free all allocated deb strings
        for (self.debs.items) |d| {
            self.alloc.free(d.name);
            self.alloc.free(d.version);
            self.alloc.free(d.sha256);
            for (d.files) |f| self.alloc.free(f);
            self.alloc.free(d.files);
        }
        self.debs.deinit(self.alloc);
        // Free history entries
        var hist_it = self.history.iterator();
        while (hist_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |h| {
                self.alloc.free(h.version);
                self.alloc.free(h.sha256);
            }
            entry.value_ptr.deinit(self.alloc);
        }
        self.history.deinit();
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
                // Free heap strings before removing from list
                self.alloc.free(old.name);
                self.alloc.free(old.version);
                self.alloc.free(old.sha256);
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
        const gop = try self.history.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.alloc, .{
            .version = self.alloc.dupe(u8, old.version) catch "",
            .sha256 = self.alloc.dupe(u8, old.sha256) catch "",
            .installed_at = old.installed_at,
        });
    }

    pub fn recordRemoval(self: *Database, name: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                const keg = self.kegs.items[i];
                self.alloc.free(keg.name);
                self.alloc.free(keg.version);
                self.alloc.free(keg.sha256);
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
                const old_cask = self.casks.items[i];
                self.alloc.free(old_cask.token);
                self.alloc.free(old_cask.version);
                for (old_cask.apps) |a| self.alloc.free(a);
                self.alloc.free(old_cask.apps);
                for (old_cask.binaries) |b| self.alloc.free(b);
                self.alloc.free(old_cask.binaries);
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
                const old_cask = self.casks.items[i];
                self.alloc.free(old_cask.token);
                self.alloc.free(old_cask.version);
                for (old_cask.apps) |a| self.alloc.free(a);
                self.alloc.free(old_cask.apps);
                for (old_cask.binaries) |b| self.alloc.free(b);
                self.alloc.free(old_cask.binaries);
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

    pub fn recordDebInstall(self: *Database, name: []const u8, version: []const u8, sha256: []const u8, files: []const []const u8) !void {
        const now = std.time.timestamp();

        // Remove existing entry for this package
        var i: usize = 0;
        while (i < self.debs.items.len) {
            if (std.mem.eql(u8, self.debs.items[i].name, name)) {
                const old_deb = self.debs.items[i];
                self.alloc.free(old_deb.name);
                self.alloc.free(old_deb.version);
                self.alloc.free(old_deb.sha256);
                for (old_deb.files) |f| self.alloc.free(f);
                self.alloc.free(old_deb.files);
                _ = self.debs.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Dupe file list
        const dfiles = try self.alloc.alloc([]const u8, files.len);
        for (files, 0..) |f, idx| dfiles[idx] = try self.alloc.dupe(u8, f);

        try self.debs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .files = dfiles,
            .sha256 = try self.alloc.dupe(u8, sha256),
            .installed_at = now,
        });
        try self.save();
    }

    pub fn recordDebRemoval(self: *Database, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.debs.items.len) {
            if (std.mem.eql(u8, self.debs.items[i].name, name)) {
                const old_deb = self.debs.items[i];
                self.alloc.free(old_deb.name);
                self.alloc.free(old_deb.version);
                self.alloc.free(old_deb.sha256);
                for (old_deb.files) |f| self.alloc.free(f);
                self.alloc.free(old_deb.files);
                _ = self.debs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.save();
    }

    pub fn findDeb(self: *Database, name: []const u8) ?DebRecord {
        for (self.debs.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn listInstalledDebs(self: *Database, alloc: std.mem.Allocator) ![]DebRecord {
        const result = try alloc.alloc(DebRecord, self.debs.items.len);
        @memcpy(result, self.debs.items);
        return result;
    }

    /// Write a JSON-escaped string to the writer (escapes \, ", control chars).
    pub fn writeJsonEscaped(writer: anytype, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch {},
                '\\' => writer.writeAll("\\\\") catch {},
                '\n' => writer.writeAll("\\n") catch {},
                '\r' => writer.writeAll("\\r") catch {},
                '\t' => writer.writeAll("\\t") catch {},
                else => {
                    if (c < 0x20) {
                        // Escape other control characters as \u00XX
                        const hex = "0123456789abcdef";
                        writer.writeAll("\\u00") catch {};
                        writer.writeAll(&.{ hex[c >> 4], hex[c & 0x0f] }) catch {};
                    } else {
                        writer.writeAll(&.{c}) catch {};
                    }
                },
            }
        }
    }

    /// Write a JSON-quoted string: "escaped_value"
    pub fn writeJsonString(writer: anytype, s: []const u8) void {
        writer.writeAll("\"") catch {};
        writeJsonEscaped(writer, s);
        writer.writeAll("\"") catch {};
    }

    fn save(self: *Database) !void {
        // Write to a temp file first, then rename atomically.
        // This ensures readers always see a complete file — a SIGKILL
        // or power-loss mid-write cannot corrupt state.json.
        const tmp_path = DB_PATH ++ ".tmp";
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

        const writer = file.deprecatedWriter();
        var write_ok = true;
        writer.writeAll("{\"kegs\":[") catch { write_ok = false; };
        for (self.kegs.items, 0..) |keg, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.writeAll("{\"name\":") catch {};
            writeJsonString(writer, keg.name);
            writer.writeAll(",\"version\":") catch {};
            writeJsonString(writer, keg.version);
            writer.writeAll(",\"sha256\":") catch {};
            writeJsonString(writer, keg.sha256);
            writer.print(",\"pinned\":{s},\"installed_at\":{d}}}", .{
                if (keg.pinned) "true" else "false", keg.installed_at,
            }) catch {};
        }
        writer.writeAll("],\"casks\":[") catch { write_ok = false; };
        for (self.casks.items, 0..) |c, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.writeAll("{\"token\":") catch {};
            writeJsonString(writer, c.token);
            writer.writeAll(",\"version\":") catch {};
            writeJsonString(writer, c.version);
            writer.writeAll(",\"apps\":[") catch {};
            for (c.apps, 0..) |a, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writeJsonString(writer, a);
            }
            writer.writeAll("],\"binaries\":[") catch {};
            for (c.binaries, 0..) |b, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writeJsonString(writer, b);
            }
            writer.writeAll("]}") catch {};
        }
        // Serialize history
        writer.writeAll("],\"history\":{") catch { write_ok = false; };
        var hist_iter = self.history.iterator();
        var hist_first = true;
        while (hist_iter.next()) |entry| {
            if (!hist_first) writer.writeAll(",") catch {};
            hist_first = false;
            writeJsonString(writer, entry.key_ptr.*);
            writer.writeAll(":[") catch {};
            for (entry.value_ptr.items, 0..) |h, hi| {
                if (hi > 0) writer.writeAll(",") catch {};
                writer.writeAll("{\"version\":") catch {};
                writeJsonString(writer, h.version);
                writer.writeAll(",\"sha256\":") catch {};
                writeJsonString(writer, h.sha256);
                writer.print(",\"installed_at\":{d}}}", .{h.installed_at}) catch {};
            }
            writer.writeAll("]") catch {};
        }
        // Serialize deb packages
        writer.writeAll("},\"deb_packages\":[") catch { write_ok = false; };
        for (self.debs.items, 0..) |d, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.writeAll("{\"name\":") catch {};
            writeJsonString(writer, d.name);
            writer.writeAll(",\"version\":") catch {};
            writeJsonString(writer, d.version);
            writer.writeAll(",\"sha256\":") catch {};
            writeJsonString(writer, d.sha256);
            writer.print(",\"installed_at\":{d},\"files\":[", .{d.installed_at}) catch {};
            for (d.files, 0..) |f, j| {
                if (j > 0) writer.writeAll(",") catch {};
                writeJsonString(writer, f);
            }
            writer.writeAll("]}") catch {};
        }
        writer.writeAll("]}") catch { write_ok = false; };

        file.sync() catch {};
        file.close();

        if (!write_ok) {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.SaveFailed;
        }

        // Atomic rename: readers see either the old complete file or the new one
        try std.fs.renameAbsolute(tmp_path, DB_PATH);
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

// ── Security tests ──

const testing = std.testing;

test "writeJsonEscaped escapes double quotes" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonEscaped(writer, "hello\"world");
    try testing.expectEqualStrings("hello\\\"world", stream.getWritten());
}

test "writeJsonEscaped escapes backslashes" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonEscaped(writer, "path\\to\\file");
    try testing.expectEqualStrings("path\\\\to\\\\file", stream.getWritten());
}

test "writeJsonEscaped escapes newlines and tabs" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonEscaped(writer, "line1\nline2\ttab");
    try testing.expectEqualStrings("line1\\nline2\\ttab", stream.getWritten());
}

test "writeJsonEscaped escapes control characters" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonEscaped(writer, "null\x00byte");
    try testing.expectEqualStrings("null\\u0000byte", stream.getWritten());
}

test "writeJsonEscaped passes normal text through" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonEscaped(writer, "normal-package_1.2.3");
    try testing.expectEqualStrings("normal-package_1.2.3", stream.getWritten());
}

test "writeJsonString produces valid JSON string" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    Database.writeJsonString(writer, "test\"pkg");
    try testing.expectEqualStrings("\"test\\\"pkg\"", stream.getWritten());
}

test "writeJsonEscaped blocks JSON injection payload" {
    // A malicious package name that tries to break out of JSON
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    const malicious = "evil\",\"pinned\":true,\"x\":\"";
    Database.writeJsonEscaped(writer, malicious);
    const escaped = stream.getWritten();
    // The escaped output must NOT contain unescaped quotes
    // Count unescaped quotes (quotes not preceded by backslash)
    var unescaped_quotes: usize = 0;
    for (escaped, 0..) |c, i| {
        if (c == '"' and (i == 0 or escaped[i - 1] != '\\')) {
            unescaped_quotes += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), unescaped_quotes);
}
