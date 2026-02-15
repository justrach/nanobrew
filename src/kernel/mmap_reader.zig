// zigrep — Memory-Mapped File Reader
//
// Zero-copy file access via mmap. The OS pages in file data on demand,
// avoiding explicit read() syscalls and buffer management. Combined
// with SIMD scanning, this means bytes flow directly from disk cache
// through SIMD registers without ever being copied to a userspace buffer.
//
// Fallback: for pipes/stdin/special files that can't be mmap'd, we
// use a streaming reader with double-buffered I/O.

const std = @import("std");
const posix = std.posix;

pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) const u8,
    len: usize,

    /// Map a file into memory. Returns null if file is empty or can't be mapped.
    pub fn open(path: []const u8) !?MappedFile {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        if (size == 0) return null;

        // PROT_READ = 1 on all POSIX platforms
        const PROT_READ: u32 = 0x01;

        const mapped = try posix.mmap(
            null,
            size,
            PROT_READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );

        // Advise the kernel we'll read sequentially (MADV_SEQUENTIAL = 2 on macOS/Linux)
        posix.madvise(@ptrCast(@alignCast(mapped.ptr)), mapped.len, 2) catch {};

        return MappedFile{
            .data = mapped,
            .len = size,
        };
    }

    /// Get the file contents as a byte slice.
    pub fn bytes(self: *const MappedFile) []const u8 {
        return self.data[0..self.len];
    }

    /// Unmap the file from memory.
    pub fn close(self: *MappedFile) void {
        posix.munmap(self.data);
    }

    /// Advise the kernel about our access pattern for a specific range.
    pub fn prefetchRange(self: *const MappedFile, offset: usize, len: usize) void {
        if (offset >= self.len) return;
        const actual_len = @min(len, self.len - offset);
        const page_mask = std.heap.page_size_min - 1;
        const aligned_offset = offset & ~page_mask;
        const aligned_end = (offset + actual_len + page_mask) & ~page_mask;
        const aligned_len = aligned_end - aligned_offset;
        _ = aligned_len;

        // MADV_WILLNEED = 3 on Linux, 4 on macOS (but madvise may not be available on all)
        const MADV_WILLNEED: u32 = if (@import("builtin").os.tag == .macos) 4 else 3;
        posix.madvise(@ptrCast(@alignCast(self.data.ptr + aligned_offset)), actual_len, MADV_WILLNEED) catch {};
    }
};

/// Streaming reader for non-mmappable sources (stdin, pipes).
/// Uses double-buffered I/O for overlap between reading and processing.
pub const StreamReader = struct {
    const BUF_SIZE = 256 * 1024; // 256KB per buffer

    buffers: [2][BUF_SIZE]u8,
    active: u1,
    len: usize,
    source: std.fs.File,
    eof: bool,

    pub fn init(source: std.fs.File) StreamReader {
        return .{
            .buffers = undefined,
            .active = 0,
            .len = 0,
            .source = source,
            .eof = false,
        };
    }

    /// Read the next chunk. Returns null at EOF.
    pub fn nextChunk(self: *StreamReader) ?[]const u8 {
        if (self.eof) return null;

        const buf = &self.buffers[self.active];
        const n = self.source.read(buf) catch return null;

        if (n == 0) {
            self.eof = true;
            return null;
        }

        self.len = n;
        self.active ^= 1; // Swap buffer for next read
        return buf[0..n];
    }
};

// ── Tests ──

test "MappedFile - open and read" {
    // Create a temp file for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Hello, zigrep!\nThis is a test file.\nWith multiple lines.\n";
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(content);
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    var mapped = (try MappedFile.open(path)) orelse return error.TestUnexpectedResult;
    defer mapped.close();

    try std.testing.expectEqualStrings(content, mapped.bytes());
}
