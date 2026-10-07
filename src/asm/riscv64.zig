const std = @import("std");

const common = @import("../common.zig");

const build_config = @import("build_config");

// RISC-V 64-bit uses LP64D (longs and pointers are 64-bit, double precision hardware floats)
// Integer arguments in a0-a7 (x10-x17)
pub const ArgumentRegistery = [_]AssemblyBuilder.Register{
    .a0, .a1, .a2, .a3, .a4, .a5, .a6, .a7,
};

// Floating point arguments in fa0-fa7 (f10-f17)
pub const FloatingPointRegistery = [_]AssemblyBuilder.Register{
    .fa0, .fa1, .fa2, .fa3, .fa4, .fa5, .fa6, .fa7,
};

pub const AssemblyBuilder = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(Instruction) = .empty,

    pub const Register = enum {
        // Integer registers
        zero,
        ra,
        sp,
        gp,
        tp,
        t0,
        t1,
        t2,
        s0,
        s1,
        a0,
        a1,
        a2,
        a3,
        a4,
        a5,
        a6,
        a7,
        s2,
        s3,
        s4,
        s5,
        s6,
        s7,
        s8,
        s9,
        s10,
        s11,
        t3,
        t4,
        t5,
        t6,

        // Floating point registers
        ft0,
        ft1,
        ft2,
        ft3,
        ft4,
        ft5,
        ft6,
        ft7,
        fs0,
        fs1,
        fa0,
        fa1,
        fa2,
        fa3,
        fa4,
        fa5,
        fa6,
        fa7,
        fs2,
        fs3,
        fs4,
        fs5,
        fs6,
        fs7,
        fs8,
        fs9,
        fs10,
        fs11,
        ft8,
        ft9,
        ft10,
        ft11,

        pub fn toInt(self: Register) u5 {
            return switch (self) {
                .zero => 0,
                .ra => 1,
                .sp => 2,
                .gp => 3,
                .tp => 4,
                .t0 => 5,
                .t1 => 6,
                .t2 => 7,
                .s0 => 8,
                .s1 => 9,
                .a0 => 10,
                .a1 => 11,
                .a2 => 12,
                .a3 => 13,
                .a4 => 14,
                .a5 => 15,
                .a6 => 16,
                .a7 => 17,
                .s2 => 18,
                .s3 => 19,
                .s4 => 20,
                .s5 => 21,
                .s6 => 22,
                .s7 => 23,
                .s8 => 24,
                .s9 => 25,
                .s10 => 26,
                .s11 => 27,
                .t3 => 28,
                .t4 => 29,
                .t5 => 30,
                .t6 => 31,

                .ft0 => 0,
                .ft1 => 1,
                .ft2 => 2,
                .ft3 => 3,
                .ft4 => 4,
                .ft5 => 5,
                .ft6 => 6,
                .ft7 => 7,
                .fs0 => 8,
                .fs1 => 9,
                .fa0 => 10,
                .fa1 => 11,
                .fa2 => 12,
                .fa3 => 13,
                .fa4 => 14,
                .fa5 => 15,
                .fa6 => 16,
                .fa7 => 17,
                .fs2 => 18,
                .fs3 => 19,
                .fs4 => 20,
                .fs5 => 21,
                .fs6 => 22,
                .fs7 => 23,
                .fs8 => 24,
                .fs9 => 25,
                .fs10 => 26,
                .fs11 => 27,
                .ft8 => 28,
                .ft9 => 29,
                .ft10 => 30,
                .ft11 => 31,
            };
        }

        /// Float names share encoding numbers with the integer file (`fa0` is
        /// also 10). Integer ops must reject them or `addi fa0` silently
        /// encodes as `addi a0`.
        pub fn isFloat(self: Register) bool {
            return @backingInt(self) >= @backingInt(Register.ft0);
        }
    };

    pub fn init(allocator: std.mem.Allocator, _: usize) AssemblyBuilder {
        return .{ .allocator = allocator };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !AssemblyBuilder {
        return .{
            .allocator = allocator,
            .array = try .initCapacity(allocator, num),
        };
    }

    pub fn appendInsnSlice(self: *AssemblyBuilder, insns: []const Instruction) !void {
        for (insns) |insn| try self.array.append(self.allocator, insn);
    }

    pub fn appendInsn(self: *AssemblyBuilder, insn: Instruction) !void {
        try self.array.append(self.allocator, insn);
    }

    pub fn print(self: *AssemblyBuilder) void {
        for (self.array.items) |insn| {
            insn.print();
        }
    }

    pub const Instruction = union(enum) {
        addi: struct { Register, Register, i32 },
        addiw: struct { Register, Register, i32 },
        andi: struct { Register, Register, i32 },
        ori: struct { Register, Register, i32 },
        xori: struct { Register, Register, i32 },
        add: struct { Register, Register, Register },
        sub: struct { Register, Register, Register },
        /// Shift amount is 0..63. SRAI sets funct6 so the immediate is not a plain shamt.
        slli: struct { Register, Register, u6 },
        srli: struct { Register, Register, u6 },
        srai: struct { Register, Register, u6 },
        /// `imm20` is the signed U-type field (the value `lui` places in bits 31:12).
        lui: struct { Register, i20 },
        auipc: struct { Register, i20 },
        ld: struct { Register, Register, i32 },
        sd: struct { Register, Register, i32 },
        lw: struct { Register, Register, i32 },
        sw: struct { Register, Register, i32 },
        lh: struct { Register, Register, i32 },
        sh: struct { Register, Register, i32 },
        lb: struct { Register, Register, i32 },
        sb: struct { Register, Register, i32 },
        lbu: struct { Register, Register, i32 },
        lhu: struct { Register, Register, i32 },
        lwu: struct { Register, Register, i32 },
        fld: struct { Register, Register, i32 },
        fsd: struct { Register, Register, i32 },
        flw: struct { Register, Register, i32 },
        fsw: struct { Register, Register, i32 },
        /// rs2 is hard-wired to x0 in the encoding. funct7 selects the width and direction.
        fmv_x_w: struct { Register, Register },
        fmv_w_x: struct { Register, Register },
        fmv_x_d: struct { Register, Register },
        fmv_d_x: struct { Register, Register },
        jalr: struct { Register, Register, i32 },

        pub fn emit(self: Instruction, writer: *std.Io.Writer) !void {
            switch (self) {
                .addi => |insn| try emitI(writer, 0x13, 0, insn[0], insn[1], insn[2]),
                .addiw => |insn| try emitI(writer, 0x1b, 0, insn[0], insn[1], insn[2]),
                .andi => |insn| try emitI(writer, 0x13, 7, insn[0], insn[1], insn[2]),
                .ori => |insn| try emitI(writer, 0x13, 6, insn[0], insn[1], insn[2]),
                .xori => |insn| try emitI(writer, 0x13, 4, insn[0], insn[1], insn[2]),
                .add => |insn| try emitR(writer, 0x33, 0, 0, insn[0], insn[1], insn[2]),
                .sub => |insn| try emitR(writer, 0x33, 0, 0x20, insn[0], insn[1], insn[2]),
                .slli => |insn| try emitShift(writer, 1, 0, insn[0], insn[1], insn[2]),
                .srli => |insn| try emitShift(writer, 5, 0, insn[0], insn[1], insn[2]),
                .srai => |insn| try emitShift(writer, 5, 0x10, insn[0], insn[1], insn[2]),
                .lui => |insn| try emitU(writer, 0x37, insn[0], insn[1]),
                .auipc => |insn| try emitU(writer, 0x17, insn[0], insn[1]),
                .ld => |insn| try emitI(writer, 0x03, 3, insn[0], insn[1], insn[2]),
                .sd => |insn| try emitS(writer, 0x23, 3, insn[0], insn[1], insn[2]),
                .lw => |insn| try emitI(writer, 0x03, 2, insn[0], insn[1], insn[2]),
                .sw => |insn| try emitS(writer, 0x23, 2, insn[0], insn[1], insn[2]),
                .lh => |insn| try emitI(writer, 0x03, 1, insn[0], insn[1], insn[2]),
                .sh => |insn| try emitS(writer, 0x23, 1, insn[0], insn[1], insn[2]),
                .lb => |insn| try emitI(writer, 0x03, 0, insn[0], insn[1], insn[2]),
                .sb => |insn| try emitS(writer, 0x23, 0, insn[0], insn[1], insn[2]),
                .lbu => |insn| try emitI(writer, 0x03, 4, insn[0], insn[1], insn[2]),
                .lhu => |insn| try emitI(writer, 0x03, 5, insn[0], insn[1], insn[2]),
                .lwu => |insn| try emitI(writer, 0x03, 6, insn[0], insn[1], insn[2]),
                .fld => |insn| try emitI(writer, 0x07, 3, insn[0], insn[1], insn[2]),
                .fsd => |insn| try emitS(writer, 0x27, 3, insn[0], insn[1], insn[2]),
                .flw => |insn| try emitI(writer, 0x07, 2, insn[0], insn[1], insn[2]),
                .fsw => |insn| try emitS(writer, 0x27, 2, insn[0], insn[1], insn[2]),
                // funct7: FMV.X.W 0x70, FMV.W.X 0x78, FMV.X.D 0x71, FMV.D.X 0x79. rs2 is x0.
                .fmv_x_w => |insn| try emitR(writer, 0x53, 0, 0x70, insn[0], insn[1], .zero),
                .fmv_w_x => |insn| try emitR(writer, 0x53, 0, 0x78, insn[0], insn[1], .zero),
                .fmv_x_d => |insn| try emitR(writer, 0x53, 0, 0x71, insn[0], insn[1], .zero),
                .fmv_d_x => |insn| try emitR(writer, 0x53, 0, 0x79, insn[0], insn[1], .zero),
                .jalr => |insn| try emitI(writer, 0x67, 0, insn[0], insn[1], insn[2]),
            }
        }

        /// RISC-V parcels are little-endian even when this file is compiled for another host.
        const code_endian = std.builtin.Endian.little;

        inline fn emitR(writer: *std.Io.Writer, opcode: u7, funct3: u3, funct7: u7, rd: Register, rs1: Register, rs2: Register) !void {
            var instr: u32 = opcode;
            instr |= @as(u32, rd.toInt()) << 7;
            instr |= @as(u32, funct3) << 12;
            instr |= @as(u32, rs1.toInt()) << 15;
            instr |= @as(u32, rs2.toInt()) << 20;
            instr |= @as(u32, funct7) << 25;
            try writer.writeInt(u32, instr, code_endian);
        }

        inline fn emitI(writer: *std.Io.Writer, opcode: u7, funct3: u3, rd: Register, rs1: Register, imm: i32) !void {
            if (imm < -2048 or imm > 2047) return error.OffsetOutOfRange;
            var instr: u32 = opcode;
            instr |= @as(u32, rd.toInt()) << 7;
            instr |= @as(u32, funct3) << 12;
            instr |= @as(u32, rs1.toInt()) << 15;
            const imm12: u12 = @truncate(@as(u32, @bitCast(imm)));
            instr |= @as(u32, imm12) << 20;
            try writer.writeInt(u32, instr, code_endian);
        }

        /// RV64 shift immediates are a 6-bit shamt plus a funct6 in the same I-type slot.
        /// SRAI's funct6 is `0x10`, which sets bit 30.
        inline fn emitShift(writer: *std.Io.Writer, funct3: u3, funct6: u6, rd: Register, rs1: Register, shamt: u6) !void {
            const imm: i32 = (@as(i32, funct6) << 6) | @as(i32, shamt);
            try emitI(writer, 0x13, funct3, rd, rs1, imm);
        }

        inline fn emitU(writer: *std.Io.Writer, opcode: u7, rd: Register, imm20: i20) !void {
            var instr: u32 = opcode;
            instr |= @as(u32, rd.toInt()) << 7;
            const bits: u20 = @bitCast(imm20);
            instr |= @as(u32, bits) << 12;
            try writer.writeInt(u32, instr, code_endian);
        }

        inline fn emitS(writer: *std.Io.Writer, opcode: u7, funct3: u3, rs2: Register, rs1: Register, imm: i32) !void {
            if (imm < -2048 or imm > 2047) return error.OffsetOutOfRange;
            var instr: u32 = opcode;
            const imm12: u12 = @truncate(@as(u32, @bitCast(imm)));
            // S-type splits the 12-bit immediate into bits [11:7] and [31:25].
            const imm5 = imm12 & 0x1F;
            const imm7 = (imm12 >> 5) & 0x7F;
            instr |= @as(u32, imm5) << 7;
            instr |= @as(u32, funct3) << 12;
            instr |= @as(u32, rs1.toInt()) << 15;
            instr |= @as(u32, rs2.toInt()) << 20;
            instr |= @as(u32, imm7) << 25;
            try writer.writeInt(u32, instr, code_endian);
        }

        pub fn print(self: Instruction) void {
            switch (self) {
                inline .addi, .addiw, .andi, .ori, .xori => |insn| {
                    std.debug.print("{s} {s}, {s}, {}\n", .{ @tagName(self), @tagName(insn[0]), @tagName(insn[1]), insn[2] });
                },
                inline .add, .sub => |insn| {
                    std.debug.print("{s} {s}, {s}, {s}\n", .{ @tagName(self), @tagName(insn[0]), @tagName(insn[1]), @tagName(insn[2]) });
                },
                inline .slli, .srli, .srai => |insn| {
                    std.debug.print("{s} {s}, {s}, {}\n", .{ @tagName(self), @tagName(insn[0]), @tagName(insn[1]), insn[2] });
                },
                inline .lui, .auipc => |insn| {
                    std.debug.print("{s} {s}, {}\n", .{ @tagName(self), @tagName(insn[0]), insn[1] });
                },
                inline .ld, .lw, .lh, .lb, .lbu, .lhu, .lwu, .fld, .flw => |insn| {
                    std.debug.print("{s} {s}, {}({s})\n", .{ @tagName(self), @tagName(insn[0]), insn[2], @tagName(insn[1]) });
                },
                inline .sd, .sw, .sh, .sb, .fsd, .fsw => |insn| {
                    std.debug.print("{s} {s}, {}({s})\n", .{ @tagName(self), @tagName(insn[0]), insn[2], @tagName(insn[1]) });
                },
                inline .fmv_x_w, .fmv_w_x, .fmv_x_d, .fmv_d_x => |insn| {
                    std.debug.print("{s} {s}, {s}\n", .{ @tagName(self), @tagName(insn[0]), @tagName(insn[1]) });
                },
                .jalr => |insn| std.debug.print("jalr {s}, {}({s})\n", .{ @tagName(insn[0]), insn[2], @tagName(insn[1]) }),
            }
        }
    };

    fn requireGp(reg: Register) error{NotIntegerRegister}!void {
        if (reg.isFloat()) return error.NotIntegerRegister;
    }

    fn requireFp(reg: Register) error{NotFloatRegister}!void {
        if (!reg.isFloat()) return error.NotFloatRegister;
    }

    fn checkImm12(imm: i32) error{OffsetOutOfRange}!void {
        if (imm < -2048 or imm > 2047) return error.OffsetOutOfRange;
    }

    pub fn addi(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .addi = .{ rd, rs1, imm } });
    }

    pub fn addiw(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .addiw = .{ rd, rs1, imm } });
    }

    pub fn andi(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .andi = .{ rd, rs1, imm } });
    }

    pub fn ori(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .ori = .{ rd, rs1, imm } });
    }

    pub fn xori(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .xori = .{ rd, rs1, imm } });
    }

    pub fn add(self: *AssemblyBuilder, rd: Register, rs1: Register, rs2: Register) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try requireGp(rs2);
        try self.appendInsn(.{ .add = .{ rd, rs1, rs2 } });
    }

    pub fn sub(self: *AssemblyBuilder, rd: Register, rs1: Register, rs2: Register) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try requireGp(rs2);
        try self.appendInsn(.{ .sub = .{ rd, rs1, rs2 } });
    }

    pub fn slli(self: *AssemblyBuilder, rd: Register, rs1: Register, shamt: u6) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try self.appendInsn(.{ .slli = .{ rd, rs1, shamt } });
    }

    pub fn srli(self: *AssemblyBuilder, rd: Register, rs1: Register, shamt: u6) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try self.appendInsn(.{ .srli = .{ rd, rs1, shamt } });
    }

    pub fn srai(self: *AssemblyBuilder, rd: Register, rs1: Register, shamt: u6) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try self.appendInsn(.{ .srai = .{ rd, rs1, shamt } });
    }

    pub fn lui(self: *AssemblyBuilder, rd: Register, imm20: i20) !void {
        try requireGp(rd);
        try self.appendInsn(.{ .lui = .{ rd, imm20 } });
    }

    pub fn auipc(self: *AssemblyBuilder, rd: Register, imm20: i20) !void {
        try requireGp(rd);
        try self.appendInsn(.{ .auipc = .{ rd, imm20 } });
    }

    pub fn mv(self: *AssemblyBuilder, rd: Register, rs1: Register) !void {
        try self.addi(rd, rs1, 0);
    }

    pub fn ld(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .ld = .{ rd, rs1, imm } });
    }

    pub fn sd(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireGp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .sd = .{ rs2, rs1, imm } });
    }

    pub fn lw(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lw = .{ rd, rs1, imm } });
    }

    pub fn sw(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireGp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .sw = .{ rs2, rs1, imm } });
    }

    pub fn lh(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lh = .{ rd, rs1, imm } });
    }

    pub fn sh(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireGp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .sh = .{ rs2, rs1, imm } });
    }

    pub fn lb(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lb = .{ rd, rs1, imm } });
    }

    pub fn sb(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireGp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .sb = .{ rs2, rs1, imm } });
    }

    pub fn lbu(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lbu = .{ rd, rs1, imm } });
    }

    pub fn lhu(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lhu = .{ rd, rs1, imm } });
    }

    pub fn lwu(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .lwu = .{ rd, rs1, imm } });
    }

    pub fn fld(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireFp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .fld = .{ rd, rs1, imm } });
    }

    pub fn fsd(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireFp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .fsd = .{ rs2, rs1, imm } });
    }

    pub fn flw(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireFp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .flw = .{ rd, rs1, imm } });
    }

    pub fn fsw(self: *AssemblyBuilder, rs2: Register, rs1: Register, imm: i32) !void {
        try requireFp(rs2);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .fsw = .{ rs2, rs1, imm } });
    }

    pub fn fmv_x_w(self: *AssemblyBuilder, rd: Register, rs1: Register) !void {
        try requireGp(rd);
        try requireFp(rs1);
        try self.appendInsn(.{ .fmv_x_w = .{ rd, rs1 } });
    }

    pub fn fmv_w_x(self: *AssemblyBuilder, rd: Register, rs1: Register) !void {
        try requireFp(rd);
        try requireGp(rs1);
        try self.appendInsn(.{ .fmv_w_x = .{ rd, rs1 } });
    }

    pub fn fmv_x_d(self: *AssemblyBuilder, rd: Register, rs1: Register) !void {
        try requireGp(rd);
        try requireFp(rs1);
        try self.appendInsn(.{ .fmv_x_d = .{ rd, rs1 } });
    }

    pub fn fmv_d_x(self: *AssemblyBuilder, rd: Register, rs1: Register) !void {
        try requireFp(rd);
        try requireGp(rs1);
        try self.appendInsn(.{ .fmv_d_x = .{ rd, rs1 } });
    }

    pub fn jalr(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i32) !void {
        try requireGp(rd);
        try requireGp(rs1);
        try checkImm12(imm);
        try self.appendInsn(.{ .jalr = .{ rd, rs1, imm } });
    }

    pub fn ret(self: *AssemblyBuilder) !void {
        try self.jalr(.zero, .ra, 0);
    }

    /// `rd = imm`. Any 64-bit value. The sequence is uncompressed RV64I
    /// (`lui` / `addi` / `addiw` / `slli`), at most eight instructions.
    ///
    /// Constants wider than 32 bits are split from the low bits upward.
    /// `addi` sign-extends its immediate, so using all 12 bits only stays
    /// correct when the low chunk is applied after the high bits are in place.
    /// `addiw` is required when `lui`'s sign-extended 32-bit result plus the
    /// low 12 bits leaves the signed-32 range (`0x7fffffff` is the usual case).
    pub fn li(self: *AssemblyBuilder, rd: Register, value: u64) !void {
        try requireGp(rd);
        var ops: [8]LiOp = undefined;
        const seq = try liSeq(@bitCast(value), &ops);
        for (seq, 0..) |op, i| {
            const rs1: Register = if (i == 0) .zero else rd;
            switch (op) {
                .lui => |imm| try self.lui(rd, imm),
                .addi => |imm| try self.addi(rd, rs1, imm),
                .addiw => |imm| try self.addiw(rd, rs1, imm),
                .slli => |shamt| try self.slli(rd, rs1, shamt),
            }
        }
    }

    /// `rd = rs1 + imm`. One `addi` when `imm` fits in 12 bits.
    /// A wider immediate is materialized in `rd` when `rd != rs1`.
    /// An in-place add (`rd == rs1`, the `sp` adjustment case) uses `tmp`,
    /// which must be a different integer register.
    pub fn addImm(self: *AssemblyBuilder, rd: Register, rs1: Register, imm: i64, tmp: Register) !void {
        try requireGp(rd);
        try requireGp(rs1);
        if (fitsI(12, imm)) {
            try self.addi(rd, rs1, @intCast(imm));
            return;
        }
        if (rd != rs1) {
            try self.li(rd, @bitCast(imm));
            try self.add(rd, rs1, rd);
            return;
        }
        try requireGp(tmp);
        if (tmp == rd or tmp == .zero) return error.BadScratch;
        try self.li(tmp, @bitCast(imm));
        try self.add(rd, rs1, tmp);
    }

    /// Uncompressed parcels only. `li` / `addImm` append one entry per real instruction.
    pub fn encodedSize(self: *const AssemblyBuilder) usize {
        return self.array.items.len * 4;
    }

    pub fn encodeInto(self: *const AssemblyBuilder, buf: []u8) error{ BufferTooSmall, OffsetOutOfRange }!usize {
        var writer: std.Io.Writer = .fixed(buf);
        var last_pos: usize = 0;
        for (self.array.items) |insn| {
            insn.emit(&writer) catch |err| switch (err) {
                error.OffsetOutOfRange => return error.OffsetOutOfRange,
                else => return error.BufferTooSmall,
            };
            if (comptime build_config.verbose_asm) {
                std.debug.print("{x}\n", .{writer.buffer[last_pos..writer.end]});
                last_pos = writer.end;
            }
        }
        return writer.end;
    }

    pub fn compile(self: *AssemblyBuilder, allocator: std.mem.Allocator) ![]align(std.heap.page_size_min) u8 {
        const len = self.encodedSize();
        const slice = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), len);
        errdefer allocator.free(slice);
        const n = try self.encodeInto(slice);
        std.debug.assert(n == len);
        return slice;
    }

    pub fn deinit(self: *AssemblyBuilder) void {
        self.array.deinit(self.allocator);
    }
};

