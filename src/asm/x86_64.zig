const std = @import("std");
const builtin = @import("builtin");

const common = @import("../common.zig");

const build_config = @import("build_config");

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

pub const AssemblyBuilder = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(Instruction),
    stack_push_offset: usize = 0,

    pub const Register = enum {
        // zig fmt: off
        ax, cx, dx, bx, sp, bp, si, di,
        eax, ecx, edx, ebx, esp, ebp, esi, edi,
        rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi,
        r8, r9, r10, r11, r12, r13, r14, r15,
        xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7,
        xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,
        // 8-bit names live after xmm so ax/eax/rax enum arithmetic stays intact.
        al, cl, dl, bl, spl, bpl, sil, dil,
        r8b, r9b, r10b, r11b, r12b, r13b, r14b, r15b,
        // zig fmt: on
        SIB,

        fn isXmm(self: Register) bool {
            return switch (self) {
                .xmm0,
                .xmm1,
                .xmm2,
                .xmm3,
                .xmm4,
                .xmm5,
                .xmm6,
                .xmm7,
                .xmm8,
                .xmm9,
                .xmm10,
                .xmm11,
                .xmm12,
                .xmm13,
                .xmm14,
                .xmm15,
                => true,
                else => false,
            };
        }

        /// 0-15 for GP (rax=0 ... r15=15). Null for xmm/SIB.
        fn gpIndex(self: Register) ?u4 {
            if (self.isXmm() or self == .SIB) return null;
            const n: u4 = @truncate(self.toInt());
            return if (self.isExtendedBase()) n + 8 else n;
        }

        pub fn withBitSize(self: Register, bit_size: u8) Register {
            if (self.isXmm() or self == .SIB) return self;
            const idx = self.gpIndex().?;
            return switch (bit_size) {
                1 => if (idx < 8)
                    @fromBackingInt(@intCast(@backingInt(Register.al) + @as(usize, idx)))
                else
                    @fromBackingInt(@intCast(@backingInt(Register.r8b) + @as(usize, idx - 8))),
                // r8-r15 have no 16/32-bit aliases in this enum; keep the 64-bit name.
                2 => if (idx < 8)
                    @fromBackingInt(@intCast(@backingInt(Register.ax) + @as(usize, idx)))
                else
                    @fromBackingInt(@intCast(@backingInt(Register.r8) + @as(usize, idx - 8))),
                4 => if (idx < 8)
                    @fromBackingInt(@intCast(@backingInt(Register.eax) + @as(usize, idx)))
                else
                    @fromBackingInt(@intCast(@backingInt(Register.r8) + @as(usize, idx - 8))),
                8 => if (idx < 8)
                    @fromBackingInt(@intCast(@backingInt(Register.rax) + @as(usize, idx)))
                else
                    @fromBackingInt(@intCast(@backingInt(Register.r8) + @as(usize, idx - 8))),
                else => unreachable,
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

            try std.testing.expectEqual(.al, withBitSize(Register.rax, 1));
            try std.testing.expectEqual(.al, withBitSize(Register.eax, 1));
            try std.testing.expectEqual(.sil, withBitSize(Register.rsi, 1));
            try std.testing.expectEqual(.dil, withBitSize(Register.rdi, 1));
            try std.testing.expectEqual(.r8b, withBitSize(Register.r8, 1));
            try std.testing.expectEqual(.r11b, withBitSize(Register.r11, 1));
            try std.testing.expectEqual(.spl, withBitSize(Register.rsp, 1));
            try std.testing.expectEqual(.r15b, withBitSize(Register.r15, 1));
            try std.testing.expectEqual(.rax, withBitSize(Register.al, 8));
            try std.testing.expectEqual(.r11, withBitSize(Register.r11b, 8));
            try std.testing.expectEqual(.rsp, withBitSize(Register.spl, 8));
            try std.testing.expectEqual(.r15, withBitSize(Register.r15b, 8));
        }

        test "toInt / toOperandSize / isExtendedBase" {
            try std.testing.expectEqual(@as(u8, 0), Register.rax.toInt());
            try std.testing.expectEqual(@as(u8, 0), Register.al.toInt());
            try std.testing.expectEqual(@as(u8, 0), Register.r8.toInt());
            try std.testing.expectEqual(@as(u8, 0), Register.xmm8.toInt());
            try std.testing.expectEqual(@as(u8, 5), Register.rbp.toInt());
            try std.testing.expectEqual(@as(u5, 1), Register.sil.toOperandSize());
            try std.testing.expectEqual(@as(u5, 2), Register.ax.toOperandSize());
            try std.testing.expectEqual(@as(u5, 4), Register.eax.toOperandSize());
            try std.testing.expectEqual(@as(u5, 8), Register.r11.toOperandSize());
            try std.testing.expectEqual(@as(u5, 16), Register.xmm8.toOperandSize());
            try std.testing.expect(Register.r11.isExtendedBase());
            try std.testing.expect(Register.r8b.isExtendedBase());
            try std.testing.expect(Register.xmm8.isExtendedBase());
            try std.testing.expect(!Register.rax.isExtendedBase());
            try std.testing.expect(!Register.xmm0.isExtendedBase());
            try std.testing.expect(Register.rsp.isSIB());
            try std.testing.expect(Register.r12.isSIB());
            try std.testing.expect(!Register.rbp.isSIB());
        }

        pub inline fn toOperandSize(self: Register) u5 {
            return switch (self) {
                .al,
                .cl,
                .dl,
                .bl,
                .spl,
                .bpl,
                .sil,
                .dil,
                .r8b,
                .r9b,
                .r10b,
                .r11b,
                .r12b,
                .r13b,
                .r14b,
                .r15b,
                => 1,
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
                .al, .ax, .eax, .rax, .r8, .r8b, .xmm0, .xmm8 => return 0x00,
                .cl, .cx, .ecx, .rcx, .r9, .r9b, .xmm1, .xmm9 => return 0x01,
                .dl, .dx, .edx, .rdx, .r10, .r10b, .xmm2, .xmm10 => return 0x02,
                .bl, .bx, .ebx, .rbx, .r11, .r11b, .xmm3, .xmm11 => return 0x03,
                .spl, .sp, .esp, .rsp, .r12, .r12b, .xmm4, .xmm12 => return 0x04,
                .bpl, .bp, .ebp, .rbp, .r13, .r13b, .xmm5, .xmm13 => return 0x05,
                .sil, .si, .esi, .rsi, .r14, .r14b, .xmm6, .xmm14 => return 0x06,
                .dil, .di, .edi, .rdi, .r15, .r15b, .xmm7, .xmm15 => return 0x07,
                .SIB => return 0x04,
            };
        }

        pub inline fn isExtendedBase(self: Register) bool {
            return switch (self) {
                .r8,
                .r9,
                .r10,
                .r11,
                .r12,
                .r13,
                .r14,
                .r15,
                .r8b,
                .r9b,
                .r10b,
                .r11b,
                .r12b,
                .r13b,
                .r14b,
                .r15b,
                .xmm8,
                .xmm9,
                .xmm10,
                .xmm11,
                .xmm12,
                .xmm13,
                .xmm14,
                .xmm15,
                => true,
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
        return (@backingInt(mod) << 6) | (reg << 3) | base;
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
        /// Always the 32-bit immediate form (0x81), so a prologue `sub rsp`
        /// keeps a fixed encoding when Code patches the frame size.
        imm32: struct { RegOpcode, Register, u32 },
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
        /// `mov r64, imm64` (movabs). Needed to bake function/data addresses.
        mov_imm: struct { Register, u64 },
        /// `lea dst, [base + disp]`
        lea: struct { Register, Register, i32 },
        /// `movzx dst, r/m8|r/m16`. `src_size` is 1 or 2.
        /// `disp == null` means `base` is a register source (`mod=11`).
        movzx: struct { Register, Register, ?i32, u8 },
        /// `movsx dst, r/m8|r/m16`. `src_size` is 1 or 2.
        /// `disp == null` means `base` is a register source (`mod=11`).
        movsx: struct { Register, Register, ?i32, u8 },

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
                try writer.writeByte(ModRM(.direct, @backingInt(op), reg.toInt()));
                try writer.writeAll(&@as([4]u8, @bitCast(value)));
            } else {
                try writer.writeByte(0x83); // imm r/m64, imm8
                try writer.writeByte(ModRM(.direct, @backingInt(op), reg.toInt()));
                try writer.writeByte(@truncate(value));
            }
        }

        inline fn emitImm32(writer: *std.Io.Writer, op: RegOpcode, reg: Register, value: u32) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66);
            try writer.writeByte(RexRegisterSingle(reg));
            try writer.writeByte(0x81);
            try writer.writeByte(ModRM(.direct, @backingInt(op), reg.toInt()));
            try writer.writeAll(&@as([4]u8, @bitCast(value)));
        }

        inline fn emitCall(writer: *std.Io.Writer, reg: Register) !void {
            if (reg.toOperandSize() == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            if (reg.isExtendedBase())
                try writer.writeByte(RexRegister(.ax, reg));
            try writer.writeByte(0xFF); // call r/m64
            try writer.writeByte(ModRM(.direct, @backingInt(RegOpcode.call), reg.toInt()));
        }

        inline fn emitRet(writer: *std.Io.Writer) !void {
            try writer.writeByte(0xC3); // ret
        }

        inline fn emitMov(writer: *std.Io.Writer, kind: MovKind, r1: Register, r2: Register, disp: ?i32) !void {
            const base = if (kind == .load) r1 else r2;
            const reg = if (kind == .load) r2 else r1;
            const size = base.toOperandSize();
            if (size == 2)
                try writer.writeByte(0x66); // 16-bit operand size
            // Always emit REX so sil/dil/spl/bpl encode as the low 8 bits, not ah/ch/dh/bh.
            try writer.writeByte(RexRegister(base, reg));
            switch (kind) {
                .load => try writer.writeByte(if (size == 1) @as(u8, 0x8A) else 0x8B),
                .store => try writer.writeByte(if (size == 1) @as(u8, 0x88) else 0x89),
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

        /// ModRM + optional SIB + displacement for `[base + disp]`.
        /// `reg_field` is ModRM.reg (destination or opcode extension).
        inline fn emitMemOperand(writer: *std.Io.Writer, reg_field: u8, base: Register, disp: i32) !void {
            const mode: Mod = if (disp > std.math.maxInt(i8) or disp < std.math.minInt(i8))
                .disp32
            else if (disp != 0 or base == .r13 or base == .rbp or base == .bpl or base == .r13b)
                .disp8
            else
                .access;
            try writer.writeByte(ModRM(mode, reg_field, base.toInt()));
            if (base.isSIB())
                try writer.writeByte(SIB(0x00, 0x04, base.toInt()));
            switch (mode) {
                .disp32 => try writer.writeAll(&@as([4]u8, @bitCast(disp))),
                .disp8 => try writer.writeByte(@bitCast(@as(i8, @truncate(disp)))),
                .access => {},
                .direct => unreachable,
            }
        }

        inline fn emitMovImm(writer: *std.Io.Writer, reg: Register, value: u64) !void {
            // movabs is always 64-bit; r8-r15 need REX.B.
            const r64 = reg.withBitSize(8);
            try writer.writeByte(RexRegisterSingle(r64));
            try writer.writeByte(0xB8 | r64.toInt());
            try writer.writeAll(&@as([8]u8, @bitCast(value)));
        }

        inline fn emitLea(writer: *std.Io.Writer, dst: Register, base: Register, disp: i32) !void {
            try writer.writeByte(RexRegister(dst, base));
            try writer.writeByte(0x8D);
            try emitMemOperand(writer, dst.toInt(), base, disp);
        }

        inline fn emitMovExtend(
            writer: *std.Io.Writer,
            dst: Register,
            base: Register,
            disp: ?i32,
            src_size: u8,
            signed: bool,
        ) !void {
            std.debug.assert(src_size == 1 or src_size == 2);
            try writer.writeByte(RexRegister(dst, base));
            try writer.writeByte(0x0F);
            const opcode: u8 = if (signed)
                (if (src_size == 1) 0xBE else 0xBF)
            else
                (if (src_size == 1) 0xB6 else 0xB7);
            try writer.writeByte(opcode);
            if (disp) |d| {
                try emitMemOperand(writer, dst.toInt(), base, d);
            } else {
                try writer.writeByte(ModRM(.direct, dst.toInt(), base.toInt()));
            }
        }

        pub fn emit(self: Instruction, writer: *std.Io.Writer) !void {
            return switch (self) {
                .push => |insn| emitPush(writer, insn),
                .pop => |insn| emitPop(writer, insn),
                .imm => |insn| emitImm(writer, insn[0], insn[1], insn[2]),
                .imm32 => |insn| emitImm32(writer, insn[0], insn[1], insn[2]),
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
                .mov_imm => |insn| emitMovImm(writer, insn[0], insn[1]),
                .lea => |insn| emitLea(writer, insn[0], insn[1], insn[2]),
                .movzx => |insn| emitMovExtend(writer, insn[0], insn[1], insn[2], insn[3], false),
                .movsx => |insn| emitMovExtend(writer, insn[0], insn[1], insn[2], insn[3], true),
            };
        }

        pub fn print(self: Instruction) void {
            return switch (self) {
                .push, .pop, .call => |insn| std.debug.print("{s}: {s}\n", .{ @tagName(self), @tagName(insn) }),
                .imm, .imm32 => |insn| std.debug.print("{s}: {s}, {s} {d}\n", .{ @tagName(self), @tagName(insn[0]), @tagName(insn[1]), insn[2] }),
                .ret => std.debug.print("ret\n", .{}),
                .mov_imm => |insn| std.debug.print("mov_imm: {s}, 0x{x}\n", .{ @tagName(insn[0]), insn[1] }),
                .lea => |insn| std.debug.print("lea: {s}, [{s} + {d}]\n", .{ @tagName(insn[0]), @tagName(insn[1]), insn[2] }),
                .movzx, .movsx => |insn| {
                    if (insn[2]) |d|
                        std.debug.print("{s}: {s}, [{s} + {d}] size={d}\n", .{
                            @tagName(self), @tagName(insn[0]), @tagName(insn[1]), d, insn[3],
                        })
                    else
                        std.debug.print("{s}: {s}, {s} size={d}\n", .{
                            @tagName(self), @tagName(insn[0]), @tagName(insn[1]), insn[3],
                        });
                },
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

    pub fn imm32(self: *AssemblyBuilder, op: RegOpcode, reg: Register, value: u32) !void {
        try self.appendInsn(.{ .imm32 = .{ op, reg, value } });
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

    pub fn mov_imm(self: *AssemblyBuilder, reg: Register, value: u64) !void {
        try self.appendInsn(.{ .mov_imm = .{ reg, value } });
    }

    pub fn lea(self: *AssemblyBuilder, dst: Register, base: Register, disp: i32) !void {
        try self.appendInsn(.{ .lea = .{ dst, base, disp } });
    }

    pub fn movzx(self: *AssemblyBuilder, dst: Register, base: Register, disp: ?i32, src_size: u8) !void {
        try self.appendInsn(.{ .movzx = .{ dst, base, disp, src_size } });
    }

    pub fn movsx(self: *AssemblyBuilder, dst: Register, base: Register, disp: ?i32, src_size: u8) !void {
        try self.appendInsn(.{ .movsx = .{ dst, base, disp, src_size } });
    }

    pub fn encodedSize(self: *const AssemblyBuilder) usize {
        var scratch: [32]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&scratch);
        for (self.array.items) |insn| {
            insn.emit(&discarding.writer) catch unreachable;
        }
        return @intCast(discarding.fullCount());
    }

    pub fn encodeInto(self: *const AssemblyBuilder, buf: []u8) error{BufferTooSmall}!usize {
        var writer: std.Io.Writer = .fixed(buf);
        var last_pos: usize = 0;
        for (self.array.items) |insn| {
            insn.emit(&writer) catch return error.BufferTooSmall;
            if (comptime build_config.verbose_asm) {
                std.debug.print("{x}\n", .{writer.buffer[last_pos..writer.end]});
                last_pos = writer.end;
            }
        }
        return writer.end;
    }

    pub fn compile(self: *AssemblyBuilder, allocator: std.mem.Allocator) ![]align(16) u8 {
        const len = self.encodedSize();
        const slice = try allocator.alignedAlloc(u8, .@"16", len);
        const n = self.encodeInto(slice) catch unreachable;
        std.debug.assert(n == len);
        return slice;
    }

    pub fn deinit(self: *AssemblyBuilder) void {
        self.array.deinit(self.allocator);
    }
};

/// Merge `incoming` into one eightbyte. INTEGER wins over SSE. MEMORY wins
/// over both. `.none` is padding and does not change the slot.
fn mergeEightbyte(slot: *common.Type.Eightbyte, incoming: common.Type.Eightbyte) void {
    if (incoming == .none or incoming == slot.*) return;
    if (slot.* == .none) {
        slot.* = incoming;
        return;
    }
    if (slot.* == .mem or incoming == .mem) {
        slot.* = .mem;
        return;
    }
    slot.* = .int;
}

fn mergeRange(
    low: *common.Type.Eightbyte,
    high: *common.Type.Eightbyte,
    start: usize,
    end: usize,
    eb: common.Type.Eightbyte,
) void {
    if (eb == .none or start >= end) return;
    if (start >= 16 or end > 16) {
        low.* = .mem;
        high.* = .mem;
        return;
    }
    if (start < 8)
        mergeEightbyte(low, eb);
    if (end > 8)
        mergeEightbyte(high, eb);
}

fn fieldEightbyte(field: common.Type) common.Type.Eightbyte {
    return switch (field.class) {
        .sse => .sse,
        .mem => .mem,
        .int => .int,
    };
}

/// Classify `field` placed at `offset` into the parent's two eightbytes.
/// An aligned nested struct contributes its own pair. A scalar contributes
/// its class to every chunk its bytes overlap.
fn mergeField(
    low: *common.Type.Eightbyte,
    high: *common.Type.Eightbyte,
    field: common.Type,
    offset: usize,
) void {
    const end = offset + field.size;
    if (field.offsets != null) {
        const slots = field.eightbytes;
        if (slots.low == .none and slots.high == .none) {
            mergeRange(low, high, offset, end, fieldEightbyte(field));
            return;
        }
        const low_end = @min(end, offset + 8);
        if (slots.low != .none and offset < low_end)
            mergeRange(low, high, offset, low_end, slots.low);
        if (slots.high != .none and offset + 8 < end)
            mergeRange(low, high, offset + 8, end, slots.high);
        return;
    }
    mergeRange(low, high, offset, end, fieldEightbyte(field));
}

fn summaryClass(low: common.Type.Eightbyte, high: common.Type.Eightbyte) common.Type.Class {
    if (low == .mem or high == .mem)
        return .mem;
    const any_int = low == .int or high == .int;
    const any_sse = low == .sse or high == .sse;
    if (any_sse and !any_int)
        return .sse;
    return .int;
}

pub fn createStruct(allocator: std.mem.Allocator, fields: []const common.Type, force_alignment: ?std.mem.Alignment) !common.Type {
    if (fields.len == 0)
        return .{ .size = 0, .alignment = .@"1" };
    var offset: usize = 0;
    var alignment: std.mem.Alignment = .@"1";
    var offsets = try allocator.alloc(usize, fields.len);
    errdefer allocator.free(offsets);
    var low: common.Type.Eightbyte = .none;
    var high: common.Type.Eightbyte = .none;
    for (fields, 0..) |field, i| {
        alignment = alignment.max(field.alignment);
        offset = field.alignment.forward(offset);
        offsets[i] = offset;
        mergeField(&low, &high, field, offset);
        offset += field.size;
    }
    if (force_alignment) |forced| {
        if (forced.compare(.lt, alignment))
            return error.PoorAlignment;
    }
    const result_align = force_alignment orelse alignment;
    const size = result_align.forward(offset);
    var class: common.Type.Class = undefined;
    // Windows never passes an aggregate in XMM. SysV passes at most two
    // eightbytes in registers; anything larger is MEMORY.
    if (size > if (comptime CallingConvention == .Windows) 8 else 16) {
        class = .mem;
        low = .mem;
        high = .mem;
    } else if (comptime CallingConvention == .Windows) {
        class = .int;
        low = .int;
        high = .none;
    } else {
        if (size <= 8)
            high = .none;
        class = summaryClass(low, high);
    }
    return .{
        .size = size,
        .alignment = result_align,
        .offsets = offsets,
        .class = class,
        .eightbytes = .{
            .low = low,
            .high = high,
        },
    };
}

pub fn createArray(@"type": common.Type, amt: usize) common.Type {
    if (amt == 0)
        return .{ .size = 0, .alignment = .@"1" };
    var offset: usize = 0;
    var alignment: std.mem.Alignment = .@"1";
    var low: common.Type.Eightbyte = .none;
    var high: common.Type.Eightbyte = .none;
    for (0..amt) |_| {
        alignment = alignment.max(@"type".alignment);
        offset = @"type".alignment.forward(offset);
        mergeField(&low, &high, @"type", offset);
        offset += @"type".size;
    }
    const size = alignment.forward(offset);
    var class: common.Type.Class = undefined;
    // Windows never passes an aggregate in XMM. SysV passes at most two
    // eightbytes in registers; anything larger is MEMORY.
    if (size > if (comptime CallingConvention == .Windows) 8 else 16) {
        class = .mem;
        low = .mem;
        high = .mem;
    } else if (comptime CallingConvention == .Windows) {
        class = .int;
        low = .int;
        high = .none;
    } else {
        if (size <= 8)
            high = .none;
        class = summaryClass(low, high);
    }
    return .{
        .size = size,
        .alignment = alignment,
        .class = class,
        .eightbytes = .{
            .low = low,
            .high = high,
        },
    };
}

pub inline fn canFitInArgRegister(class: common.Type.Class, size: usize, arg_pos: usize) bool {
    if (comptime CallingConvention == .Windows)
        // Large size data passed by reference
        return arg_pos < switch (class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        }
    else
        return size <= 16 and arg_pos + (@divCeil(size, 8)) <= switch (class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        };
}

pub fn getArgumentStackSize(args: []const common.Type, arg_pos: usize) usize {
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
                    pos += @divCeil(arg.size, 8) - 1;
            }
        } else {
            stack += 1;
            if (comptime CallingConvention != .Windows) {
                // Large size data passed by reference
                if (arg.size > 8)
                    stack += @divCeil(arg.size, 8) - 1;
            }
        }
    }
    return stack;
}

fn encodeAll(code: *AssemblyBuilder) ![]u8 {
    const n = code.encodedSize();
    const buf = try std.testing.allocator.alloc(u8, n);
    errdefer std.testing.allocator.free(buf);
    const wrote = try code.encodeInto(buf);
    try std.testing.expectEqual(n, wrote);
    return buf;
}

fn expectBytes(code: *AssemblyBuilder, expected: []const u8) !void {
    const bytes = try encodeAll(code);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "AssemblyBuilder mov_imm encoding" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer code.deinit();
    try code.mov_imm(.rax, 0x1122334455667788);
    try code.mov_imm(.r11, 0x0102030405060708);
    try expectBytes(&code, &.{
        0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0x49, 0xBB, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    });
}

test "AssemblyBuilder lea encoding" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.lea(.rax, .rbp, -8);
    try code.lea(.r11, .rbp, -16);
    // disp=0 on rbp still needs a disp8: [rbp] would otherwise encode as [rip+disp32].
    try code.lea(.rcx, .rbp, 0);
    try code.lea(.rax, .rax, 0);
    try code.lea(.rax, .rbp, 256);
    // rsp is SIB-only; [rsp+8] must emit SIB with index=none.
    try code.lea(.rax, .rsp, 8);
    try expectBytes(&code, &.{
        0x48, 0x8D, 0x45, 0xF8, // lea rax, [rbp-8]
        0x4C, 0x8D, 0x5D, 0xF0, // lea r11, [rbp-16]
        0x48, 0x8D, 0x4D, 0x00, // lea rcx, [rbp+0]
        0x48, 0x8D, 0x00, // lea rax, [rax]
        0x48, 0x8D, 0x85, 0x00, 0x01, 0x00, 0x00, // lea rax, [rbp+256]
        0x48, 0x8D, 0x44, 0x24, 0x08, // lea rax, [rsp+8]
    });
}

