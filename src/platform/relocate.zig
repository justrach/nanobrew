// nanobrew — Platform-dispatched binary relocator
//
// macOS: Mach-O relocator (install_name_tool + codesign)
// Linux: ELF relocator (patchelf)

const builtin = @import("builtin");

const macho = if (builtin.os.tag == .macos) @import("../macho/relocate.zig") else struct {};
const elf = if (builtin.os.tag == .linux) @import("../elf/relocate.zig") else struct {};

pub const relocateKeg = if (builtin.os.tag == .macos)
    macho.relocateKeg
else if (builtin.os.tag == .linux)
    elf.relocateKeg
else
    @compileError("unsupported OS");
