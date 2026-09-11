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
    probe_success: bool = false,
    probed_at: i64 = 0,
    probe_schema: u32 = 0,
    probe_platform: u32 = 0,
};

pub const CaskRecord = struct {
    token: []const u8,
    canonical_token: []const u8 = "",
    version: []const u8,
    sha256: []const u8 = "",
    apps: []const []const u8,
    binaries: []const []const u8,
    probe_success: bool = false,
    probed_at: i64 = 0,
    probe_schema: u32 = 0,
    probe_platform: u32 = 0,
};

pub const HistoryEntry = struct {
    version: []const u8,
    sha256: []const u8,
    installed_at: i64,
};

pub const DebRecord = struct {
    name: []const u8,
    version: []const u8,
    files: []const []const u8,
    sha256: []const u8 = "",
    installed_at: i64 = 0,
};

pub const Database = struct {
    alloc: std.mem.Allocator,
    path: []const u8 = DB_PATH,
    kegs: std.ArrayList(Keg),
    casks: std.ArrayList(CaskRecord),
    debs: std.ArrayList(DebRecord),
    history: std.StringHashMap(std.ArrayList(HistoryEntry)),
    dirty: bool = false,
    loaded_mtime_ns: ?i96 = null,

    pub const MAX_DB_SIZE: usize = 16 * 1024 * 1024;

    pub fn open(alloc: std.mem.Allocator) !Database {
        return openAt(alloc, DB_PATH);
    }

    pub fn openAt(alloc: std.mem.Allocator, path: []const u8) !Database {
        var db = Database{
            .alloc = alloc,
            .path = path,
            .kegs = .empty,
            .casks = .empty,
            .debs = .empty,
            .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(alloc),
        };

        const lib_io = paths.safe_io;
        const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return db;
        defer file.close(lib_io);

        const max_state_bytes = MAX_DB_SIZE;
        const st = file.stat(lib_io) catch return db;
        db.loaded_mtime_ns = st.mtime.nanoseconds;
        const sz = @min(st.size, max_state_bytes);
        const contents = alloc.alloc(u8, sz) catch return db;
        const n_read = file.readPositionalAll(lib_io, contents, 0) catch {
            alloc.free(contents);
            std.Io.File.stderr().writeStreamingAll(paths.safe_io, "warning: nanobrew database read failed: " ++ DB_PATH ++ "\n") catch {};
            return db;
        };
        defer alloc.free(contents);
        const data = contents[0..n_read];
        if (data.len == 0) return db;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch {
            std.Io.File.stderr().writeStreamingAll(paths.safe_io, "warning: nanobrew database parse failed; returning empty database. File may be corrupted: " ++ DB_PATH ++ "\n") catch {};
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
                            const kprobe = getBool(item.object, "probe_success");
                            const kprobed = getInt(item.object, "probed_at");
                            const kprobe_schema = getU32(item.object, "probe_schema");
                            const kprobe_platform = getU32(item.object, "probe_platform");
                            // All-or-nothing: free any prior dupes if a
                            // later alloc or append fails so we never
                            // leak a partial Keg on OOM.
                            const k_name = alloc.dupe(u8, kname) catch continue;
                            const k_ver = alloc.dupe(u8, kver) catch {
                                alloc.free(k_name);
                                continue;
                            };
                            const k_sha = alloc.dupe(u8, ksha) catch {
                                alloc.free(k_name);
                                alloc.free(k_ver);
                                continue;
                            };
                            db.kegs.append(alloc, .{
                                .name = k_name,
                                .version = k_ver,
                                .sha256 = k_sha,
                                .pinned = kpinned,
                                .installed_at = kinst,
                                .probe_success = kprobe,
                                .probed_at = kprobed,
                                .probe_schema = kprobe_schema,
                                .probe_platform = kprobe_platform,
                            }) catch {
                                alloc.free(k_name);
                                alloc.free(k_ver);
                                alloc.free(k_sha);
                            };
                        }
                    }
                }
            }
            if (parsed.value.object.get("casks")) |casks_val| {
                if (casks_val == .array) {
                    for (casks_val.array.items) |item| {
                        if (item != .object) continue;
                        const ctoken = getStr(item.object, "token") orelse continue;
                        const ccanonical = getStr(item.object, "canonical_token") orelse ctoken;
                        const cver = getStr(item.object, "version") orelse continue;
                        const csha = getStr(item.object, "sha256") orelse "";
                        const cprobe = getBool(item.object, "probe_success");
                        const cprobed = getInt(item.object, "probed_at");
                        const cprobe_schema = getU32(item.object, "probe_schema");
                        const cprobe_platform = getU32(item.object, "probe_platform");

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

                        const c_token = alloc.dupe(u8, ctoken) catch continue;
                        const c_canonical = alloc.dupe(u8, ccanonical) catch {
                            alloc.free(c_token);
                            continue;
                        };
                        const c_ver = alloc.dupe(u8, cver) catch {
                            alloc.free(c_token);
                            alloc.free(c_canonical);
                            continue;
                        };
                        const c_sha = alloc.dupe(u8, csha) catch {
                            alloc.free(c_token);
                            alloc.free(c_canonical);
                            alloc.free(c_ver);
                            continue;
                        };
                        const c_apps = capps.toOwnedSlice(alloc) catch {
                            alloc.free(c_token);
                            alloc.free(c_canonical);
                            alloc.free(c_ver);
                            alloc.free(c_sha);
                            continue;
                        };
                        const c_bins = cbins.toOwnedSlice(alloc) catch {
                            alloc.free(c_token);
                            alloc.free(c_canonical);
                            alloc.free(c_ver);
                            alloc.free(c_sha);
                            for (c_apps) |s| alloc.free(s);
                            alloc.free(c_apps);
                            continue;
                        };
                        db.casks.append(alloc, .{
                            .token = c_token,
                            .canonical_token = c_canonical,
                            .version = c_ver,
                            .sha256 = c_sha,
                            .apps = c_apps,
                            .binaries = c_bins,
                            .probe_success = cprobe,
                            .probed_at = cprobed,
                            .probe_schema = cprobe_schema,
                            .probe_platform = cprobe_platform,
                        }) catch {
                            alloc.free(c_token);
                            alloc.free(c_canonical);
                            alloc.free(c_ver);
                            alloc.free(c_sha);
                            for (c_apps) |s| alloc.free(s);
                            alloc.free(c_apps);
                            for (c_bins) |s| alloc.free(s);
                            alloc.free(c_bins);
                        };
                    }
                }
            }
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
                                const h_ver_s = alloc.dupe(u8, hver) catch continue;
                                const h_sha_s = alloc.dupe(u8, hsha) catch {
                                    alloc.free(h_ver_s);
                                    continue;
                                };
                                entries.append(alloc, .{
                                    .version = h_ver_s,
                                    .sha256 = h_sha_s,
                                    .installed_at = hinst,
                                }) catch {
                                    alloc.free(h_ver_s);
                                    alloc.free(h_sha_s);
                                };
                            }
                        }
                        db.history.put(pkg_name, entries) catch {};
                    }
                }
            }
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

                        const d_name = alloc.dupe(u8, dname) catch continue;
                        const d_ver = alloc.dupe(u8, dver) catch {
                            alloc.free(d_name);
                            continue;
                        };
                        const d_files = dfiles.toOwnedSlice(alloc) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            continue;
                        };
                        const d_sha = alloc.dupe(u8, dsha) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            for (d_files) |s| alloc.free(s);
                            alloc.free(d_files);
                            continue;
                        };
                        db.debs.append(alloc, .{
                            .name = d_name,
                            .version = d_ver,
                            .files = d_files,
                            .sha256 = d_sha,
                            .installed_at = dinst,
                        }) catch {
                            alloc.free(d_name);
                            alloc.free(d_ver);
                            for (d_files) |s| alloc.free(s);
                            alloc.free(d_files);
                            alloc.free(d_sha);
                        };
                    }
                }
            }
        }

        return db;
    }

    pub fn close(self: *Database) void {
        self.save() catch |err| {
            var _warn_buf: [256]u8 = undefined;
            const _warn_msg = std.fmt.bufPrint(&_warn_buf, "nb: WARNING: failed to save package database: {}\n", .{err}) catch "nb: WARNING: failed to save package database\n";
            std.Io.File.stderr().writeStreamingAll(paths.safe_io, _warn_msg) catch {};
        };
        for (self.kegs.items) |keg| {
            self.alloc.free(keg.name);
            self.alloc.free(keg.version);
            self.alloc.free(keg.sha256);
        }
        self.kegs.deinit(self.alloc);
        for (self.casks.items) |c| {
            self.alloc.free(c.token);
            self.alloc.free(c.canonical_token);
            self.alloc.free(c.version);
            self.alloc.free(c.sha256);
            for (c.apps) |a| self.alloc.free(a);
            self.alloc.free(c.apps);
            for (c.binaries) |b| self.alloc.free(b);
            self.alloc.free(c.binaries);
        }
        self.casks.deinit(self.alloc);
        for (self.debs.items) |d| {
            self.alloc.free(d.name);
            self.alloc.free(d.version);
            self.alloc.free(d.sha256);
            for (d.files) |f| self.alloc.free(f);
            self.alloc.free(d.files);
        }
        self.debs.deinit(self.alloc);
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

    fn nowUnix() i64 {
        const io = paths.safe_io;
        const now = std.Io.Timestamp.now(io, .real);
        return @as(i64, @truncate(@divTrunc(now.nanoseconds, std.time.ns_per_s)));
    }

    pub fn recordInstall(self: *Database, name: []const u8, version: []const u8, sha256: []const u8) !void {
        const now = nowUnix();

        var i: usize = 0;
        while (i < self.kegs.items.len) {
            if (std.mem.eql(u8, self.kegs.items[i].name, name)) {
                const old = self.kegs.items[i];
                self.pushHistory(name, old) catch {};
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
            .probe_success = false,
            .probed_at = 0,
            .probe_schema = 0,
            .probe_platform = 0,
        });
        self.dirty = true;
    }

    pub fn recordKegProbe(
        self: *Database,
        name: []const u8,
        version: []const u8,
        sha256: []const u8,
        success: bool,
        schema: u32,
        platform: u32,
    ) !void {
        for (self.kegs.items) |*keg| {
            if (!std.mem.eql(u8, keg.name, name) or
                !std.mem.eql(u8, keg.version, version) or
                !std.mem.eql(u8, keg.sha256, sha256)) continue;
            keg.probe_success = success;
            keg.probed_at = nowUnix();
            keg.probe_schema = schema;
            keg.probe_platform = platform;
            self.dirty = true;
            return;
        }
        return error.IdentityChanged;
    }

    fn pushHistory(self: *Database, name: []const u8, old: Keg) !void {
        const gop = try self.history.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        // All-or-nothing: if append fails we must free both dupes, and
        // if the second dupe fails we must free the first. `catch ""`
        // on a leaked dupe would silently leak on OOM.
        const ver_owned = try self.alloc.dupe(u8, old.version);
        errdefer self.alloc.free(ver_owned);
        const sha_owned = try self.alloc.dupe(u8, old.sha256);
        errdefer self.alloc.free(sha_owned);
        try gop.value_ptr.append(self.alloc, .{
            .version = ver_owned,
            .sha256 = sha_owned,
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
        self.dirty = true;
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

    pub fn recordCaskInstall(self: *Database, token: []const u8, canonical_token: []const u8, version: []const u8, sha256: []const u8, apps: []const []const u8, binaries: []const []const u8) !void {
        // Build the replacement first: callers may pass fields borrowed from
        // the existing record, and allocation failure must preserve that record.
        const replacement = try dupeCaskRecord(self.alloc, .{ .token = token, .canonical_token = canonical_token, .version = version, .sha256 = sha256, .apps = apps, .binaries = binaries });
        errdefer freeCaskRecord(self.alloc, replacement);
        try self.casks.ensureUnusedCapacity(self.alloc, 1);
        var i: usize = 0;
        while (i < self.casks.items.len) {
            const existing = self.casks.items[i];
            if (std.mem.eql(u8, existing.token, replacement.token) or
                std.mem.eql(u8, existing.canonical_token, replacement.canonical_token))
            {
                freeCaskRecord(self.alloc, existing);
                _ = self.casks.orderedRemove(i);
            } else i += 1;
        }
        self.casks.appendAssumeCapacity(replacement);
        self.dirty = true;
    }

    pub fn recordCaskProbe(
        self: *Database,
        canonical_token: []const u8,
        version: []const u8,
        sha256: []const u8,
        success: bool,
        schema: u32,
        platform: u32,
    ) !void {
        for (self.casks.items) |*cask| {
            if (!std.mem.eql(u8, cask.canonical_token, canonical_token) or
                !std.mem.eql(u8, cask.version, version) or
                !std.mem.eql(u8, cask.sha256, sha256)) continue;
            cask.probe_success = success;
            cask.probed_at = nowUnix();
            cask.probe_schema = schema;
            cask.probe_platform = platform;
            self.dirty = true;
            return;
        }
        return error.IdentityChanged;
    }

    /// Persist the database to disk now if there are unsaved changes, without
    /// closing it. close() still flushes implicitly; this lets a long-running
    /// multi-item install checkpoint progress so an interrupted run does not
    /// lose records for items that already completed (issue #302).
    pub fn flush(self: *Database) !void {
        return self.save();
    }

    pub fn recordCaskRemoval(self: *Database, token: []const u8, alloc: std.mem.Allocator) !void {
        _ = alloc;
        var i: usize = 0;
        while (i < self.casks.items.len) {
            const existing = self.casks.items[i];
            if (std.mem.eql(u8, existing.token, token) or
                std.mem.eql(u8, existing.canonical_token, token))
            {
                const old_cask = existing;
                self.alloc.free(old_cask.token);
                self.alloc.free(old_cask.canonical_token);
                self.alloc.free(old_cask.version);
                self.alloc.free(old_cask.sha256);
                for (old_cask.apps) |a| self.alloc.free(a);
                self.alloc.free(old_cask.apps);
                for (old_cask.binaries) |b| self.alloc.free(b);
                self.alloc.free(old_cask.binaries);
                _ = self.casks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.dirty = true;
    }

    pub fn findCask(self: *Database, token: []const u8) ?CaskRecord {
        for (self.casks.items) |c| {
            if (std.mem.eql(u8, c.token, token) or
                std.mem.eql(u8, c.canonical_token, token)) return c;
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
                self.dirty = true;
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
        var ts_now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts_now);
        const now: i64 = ts_now.sec;

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

        const dfiles = try self.alloc.alloc([]const u8, files.len);
        for (files, 0..) |f, idx| dfiles[idx] = try self.alloc.dupe(u8, f);

        try self.debs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .files = dfiles,
            .sha256 = try self.alloc.dupe(u8, sha256),
            .installed_at = now,
        });
        self.dirty = true;
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
        self.dirty = true;
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

    fn writeJsonEscapedFallible(writer: anytype, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        try writer.writeAll("\\u00");
                        try writer.writeAll(&.{ hex[c >> 4], hex[c & 0x0f] });
                    } else {
                        try writer.writeAll(&.{c});
                    }
                },
            }
        }
    }

    pub fn writeJsonEscaped(writer: anytype, s: []const u8) void {
        writeJsonEscapedFallible(writer, s) catch {};
    }

    fn writeJsonStringFallible(writer: anytype, s: []const u8) !void {
        try writer.writeAll("\"");
        try writeJsonEscapedFallible(writer, s);
        try writer.writeAll("\"");
    }

    pub fn writeJsonString(writer: anytype, s: []const u8) void {
        writeJsonStringFallible(writer, s) catch {};
    }

    fn dbMtimeNs(self: *Database) ?i96 {
        const io = paths.safe_io;
        const file = std.Io.Dir.openFileAbsolute(io, self.path, .{}) catch return null;
        defer file.close(io);
        const st = file.stat(io) catch return null;
        return st.mtime.nanoseconds;
    }

    fn save(self: *Database) !void {
        if (!self.dirty) return;
        const lib_io = paths.safe_io;
        const lock_path = try std.fmt.allocPrint(self.alloc, "{s}.lock", .{self.path});
        defer self.alloc.free(lock_path);
        const lock_file = try std.Io.Dir.createFileAbsolute(lib_io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
        });
        defer lock_file.close(lib_io);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}.{d}", .{
            self.path, std.c.getpid(), std.Thread.getCurrentId(),
        }) catch return error.PathTooLong;
        try self.writeSnapshot(tmp_path);
        errdefer std.Io.Dir.deleteFileAbsolute(lib_io, tmp_path) catch {};

        // Optimistic concurrency guard: never replace state that changed since
        // this Database snapshot was opened. Process-unique temp paths prevent
        // concurrent writers from corrupting each other's staging files.
        const current_mtime = self.dbMtimeNs();
        const unchanged = if (self.loaded_mtime_ns) |loaded|
            if (current_mtime) |current| current == loaded else false
        else
            current_mtime == null;
        if (!unchanged) {
            std.Io.Dir.deleteFileAbsolute(lib_io, tmp_path) catch {};
            return error.ConcurrentModification;
        }

        try std.Io.Dir.renameAbsolute(tmp_path, self.path, lib_io);
        self.loaded_mtime_ns = self.dbMtimeNs();
        self.dirty = false;
    }
    /// Serialize a candidate without publishing it or changing this snapshot's
    /// persistence state. Cask transactions activate this file with the payload.
    pub fn writeSnapshot(self: *Database, snapshot_path: []const u8) !void {
        const lib_io = paths.safe_io;
        const file = try std.Io.Dir.createFileAbsolute(lib_io, snapshot_path, .{});
        errdefer std.Io.Dir.deleteFileAbsolute(lib_io, snapshot_path) catch {};

        var file_open = true;
        errdefer if (file_open) file.close(lib_io);
        var write_buf: [65536]u8 = undefined;
        var writer = file.writer(lib_io, &write_buf);
        try writer.interface.writeAll("{\"kegs\":[");
        for (self.kegs.items, 0..) |keg, i| {
            if (i > 0) try writer.interface.writeAll(",");
            try writer.interface.writeAll("{\"name\":");
            try writeJsonStringFallible(&writer.interface, keg.name);
            try writer.interface.writeAll(",\"version\":");
            try writeJsonStringFallible(&writer.interface, keg.version);
            try writer.interface.writeAll(",\"sha256\":");
            try writeJsonStringFallible(&writer.interface, keg.sha256);
            try writer.interface.print(",\"pinned\":{s},\"installed_at\":{d},\"probe_success\":{s},\"probed_at\":{d},\"probe_schema\":{d},\"probe_platform\":{d}}}", .{
                if (keg.pinned) "true" else "false",
                keg.installed_at,
                if (keg.probe_success) "true" else "false",
                keg.probed_at,
                keg.probe_schema,
                keg.probe_platform,
            });
        }
        try writer.interface.writeAll("],\"casks\":[");
        for (self.casks.items, 0..) |c, i| {
            if (i > 0) try writer.interface.writeAll(",");
            try writer.interface.writeAll("{\"token\":");
            try writeJsonStringFallible(&writer.interface, c.token);
            try writer.interface.writeAll(",\"canonical_token\":");
            try writeJsonStringFallible(&writer.interface, c.canonical_token);
            try writer.interface.writeAll(",\"version\":");
            try writeJsonStringFallible(&writer.interface, c.version);
            try writer.interface.writeAll(",\"sha256\":");
            try writeJsonStringFallible(&writer.interface, c.sha256);
            try writer.interface.print(",\"probe_success\":{s},\"probed_at\":{d},\"probe_schema\":{d},\"probe_platform\":{d}", .{
                if (c.probe_success) "true" else "false",
                c.probed_at,
                c.probe_schema,
                c.probe_platform,
            });
            try writer.interface.writeAll(",\"apps\":[");
            for (c.apps, 0..) |a, j| {
                if (j > 0) try writer.interface.writeAll(",");
                try writeJsonStringFallible(&writer.interface, a);
            }
            try writer.interface.writeAll("],\"binaries\":[");
            for (c.binaries, 0..) |b, j| {
                if (j > 0) try writer.interface.writeAll(",");
                try writeJsonStringFallible(&writer.interface, b);
            }
            try writer.interface.writeAll("]}");
        }
        try writer.interface.writeAll("],\"history\":{");
        var hist_iter = self.history.iterator();
        var hist_first = true;
        while (hist_iter.next()) |entry| {
            if (!hist_first) try writer.interface.writeAll(",");
            hist_first = false;
            try writeJsonStringFallible(&writer.interface, entry.key_ptr.*);
            try writer.interface.writeAll(":[");
            for (entry.value_ptr.items, 0..) |h, hi| {
                if (hi > 0) try writer.interface.writeAll(",");
                try writer.interface.writeAll("{\"version\":");
                try writeJsonStringFallible(&writer.interface, h.version);
                try writer.interface.writeAll(",\"sha256\":");
                try writeJsonStringFallible(&writer.interface, h.sha256);
                try writer.interface.print(",\"installed_at\":{d}}}", .{h.installed_at});
            }
            try writer.interface.writeAll("]");
        }
        try writer.interface.writeAll("},\"deb_packages\":[");
        for (self.debs.items, 0..) |d, i| {
            if (i > 0) try writer.interface.writeAll(",");
            try writer.interface.writeAll("{\"name\":");
            try writeJsonStringFallible(&writer.interface, d.name);
            try writer.interface.writeAll(",\"version\":");
            try writeJsonStringFallible(&writer.interface, d.version);
            try writer.interface.writeAll(",\"sha256\":");
            try writeJsonStringFallible(&writer.interface, d.sha256);
            try writer.interface.print(",\"installed_at\":{d},\"files\":[", .{d.installed_at});
            for (d.files, 0..) |f, j| {
                if (j > 0) try writer.interface.writeAll(",");
                try writeJsonStringFallible(&writer.interface, f);
            }
            try writer.interface.writeAll("]}");
        }
        try writer.interface.writeAll("]}");
        try writer.interface.flush();
        try file.sync(lib_io);
        file.close(lib_io);
        file_open = false;
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

fn getU32(obj: std.json.ObjectMap, key: []const u8) u32 {
    const value = getInt(obj, key);
    if (value < 0 or value > std.math.maxInt(u32)) return 0;
    return @intCast(value);
}

const testing = std.testing;

const TestBufWriter = struct {
    buf: [20480]u8 = undefined,
    pos: usize = 0,
    pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
    pub fn written(self: *const @This()) []const u8 {
        return self.buf[0..self.pos];
    }
    pub fn reset(self: *@This()) void {
        self.pos = 0;
    }
};

test "writeJsonEscaped escapes double quotes" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "hello\"world");
    try testing.expectEqualStrings("hello\\\"world", w.written());
}

