const std = @import("std");
const builtin = @import("builtin");

const common = @import("../common.zig");
const rv = @import("../asm/riscv64.zig");
const mem = @import("../mem.zig");

pub const ir = @import("ir.zig");

const code_body = @import("body.zig");

pub const Value = ir.Value;

pub const AssemblyBuilder = rv.AssemblyBuilder;
const Register = AssemblyBuilder.Register;

const gp_regs = rv.ArgumentRegistery;
const fp_regs = rv.FloatingPointRegistery;

// User values live only in a0–a7 and fa0–fa7. t0/t1 may hold a value and must
// be spilled before reuse. t2 builds an out-of-range address, t6 is the
// indirect callee, ft0 is the FP scratch: none of those three is a binding.
const fp_reg = Register.s0;
const tmp_ptr = Register.t0;
const tmp = Register.t1;
const callee_reg = Register.t6;
const addr_tmp = Register.t2;
const fp_tmp = Register.ft0;

/// Where an outgoing or incoming argument sits. `spilled` in `classify` is
/// separate: an HFA that misses `fa` and fits in `a` is `fp_in_gp`, not a spill.
const Place = union(enum) {
    gp: struct { base: usize, n: usize },
    fp: struct { base: usize, n: usize },
    /// One GPR per HFA field (`fmv.x` / `lw`/`ld` of the bits). Not a stack spill,
    /// so later arguments may still use leftover `fa` or `a` registers.
    fp_in_gp: struct { base: usize, n: usize },
    /// Integer aggregate that filled the remaining GPRs and continued on the stack.
    /// Only legal before the first spill. The stack tail is `stack_words` slots.
    split: struct { gp_base: usize, gp_n: usize, stack: usize, stack_words: usize },
    /// One FP real and one integer real, each in its own register. Field order
    /// lives on the type (`fpccMixed`). Missing either register falls back to
    /// the integer memory image and does not by itself set `spilled`.
    mixed: struct { gp: usize, fp: usize },
    stack: usize,
};

fn intWords(size: usize) usize {
    if (size == 0) return 1;
    return (size + 7) / 8;
}

fn wordBytes(ty: common.Type, word: usize) usize {
    if (ty.size == 0) return 8;
    const start = word * 8;
    if (start >= ty.size) return 0;
    return @min(8, ty.size - start);
}

/// `.mem` or larger than 16 bytes is one pointer. Same predicate for arguments
/// and results: the hidden result pointer is `a0` and shifts later GPRs.
pub fn needsByPointer(ty: common.Type) bool {
    return ty.class == .mem or ty.size > 16;
}

pub fn isMemoryClass(ty: common.Type) bool {
    return needsByPointer(ty);
}

pub fn isStructureReturn(ty: common.Type) bool {
    if (ty.size == 0) return false;
    return needsByPointer(ty);
}

/// No return address and no red zone. At entry, stack arguments are at [sp].
/// After the prologue, `s0` is that entry SP, so the same slots are [s0 + off].
pub fn incomingStackBase() comptime_int {
    return 0;
}

fn stackBytes(ty: common.Type) usize {
    if (needsByPointer(ty)) return 8;
    return intWords(ty.size) * 8;
}

/// `{f32,f32}` is one 8-byte chunk if you ask `eightbyte`, and two FP registers
/// here. Only call this for `.sse` (a non-sse value with offsets reports the
/// field count, which is not an HFA width).
fn hfaCount(ty: common.Type) usize {
    return rv.hfaFieldCount(ty);
}

fn fieldSize(ty: common.Type, field_index: usize) usize {
    if (ty.field_sizes) |sizes| {
        if (field_index < sizes.len) return sizes[field_index];
    }
    const n = hfaCount(ty);
    if (n == 0) return @max(ty.size, 1);
    const sz = ty.size / n;
    return if (sz == 0) 1 else sz;
}

/// LP64D float+int pair. `class` stays `.int`. The eightbyte slots are the
/// two member classes, and `field_sizes` is the real width (the gap in
/// `{i32,f64}` is padding, not part of the int).
const FpccMixed = struct {
    float_index: usize,
    int_index: usize,
    float_size: usize,
    int_size: usize,
};

fn fpccMixed(ty: common.Type) ?FpccMixed {
    if (ty.class != .int or needsByPointer(ty)) return null;
    const sizes = ty.field_sizes orelse return null;
    if (sizes.len != 2) return null;
    const float_index: usize = switch (ty.eightbytes.low) {
        .sse => if (ty.eightbytes.high == .int) 0 else return null,
        .int => if (ty.eightbytes.high == .sse) 1 else return null,
        else => return null,
    };
    const int_index = 1 - float_index;
    return .{
        .float_index = float_index,
        .int_index = int_index,
        .float_size = sizes[float_index],
        .int_size = sizes[int_index],
    };
}

fn fieldOff(ty: common.Type, field_index: usize) i32 {
    const n = hfaCount(ty);
    const elem: usize = if (n == 0) 0 else ty.size / n;
    return @intCast(rv.hfaFieldOffset(ty, field_index, elem));
}

/// A value that cannot stay in one register. Two f32 fields are 8 bytes and
/// still need a home: each field has its own register. `{f32,i32}` is also
/// 8 bytes and still two registers, so it is an object too.
pub fn isObject(ty: common.Type) bool {
    if (ty.class == .mem or ty.size > 8) return true;
    if (fpccMixed(ty) != null) return true;
    if (ty.class == .sse) return hfaCount(ty) > 1;
    return false;
}

fn fitsI12(imm: i64) bool {
    return imm >= -2048 and imm <= 2047;
}

