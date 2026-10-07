const std = @import("std");
const builtin = @import("builtin");

const common = @import("../common.zig");

const build_config = @import("build_config");

const endian = builtin.cpu.arch.endian();

pub const CallingConvention = enum {
    AAPCS64,
};

// AArch64 uses x0-x7 for integer/pointer arguments
pub const ArgumentRegistery = [_]AssemblyBuilder.Register{
    .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
};

// AArch64 uses v0-v7 for floating-point arguments
pub const FloatingPointRegistery = [_]AssemblyBuilder.Register{
    .q0, .q1, .q2, .q3, .q4, .q5, .q6, .q7,
};

pub const AssemblyBuilder = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(Instruction) = .empty,
    stack_push_offset: usize = 0,

    pub const Register = enum {
        // zig fmt: off
        b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10,
        b11, b12, b13, b14, b15, b16, b17, b18, b19, b20,
        b21, b22, b23, b24, b25, b26, b27, b28, b29, b30,
        h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10,
        h11, h12, h13, h14, h15, h16, h17, h18, h19, h20,
        h21, h22, h23, h24, h25, h26, h27, h28, h29, h30,
        w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10,
        w11, w12, w13, w14, w15, w16, w17, w18, w19, w20,
        w21, w22, w23, w24, w25, w26, w27, w28, w29, w30,
        x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10,
        x11, x12, x13, x14, x15, x16, x17, x18, x19, x20,
        x21, x22, x23, x24, x25, x26, x27, x28, x29, x30,
        q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10,
        q11, q12, q13, q14, q15, q16, q17, q18, q19, q20,
        q21, q22, q23, q24, q25, q26, q27, q28, q29, q30,
        // zig fmt: on
        sp,
        lr,
        zr,

        pub fn toOperandSize(self: Register) u5 {
            return switch (self) {
                .b0, .b1, .b2, .b3, .b4, .b5, .b6, .b7, .b8, .b9, .b10, .b11, .b12, .b13, .b14, .b15, .b16, .b17, .b18, .b19, .b20, .b21, .b22, .b23, .b24, .b25, .b26, .b27, .b28, .b29, .b30 => 1,
                .h0, .h1, .h2, .h3, .h4, .h5, .h6, .h7, .h8, .h9, .h10, .h11, .h12, .h13, .h14, .h15, .h16, .h17, .h18, .h19, .h20, .h21, .h22, .h23, .h24, .h25, .h26, .h27, .h28, .h29, .h30 => 2,
                .w0, .w1, .w2, .w3, .w4, .w5, .w6, .w7, .w8, .w9, .w10, .w11, .w12, .w13, .w14, .w15, .w16, .w17, .w18, .w19, .w20, .w21, .w22, .w23, .w24, .w25, .w26, .w27, .w28, .w29, .w30 => 4,
                .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15, .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28, .x29, .x30, .sp, .lr, .zr => 8,
                .q0, .q1, .q2, .q3, .q4, .q5, .q6, .q7, .q8, .q9, .q10, .q11, .q12, .q13, .q14, .q15, .q16, .q17, .q18, .q19, .q20, .q21, .q22, .q23, .q24, .q25, .q26, .q27, .q28, .q29, .q30 => 16,
            };
        }

        pub fn toInt(self: Register) u5 {
            return switch (self) {
                .b0, .h0, .w0, .x0, .q0 => 0,
                .b1, .h1, .w1, .x1, .q1 => 1,
                .b2, .h2, .w2, .x2, .q2 => 2,
                .b3, .h3, .w3, .x3, .q3 => 3,
                .b4, .h4, .w4, .x4, .q4 => 4,
                .b5, .h5, .w5, .x5, .q5 => 5,
                .b6, .h6, .w6, .x6, .q6 => 6,
                .b7, .h7, .w7, .x7, .q7 => 7,
                .b8, .h8, .w8, .x8, .q8 => 8,
                .b9, .h9, .w9, .x9, .q9 => 9,
                .b10, .h10, .w10, .x10, .q10 => 10,
                .b11, .h11, .w11, .x11, .q11 => 11,
                .b12, .h12, .w12, .x12, .q12 => 12,
                .b13, .h13, .w13, .x13, .q13 => 13,
                .b14, .h14, .w14, .x14, .q14 => 14,
                .b15, .h15, .w15, .x15, .q15 => 15,
                .b16, .h16, .w16, .x16, .q16 => 16,
                .b17, .h17, .w17, .x17, .q17 => 17,
                .b18, .h18, .w18, .x18, .q18 => 18,
                .b19, .h19, .w19, .x19, .q19 => 19,
                .b20, .h20, .w20, .x20, .q20 => 20,
                .b21, .h21, .w21, .x21, .q21 => 21,
                .b22, .h22, .w22, .x22, .q22 => 22,
                .b23, .h23, .w23, .x23, .q23 => 23,
                .b24, .h24, .w24, .x24, .q24 => 24,
                .b25, .h25, .w25, .x25, .q25 => 25,
                .b26, .h26, .w26, .x26, .q26 => 26,
                .b27, .h27, .w27, .x27, .q27 => 27,
                .b28, .h28, .w28, .x28, .q28 => 28,
                .b29, .h29, .w29, .x29, .q29 => 29,
                .b30, .h30, .w30, .x30, .q30, .lr => 30,
                .sp => 31,
                .zr => 31,
            };
        }

        /// `sp` and `zr` share encoding 31 and are not in the b/h/w/x/q runs.
        /// `lr` is x30. FP width is selected by operand size of the w/x/q name:
        /// `q0.withBitSize(4)` is `w0`, and an FP opcode then writes s0.
        pub fn withBitSize(self: Register, bit_size: u8) Register {
            const base = if (self == .lr) Register.x30 else self;
            if (base == .sp or base == .zr) {
                if (bit_size == 8) return base;
                unreachable;
            }
            const reg_num: usize = base.toInt();
            return switch (bit_size) {
                1 => @fromBackingInt(@intCast(@backingInt(Register.b0) + reg_num)),
                2 => @fromBackingInt(@intCast(@backingInt(Register.h0) + reg_num)),
                4 => @fromBackingInt(@intCast(@backingInt(Register.w0) + reg_num)),
                8 => @fromBackingInt(@intCast(@backingInt(Register.x0) + reg_num)),
                16 => @fromBackingInt(@intCast(@backingInt(Register.q0) + reg_num)),
                else => unreachable,
            };
        }

        test "aarch64 withBitSize" {
            // FP ops reuse the GP name with the same number. q0 is v0;
            // withBitSize(4) must be w0 so LDR/STR (SIMD) writes s0.
            try std.testing.expectEqual(Register.w0, Register.q0.withBitSize(4));
            try std.testing.expectEqual(Register.x0, Register.q0.withBitSize(8));
            try std.testing.expectEqual(Register.q0, Register.x0.withBitSize(16));
            try std.testing.expectEqual(Register.q7, Register.w7.withBitSize(16));
            try std.testing.expectEqual(Register.b19, Register.x19.withBitSize(1));
            try std.testing.expectEqual(Register.h7, Register.w7.withBitSize(2));
            try std.testing.expectEqual(Register.x30, Register.lr.withBitSize(8));
            try std.testing.expectEqual(Register.w30, Register.lr.withBitSize(4));
            try std.testing.expectEqual(Register.sp, Register.sp.withBitSize(8));
            try std.testing.expectEqual(Register.zr, Register.zr.withBitSize(8));
        }
    };

    pub fn init(allocator: std.mem.Allocator, num: usize) !AssemblyBuilder {
        return initCapacity(allocator, num);
    }

    pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !AssemblyBuilder {
        return .{
            .allocator = allocator,
            .array = try .initCapacity(allocator, num),
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
        for (self.array.items) |insn|
            insn.print();
    }

    pub const EncodeError = error{
        OffsetOutOfRange,
        ImmediateOutOfRange,
        UnsupportedRegisterSize,
    };

    /// Fixed 32-bit instructions. `str`/`ldr` offsets are signed bytes.
    /// A non-negative multiple of the access size uses the unsigned imm12
    /// form. Anything else in −256..255 uses LDUR/STUR (the imm9 is not
    /// scaled). The pre-index form is not used: it would write the base back.
    pub const Instruction = union(enum) {
        str: struct { Register, Register, i32 },
        ldr: struct { Register, Register, i32 },
        strb: struct { Register, Register, i32 },
        ldrb: struct { Register, Register, i32 },
        strh: struct { Register, Register, i32 },
        ldrh: struct { Register, Register, i32 },
        str_fp: struct { Register, Register, i32 },
        ldr_fp: struct { Register, Register, i32 },
        mov: struct { Register, Register },
        /// MOVZ of the lowest set halfword, then MOVK for the others.
        /// Up to four instructions. Not a fixed-width hole.
        mov_imm: struct { Register, u64 },
        /// `fmov` s/d, or `mov Vd.16B, Vn.16B` for q. Width comes from the
        /// register's operand size, so `w` is S and `x` is D.
        fmov: struct { Register, Register },
        add: struct { Register, Register, Register },
        sub: struct { Register, Register, Register },
        /// Last field is the `lsl #12` shift on the imm12. Bit 22 in the
        /// encoding. A later patch of the frame size has to keep that bit
        /// and the imm12 in range or the instruction stops meaning ADD/SUB.
        add_imm: struct { Register, Register, u12, bool },
        sub_imm: struct { Register, Register, u12, bool },
        /// Byte displacement from this instruction. Must be a multiple of 4.
        bl: i32,
        blr: Register,
        br: Register,
        ret: void,
        stp: struct { Register, Register, Register, i32 },
        ldp: struct { Register, Register, Register, i32 },

        const MemOp = enum { load, store };

        inline fn writeInsn(writer: *std.Io.Writer, instr: u32) !void {
            try writer.writeInt(u32, instr, endian);
        }

        inline fn dataIndex(rt: Register) !u5 {
            if (rt == .sp or rt == .zr) return error.UnsupportedRegisterSize;
            if (rt == .lr) return 30;
            return rt.toInt();
        }

        inline fn addrIndex(rn: Register) !u5 {
            // Rn=31 in a load/store is SP. ZR is the same number and is not a base.
            if (rn == .zr) return error.UnsupportedRegisterSize;
            if (rn == .lr) return 30;
            return rn.toInt();
        }

        inline fn fitsUnsigned(size: u8, offset: i32) ?u32 {
            if (offset < 0) return null;
            const sz: i32 = size;
            if (@rem(offset, sz) != 0) return null;
            const scaled = @divExact(offset, sz);
            if (scaled > 0xfff) return null;
            return @intCast(scaled);
        }

        inline fn emitMem(writer: *std.Io.Writer, op: MemOp, rt: Register, rn: Register, offset: i32, fp: bool) !void {
            if (fp) {
                if (rt == .sp or rt == .zr or rt == .lr) return error.UnsupportedRegisterSize;
                const size = rt.toOperandSize();
                if (size != 4 and size != 8 and size != 16) return error.UnsupportedRegisterSize;
                try emitMemSized(writer, op, rt, rn, offset, size, true);
                return;
            }
            const size = rt.toOperandSize();
            if (size != 4 and size != 8) return error.UnsupportedRegisterSize;
            try emitMemSized(writer, op, rt, rn, offset, size, false);
        }

        inline fn emitMemSized(writer: *std.Io.Writer, op: MemOp, rt: Register, rn: Register, offset: i32, size: u8, fp: bool) !void {
            const rt_i = try dataIndex(rt);
            const rn_i = try addrIndex(rn);
            const word = try memWord(op, size, rt_i, rn_i, offset, fp);
            try writeInsn(writer, word);
        }

        inline fn memWord(op: MemOp, size: u8, rt: u5, rn: u5, offset: i32, fp: bool) !u32 {
            if (fitsUnsigned(size, offset)) |imm12| {
                const base: u32 = if (fp) fpUnsigned(op, size) else gpUnsigned(op, size);
                return base | (imm12 << 10) | (@as(u32, rn) << 5) | rt;
            }
            if (offset < -256 or offset > 255) return error.OffsetOutOfRange;
            const base: u32 = if (fp) fpUnscaled(op, size) else gpUnscaled(op, size);
            const imm9: u9 = @bitCast(@as(i9, @intCast(offset)));
            return base | (@as(u32, imm9) << 12) | (@as(u32, rn) << 5) | rt;
        }

        inline fn gpUnsigned(op: MemOp, size: u8) u32 {
            return switch (size) {
                1 => if (op == .load) 0x39400000 else 0x39000000,
                2 => if (op == .load) 0x79400000 else 0x79000000,
                4 => if (op == .load) 0xB9400000 else 0xB9000000,
                8 => if (op == .load) 0xF9400000 else 0xF9000000,
                else => unreachable,
            };
        }

        inline fn gpUnscaled(op: MemOp, size: u8) u32 {
            return switch (size) {
                1 => if (op == .load) 0x38400000 else 0x38000000,
                2 => if (op == .load) 0x78400000 else 0x78000000,
                4 => if (op == .load) 0xB8400000 else 0xB8000000,
                8 => if (op == .load) 0xF8400000 else 0xF8000000,
                else => unreachable,
            };
        }

        inline fn fpUnsigned(op: MemOp, size: u8) u32 {
            return switch (size) {
                4 => if (op == .load) 0xBD400000 else 0xBD000000,
                8 => if (op == .load) 0xFD400000 else 0xFD000000,
                16 => if (op == .load) 0x3DC00000 else 0x3D800000,
                else => unreachable,
            };
        }

        inline fn fpUnscaled(op: MemOp, size: u8) u32 {
            return switch (size) {
                4 => if (op == .load) 0xBC400000 else 0xBC000000,
                8 => if (op == .load) 0xFC400000 else 0xFC000000,
                16 => if (op == .load) 0x3CC00000 else 0x3C800000,
                else => unreachable,
            };
        }

        const Gp = struct { idx: u5, wide: ?bool };

        inline fn gpOperand(reg: Register) !Gp {
            // wide == null is ZR: it adopts the other operand's width. 31 in a
            // logical op is ZR; 31 in ADD immediate is SP, so callers reject ZR there.
            if (reg == .zr) return .{ .idx = 31, .wide = null };
            if (reg == .sp) return .{ .idx = 31, .wide = true };
            if (reg == .lr) return .{ .idx = 30, .wide = true };
            return switch (reg.toOperandSize()) {
                8 => .{ .idx = reg.toInt(), .wide = true },
                4 => .{ .idx = reg.toInt(), .wide = false },
                else => error.UnsupportedRegisterSize,
            };
        }

        inline fn resolveWide(parts: []const ?bool) !bool {
            var wide: ?bool = null;
            for (parts) |part| {
                const bit = part orelse continue;
                if (wide) |got| {
                    if (got != bit) return error.UnsupportedRegisterSize;
                } else wide = bit;
            }
            return wide orelse true;
        }

        inline fn emitMov(writer: *std.Io.Writer, rd: Register, rn: Register) !void {
            // MOV to or from SP is ADD immediate #0. ORR cannot name SP: 31 is ZR.
            if (rd == .sp or rn == .sp) {
                if (rd == .zr or rn == .zr) return error.UnsupportedRegisterSize;
                const dst = try gpOperand(rd);
                const src = try gpOperand(rn);
                if (dst.wide != true or src.wide != true) return error.UnsupportedRegisterSize;
                try writeInsn(writer, 0x91000000 | (@as(u32, src.idx) << 5) | dst.idx);
                return;
            }
            const dst = try gpOperand(rd);
            const src = try gpOperand(rn);
            const wide = try resolveWide(&.{ dst.wide, src.wide });
            const base: u32 = if (wide) 0xAA0003E0 else 0x2A0003E0;
            try writeInsn(writer, base | (@as(u32, src.idx) << 16) | dst.idx);
        }

        inline fn emitMovImm(writer: *std.Io.Writer, rd: Register, value: u64) !void {
            const dst = try gpOperand(rd);
            const wide = dst.wide orelse return error.UnsupportedRegisterSize;
            if (!wide and value > 0xffffffff) return error.ImmediateOutOfRange;
            const chunks: usize = if (wide) 4 else 2;
            var started = false;
            for (0..chunks) |i| {
                const part: u16 = @truncate(value >> @intCast(i * 16));
                if (part == 0 and (started or value != 0)) {
                    var later = false;
                    for (i + 1..chunks) |j| {
                        const next: u16 = @truncate(value >> @intCast(j * 16));
                        if (next != 0) later = true;
                    }
                    if (later or started) continue;
                }
                const base: u32 = if (!started)
                    (if (wide) 0xD2800000 else 0x52800000)
                else
                    (if (wide) 0xF2800000 else 0x72800000);
                const hw: u32 = @intCast(i);
                try writeInsn(writer, base | (hw << 21) | (@as(u32, part) << 5) | dst.idx);
                started = true;
            }
        }

        inline fn emitFmov(writer: *std.Io.Writer, rd: Register, rn: Register) !void {
            if (rd == .sp or rd == .zr or rn == .sp or rn == .zr or rd == .lr or rn == .lr)
                return error.UnsupportedRegisterSize;
            if (rd.toOperandSize() != rn.toOperandSize()) return error.UnsupportedRegisterSize;
            const n: u32 = rn.toInt();
            const d: u32 = rd.toInt();
            const instr: u32 = switch (rd.toOperandSize()) {
                4 => 0x1E204000 | (n << 5) | d,
                8 => 0x1E604000 | (n << 5) | d,
                // ORR Vd.16B, Vn.16B, Vn.16B. There is no scalar FMOV for Q.
                16 => 0x4EA01C00 | (n << 16) | (n << 5) | d,
                else => return error.UnsupportedRegisterSize,
            };
            try writeInsn(writer, instr);
        }

        inline fn emitAddSubReg(writer: *std.Io.Writer, subtract: bool, rd: Register, rn: Register, rm: Register) !void {
            // Shifted-register ADD cannot encode SP (31 would be ZR). Use add_imm.
            if (rd == .sp or rn == .sp or rm == .sp) return error.UnsupportedRegisterSize;
            const dst = try gpOperand(rd);
            const src = try gpOperand(rn);
            const rhs = try gpOperand(rm);
            const wide = try resolveWide(&.{ dst.wide, src.wide, rhs.wide });
            const base: u32 = if (subtract)
                (if (wide) 0xCB000000 else 0x4B000000)
            else
                (if (wide) 0x8B000000 else 0x0B000000);
            try writeInsn(writer, base | (@as(u32, rhs.idx) << 16) | (@as(u32, src.idx) << 5) | dst.idx);
        }

        inline fn emitAddSubImm(writer: *std.Io.Writer, subtract: bool, rd: Register, rn: Register, imm: u12, shift12: bool) !void {
            if (rd == .zr or rn == .zr) return error.UnsupportedRegisterSize;
            const dst = try gpOperand(rd);
            const src = try gpOperand(rn);
            const wide = try resolveWide(&.{ dst.wide, src.wide });
            const base: u32 = if (subtract)
                (if (wide) 0xD1000000 else 0x51000000)
            else
                (if (wide) 0x91000000 else 0x11000000);
            var instr = base | (@as(u32, imm) << 10) | (@as(u32, src.idx) << 5) | dst.idx;
            if (shift12) instr |= 1 << 22;
            try writeInsn(writer, instr);
        }

        inline fn emitBl(writer: *std.Io.Writer, disp_bytes: i32) !void {
            if (@rem(disp_bytes, 4) != 0) return error.ImmediateOutOfRange;
            const imm = @divExact(disp_bytes, 4);
            if (imm < -0x2000000 or imm > 0x1ffffff) return error.ImmediateOutOfRange;
            const bits: u26 = @bitCast(@as(i26, @intCast(imm)));
            try writeInsn(writer, 0x94000000 | @as(u32, bits));
        }

        inline fn emitBranch(writer: *std.Io.Writer, base: u32, reg: Register) !void {
            if (reg == .sp or reg == .zr) return error.UnsupportedRegisterSize;
            const idx: u5 = if (reg == .lr) 30 else reg.toInt();
            if (reg != .lr and reg.toOperandSize() != 8) return error.UnsupportedRegisterSize;
            try writeInsn(writer, base | (@as(u32, idx) << 5));
        }

        inline fn emitPair(writer: *std.Io.Writer, load: bool, rt1: Register, rt2: Register, rn: Register, offset: i32) !void {
            const a = try gpOperand(rt1);
            const b = try gpOperand(rt2);
            if (a.wide == null or b.wide == null or rt1 == .sp or rt2 == .sp)
                return error.UnsupportedRegisterSize;
            const wide = try resolveWide(&.{ a.wide, b.wide });
            const rn_i = try addrIndex(rn);
            const size: u8 = if (wide) 8 else 4;
            const sz: i32 = size;
            if (@rem(offset, sz) != 0) return error.OffsetOutOfRange;
            const scaled = @divExact(offset, sz);
            if (scaled < -64 or scaled > 63) return error.OffsetOutOfRange;
            const imm7: u7 = @bitCast(@as(i7, @intCast(scaled)));
            const base: u32 = if (load)
                (if (wide) 0xA9400000 else 0x29400000)
            else
                (if (wide) 0xA9000000 else 0x29000000);
            try writeInsn(writer, base | (@as(u32, imm7) << 15) | (@as(u32, b.idx) << 10) | (@as(u32, rn_i) << 5) | a.idx);
        }

        pub fn emit(self: Instruction, writer: *std.Io.Writer) !void {
            switch (self) {
                .str => |i| try emitMem(writer, .store, i[0], i[1], i[2], false),
                .ldr => |i| try emitMem(writer, .load, i[0], i[1], i[2], false),
                .strb => |i| try emitMemSized(writer, .store, i[0], i[1], i[2], 1, false),
                .ldrb => |i| try emitMemSized(writer, .load, i[0], i[1], i[2], 1, false),
                .strh => |i| try emitMemSized(writer, .store, i[0], i[1], i[2], 2, false),
                .ldrh => |i| try emitMemSized(writer, .load, i[0], i[1], i[2], 2, false),
                .str_fp => |i| try emitMem(writer, .store, i[0], i[1], i[2], true),
                .ldr_fp => |i| try emitMem(writer, .load, i[0], i[1], i[2], true),
                .mov => |i| try emitMov(writer, i[0], i[1]),
                .mov_imm => |i| try emitMovImm(writer, i[0], i[1]),
                .fmov => |i| try emitFmov(writer, i[0], i[1]),
                .add => |i| try emitAddSubReg(writer, false, i[0], i[1], i[2]),
                .sub => |i| try emitAddSubReg(writer, true, i[0], i[1], i[2]),
                .add_imm => |i| try emitAddSubImm(writer, false, i[0], i[1], i[2], i[3]),
                .sub_imm => |i| try emitAddSubImm(writer, true, i[0], i[1], i[2], i[3]),
                .bl => |disp| try emitBl(writer, disp),
                .blr => |reg| try emitBranch(writer, 0xD63F0000, reg),
                .br => |reg| try emitBranch(writer, 0xD61F0000, reg),
                .ret => try writeInsn(writer, 0xD65F03C0),
                .stp => |i| try emitPair(writer, false, i[0], i[1], i[2], i[3]),
                .ldp => |i| try emitPair(writer, true, i[0], i[1], i[2], i[3]),
            }
        }

        pub fn print(self: Instruction) void {
            switch (self) {
                .str, .ldr, .strb, .ldrb, .strh, .ldrh, .str_fp, .ldr_fp => |i| {
                    std.debug.print("{s} {s}, [{s}, #{d}]\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]), i[2] });
                },
                .mov, .fmov => |i| std.debug.print("{s} {s}, {s}\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]) }),
                .mov_imm => |i| std.debug.print("mov {s}, #0x{x}\n", .{ @tagName(i[0]), i[1] }),
                .add, .sub => |i| std.debug.print("{s} {s}, {s}, {s}\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]), @tagName(i[2]) }),
                .add_imm, .sub_imm => |i| {
                    if (i[3])
                        std.debug.print("{s} {s}, {s}, #{d}, lsl #12\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]), i[2] })
                    else
                        std.debug.print("{s} {s}, {s}, #{d}\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]), i[2] });
                },
                .bl => |disp| std.debug.print("bl #{d}\n", .{disp}),
                .blr, .br => |reg| std.debug.print("{s} {s}\n", .{ @tagName(self), @tagName(reg) }),
                .ret => std.debug.print("ret\n", .{}),
                .stp, .ldp => |i| std.debug.print("{s} {s}, {s}, [{s}, #{d}]\n", .{ @tagName(self), @tagName(i[0]), @tagName(i[1]), @tagName(i[2]), i[3] }),
            }
        }
    };

    fn commit(self: *AssemblyBuilder, insn: Instruction) !void {
        var scratch: [8]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&scratch);
        // Reject an offset or register the encoder cannot represent before
        // it lands in the list. encodeInto then only fails when the buffer
        // is short. mov_imm is at most 16 bytes; Discarding still accepts it.
        insn.emit(&discarding.writer) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
        try self.appendInsn(insn);
    }

    pub fn str(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .str = .{ rt, rn, offset } });
    }

    pub fn ldr(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .ldr = .{ rt, rn, offset } });
    }

    pub fn strb(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .strb = .{ rt, rn, offset } });
    }

    pub fn ldrb(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .ldrb = .{ rt, rn, offset } });
    }

    pub fn strh(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .strh = .{ rt, rn, offset } });
    }

    pub fn ldrh(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .ldrh = .{ rt, rn, offset } });
    }

    pub fn str_fp(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .str_fp = .{ rt, rn, offset } });
    }

    pub fn ldr_fp(self: *AssemblyBuilder, rt: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .ldr_fp = .{ rt, rn, offset } });
    }

    pub fn mov(self: *AssemblyBuilder, rd: Register, rn: Register) !void {
        try self.commit(.{ .mov = .{ rd, rn } });
    }

    pub fn mov_imm(self: *AssemblyBuilder, rd: Register, value: u64) !void {
        try self.commit(.{ .mov_imm = .{ rd, value } });
    }

    pub fn fmov(self: *AssemblyBuilder, rd: Register, rn: Register) !void {
        try self.commit(.{ .fmov = .{ rd, rn } });
    }

    pub fn add(self: *AssemblyBuilder, rd: Register, rn: Register, rm: Register) !void {
        try self.commit(.{ .add = .{ rd, rn, rm } });
    }

    pub fn sub(self: *AssemblyBuilder, rd: Register, rn: Register, rm: Register) !void {
        try self.commit(.{ .sub = .{ rd, rn, rm } });
    }

    pub fn add_imm(self: *AssemblyBuilder, rd: Register, rn: Register, imm: u12) !void {
        try self.addImm(rd, rn, imm, false);
    }

    pub fn sub_imm(self: *AssemblyBuilder, rd: Register, rn: Register, imm: u12) !void {
        try self.subImm(rd, rn, imm, false);
    }

    fn addImm(self: *AssemblyBuilder, rd: Register, rn: Register, imm: u12, shift12: bool) !void {
        try self.commit(.{ .add_imm = .{ rd, rn, imm, shift12 } });
        self.noteSp(rd, rn, imm, shift12, false);
    }

    fn subImm(self: *AssemblyBuilder, rd: Register, rn: Register, imm: u12, shift12: bool) !void {
        try self.commit(.{ .sub_imm = .{ rd, rn, imm, shift12 } });
        self.noteSp(rd, rn, imm, shift12, true);
    }

    const Imm12 = struct { imm: u12, shift12: bool };

    fn splitImm12(value: u32) error{ImmediateOutOfRange}!Imm12 {
        if (value <= 0xfff) return .{ .imm = @intCast(value), .shift12 = false };
        if (value & 0xfff == 0 and (value >> 12) <= 0xfff)
            return .{ .imm = @intCast(value >> 12), .shift12 = true };
        return error.ImmediateOutOfRange;
    }

    /// `add`/`sub` immediate. Negative displacements are SUB. A multiple of
    /// 4096 uses the shifted imm12 so a 16-byte-aligned frame still fits
    /// in one instruction up to 16773120.
    pub fn lea(self: *AssemblyBuilder, dst: Register, base: Register, disp: i32) !void {
        if (disp >= 0) {
            const parts = try splitImm12(@intCast(disp));
            try self.addImm(dst, base, parts.imm, parts.shift12);
        } else {
            const mag: u32 = @intCast(-@as(i64, disp));
            const parts = try splitImm12(mag);
            try self.subImm(dst, base, parts.imm, parts.shift12);
        }
    }

    pub fn bl(self: *AssemblyBuilder, disp_bytes: i32) !void {
        try self.commit(.{ .bl = disp_bytes });
    }

    pub fn blr(self: *AssemblyBuilder, reg: Register) !void {
        try self.commit(.{ .blr = reg });
    }

    pub fn br(self: *AssemblyBuilder, reg: Register) !void {
        try self.commit(.{ .br = reg });
    }

    pub fn ret(self: *AssemblyBuilder) !void {
        try self.commit(.ret);
    }

    pub fn stp(self: *AssemblyBuilder, rt1: Register, rt2: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .stp = .{ rt1, rt2, rn, offset } });
    }

    pub fn ldp(self: *AssemblyBuilder, rt1: Register, rt2: Register, rn: Register, offset: i32) !void {
        try self.commit(.{ .ldp = .{ rt1, rt2, rn, offset } });
    }

    fn noteSp(self: *AssemblyBuilder, rd: Register, rn: Register, imm: u12, shift12: bool, subtract: bool) void {
        if (rd != .sp or rn != .sp) return;
        const bytes: usize = if (shift12) @as(usize, imm) << 12 else imm;
        if (subtract)
            self.stack_push_offset += bytes
        else
            self.stack_push_offset -= bytes;
    }

    pub fn encodedSize(self: *const AssemblyBuilder) usize {
        var scratch: [32]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&scratch);
        for (self.array.items) |insn| {
            // commit() already rejected instructions that cannot be encoded.
            insn.emit(&discarding.writer) catch unreachable;
        }
        return @intCast(discarding.fullCount());
    }

    pub fn encodeInto(self: *const AssemblyBuilder, buf: []u8) (EncodeError || error{BufferTooSmall})!usize {
        var writer: std.Io.Writer = .fixed(buf);
        for (self.array.items) |insn| {
            const start = writer.end;
            insn.emit(&writer) catch |err| switch (err) {
                error.WriteFailed => return error.BufferTooSmall,
                else => |e| return e,
            };
            if (comptime build_config.verbose_asm)
                std.debug.print("{x}\n", .{writer.buffer[start..writer.end]});
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

const Aggregate = struct {
    cursor: usize,
    alignment: std.mem.Alignment,
    class: common.Type.Class,
};

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
    // Flat HFA: 1–4 members, all the same FP size. Nested aggregates are not
    // flattened; a field that is already a struct counts as one member.
    const hfa = uniform and fields.len >= 1 and fields.len <= 4 and elem_class == .sse;
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
    return .{
        .size = size,
        .alignment = result_align,
        .offsets = offsets,
        .class = if (size > 16) .mem else layout.class,
    };
}

/// No offset table: `Type.array` has no allocator. `hfaFieldCount` recovers
/// an FP array as size/alignment members (a scalar's ratio is 1).
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
    const hfa = amt >= 1 and amt <= 4 and @"type".class == .sse;
    return .{
        .size = size,
        .alignment = alignment,
        .class = if (size > 16) .mem else if (hfa) .sse else .int,
    };
}

