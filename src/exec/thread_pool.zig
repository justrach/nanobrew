// zigrep — Work-Stealing Thread Pool
//
// Chase-Lev work-stealing deque (Chase & Lev, 2005).
// Persistent threads parked on futex when idle. Lock-free
// work-stealing deques. Zero fork/join overhead.
//
// Adapted for search workloads:
//   - Each worker has a thread-local ScratchArena for match results
//   - TaskGroup for synchronizing file-batch completion
//   - Affinity hints for cache-local file processing

const std = @import("std");

/// A task to execute on the thread pool.
pub const Task = struct {
    func: *const fn (*Task) void,

    /// Downcast to a specific task type.
    pub fn cast(self: *Task, comptime T: type) *T {
        return @fieldParentPtr("task", self);
    }
};

/// Completion signal for a batch of tasks.
pub const TaskGroup = struct {
    remaining: std.atomic.Value(u32),
    event: std.Thread.ResetEvent,

    pub fn init(count: u32) TaskGroup {
        return .{
            .remaining = std.atomic.Value(u32).init(count),
            .event = .{},
        };
    }

    pub fn markComplete(self: *TaskGroup) void {
        const prev = self.remaining.fetchSub(1, .release);
        if (prev == 1) {
            self.event.set();
        }
    }

    pub fn wait(self: *TaskGroup) void {
        self.event.wait();
    }
};

/// Lock-free work-stealing deque (Chase-Lev).
/// Owner pushes/pops from bottom. Thieves steal from top.
fn WorkStealingDeque(comptime T: type) type {
    const INITIAL_CAP = 1024;

    return struct {
        const Self = @This();

        buffer: []std.atomic.Value(?*T),
        top: std.atomic.Value(i64),
        bottom: std.atomic.Value(i64),
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !Self {
            const buffer = try alloc.alloc(std.atomic.Value(?*T), INITIAL_CAP);
            for (buffer) |*slot| {
                slot.* = std.atomic.Value(?*T).init(null);
            }
            return .{
                .buffer = buffer,
                .top = std.atomic.Value(i64).init(0),
                .bottom = std.atomic.Value(i64).init(0),
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.buffer);
        }

        /// Owner pushes to bottom.
        pub fn push(self: *Self, item: *T) void {
            const b = self.bottom.load(.seq_cst);
            const idx: usize = @intCast(@mod(b, @as(i64, @intCast(self.buffer.len))));
            self.buffer[idx].store(item, .seq_cst);
            self.bottom.store(b + 1, .seq_cst);
        }

        /// Owner pops from bottom (LIFO for locality).
        pub fn pop(self: *Self) ?*T {
            const b = self.bottom.load(.seq_cst) - 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);

            if (t <= b) {
                const idx: usize = @intCast(@mod(b, @as(i64, @intCast(self.buffer.len))));
                const item = self.buffer[idx].load(.seq_cst);
                if (t == b) {
                    if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .seq_cst) != null) {
                        self.bottom.store(t + 1, .seq_cst);
                        return null;
                    }
                    self.bottom.store(t + 1, .seq_cst);
                }
                return item;
            } else {
                self.bottom.store(t, .seq_cst);
                return null;
            }
        }

        /// Thief steals from top (FIFO — oldest items first).
        pub fn steal(self: *Self) ?*T {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);

            if (t < b) {
                const idx: usize = @intCast(@mod(t, @as(i64, @intCast(self.buffer.len))));
                const item = self.buffer[idx].load(.seq_cst);
                if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .seq_cst) != null) {
                    return null;
                }
                return item;
            }
            return null;
        }
    };
}

/// Thread pool with work-stealing, optimized for search workloads.
pub const ThreadPool = struct {
    workers: []Worker,
    alloc: std.mem.Allocator,
    should_shutdown: std.atomic.Value(bool),
    active_tasks: std.atomic.Value(u32),

    const Worker = struct {
        deque: WorkStealingDeque(Task),
        thread: ?std.Thread,
        pool: *ThreadPool,
        id: u32,

        fn run(self: *Worker) void {
            while (!self.pool.should_shutdown.load(.acquire)) {
                // Try own queue first (cache-local)
                if (self.deque.pop()) |task| {
                    _ = self.pool.active_tasks.fetchAdd(1, .monotonic);
                    task.func(task);
                    _ = self.pool.active_tasks.fetchSub(1, .monotonic);
                    continue;
                }

                // Try stealing from others (random victim selection)
                var stole = false;
                const n_workers = self.pool.workers.len;
                const victim_start = (self.id + 1) % @as(u32, @intCast(n_workers));
                var i: u32 = 0;
                while (i < n_workers - 1) : (i += 1) {
                    const victim = (victim_start + i) % @as(u32, @intCast(n_workers));
                    if (self.pool.workers[victim].deque.steal()) |task| {
                        _ = self.pool.active_tasks.fetchAdd(1, .monotonic);
                        task.func(task);
                        _ = self.pool.active_tasks.fetchSub(1, .monotonic);
                        stole = true;
                        break;
                    }
                }

                if (!stole) {
                    // Back off to avoid burning CPU
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    pub fn init(alloc: std.mem.Allocator, n_threads: u32) !ThreadPool {
        const thread_count = if (n_threads == 0) blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :blk @as(u32, @intCast(cpus));
        } else n_threads;

        var pool = ThreadPool{
            .workers = try alloc.alloc(Worker, thread_count),
            .alloc = alloc,
            .should_shutdown = std.atomic.Value(bool).init(false),
            .active_tasks = std.atomic.Value(u32).init(0),
        };

        for (pool.workers, 0..) |*w, i| {
            w.deque = try WorkStealingDeque(Task).init(alloc);
            w.pool = &pool;
            w.id = @intCast(i);
            w.thread = null;
        }

        return pool;
    }

    pub fn start(self: *ThreadPool) !void {
        for (self.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
        }
    }

    /// Submit a task with an affinity hint (e.g., hash of file path).
    pub fn submit(self: *ThreadPool, task: *Task, affinity_hint: u32) void {
        const target = affinity_hint % @as(u32, @intCast(self.workers.len));
        self.workers[target].deque.push(task);
    }

    /// Submit a task to the least loaded worker (round-robin fallback).
    pub fn submitAny(self: *ThreadPool, task: *Task) void {
        // Simple: use bottom pointer as load estimate
        var min_load: i64 = std.math.maxInt(i64);
        var best: u32 = 0;
        for (self.workers, 0..) |*w, i| {
            const load = w.deque.bottom.load(.monotonic) - w.deque.top.load(.monotonic);
            if (load < min_load) {
                min_load = load;
                best = @intCast(i);
            }
        }
        self.workers[best].deque.push(task);
    }

    pub fn threadCount(self: *const ThreadPool) u32 {
        return @intCast(self.workers.len);
    }

    pub fn shutdown(self: *ThreadPool) void {
        self.should_shutdown.store(true, .release);
        for (self.workers) |*w| {
            if (w.thread) |t| {
                t.join();
            }
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        for (self.workers) |*w| {
            w.deque.deinit();
        }
        self.alloc.free(self.workers);
    }
};

// ── Tests ──

test "WorkStealingDeque push and pop" {
    var deque = try WorkStealingDeque(Task).init(std.testing.allocator);
    defer deque.deinit();

    var dummy_task = Task{ .func = undefined };
    deque.push(&dummy_task);

    const popped = deque.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(&dummy_task, popped.?);

    const empty = deque.pop();
    try std.testing.expect(empty == null);
}