/// LP64D. `sret` consumes `a0`. An HFA is never split across `fa`, `a`, and
/// memory. FP-to-GP overflow is not a spill. A float+int pair takes one `fa`
/// and one `a` when both are free; if either is missing, the pair uses the
/// integer memory image and that miss does not set `spilled`. Once any part
/// of an argument lands on the stack, later integer and FP arguments go
/// entirely to the stack.
pub fn classify(args: []const common.Type, sret: bool) [32]Place {
    var places: [32]Place = undefined;
    std.debug.assert(args.len <= places.len);

    var gp: usize = if (sret) 1 else 0;
    var fp: usize = 0;
    var stack: usize = 0;
    var spilled = false;

    for (args, 0..) |arg, i| {
        if (needsByPointer(arg)) {
            if (!spilled and gp < gp_regs.len) {
                places[i] = .{ .gp = .{ .base = gp, .n = 1 } };
                gp += 1;
            } else {
                places[i] = .{ .stack = stack };
                stack += 8;
                spilled = true;
            }
            continue;
        }
        if (arg.class == .sse) {
            const n = hfaCount(arg);
            if (!spilled and fp + n <= fp_regs.len) {
                places[i] = .{ .fp = .{ .base = fp, .n = n } };
                fp += n;
            } else if (!spilled and gp + n <= gp_regs.len) {
                places[i] = .{ .fp_in_gp = .{ .base = gp, .n = n } };
                gp += n;
            } else {
                places[i] = .{ .stack = stack };
                stack += stackBytes(arg);
                spilled = true;
            }
            continue;
        }
        // Both files must be free. A miss is not a spill: the integer path
        // below may still place the memory image in GPRs.
        if (!spilled and fpccMixed(arg) != null and fp < fp_regs.len and gp < gp_regs.len) {
            places[i] = .{ .mixed = .{ .gp = gp, .fp = fp } };
            gp += 1;
            fp += 1;
            continue;
        }
        const words = intWords(arg.size);
        if (!spilled and gp + words <= gp_regs.len) {
            places[i] = .{ .gp = .{ .base = gp, .n = words } };
            gp += words;
        } else if (!spilled and gp < gp_regs.len) {
            const gp_n = gp_regs.len - gp;
            const stack_words = words - gp_n;
            places[i] = .{ .split = .{
                .gp_base = gp,
                .gp_n = gp_n,
                .stack = stack,
                .stack_words = stack_words,
            } };
            stack += stack_words * 8;
            gp = gp_regs.len;
            spilled = true;
        } else {
            places[i] = .{ .stack = stack };
            stack += stackBytes(arg);
            spilled = true;
        }
    }
    return places;
}

pub fn outgoingBytes(args: []const common.Type, places: []const Place, sret: bool) u32 {
    _ = sret;
    var stack_end: usize = 0;
    for (args, 0..) |arg, i| {
        switch (places[i]) {
            .stack => |off| stack_end = @max(stack_end, off + stackBytes(arg)),
            .split => |s| stack_end = @max(stack_end, s.stack + s.stack_words * 8),
            .gp, .fp, .fp_in_gp, .mixed => {},
        }
    }
    return @intCast(std.mem.Alignment.@"16".forward(stack_end));
}

pub const Code = code_body.Code(@This());

const Where = union(enum) {
    none,
    gp: Register,
    fp: Register,
    stack: i32,
};

pub const Slot = struct {
    where: Where = .none,
    home: ?i32 = null,
    type: common.Type,
    is_object: bool = false,
};