test "AssemblyBuilder imm vs imm32" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.imm(.sub, .rsp, 8); // fits in imm8
    try code.imm(.sub, .rsp, 256); // needs imm32
    try code.imm(.add, .rsp, 32);
    try code.imm32(.sub, .rsp, 8); // still 32-bit form, so Code can patch the immediate
    try code.imm(.sub, .r11, 1);
    try expectBytes(&code, &.{
        0x48, 0x83, 0xEC, 0x08, // sub rsp, 8
        0x48, 0x81, 0xEC, 0x00, 0x01, 0x00, 0x00, // sub rsp, 256
        0x48, 0x83, 0xC4, 0x20, // add rsp, 32
        0x48, 0x81, 0xEC, 0x08, 0x00, 0x00, 0x00, // sub rsp, 8 (imm32)
        0x49, 0x83, 0xEB, 0x01, // sub r11, 1
    });
}

test "AssemblyBuilder push pop ret call" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.push(.rax);
    try code.push(.rbp);
    try code.push(.r11);
    try code.pop(.r11);
    try code.pop(.rbp);
    try code.pop(.rax);
    try code.call(.rax);
    try code.call(.r11);
    try code.ret();
    try expectBytes(&code, &.{
        0x50, // push rax
        0x55, // push rbp
        0x49, 0x53, // push r11 (REX.W+B — W is redundant on push)
        0x49, 0x5B, // pop r11
        0x5D, // pop rbp
        0x58, // pop rax
        0xFF, 0xD0, // call rax
        0x41, 0xFF, 0xD3, // call r11
        0xC3, // ret
    });
}

