const std = @import("std");
const common = @import("../common.zig");

/// Straight-line virtual register. Assigned densely from 0 at build time.
pub const VReg = enum(u32) {
    _,

    pub fn int(v: VReg) u32 {
        return @backingInt(v);
    }

    pub fn fromInt(i: u32) VReg {
        return @fromBackingInt(i);
    }
};
/// Operand of an instruction: a vreg or a compile-time constant.
pub const Ref = union(enum) {
    virtual: VReg,
    /// Integer/float bit pattern; type lives on the instruction that uses it.
    immediate: u64,
    /// Absolute address baked at generation.
    pointer: *const anyopaque,

    pub fn vreg(v: VReg) Ref {
        return .{ .virtual = v };
    }

    pub fn imm(bits: u64) Ref {
        return .{ .immediate = bits };
    }
    pub fn ptr(p: *const anyopaque) Ref {
        return .{ .pointer = p };
    }
};

pub const Value = struct {
    type: common.Type,
    location: Ref,

    pub fn symbol(p: *const anyopaque) Value {
        return .{
            .type = .pointer,
            .location = .{ .pointer = p },
        };
    }

    pub fn imm(ty: common.Type, value: u64) Value {
        return .{
            .type = ty,
            .location = .{ .immediate = value },
        };
    }
};

pub const Callee = union(enum) {
    immediate: *const anyopaque,
    virtual: VReg,

    pub fn imm(ptr: *const anyopaque) Callee {
        return .{ .immediate = ptr };
    }
    pub fn vreg(v: VReg) Callee {
        return .{ .virtual = v };
    }
    pub fn value(v: Value) Callee {
        std.debug.assert(v.location == .virtual);
        return .{ .virtual = v.location.virtual };
    }
};

pub const Arg = struct {
    ref: Ref,
    type: common.Type,
};

/// Linear IR. No control flow — last-use is a single forward scan.
pub const Inst = union(enum) {
    /// Stack object. Always has a frame home.
    allocate: struct {
        destination: VReg,
        type: common.Type,

        pub fn with(destination: VReg, @"type": common.Type) @This() {
            return .{
                .destination = destination,
                .type = @"type",
            };
        }
    },
    /// `dst = lea(src)`. Forces `src` into memory.
    address_of: struct {
        destination: VReg,
        source: VReg,

        pub fn with(destination: VReg, source: VReg) @This() {
            return .{
                .destination = destination,
                .source = source,
            };
        }
    },
    /// `dst = *(ptr + off)`.
    load: struct {
        destination: VReg,
        pointer: Ref,
        offset: i32,
        type: common.Type,

        pub fn with(destination: VReg, pointer: Ref, offset: i32, @"type": common.Type) @This() {
            return .{
                .destination = destination,
                .pointer = pointer,
                .offset = offset,
                .type = @"type",
            };
        }
    },
    /// `*(ptr + off) = src`.
    store: struct {
        pointer: Ref,
        offset: i32,
        source: Ref,
        type: common.Type,

        pub fn with(pointer: Ref, offset: i32, source: Ref, @"type": common.Type) @This() {
            return .{
                .pointer = pointer,
                .offset = offset,
                .source = source,
                .type = @"type",
            };
        }
    },
    /// `dst = lea(base + off)` — pointer arithmetic, not a stack object.
    load_effective_address: struct {
        destination: VReg,
        base: Ref,
        offset: i32,

        pub fn with(destination: VReg, base: Ref, offset: i32) @This() {
            return .{
                .destination = destination,
                .base = base,
                .offset = offset,
            };
        }
    },
    call: Call,

    pub const Call = struct {
        destination: ?VReg,
        callee: Callee,
        arguments: []const Arg,
        return_type: common.Type,
        structure_return_dest: ?Ref,

        pub fn stage(
            destination: ?VReg,
            callee: Callee,
            arguments: []const Arg,
            return_type: common.Type,
            structure_return_dest: ?Ref,
        ) @This() {
            return .{
                .destination = destination,
                .callee = callee,
                .arguments = arguments,
                .return_type = return_type,
                .structure_return_dest = structure_return_dest,
            };
        }
    };

    pub fn def(self: Inst) ?VReg {
        return switch (self) {
            .allocate => |i| i.destination,
            .address_of => |i| i.destination,
            .load => |i| i.destination,
            .store => null,
            .load_effective_address => |i| i.destination,
            .call => |c| c.destination,
        };
    }
};