test "writeJsonEscaped escapes backslashes" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "path\\to\\file");
    try testing.expectEqualStrings("path\\\\to\\\\file", w.written());
}

test "writeJsonEscaped escapes newlines and tabs" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "line1\nline2\ttab");
    try testing.expectEqualStrings("line1\\nline2\\ttab", w.written());
}

test "writeJsonEscaped escapes control characters" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "null\x00byte");
    try testing.expectEqualStrings("null\\u0000byte", w.written());
}

test "writeJsonEscaped passes normal text through" {
    var w: TestBufWriter = .{};
    Database.writeJsonEscaped(&w, "normal-package_1.2.3");
    try testing.expectEqualStrings("normal-package_1.2.3", w.written());
}

test "writeJsonString produces valid JSON string" {
    var w: TestBufWriter = .{};
    Database.writeJsonString(&w, "test\"pkg");
    try testing.expectEqualStrings("\"test\\\"pkg\"", w.written());
}

test "writeJsonEscaped blocks JSON injection payload" {
    var w: TestBufWriter = .{};
    const malicious = "evil\",\"pinned\":true,\"x\":\"";
    Database.writeJsonEscaped(&w, malicious);
    const escaped = w.written();
    var unescaped_quotes: usize = 0;
    for (escaped, 0..) |c, i| {
        if (c == '"' and (i == 0 or escaped[i - 1] != '\\')) {
            unescaped_quotes += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), unescaped_quotes);
}

