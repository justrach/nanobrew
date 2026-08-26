// nanobrew — Dependency resolver
//
// BFS parallel resolution: fetches each dependency level in parallel using a
// bounded worker pool (<= 8 threads). Each worker owns a persistent
// std.http.Client that it reuses across every frontier item it picks up via
// an atomic work-index, eliminating per-item DNS + TLS handshake cost.
// Produces a topological sort (install order) via Kahn's algorithm with
// cycle detection.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const proxy = @import("../net/proxy.zig");
const api = @import("../api/client.zig");
const Formula = @import("../api/formula.zig").Formula;

pub const DepResolver = struct {
    alloc: std.mem.Allocator,
    formulae: std.StringHashMap(Formula),
    edges: std.StringHashMap([]const []const u8),
    client: ?proxy.Client,

    pub fn init(alloc: std.mem.Allocator) DepResolver {
        return .{
            .alloc = alloc,
            .formulae = std.StringHashMap(Formula).init(alloc),
            .edges = std.StringHashMap([]const []const u8).init(alloc),
            .client = proxy.Client.init(alloc, paths.safe_io),
        };
    }

    pub fn deinit(self: *DepResolver) void {
        if (self.client) |*c| c.deinit();
        var it = self.formulae.valueIterator();
        while (it.next()) |f| f.deinit(self.alloc);
        self.formulae.deinit();
        self.edges.deinit();
    }

    /// Resolve a formula and all its transitive dependencies using BFS.
    /// Each BFS level fetches all unknown deps in parallel.
    /// Shares one HTTP client across all fetches for TLS connection reuse.
    pub fn resolve(self: *DepResolver, name: []const u8) !void {
        return self.resolveMany(&.{name});
    }

    /// Resolve multiple independent roots in one BFS. This exposes root metadata
    /// fetches to the existing worker pool instead of resolving CLI arguments
    /// serially, and deduplicates shared roots/dependencies before any I/O.
    pub fn resolveMany(self: *DepResolver, names: []const []const u8) !void {
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(self.alloc);
        // Membership set makes root and next-level deduplication O(1).
        var queued_names = std.StringHashMap(void).init(self.alloc);
        defer queued_names.deinit();
        for (names) |name| {
            if (self.formulae.contains(name) or self.formulae.contains(tapShortName(name))) continue;
            const gop = try queued_names.getOrPut(name);
            if (!gop.found_existing) try frontier.append(self.alloc, name);
        }

        const client_ptr: ?*std.http.Client = if (self.client) |*c| c.ptr() else null;
        // BFS: each iteration fetches all frontier names in parallel
        while (frontier.items.len > 0) {
            const batch_size = frontier.items.len;

            // Allocate result slots (one per frontier entry)
            const results = try self.alloc.alloc(?Formula, batch_size);
            defer self.alloc.free(results);
            @memset(results, null);

            if (batch_size == 1) {
                // Single item — no thread overhead
                results[0] = api.fetchFormulaWithClient(self.alloc, client_ptr, frontier.items[0]) catch null;
            } else {
                // Bounded worker pool — each worker owns a persistent std.http.Client
                // that's reused across every item it picks up. Mirrors the
                // checkWorkerFn pattern in main.zig. Eliminates per-item DNS/TLS
                // handshake cost on multi-dep cold installs.
                const WorkerCtx = struct {
                    alloc_: std.mem.Allocator,
                    items: []const []const u8,
                    results: []?Formula,
                    next_idx: *std.atomic.Value(usize),
                };

                const workerFn = struct {
                    fn run(ctx: WorkerCtx) void {
                        var client = proxy.Client.init(ctx.alloc_, paths.safe_io);
                        defer client.deinit();
                        while (true) {
                            const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                            if (idx >= ctx.items.len) break;
                            ctx.results[idx] = api.fetchFormulaWithClient(ctx.alloc_, client.ptr(), ctx.items[idx]) catch null;
                        }
                    }
                }.run;

                var next_idx = std.atomic.Value(usize).init(0);
                const ctx = WorkerCtx{
                    .alloc_ = self.alloc,
                    .items = frontier.items,
                    .results = results,
                    .next_idx = &next_idx,
                };

                const n_threads = @min(batch_size, 8);
                var threads: [8]std.Thread = undefined;
                var spawned: usize = 0;
                for (0..n_threads) |_| {
                    threads[spawned] = std.Thread.spawn(.{}, workerFn, .{ctx}) catch continue;
                    spawned += 1;
                }

                if (spawned == 0) {
                    // Fallback: spawn failed entirely — fetch inline with the shared client.
                    for (frontier.items, 0..) |dep_name, i| {
                        results[i] = api.fetchFormulaWithClient(self.alloc, client_ptr, dep_name) catch null;
                    }
                } else {
                    for (threads[0..spawned]) |t| t.join();
                }
            }

            // Collect results, discover next frontier.
            frontier.clearRetainingCapacity();
            queued_names.clearRetainingCapacity();
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
                        const gop = queued_names.getOrPut(dep) catch continue;
                        if (!gop.found_existing) {
                            frontier.append(self.alloc, dep) catch {
                                _ = queued_names.remove(dep);
                                continue;
                            };
                        }
                    }
                }
            }
        }
    }

    /// Inject an already-resolved Formula (e.g. a version-pinned bottle whose
    /// metadata we built ourselves) and resolve its transitive dependencies.
    /// Takes ownership of `f` — it will be freed by `deinit`. If a formula with
    /// the same name is already present, `f` is freed and this is a no-op.
    pub fn addResolved(self: *DepResolver, f: Formula) !void {
        if (self.formulae.contains(f.name)) {
            f.deinit(self.alloc);
            return;
        }
        try self.formulae.put(f.name, f);
        try self.edges.put(f.name, f.dependencies);
        // Pull in the dependency tree (the injected node itself is now present,
        // so resolve() below short-circuits for it and only fetches deps).
        for (f.dependencies) |dep| try self.resolve(dep);
    }

    pub fn hasFormula(self: *DepResolver, name: []const u8) bool {
        // Check exact name
        if (self.formulae.contains(name)) return true;
        // Check tapShortName (for "user/tap/formula" -> "formula")
        if (self.formulae.contains(tapShortName(name))) return true;
        return false;
    }

    /// Check if a name (which might be an alias) matches any stored formula.
    /// This requires network access to check aliases, so it's only used when direct lookup fails.
    pub fn hasFormulaOrAlias(self: *DepResolver, alloc: std.mem.Allocator, name: []const u8) bool {
        // First check direct match
        if (self.formulae.contains(name)) return true;
        if (self.formulae.contains(tapShortName(name))) return true;
        // Try to resolve as alias
        const resolved = api.resolveFormulaAlias(alloc, name) orelse return false;
        defer alloc.free(resolved);
        if (self.formulae.contains(resolved)) return true;
        if (self.formulae.contains(tapShortName(resolved))) return true;
        return false;
    }

    pub fn topologicalSort(self: *DepResolver) ![]const Formula {
        // Close the shared client before install phase (frees TLS resources)
        if (self.client) |*c| {
            c.deinit();
            self.client = null;
        }

        // in_degree[name] = number of known Homebrew deps name has.
        // Deps not in formulae (system libraries from uses_from_macos like bzip2,
        // libarchive, zlib) are simply skipped — they come from the OS and are not
        // installed by nanobrew. The reverse_edges builder below uses the same
        // formulae.contains() guard, so in_degree counts and decrement counts
        // are always consistent, and Kahn's algorithm produces a correct order.

        var in_degree = std.StringHashMap(u32).init(self.alloc);
        defer in_degree.deinit();

        var name_iter = self.formulae.keyIterator();
        while (name_iter.next()) |name_ptr| {
            try in_degree.put(name_ptr.*, 0);
        }

        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            if (in_degree.getPtr(entry.key_ptr.*)) |count| {
                var known: u32 = 0;
                for (entry.value_ptr.*) |dep| {
                    if (std.mem.eql(u8, dep, entry.key_ptr.*)) continue; // skip self-dep
                    if (self.formulae.contains(dep)) known += 1;
                }
                count.* = known;
            }
        }

        // Build reverse adjacency map: dep -> list of nodes that depend on dep.
        // This lets us find dependents in O(out-degree) instead of O(V+E) per dequeue.
        var reverse_edges = std.StringHashMap(std.ArrayList([]const u8)).init(self.alloc);
        defer {
            var rev_it = reverse_edges.valueIterator();
            while (rev_it.next()) |list| list.deinit(self.alloc);
            reverse_edges.deinit();
        }

        var build_iter = self.edges.iterator();
        while (build_iter.next()) |entry| {
            const dependent = entry.key_ptr.*;
            for (entry.value_ptr.*) |dep| {
                if (std.mem.eql(u8, dep, dependent)) continue; // skip self-dep
                if (!self.formulae.contains(dep)) continue;
                const gop = try reverse_edges.getOrPut(dep);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(self.alloc, dependent);
            }
        }

        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.alloc);
        var queue_head: usize = 0; // index pointer — O(1) dequeue, no array shifts

        var deg_iter = in_degree.iterator();
        while (deg_iter.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(self.alloc, entry.key_ptr.*);
            }
        }

        var result: std.ArrayList(Formula) = .empty;

        while (queue_head < queue.items.len) {
            const sorted_name = queue.items[queue_head];
            queue_head += 1;
            const f = self.formulae.get(sorted_name) orelse continue;
            try result.append(self.alloc, f);

            // Use reverse_edges for O(out-degree) lookup instead of O(V+E) full scan
            if (reverse_edges.get(sorted_name)) |dependents| {
                for (dependents.items) |dependent| {
                    if (in_degree.getPtr(dependent)) |count| {
                        count.* -= 1;
                        if (count.* == 0) {
                            try queue.append(self.alloc, dependent);
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

/// For tap refs like "user/tap/formula", return just "formula".
/// For plain names, return as-is.
fn tapShortName(name: []const u8) []const u8 {
    // Find the last slash
    var last_slash: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '/') last_slash = i;
    }
    if (last_slash) |pos| {
        if (pos + 1 < name.len) return name[pos + 1 ..];
    }
    return name;
}

const testing = std.testing;

fn makeFormula(name: []const u8, dep_list: []const []const u8) Formula {
    return .{
        .name = name,
        .version = "1.0",
        .dependencies = dep_list,
    };
}

test "topologicalSort - linear chain" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // C has no deps, B depends on C, A depends on B
    const c = makeFormula("c", &.{});
    const b = makeFormula("b", &.{"c"});
    const a = makeFormula("a", &.{"b"});

    try r.formulae.put("a", a);
    try r.formulae.put("b", b);
    try r.formulae.put("c", c);
    try r.edges.put("a", a.dependencies);
    try r.edges.put("b", b.dependencies);
    try r.edges.put("c", c.dependencies);

    const sorted = try r.topologicalSort();
    defer testing.allocator.free(sorted);

    // c must come before b, b before a
    try testing.expectEqual(@as(usize, 3), sorted.len);
    try testing.expectEqualStrings("c", sorted[0].name);
    try testing.expectEqualStrings("b", sorted[1].name);
    try testing.expectEqualStrings("a", sorted[2].name);
}

test "topologicalSort - diamond dependency" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // D has no deps; B and C depend on D; A depends on B and C
    const d = makeFormula("d", &.{});
    const b_dep = makeFormula("b", &.{"d"});
    const c_dep = makeFormula("c", &.{"d"});
    const a_dep = makeFormula("a", &.{ "b", "c" });

    try r.formulae.put("a", a_dep);
    try r.formulae.put("b", b_dep);
    try r.formulae.put("c", c_dep);
    try r.formulae.put("d", d);
    try r.edges.put("a", a_dep.dependencies);
    try r.edges.put("b", b_dep.dependencies);
    try r.edges.put("c", c_dep.dependencies);
    try r.edges.put("d", d.dependencies);

    const sorted = try r.topologicalSort();
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 4), sorted.len);
    // d must be first (leaf), a must be last (root)
    try testing.expectEqualStrings("d", sorted[0].name);
    try testing.expectEqualStrings("a", sorted[3].name);
}

