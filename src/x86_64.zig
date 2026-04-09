const std = @import("std");
const builtin = @import("builtin");

const build_cfg = @import("build_cfg");

const Conventions = enum {
    Windows,
    SystemV,
};

pub const CallingConvention = switch (builtin.os.tag) {
    .windows => Conventions.Windows,
    else => Conventions.SystemV,
};

const REX = 0x40;

pub const ArgumentRegistery = switch (CallingConvention) {
    .Windows => [_]AssemblyBuilder.Register{ .rcx, .rdx, .r8, .r9 },
    else => [_]AssemblyBuilder.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 },
};

pub const FloatingPointRegistery = switch (CallingConvention) {
    .Windows => [_]AssemblyBuilder.Register{ .xmm0, .xmm1, .xmm2, .xmm3 },
    else => [_]AssemblyBuilder.Register{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 },
};

const CalleeSavedRegistery = switch (CallingConvention) {
    .Windows => [_]AssemblyBuilder.Register{ .rbx, .rbp, .rdi, .rsi, .r12, .r13, .r14, .r15 },
    else => [_]AssemblyBuilder.Register{ .rbx, .rbp, .r12, .r13, .r14, .r15 },
};

const CallerSavedRegistery = switch (CallingConvention) {
    .Windows => [_]AssemblyBuilder.Register{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 },
    else => [_]AssemblyBuilder.Register{ .rax, .rdi, .rsi, .rdx, .rcx, .r8, .r9, .r10, .r11 },
};

