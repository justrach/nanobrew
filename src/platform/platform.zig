// nanobrew — Platform detection hub
//
// Centralizes all platform-specific code behind comptime switches.
// Dead code for the non-target platform is never compiled.

const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

/// Debian architecture string for the current target.
/// Maps Zig's CPU arch to dpkg arch names.
pub const deb_arch = if (builtin.cpu.arch == .aarch64) "arm64" else "amd64";

pub const paths = @import("paths.zig");
pub const copy = @import("copy.zig");
pub const relocate = @import("relocate.zig");
pub const placeholder = @import("placeholder.zig");
