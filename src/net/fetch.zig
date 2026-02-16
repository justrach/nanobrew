// nanobrew — Native HTTP fetch (zero curl dependency)
//
// Replaces all curl subprocess spawns with Zig's std.http.Client.
// Follows redirects. Auto-decompresses gzip responses.

const std = @import("std");
const flate = std.compress.flate;

/// Fetch a URL and return the response body as an owned slice.
/// Caller must free the returned slice with `alloc.free()`.
/// Follows up to 5 redirects. Auto-decompresses gzip. Returns error on non-200 status.
pub fn get(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    return getWithClient(alloc, &client, url);
}

/// Fetch using an existing client (avoids repeated TLS setup).
pub fn getWithClient(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
    }) catch return error.FetchFailed;

    req.sendBodiless() catch {
        req.deinit();
        return error.FetchFailed;
    };

    var head_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        req.deinit();
        return error.FetchFailed;
    }

    // Stream raw response body to memory
    var out: std.Io.Writer.Allocating = .init(alloc);
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch {
        out.deinit();
        req.deinit();
        return error.FetchFailed;
    };
    req.deinit();

    const raw = out.toOwnedSlice() catch {
        out.deinit();
        return error.OutOfMemory;
    };

    // Auto-decompress gzip if server sent compressed response
    if (response.head.content_encoding == .gzip) {
        defer alloc.free(raw);
        return decompressGzip(alloc, raw);
    }

    return raw;
}

fn decompressGzip(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var fixed_reader = std.Io.Reader.fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fixed_reader, .gzip, &window);

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    _ = decomp.reader.streamRemaining(&result.writer) catch return error.FetchFailed;
    return result.toOwnedSlice() catch return error.OutOfMemory;
}

/// Fetch a URL and write the response body directly to a file.
pub fn download(alloc: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    return downloadWithClient(&client, url, dest_path);
}

/// Download using an existing client.
pub fn downloadWithClient(client: *std.http.Client, url: []const u8, dest_path: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
    }) catch return error.FetchFailed;

    req.sendBodiless() catch {
        req.deinit();
        return error.FetchFailed;
    };

    var head_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        req.deinit();
        return error.FetchFailed;
    };
    if (response.head.status != .ok) {
        req.deinit();
        return error.FetchFailed;
    }

    var file = std.fs.createFileAbsolute(dest_path, .{}) catch {
        req.deinit();
        return error.FetchFailed;
    };
    var file_writer_buf: [65536]u8 = undefined;
    var file_writer = file.writer(&file_writer_buf);
    var reader = response.reader(&.{});

    _ = reader.streamRemaining(&file_writer.interface) catch {
        file.close();
        req.deinit();
        std.fs.deleteFileAbsolute(dest_path) catch {};
        return error.FetchFailed;
    };
    file_writer.interface.flush() catch {
        file.close();
        req.deinit();
        std.fs.deleteFileAbsolute(dest_path) catch {};
        return error.FetchFailed;
    };
    file.close();
    req.deinit();
}