const LiOp = union(enum) {
    lui: i20,
    addi: i32,
    addiw: i32,
    slli: u6,
};

fn fitsI(comptime bits: u7, value: i64) bool {
    const shift: u6 = @intCast(bits - 1);
    const min = -(@as(i64, 1) << shift);
    const max = (@as(i64, 1) << shift) - 1;
    return value >= min and value <= max;
}

fn sext12(value: i64) i64 {
    const lo: i12 = @truncate(value);
    return lo;
}

fn appendLi(ops: *[8]LiOp, n: *usize, op: LiOp) error{ImmediateTooWide}!void {
    if (n.* == ops.len) return error.ImmediateTooWide;
    ops[n.*] = op;
    n.* += 1;
}

/// LSB-first split, instructions emitted high part first via recursion.
/// Worst case observed for RV64I is eight parcels (LUI+ADDIW plus three SLLI+ADDI pairs).
fn liSeq(val: i64, ops: *[8]LiOp) error{ImmediateTooWide}![]LiOp {
    var n: usize = 0;
    try liSeqRec(val, ops, &n);
    return ops[0..n];
}

fn liSeqRec(val: i64, ops: *[8]LiOp, n: *usize) error{ImmediateTooWide}!void {
    if (fitsI(32, val)) {
        const summed = val + 0x800;
        const shifted: i64 = summed >> 12;
        const hi20: u64 = @as(u64, @bitCast(shifted)) & 0xFFFFF;
        const hi_s: i64 = if (hi20 >= 0x80000) @as(i64, @intCast(hi20)) - 0x100000 else @as(i64, @intCast(hi20));
        const lo: i64 = sext12(val);
        if (hi_s != 0)
            try appendLi(ops, n, .{ .lui = @intCast(hi_s) });
        if (lo != 0 or hi_s == 0) {
            const hi_u: u32 = @intCast(hi20);
            const lui_bits: u32 = hi_u << 12;
            const lui64: i64 = @as(i32, @bitCast(lui_bits));
            // `lui` sign-extends from bit 31. Adding `lo` in the full register
            // is wrong when that sum is outside i32; `addiw` wraps the low 32
            // and sign-extends again.
            const use_w = hi_s != 0 and !fitsI(32, lui64 + lo);
            if (use_w)
                try appendLi(ops, n, .{ .addiw = @intCast(lo) })
            else
                try appendLi(ops, n, .{ .addi = @intCast(lo) });
        }
        return;
    }

    const lo: i64 = sext12(val);
    var rest_u: u64 = @as(u64, @bitCast(val)) -% @as(u64, @bitCast(lo));
    var rest: i64 = @bitCast(rest_u);
    var shift: u6 = 0;
    if (!fitsI(32, rest)) {
        const tz_raw = @ctz(rest_u);
        std.debug.assert(tz_raw < 64);
        const tz: u6 = @intCast(tz_raw);
        rest_u >>= tz;
        rest = @bitCast(rest_u);
        shift = tz;
        // Pull 12 zero bits back into the shifted value when that lets the
        // recursive step use `lui` (which zeros bits 11:0) instead of a longer
        // sequence. Refuse the shift when it would drop high bits.
        if (shift > 12 and !fitsI(12, rest) and rest_u <= (std.math.maxInt(u64) >> 12)) {
            const widened = rest_u << 12;
            const widened_s: i64 = @bitCast(widened);
            if (fitsI(32, widened_s)) {
                shift -= 12;
                rest_u = widened;
                rest = widened_s;
            }
        }
    }

    try liSeqRec(rest, ops, n);
    if (shift != 0)
        try appendLi(ops, n, .{ .slli = shift });
    if (lo != 0)
        try appendLi(ops, n, .{ .addi = @intCast(lo) });
}