pub const Lower = struct {
    assembler: *AssemblyBuilder,
    slots: []Slot,
    last: []const u32,
    instruction_idx: u32 = 0,
    /// Bytes below `s0`. Starts at -16 so the first home does not cover the
    /// saved `ra`/`s0` pair at [s0-16, s0).
    local_offset: i32 = -16,

    fn liveAfter(self: Lower, v: ir.VReg) bool {
        return self.last[v.int()] > self.instruction_idx and self.last[v.int()] != ir.no_use;
    }

    fn liveHere(self: Lower, v: ir.VReg) bool {
        return self.last[v.int()] >= self.instruction_idx and self.last[v.int()] != ir.no_use;
    }

    fn used(self: Lower, v: ir.VReg) bool {
        return self.last[v.int()] != ir.no_use;
    }

    fn allocHome(self: *Lower, ty: common.Type) i32 {
        const size: usize = if (ty.size == 0) 8 else @max(ty.size, 8);
        const alignment = ty.alignment.max(.@"8");
        var next = @as(usize, @intCast(-self.local_offset)) + size;
        next = alignment.forward(next);
        self.local_offset = -@as(i32, @intCast(next));
        return self.local_offset;
    }

    fn ensureHome(self: *Lower, v: ir.VReg) i32 {
        if (self.slots[v.int()].home) |h| return h;
        const h = self.allocHome(self.slots[v.int()].type);
        self.slots[v.int()].home = h;
        return h;
    }

    fn frameBytes(self: *const Lower) i64 {
        const bytes: usize = @intCast(-self.local_offset);
        return @intCast(std.mem.Alignment.@"16".forward(bytes));
    }

    fn occupantGp(self: *const Lower, reg: Register) ?ir.VReg {
        for (self.slots, 0..) |s, i| {
            switch (s.where) {
                .gp => |r| if (r == reg) return .fromInt(@intCast(i)),
                else => {},
            }
        }
        return null;
    }

    fn occupantFp(self: *const Lower, reg: Register) ?ir.VReg {
        for (self.slots, 0..) |s, i| {
            switch (s.where) {
                .fp => |r| if (r == reg) return .fromInt(@intCast(i)),
                else => {},
            }
        }
        return null;
    }

    fn takeGp(self: *Lower, reg: Register) !void {
        if (self.occupantGp(reg)) |v| {
            if (self.liveHere(v))
                try self.spill(v)
            else
                self.slots[v.int()].where = .none;
        }
    }

    fn takeFp(self: *Lower, reg: Register) !void {
        if (self.occupantFp(reg)) |v| {
            if (self.liveHere(v))
                try self.spill(v)
            else
                self.slots[v.int()].where = .none;
        }
    }

    fn bindGp(self: *Lower, v: ir.VReg, reg: Register) void {
        if (self.occupantGp(reg)) |old| {
            if (old != v) self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .gp = reg };
    }

    fn bindFp(self: *Lower, v: ir.VReg, reg: Register) void {
        if (self.occupantFp(reg)) |old| {
            if (old != v) self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .fp = reg };
    }

    fn gpCopy(self: *Lower, dest: Register, src: Register) !void {
        if (dest == src) return;
        try self.assembler.mv(dest, src);
    }

    fn spill(self: *Lower, v: ir.VReg) !void {
        const home = self.ensureHome(v);
        const ty = self.slots[v.int()].type;
        switch (self.slots[v.int()].where) {
            .gp => |r| {
                if (ty.class == .sse and !needsByPointer(ty)) {
                    if (ty.size <= 4)
                        try self.assembler.fmv_w_x(fp_tmp, r)
                    else
                        try self.assembler.fmv_d_x(fp_tmp, r);
                    try self.storeFp(fp_reg, home, fp_tmp, @max(ty.size, 1));
                } else {
                    try self.storeRegBytes(fp_reg, home, r, @max(@min(ty.size, 8), 1));
                }
            },
            .fp => |r| try self.storeFp(fp_reg, home, r, @max(ty.size, 1)),
            .stack, .none => {},
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn spillLiveAcrossCall(self: *Lower) !void {
        for (self.slots, 0..) |s, i| {
            const v: ir.VReg = .fromInt(@intCast(i));
            if (!self.liveAfter(v)) continue;
            switch (s.where) {
                .gp, .fp => try self.spill(v),
                else => {},
            }
        }
    }

    fn spillIfLive(self: *Lower, reg: Register, fp: bool) !void {
        const occ = if (fp) self.occupantFp(reg) else self.occupantGp(reg);
        if (occ) |v| {
            if (self.liveHere(v)) try self.spill(v);
        }
    }

    /// Map-only. Physical `a0`/`fa0` still hold the call result until
    /// `bindCallResult` reads them.
    fn clobberCallerSaved(self: *Lower) void {
        for (self.slots) |*s| {
            switch (s.where) {
                .gp, .fp => s.where = if (s.home) |h| .{ .stack = h } else .none,
                else => {},
            }
        }
    }

    pub fn bindIncoming(
        self: *Lower,
        param_types: []const common.Type,
        param_values: []const Value,
        sret_vreg: ?ir.VReg,
        sret: bool,
    ) !void {
        const places = classify(param_types, sret);
        if (sret_vreg) |v| self.bindGp(v, .a0);

        for (param_types, 0..) |ty, i| {
            const v = param_values[i].location.virtual;
            if (!self.used(v)) continue;
            const by_ptr = needsByPointer(ty);
            switch (places[i]) {
                .gp => |g| {
                    if (by_ptr or (!self.slots[v.int()].is_object and g.n == 1)) {
                        self.bindGp(v, gp_regs[g.base]);
                        if (by_ptr) self.slots[v.int()].is_object = false;
                    } else {
                        try self.parkGpWords(v, ty, g.base, g.n);
                    }
                },
                .fp => |f| {
                    if (!self.slots[v.int()].is_object and f.n == 1) {
                        self.bindFp(v, fp_regs[f.base]);
                    } else {
                        try self.parkFp(v, ty, f.base, f.n);
                    }
                },
                .fp_in_gp => |f| {
                    if (f.n == 1) {
                        self.bindGp(v, gp_regs[f.base]);
                    } else {
                        try self.parkFpBits(v, ty, f.base, f.n);
                    }
                },
                .mixed => |m| try self.parkMixed(v, ty, m),
                .split => |s| try self.parkSplit(v, ty, s),
                .stack => |off| {
                    const disp: i32 = @intCast(incomingStackBase() + off);
                    self.slots[v.int()].home = disp;
                    self.slots[v.int()].where = .{ .stack = disp };
                    if (by_ptr) self.slots[v.int()].is_object = false;
                },
            }
        }
    }

    fn parkGpWords(self: *Lower, v: ir.VReg, ty: common.Type, base: usize, n: usize) !void {
        const home = self.ensureHome(v);
        self.slots[v.int()].is_object = true;
        for (0..n) |w| {
            const disp = home + @as(i32, @intCast(w * 8));
            try self.storeRegBytes(fp_reg, disp, gp_regs[base + w], wordBytes(ty, w));
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn parkFp(self: *Lower, v: ir.VReg, ty: common.Type, base: usize, n: usize) !void {
        const home = self.ensureHome(v);
        self.slots[v.int()].is_object = true;
        for (0..n) |w| {
            try self.storeFp(fp_reg, home + fieldOff(ty, w), fp_regs[base + w], fieldSize(ty, w));
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn parkFpBits(self: *Lower, v: ir.VReg, ty: common.Type, base: usize, n: usize) !void {
        const home = self.ensureHome(v);
        self.slots[v.int()].is_object = true;
        for (0..n) |w| {
            const sz = fieldSize(ty, w);
            if (sz <= 4)
                try self.assembler.fmv_w_x(fp_tmp, gp_regs[base + w])
            else
                try self.assembler.fmv_d_x(fp_tmp, gp_regs[base + w]);
            try self.storeFp(fp_reg, home + fieldOff(ty, w), fp_tmp, sz);
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    /// Float and int land at their field offsets, not packed into one XLEN word.
    /// `{f32,i32}` is `fsw` at 0 and `sw` at 4. Padding between `{i32,f64}` is left
    /// untouched; the psABI leaves those bits unspecified.
    fn parkMixed(self: *Lower, v: ir.VReg, ty: common.Type, m: @FieldType(Place, "mixed")) !void {
        const info = fpccMixed(ty).?;
        const home = self.ensureHome(v);
        self.slots[v.int()].is_object = true;
        try self.storeFp(fp_reg, home + fieldOff(ty, info.float_index), fp_regs[m.fp], info.float_size);
        try self.storeRegBytes(fp_reg, home + fieldOff(ty, info.int_index), gp_regs[m.gp], info.int_size);
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn parkSplit(self: *Lower, v: ir.VReg, ty: common.Type, s: @FieldType(Place, "split")) !void {
        const home = self.ensureHome(v);
        self.slots[v.int()].is_object = true;
        for (0..s.gp_n) |w| {
            const disp = home + @as(i32, @intCast(w * 8));
            try self.storeRegBytes(fp_reg, disp, gp_regs[s.gp_base + w], wordBytes(ty, w));
        }
        for (0..s.stack_words) |w| {
            const word = s.gp_n + w;
            const chunk = wordBytes(ty, word);
            const src: i32 = @intCast(incomingStackBase() + s.stack + w * 8);
            const dst = home + @as(i32, @intCast(word * 8));
            try self.copyMem(fp_reg, src, fp_reg, dst, chunk);
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    pub fn emitInst(self: *Lower, inst: ir.Inst) !void {
        switch (inst) {
            .allocate => |i| {
                const home = self.ensureHome(i.destination);
                self.slots[i.destination.int()].is_object = true;
                self.slots[i.destination.int()].where = .{ .stack = home };
            },
            .address_of => |i| {
                const disp = try self.ensureInMemory(i.source);
                try self.takeGp(tmp_ptr);
                try self.assembler.addImm(tmp_ptr, fp_reg, disp, tmp);
                self.bindGp(i.destination, tmp_ptr);
            },
            .load => |i| try self.emitLoad(i.destination, i.pointer, i.offset, i.type),
            .store => |i| {
                try self.takeGp(tmp_ptr);
                try self.loadRefTo(tmp_ptr, i.pointer);
                try self.copyRefToMem(i.source, i.type, tmp_ptr, i.offset);
            },
            .load_effective_address => |i| {
                try self.loadRefTo(tmp, i.base);
                try self.takeGp(tmp_ptr);
                try self.assembler.addImm(tmp_ptr, tmp, i.offset, addr_tmp);
                self.bindGp(i.destination, tmp_ptr);
            },
            .call => |c| try self.emitCall(c),
        }
    }

    fn emitCall(self: *Lower, c: ir.Inst.Call) !void {
        // Callee first: it may sit in t0, and the next step spills t0.
        try self.materializeCallee(c.callee);
        try self.spillLiveAcrossCall();
        // `adjustSp` clobbers t0 when the delta does not fit i12. An sret
        // pointer whose last use is this call is not live-after, so the
        // live-across pass leaves it in t0.
        try self.spillIfLive(tmp_ptr, false);
        try self.spillIfLive(tmp, false);
        try self.spillIfLive(fp_tmp, true);

        var arg_types: [32]common.Type = undefined;
        for (c.arguments, 0..) |arg, i| arg_types[i] = arg.type;
        const sret = c.structure_return_dest != null and isStructureReturn(c.return_type);
        const places = classify(arg_types[0..c.arguments.len], sret);
        const outgoing = outgoingBytes(arg_types[0..c.arguments.len], places[0..c.arguments.len], sret);

        if (outgoing > 0) try self.adjustSp(outgoing, true);
        if (sret) try self.loadRefTo(.a0, c.structure_return_dest.?);
        for (c.arguments, 0..) |arg, i|
            try self.marshalArg(arg, places[i]);

        try self.assembler.jalr(.ra, callee_reg, 0);
        if (outgoing > 0) try self.adjustSp(outgoing, false);

        self.clobberCallerSaved();
        if (c.destination) |dst| try self.bindCallResult(dst, c.return_type);
    }

    fn materializeCallee(self: *Lower, callee: ir.Callee) !void {
        switch (callee) {
            .immediate => |p| {
                try self.takeGp(callee_reg);
                try self.assembler.li(callee_reg, @intCast(@intFromPtr(p)));
            },
            .virtual => |v| try self.loadVregToGp(callee_reg, v, 0),
        }
    }

    fn marshalArg(self: *Lower, arg: ir.Arg, place: Place) !void {
        const by_ptr = needsByPointer(arg.type);
        switch (place) {
            .gp => |g| {
                if (by_ptr) {
                    try self.loadArgPointer(gp_regs[g.base], arg);
                    return;
                }
                for (0..g.n) |w|
                    try self.loadMemberToGp(gp_regs[g.base + w], arg, w);
            },
            .fp => |f| {
                for (0..f.n) |w|
                    try self.loadMemberToFp(fp_regs[f.base + w], arg, w);
            },
            .fp_in_gp => |f| {
                for (0..f.n) |w|
                    try self.loadFpBitsToGp(gp_regs[f.base + w], arg, w);
            },
            .mixed => |m| {
                const info = fpccMixed(arg.type).?;
                try self.loadMemberToFp(fp_regs[m.fp], arg, info.float_index);
                try self.loadIntField(gp_regs[m.gp], arg, info.int_index);
            },
            .split => |s| {
                for (0..s.gp_n) |w|
                    try self.loadMemberToGp(gp_regs[s.gp_base + w], arg, w);
                for (0..s.stack_words) |w| {
                    try self.loadMemberToGp(tmp, arg, s.gp_n + w);
                    const disp: i32 = @intCast(s.stack + w * 8);
                    try self.storeSized(.sp, disp, tmp, 8);
                }
            },
            .stack => |off| {
                const disp: i32 = @intCast(off);
                if (by_ptr) {
                    try self.loadArgPointer(tmp, arg);
                    try self.storeSized(.sp, disp, tmp, 8);
                    return;
                }
                if (arg.type.class == .sse) {
                    try self.marshalFpStack(arg, disp);
                    return;
                }
                const n = intWords(arg.type.size);
                for (0..n) |w| {
                    try self.loadMemberToGp(tmp, arg, w);
                    try self.storeSized(.sp, disp + @as(i32, @intCast(w * 8)), tmp, 8);
                }
            },
        }
    }

    /// Size 4 is `fsw` into an 8-byte slot. A wider HFA is an `fld`/`fsd` image
    /// (`{f32,f32}` is one 8-byte store, not two padded slots).
    fn marshalFpStack(self: *Lower, arg: ir.Arg, disp: i32) !void {
        const ty = arg.type;
        if (ty.size == 4) {
            try self.loadMemberToFp(fp_tmp, arg, 0);
            try self.storeFp(.sp, disp, fp_tmp, 4);
            return;
        }
        if (!isObject(ty)) {
            try self.loadMemberToFp(fp_tmp, arg, 0);
            try self.storeFp(.sp, disp, fp_tmp, 8);
            return;
        }
        switch (arg.ref) {
            .virtual => |v| {
                const home = try self.ensureInMemory(v);
                const n = intWords(ty.size);
                for (0..n) |w| {
                    const off: i32 = @intCast(w * 8);
                    try self.loadFp(fp_tmp, fp_reg, home + off, 8);
                    try self.storeFp(.sp, disp + off, fp_tmp, 8);
                }
            },
            else => {
                const n = hfaCount(ty);
                for (0..n) |w| {
                    try self.loadMemberToFp(fp_tmp, arg, w);
                    try self.storeFp(.sp, disp + fieldOff(ty, w), fp_tmp, fieldSize(ty, w));
                }
            },
        }
    }

    fn loadArgPointer(self: *Lower, dest: Register, arg: ir.Arg) !void {
        switch (arg.ref) {
            .virtual => |v| {
                // By-pointer params are retyped to `.pointer` in `Code.init`.
                // A `.mem` object still has its own type and needs its address.
                if (!needsByPointer(self.slots[v.int()].type)) {
                    try self.loadVregToGp(dest, v, 0);
                    return;
                }
                const disp = try self.ensureInMemory(v);
                try self.takeGp(dest);
                try self.assembler.addImm(dest, fp_reg, disp, tmp_ptr);
            },
            else => try self.loadRefTo(dest, arg.ref),
        }
    }

    fn bindCallResult(self: *Lower, dst: ir.VReg, ty: common.Type) !void {
        if (isStructureReturn(ty)) return;
        self.slots[dst.int()].type = ty;
        // A float+int result uses fa0 and a0, the same registers as the first
        // named argument. `sret` never reaches here.
        if (fpccMixed(ty) != null) {
            try self.parkMixed(dst, ty, .{ .gp = 0, .fp = 0 });
            return;
        }
        if (isObject(ty)) {
            if (ty.class == .sse)
                try self.parkFp(dst, ty, 0, hfaCount(ty))
            else
                try self.parkGpWords(dst, ty, 0, intWords(ty.size));
            return;
        }
        if (ty.class == .sse) {
            self.bindFp(dst, .fa0);
            return;
        }
        self.bindGp(dst, .a0);
    }

    fn emitLoad(self: *Lower, dst: ir.VReg, ptr: ir.Ref, off: i32, ty: common.Type) !void {
        try self.takeGp(tmp_ptr);
        try self.loadRefTo(tmp_ptr, ptr);
        self.slots[dst.int()].type = ty;
        if (isObject(ty)) {
            const home = self.ensureHome(dst);
            self.slots[dst.int()].is_object = true;
            try self.copyMem(tmp_ptr, off, fp_reg, home, @max(ty.size, 1));
            self.slots[dst.int()].where = .{ .stack = home };
        } else if (ty.class == .sse) {
            try self.loadFp(.fa0, tmp_ptr, off, @max(ty.size, 1));
            self.bindFp(dst, .fa0);
        } else {
            try self.loadIntegerWord(tmp, tmp_ptr, off, @max(ty.size, 1));
            self.bindGp(dst, tmp);
        }
    }

    pub fn emitReturn(self: *Lower, return_type: common.Type, ret: ?Value, sret_vreg: ?ir.VReg) !void {
        if (return_type.size == 0) return;
        const v = ret.?;
        if (isStructureReturn(return_type)) {
            const dest = sret_vreg orelse return error.MissingReturnValue;
            // `copyMem` bounces bytes through t1, so the destination pointer
            // stays in t0. `rawAddr` does not write t0 when the base is t0.
            try self.loadVregToGp(tmp_ptr, dest, 0);
            try self.copyRefToMem(v.location, v.type, tmp_ptr, 0);
            try self.takeGp(.a0);
            try self.gpCopy(.a0, tmp_ptr);
            return;
        }
        try self.loadValueToReturnRegs(v);
    }

    fn loadValueToReturnRegs(self: *Lower, v: Value) !void {
        const arg: ir.Arg = .{ .ref = v.location, .type = v.type };
        if (fpccMixed(v.type)) |info| {
            try self.loadMemberToFp(.fa0, arg, info.float_index);
            try self.loadIntField(.a0, arg, info.int_index);
            return;
        }
        if (v.type.class == .sse and !needsByPointer(v.type)) {
            const n = hfaCount(v.type);
            for (0..n) |w| try self.loadMemberToFp(fp_regs[w], arg, w);
            return;
        }
        const n = intWords(v.type.size);
        for (0..n) |w| try self.loadMemberToGp(gp_regs[w], arg, w);
    }

    /// `s0` becomes the entry SP. Saved `ra`/`s0` occupy [s0-16, s0). Homes
    /// are negative displacements below that. Prologue and epilogue call
    /// `addImm` directly: `takeGp` would emit a spill before `s0` exists.
    pub fn wrapFrame(self: *Lower) !void {
        const a = self.assembler.allocator;
        const emitted = try self.assembler.array.toOwnedSlice(a);
        defer a.free(emitted);

        self.assembler.array = try std.ArrayList(AssemblyBuilder.Instruction).initCapacity(a, emitted.len + 16);
        const frame = self.frameBytes();
        try self.assembler.addImm(.sp, .sp, -frame, tmp_ptr);
        try self.accessFrameSlot(frame, false);
        try self.assembler.addImm(fp_reg, .sp, frame, tmp_ptr);
        try self.assembler.appendInsnSlice(emitted);
        try self.accessFrameSlot(frame, true);
        try self.assembler.addImm(.sp, .sp, frame, tmp_ptr);
        try self.assembler.ret();
    }

    fn accessFrameSlot(self: *Lower, frame: i64, do_load: bool) !void {
        const ra_off = frame - 8;
        if (ra_off <= 2047) {
            const hi: i32 = @intCast(ra_off);
            const lo: i32 = @intCast(frame - 16);
            if (do_load) {
                try self.assembler.ld(.ra, .sp, hi);
                try self.assembler.ld(fp_reg, .sp, lo);
            } else {
                try self.assembler.sd(.ra, .sp, hi);
                try self.assembler.sd(fp_reg, .sp, lo);
            }
            return;
        }
        try self.assembler.addImm(addr_tmp, .sp, ra_off, tmp_ptr);
        if (do_load) {
            try self.assembler.ld(.ra, addr_tmp, 0);
            try self.assembler.ld(fp_reg, addr_tmp, -8);
        } else {
            try self.assembler.sd(.ra, addr_tmp, 0);
            try self.assembler.sd(fp_reg, addr_tmp, -8);
        }
    }

    fn adjustSp(self: *Lower, bytes: u32, subtract: bool) !void {
        if (bytes == 0) return;
        const imm: i64 = if (subtract) -@as(i64, bytes) else @as(i64, bytes);
        if (!fitsI12(imm)) try self.takeGp(tmp_ptr);
        try self.assembler.addImm(.sp, .sp, imm, tmp_ptr);
    }

    fn ensureInMemory(self: *Lower, v: ir.VReg) !i32 {
        switch (self.slots[v.int()].where) {
            .stack => |d| return d,
            else => {
                try self.spill(v);
                return self.slots[v.int()].home.?;
            },
        }
    }

    fn loadRefTo(self: *Lower, dest: Register, ref: ir.Ref) !void {
        switch (ref) {
            .virtual => |v| try self.loadVregToGp(dest, v, 0),
            .immediate => |b| {
                try self.takeGp(dest);
                try self.assembler.li(dest, b);
            },
            .pointer => |p| {
                try self.takeGp(dest);
                try self.assembler.li(dest, @intCast(@intFromPtr(p)));
            },
        }
    }

    fn loadVregToGp(self: *Lower, dest: Register, v: ir.VReg, word: usize) !void {
        const ty = self.slots[v.int()].type;
        const as_bits = ty.class == .sse and !needsByPointer(ty);
        const already = word == 0 and switch (self.slots[v.int()].where) {
            .gp => |r| r == dest,
            else => false,
        };
        if (!already) try self.takeGp(dest);
        switch (self.slots[v.int()].where) {
            .gp => |r| {
                std.debug.assert(word == 0);
                try self.gpCopy(dest, r);
            },
            .fp => |r| {
                std.debug.assert(word == 0);
                if (ty.size <= 4)
                    try self.assembler.fmv_x_w(dest, r)
                else
                    try self.assembler.fmv_x_d(dest, r);
            },
            .stack => |d| {
                if (as_bits) {
                    const sz = fieldSize(ty, word);
                    const disp = d + fieldOff(ty, word);
                    // `lw` sign-extends bit 31, matching `fmv.x.w`.
                    if (sz <= 4)
                        try self.loadSized(dest, fp_reg, disp, 4)
                    else
                        try self.loadSized(dest, fp_reg, disp, 8);
                } else {
                    const disp = d + @as(i32, @intCast(word * 8));
                    try self.loadIntegerWordNoTake(dest, fp_reg, disp, wordBytes(ty, word));
                }
            },
            .none => {
                std.debug.assert(self.used(v));
                try self.spill(v);
                try self.loadVregToGp(dest, v, word);
            },
        }
    }

    /// Integer member of a float+int pair. The slot is the field width at the
    /// field offset, not an XLEN word: `{f32,i32}` keeps the int at byte 4.
    fn loadIntField(self: *Lower, dest: Register, arg: ir.Arg, field_index: usize) !void {
        const sz = fieldSize(arg.type, field_index);
        const add = fieldOff(arg.type, field_index);
        switch (arg.ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .stack => |d| try self.loadIntegerWord(dest, fp_reg, d + add, sz),
                else => unreachable,
            },
            else => unreachable,
        }
    }

    fn loadMemberToGp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        if (arg.type.class == .sse and !needsByPointer(arg.type)) {
            try self.loadFpBitsToGp(dest, arg, word);
            return;
        }
        switch (arg.ref) {
            .virtual => |v| try self.loadVregToGp(dest, v, word),
            .immediate => |bits| {
                std.debug.assert(word == 0);
                try self.takeGp(dest);
                try self.assembler.li(dest, bits);
            },
            .pointer => |p| {
                std.debug.assert(word == 0);
                try self.takeGp(dest);
                try self.assembler.li(dest, @intCast(@intFromPtr(p)));
            },
        }
    }

    fn loadFpBitsToGp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        switch (arg.ref) {
            .virtual => |v| try self.loadVregToGp(dest, v, word),
            .immediate => |bits| {
                std.debug.assert(word == 0);
                try self.takeGp(dest);
                try self.assembler.li(dest, bits);
            },
            .pointer => unreachable,
        }
    }

    fn loadMemberToFp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        const size = fieldSize(arg.type, word);
        const add = fieldOff(arg.type, word);
        switch (arg.ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .fp => |r| {
                    std.debug.assert(word == 0);
                    try self.fpCopy(dest, r, size);
                },
                .stack => |d| try self.loadFp(dest, fp_reg, d + add, size),
                .gp => |r| {
                    std.debug.assert(word == 0);
                    try self.takeFp(dest);
                    if (size <= 4)
                        try self.assembler.fmv_w_x(dest, r)
                    else
                        try self.assembler.fmv_d_x(dest, r);
                },
                .none => {
                    try self.spill(v);
                    try self.loadMemberToFp(dest, arg, word);
                },
            },
            .immediate => |bits| {
                try self.takeFp(dest);
                try self.takeGp(tmp_ptr);
                try self.assembler.li(tmp_ptr, bits);
                if (size <= 4)
                    try self.assembler.fmv_w_x(dest, tmp_ptr)
                else
                    try self.assembler.fmv_d_x(dest, tmp_ptr);
            },
            .pointer => unreachable,
        }
    }

    /// No scalar FP move in this assembler. Bounce through `t0`.
    fn fpCopy(self: *Lower, dest: Register, src: Register, size: usize) !void {
        if (dest == src) return;
        try self.takeFp(dest);
        try self.takeGp(tmp_ptr);
        if (size <= 4) {
            try self.assembler.fmv_x_w(tmp_ptr, src);
            try self.assembler.fmv_w_x(dest, tmp_ptr);
        } else {
            try self.assembler.fmv_x_d(tmp_ptr, src);
            try self.assembler.fmv_d_x(dest, tmp_ptr);
        }
    }

    fn copyMem(self: *Lower, src_base: Register, src_off: i32, dst_base: Register, dst_off: i32, size: usize) !void {
        std.debug.assert(src_base != tmp and dst_base != tmp);
        try self.takeGp(tmp);
        var done: usize = 0;
        while (done < size) {
            const left = size - done;
            const chunk: usize = if (left >= 8) 8 else if (left >= 4) 4 else if (left >= 2) 2 else 1;
            const sd = src_off + @as(i32, @intCast(done));
            const dd = dst_off + @as(i32, @intCast(done));
            try self.loadSized(tmp, src_base, sd, chunk);
            try self.storeSized(dst_base, dd, tmp, chunk);
            done += chunk;
        }
    }

    fn copyRefToMem(self: *Lower, ref: ir.Ref, ty: common.Type, dst_base: Register, dst_off: i32) !void {
        switch (ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .stack => |d| try self.copyMem(fp_reg, d, dst_base, dst_off, @max(ty.size, 1)),
                .gp => |r| {
                    if (ty.class == .sse and !needsByPointer(ty) and ty.size <= 8) {
                        if (ty.size <= 4)
                            try self.assembler.fmv_w_x(fp_tmp, r)
                        else
                            try self.assembler.fmv_d_x(fp_tmp, r);
                        try self.storeFp(dst_base, dst_off, fp_tmp, @max(ty.size, 1));
                        return;
                    }
                    if (ty.size > 8) {
                        try self.spill(v);
                        try self.copyRefToMem(ref, ty, dst_base, dst_off);
                        return;
                    }
                    try self.storeRegBytes(dst_base, dst_off, r, @max(ty.size, 1));
                },
                .fp => |r| {
                    if (ty.size > 8) {
                        try self.spill(v);
                        try self.copyRefToMem(ref, ty, dst_base, dst_off);
                        return;
                    }
                    try self.storeFp(dst_base, dst_off, r, @max(ty.size, 1));
                },
                .none => {
                    try self.spill(v);
                    try self.copyRefToMem(ref, ty, dst_base, dst_off);
                },
            },
            .immediate => |bits| {
                try self.takeGp(tmp);
                try self.assembler.li(tmp, bits);
                try self.storeRegBytes(dst_base, dst_off, tmp, @max(@min(ty.size, 8), 1));
            },
            .pointer => |p| {
                try self.takeGp(tmp);
                try self.assembler.li(tmp, @intCast(@intFromPtr(p)));
                try self.storeSized(dst_base, dst_off, tmp, 8);
            },
        }
    }

    fn loadIntegerWord(self: *Lower, dest: Register, base: Register, disp: i32, nbytes: usize) !void {
        try self.takeGp(dest);
        try self.loadIntegerWordNoTake(dest, base, disp, nbytes);
    }

    /// Signed `lb`/`lh`/`lw`/`ld`. A 3/5/6/7-byte tail is zero-extended pieces
    /// combined with `add` (no `or` on this assembler) then arithmetic-shifted
    /// back. The address is 8-byte aligned, so the 4/2/1 chunks stay aligned.
    fn loadIntegerWordNoTake(self: *Lower, dest: Register, base: Register, disp: i32, nbytes: usize) !void {
        switch (nbytes) {
            1 => try self.loadSized(dest, base, disp, 1),
            2 => try self.loadSized(dest, base, disp, 2),
            4 => try self.loadSized(dest, base, disp, 4),
            8 => try self.loadSized(dest, base, disp, 8),
            3, 5, 6, 7 => try self.packWord(dest, base, disp, nbytes),
            else => unreachable,
        }
    }

    fn packWord(self: *Lower, dest: Register, base: Register, disp: i32, nbytes: usize) !void {
        std.debug.assert(dest != addr_tmp);
        var left = nbytes;
        var off: i32 = 0;
        var bit: u6 = 0;
        var first = true;
        while (left > 0) {
            const n: usize = if (left >= 4) 4 else if (left >= 2) 2 else 1;
            const rd: Register = if (first) dest else addr_tmp;
            const where = try self.rawAddr(base, disp + off, n);
            switch (n) {
                4 => try self.assembler.lwu(rd, where[0], where[1]),
                2 => try self.assembler.lhu(rd, where[0], where[1]),
                else => try self.assembler.lbu(rd, where[0], where[1]),
            }
            if (!first) {
                try self.assembler.slli(rd, rd, bit);
                try self.assembler.add(dest, dest, rd);
            }
            first = false;
            bit += @intCast(n * 8);
            off += @intCast(n);
            left -= n;
        }
        const sh: u6 = @intCast(64 - nbytes * 8);
        try self.assembler.slli(dest, dest, sh);
        try self.assembler.srai(dest, dest, sh);
    }

    /// ABI integer slots are `sd` of the widened register. A home store uses
    /// the real width so a 4-byte tail does not write past the object.
    fn storeRegBytes(self: *Lower, base: Register, disp: i32, src: Register, nbytes: usize) !void {
        switch (nbytes) {
            1, 2, 4, 8 => try self.storeSized(base, disp, src, nbytes),
            else => {
                const shift_tmp: Register = if (src == tmp) tmp_ptr else tmp;
                var left = nbytes;
                var off: i32 = 0;
                var bit: u6 = 0;
                while (left > 0) {
                    const n: usize = if (left >= 4) 4 else if (left >= 2) 2 else 1;
                    const rd: Register = if (bit == 0) src else shift_tmp;
                    if (bit != 0) try self.assembler.srli(shift_tmp, src, bit);
                    try self.storeSized(base, disp + off, rd, n);
                    bit += @intCast(n * 8);
                    off += @intCast(n);
                    left -= n;
                }
            },
        }
    }

    fn spanFits(disp: i32, size: usize) bool {
        if (size == 0) return fitsI12(disp);
        const last = disp + @as(i32, @intCast(size - 1));
        return disp >= -2048 and last <= 2047 and last >= disp;
    }

    /// Direct `addImm` into `t2`. Calling `takeGp` here would spill, and that
    /// spill would need another address in `t2`.
    fn rawAddr(self: *Lower, base: Register, disp: i32, size: usize) !struct { Register, i32 } {
        if (spanFits(disp, size)) return .{ base, disp };
        std.debug.assert(base != addr_tmp);
        try self.assembler.addImm(addr_tmp, base, disp, tmp_ptr);
        return .{ addr_tmp, 0 };
    }

    fn loadSized(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) !void {
        const where = try self.rawAddr(base, disp, size);
        switch (size) {
            1 => try self.assembler.lb(dest, where[0], where[1]),
            2 => try self.assembler.lh(dest, where[0], where[1]),
            4 => try self.assembler.lw(dest, where[0], where[1]),
            8 => try self.assembler.ld(dest, where[0], where[1]),
            else => unreachable,
        }
    }

    fn storeSized(self: *Lower, base: Register, disp: i32, src: Register, size: usize) !void {
        const where = try self.rawAddr(base, disp, size);
        switch (size) {
            1 => try self.assembler.sb(src, where[0], where[1]),
            2 => try self.assembler.sh(src, where[0], where[1]),
            4 => try self.assembler.sw(src, where[0], where[1]),
            8 => try self.assembler.sd(src, where[0], where[1]),
            else => unreachable,
        }
    }

    fn loadFp(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) !void {
        try self.takeFp(dest);
        const n: usize = if (size <= 4) 4 else 8;
        const where = try self.rawAddr(base, disp, n);
        if (size <= 4)
            try self.assembler.flw(dest, where[0], where[1])
        else
            try self.assembler.fld(dest, where[0], where[1]);
    }

    fn storeFp(self: *Lower, base: Register, disp: i32, src: Register, size: usize) !void {
        const n: usize = if (size <= 4) 4 else 8;
        const where = try self.rawAddr(base, disp, n);
        if (size <= 4)
            try self.assembler.fsw(src, where[0], where[1])
        else
            try self.assembler.fsd(src, where[0], where[1]);
    }
};

fn requireRiscv() !void {
    if (comptime builtin.cpu.arch != .riscv64) return error.SkipZigTest;
}

fn expectPlace(places: [32]Place, i: usize, want: Place) !void {
    try std.testing.expectEqual(want, places[i]);
}

test "riscv64 code classify i64" {
    const places = classify(&.{.int64}, false);
    try expectPlace(places, 0, .{ .gp = .{ .base = 0, .n = 1 } });
}

test "riscv64 code classify two i64" {
    const places = classify(&.{ .int64, .int64 }, false);
    try expectPlace(places, 0, .{ .gp = .{ .base = 0, .n = 1 } });
    try expectPlace(places, 1, .{ .gp = .{ .base = 1, .n = 1 } });
}

test "riscv64 code classify f64" {
    const places = classify(&.{.float64}, false);
    try expectPlace(places, 0, .{ .fp = .{ .base = 0, .n = 1 } });
}

test "riscv64 code classify f32 pair" {
    const pair: common.Type = .{ .size = 8, .alignment = .@"4", .class = .sse };
    const places = classify(&.{pair}, false);
    try expectPlace(places, 0, .{ .fp = .{ .base = 0, .n = 2 } });

    const allocator = std.testing.allocator;
    const built = try rv.createStruct(allocator, &.{ .float32, .float32 }, null);
    defer built.free(allocator);
    const again = classify(&.{built}, false);
    try expectPlace(again, 0, .{ .fp = .{ .base = 0, .n = 2 } });
}

test "riscv64 code classify ninth f64 is fp_in_gp" {
    var args: [9]common.Type = undefined;
    @memset(&args, .float64);
    const places = classify(&args, false);
    try expectPlace(places, 8, .{ .fp_in_gp = .{ .base = 0, .n = 1 } });
}

test "riscv64 code classify ninth and tenth i64 on stack" {
    var args: [10]common.Type = undefined;
    @memset(&args, .int64);
    const places = classify(&args, false);
    try expectPlace(places, 8, .{ .stack = 0 });
    try expectPlace(places, 9, .{ .stack = 8 });
    try std.testing.expectEqual(@as(u32, 16), outgoingBytes(&args, &places, false));
}

test "riscv64 code classify mem is one pointer" {
    const mem_ty: common.Type = .{ .size = 24, .alignment = .@"8", .class = .mem };
    const places = classify(&.{ mem_ty, .int64 }, false);
    try expectPlace(places, 0, .{ .gp = .{ .base = 0, .n = 1 } });
    try expectPlace(places, 1, .{ .gp = .{ .base = 1, .n = 1 } });
    try std.testing.expect(needsByPointer(mem_ty));
    try std.testing.expect(isStructureReturn(mem_ty));
    try std.testing.expect(!isStructureReturn(.void));
}

test "riscv64 code classify sret shifts gp" {
    const places = classify(&.{.int64}, true);
    try expectPlace(places, 0, .{ .gp = .{ .base = 1, .n = 1 } });
}

test "riscv64 code classify split after seven i64" {
    const big: common.Type = .{ .size = 16, .alignment = .@"8" };
    var args: [8]common.Type = undefined;
    @memset(&args, .int64);
    args[7] = big;
    const places = classify(&args, false);
    try expectPlace(places, 7, .{ .split = .{ .gp_base = 7, .gp_n = 1, .stack = 0, .stack_words = 1 } });
}

test "riscv64 code classify three f32 array is int" {
    const ty = rv.createArray(.float32, 3);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .gp = .{ .base = 0, .n = 2 } });
}

test "riscv64 code outgoingBytes nine i64 is 16" {
    var args: [9]common.Type = undefined;
    @memset(&args, .int64);
    const places = classify(&args, false);
    try std.testing.expectEqual(@as(u32, 16), outgoingBytes(&args, &places, false));
}

test "riscv64 code classify ten f64 then f64 pair stays in gp" {
    const pair: common.Type = .{ .size = 16, .alignment = .@"8", .class = .sse };
    var args: [11]common.Type = undefined;
    @memset(&args, .float64);
    args[10] = pair;
    const places = classify(&args, false);
    try expectPlace(places, 8, .{ .fp_in_gp = .{ .base = 0, .n = 1 } });
    try expectPlace(places, 9, .{ .fp_in_gp = .{ .base = 1, .n = 1 } });
    try expectPlace(places, 10, .{ .fp_in_gp = .{ .base = 2, .n = 2 } });
}

test "riscv64 code classify sret puts eighth int on stack" {
    var args: [8]common.Type = undefined;
    @memset(&args, .int64);
    const places = classify(&args, true);
    try expectPlace(places, 0, .{ .gp = .{ .base = 1, .n = 1 } });
    try expectPlace(places, 6, .{ .gp = .{ .base = 7, .n = 1 } });
    try expectPlace(places, 7, .{ .stack = 0 });
}

test "riscv64 code classify no backfill after hfa stack miss" {
    const pair: common.Type = .{ .size = 16, .alignment = .@"8", .class = .sse };
    var args: [17]common.Type = undefined;
    for (0..8) |i| args[i] = .float64;
    for (8..15) |i| args[i] = .int64;
    args[15] = pair;
    args[16] = .int64;
    const places = classify(&args, false);
    try expectPlace(places, 15, .{ .stack = 0 });
    try expectPlace(places, 16, .{ .stack = 16 });
}

test "riscv64 code classify mixed f64 i64 uses fa and a" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .mixed = .{ .gp = 0, .fp = 0 } });
}