test "topologicalSort - cycle detection" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // A depends on B, B depends on A — cycle
    const a = makeFormula("a", &.{"b"});
    const b = makeFormula("b", &.{"a"});

    try r.formulae.put("a", a);
    try r.formulae.put("b", b);
    try r.edges.put("a", a.dependencies);
    try r.edges.put("b", b.dependencies);

    try testing.expectError(error.DependencyCycle, r.topologicalSort());
}

test "topologicalSort - system dep (uses_from_macos) not in formulae is skipped not errored" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // A depends on "bzip2" (a macOS system library not in formulae).
    // This mirrors `nb install node` where uses_from_macos adds system lib names
    // that have no standalone Homebrew formula.  The sort must succeed and
    // produce [a], not return MissingDependency or DependencyCycle.
    const a = makeFormula("a", &.{"bzip2"});

    try r.formulae.put("a", a);
    try r.edges.put("a", a.dependencies);
    // "bzip2" intentionally absent — it is a system dep, not a Homebrew formula

    const sorted = try r.topologicalSort();
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 1), sorted.len);
    try testing.expectEqualStrings("a", sorted[0].name);
}

test "topologicalSort - self-dependency does not cause false cycle" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // Package "r" depends on itself — should not be treated as a cycle
    const pkg_r = makeFormula("r", &.{ "r", "b" });
    const pkg_b = makeFormula("b", &.{});

    try r.formulae.put("r", pkg_r);
    try r.formulae.put("b", pkg_b);
    try r.edges.put("r", pkg_r.dependencies);
    try r.edges.put("b", pkg_b.dependencies);

    const sorted = try r.topologicalSort();
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 2), sorted.len);
    try testing.expectEqualStrings("b", sorted[0].name);
    try testing.expectEqualStrings("r", sorted[1].name);
}