const Aggregate = struct {
    cursor: usize,
    alignment: std.mem.Alignment,
    class: common.Type.Class,
    eightbytes: common.Type.Eightbytes = .{},
    /// True when `size / field_count` is the wrong width. `{f32,f64}` is 16
    /// bytes and two fields, but the first field is 4, not 8.
    record_sizes: bool = false,
};

/// A hardware FP real. A nested aggregate has offsets, so it stays one member
/// even when its own class is `.sse`. `[2]f32` fails `size == alignment`.
fn isFpScalar(ty: common.Type) bool {
    if (ty.offsets != null or ty.class != .sse) return false;
    const step = ty.alignment.toByteUnits();
    return step == ty.size and (ty.size == 4 or ty.size == 8);
}

/// An integer or pointer real. Aggregates have offsets and are not flattened.
fn isIntScalar(ty: common.Type) bool {
    if (ty.offsets != null or ty.class != .int) return false;
    const step = ty.alignment.toByteUnits();
    return ty.size > 0 and ty.size <= 8 and step == ty.size;
}

fn layoutFields(fields: []const common.Type, offsets: ?[]usize) Aggregate {
    var cursor: usize = 0;
    var alignment: std.mem.Alignment = .@"1";
    var uniform = fields.len > 0;
    const elem_size = if (fields.len > 0) fields[0].size else 0;
    const elem_class: common.Type.Class = if (fields.len > 0) fields[0].class else .int;
    for (fields, 0..) |field, i| {
        alignment = alignment.max(field.alignment);
        cursor = field.alignment.forward(cursor);
        if (offsets) |buf| buf[i] = cursor;
        cursor += field.size;
        if (field.class != elem_class or field.size != elem_size) uniform = false;
    }
    // LP64D: one or two FP reals, sizes may differ, go in fa registers.
    // A nested aggregate counts as one member and is not flattened.
    if (fields.len == 2 and isFpScalar(fields[0]) and isFpScalar(fields[1])) {
        const padded = cursor != fields[0].size + fields[1].size;
        return .{
            .cursor = cursor,
            .alignment = alignment,
            .class = .sse,
            .record_sizes = fields[0].size != fields[1].size or padded,
        };
    }
    // One float and one integer, either order. Class stays `.int` so a
    // caller that only looks at `class` still sees a non-HFA. The eightbyte
    // slots are the member classes, which the lowerer uses to pick fa+a.
    if (fields.len == 2) {
        const float_then_int = isFpScalar(fields[0]) and isIntScalar(fields[1]);
        const int_then_float = isIntScalar(fields[0]) and isFpScalar(fields[1]);
        if (float_then_int or int_then_float) {
            return .{
                .cursor = cursor,
                .alignment = alignment,
                .class = .int,
                .record_sizes = true,
                .eightbytes = .{
                    .low = if (isFpScalar(fields[0])) .sse else .int,
                    .high = if (isFpScalar(fields[1])) .sse else .int,
                },
            };
        }
    }
    const hfa = uniform and fields.len >= 1 and fields.len <= 2 and elem_class == .sse;
    return .{
        .cursor = cursor,
        .alignment = alignment,
        .class = if (hfa) .sse else .int,
    };
}

