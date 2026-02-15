// nanobrew — Dependency resolver
//
// BFS parallel resolution: fetches each dependency level in parallel,
// then produces a topological sort (install order).
// Uses Kahn's algorithm with cycle detection.

const std = @import("std");
const api = @import("../api/client.zig");
const Formula = @import("../api/formula.zig").Formula;

pub const DepResolver = struct {
    alloc: std.mem.Allocator,
    formulae: std.StringHashMap(Formula),
    edges: std.StringHashMap([]const []const u8),

    pub fn init(alloc: std.mem.Allocator) DepResolver {
        return .{
            .alloc = alloc,
            .formulae = std.StringHashMap(Formula).init(alloc),
            .edges = std.StringHashMap([]const []const u8).init(alloc),
        };
    }

    pub fn deinit(self: *DepResolver) void {
        var it = self.formulae.valueIterator();
        while (it.next()) |f| f.deinit(self.alloc);
        self.formulae.deinit();
        self.edges.deinit();
    }

    /// Resolve a formula and all its transitive dependencies using BFS.
    /// Each BFS level fetches all unknown deps in parallel.
    pub fn resolve(self: *DepResolver, name: []const u8) !void {
        if (self.formulae.contains(name)) return;

        // Seed the frontier with the requested name
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(self.alloc);
        try frontier.append(self.alloc, name);

        // BFS: each iteration fetches all frontier names in parallel
        while (frontier.items.len > 0) {
            const batch_size = frontier.items.len;

            // Allocate result slots (one per frontier entry)
            const results = try self.alloc.alloc(?Formula, batch_size);
            defer self.alloc.free(results);
            @memset(results, null);

            if (batch_size == 1) {
                // Single item — no thread overhead
                results[0] = api.fetchFormula(self.alloc, frontier.items[0]) catch null;
            } else {
                // Parallel fetch
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(self.alloc);

                for (frontier.items, 0..) |dep_name, i| {
                    const t = std.Thread.spawn(.{}, fetchWorker, .{ self.alloc, dep_name, &results[i] }) catch {
                        // Fallback: fetch inline if thread spawn fails
                        results[i] = api.fetchFormula(self.alloc, dep_name) catch null;
                        continue;
                    };
                    threads.append(self.alloc, t) catch continue;
                }
                for (threads.items) |t| t.join();
            }

            // Collect results, discover next frontier
            frontier.clearRetainingCapacity();
            for (results) |maybe_f| {
                const f = maybe_f orelse continue;
                if (self.formulae.contains(f.name)) {
                    var dup = f;
                    dup.deinit(self.alloc);
                    continue;
                }
                self.formulae.put(f.name, f) catch continue;
                self.edges.put(f.name, f.dependencies) catch continue;

                // Queue any unseen deps for next BFS level
                for (f.dependencies) |dep| {
                    if (!self.formulae.contains(dep)) {
                        // Avoid duplicates in frontier
                        var already_queued = false;
                        for (frontier.items) |queued| {
                            if (std.mem.eql(u8, queued, dep)) {
                                already_queued = true;
                                break;
                            }
                        }
                        if (!already_queued) {
                            frontier.append(self.alloc, dep) catch continue;
                        }
                    }
                }
            }
        }
    }

    pub fn topologicalSort(self: *DepResolver) ![]const Formula {
        var in_degree = std.StringHashMap(u32).init(self.alloc);
        defer in_degree.deinit();

        var name_iter = self.formulae.keyIterator();
        while (name_iter.next()) |name_ptr| {
            try in_degree.put(name_ptr.*, 0);
        }

        // in_degree[name] = number of deps name has (must be installed before name)
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            if (in_degree.getPtr(entry.key_ptr.*)) |count| {
                count.* = @intCast(entry.value_ptr.*.len);
            }
        }

        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.alloc);

        var deg_iter = in_degree.iterator();
        while (deg_iter.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(self.alloc, entry.key_ptr.*);
            }
        }

        var result: std.ArrayList(Formula) = .empty;

        while (queue.items.len > 0) {
            const sorted_name = queue.orderedRemove(0);
            const f = self.formulae.get(sorted_name) orelse continue;
            try result.append(self.alloc, f);

            var re_iter = self.edges.iterator();
            while (re_iter.next()) |entry| {
                for (entry.value_ptr.*) |dep| {
                    if (std.mem.eql(u8, dep, sorted_name)) {
                        if (in_degree.getPtr(entry.key_ptr.*)) |count| {
                            count.* -= 1;
                            if (count.* == 0) {
                                try queue.append(self.alloc, entry.key_ptr.*);
                            }
                        }
                    }
                }
            }
        }

        if (result.items.len != self.formulae.count()) {
            return error.DependencyCycle;
        }

        return try result.toOwnedSlice(self.alloc);
    }
};

fn fetchWorker(alloc: std.mem.Allocator, name: []const u8, slot: *?Formula) void {
    slot.* = api.fetchFormula(alloc, name) catch null;
}