/// FP registers an `.sse` value needs. Structs store one offset per member.
/// Arrays do not, so a scalar (size == alignment) is one register and
/// `[N]f32` is N. N > 4 has already been classed `.mem`.
pub fn hfaFieldCount(ty: common.Type) usize {
    if (ty.offsets) |offs| {
        if (offs.len > 0) return offs.len;
    }
    const step = ty.alignment.toByteUnits();
    if (ty.class == .sse and step != 0 and ty.size % step == 0) {
        const n = ty.size / step;
        if (n >= 1 and n <= 4) return n;
    }
    return 1;
}

pub inline fn canFitInArgRegister(class: common.Type.Class, size: usize, arg_pos: usize) bool {
    // Ceiling division ensures sub-8-byte types still require at least 1 register slot
    return size <= 16 and arg_pos + (size + 7) / 8 <= switch (class) {
        .sse => FloatingPointRegistery.len,
        else => ArgumentRegistery.len,
    };
}

const darwin_pcs = builtin.os.tag.isDarwin();

/// Stack slot for one spilled argument. Darwin PCS uses the type's natural
/// size and alignment (f32 is 4 bytes); AAPCS64 uses 8-byte minimum slots
/// (C.5 sets f32 size to 8). Trailing frame padding is applied separately
/// so SP stays 16-byte aligned.
pub fn stackArgLayout(arg: common.Type) struct { size: usize, alignment: std.mem.Alignment } {
    const is_mem = arg.class == .mem;
    const size: usize = if (is_mem) 8 else arg.size;
    const natural_align: std.mem.Alignment = if (is_mem) .@"8" else arg.alignment;
    if (comptime darwin_pcs) {
        return .{ .size = size, .alignment = natural_align };
    }
    return .{
        .size = std.mem.Alignment.@"8".forward(size),
        .alignment = if (natural_align.compare(.gte, .@"16")) .@"16" else .@"8",
    };
}