pub fn createStruct(allocator: std.mem.Allocator, fields: []const common.Type, force_alignment: ?std.mem.Alignment) !common.Type {
    if (fields.len == 0)
        return .{ .size = 0, .alignment = .@"1" };
    const offsets = try allocator.alloc(usize, fields.len);
    errdefer allocator.free(offsets);
    const layout = layoutFields(fields, offsets);
    if (force_alignment) |forced| {
        if (forced.compare(.lt, layout.alignment))
            return error.PoorAlignment;
    }
    const result_align = force_alignment orelse layout.alignment;
    const size = result_align.forward(layout.cursor);
    // Larger than two XLEN words: the pointer is passed, not the bytes.
    // FPCC field sizes are meaningless once the argument is a pointer.
    const by_ref = size > 16;
    const field_sizes: ?[]const usize = if (!by_ref and layout.record_sizes) blk: {
        const sizes = try allocator.alloc(usize, fields.len);
        for (fields, 0..) |field, i| sizes[i] = field.size;
        break :blk sizes;
    } else null;
    return .{
        .size = size,
        .alignment = result_align,
        .offsets = offsets,
        .field_sizes = field_sizes,
        .class = if (by_ref) .mem else layout.class,
        .eightbytes = if (by_ref) .{} else layout.eightbytes,
    };
}