const AssemblyBuilder = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(Instruction),
    stack_push_offset: usize = 0,

    const Register = enum {
        // zig fmt: off
        ax, cx, dx, bx, sp, bp, si, di,
        eax, ecx, edx, ebx, esp, ebp, esi, edi,
        rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi,
        r8, r9, r10, r11, r12, r13, r14, r15,
        xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7,
        xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,
        // zig fmt: on
        SIB,

        pub fn withBitSize(self: Register, bit_size: u8) Register {
            if (@intFromEnum(self) >= @intFromEnum(@as(Register, .r8)))
                return self;
            return switch (bit_size) {
                2 => switch (self) {
                    .ax, .cx, .dx, .bx, .sp, .bp, .si, .di => self,
                    .eax, .ecx, .edx, .ebx, .esp, .ebp, .esi, .edi => @enumFromInt(@intFromEnum(self) - @intFromEnum(@as(Register, .eax))),
                    .rax, .rcx, .rdx, .rbx, .rsp, .rbp, .rsi, .rdi => @enumFromInt(@intFromEnum(self) - @intFromEnum(@as(Register, .rax))),
                    else => unreachable,
                },
                4 => switch (self) {
                    .ax, .cx, .dx, .bx, .sp, .bp, .si, .di => @enumFromInt(@intFromEnum(self) + @intFromEnum(@as(Register, .eax))),
                    .eax, .ecx, .edx, .ebx, .esp, .ebp, .esi, .edi => self,
                    .rax, .rcx, .rdx, .rbx, .rsp, .rbp, .rsi, .rdi => @enumFromInt(@intFromEnum(self) - @intFromEnum(@as(Register, .eax))),
                    else => unreachable,
                },
                8 => switch (self) {
                    .ax, .cx, .dx, .bx, .sp, .bp, .si, .di => @enumFromInt(@intFromEnum(self) + @intFromEnum(@as(Register, .rax))),
                    .eax, .ecx, .edx, .ebx, .esp, .ebp, .esi, .edi => @enumFromInt(@intFromEnum(self) + @intFromEnum(@as(Register, .eax))),
                    .rax, .rcx, .rdx, .rbx, .rsp, .rbp, .rsi, .rdi => self,
                    else => unreachable,
                },
                else => unreachable, // bit_size either not 2, 4 or 8
            };
        }

        test withBitSize {
            try std.testing.expectEqual(.ax, withBitSize(Register.ax, 2));
            try std.testing.expectEqual(.ax, withBitSize(Register.rax, 2));
            try std.testing.expectEqual(.ax, withBitSize(Register.eax, 2));
            try std.testing.expectEqual(.cx, withBitSize(Register.rcx, 2));
            try std.testing.expectEqual(.cx, withBitSize(Register.ecx, 2));
            try std.testing.expectEqual(.r8, withBitSize(Register.r8, 2));
            try std.testing.expectEqual(.xmm0, withBitSize(Register.xmm0, 2));

            try std.testing.expectEqual(.eax, withBitSize(Register.eax, 4));
            try std.testing.expectEqual(.eax, withBitSize(Register.rax, 4));
            try std.testing.expectEqual(.eax, withBitSize(Register.ax, 4));
            try std.testing.expectEqual(.ecx, withBitSize(Register.cx, 4));
            try std.testing.expectEqual(.ecx, withBitSize(Register.rcx, 4));
            try std.testing.expectEqual(.r8, withBitSize(Register.r8, 4));
            try std.testing.expectEqual(.xmm0, withBitSize(Register.xmm0, 4));

            try std.testing.expectEqual(.rax, withBitSize(Register.rax, 8));
            try std.testing.expectEqual(.rax, withBitSize(Register.eax, 8));
            try std.testing.expectEqual(.rax, withBitSize(Register.ax, 8));
            try std.testing.expectEqual(.rcx, withBitSize(Register.rcx, 8));
            try std.testing.expectEqual(.rcx, withBitSize(Register.ecx, 8));
            try std.testing.expectEqual(.r8, withBitSize(Register.r8, 8));
            try std.testing.expectEqual(.xmm0, withBitSize(Register.xmm0, 8));
        }

        pub inline fn toOperandSize(self: Register) u5 {
            return switch (self) {
                .ax, .cx, .dx, .bx, .sp, .bp, .si, .di => 2,
                .eax, .ecx, .edx, .ebx, .esp, .ebp, .esi, .edi => 4,
                .rax, .rcx, .rdx, .rbx, .rsp, .rbp, .rsi, .rdi => 8,
                .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15 => 8,
                .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 => 16,
                .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15 => 16,
                .SIB => 8,
            };
        }

        pub inline fn toInt(self: Register) u8 {
            return switch (self) {
                .ax, .eax, .rax, .r8, .xmm0, .xmm8 => return 0x00,
                .cx, .ecx, .rcx, .r9, .xmm1, .xmm9 => return 0x01,
                .dx, .edx, .rdx, .r10, .xmm2, .xmm10 => return 0x02,
                .bx, .ebx, .rbx, .r11, .xmm3, .xmm11 => return 0x03,
                .sp, .esp, .rsp, .r12, .xmm4, .xmm12 => return 0x04,
                .bp, .ebp, .rbp, .r13, .xmm5, .xmm13 => return 0x05,
                .si, .esi, .rsi, .r14, .xmm6, .xmm14 => return 0x06,
                .di, .edi, .rdi, .r15, .xmm7, .xmm15 => return 0x07,
                .SIB => return 0x04,
            };
        }

        pub inline fn isExtendedBase(self: Register) bool {
            return switch (self) {
                .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15 => true,
                else => false,
            };
        }

        pub inline fn isSIB(self: Register) bool {
            return switch (self) {
                .rsp, .r12 => true,
                else => false,
            };
        }
    };

    const Mod = enum(u8) {
        access = 0x00,
        disp8 = 0x01,
        disp32 = 0x02,
        direct = 0x03,
    };

    const RegOpcode = enum(u8) {
        add = 0x00,
        call = 0x02,
        sub = 0x05,
    };

    pub fn SIB(comptime scale: u8, index: u8, base: u8) u8 {
        return (scale << 6) | (index << 3) | base;
    }

    pub fn ModRM(mod: Mod, reg: u8, base: u8) u8 {
        return (@intFromEnum(mod) << 6) | (reg << 3) | base;
    }

    pub fn init(allocator: std.mem.Allocator, num: usize) AssemblyBuilder {
        return .{
            .allocator = allocator,
            .array = try std.ArrayList(Instruction).init(allocator, num),
        };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !AssemblyBuilder {
        return .{
            .allocator = allocator,
            .array = try std.ArrayList(Instruction).initCapacity(allocator, num),
        };
    }

    pub fn appendInsnSlice(self: *AssemblyBuilder, insns: []const Instruction) !void {
        for (insns) |insn|
            try self.array.append(self.allocator, insn);
    }

    pub fn appendInsn(self: *AssemblyBuilder, insn: Instruction) !void {
        try self.array.append(self.allocator, insn);
    }

    pub fn print(self: *AssemblyBuilder) void {
        for (self.array.items) |insn| {
            insn.print();
        }
    }

    inline fn RexRegister(reg: Register, base: Register) u8 {
        var rex: u8 = 0x40;

        if (reg.toOperandSize() == 8)
            rex |= (0x01 << 3); // 64-bit operand size

        if (reg.isExtendedBase())
            rex |= (0x01 << 2); // REG is extended registers

        if (base.isExtendedBase())
            rex |= 0x01; // Base is extended registers

        return rex;
    }

    inline fn RexRegisterSingle(base: Register) u8 {
        var rex: u8 = 0x40;

        if (base.toOperandSize() == 8)
            rex |= (0x01 << 3); // 64-bit operand size

        if (base.isExtendedBase())
            rex |= 0x01; // Base is extended registers

        return rex;
    }

    pub const Instruction = union(enum) {
        push: Register,
        pop: Register,
        imm: struct { RegOpcode, Register, u32 },
        call: Register,
        ret: void,
        mov: struct { MovKind, Register, Register, ?i32 },
        movss: struct { MovKind, Register, Register, ?i32 },
        movsd: struct { MovKind, Register, Register, ?i32 },
        movaps: struct { MovKind, Register, Register, ?i32 },
        movapd: struct { MovKind, Register, Register, ?i32 },
        movups: struct { MovKind, Register, Register, ?i32 },
        movupd: struct { MovKind, Register, Register, ?i32 },
        movdqu: struct { MovKind, Register, Register, ?i32 },

        pub const MovKind = enum { load, store };

        inline fn emitPush(writer: *std.Io.Writer, reg: Register) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            if (reg.isExtendedBase()) {
                try writer.writeByte(RexRegisterSingle(reg));
                try writer.writeByte(0x50 | reg.toInt());
            } else try writer.writeByte(0x50 | reg.toInt());
        }

        inline fn emitPop(writer: *std.Io.Writer, reg: Register) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            if (reg.isExtendedBase()) {
                try writer.writeByte(RexRegisterSingle(reg));
                try writer.writeByte(0x58 | reg.toInt());
            } else try writer.writeByte(0x58 | reg.toInt());
        }

        inline fn emitImm(writer: *std.Io.Writer, op: RegOpcode, reg: Register, value: u32) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            try writer.writeByte(RexRegisterSingle(reg));
            if (value > std.math.maxInt(u8)) {
                try writer.writeByte(0x81); // imm r/m64, imm32
                try writer.writeByte(ModRM(.direct, @intFromEnum(op), reg.toInt()));
                try writer.writeAll(&@as([4]u8, @bitCast(value)));
            } else {
                try writer.writeByte(0x83); // imm r/m64, imm8
                try writer.writeByte(ModRM(.direct, @intFromEnum(op), reg.toInt()));
                try writer.writeByte(@truncate(value));
            }
        }

        inline fn emitCall(writer: *std.Io.Writer, reg: Register) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            if (reg.isExtendedBase())
                try writer.writeByte(RexRegister(.ax, reg));
            try writer.writeByte(0xFF); // call r/m64
            try writer.writeByte(ModRM(.direct, @intFromEnum(RegOpcode.call), reg.toInt()));
        }

        inline fn emitRet(writer: *std.Io.Writer) !void {
            try writer.writeByte(0xC3); // ret
        }

        inline fn emitMov(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            if (base.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            try writer.writeByte(RexRegister(base, reg));
            switch (kind) {
                .load => try writer.writeByte(0x8B), // mov r64, r/m64
                .store => try writer.writeByte(0x89), // mov r/m64, r64
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovss(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0xF3); // Scalar single-precision
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            try writer.writeByte(0x0F); // Prefix for SSE2
            switch (kind) {
                .load => try writer.writeByte(0x10), // mov xmm, r/m32
                .store => try writer.writeByte(0x11), // mov r/m32, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovsd(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0xF2); // Scalar double-precision
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            try writer.writeByte(0x0F); // Prefix for SSE2
            switch (kind) {
                .load => try writer.writeByte(0x10), // mov xmm, r/m64
                .store => try writer.writeByte(0x11), // mov r/m64, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovaps(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0x0F); // Prefix for SSE2
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            switch (kind) {
                .load => try writer.writeByte(0x28), // mov xmm, r/m128
                .store => try writer.writeByte(0x29), // mov r/m128, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovapd(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0x66); // double-precision
            try writer.writeByte(0x0F); // Prefix for SSE2
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            switch (kind) {
                .load => try writer.writeByte(0x28), // mov xmm, r/m128
                .store => try writer.writeByte(0x29), // mov r/m128, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovups(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0x0F); // Prefix for SSE2
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            switch (kind) {
                .load => try writer.writeByte(0x10), // mov xmm, r/m128
                .store => try writer.writeByte(0x11), // mov r/m128, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovupd(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0x66); // double-precision
            try writer.writeByte(0x0F); // Prefix for SSE2
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            switch (kind) {
                .load => try writer.writeByte(0x10), // mov xmm, r/m128
                .store => try writer.writeByte(0x11), // mov r/m128, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        inline fn emitMovdqu(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            try writer.writeByte(0xF3);
            const rex = RexRegister(base, reg);
            if (rex != 0x40)
                try writer.writeByte(rex);
            try writer.writeByte(0x0F); // Prefix for SSE2
            switch (kind) {
                .load => try writer.writeByte(0x6F), // mov xmm, r/m128
                .store => try writer.writeByte(0x7F), // mov r/m128, xmm
            }
            if (disp) |d| {
                const mode: Mod = if (d > std.math.maxInt(i8) or d < std.math.minInt(i8))
                    .disp32
                else if (d != 0 or reg == .r13 or reg == .rbp)
                    .disp8
                else
                    .access;
                try writer.writeByte(ModRM(mode, base.toInt(), reg.toInt()));
                if (reg.isSIB())
                    try writer.writeByte(SIB(0x00, 0x04, reg.toInt()));
                switch (mode) {
                    .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(d))),
                    .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(d)))),
                    .access => {},
                    .direct => unreachable,
                }
            } else try writer.writeByte(ModRM(.direct, base.toInt(), reg.toInt()));
        }

        pub fn emit(self: Instruction, writer: *std.Io.Writer) !void {
            return switch (self) {
                .push => |insn| emitPush(writer, insn),
                .pop => |insn| emitPop(writer, insn),
                .imm => |insn| emitImm(writer, insn[0], insn[1], insn[2]),
                .call => |insn| emitCall(writer, insn),
                .ret => emitRet(writer),
                .mov => |insn| emitMov(writer, insn[0], insn[1], insn[2], insn[3]),
                .movss => |insn| emitMovss(writer, insn[0], insn[1], insn[2], insn[3]),
                .movsd => |insn| emitMovsd(writer, insn[0], insn[1], insn[2], insn[3]),
                .movaps => |insn| emitMovaps(writer, insn[0], insn[1], insn[2], insn[3]),
                .movapd => |insn| emitMovapd(writer, insn[0], insn[1], insn[2], insn[3]),
                .movups => |insn| emitMovups(writer, insn[0], insn[1], insn[2], insn[3]),
                .movupd => |insn| emitMovupd(writer, insn[0], insn[1], insn[2], insn[3]),
                .movdqu => |insn| emitMovdqu(writer, insn[0], insn[1], insn[2], insn[3]),
            };
        }

        pub fn print(self: Instruction) void {
            return switch (self) {
                .push, .pop, .call => |insn| std.debug.print("{s}: {s}\n", .{ @tagName(self), @tagName(insn) }),
                .imm => |insn| std.debug.print("imm: {s}, {s} {d}\n", .{ @tagName(insn[0]), @tagName(insn[1]), insn[2] }),
                .ret => std.debug.print("ret\n", .{}),
                .mov, .movss, .movsd, .movapd, .movaps, .movupd, .movups, .movdqu => |insn| switch (insn[0]) {
                    .store => {
                        if (insn[3]) |d|
                            std.debug.print("{s}: [{s} + {d}], {s}\n", .{ @tagName(self), @tagName(insn[1]), d, @tagName(insn[2]) })
                        else
                            std.debug.print("{s}: {s}, {s}\n", .{ @tagName(self), @tagName(insn[1]), @tagName(insn[2]) });
                    },
                    .load => {
                        if (insn[3]) |d|
                            std.debug.print("{s}: {s}, [{s} + {d}]\n", .{ @tagName(self), @tagName(insn[1]), @tagName(insn[2]), d })
                        else
                            std.debug.print("{s}: {s}, {s}\n", .{ @tagName(self), @tagName(insn[1]), @tagName(insn[2]) });
                    },
                },
            };
        }
    };

    pub fn push(self: *AssemblyBuilder, reg: Register) !void {
        try self.appendInsn(.{ .push = reg });
        self.stack_push_offset += 8;
    }

    pub fn pop(self: *AssemblyBuilder, reg: Register) !void {
        try self.appendInsn(.{ .pop = reg });
        self.stack_push_offset -= 8;
    }

    pub fn imm(self: *AssemblyBuilder, op: RegOpcode, reg: Register, value: u32) !void {
        try self.appendInsn(.{ .imm = .{ op, reg, value } });
    }

    pub fn call(self: *AssemblyBuilder, reg: Register) !void {
        try self.appendInsn(.{ .call = reg });
    }

    pub fn ret(self: *AssemblyBuilder) !void {
        try self.appendInsn(.ret);
    }

    pub fn mov(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .mov = .{ kind, base, reg, disp } });
    }

    pub fn movss(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movss = .{ kind, base, reg, disp } });
    }

    pub fn movsd(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movsd = .{ kind, base, reg, disp } });
    }

    pub fn movaps(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movaps = .{ kind, base, reg, disp } });
    }

    pub fn movapd(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movapd = .{ kind, base, reg, disp } });
    }

    pub fn movups(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movups = .{ kind, base, reg, disp } });
    }

    pub fn movupd(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movupd = .{ kind, base, reg, disp } });
    }

    pub fn movdqu(self: *AssemblyBuilder, kind: Instruction.MovKind, base: Register, reg: Register, disp: ?i32) !void {
        try self.appendInsn(.{ .movdqu = .{ kind, base, reg, disp } });
    }

    pub fn compile(self: *AssemblyBuilder, allocator: std.mem.Allocator) ![]align(std.heap.page_size_min) u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        var last_pos: usize = 0;
        for (self.array.items) |insn| {
            try insn.emit(&writer.writer);
            const slice = writer.written()[last_pos..];
            last_pos = writer.written().len;
            if (comptime build_cfg.verbose_asm) {
                std.debug.print("{x}\n", .{slice});
            }
        }
        const slice = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), writer.written().len);
        @memcpy(slice, writer.written());
        return slice;
    }

    pub fn deinit(self: *AssemblyBuilder) void {
        self.array.deinit(self.allocator);
    }
};