pub fn getArgumentStackSize(args: []const common.Type, arg_pos: usize) !usize {
    var pos: usize = arg_pos;
    var float_pos: usize = 0;
    var stack: usize = 0;
    for (args) |arg| {
        // AAPCS64: structs > 16 bytes are passed by pointer (8 bytes in an integer register)
        const is_mem = arg.class == .mem;
        const effective_class: common.Type.Class = if (is_mem) .int else arg.class;
        const effective_size: usize = if (is_mem) 8 else arg.size;

        // HFA: one FP register per member. An array has no offset table;
        // hfaFieldCount uses size/alignment. Integer composites use words.
        const num_regs: usize = switch (effective_class) {
            .sse => hfaFieldCount(arg),
            else => (effective_size + 7) / 8,
        };
        const reg_limit: usize = switch (effective_class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        };
        const cur_pos: usize = switch (effective_class) {
            .sse => float_pos,
            else => pos,
        };
        if (cur_pos + num_regs <= reg_limit and stack == 0) {
            switch (effective_class) {
                .sse => float_pos += num_regs,
                else => pos += num_regs,
            }
        } else {
            const layout = stackArgLayout(arg);
            stack = layout.alignment.forward(stack);
            stack += layout.size;
        }
    }
    return stack;
}

pub fn buildCallInvoker(allocator: std.mem.Allocator, param_types: []const common.Type, return_type: common.Type) ![]align(std.heap.page_size_min) u8 {
    var code = try AssemblyBuilder.initCapacity(allocator, 64);
    defer code.deinit();
    defer if (comptime build_config.verbose_asm) code.print();

    // Callee-saved registers for preserving state across the function call
    const fnPtr: AssemblyBuilder.Register = .x19;
    const argsPtr: AssemblyBuilder.Register = .x20;
    const retPtr: AssemblyBuilder.Register = .x21;

    // AAPCS64: indirect return (size > 16) uses x8, not an argument register
    const use_return_address = return_type.size > 16;

    // Bytes occupied by spilled arguments (Darwin: natural slots; AAPCS64: 8-byte slots)
    const args_stack_bytes = try getArgumentStackSize(param_types, 0);

    // Frame layout (from new sp, growing upward):
    //   [sp + 0 .. args_stack_bytes)   : stack arguments for callee
    //   [sp + save_base + 0]           : saved x29, x30 (16 bytes)
    //   [sp + save_base + 16]          : saved x19, x20 (16 bytes)
    //   [sp + save_base + 32]          : saved x21 + padding (16 bytes)
    const save_area: usize = 48;
    const total_frame = (args_stack_bytes + save_area + 15) & ~@as(usize, 15);
    const save_base = total_frame - save_area;
    const save_base_i32: i32 = @intCast(save_base);

    // Prologue: allocate stack frame
    {
        var remaining = total_frame;
        while (remaining > 0) {
            const chunk: u12 = @intCast(@min(remaining, 4095));
            try code.sub_imm(.sp, .sp, chunk);
            remaining -= chunk;
        }
    }

    // Save callee-saved registers
    try code.stp(.x29, .x30, .sp, save_base_i32);
    try code.stp(.x19, .x20, .sp, save_base_i32 + 16);
    try code.str(.x21, .sp, @intCast(save_base + 32));

    // Save incoming parameters to callee-saved registers
    // Entry: x0 = function pointer, x1 = args array, x2 = return pointer
    try code.mov(fnPtr, .x0);
    if (param_types.len > 0) {
        try code.mov(argsPtr, .x1);
    }
    if (return_type.size > 0) {
        if (use_return_address) {
            // AAPCS64: indirect return pointer goes in x8 (separate from arg registers)
            try code.mov(.x8, .x2);
        } else {
            try code.mov(retPtr, .x2);
        }
    }

    // Load arguments into registers or spill to stack per AAPCS64
    var arg_pos: usize = 0;
    var floating_arg_pos: usize = 0;
    var stack_offset: usize = 0;

    // x9 = temp for arg address loading (avoids x8 which holds indirect return pointer)
    const temp: AssemblyBuilder.Register = .x9;
    const temp2: AssemblyBuilder.Register = .x10;

    for (param_types, 0..) |param, pos| {
        std.debug.assert(param.size > 0);

        // Load pointer to this argument's data from the args array
        try code.ldr(temp, argsPtr, @intCast(pos * 8));

        // AAPCS64: structs > 16 bytes are passed by pointer, not by value
        const is_mem = param.class == .mem;
        const effective_size: usize = if (is_mem) 8 else param.size;
        const effective_class: common.Type.Class = if (is_mem) .int else param.class;

        const reg_pos = switch (effective_class) {
            .sse => floating_arg_pos,
            else => arg_pos,
        };

        // HFA: one FP register per member, including FP arrays with no offsets.
        const num_regs_needed: usize = switch (effective_class) {
            .sse => hfaFieldCount(param),
            else => (effective_size + 7) / 8,
        };
        const reg_limit: usize = switch (effective_class) {
            .sse => FloatingPointRegistery.len,
            else => ArgumentRegistery.len,
        };
        const can_fit = reg_pos + num_regs_needed <= reg_limit;

        if (can_fit) {
            switch (effective_class) {
                .int => {
                    const reg = ArgumentRegistery[arg_pos];
                    if (is_mem) {
                        // Pass the pointer directly (temp already holds args[pos])
                        try code.mov(reg, temp);
                        arg_pos += 1;
                    } else switch (param.size) {
                        1 => {
                            try code.ldrb(reg, temp, 0);
                            arg_pos += 1;
                        },
                        2 => {
                            try code.ldrh(reg, temp, 0);
                            arg_pos += 1;
                        },
                        4 => {
                            // 32-bit load zero-extends into the 64-bit register
                            try code.ldr(reg.withBitSize(4), temp, 0);
                            arg_pos += 1;
                        },
                        8 => {
                            try code.ldr(reg, temp, 0);
                            arg_pos += 1;
                        },
                        else => {
                            // Composite <= 16 bytes: load into 1-2 consecutive registers
                            try code.ldr(reg, temp, 0);
                            arg_pos += 1;
                            if (param.size > 8 and arg_pos < ArgumentRegistery.len) {
                                try code.ldr(ArgumentRegistery[arg_pos], temp, 8);
                                arg_pos += 1;
                            }
                        },
                    }
                },
                .sse => {
                    const fields = hfaFieldCount(param);
                    const elem_size = param.size / fields;
                    if (elem_size != 4 and elem_size != 8) unreachable;
                    const bits: u8 = if (elem_size == 4) 4 else 8;
                    for (0..fields) |fi| {
                        const field_off: i32 = if (param.offsets) |offs|
                            @intCast(offs[fi])
                        else
                            @intCast(fi * elem_size);
                        // w → LDR S, x → LDR D. qN.withBitSize selects that name.
                        try code.ldr_fp(FloatingPointRegistery[floating_arg_pos].withBitSize(bits), temp, field_off);
                        floating_arg_pos += 1;
                    }
                },
                .mem => unreachable, // converted to .int above
            }
        } else {
            // Spill to stack at [sp + stack_offset]. Store width must match the
            // slot: a 64-bit store of a Darwin f32 would clobber the next 4-byte arg.
            const layout = stackArgLayout(param);
            stack_offset = layout.alignment.forward(stack_offset);
            if (is_mem) {
                // Store the pointer itself, not the struct data
                try code.str(temp, .sp, @intCast(stack_offset));
            } else {
                var copied: usize = 0;
                while (copied < param.size) {
                    const remaining = param.size - copied;
                    const dst = stack_offset + copied;
                    if (remaining >= 8) {
                        try code.ldr(temp2, temp, @intCast(copied));
                        try code.str(temp2, .sp, @intCast(dst));
                        copied += 8;
                    } else if (remaining >= 4) {
                        try code.ldr(temp2.withBitSize(4), temp, @intCast(copied));
                        try code.str(temp2.withBitSize(4), .sp, @intCast(dst));
                        copied += 4;
                    } else if (remaining >= 2) {
                        try code.ldrh(temp2, temp, @intCast(copied));
                        try code.strh(temp2, .sp, @intCast(dst));
                        copied += 2;
                    } else {
                        try code.ldrb(temp2, temp, @intCast(copied));
                        try code.strb(temp2, .sp, @intCast(dst));
                        copied += 1;
                    }
                }
            }
            stack_offset += layout.size;
        }
    }

    // Call the target function
    try code.blr(fnPtr);

    // Store return value back through the return pointer
    if (return_type.size > 0 and !use_return_address) {
        switch (return_type.class) {
            .sse => {
                // One FP register per HFA member, or s0/d0 for a scalar.
                const fields = hfaFieldCount(return_type);
                const elem_size = return_type.size / fields;
                if (elem_size != 4 and elem_size != 8) unreachable;
                const bits: u8 = if (elem_size == 4) 4 else 8;
                for (0..fields) |fi| {
                    const field_off: i32 = if (return_type.offsets) |offs|
                        @intCast(offs[fi])
                    else
                        @intCast(fi * elem_size);
                    try code.str_fp(FloatingPointRegistery[fi].withBitSize(bits), retPtr, field_off);
                }
            },
            else => switch (return_type.size) {
                1 => try code.strb(.w0, retPtr, 0),
                2 => try code.strh(.w0, retPtr, 0),
                4 => try code.str(.w0, retPtr, 0),
                8 => try code.str(.x0, retPtr, 0),
                else => {
                    // 9-16 byte composite returned in x0, x1
                    try code.str(.x0, retPtr, 0);
                    if (return_type.size > 8)
                        try code.str(.x1, retPtr, 8);
                },
            },
        }
    }

    // Epilogue: restore callee-saved registers
    try code.ldr(.x21, .sp, @intCast(save_base + 32));
    try code.ldp(.x19, .x20, .sp, save_base_i32 + 16);
    try code.ldp(.x29, .x30, .sp, save_base_i32);

    // Deallocate stack frame
    {
        var remaining = total_frame;
        while (remaining > 0) {
            const chunk: u12 = @intCast(@min(remaining, 4095));
            try code.add_imm(.sp, .sp, chunk);
            remaining -= chunk;
        }
    }

    try code.ret();

    return try code.compile(allocator);
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

test "aarch64 AssemblyBuilder alu and branches" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 16);
    defer code.deinit();
    try code.ret();
    try code.blr(.x19);
    try code.br(.x16);
    try code.mov(.x19, .x0);
    try code.mov(.w2, .w3);
    try code.mov(.x0, .sp);
    try code.mov(.sp, .x0);
    try code.add(.x0, .x1, .x2);
    try code.add(.w3, .w4, .w5);
    try code.sub(.x0, .x1, .x2);
    try code.sub_imm(.sp, .sp, 16);
    try code.add_imm(.sp, .sp, 16);
    try code.lea(.x0, .x1, 4096);
    try code.lea(.x2, .x3, -8192);
    try code.bl(8);
    try code.bl(-4);
    try expectBytes(&code, &.{
        0xc0, 0x03, 0x5f, 0xd6, // ret
        0x60, 0x02, 0x3f, 0xd6, // blr x19
        0x00, 0x02, 0x1f, 0xd6, // br x16
        0xf3, 0x03, 0x00, 0xaa, // mov x19, x0
        0xe2, 0x03, 0x03, 0x2a, // mov w2, w3
        0xe0, 0x03, 0x00, 0x91, // mov x0, sp
        0x1f, 0x00, 0x00, 0x91, // mov sp, x0
        0x20, 0x00, 0x02, 0x8b, // add x0, x1, x2
        0x83, 0x00, 0x05, 0x0b, // add w3, w4, w5
        0x20, 0x00, 0x02, 0xcb, // sub x0, x1, x2
        0xff, 0x43, 0x00, 0xd1, // sub sp, sp, #16
        0xff, 0x43, 0x00, 0x91, // add sp, sp, #16
        0x20, 0x04, 0x40, 0x91, // add x0, x1, #1, lsl #12
        0x62, 0x08, 0x40, 0xd1, // sub x2, x3, #2, lsl #12
        0x02, 0x00, 0x00, 0x94, // bl #8
        0xff, 0xff, 0xff, 0x97, // bl #-4
    });
}