/// No offset table: `Type.array` has no allocator. `hfaFieldCount` recovers
/// the FP count as size/alignment, which is 1 for a scalar and 2 for `[2]f32`.
/// A ratio above 2 is integer (or memory, once the bytes exceed 16).
pub fn createArray(@"type": common.Type, amt: usize) common.Type {
    if (amt == 0)
        return .{ .size = 0, .alignment = .@"1" };
    var cursor: usize = 0;
    var alignment: std.mem.Alignment = .@"1";
    for (0..amt) |_| {
        alignment = alignment.max(@"type".alignment);
        cursor = @"type".alignment.forward(cursor);
        cursor += @"type".size;
    }
    const size = alignment.forward(cursor);
    const step = alignment.toByteUnits();
    const ratio = if (step != 0 and size % step == 0) size / step else 0;
    const hfa = @"type".class == .sse and ratio >= 1 and ratio <= 2;
    return .{
        .size = size,
        .alignment = alignment,
        .class = if (size > 16) .mem else if (hfa) .sse else .int,
    };
}

/// FP registers an `.sse` value needs. Structs store one offset per member.
/// Arrays do not, so a scalar (size == alignment) is one register and `[2]f32`
/// is two. A ratio above 2 has already been classed `.int` or `.mem`.
pub fn hfaFieldCount(ty: common.Type) usize {
    if (ty.offsets) |offs| {
        if (offs.len > 0) return offs.len;
    }
    const step = ty.alignment.toByteUnits();
    if (ty.class == .sse and step != 0 and ty.size % step == 0) {
        const n = ty.size / step;
        if (n >= 1 and n <= 2) return n;
    }
    return 1;
}