test "riscv64 code classify mixed i32 f64 uses fa and a" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .int32, .float64 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .mixed = .{ .gp = 0, .fp = 0 } });
}

test "riscv64 code classify f32 i32 is mixed not one gpr" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float32, .int32 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .mixed = .{ .gp = 0, .fp = 0 } });
    try std.testing.expect(isObject(ty));
}

test "riscv64 code classify f32 f64 is two fa" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float32, .float64 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .fp = .{ .base = 0, .n = 2 } });
}

test "riscv64 code classify quad stays two gpr" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float32, .float32, .int32, .int32 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, false);
    try expectPlace(places, 0, .{ .gp = .{ .base = 0, .n = 2 } });
}

test "riscv64 code classify mixed misses fa without spilling" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);
    var args: [10]common.Type = undefined;
    @memset(&args, .float64);
    args[8] = ty;
    args[9] = .int64;
    const places = classify(&args, false);
    // fa0–fa7 are full. The pair is the 16-byte integer image in a0/a1.
    // That miss does not close the GP file, so the next i64 still uses a2.
    try expectPlace(places, 8, .{ .gp = .{ .base = 0, .n = 2 } });
    try expectPlace(places, 9, .{ .gp = .{ .base = 2, .n = 1 } });
}

test "riscv64 code classify sret mixed shifts only gp" {
    const allocator = std.testing.allocator;
    const ty = try rv.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);
    const places = classify(&.{ty}, true);
    try expectPlace(places, 0, .{ .mixed = .{ .gp = 1, .fp = 0 } });
}

