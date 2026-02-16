// nanobrew — Deb Packages.gz index parser
//
// Parses the APT Packages index format (RFC 822-style key-value blocks).
// Each block describes one .deb package with: Package, Version, Depends,
// Filename, SHA256, Size fields.

const std = @import("std");

pub const DebPackage = struct {
    name: []const u8,
    version: []const u8,
    depends: []const u8, // raw Depends: field (parsed later by resolver)
    filename: []const u8, // e.g. "pool/main/c/curl/curl_8.5.0-2_amd64.deb"
    sha256: []const u8,
    size: u64,
    description: []const u8,

    pub fn deinit(self: DebPackage, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.depends);
        alloc.free(self.filename);
        alloc.free(self.sha256);
        alloc.free(self.description);
    }
};

/// Parse a Packages index (uncompressed text) into a list of DebPackage.
pub fn parsePackagesIndex(alloc: std.mem.Allocator, data: []const u8) ![]DebPackage {
    var packages: std.ArrayList(DebPackage) = .empty;
    defer packages.deinit(alloc);

    // Split by double newline (paragraph separator)
    var blocks = std.mem.splitSequence(u8, data, "\n\n");
    while (blocks.next()) |block| {
        if (block.len == 0) continue;
        if (parseOnePackage(alloc, block)) |pkg| {
            packages.append(alloc, pkg) catch continue;
        }
    }

    return packages.toOwnedSlice(alloc);
}

fn parseOnePackage(alloc: std.mem.Allocator, block: []const u8) ?DebPackage {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var depends: []const u8 = "";
    var filename: ?[]const u8 = null;
    var sha256: []const u8 = "";
    var size: u64 = 0;
    var description: []const u8 = "";

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        // Skip continuation lines (start with space/tab)
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;

        if (fieldValue(line, "Package: ")) |v| {
            name = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "Version: ")) |v| {
            version = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "Depends: ")) |v| {
            depends = alloc.dupe(u8, v) catch "";
        } else if (fieldValue(line, "Filename: ")) |v| {
            filename = alloc.dupe(u8, v) catch null;
        } else if (fieldValue(line, "SHA256: ")) |v| {
            sha256 = alloc.dupe(u8, v) catch "";
        } else if (fieldValue(line, "Size: ")) |v| {
            size = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (fieldValue(line, "Description: ")) |v| {
            description = alloc.dupe(u8, v) catch "";
        }
    }

    const pkg_name = name orelse return null;
    const pkg_version = version orelse {
        alloc.free(pkg_name);
        return null;
    };
    const pkg_filename = filename orelse {
        alloc.free(pkg_name);
        alloc.free(pkg_version);
        return null;
    };

    return DebPackage{
        .name = pkg_name,
        .version = pkg_version,
        .depends = depends,
        .filename = pkg_filename,
        .sha256 = sha256,
        .size = size,
        .description = description,
    };
}

fn fieldValue(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, prefix)) {
        return std.mem.trim(u8, line[prefix.len..], " \t\r");
    }
    return null;
}

/// Build the full URL for a .deb package from a mirror base URL.
pub fn debUrl(base_url: []const u8, filename: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base_url, filename }) catch "";
}

/// Build a package index into a name → DebPackage lookup map.
pub fn buildIndex(alloc: std.mem.Allocator, packages: []const DebPackage) !std.StringHashMap(DebPackage) {
    var map = std.StringHashMap(DebPackage).init(alloc);
    for (packages) |pkg| {
        map.put(pkg.name, pkg) catch continue;
    }
    return map;
}

const testing = std.testing;

test "parsePackagesIndex - parses single package" {
    const data =
        \\Package: curl
        \\Version: 8.5.0-2ubuntu10.6
        \\Depends: libc6 (>= 2.38), libcurl4t64
        \\Filename: pool/main/c/curl/curl_8.5.0-2ubuntu10.6_amd64.deb
        \\SHA256: abc123def456
        \\Size: 227824
        \\Description: command line tool for transferring data
    ;
    const pkgs = try parsePackagesIndex(testing.allocator, data);
    defer {
        for (pkgs) |p| p.deinit(testing.allocator);
        testing.allocator.free(pkgs);
    }
    try testing.expectEqual(@as(usize, 1), pkgs.len);
    try testing.expectEqualStrings("curl", pkgs[0].name);
    try testing.expectEqualStrings("8.5.0-2ubuntu10.6", pkgs[0].version);
    try testing.expectEqualStrings("abc123def456", pkgs[0].sha256);
    try testing.expectEqual(@as(u64, 227824), pkgs[0].size);
}

test "parsePackagesIndex - parses multiple packages" {
    const data =
        \\Package: curl
        \\Version: 8.5.0
        \\Filename: pool/main/c/curl/curl_8.5.0_amd64.deb
        \\SHA256: aaa
        \\Size: 100
        \\
        \\Package: wget
        \\Version: 1.21.4
        \\Filename: pool/main/w/wget/wget_1.21.4_amd64.deb
        \\SHA256: bbb
        \\Size: 200
    ;
    const pkgs = try parsePackagesIndex(testing.allocator, data);
    defer {
        for (pkgs) |p| p.deinit(testing.allocator);
        testing.allocator.free(pkgs);
    }
    try testing.expectEqual(@as(usize, 2), pkgs.len);
    try testing.expectEqualStrings("curl", pkgs[0].name);
    try testing.expectEqualStrings("wget", pkgs[1].name);
}

test "debUrl - formats full URL" {
    var buf: [512]u8 = undefined;
    const url = debUrl("http://archive.ubuntu.com/ubuntu", "pool/main/c/curl/curl.deb", &buf);
    try testing.expectEqualStrings("http://archive.ubuntu.com/ubuntu/pool/main/c/curl/curl.deb", url);
}