pub const DataType = struct {
    size: usize,
    alignment: u29,
    offsets: ?[]const usize = null,
    class: Class = .int,

    pub const Class = enum { sse, int, mem };

    pub fn free(self: DataType, allocator: std.mem.Allocator) void {
        if (self.offsets) |offsets|
            allocator.free(offsets);
    }
};

fn alignForward(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(@as(usize, alignment - 1));
}

pub fn createStruct(allocator: std.mem.Allocator, fields: []const DataType, force_alignment: ?u29) !DataType {
    if (fields.len == 0)
        return DataType{ .size = 0, .alignment = 0 };
    var offset: usize = 0;
    var alignment: u29 = 1;
    var offsets = try allocator.alloc(usize, fields.len);
    errdefer allocator.free(offsets);
    var class = fields[0].class;
    for (fields, 0..) |field, i| {
        alignment = @max(alignment, field.alignment);
        offset = alignForward(offset, field.alignment);
        offsets[i] = offset;
        offset += field.size;
        if (class != field.class)
            class = .int;
    }
    if (force_alignment orelse alignment < alignment)
        return error.PoorAlignment;
    const size = alignForward(offset, force_alignment orelse alignment);
    if (size > if (comptime CallingConvention == .Windows) 8 else 16) {
        class = .mem;
    } else if (comptime CallingConvention == .Windows)
        class = .int; // Windows ABI does not use SSE for structs
    return .{
        .size = size,
        .alignment = force_alignment orelse alignment,
        .offsets = offsets,
        .class = class,
    };
}

