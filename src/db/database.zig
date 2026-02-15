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
};

pub const Database = struct {
    alloc: std.mem.Allocator,
    kegs: std.ArrayList(Keg),

    pub fn open() !Database {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const alloc = gpa.allocator();

        var db = Database{
            .alloc = alloc,
            .kegs = .empty,
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
                            db.kegs.append(alloc, .{
                                .name = alloc.dupe(u8, kname) catch continue,
                                .version = alloc.dupe(u8, kver) catch continue,
                                .sha256 = alloc.dupe(u8, ksha) catch continue,
                            }) catch {};
                        }
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
        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                _ = self.kegs.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        try self.kegs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .sha256 = try self.alloc.dupe(u8, sha256),
        });
        try self.save();
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

    fn save(self: *Database) !void {
        const file = try std.fs.createFileAbsolute(DB_PATH, .{});
        defer file.close();

        const writer = file.deprecatedWriter();
        writer.writeAll("{\"kegs\":[") catch return;
        for (self.kegs.items, 0..) |keg, i| {
            if (i > 0) writer.writeAll(",") catch {};
            writer.print("{{\"name\":\"{s}\",\"version\":\"{s}\",\"sha256\":\"{s}\"}}", .{
                keg.name, keg.version, keg.sha256,
            }) catch {};
        }
        writer.writeAll("]}") catch {};
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}
