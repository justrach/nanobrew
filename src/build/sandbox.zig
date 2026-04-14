// nanobrew — macOS sandbox-exec SBPL profile generation
//
// Generates sandbox profiles that restrict post-install script execution
// to the keg directory, denying network access and limiting IPC.

const std = @import("std");
const builtin = @import("builtin");

const PROFILE_TEMPLATE =
    \\(version 1)
    \\(deny default)
    \\
    \\;; Allow reads on system essentials
    \\(allow file-read*
    \\    (subpath "/usr/lib")
    \\    (subpath "/usr/share")
    \\    (subpath "/System")
    \\    (subpath "/Library/Preferences")
    \\    (subpath "/private/var/db")
    \\    (literal "/dev/null")
    \\    (literal "/dev/urandom")
    \\    (literal "/dev/random")
    \\    (subpath "/etc"))
    \\
    \\;; Allow read/write within the keg only
    \\(allow file-read* file-write*
    \\    (subpath "@@KEG_PATH@@"))
    \\
    \\;; Allow executing system tools needed by post-install
    \\(allow process-exec
    \\    (subpath "/bin")
    \\    (subpath "/usr/bin")
    \\    (subpath "@@KEG_PATH@@"))
    \\
    \\;; Allow process-fork (needed for mkdir, ln, etc.)
    \\(allow process-fork)
    \\
    \\;; Deny network entirely
    \\(deny network*)
    \\
    \\;; Deny IPC except essentials
    \\(deny mach-lookup)
    \\(allow mach-lookup
    \\    (global-name "com.apple.system.logger"))
    \\
    \\;; Deny signal sending
    \\(deny signal (target others))
;

/// Generate an SBPL sandbox profile for the given keg path.
/// Caller owns the returned slice.
pub fn generateProfile(alloc: std.mem.Allocator, keg_path: []const u8) ![]u8 {
    // Validate keg_path: reject characters that could break SBPL quoting
    for (keg_path) |c| {
        switch (c) {
            '"', '(', ')', '\\', 0 => return error.UnsafeKegPath,
            else => {},
        }
    }

    // Replace all @@KEG_PATH@@ placeholders with the actual keg path
    const placeholder_str = "@@KEG_PATH@@";
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    var remaining: []const u8 = PROFILE_TEMPLATE;
    while (std.mem.indexOf(u8, remaining, placeholder_str)) |idx| {
        try result.appendSlice(alloc, remaining[0..idx]);
        try result.appendSlice(alloc, keg_path);
        remaining = remaining[idx + placeholder_str.len ..];
    }
    try result.appendSlice(alloc, remaining);

    return try result.toOwnedSlice(alloc);
}

pub const SandboxedResult = struct {
    argv: []const []const u8,
    profile: []u8,
};

/// Wrap an argv in a sandbox-exec invocation on macOS.
/// On other platforms, duplicates the original argv unchanged.
/// Caller owns all returned memory.
pub fn sandboxedArgv(
    alloc: std.mem.Allocator,
    original_argv: []const []const u8,
    keg_path: []const u8,
) !SandboxedResult {
    if (comptime builtin.os.tag != .macos) {
        // Non-macOS: just duplicate the original argv
        const duped = try alloc.alloc([]const u8, original_argv.len);
        for (original_argv, 0..) |arg, i| {
            duped[i] = try alloc.dupe(u8, arg);
        }
        return .{
            .argv = duped,
            .profile = &.{},
        };
    }

    const profile = try generateProfile(alloc, keg_path);
    errdefer alloc.free(profile);

    // Build new argv: ["sandbox-exec", "-p", <profile>, ...original_argv]
    const new_len = 3 + original_argv.len;
    const new_argv = try alloc.alloc([]const u8, new_len);
    errdefer alloc.free(new_argv);

    new_argv[0] = try alloc.dupe(u8, "sandbox-exec");
    new_argv[1] = try alloc.dupe(u8, "-p");
    new_argv[2] = try alloc.dupe(u8, profile);
    for (original_argv, 0..) |arg, i| {
        new_argv[3 + i] = try alloc.dupe(u8, arg);
    }

    return .{
        .argv = new_argv,
        .profile = profile,
    };
}
