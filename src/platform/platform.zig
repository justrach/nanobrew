// nanobrew — Platform detection hub
//
// Centralizes all platform-specific code behind comptime switches.
// Dead code for the non-target platform is never compiled.

const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

pub const paths = @import("paths.zig");
pub const copy = @import("copy.zig");
pub const relocate = @import("relocate.zig");
pub const placeholder = @import("placeholder.zig");
