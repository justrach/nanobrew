// nanobrew — Service management dispatcher
//
// macOS: launchd (plist files)
// Linux: systemd (.service files)

const builtin = @import("builtin");

const impl = if (builtin.os.tag == .linux)
    @import("systemd.zig")
else
    @import("launchd.zig");

pub const Service = impl.Service;
pub const discoverServices = impl.discoverServices;
pub const isRunning = impl.isRunning;
pub const start = impl.start;
pub const stop = impl.stop;