test "aarch64 AssemblyBuilder mov_imm" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 8);
    defer code.deinit();
    try code.mov_imm(.x0, 0x1122334455667788);
    try code.mov_imm(.x11, 0);
    try code.mov_imm(.x0, 0x10000);
    try code.mov_imm(.w0, 0x42);
    try expectBytes(&code, &.{
        0x00, 0xf1, 0x8e, 0xd2, // movz x0, #0x7788
        0xc0, 0xac, 0xaa, 0xf2, // movk x0, #0x5566, lsl #16
        0x80, 0x68, 0xc6, 0xf2, // movk x0, #0x3344, lsl #32
        0x40, 0x24, 0xe2, 0xf2, // movk x0, #0x1122, lsl #48
        0x0b, 0x00, 0x80, 0xd2, // mov x11, #0
        0x20, 0x00, 0xa0, 0xd2, // mov x0, #0x10000
        0x40, 0x08, 0x80, 0x52, // mov w0, #0x42
    });
    try std.testing.expectError(error.ImmediateOutOfRange, code.mov_imm(.w0, 0x1_0000_0000));
    try std.testing.expectError(error.UnsupportedRegisterSize, code.mov_imm(.q0, 1));
}

test "aarch64 AssemblyBuilder loads and stores" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 32);
    defer code.deinit();
    try code.ldr(.x0, .x1, 0);
    try code.ldr(.x0, .x1, 8);
    try code.ldr(.w2, .x3, 4);
    try code.str(.x21, .sp, 32);
    try code.str(.w0, .x1, 4);
    try code.ldr(.x0, .x1, -8);
    try code.str(.x0, .x1, -8);
    try code.ldr(.w2, .x3, -4);
    try code.str(.w2, .x3, 1);
    try code.ldrb(.w0, .x1, 3);
    try code.strb(.w4, .x5, 0);
    try code.ldrh(.w2, .x3, 4);
    try code.strh(.w1, .x2, 2);
    try code.ldrb(.w0, .x1, -1);
    try code.strh(.w2, .x3, -2);
    try code.ldr_fp(.w0, .x1, 0);
    try code.ldr_fp(.w0, .x1, 4);
    try code.str_fp(.x1, .x2, 8);
    try code.ldr_fp(.q0, .x1, 16);
    try code.str_fp(.w0, .x1, -4);
    try code.ldr_fp(.x0, .x2, -8);
    try code.str_fp(.q0, .x1, -16);
    try code.stp(.x29, .x30, .sp, 0);
    try code.ldp(.x19, .x20, .sp, 16);
    try code.stp(.w0, .w1, .x2, 8);
    try code.stp(.x29, .x30, .sp, -16);
    try code.stp(.x0, .x1, .x2, 504);
    try code.stp(.x0, .x1, .x2, -512);
    try code.fmov(.w0, .w1);
    try code.fmov(.x2, .x3);
    try code.fmov(.q0, .q1);
    try expectBytes(&code, &.{
        0x20, 0x00, 0x40, 0xf9, // ldr x0, [x1]
        0x20, 0x04, 0x40, 0xf9, // ldr x0, [x1, #8]
        0x62, 0x04, 0x40, 0xb9, // ldr w2, [x3, #4]
        0xf5, 0x13, 0x00, 0xf9, // str x21, [sp, #32]
        0x20, 0x04, 0x00, 0xb9, // str w0, [x1, #4]
        0x20, 0x80, 0x5f, 0xf8, // ldur x0, [x1, #-8]
        0x20, 0x80, 0x1f, 0xf8, // stur x0, [x1, #-8]
        0x62, 0xc0, 0x5f, 0xb8, // ldur w2, [x3, #-4]
        0x62, 0x10, 0x00, 0xb8, // stur w2, [x3, #1]
        0x20, 0x0c, 0x40, 0x39, // ldrb w0, [x1, #3]
        0xa4, 0x00, 0x00, 0x39, // strb w4, [x5]
        0x62, 0x08, 0x40, 0x79, // ldrh w2, [x3, #4]
        0x41, 0x04, 0x00, 0x79, // strh w1, [x2, #2]
        0x20, 0xf0, 0x5f, 0x38, // ldurb w0, [x1, #-1]
        0x62, 0xe0, 0x1f, 0x78, // sturh w2, [x3, #-2]
        0x20, 0x00, 0x40, 0xbd, // ldr s0, [x1]
        0x20, 0x04, 0x40, 0xbd, // ldr s0, [x1, #4]
        0x41, 0x04, 0x00, 0xfd, // str d1, [x2, #8]
        0x20, 0x04, 0xc0, 0x3d, // ldr q0, [x1, #16]
        0x20, 0xc0, 0x1f, 0xbc, // stur s0, [x1, #-4]
        0x40, 0x80, 0x5f, 0xfc, // ldur d0, [x2, #-8]
        0x20, 0x00, 0x9f, 0x3c, // stur q0, [x1, #-16]
        0xfd, 0x7b, 0x00, 0xa9, // stp x29, x30, [sp]
        0xf3, 0x53, 0x41, 0xa9, // ldp x19, x20, [sp, #16]
        0x40, 0x04, 0x01, 0x29, // stp w0, w1, [x2, #8]
        0xfd, 0x7b, 0x3f, 0xa9, // stp x29, x30, [sp, #-16]
        0x40, 0x84, 0x1f, 0xa9, // stp x0, x1, [x2, #504]
        0x40, 0x04, 0x20, 0xa9, // stp x0, x1, [x2, #-512]
        0x20, 0x40, 0x20, 0x1e, // fmov s0, s1
        0x62, 0x40, 0x60, 0x1e, // fmov d2, d3
        0x20, 0x1c, 0xa1, 0x4e, // mov v0.16b, v1.16b
    });
    try std.testing.expectError(error.OffsetOutOfRange, code.str(.x0, .x1, 1 << 20));
    try std.testing.expectError(error.OffsetOutOfRange, code.stp(.x0, .x1, .x2, 512));
    try std.testing.expectError(error.ImmediateOutOfRange, code.bl(2));
    try std.testing.expectError(error.UnsupportedRegisterSize, code.add(.sp, .sp, .x0));
}