pub fn hfaFieldOffset(ty: common.Type, index: usize, elem_size: usize) usize {
    if (ty.offsets) |offs| return offs[index];
    return index * elem_size;
}

pub inline fn canFitInArgRegister(class: common.Type.Class, size: usize, arg_pos: usize) bool {
    // Limits live in src/code/riscv64.zig. Callers that still branch on this
    // enter the marshaller, which applies the real register file.
    _ = class;
    _ = size;
    _ = arg_pos;
    return true;
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

/// Run an `li` sequence. Every parcel writes `rd`, and reads either x0 or `rd`.
fn execLi(bytes: []const u8, rd_expect: u5) !u64 {
    var reg: u64 = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) {
        const insn = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        const opcode: u32 = insn & 0x7f;
        const rd: u5 = @intCast((insn >> 7) & 0x1f);
        const funct3: u32 = (insn >> 12) & 0x7;
        const rs1: u5 = @intCast((insn >> 15) & 0x1f);
        const imm12: i64 = @as(i12, @bitCast(@as(u12, @truncate(insn >> 20))));
        if (rd != rd_expect) return error.BadRd;
        // U-type (`lui`) has no rs1; bits [19:15] belong to the immediate.
        if (opcode != 0x37 and rs1 != 0 and rs1 != rd_expect) return error.BadRs1;
        const src: u64 = if (rs1 == 0) 0 else reg;
        switch (opcode) {
            0x37 => {
                const low: u32 = insn & 0xFFFFF000;
                reg = @bitCast(@as(i64, @as(i32, @bitCast(low))));
            },
            0x13 => switch (funct3) {
                0 => reg = @bitCast(@as(i64, @bitCast(src)) +% imm12),
                1 => reg = src << @as(u6, @intCast(imm12)),
                else => return error.UnexpectedOp,
            },
            0x1b => {
                const src32: i32 = @bitCast(@as(u32, @truncate(src)));
                const sum: i32 = src32 +% @as(i32, @intCast(imm12));
                reg = @bitCast(@as(i64, sum));
            },
            else => return error.UnexpectedOp,
        }
    }
    return reg;
}

fn expectLi(value: u64) !void {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.li(.a0, value);
    try std.testing.expect(code.encodedSize() >= 4 and code.encodedSize() <= 32);
    const bytes = try encodeAll(&code);
    defer std.testing.allocator.free(bytes);
    const got = execLi(bytes, 10) catch |err| {
        std.debug.print("li 0x{x} -> {x}\n", .{ value, bytes });
        return err;
    };
    if (got != value) {
        std.debug.print("li 0x{x} produced 0x{x} from {x}\n", .{ value, got, bytes });
        return error.WrongImmediate;
    }
}

test "riscv64 AssemblyBuilder integer and branch encodings" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 16);
    defer code.deinit();
    try code.addi(.sp, .sp, -16);
    try code.mv(.a0, .a1);
    try code.add(.a0, .a0, .a1);
    try code.sub(.a0, .a1, .a2);
    try code.jalr(.ra, .a0, 0);
    try code.ret();
    try code.andi(.a0, .a0, 0xff);
    try code.ori(.a0, .a0, 1);
    try code.xori(.a0, .a0, -1);
    try code.addiw(.a0, .a0, 0);
    try code.addiw(.a0, .a0, -1);
    try expectBytes(&code, &.{
        0x13, 0x01, 0x01, 0xff, // addi sp, sp, -16
        0x13, 0x85, 0x05, 0x00, // mv a0, a1
        0x33, 0x05, 0xb5, 0x00, // add a0, a0, a1
        0x33, 0x85, 0xc5, 0x40, // sub a0, a1, a2
        0xe7, 0x00, 0x05, 0x00, // jalr ra, a0, 0
        0x67, 0x80, 0x00, 0x00, // ret
        0x13, 0x75, 0xf5, 0x0f, // andi a0, a0, 255
        0x13, 0x65, 0x15, 0x00, // ori a0, a0, 1
        0x13, 0x45, 0xf5, 0xff, // xori a0, a0, -1
        0x1b, 0x05, 0x05, 0x00, // addiw a0, a0, 0
        0x1b, 0x05, 0xf5, 0xff, // addiw a0, a0, -1
    });
}

test "riscv64 AssemblyBuilder shifts lui auipc" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.slli(.a0, .a0, 1);
    try code.srli(.a0, .a0, 1);
    try code.srai(.a0, .a0, 1);
    try code.slli(.a0, .a0, 63);
    try code.lui(.a0, 1);
    try code.lui(.a0, -1);
    try code.auipc(.a0, 0);
    try expectBytes(&code, &.{
        0x13, 0x15, 0x15, 0x00, // slli a0, a0, 1
        0x13, 0x55, 0x15, 0x00, // srli a0, a0, 1
        0x13, 0x55, 0x15, 0x40, // srai a0, a0, 1
        0x13, 0x15, 0xf5, 0x03, // slli a0, a0, 63
        0x37, 0x15, 0x00, 0x00, // lui a0, 1
        0x37, 0xf5, 0xff, 0xff, // lui a0, -1
        0x17, 0x05, 0x00, 0x00, // auipc a0, 0
    });
}

test "riscv64 AssemblyBuilder loads and stores" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 24);
    defer code.deinit();
    try code.ld(.a0, .sp, 8);
    try code.sd(.ra, .sp, 8);
    try code.sd(.ra, .sp, -8);
    try code.ld(.a0, .sp, 2047);
    try code.ld(.a0, .sp, -2048);
    try code.lw(.a0, .a1, 0);
    try code.sw(.a0, .sp, 4);
    try code.lh(.a0, .a1, 2);
    try code.sh(.a0, .sp, 2);
    try code.lb(.a0, .a1, 1);
    try code.sb(.a0, .sp, 1);
    try code.sb(.a0, .sp, -1);
    try code.lbu(.a0, .a1, 0);
    try code.lhu(.a0, .a1, 0);
    try code.lwu(.a0, .a1, 0);
    try code.lbu(.a0, .a1, -1);
    try expectBytes(&code, &.{
        0x03, 0x35, 0x81, 0x00, // ld a0, 8(sp)
        0x23, 0x34, 0x11, 0x00, // sd ra, 8(sp)
        0x23, 0x3c, 0x11, 0xfe, // sd ra, -8(sp)
        0x03, 0x35, 0xf1, 0x7f, // ld a0, 2047(sp)
        0x03, 0x35, 0x01, 0x80, // ld a0, -2048(sp)
        0x03, 0xa5, 0x05, 0x00, // lw a0, 0(a1)
        0x23, 0x22, 0xa1, 0x00, // sw a0, 4(sp)
        0x03, 0x95, 0x25, 0x00, // lh a0, 2(a1)
        0x23, 0x11, 0xa1, 0x00, // sh a0, 2(sp)
        0x03, 0x85, 0x15, 0x00, // lb a0, 1(a1)
        0xa3, 0x00, 0xa1, 0x00, // sb a0, 1(sp)
        0xa3, 0x0f, 0xa1, 0xfe, // sb a0, -1(sp)
        0x03, 0xc5, 0x05, 0x00, // lbu a0, 0(a1)
        0x03, 0xd5, 0x05, 0x00, // lhu a0, 0(a1)
        0x03, 0xe5, 0x05, 0x00, // lwu a0, 0(a1)
        0x03, 0xc5, 0xf5, 0xff, // lbu a0, -1(a1)
    });
}

