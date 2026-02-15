// nanobrew — Dependency resolver
//
// Recursively fetches formula metadata for all transitive dependencies,
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
        self.formulae.deinit();
        self.edges.deinit();
    }

    pub fn resolve(self: *DepResolver, name: []const u8) !void {
        if (self.formulae.contains(name)) return;

        const f = try api.fetchFormula(self.alloc, name);
        const owned_name = try self.alloc.dupe(u8, f.name);
        try self.formulae.put(owned_name, f);
        try self.edges.put(owned_name, f.dependencies);

        for (f.dependencies) |dep| {
            try self.resolve(dep);
        }
    }

    pub fn topologicalSort(self: *DepResolver) ![]const Formula {
        var in_degree = std.StringHashMap(u32).init(self.alloc);
        defer in_degree.deinit();

        var name_iter = self.formulae.keyIterator();
        while (name_iter.next()) |name| {
            try in_degree.put(name.*, 0);
        }

        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            for (entry.value_ptr.*) |dep| {
                if (in_degree.getPtr(dep)) |count| {
                    count.* += 1;
                }
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
            const name = queue.orderedRemove(0);
            const f = self.formulae.get(name) orelse continue;
            try result.append(self.alloc, f);

            var re_iter = self.edges.iterator();
            while (re_iter.next()) |entry| {
                for (entry.value_ptr.*) |dep| {
                    if (std.mem.eql(u8, dep, name)) {
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
