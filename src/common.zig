const std = @import("std");

const wire = @import("./lib.zig");

pub const Type = struct {
    size: usize,
    alignment: std.mem.Alignment,
    offsets: ?[]const usize = null,
    class: Class = .int,
    /// SysV eightbyte classes, least-significant chunk first. Both `.none`
    /// means "not recorded": scalars keep using `class` for their one chunk.
    /// RISC-V `createStruct` reuses the two slots as the member classes of a
    /// two-field float+int pair. That is not a SysV chunk class: `{f32,i32}`
    /// is one INTEGER chunk on SysV and two registers on LP64D.
    eightbytes: Eightbytes = .{},
    /// Per-field byte sizes. Null on every backend except RISC-V FPCC pairs
    /// whose members are not `size / count` (`{f32,f64}` is 4 then 8, with
    /// padding in the gap). `free` releases the slice.
    field_sizes: ?[]const usize = null,

    pub const Class = enum { sse, int, mem };

    /// Class of one 8-byte chunk. `.none` is padding or an unused high chunk.
    pub const Eightbyte = enum(u2) { none, int, sse, mem };

    pub const Eightbytes = packed struct(u4) {
        low: Eightbyte = .none,
        high: Eightbyte = .none,
    };

    /// Class of eightbyte `word` (0 is the low chunk). A struct records the
    /// pair in `eightbytes`. A scalar repeats `class` across each chunk it
    /// occupies.
    pub fn eightbyte(self: Type, word: usize) Eightbyte {
        if (self.eightbytes.low != .none or self.eightbytes.high != .none) {
            return switch (word) {
                0 => self.eightbytes.low,
                1 => self.eightbytes.high,
                else => .none,
            };
        }
        if (word > 1) return .none;
        if (word > 0 and self.size <= 8) return .none;
        return switch (self.class) {
            .sse => .sse,
            .mem => .mem,
            .int => .int,
        };
    }

    pub const @"void": Type = .{ .size = 0, .alignment = .@"1" };
    pub const int8: Type = .{ .size = 1, .alignment = .@"1" };
    pub const int16: Type = .{ .size = 2, .alignment = .@"2" };
    pub const int32: Type = .{ .size = 4, .alignment = .@"4" };
    pub const int64: Type = .{ .size = 8, .alignment = .@"8" };
    pub const uint8: Type = .int8;
    pub const uint16: Type = .int16;
    pub const uint32: Type = .int32;
    pub const uint64: Type = .int64;
    pub const float32: Type = .{ .size = 4, .alignment = .@"4", .class = .sse };
    pub const float64: Type = .{ .size = 8, .alignment = .@"8", .class = .sse };
    pub const pointer: Type = .{ .size = 8, .alignment = .@"8" };

    pub fn free(self: Type, allocator: std.mem.Allocator) void {
        if (self.offsets) |offsets|
            allocator.free(offsets);
        if (self.field_sizes) |sizes|
            allocator.free(sizes);
    }

    pub fn array(@"type": Type, amt: usize) Type {
        return wire.asmb.createArray(@"type", amt);
    }

    pub fn @"struct"(allocator: std.mem.Allocator, fields: []const Type, force_alignment: ?std.mem.Alignment) !Type {
        return wire.asmb.createStruct(allocator, fields, force_alignment);
    }
};