test "AssemblyBuilder stack_push_offset tracks push/pop" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer code.deinit();
    try std.testing.expectEqual(@as(usize, 0), code.stack_push_offset);
    try code.push(.rax);
    try std.testing.expectEqual(@as(usize, 8), code.stack_push_offset);
    try code.push(.r12);
    try std.testing.expectEqual(@as(usize, 16), code.stack_push_offset);
    try code.pop(.r12);
    try std.testing.expectEqual(@as(usize, 8), code.stack_push_offset);
    try code.pop(.rax);
    try std.testing.expectEqual(@as(usize, 0), code.stack_push_offset);
}

test "AssemblyBuilder GP mov reg-reg and memory" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 16);
    defer code.deinit();
    try code.mov(.store, .rbp, .rsp, null); // mov rbp, rsp
    try code.mov(.store, .rax, .rdi, null); // mov rax, rdi
    try code.mov(.store, .rbp, .rax, -8); // mov [rbp-8], rax
    try code.mov(.load, .rax, .rbp, -8); // mov rax, [rbp-8]
    try code.mov(.load, .rax, .rsi, 0); // mov rax, [rsi] — no disp
    // [rbp] with disp=0 still uses disp8; ModRM.rm=rbp without disp means [rip+disp32].
    try code.mov(.load, .rax, .rbp, 0);
    try code.mov(.load, .rax, .rbp, 256); // disp32
    try code.mov(.load, .rax, .rsp, 0); // SIB
    try code.mov(.load, .rax, .r12, 0); // SIB + REX.B
    try expectBytes(&code, &.{
        0x48, 0x89, 0xE5, // mov rbp, rsp
        0x48, 0x89, 0xF8, // mov rax, rdi
        0x48, 0x89, 0x45, 0xF8, // mov [rbp-8], rax
        0x48, 0x8B, 0x45, 0xF8, // mov rax, [rbp-8]
        0x48, 0x8B, 0x06, // mov rax, [rsi]
        0x48, 0x8B, 0x45, 0x00, // mov rax, [rbp+0]
        0x48, 0x8B, 0x85, 0x00, 0x01, 0x00, 0x00, // mov rax, [rbp+256]
        0x48, 0x8B, 0x04, 0x24, // mov rax, [rsp]
        0x49, 0x8B, 0x04, 0x24, // mov rax, [r12]
    });
}