test "riscv64 code classify hfa miss keeps a later fa" {
    const pair: common.Type = .{ .size = 16, .alignment = .@"8", .class = .sse };
    var args: [9]common.Type = undefined;
    @memset(&args, .float64);
    args[7] = pair;
    const places = classify(&args, false);
    try expectPlace(places, 7, .{ .fp_in_gp = .{ .base = 0, .n = 2 } });
    try expectPlace(places, 8, .{ .fp = .{ .base = 7, .n = 1 } });
}

const identity_bytes = [_]u8{
    0x13, 0x01, 0x01, 0xff, // addi sp, sp, -16
    0x23, 0x34, 0x11, 0x00, // sd ra, 8(sp)
    0x23, 0x30, 0x81, 0x00, // sd s0, 0(sp)
    0x13, 0x04, 0x01, 0x01, // addi s0, sp, 16
    0x83, 0x30, 0x81, 0x00, // ld ra, 8(sp)
    0x03, 0x34, 0x01, 0x00, // ld s0, 0(sp)
    0x13, 0x01, 0x01, 0x01, // addi sp, sp, 16
    0x67, 0x80, 0x00, 0x00, // ret
};

fn containsInsn(bytes: []const u8, insn: [4]u8) bool {
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        if (std.mem.eql(u8, bytes[i..][0..4], &insn)) return true;
    }
    return false;
}

