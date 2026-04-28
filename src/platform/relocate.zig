// nanobrew — Platform-dispatched binary relocator
//
// macOS: Mach-O relocator (install_name_tool + codesign)
// Linux: ELF relocator (patchelf)

const builtin = @import("builtin");

const macho = if (builtin.os.tag == .macos) @import("../macho/relocate.zig") else struct {};
const elf = if (builtin.os.tag == .linux) @import("../elf/relocate.zig") else struct {};
pub const placeholder = @import("placeholder.zig");

pub const relocateKeg = if (builtin.os.tag == .macos)
    macho.relocateKeg
else if (builtin.os.tag == .linux)
    elf.relocateKeg
else
    @compileError("unsupported OS");

/// On Linux, returns whether `patchelf --version` succeeds. On other
/// platforms it always returns true since no patchelf-equivalent is needed.
/// Used by the install pipeline to fail fast before downloading anything
/// when the prerequisite is missing.
pub fn hasPatchelf(alloc: std.mem.Allocator, io: std.Io) bool {
    if (builtin.os.tag != .linux) return true;
    return elf.hasPatchelf(alloc, io);
}

/// Replace @@HOMEBREW_*@@ placeholders in all text files within a keg.
/// Handles shebangs, scripts, config files, etc.
pub const replaceKegPlaceholders = placeholder.replaceKegPlaceholders;

/// Re-seal every *.framework bundle inside a keg with `codesign --deep`.
/// macOS-only; no-op on other platforms. Must be called AFTER
/// `relocateKeg` AND `replaceKegPlaceholders`, so the final bundle seal
/// covers every file mutation.
pub fn sealKegBundles(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) void {
    if (builtin.os.tag == .macos) {
        macho.sealKegBundles(alloc, io, name, version);
    }
}

const std = @import("std");