test "AssemblyBuilder GP mov 8/16/32-bit" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.mov(.store, .rbp, .al, -8);
    try code.mov(.load, .al, .rbp, -8);
    try code.mov(.load, .sil, .rbp, -8); // REX required so this is sil, not dh
    try code.mov(.store, .rbp, .r8b, -8);
    try code.mov(.load, .ax, .rbp, -2);
    try code.mov(.load, .eax, .rbp, -4);
    try expectBytes(&code, &.{
        0x40, 0x88, 0x45, 0xF8, // mov [rbp-8], al
        0x40, 0x8A, 0x45, 0xF8, // mov al, [rbp-8]
        0x40, 0x8A, 0x75, 0xF8, // mov sil, [rbp-8]
        0x44, 0x88, 0x45, 0xF8, // mov [rbp-8], r8b
        0x66, 0x40, 0x8B, 0x45, 0xFE, // mov ax, [rbp-2]
        0x40, 0x8B, 0x45, 0xFC, // mov eax, [rbp-4]
    });
}

test "AssemblyBuilder movzx movsx" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.movzx(.rax, .rbp, -8, 1);
    try code.movzx(.rax, .rbp, -8, 2);
    try code.movsx(.rax, .rbp, -8, 1);
    try code.movsx(.rax, .rbp, -8, 2);
    try code.movzx(.r11, .rbp, -1, 1);
    try code.movzx(.rax, .al, null, 1);
    try code.movzx(.rdi, .al, null, 1);
    try code.movzx(.rax, .ax, null, 2);
    try code.movzx(.r11, .r11b, null, 1);
    try expectBytes(&code, &.{
        0x48, 0x0F, 0xB6, 0x45, 0xF8, // movzx rax, byte [rbp-8]
        0x48, 0x0F, 0xB7, 0x45, 0xF8, // movzx rax, word [rbp-8]
        0x48, 0x0F, 0xBE, 0x45, 0xF8, // movsx rax, byte [rbp-8]
        0x48, 0x0F, 0xBF, 0x45, 0xF8, // movsx rax, word [rbp-8]
        0x4C, 0x0F, 0xB6, 0x5D, 0xFF, // movzx r11, byte [rbp-1]
        0x48, 0x0F, 0xB6, 0xC0, // movzx rax, al
        0x48, 0x0F, 0xB6, 0xF8, // movzx rdi, al
        0x48, 0x0F, 0xB7, 0xC0, // movzx rax, ax
        0x4D, 0x0F, 0xB6, 0xDB, // movzx r11, r11b
    });
}

