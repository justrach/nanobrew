// nanobrew — Lock-free MPMC queue
//
// Adapted from zigrep's directory queue for parallel bottle operations.
// Used to distribute download/extract work across threads.

const std = @import("std");

pub const Slot = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const QUEUE_CAP = 4096;

pub const WorkQueue = struct {
    slots: []Slot,
    write_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pending: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    done_seeding: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(alloc: std.mem.Allocator) !*WorkQueue {
        const self = try alloc.create(WorkQueue);
        const slots = try alloc.alloc(Slot, QUEUE_CAP);
        for (slots) |*s| s.* = .{};
        self.* = .{ .slots = slots };
        return self;
    }

    pub fn deinit(self: *WorkQueue, alloc: std.mem.Allocator) void {
        alloc.free(self.slots);
        alloc.destroy(self);
    }

    pub fn push(self: *WorkQueue, p: []const u8) void {
        _ = self.pending.fetchAdd(1, .acq_rel);

        const w = self.write_pos.fetchAdd(1, .monotonic);
        const idx = @as(usize, @intCast(w % QUEUE_CAP));
        const slot = &self.slots[idx];

        while (slot.ready.load(.acquire)) {
            std.Thread.yield() catch {};
        }

        const n: u32 = @intCast(@min(p.len, slot.buf.len));
        @memcpy(slot.buf[0..n], p[0..n]);
        slot.len.store(n, .monotonic);
        slot.ready.store(true, .release);
    }

    pub fn markProcessed(self: *WorkQueue) void {
        _ = self.pending.fetchSub(1, .acq_rel);
    }

    pub fn pop(self: *WorkQueue) ?[]const u8 {
        while (true) {
            const r = self.read_pos.load(.monotonic);
            const w = self.write_pos.load(.acquire);

            if (r < w) {
                if (self.read_pos.cmpxchgWeak(r, r + 1, .acquire, .monotonic) != null) {
                    continue;
                }

                const idx = @as(usize, @intCast(r % QUEUE_CAP));
                const slot = &self.slots[idx];

                while (!slot.ready.load(.acquire)) {
                    std.Thread.yield() catch {};
                }

                const n = slot.len.load(.monotonic);
                const path = slot.buf[0..n];
                slot.ready.store(false, .release);
                return path;
            }

            if (self.done_seeding.load(.acquire) and self.pending.load(.acquire) <= 0) {
                return null;
            }

            std.Thread.yield() catch {};
        }
    }
};