pub const type_void = DataType{ .size = 0, .alignment = 0 };
pub const type_i8 = DataType{ .size = 1, .alignment = 1 };
pub const type_i16 = DataType{ .size = 2, .alignment = 2 };
pub const type_i32 = DataType{ .size = 4, .alignment = 4 };
pub const type_i64 = DataType{ .size = 8, .alignment = 8 };
pub const type_f32 = DataType{ .size = 4, .alignment = 4, .class = .sse };
pub const type_f64 = DataType{ .size = 8, .alignment = 8, .class = .sse };
pub const type_pointer = DataType{ .size = 8, .alignment = 8 };

pub inline fn canFitInArgRegister(class: DataType.Class, size: usize, arg_pos: usize) bool {
    if (comptime CallingConvention == .Windows)
        // Large size data passed by reference
        return arg_pos < switch (class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        }
    else
        return size <= 16 and arg_pos + @divFloor(size, 8) <= switch (class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        };
}

pub fn getArgumentStackSize(args: []const DataType, arg_pos: usize) !usize {
    var pos: usize = arg_pos;
    var float_pos: usize = 0;
    var stack: usize = 0;
    for (args) |arg| {
        const class = if (comptime CallingConvention == .Windows) .int else arg.class;
        const p = switch (class) {
            .sse => blk: {
                defer float_pos += 1;
                break :blk float_pos;
            },
            else => blk: {
                defer pos += 1;
                break :blk pos;
            },
        };
        if (canFitInArgRegister(class, arg.size, p) and stack == 0) {
            if (comptime CallingConvention != .Windows) {
                if (arg.size > 8)
                    pos += try std.math.divCeil(usize, arg.size, 8) - 1;
            }
        } else {
            stack += 1;
            if (comptime CallingConvention != .Windows) {
                // Large size data passed by reference
                if (arg.size > 8)
                    stack += try std.math.divCeil(usize, arg.size, 8) - 1;
            }
        }
    }
    return stack;
}