test "legacy records default to unknown probe evidence" {
    const keg: Keg = .{ .name = "pkg", .version = "1.0" };
    try testing.expect(!keg.probe_success);
    try testing.expectEqual(@as(i64, 0), keg.probed_at);
    try testing.expectEqual(@as(u32, 0), keg.probe_schema);
    try testing.expectEqual(@as(u32, 0), keg.probe_platform);

    const cask: CaskRecord = .{
        .token = "app",
        .version = "1.0",
        .apps = &.{},
        .binaries = &.{},
    };
    try testing.expect(!cask.probe_success);
    try testing.expectEqual(@as(i64, 0), cask.probed_at);
    try testing.expectEqual(@as(u32, 0), cask.probe_schema);
    try testing.expectEqual(@as(u32, 0), cask.probe_platform);
}

test "probe results persist against current package records" {
    var db: Database = .{
        .alloc = testing.allocator,
        .kegs = .empty,
        .casks = .empty,
        .debs = .empty,
        .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(testing.allocator),
    };
    defer {
        // This is an in-memory unit fixture; prevent close() from writing the
        // process-wide production DB path.
        db.dirty = false;
        db.close();
    }

    try db.recordInstall("pkg", "1.0", "abc");
    try db.recordKegProbe("pkg", "1.0", "abc", true, 7, 8);
    var keg = db.findKeg("pkg").?;
    try testing.expect(keg.probe_success);
    try testing.expect(keg.probed_at > 0);
    try testing.expectEqual(@as(u32, 7), keg.probe_schema);
    try testing.expectEqual(@as(u32, 8), keg.probe_platform);

    try testing.expectError(error.IdentityChanged, db.recordKegProbe("pkg", "2.0", "abc", false, 7, 8));
    try db.recordKegProbe("pkg", "1.0", "abc", false, 9, 10);
    keg = db.findKeg("pkg").?;
    try testing.expect(!keg.probe_success);
    try testing.expectEqual(@as(u32, 9), keg.probe_schema);
    try testing.expectEqual(@as(u32, 10), keg.probe_platform);

    try db.recordCaskInstall("alias", "canonical", "2.0", "def", &.{"App.app"}, &.{});
    try db.recordCaskProbe("canonical", "2.0", "def", true, 11, 12);
    var cask = db.findCask("canonical").?;
    try testing.expect(cask.probe_success);
    try testing.expect(cask.probed_at > 0);
    try testing.expectEqual(@as(u32, 11), cask.probe_schema);
    try testing.expectEqual(@as(u32, 12), cask.probe_platform);

    try testing.expectError(error.IdentityChanged, db.recordCaskProbe("canonical", "3.0", "def", false, 11, 12));
    try db.recordCaskProbe("canonical", "2.0", "def", false, 13, 14);
    cask = db.findCask("canonical").?;
    try testing.expect(!cask.probe_success);
    try testing.expectEqual(@as(u32, 13), cask.probe_schema);
    try testing.expectEqual(@as(u32, 14), cask.probe_platform);
}