test "topologicalSort - node-style diamond with system deps does not false-cycle" {
    var r = DepResolver.init(testing.allocator);
    defer r.deinit();

    // Mirrors the real `node` dep graph structure reported in issue #216:
    //   node -> openssl@3 (direct)
    //   node -> libnghttp2
    //   node -> libuv (direct)
    //   node -> uvwasi
    //   node -> bzip2   (uses_from_macos — NOT in formulae)
    //   libnghttp2 -> openssl@3          (diamond via openssl@3)
    //   uvwasi -> libuv                  (diamond via libuv)
    const openssl = makeFormula("openssl@3", &.{});
    const libuv = makeFormula("libuv", &.{});
    const libnghttp2 = makeFormula("libnghttp2", &.{"openssl@3"});
    const uvwasi = makeFormula("uvwasi", &.{"libuv"});
    const node = makeFormula("node", &.{ "openssl@3", "libnghttp2", "libuv", "uvwasi", "bzip2" });

    try r.formulae.put("openssl@3", openssl);
    try r.formulae.put("libuv", libuv);
    try r.formulae.put("libnghttp2", libnghttp2);
    try r.formulae.put("uvwasi", uvwasi);
    try r.formulae.put("node", node);
    try r.edges.put("openssl@3", openssl.dependencies);
    try r.edges.put("libuv", libuv.dependencies);
    try r.edges.put("libnghttp2", libnghttp2.dependencies);
    try r.edges.put("uvwasi", uvwasi.dependencies);
    try r.edges.put("node", node.dependencies);
    // "bzip2" absent — system dep from uses_from_macos

    const sorted = try r.topologicalSort();
    defer testing.allocator.free(sorted);

    // All 5 known formulae must be present in the result
    try testing.expectEqual(@as(usize, 5), sorted.len);
    // node must come last (depends on everything else)
    try testing.expectEqualStrings("node", sorted[sorted.len - 1].name);
    // openssl@3 and libuv must precede their dependents
    var openssl_pos: usize = 0;
    var libuv_pos: usize = 0;
    var libnghttp2_pos: usize = 0;
    var uvwasi_pos: usize = 0;
    for (sorted, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "openssl@3")) openssl_pos = i;
        if (std.mem.eql(u8, f.name, "libuv")) libuv_pos = i;
        if (std.mem.eql(u8, f.name, "libnghttp2")) libnghttp2_pos = i;
        if (std.mem.eql(u8, f.name, "uvwasi")) uvwasi_pos = i;
    }
    try testing.expect(openssl_pos < libnghttp2_pos);
    try testing.expect(libuv_pos < uvwasi_pos);
}