test "riscv64 AssemblyBuilder float encodings" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 16);
    defer code.deinit();
    try code.flw(.fa0, .a0, 0);
    try code.fsw(.fa0, .a0, 0);
    try code.fld(.fa0, .a0, 8);
    try code.fsd(.fa0, .a0, 8);
    try code.flw(.ft0, .sp, -4);
    try code.fsw(.fs0, .s1, 12);
    try code.fmv_x_w(.a0, .fa0);
    try code.fmv_w_x(.fa0, .a0);
    try code.fmv_x_d(.a0, .fa0);
    try code.fmv_d_x(.fa0, .a0);
    try code.fmv_x_d(.t0, .ft0);
    try code.fmv_d_x(.ft11, .t6);
    try expectBytes(&code, &.{
        0x07, 0x25, 0x05, 0x00, // flw fa0, 0(a0)
        0x27, 0x20, 0xa5, 0x00, // fsw fa0, 0(a0)
        0x07, 0x35, 0x85, 0x00, // fld fa0, 8(a0)
        0x27, 0x34, 0xa5, 0x00, // fsd fa0, 8(a0)
        0x07, 0x20, 0xc1, 0xff, // flw ft0, -4(sp)
        0x27, 0xa6, 0x84, 0x00, // fsw fs0, 12(s1)
        0x53, 0x05, 0x05, 0xe0, // fmv.x.w a0, fa0
        0x53, 0x05, 0x05, 0xf0, // fmv.w.x fa0, a0
        0x53, 0x05, 0x05, 0xe2, // fmv.x.d a0, fa0
        0x53, 0x05, 0x05, 0xf2, // fmv.d.x fa0, a0
        0xd3, 0x02, 0x00, 0xe2, // fmv.x.d t0, ft0
        0xd3, 0x8f, 0x0f, 0xf2, // fmv.d.x ft11, t6
    });
}

test "riscv64 AssemblyBuilder li encodings" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.li(.a0, 0);
    try code.li(.a0, @bitCast(@as(i64, -1)));
    try code.li(.a0, @bitCast(@as(i64, -4096)));
    try code.li(.a0, 0x7fffffff);
    try code.li(.a0, 0x80000000);
    try code.li(.a0, 0x100000000);
    try expectBytes(&code, &.{
        0x13, 0x05, 0x00, 0x00, // addi a0, zero, 0
        0x13, 0x05, 0xf0, 0xff, // addi a0, zero, -1
        0x37, 0xf5, 0xff, 0xff, // lui a0, -1
        0x37, 0x05, 0x00, 0x80, // lui a0, 0x80000
        0x1b, 0x05, 0xf5, 0xff, // addiw a0, a0, -1
        0x13, 0x05, 0x10, 0x00, // addi a0, zero, 1
        0x13, 0x15, 0xf5, 0x01, // slli a0, a0, 31
        0x13, 0x05, 0x10, 0x00, // addi a0, zero, 1
        0x13, 0x15, 0x05, 0x02, // slli a0, a0, 32
    });
}

test "riscv64 AssemblyBuilder li materializes u64" {
    const values = [_]u64{
        0,
        1,
        @bitCast(@as(i64, -1)),
        2047,
        @bitCast(@as(i64, -2048)),
        2048,
        @bitCast(@as(i64, -2049)),
        0x800,
        0x1000,
        0x7fffffff,
        0x80000000,
        0xffffffff,
        0x100000000,
        0x7ffff800,
        0xffffffff80000000,
        0x1122334455667788,
        0x0123456789abcdef,
        0x8000000000000000,
        0x7fffffffffffffff,
        0xfffffffffffff800,
        0xfffffffffffff000,
        0xfff,
        0x8000000000000001,
        0xdeadbeefcafebabe,
        0xffffffff00000000,
    };
    for (values) |value|
        try expectLi(value);

    var state: u64 = 0x123456789abcdef;
    for (0..200) |_| {
        state = state *% 6364136223846793005 +% 1;
        try expectLi(state);
    }
}

test "riscv64 AssemblyBuilder addImm" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer code.deinit();
    try code.addImm(.a0, .sp, 8, .t6);
    try code.addImm(.a0, .a1, 4096, .t6);
    try code.addImm(.sp, .sp, 4096, .t6);
    try expectBytes(&code, &.{
        0x13, 0x05, 0x81, 0x00, // addi a0, sp, 8
        0x37, 0x15, 0x00, 0x00, // lui a0, 1
        0x33, 0x85, 0xa5, 0x00, // add a0, a1, a0
        0xb7, 0x1f, 0x00, 0x00, // lui t6, 1
        0x33, 0x01, 0xf1, 0x01, // add sp, sp, t6
    });

    try std.testing.expectError(error.BadScratch, code.addImm(.sp, .sp, 4096, .sp));
    try std.testing.expectError(error.BadScratch, code.addImm(.sp, .sp, 4096, .zero));
}

test "riscv64 AssemblyBuilder rejects bad operands" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer code.deinit();
    try std.testing.expectError(error.OffsetOutOfRange, code.addi(.a0, .a0, 2048));
    try std.testing.expectError(error.OffsetOutOfRange, code.ld(.a0, .sp, -2049));
    try std.testing.expectError(error.OffsetOutOfRange, code.sd(.a0, .sp, 2048));
    try std.testing.expectError(error.NotIntegerRegister, code.addi(.fa0, .sp, 0));
    try std.testing.expectError(error.NotFloatRegister, code.fld(.a0, .sp, 0));
    try std.testing.expectError(error.NotFloatRegister, code.fmv_d_x(.a0, .fa0));
    try std.testing.expectError(error.NotIntegerRegister, code.fmv_x_d(.fa0, .fa0));
    try std.testing.expectEqual(@as(usize, 0), code.array.items.len);

    try code.appendInsn(.{ .addi = .{ .a0, .a0, 4096 } });
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.OffsetOutOfRange, code.encodeInto(&buf));
}