fn dupeStrings(alloc: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try alloc.alloc([]const u8, strings.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |s| alloc.free(s);
        alloc.free(result);
    }
    for (strings, 0..) |s, i| {
        result[i] = try alloc.dupe(u8, s);
        count += 1;
    }
    return result;
}

fn dupeCaskRecord(alloc: std.mem.Allocator, c: CaskRecord) !CaskRecord {
    const token = try alloc.dupe(u8, c.token);
    errdefer alloc.free(token);
    const canonical = try alloc.dupe(u8, c.canonical_token);
    errdefer alloc.free(canonical);
    const version = try alloc.dupe(u8, c.version);
    errdefer alloc.free(version);
    const sha = try alloc.dupe(u8, c.sha256);
    errdefer alloc.free(sha);
    const apps = try dupeStrings(alloc, c.apps);
    errdefer {
        for (apps) |s| alloc.free(s);
        alloc.free(apps);
    }
    const bins = try dupeStrings(alloc, c.binaries);
    return .{ .token = token, .canonical_token = canonical, .version = version, .sha256 = sha, .apps = apps, .binaries = bins };
}

fn freeCaskRecord(alloc: std.mem.Allocator, c: CaskRecord) void {
    alloc.free(c.token);
    alloc.free(c.canonical_token);
    alloc.free(c.version);
    alloc.free(c.sha256);
    for (c.apps) |s| alloc.free(s);
    alloc.free(c.apps);
    for (c.binaries) |s| alloc.free(s);
    alloc.free(c.binaries);
}