pub fn uses(buf: []VReg, inst: Inst) usize {
    std.debug.assert(buf.len > 0);
    var n: usize = 0;
    switch (inst) {
        .allocate => {},
        .address_of => |i| {
            buf[n] = i.source;
            return 1;
        },
        .load => |i| switch (i.pointer) {
            .virtual => |v| {
                buf[0] = v;
                return 1;
            },
            else => {},
        },
        .store => |i| {
            switch (i.pointer) {
                .virtual => |v| {
                    buf[n] = v;
                    n += 1;
                },
                else => {},
            }
            switch (i.source) {
                .virtual => |v| {
                    buf[n] = v;
                    n += 1;
                },
                else => {},
            }
            return n;
        },
        .load_effective_address => |i| switch (i.base) {
            .virtual => |v| {
                buf[n] = v;
                return 1;
            },
            else => {},
        },
        .call => |c| {
            switch (c.callee) {
                .virtual => |v| {
                    buf[n] = v;
                    n += 1;
                },
                else => {},
            }
            if (c.structure_return_dest) |d| switch (d) {
                .virtual => |v| {
                    buf[n] = v;
                    n += 1;
                },
                else => {},
            };
            for (c.arguments) |a| switch (a.ref) {
                .virtual => |v| {
                    buf[n] = v;
                    n += 1;
                },
                else => {},
            };
            return n;
        },
    }
    return 0;
}

pub const no_use: u32 = std.math.maxInt(u32);

pub fn lastUse(
    allocator: std.mem.Allocator,
    insts: []const Inst,
    n_vregs: usize,
    extra: []const VReg,
) ![]u32 {
    const last = try allocator.alloc(u32, n_vregs);
    @memset(last, no_use);
    var buf: [36]VReg = undefined;
    for (insts, 0..) |inst, i| {
        const amt = uses(buf[0..], inst);
        for (buf[0..amt]) |v|
            last[v.int()] = @intCast(i);
    }
    const finish_idx: u32 = @intCast(insts.len);
    for (extra) |v|
        last[v.int()] = finish_idx;
    return last;
}

test "lastUse unused param is no_use" {
    // v0 unused, v1 used as callee of inst 0.
    const insts = [_]Inst{.{
        .call = .stage(null, .vreg(@fromBackingInt(1)), &.{}, .void, null),
    }};
    const last = try lastUse(std.testing.allocator, &insts, 2, &.{});
    defer std.testing.allocator.free(last);
    try std.testing.expectEqual(no_use, last[0]);
    try std.testing.expectEqual(@as(u32, 0), last[1]);
}

test "lastUse live across call" {
    const args = [_]Arg{.{ .ref = .vreg(@fromBackingInt(0)), .type = .int64 }};
    const insts = [_]Inst{
        .{
            .call = .stage(@fromBackingInt(1), .imm(@ptrFromInt(1)), &args, .int64, null),
        },
        .{
            .call = .stage(@fromBackingInt(2), .imm(@ptrFromInt(1)), &args, .int64, null),
        },
    };
    const last = try lastUse(std.testing.allocator, &insts, 3, &.{@fromBackingInt(2)});
    defer std.testing.allocator.free(last);
    try std.testing.expectEqual(@as(u32, 1), last[0]); // used at second call
    try std.testing.expectEqual(no_use, last[1]); // dst of first, never consumed
    try std.testing.expectEqual(@as(u32, 2), last[2]); // returned at finish
}
