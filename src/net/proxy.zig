// Optional proxy transport. curl owns CONNECT/TLS and re-evaluates NO_PROXY
// on every redirect. The native transport remains the default without proxies.
const std = @import("std");
const paths = @import("../platform/paths.zig");
pub var environment: ?*const std.process.Environ.Map = null;

pub fn enabled() bool {
    inline for (.{ "http_proxy", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
        if (std.c.getenv(name)) |v| if (v[0] != 0) return true;
    }
    // HTTP_PROXY is unsafe in CGI, where it can come from an HTTP header.
    if (std.c.getenv("REQUEST_METHOD") == null) {
        if (std.c.getenv("HTTP_PROXY")) |v| if (v[0] != 0) return true;
    }
    return false;
}

fn option(out: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = \"");
    for (value) |c| switch (c) {
        '\\', '"' => {
            try out.append(a, '\\');
            try out.append(a, c);
        },
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        0 => return error.InvalidValue,
        else => try out.append(a, c),
    };
    try out.appendSlice(a, "\"\n");
}

/// Credentials and headers travel over stdin, never command-line arguments.
/// Caller owns the returned body. File downloads return an empty owned body.
pub fn request(a: std.mem.Allocator, url: []const u8, dest: ?[]const u8, headers: []const std.http.Header, body: ?[]const u8) ![]u8 {
    return requestInner(a, url, dest, headers, body, 3);
}

fn requestInner(a: std.mem.Allocator, url: []const u8, dest: ?[]const u8, headers: []const std.http.Header, body: ?[]const u8, hops: u8) anyerror![]u8 {
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidUrl;
    var env = if (environment) |e| try e.clone(a) else std.process.Environ.Map.init(a);
    defer env.deinit();
    if (environment != null and !env.contains("http_proxy") and !env.contains("REQUEST_METHOD")) {
        if (env.get("HTTP_PROXY")) |v| try env.put("http_proxy", v);
    }
    var config: std.ArrayList(u8) = .empty;
    defer config.deinit(a);
    try config.appendSlice(a, "silent\nfail\ngloboff\nconnect-timeout = 30\nmax-time = 1800\nproto = \"=http,https\"\n");
    try option(&config, a, "url", url);
    try option(&config, a, "proto-redir", if (std.mem.eql(u8, uri.scheme, "https")) "=https" else "=http,https");
    if (body == null) {
        try config.appendSlice(a, "location\n");
        var count_buf: [3]u8 = undefined;
        try option(&config, a, "max-redirs", try std.fmt.bufPrint(&count_buf, "{d}", .{hops}));
    }
    if (dest) |p| try option(&config, a, "output", p) else try config.appendSlice(a, "compressed\n");
    for (headers) |h| {
        if (std.mem.indexOfAny(u8, h.name, "\r\n:") != null or std.mem.indexOfAny(u8, h.value, "\r\n") != null) return error.InvalidHeader;
        const hline = try std.fmt.allocPrint(a, "{s}: {s}", .{ h.name, h.value });
        defer a.free(hline);
        try option(&config, a, "header", hline);
    }
    if (body) |b| try option(&config, a, "data-raw", b);
    try config.appendSlice(a, "write-out = \"\\n%{http_code}\\n%{redirect_url}\"\n");
    const io = paths.safe_io;
    var child = std.process.spawn(io, .{
        .argv = &.{ "curl", "--disable", "--config", "-" },
        .environ_map = if (environment != null) &env else null,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.ProxyTransportUnavailable;
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, config.items);
    child.stdin.?.close(io);
    child.stdin = null;
    var buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    const out = try reader.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
    errdefer a.free(out);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0 and code != 22) {
            return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }
    const location_start = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return error.FetchFailed;
    const status_start = std.mem.lastIndexOfScalar(u8, out[0..location_start], '\n') orelse return error.FetchFailed;
    const status = std.fmt.parseInt(u16, out[status_start + 1 .. location_start], 10) catch return error.FetchFailed;
    if (body != null and (status == 301 or status == 302 or status == 303)) {
        if (hops == 0) return error.TooManyRedirects;
        const location = out[location_start + 1 ..];
        const target = try std.Uri.parse(location);
        if (std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, target.scheme, "https")) return error.InsecureRedirect;
        // POST converts to GET. Strip body-specific and sensitive headers; curl
        // supplies a fresh Host header for the redirected origin.
        var redirected: std.ArrayList(std.http.Header) = .empty;
        defer redirected.deinit(a);
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Authorization") or std.ascii.eqlIgnoreCase(h.name, "Cookie") or std.ascii.eqlIgnoreCase(h.name, "Host") or std.ascii.eqlIgnoreCase(h.name, "Content-Type") or std.ascii.eqlIgnoreCase(h.name, "Content-Length")) continue;
            try redirected.append(a, h);
        }
        const result = try requestInner(a, location, dest, redirected.items, null, hops - 1);
        a.free(out);
        return result;
    }
    switch (status) {
        200, 202 => {},
        404, 410 => return error.BottleNotFound,
        401, 403 => return error.AuthFailed,
        429 => return error.RateLimited,
        else => return error.FetchFailed,
    }
    const result = try a.dupe(u8, out[0..status_start]);
    a.free(out);
    return result;
}

pub fn download(a: std.mem.Allocator, url: []const u8, dest: []const u8, sha: ?[]const u8, headers: []const std.http.Header, body: ?[]const u8) !void {
    // Stage before replacing the destination. Network or checksum failures must
    // not remove a previously valid file supplied by the caller.
    const temp = try std.fmt.allocPrint(a, "{s}.{d}-{d}.proxy", .{ dest, std.c.getpid(), std.Thread.getCurrentId() });
    defer a.free(temp);
    defer std.Io.Dir.deleteFileAbsolute(paths.safe_io, temp) catch {};
    const result = try request(a, url, temp, headers, body);
    defer a.free(result);
    if (sha) |expected| {
        if (!try matchesSha(temp, expected)) return error.ChecksumMismatch;
    }
    try std.Io.Dir.renameAbsolute(temp, dest, paths.safe_io);
}

pub fn matchesSha(path: []const u8, expected: []const u8) !bool {
    if (expected.len != 64) return false;
    const io = paths.safe_io;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var offset: u64 = 0;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = try file.readPositional(io, &.{&buf}, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }
    const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return std.ascii.eqlIgnoreCase(&hex, expected);
}
