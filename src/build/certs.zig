// nanobrew — Native TLS trust-store wiring (cert.pem symlinks)
//
// Homebrew wires TLS trust in Ruby post_install blocks that the heuristic
// parser in postinstall.zig cannot execute (`install_symlink`, macOS
// keychain extraction). The consequence: <prefix>/etc/ca-certificates/cert.pem
// — the path baked into every TLS consumer at build time (openssl@3's
// OPENSSLDIR, curl's --with-ca-bundle, gnutls' default trust store) —
// never existed, so anything linking brewed TLS failed certificate
// verification out of the box, most visibly on fresh Linux machines.
//
// This module does natively what the Ruby would have:
//   ca-certificates → etc/ca-certificates/cert.pem → keg's cacert.pem
//   openssl[@N]     → etc/openssl[@N]/cert.pem     → etc/ca-certificates/cert.pem
//   gnutls/libressl → etc/<name>/cert.pem          → etc/ca-certificates/cert.pem
//
// When the ca-certificates keg isn't installed the system CA bundle is
// used as the target instead, so even a bare `nb install openssl@3` gets
// working TLS. Everything is idempotent and converging: a later
// ca-certificates install repoints the store at the keg bundle.

const std = @import("std");
const paths = @import("../platform/paths.zig");

const CA_STORE_DIR = paths.ETC_DIR ++ "/ca-certificates";
const CA_STORE_PEM = CA_STORE_DIR ++ "/cert.pem";
// Stable across version upgrades via the linker's opt/ symlink.
const KEG_CACERT = paths.OPT_DIR ++ "/ca-certificates/share/ca-certificates/cacert.pem";

// Well-known system CA bundle locations, fallback when the formula store
// isn't installed.
const SYSTEM_BUNDLES = [_][]const u8{
    "/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu/Alpine/Arch
    "/etc/pki/tls/certs/ca-bundle.crt", // Fedora/RHEL
    "/etc/ssl/ca-bundle.pem", // openSUSE
    "/etc/ssl/cert.pem", // macOS, FreeBSD
};

/// Post-install steps Homebrew implements in Ruby that the script parser
/// can't run. Called for every installed formula; cheap no-op for names
/// that don't participate in TLS trust.
/// Formulae whose post-install TLS wiring `nativePostInstall` does itself.
/// Their API post-install steps are not run on top (#493).
pub fn handlesPostInstall(name: []const u8) bool {
    return std.mem.eql(u8, name, "ca-certificates") or std.mem.eql(u8, name, "openssl") or
        std.mem.startsWith(u8, name, "openssl@") or std.mem.eql(u8, name, "gnutls") or
        std.mem.eql(u8, name, "libressl");
}

pub fn nativePostInstall(io: std.Io, name: []const u8) void {
    if (std.mem.eql(u8, name, "ca-certificates")) {
        _ = ensureCaStore(io);
    } else if (std.mem.eql(u8, name, "openssl") or
        std.mem.startsWith(u8, name, "openssl@") or
        std.mem.eql(u8, name, "gnutls") or
        std.mem.eql(u8, name, "libressl"))
    {
        ensureFormulaCertPem(io, name);
    }
}

/// Make <prefix>/etc/ca-certificates/cert.pem resolve to a real CA bundle:
/// the installed ca-certificates keg when present, else the system bundle.
/// Returns false when no bundle exists anywhere.
fn ensureCaStore(io: std.Io) bool {
    const target: []const u8 = if (fileExists(io, KEG_CACERT))
        KEG_CACERT
    else blk: {
        for (&SYSTEM_BUNDLES) |bundle| {
            if (fileExists(io, bundle)) break :blk bundle;
        }
        return false;
    };
    std.Io.Dir.createDirAbsolute(io, paths.ETC_DIR, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(io, CA_STORE_DIR, .default_dir) catch {};
    return ensureSymlink(io, target, CA_STORE_PEM);
}

/// Wire <prefix>/etc/<name>/cert.pem (openssl@3's OPENSSLDIR, gnutls'
/// default trust store, …) to the shared CA store.
fn ensureFormulaCertPem(io: std.Io, name: []const u8) void {
    if (!ensureCaStore(io)) return;
    var dir_buf: [256]u8 = undefined;
    const etc_dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ paths.ETC_DIR, name }) catch return;
    std.Io.Dir.createDirAbsolute(io, etc_dir, .default_dir) catch {};
    var pem_buf: [256]u8 = undefined;
    const pem_link = std.fmt.bufPrint(&pem_buf, "{s}/cert.pem", .{etc_dir}) catch return;
    _ = ensureSymlink(io, CA_STORE_PEM, pem_link);
}

/// Idempotently point `link_path` at `target`. An existing symlink is
/// repointed; an existing regular file is left alone (a user-managed
/// bundle wins over ours). Returns true when the link resolves usably.
fn ensureSymlink(io: std.Io, target: []const u8, link_path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, link_path, &buf)) |existing_len| {
        if (std.mem.eql(u8, buf[0..existing_len], target)) return true;
        std.Io.Dir.deleteFileAbsolute(io, link_path) catch return false;
    } else |err| switch (err) {
        error.FileNotFound => {},
        // Exists but isn't a symlink we manage (regular file) — leave it.
        else => return true,
    }
    std.Io.Dir.symLinkAbsolute(io, target, link_path, .{}) catch return false;
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;

fn tmpAbsPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    return std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}/{s}", .{ cwd, tmp.sub_path[0..], name });
}
test "ensureSymlink creates, repoints, and leaves regular files alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_a = try tmpAbsPath(&tmp, "bundle-a.pem");
    defer testing.allocator.free(target_a);
    const target_b = try tmpAbsPath(&tmp, "bundle-b.pem");
    defer testing.allocator.free(target_b);
    const link_path = try tmpAbsPath(&tmp, "cert.pem");
    defer testing.allocator.free(link_path);

    {
        var f = try tmp.dir.createFile(testing.io, "bundle-a.pem", .{});
        f.close(testing.io);
    }

    // Creates when missing.
    try testing.expect(ensureSymlink(testing.io, target_a, link_path));
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var n = try std.Io.Dir.readLinkAbsolute(testing.io, link_path, &buf);
    try testing.expectEqualStrings(target_a, buf[0..n]);

    // Repoints an existing symlink (converges system bundle → keg bundle).
    try testing.expect(ensureSymlink(testing.io, target_b, link_path));
    n = try std.Io.Dir.readLinkAbsolute(testing.io, link_path, &buf);
    try testing.expectEqualStrings(target_b, buf[0..n]);

    // Idempotent when already correct.
    try testing.expect(ensureSymlink(testing.io, target_b, link_path));

    // A regular file at the link path is left untouched.
    try std.Io.Dir.deleteFileAbsolute(testing.io, link_path);
    {
        var f = try tmp.dir.createFile(testing.io, "cert.pem", .{});
        f.close(testing.io);
    }
    try testing.expect(ensureSymlink(testing.io, target_a, link_path));
    if (std.Io.Dir.readLinkAbsolute(testing.io, link_path, &buf)) |_| {
        return error.TestUnexpectedResult; // must still be a regular file
    } else |_| {}
}

test "nativePostInstall ignores unrelated formulae" {
    // Must be a pure no-op for names outside the TLS set — no /opt access.
    nativePostInstall(testing.io, "wget-not-really");
    nativePostInstall(testing.io, "ripgrep");
}