test "riscv64 code identity i64" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int64}, .int64);
    defer c.deinit();
    const a = c.param(0);
    const bytes = try c.compileAlloc(allocator, a);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &identity_bytes, bytes);
    // `mv a0, a0` is `addi a0, a0, 0`.
    try std.testing.expect(!containsInsn(bytes, .{ 0x13, 0x05, 0x05, 0x00 }));
}

test "riscv64 code call through param0 noargs" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.pointer}, .void);
    defer c.deinit();
    const fn_ptr = c.param(0);
    _ = try c.call(.value(fn_ptr), &.{}, .void);
    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const call_bytes = [_]u8{
        0x93, 0x0f, 0x05, 0x00, // mv t6, a0
        0xe7, 0x80, 0x0f, 0x00, // jalr ra, t6, 0
    };
    try std.testing.expectEqualSlices(u8, identity_bytes[0..16], bytes[0..16]);
    try std.testing.expectEqualSlices(u8, &call_bytes, bytes[16..24]);
    try std.testing.expectEqualSlices(u8, identity_bytes[16..], bytes[24..]);
}

test "riscv64 code large frame addr encodes" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();
    const ty: common.Type = .{ .size = 3000, .alignment = .@"8" };
    const obj = try c.alloc(ty);
    _ = try c.addrOf(obj);
    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len % 4);
    try std.testing.expect(bytes.len > identity_bytes.len);
}

test "riscv64 code identity i64 runs" {
    try requireRiscv();
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int64}, .int64);
    defer c.deinit();
    const a = c.param(0);
    const bytes = try c.compileAlloc(allocator, a);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();
    const f: *const fn (i64) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 5), f(5));
    try std.testing.expectEqual(@as(i64, -1), f(-1));
}