test "AssemblyBuilder SSE scalar movss/movsd" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.movss(.load, .xmm0, .rbp, -8);
    try code.movss(.store, .rbp, .xmm0, -8);
    try code.movsd(.load, .xmm0, .rbp, -8);
    try code.movsd(.store, .rbp, .xmm1, 8);
    try code.movss(.load, .xmm8, .rbp, -8);
    try expectBytes(&code, &.{
        0xF3, 0x0F, 0x10, 0x45, 0xF8, // movss xmm0, [rbp-8]
        0xF3, 0x0F, 0x11, 0x45, 0xF8, // movss [rbp-8], xmm0
        0xF2, 0x0F, 0x10, 0x45, 0xF8, // movsd xmm0, [rbp-8]
        0xF2, 0x0F, 0x11, 0x4D, 0x08, // movsd [rbp+8], xmm1
        0xF3, 0x44, 0x0F, 0x10, 0x45, 0xF8, // movss xmm8, [rbp-8]
    });
}

test "AssemblyBuilder SSE packed load/store" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.movaps(.load, .xmm0, .rsi, 0);
    try code.movaps(.store, .rbp, .xmm0, -16);
    try code.movapd(.load, .xmm0, .rbp, -16);
    try code.movups(.load, .xmm0, .rsi, 0);
    try code.movupd(.store, .rbp, .xmm0, -16);
    try code.movdqu(.load, .xmm0, .rbp, -16);
    try expectBytes(&code, &.{
        0x0F, 0x28, 0x06, // movaps xmm0, [rsi]
        0x0F, 0x29, 0x45, 0xF0, // movaps [rbp-16], xmm0
        0x66, 0x0F, 0x28, 0x45, 0xF0, // movapd xmm0, [rbp-16]
        0x0F, 0x10, 0x06, // movups xmm0, [rsi]
        0x66, 0x0F, 0x11, 0x45, 0xF0, // movupd [rbp-16], xmm0
        0xF3, 0x0F, 0x6F, 0x45, 0xF0, // movdqu xmm0, [rbp-16]
    });
}

test "AssemblyBuilder encodeInto exact-size buffer" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 2);
    defer code.deinit();
    try code.ret();
    var exact: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try code.encodeInto(&exact));
    try std.testing.expectEqual(@as(u8, 0xC3), exact[0]);
    var too_small: [0]u8 = .{};
    try std.testing.expectError(error.BufferTooSmall, code.encodeInto(&too_small));

    var wide = try AssemblyBuilder.initCapacity(std.testing.allocator, 1);
    defer wide.deinit();
    try wide.mov_imm(.rax, 1); // 10 bytes
    var nine: [9]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, wide.encodeInto(&nine));
}

test "AssemblyBuilder compile matches encodeInto" {
    const allocator = std.testing.allocator;
    var code = try AssemblyBuilder.initCapacity(allocator, 8);
    defer code.deinit();
    try code.push(.rbp);
    try code.mov(.store, .rbp, .rsp, null);
    try code.mov_imm(.r11, 0x1000);
    try code.call(.r11);
    try code.pop(.rbp);
    try code.ret();

    const encoded = try encodeAll(&code);
    defer allocator.free(encoded);
    const compiled = try code.compile(allocator);
    defer allocator.free(compiled);
    try std.testing.expectEqualSlices(u8, encoded, compiled);
}
