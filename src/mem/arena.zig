// zigrep — Thread-Local Arena Allocator
//
// Standard bump allocator. Zero-malloc query path. Each search
// thread gets a pre-allocated scratch buffer that is reset between
// file searches. O(1) allocation, O(1) reset.

const std = @import("std");

/// A fixed-size bump allocator. O(1) alloc, O(1) reset.
pub const ScratchArena = struct {
    buffer: []u8,
    offset: usize,
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator, size: usize) !ScratchArena {
        const buf = try backing.alloc(u8, size);
        return .{
            .buffer = buf,
            .offset = 0,
            .backing = backing,
        };
    }

    pub fn deinit(self: *ScratchArena) void {
        self.backing.free(self.buffer);
    }

    /// Allocate a slice of T from the arena. Returns null if OOM.
    pub fn alloc(self: *ScratchArena, comptime T: type, n: usize) ?[]T {
        const alignment = @alignOf(T);
        const bytes = n * @sizeOf(T);
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const end = aligned_offset + bytes;

        if (end > self.buffer.len) return null;

        self.offset = end;
        const ptr: [*]T = @ptrCast(@alignCast(self.buffer.ptr + aligned_offset));
        return ptr[0..n];
    }

    /// Allocate a single item.
    pub fn create(self: *ScratchArena, comptime T: type) ?*T {
        const slice = self.alloc(T, 1) orelse return null;
        return &slice[0];
    }

    /// Reset the arena. All previous allocations become invalid.
    pub fn reset(self: *ScratchArena) void {
        self.offset = 0;
    }

    pub fn remaining(self: *const ScratchArena) usize {
        return self.buffer.len - self.offset;
    }

    pub fn used(self: *const ScratchArena) usize {
        return self.offset;
    }
};

/// Ring buffer for LRU-style caching of recent search results.
/// Standard circular buffer implementation.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, item: T) void {
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            if (self.count < capacity) {
                self.count += 1;
            } else {
                self.head = (self.head + 1) % capacity; // Overwrite oldest
            }
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.buffer[self.head];
        }

        pub fn isFull(self: *const Self) bool {
            return self.count >= capacity;
        }
    };
}

// ── Tests ──

test "ScratchArena basic" {
    var arena = try ScratchArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    const slice = arena.alloc(f32, 100);
    try std.testing.expect(slice != null);
    try std.testing.expectEqual(@as(usize, 100), slice.?.len);
}

test "ScratchArena reset" {
    var arena = try ScratchArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    _ = arena.alloc(u8, 1000);
    try std.testing.expect(arena.used() >= 1000);
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}

test "RingBuffer overflow" {
    var rb = RingBuffer(u32, 3){};
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4); // Overwrites 1
    try std.testing.expectEqual(@as(u32, 2), rb.pop().?);
    try std.testing.expectEqual(@as(u32, 3), rb.pop().?);
    try std.testing.expectEqual(@as(u32, 4), rb.pop().?);
}