test "cask replacement preserves borrowed fields and is allocation atomic" {
    try testing.checkAllAllocationFailures(testing.allocator, testCaskReplacementAllocation, .{});
}

fn testCaskReplacementAllocation(alloc: std.mem.Allocator) !void {
    var db: Database = .{
        .alloc = alloc,
        .kegs = .empty,
        .casks = .empty,
        .debs = .empty,
        .history = std.StringHashMap(std.ArrayList(HistoryEntry)).init(alloc),
    };
    defer {
        db.dirty = false;
        db.close();
    }
    try db.recordCaskInstall("alias", "canonical", "1", "old-sha", &.{"App.app"}, &.{"tool"});
    const old = db.findCask("alias").?;
    db.recordCaskInstall(old.token, old.canonical_token, "2", "new-sha", old.apps, old.binaries) catch |err| {
        try testing.expectEqualStrings("1", db.findCask("alias").?.version);
        try testing.expectEqualStrings("old-sha", db.findCask("alias").?.sha256);
        return err;
    };
    const new = db.findCask("canonical").?;
    try testing.expectEqualStrings("alias", new.token);
    try testing.expectEqualStrings("2", new.version);
    try testing.expectEqualStrings("App.app", new.apps[0]);
    try testing.expectEqualStrings("tool", new.binaries[0]);
}
