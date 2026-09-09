const std = @import("std");

/// Detach parsed JSON snapshots from their arena for the existing owned models.
pub fn clone(comptime T: type, a: std.mem.Allocator, value: T) !T {
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("only slices supported");
            const out = try a.alloc(p.child, value.len);
            var done: usize = 0;
            errdefer {
                for (out[0..done]) |v| free(p.child, a, v);
                a.free(out);
            }
            for (value, 0..) |v, i| {
                out[i] = try clone(p.child, a, v);
                done += 1;
            }
            break :blk out;
        },
        .optional => |o| if (value) |v| try clone(o.child, a, v) else null,
        .@"struct" => blk: {
            var out: T = undefined;
            var done: usize = 0;
            errdefer inline for (comptime std.meta.fieldNames(T), 0..) |name, i| {
                if (i < done) free(@FieldType(T, name), a, @field(out, name));
            };
            inline for (comptime std.meta.fieldNames(T)) |name| {
                @field(out, name) = try clone(@FieldType(T, name), a, @field(value, name));
                done += 1;
            }
            break :blk out;
        },
        .@"union" => blk: {
            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (std.mem.eql(u8, @tagName(value), name)) break :blk @unionInit(T, name, try clone(@FieldType(T, name), a, @field(value, name)));
            }
            unreachable;
        },
        else => value,
    };
}

pub fn free(comptime T: type, a: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            for (value) |v| free(p.child, a, v);
            a.free(value);
        },
        .optional => |o| {
            if (value) |v| free(o.child, a, v);
        },
        .@"struct" => {
            inline for (comptime std.meta.fieldNames(T)) |name| free(@FieldType(T, name), a, @field(value, name));
        },
        .@"union" => {
            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (std.mem.eql(u8, @tagName(value), name)) free(@FieldType(T, name), a, @field(value, name));
            }
        },
        else => {},
    }
}