test "aarch64 AssemblyBuilder stack_push_offset" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer code.deinit();
    try std.testing.expectEqual(@as(usize, 0), code.stack_push_offset);
    try code.sub_imm(.sp, .sp, 16);
    try std.testing.expectEqual(@as(usize, 16), code.stack_push_offset);
    try code.lea(.sp, .sp, -8192);
    try std.testing.expectEqual(@as(usize, 8208), code.stack_push_offset);
    try code.add_imm(.sp, .sp, 16);
    try std.testing.expectEqual(@as(usize, 8192), code.stack_push_offset);
    try code.lea(.sp, .sp, 8192);
    try std.testing.expectEqual(@as(usize, 0), code.stack_push_offset);
    // A non-SP add does not look like a frame adjustment.
    try code.add_imm(.x0, .x1, 8);
    try std.testing.expectEqual(@as(usize, 0), code.stack_push_offset);
}

test "aarch64 AssemblyBuilder encodeInto" {
    var code = try AssemblyBuilder.initCapacity(std.testing.allocator, 2);
    defer code.deinit();
    try code.ret();
    var exact: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try code.encodeInto(&exact));
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x03, 0x5f, 0xd6 }, &exact);
    var too_small: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, code.encodeInto(&too_small));

    const compiled = try code.compile(std.testing.allocator);
    defer std.testing.allocator.free(compiled);
    try std.testing.expectEqualSlices(u8, &exact, compiled);
}

