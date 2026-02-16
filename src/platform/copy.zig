// nanobrew — COW copy abstraction
//
// macOS: clonefile(2) syscall for zero-cost APFS copy-on-write
// Linux: returns false → triggers cp --reflink=auto fallback (btrfs/xfs COW)

const std = @import("std");
const builtin = @import("builtin");

/// Attempt to clone a directory tree using OS-native COW.
/// Returns true if the clone succeeded, false if caller should use cp fallback.
pub fn cloneTree(src: [*:0]const u8, dst: [*:0]const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return clonefile(src, dst, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0;
}

/// Build the cp fallback args for the current platform.
/// macOS: cp -R src dst
/// Linux: cp --reflink=auto -R src dst (enables COW on btrfs/xfs)
pub fn cpFallbackArgs(src: []const u8, dst: []const u8) [4][]const u8 {
    if (comptime builtin.os.tag == .linux) {
        return .{ "cp", "--reflink=auto", "-R", src };
    } else {
        return .{ "cp", "-R", src, dst };
    }
}

/// Run the cp fallback for the current platform.
pub fn cpFallback(src: []const u8, dst: []const u8) !void {
    if (comptime builtin.os.tag == .linux) {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "cp", "--reflink=auto", "-R", src, dst },
        }) catch return error.CopyFailed;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    } else {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "cp", "-R", src, dst },
        }) catch return error.CopyFailed;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
}

// macOS clonefile(2) — only compiled on macOS
const CLONE_NOFOLLOW: c_uint = 0x0001;
const CLONE_NOOWNERCOPY: c_uint = 0x0002;

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;