pub const CallFn = fn (ptr: *const anyopaque, args: ?[*]const *anyopaque, ?*anyopaque) callconv(.c) void;

fn getRegBitSize(size: usize) u8 {
    if (size >= 8)
        return 8;
    return switch (size) {
        1...2 => 2,
        3...4 => 4,
        5...7 => 8,
        else => unreachable,
    };
}

pub fn generateAsmCall(allocator: std.mem.Allocator, param_types: []const DataType, return_type: DataType) ![]align(std.heap.page_size_min) u8 {
    var code = try AssemblyBuilder.initCapacity(allocator, 64);
    defer code.deinit();
    defer if (comptime build_cfg.verbose_asm) code.print();

    const fnPtr: AssemblyBuilder.Register = CalleeSavedRegistery[0];
    const argsPtr: AssemblyBuilder.Register = CalleeSavedRegistery[2];
    const retPtr: AssemblyBuilder.Register = CalleeSavedRegistery[3];

    const use_return_address = return_type.size > (if (comptime CallingConvention == .Windows) 8 else 16);

    var arg_pos: usize = 0;
    var floating_arg_pos: usize = 0;
    var stack_offset: u32 = 0;

    // push all registers to the stack
    try code.push(fnPtr);
    if (param_types.len > 0) {
        try code.push(argsPtr);
        try code.push(.r10);
    }
    if (return_type.size > 0 and !use_return_address)
        try code.push(retPtr);

    try code.mov(.store, fnPtr, ArgumentRegistery[0], null); // mov <fnPtr>, <arg_1>
    if (param_types.len > 0) {
        try code.mov(.store, argsPtr, ArgumentRegistery[1], null); // mov <paramsPtr>, <arg_2>
    }
    if (return_type.size > 0) {
        if (use_return_address) {
            arg_pos += 1;
            try code.mov(.store, ArgumentRegistery[0], ArgumentRegistery[2], null); // mov <arg_1>, <arg_3>
        } else {
            try code.mov(.store, retPtr, ArgumentRegistery[2], null); // mov <returnPtr>, <arg_3>
        }
    }

    const stack_size = try getArgumentStackSize(param_types, arg_pos);

    const padding = (code.stack_push_offset + 8 + (8 * stack_size)) % 16;

    const allocated_stack = (8 * stack_size) + padding;

    if (allocated_stack > 0) {
        // allocate args + align the stack
        try code.imm(.sub, .rsp, @truncate(allocated_stack)); // sub rsp, <padding>
    }

    for (param_types, 0..) |param, pos| {
        std.debug.assert(param.size > 0); // void params not supported

        const bit_size: u8 = getRegBitSize(param.size);

        if (comptime CallingConvention == .Windows) if (param.size > 8) {
            if (canFitInArgRegister(param.class, param.size, arg_pos)) {
                defer arg_pos += 1;
                try code.mov(.load, ArgumentRegistery[arg_pos], argsPtr, @truncate(@as(isize, @intCast(pos * 8)))); // mov <REGISTER>, [<arg_list_reg> + <pos>]
            } else {
                defer stack_offset += 8;
                try code.mov(.load, .rax, argsPtr, @truncate(@as(isize, @intCast(pos * 8)))); // mov rax, [<arg_list_reg> + <pos>]
                const write_offset: i32 = @intCast(stack_offset);
                if (write_offset >= allocated_stack)
                    return error.StackOverflow;
                try code.mov(.store, .rsp, .rax, write_offset); // mov [rsp + <offset>], rax
            }
            continue;
        } else std.debug.assert(param.size <= 8);

        const can_fit = canFitInArgRegister(param.class, param.size, if (comptime CallingConvention == .Windows) arg_pos else switch (param.class) {
            .sse => floating_arg_pos,
            else => arg_pos,
        });

        try code.mov(.load, .rax, argsPtr, @truncate(@as(isize, @intCast(pos * 8)))); // mov rax, [<arg_list_reg> + <pos>]

        const fill = try std.math.divCeil(usize, param.size, 8);
        defer if (!can_fit) {
            stack_offset += @truncate(fill * 8);
        };
        for (0..fill) |i| {
            const offset: i32 = @intCast(i * 8); // Offset within the argument
            work: switch (param.class) {
                .int => {
                    if (!can_fit)
                        continue :work .mem;
                    defer arg_pos += 1;
                    try code.mov(.load, ArgumentRegistery[arg_pos].withBitSize(bit_size), .withBitSize(.rax, bit_size), offset); // mov <REGISTER>, [rax + <offset>]
                },
                .sse => {
                    if (!can_fit)
                        continue :work .mem;
                    if (comptime CallingConvention == .Windows) {
                        defer arg_pos += 1;
                        switch (param.size) {
                            4 => try code.movss(.load, FloatingPointRegistery[arg_pos], .withBitSize(.rax, bit_size), offset), // movss xmm, [rax + <offset>]
                            8 => try code.movsd(.load, FloatingPointRegistery[arg_pos], .withBitSize(.rax, bit_size), offset), // movsd xmm, [rax + <offset>]
                            else => unreachable, // should not happen
                        }
                        break;
                    } else {
                        defer floating_arg_pos += 1;
                        switch (param.size) {
                            4 => try code.movss(.load, FloatingPointRegistery[floating_arg_pos], .withBitSize(.rax, bit_size), offset), // movss xmm, [rax + <offset>]
                            else => try code.movsd(.load, FloatingPointRegistery[floating_arg_pos], .withBitSize(.rax, bit_size), offset), // movsd xmm, [rax + <offset>]
                        }
                    }
                },
                .mem => {
                    try code.mov(.load, .r10, .withBitSize(.rax, bit_size), offset); // mov r10, [rax + <offset>]
                    const write_offset: i32 = @as(i32, @intCast(stack_offset)) + offset;
                    if (write_offset >= allocated_stack)
                        return error.StackOverflow;
                    try code.mov(.store, .rsp, .r10, write_offset); // mov [rsp + <offset>], r10
                },
            }
        }
    }

    if (comptime CallingConvention == .Windows)
        try code.imm(.sub, .rsp, 32); // sub rsp, 32

    // call function
    try code.call(fnPtr); // call <fnPtr>

    // return value into pointer
    if (return_type.size > 0 and !use_return_address) {
        switch (return_type.class) {
            .sse => {
                if (comptime CallingConvention == .Windows) switch (return_type.size) {
                    4 => try code.movss(.store, retPtr, .xmm0, 0), // movss [<retPtr>], xmm0
                    8 => try code.movsd(.store, retPtr, .xmm0, 0), // movsd [<retPtr>], xmm0
                    else => return error.InvalidReturnType,
                } else {
                    switch (return_type.size) {
                        4 => try code.movss(.store, retPtr, .xmm0, 0), // movss [<retPtr>], xmm0
                        else => try code.movsd(.store, retPtr, .xmm0, 0), // movsd [<retPtr>], xmm0
                    }
                    if (return_type.size > 8)
                        try code.movsd(.store, retPtr, .xmm1, 0x8); // movsd [<retPtr> + 8], xmm1
                }
            },
            else => {
                try code.mov(.store, retPtr, .withBitSize(.rax, getRegBitSize(return_type.size)), 0); // mov [<retPtr>], rax
                if (comptime CallingConvention != .Windows)
                    if (return_type.size > 8) {
                        try code.mov(.store, retPtr, .rdx, 0x8); // mov [<retPtr> + 8], rdx
                    };
            },
        }
    }

    if (comptime CallingConvention == .Windows)
        try code.imm(.add, .rsp, 32); // add rsp, 32

    if (allocated_stack > 0) {
        // restore stack pointer
        try code.imm(.add, .rsp, @truncate(allocated_stack)); // add rsp, <args_size + padding>
    }

    // pop all registers, restoring registers
    if (return_type.size > 0 and !use_return_address)
        try code.pop(retPtr);
    if (param_types.len > 0) {
        try code.pop(.r10);
        try code.pop(argsPtr);
    }
    try code.pop(fnPtr);

    try code.ret();

    return try code.compile(allocator);
}