test "aarch64 createStruct and createArray" {
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

    const four = try createStruct(allocator, &.{ .float32, .float32, .float32, .float32 }, null);
    defer four.free(allocator);
    try std.testing.expectEqual(common.Type.Class.sse, four.class);
    try std.testing.expectEqual(@as(usize, 16), four.size);

    const mixed = try createStruct(allocator, &.{ .int32, .float64 }, null);
    defer mixed.free(allocator);
    try std.testing.expectEqual(common.Type.Class.int, mixed.class);
    try std.testing.expectEqualSlices(usize, &.{ 0, 8 }, mixed.offsets.?);

    const big = try createStruct(allocator, &.{ .float32, .float32, .float32, .float32, .float32 }, null);
    defer big.free(allocator);
    try std.testing.expectEqual(common.Type.Class.mem, big.class);
    try std.testing.expectEqual(@as(usize, 20), big.size);

    try std.testing.expectError(error.PoorAlignment, createStruct(allocator, &.{.int64}, .@"4"));

    const two = createArray(.float32, 2);
    try std.testing.expect(two.offsets == null);
    try std.testing.expectEqual(common.Type.Class.sse, two.class);
    try std.testing.expectEqual(@as(usize, 8), two.size);
    try std.testing.expectEqual(std.mem.Alignment.@"4", two.alignment);
    try std.testing.expectEqual(@as(usize, 2), hfaFieldCount(two));
    try std.testing.expectEqual(@as(usize, 1), hfaFieldCount(.float64));
    try std.testing.expectEqual(@as(usize, 1), hfaFieldCount(.float32));
    try std.testing.expectEqual(@as(usize, 4), hfaFieldCount(createArray(.float32, 4)));
    try std.testing.expectEqual(common.Type.Class.mem, createArray(.float32, 5).class);
    try std.testing.expectEqual(common.Type.Class.int, createArray(.int32, 4).class);
    try std.testing.expectEqual(@as(usize, 16), createArray(.int32, 4).size);
    try std.testing.expectEqual(@as(usize, 0), createArray(.float64, 0).size);
}