test "riscv64 AssemblyBuilder encodeInto exact-size buffer" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 2);
    defer code.deinit();
    try code.ret();
    var exact: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try code.encodeInto(&exact));
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 0x80, 0x00, 0x00 }, &exact);
    var too_small: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, code.encodeInto(&too_small));

    var empty = try AssemblyBuilder.initCapacity(std.testing.allocator, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.encodedSize());
    try std.testing.expectEqual(@as(usize, 0), try empty.encodeInto(&.{}));
}

test "riscv64 AssemblyBuilder compile matches encodeInto" {
    const allocator = std.testing.allocator;
    var code = try AssemblyBuilder.initCapacity(allocator, 8);
    defer code.deinit();
    try code.addi(.sp, .sp, -16);
    try code.sd(.ra, .sp, 8);
    try code.li(.a0, 0x1122334455667788);
    try code.jalr(.ra, .a0, 0);
    try code.ld(.ra, .sp, 8);
    try code.addi(.sp, .sp, 16);
    try code.ret();

    const encoded = try encodeAll(&code);
    defer allocator.free(encoded);
    const compiled = try code.compile(allocator);
    defer allocator.free(compiled);
    try std.testing.expectEqualSlices(u8, encoded, compiled);
}

test "riscv64 createStruct and createArray" {
    const allocator = std.testing.allocator;
    const empty = try createStruct(allocator, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), empty.size);

    const pair = try createStruct(allocator, &.{ .float32, .float32 }, null);
    defer pair.free(allocator);
    try std.testing.expectEqual(@as(usize, 8), pair.size);
    try std.testing.expectEqual(std.mem.Alignment.@"4", pair.alignment);
    try std.testing.expectEqual(common.Type.Class.sse, pair.class);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, pair.offsets.?);
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(pair));

    const two_f64 = try createStruct(allocator, &.{ .float64, .float64 }, null);
    defer two_f64.free(allocator);
    try std.testing.expectEqual(common.Type.Class.sse, two_f64.class);
    try std.testing.expectEqual(@as(usize, 16), two_f64.size);
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(two_f64));

    // A third float is past the LP64D pair, so this stays integer even though
    // the bytes still fit in two XLEN words.
    const three = try createStruct(allocator, &.{ .float32, .float32, .float32 }, null);
    defer three.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, three.class);
    try std.testing.expectEqual(@as(usize, 12), three.size);

    const mixed = try createStruct(allocator, &.{ .int32, .float64 }, null);
    defer mixed.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, mixed.class);
    try std.testing.expectEqualSlices(usize, &.{ 0, 8 }, mixed.offsets.?);
    try std.testing.expectEqualSlices(usize, &.{ 4, 8 }, mixed.field_sizes.?);
    try std.testing.expectEqual(common.Type.Eightbyte.int, mixed.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, mixed.eightbytes.high);

    // Different float widths are still two fa registers. `size / 2` is 8,
    // which would load the f32 plus its padding as a double.
    const uneven = try createStruct(allocator, &.{ .float32, .float64 }, null);
    defer uneven.free(allocator);
    try std.testing.expectEqual(common.Type.Class.sse, uneven.class);
    try std.testing.expectEqual(@as(usize, 16), uneven.size);
    try std.testing.expectEqualSlices(usize, &.{ 0, 8 }, uneven.offsets.?);
    try std.testing.expectEqualSlices(usize, &.{ 4, 8 }, uneven.field_sizes.?);
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(uneven));

    const same_word = try createStruct(allocator, &.{ .float32, .int32 }, null);
    defer same_word.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, same_word.class);
    try std.testing.expectEqual(@as(usize, 8), same_word.size);
    try std.testing.expectEqualSlices(usize, &.{ 4, 4 }, same_word.field_sizes.?);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, same_word.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.int, same_word.eightbytes.high);

    const float_int = try createStruct(allocator, &.{ .float64, .int64 }, null);
    defer float_int.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, float_int.class);
    try std.testing.expectEqualSlices(usize, &.{ 8, 8 }, float_int.field_sizes.?);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, float_int.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.int, float_int.eightbytes.high);

    // Four fields is not an FPCC pair. It stays an integer memory image.
    const quad = try createStruct(allocator, &.{ .float32, .float32, .int32, .int32 }, null);
    defer quad.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, quad.class);
    try std.testing.expect(quad.field_sizes == null);
    try std.testing.expectEqual(common.Type.Eightbyte.none, quad.eightbytes.low);

    const big = try createStruct(allocator, &.{ .float64, .float64, .float64 }, null);
    defer big.free(allocator);
    try std.testing.expectEqual(common.Type.Class.mem, big.class);
    try std.testing.expectEqual(@as(usize, 24), big.size);

    // The nested HFA is one member. Flattening it would report two registers.
    const nested = try createStruct(allocator, &.{pair}, null);
    defer nested.free(allocator);
    try std.testing.expectEqual(common.Type.Class.sse, nested.class);
    try std.testing.expectEqual(@as(usize, 1), hfaFieldCount(nested));

    try std.testing.expectError(error.PoorAlignment, createStruct(allocator, &.{.int64}, .@"4"));

    const two = createArray(.float32, 2);
    try std.testing.expect(two.offsets == null);
    try std.testing.expectEqual(common.Type.Class.sse, two.class);
    try std.testing.expectEqual(@as(usize, 8), two.size);
    try std.testing.expectEqual(std.mem.Alignment.@"4", two.alignment);
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(two));
    try std.testing.expectEqual(@as(usize, 1), hfaFieldCount(.float64));
    try std.testing.expectEqual(@as(usize, 1), hfaFieldCount(.float32));
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(createArray(.float64, 2)));
    try std.testing.expectEqual(common.Type.Class.int, createArray(.float32, 3).class);
    try std.testing.expectEqual(@as(usize, 12), createArray(.float32, 3).size);
    try std.testing.expectEqual(common.Type.Class.mem, createArray(.float32, 5).class);
    try std.testing.expectEqual(common.Type.Class.int, createArray(.int32, 4).class);
    try std.testing.expectEqual(@as(usize, 16), createArray(.int32, 4).size);
    try std.testing.expectEqual(@as(usize, 0), createArray(.float64, 0).size);

    // Two copies of a 2-float struct are four floats. The ratio exceeds 2,
    // so the array is not an HFA even though each element is.
    const doubled = createArray(pair, 2);
    try std.testing.expectEqual(common.Type.Class.int, doubled.class);
    try std.testing.expectEqual(@as(usize, 16), doubled.size);
}