test "aarch64 void trampoline bytes" {
    const bytes = try buildCallInvoker(std.testing.allocator, &.{}, .void);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 0xc3, 0x00, 0xd1, // sub sp, sp, #48
        0xfd, 0x7b, 0x00, 0xa9, // stp x29, x30, [sp]
        0xf3, 0x53, 0x01, 0xa9, // stp x19, x20, [sp, #16]
        0xf5, 0x13, 0x00, 0xf9, // str x21, [sp, #32]
        0xf3, 0x03, 0x00, 0xaa, // mov x19, x0
        0x60, 0x02, 0x3f, 0xd6, // blr x19
        0xf5, 0x13, 0x40, 0xf9, // ldr x21, [sp, #32]
        0xf3, 0x53, 0x41, 0xa9, // ldp x19, x20, [sp, #16]
        0xfd, 0x7b, 0x40, 0xa9, // ldp x29, x30, [sp]
        0xff, 0xc3, 0x00, 0x91, // add sp, sp, #48
        0xc0, 0x03, 0x5f, 0xd6, // ret
    }, bytes);
}

test "aarch64 i32 arg trampoline bytes" {
    const bytes = try buildCallInvoker(std.testing.allocator, &.{.int32}, .void);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 0xc3, 0x00, 0xd1, // sub sp, sp, #48
        0xfd, 0x7b, 0x00, 0xa9, // stp x29, x30, [sp]
        0xf3, 0x53, 0x01, 0xa9, // stp x19, x20, [sp, #16]
        0xf5, 0x13, 0x00, 0xf9, // str x21, [sp, #32]
        0xf3, 0x03, 0x00, 0xaa, // mov x19, x0
        0xf4, 0x03, 0x01, 0xaa, // mov x20, x1
        0x89, 0x02, 0x40, 0xf9, // ldr x9, [x20]
        0x20, 0x01, 0x40, 0xb9, // ldr w0, [x9]
        0x60, 0x02, 0x3f, 0xd6, // blr x19
        0xf5, 0x13, 0x40, 0xf9, // ldr x21, [sp, #32]
        0xf3, 0x53, 0x41, 0xa9, // ldp x19, x20, [sp, #16]
        0xfd, 0x7b, 0x40, 0xa9, // ldp x29, x30, [sp]
        0xff, 0xc3, 0x00, 0x91, // add sp, sp, #48
        0xc0, 0x03, 0x5f, 0xd6, // ret
    }, bytes);
}
