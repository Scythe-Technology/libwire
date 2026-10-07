const std = @import("std");
const builtin = @import("builtin");

const common = @import("../common.zig");
const aarch64 = @import("../asm/aarch64.zig");
const mem = @import("../mem.zig");

pub const ir = @import("ir.zig");

const code_body = @import("body.zig");

pub const Value = ir.Value;

pub const AssemblyBuilder = aarch64.AssemblyBuilder;
/// `commit` appends, so a load/store can also run out of memory. Named so
/// `storeAt` → `accessBase` → `spill` → `storeAt` is not an inferred cycle.
const EmitError = AssemblyBuilder.EncodeError || error{OutOfMemory};
const Register = AssemblyBuilder.Register;
const Instruction = AssemblyBuilder.Instruction;
const ArgumentRegistery = aarch64.ArgumentRegistery;
const FloatingPointRegistery = aarch64.FloatingPointRegistery;

const gp_regs = ArgumentRegistery;
const fp_regs = FloatingPointRegistery;

/// Intra-procedure temps. x8 is the indirect-result register, not a temp.
/// x9 holds a pointer, x10 holds data, x11 holds the callee, x12 builds an
/// address when the displacement does not fit a load/store immediate.
const fp_reg = Register.x29;
const tmp_ptr = Register.x9;
const tmp = Register.x10;
const callee_reg = Register.x11;
const addr_tmp = Register.x12;
const sret_reg = Register.x8;
/// Caller-saved and outside v0–v7, so a stack store can use it without
/// clobbering an FP argument that has not been consumed yet. v8–v15 are
/// callee-saved; this lowerer does not preserve them.
const fp_tmp = Register.q16;

const Place = union(enum) {
    gp: usize,
    /// First FP register. An HFA uses this many consecutive registers.
    fp: usize,
    stack: usize,
};

const RegUse = struct { gp: usize = 0, fp: usize = 0 };

fn wordBytes(ty: common.Type, word: usize) usize {
    const start = word * 8;
    if (start >= ty.size) return if (ty.size == 0) 8 else 0;
    return @min(8, ty.size - start);
}

fn eightbytes(size: usize) usize {
    if (size == 0) return 0;
    return @divCeil(size, 8);
}

fn returnGpReg(idx: usize) Register {
    return switch (idx) {
        0 => .x0,
        else => .x1,
    };
}

/// Aggregates larger than 16 bytes are passed and returned by pointer.
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

/// Saved x29/x30 sit between the entry SP and this frame. Stack arguments
/// were at [entry SP], which is [x29 + 16] after that pair is stored.
pub fn incomingStackBase() comptime_int {
    return 16;
}

fn regUse(ty: common.Type) RegUse {
    if (needsByPointer(ty)) return .{ .gp = 1 };
    if (ty.class == .sse) return .{ .fp = aarch64.hfaFieldCount(ty) };
    return .{ .gp = @max(eightbytes(ty.size), 1) };
}

fn memberCount(ty: common.Type) usize {
    if (needsByPointer(ty)) return 1;
    if (ty.class == .sse) return aarch64.hfaFieldCount(ty);
    return @max(eightbytes(ty.size), 1);
}

fn memberOff(ty: common.Type, i: usize) i32 {
    if (ty.class == .sse and !needsByPointer(ty)) {
        if (ty.offsets) |offs| {
            if (i < offs.len) return @intCast(offs[i]);
        }
        const n = aarch64.hfaFieldCount(ty);
        const step: usize = if (n == 0) 8 else ty.size / n;
        return @intCast(i * step);
    }
    return @intCast(i * 8);
}

fn memberSize(ty: common.Type, i: usize) usize {
    if (ty.class == .sse and !needsByPointer(ty)) {
        const n = aarch64.hfaFieldCount(ty);
        if (n == 0) return @max(ty.size, 1);
        return @max(ty.size / n, 1);
    }
    return @max(wordBytes(ty, i), 1);
}

fn fpWidth(size: usize) u8 {
    return switch (size) {
        0...4 => 4,
        5...8 => 8,
        else => 16,
    };
}

/// A value that cannot stay in one register. HFAs of two f32 are 8 bytes
/// and still need a home, because each field has its own FP register.
pub fn isObject(ty: common.Type) bool {
    if (ty.class == .mem or ty.size > 8) return true;
    if (ty.class == .sse) return aarch64.hfaFieldCount(ty) > 1;
    return false;
}

fn stackSlot(ty: common.Type) struct { size: usize, alignment: std.mem.Alignment } {
    if (needsByPointer(ty)) return .{ .size = 8, .alignment = .@"8" };
    const layout = aarch64.stackArgLayout(ty);
    return .{ .size = layout.size, .alignment = layout.alignment };
}

/// Classify user arguments for an AAPCS64 call.
/// `sret` does not consume x0: the indirect result uses x8.
/// A composite or HFA that does not fit closes that register file (NGRN or
/// NSRN is set to 8), so later arguments of the same file also go to memory.
pub fn classify(args: []const common.Type, sret: bool) [32]Place {
    _ = sret;
    var places: [32]Place = undefined;
    std.debug.assert(args.len <= places.len);

    var gp: usize = 0;
    var fp: usize = 0;
    var stack: usize = 0;

    for (args, 0..) |arg, i| {
        const use = regUse(arg);
        const fp_arg = arg.class == .sse and !needsByPointer(arg);
        const fits = if (fp_arg)
            fp + use.fp <= fp_regs.len
        else
            gp + use.gp <= gp_regs.len;
        if (fits) {
            if (fp_arg) {
                places[i] = .{ .fp = fp };
                fp += use.fp;
            } else {
                places[i] = .{ .gp = gp };
                gp += use.gp;
            }
            continue;
        }
        const slot = stackSlot(arg);
        stack = slot.alignment.forward(stack);
        places[i] = .{ .stack = stack };
        stack += slot.size;
        if (fp_arg)
            fp = fp_regs.len
        else
            gp = gp_regs.len;
    }
    return places;
}

pub fn outgoingBytes(args: []const common.Type, places: []const Place, sret: bool) u32 {
    _ = sret;
    var stack_end: usize = 0;
    for (args, 0..) |arg, i| {
        switch (places[i]) {
            .stack => |off| stack_end = @max(stack_end, off + stackSlot(arg).size),
            else => {},
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
    local_offset: i32 = 0,
    scratch: ?i32 = null,

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
        const size: usize = if (ty.size == 0) 8 else @max(ty.size, ty.alignment.toByteUnits());
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

    fn ensureScratch(self: *Lower) i32 {
        if (self.scratch) |s| return s;
        const h = self.allocHome(.int64);
        self.scratch = h;
        return h;
    }

    fn occupantGp(self: Lower, reg: Register) ?ir.VReg {
        const want = reg.withBitSize(8);
        for (self.slots, 0..) |s, i| {
            switch (s.where) {
                .gp => |r| if (r.withBitSize(8) == want) return @fromBackingInt(@intCast(i)),
                else => {},
            }
        }
        return null;
    }

    fn occupantFp(self: Lower, reg: Register) ?ir.VReg {
        const want = reg.withBitSize(16);
        for (self.slots, 0..) |s, i| {
            switch (s.where) {
                .fp => |r| if (r.withBitSize(16) == want) return @fromBackingInt(@intCast(i)),
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
        const r = reg.withBitSize(8);
        if (self.occupantGp(r)) |old| {
            if (old != v) self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .gp = r };
    }

    fn bindFp(self: *Lower, v: ir.VReg, reg: Register) void {
        const r = reg.withBitSize(16);
        if (self.occupantFp(r)) |old| {
            if (old != v) self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .fp = r };
    }

    fn gpCopy(self: *Lower, dest: Register, src: Register) !void {
        if (dest.withBitSize(8) == src.withBitSize(8)) return;
        try self.assembler.mov(dest.withBitSize(8), src.withBitSize(8));
    }

    /// ldrb/ldrh/ldr w already zero-extend. A value already in a register
    /// may have junk above the type, and `Type` has no signedness.
    fn zeroExtendIfSmall(self: *Lower, reg: Register, ty: common.Type) !void {
        if (ty.class != .int or ty.size == 0 or ty.size >= 8) return;
        if (ty.size >= 4) {
            const w = reg.withBitSize(4);
            try self.assembler.mov(w, w);
            return;
        }
        const scratch = self.ensureScratch();
        if (ty.size == 1) {
            try self.storeAt(fp_reg, scratch, reg, 1);
            try self.loadAt(reg, fp_reg, scratch, 1);
        } else {
            try self.storeAt(fp_reg, scratch, reg, 2);
            try self.loadAt(reg, fp_reg, scratch, 2);
        }
    }

    fn spill(self: *Lower, v: ir.VReg) !void {
        const home = self.ensureHome(v);
        const ty = self.slots[v.int()].type;
        switch (self.slots[v.int()].where) {
            .gp => |r| try self.storeAt(fp_reg, home, r, @max(ty.size, 1)),
            .fp => |r| try self.storeFp(fp_reg, home, r, @max(ty.size, 1)),
            .stack, .none => {},
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn spillLiveAcrossCall(self: *Lower) !void {
        for (self.slots, 0..) |s, i| {
            const v: ir.VReg = @fromBackingInt(@intCast(i));
            if (!self.liveAfter(v)) continue;
            switch (s.where) {
                .gp, .fp => try self.spill(v),
                else => {},
            }
        }
    }

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
        if (sret_vreg) |v| self.bindGp(v, sret_reg);

        for (param_types, 0..) |ty, i| {
            const v = param_values[i].location.virtual;
            if (!self.used(v)) continue;
            const by_ptr = needsByPointer(ty);
            switch (places[i]) {
                .gp => |g| {
                    if (self.slots[v.int()].is_object and !by_ptr) {
                        const home = self.ensureHome(v);
                        const n = memberCount(ty);
                        for (0..n) |w| {
                            const chunk = memberSize(ty, w);
                            try self.storeAt(fp_reg, home + memberOff(ty, w), gp_regs[g + w], chunk);
                        }
                        self.slots[v.int()].where = .{ .stack = home };
                    } else {
                        self.bindGp(v, gp_regs[g]);
                        try self.zeroExtendIfSmall(gp_regs[g], if (by_ptr) .pointer else ty);
                    }
                },
                .fp => |s| {
                    if (self.slots[v.int()].is_object) {
                        const home = self.ensureHome(v);
                        const n = memberCount(ty);
                        for (0..n) |w| {
                            try self.storeFp(fp_reg, home + memberOff(ty, w), fp_regs[s + w], memberSize(ty, w));
                        }
                        self.slots[v.int()].where = .{ .stack = home };
                    } else {
                        self.bindFp(v, fp_regs[s]);
                    }
                },
                .stack => |off| {
                    const disp = incomingStackBase() + @as(i32, @intCast(off));
                    self.slots[v.int()].home = disp;
                    self.slots[v.int()].where = .{ .stack = disp };
                    if (by_ptr) self.slots[v.int()].is_object = false;
                },
            }
        }
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
                try self.takeGp(tmp);
                try self.assembler.lea(tmp, fp_reg, disp);
                self.bindGp(i.destination, tmp);
            },
            .load => |i| try self.emitLoad(i.destination, i.pointer, i.offset, i.type),
            .store => |i| {
                try self.takeGp(tmp_ptr);
                try self.loadRefTo(tmp_ptr, i.pointer);
                try self.copyRefToMem(i.source, i.type, tmp_ptr, i.offset);
            },
            .load_effective_address => |i| {
                try self.takeGp(tmp_ptr);
                try self.loadRefTo(tmp_ptr, i.base);
                try self.takeGp(tmp);
                try self.assembler.lea(tmp, tmp_ptr, i.offset);
                self.bindGp(i.destination, tmp);
            },
            .call => |c| try self.emitCall(c),
        }
    }

    fn emitCall(self: *Lower, c: ir.Inst.Call) !void {
        try self.materializeCallee(c.callee);
        try self.spillLiveAcrossCall();

        var arg_types: [32]common.Type = undefined;
        for (c.arguments, 0..) |arg, i| arg_types[i] = arg.type;
        const sret = c.structure_return_dest != null and isStructureReturn(c.return_type);
        const places = classify(arg_types[0..c.arguments.len], sret);
        const outgoing = outgoingBytes(arg_types[0..c.arguments.len], places[0..c.arguments.len], sret);

        if (outgoing > 0) try self.adjustSp(outgoing, true);
        if (sret) try self.loadRefTo(sret_reg, c.structure_return_dest.?);
        for (c.arguments, 0..) |arg, i|
            try self.marshalArg(arg, places[i], c.arguments[i + 1 ..]);

        try self.assembler.blr(callee_reg);
        if (outgoing > 0) try self.adjustSp(outgoing, false);

        self.clobberCallerSaved();
        if (c.destination) |dst| try self.bindCallResult(dst, c.return_type);
    }

    fn materializeCallee(self: *Lower, callee: ir.Callee) !void {
        switch (callee) {
            .immediate => |p| {
                try self.takeGp(callee_reg);
                try self.assembler.mov_imm(callee_reg, @intFromPtr(p));
            },
            .virtual => |v| try self.loadVregToGp(callee_reg, v, 0),
        }
    }

    fn marshalArg(self: *Lower, arg: ir.Arg, place: Place, later: []const ir.Arg) !void {
        const by_ptr = needsByPointer(arg.type);
        switch (place) {
            .gp => |g| {
                if (by_ptr) {
                    try self.evictForDest(.{ .gp = gp_regs[g] }, arg.ref, later);
                    try self.loadArgPointer(gp_regs[g], arg);
                    return;
                }
                const n = memberCount(arg.type);
                for (0..n) |w| {
                    try self.evictForDest(.{ .gp = gp_regs[g + w] }, arg.ref, later);
                    try self.loadMemberToGp(gp_regs[g + w], arg, w);
                }
            },
            .fp => |s| {
                const n = memberCount(arg.type);
                for (0..n) |w| {
                    try self.evictForDest(.{ .fp = fp_regs[s + w] }, arg.ref, later);
                    try self.loadMemberToFp(fp_regs[s + w], arg, w);
                }
            },
            .stack => |off| {
                if (by_ptr) {
                    try self.loadArgPointer(tmp, arg);
                    try self.storeAt(.sp, @intCast(off), tmp, 8);
                    return;
                }
                const n = memberCount(arg.type);
                if (arg.type.class == .sse) {
                    try self.takeFp(fp_tmp);
                    for (0..n) |w| {
                        try self.loadMemberToFp(fp_tmp, arg, w);
                        try self.storeFp(.sp, @as(i32, @intCast(off)) + memberOff(arg.type, w), fp_tmp, memberSize(arg.type, w));
                    }
                    return;
                }
                for (0..n) |w| {
                    try self.loadMemberToGp(tmp, arg, w);
                    try self.storeAt(.sp, @as(i32, @intCast(off)) + memberOff(arg.type, w), tmp, memberSize(arg.type, w));
                }
            },
        }
    }

    fn evictForDest(self: *Lower, dest: Where, src: ir.Ref, later: []const ir.Arg) !void {
        const occ: ?ir.VReg = switch (dest) {
            .gp => |r| self.occupantGp(r),
            .fp => |r| self.occupantFp(r),
            else => null,
        };
        const v = occ orelse return;
        switch (src) {
            .virtual => |sv| if (sv == v) return,
            else => {},
        }
        var needed_later = self.liveAfter(v);
        if (!needed_later) {
            for (later) |a| switch (a.ref) {
                .virtual => |lv| if (lv == v) {
                    needed_later = true;
                    break;
                },
                else => {},
            };
        }
        if (!needed_later) {
            self.slots[v.int()].where = .none;
            return;
        }
        switch (dest) {
            .gp => {
                if (self.occupantGp(tmp_ptr)) |cur| {
                    if (cur != v) try self.spill(cur);
                }
                try self.gpCopy(tmp_ptr, dest.gp);
                self.bindGp(v, tmp_ptr);
            },
            .fp => try self.spill(v),
            else => {},
        }
    }

    fn loadArgPointer(self: *Lower, dest: Register, arg: ir.Arg) !void {
        if (arg.type.size == 8 and arg.type.class != .sse) {
            try self.loadRefTo(dest, arg.ref);
            return;
        }
        switch (arg.ref) {
            .virtual => |v| {
                const d = try self.ensureInMemory(v);
                try self.assembler.lea(dest, fp_reg, d);
            },
            else => try self.loadRefTo(dest, arg.ref),
        }
    }

    fn bindCallResult(self: *Lower, dst: ir.VReg, ty: common.Type) !void {
        if (isObject(ty) or isStructureReturn(ty)) {
            const home = self.ensureHome(dst);
            self.slots[dst.int()].is_object = true;
            try self.storeReturnToDisp(ty, home);
            self.slots[dst.int()].where = .{ .stack = home };
            return;
        }
        if (ty.class == .sse) {
            self.bindFp(dst, fp_regs[0]);
            return;
        }
        self.bindGp(dst, .x0);
        try self.zeroExtendIfSmall(.x0, ty);
    }

    fn storeReturnToDisp(self: *Lower, ty: common.Type, d: i32) !void {
        if (ty.class == .sse) {
            const n = memberCount(ty);
            for (0..n) |w| {
                try self.storeFp(fp_reg, d + memberOff(ty, w), fp_regs[w], memberSize(ty, w));
            }
            return;
        }
        const n = memberCount(ty);
        for (0..n) |w| {
            try self.storeAt(fp_reg, d + memberOff(ty, w), returnGpReg(w), memberSize(ty, w));
        }
    }

    fn emitLoad(self: *Lower, dst: ir.VReg, ptr: ir.Ref, off: i32, ty: common.Type) !void {
        try self.takeGp(tmp_ptr);
        try self.loadRefTo(tmp_ptr, ptr);
        self.slots[dst.int()].type = ty;
        if (isObject(ty)) {
            const home = self.ensureHome(dst);
            self.slots[dst.int()].is_object = true;
            try self.copyMem(tmp_ptr, off, fp_reg, home, ty.size);
            self.slots[dst.int()].where = .{ .stack = home };
        } else if (ty.class == .sse) {
            try self.takeFp(fp_regs[0]);
            try self.loadFp(fp_regs[0], tmp_ptr, off, @max(ty.size, 1));
            self.bindFp(dst, fp_regs[0]);
        } else {
            try self.takeGp(tmp);
            try self.loadAt(tmp, tmp_ptr, off, @max(ty.size, 1));
            self.bindGp(dst, tmp);
        }
    }

    pub fn emitReturn(self: *Lower, return_type: common.Type, ret: ?Value, sret_vreg: ?ir.VReg) !void {
        if (return_type.size == 0) return;
        const v = ret.?;
        if (isStructureReturn(return_type)) {
            const dest = sret_vreg orelse return error.MissingReturnValue;
            try self.takeGp(tmp_ptr);
            try self.loadVregToGp(tmp_ptr, dest, 0);
            try self.copyRefToMem(v.location, v.type, tmp_ptr, 0);
            try self.takeGp(.x0);
            try self.gpCopy(.x0, tmp_ptr);
            try self.gpCopy(sret_reg, tmp_ptr);
            return;
        }
        try self.loadValueToReturnRegs(v);
    }

    fn loadValueToReturnRegs(self: *Lower, v: Value) !void {
        const arg: ir.Arg = .{ .ref = v.location, .type = v.type };
        if (v.type.class == .sse) {
            const n = memberCount(v.type);
            for (0..n) |w| try self.loadMemberToFp(fp_regs[w], arg, w);
            return;
        }
        const n = memberCount(v.type);
        for (0..n) |w| try self.loadMemberToGp(returnGpReg(w), arg, w);
    }

    /// Entry SP is 16-byte aligned and holds stack arguments.
    /// `sub sp, sp, #16; stp x29, x30, [sp]; mov x29, sp` makes [x29 + 16]
    /// the first stack argument. Locals are negative displacements from x29.
    pub fn wrapFrame(self: *Lower) !void {
        const a = self.assembler.allocator;
        const emitted = try self.assembler.array.toOwnedSlice(a);
        defer a.free(emitted);

        self.assembler.array = try std.ArrayList(Instruction).initCapacity(a, emitted.len + 8);
        try self.adjustSp(16, true);
        try self.assembler.stp(fp_reg, .x30, .sp, 0);
        try self.assembler.mov(fp_reg, .sp);
        const frame: u32 = @intCast(std.mem.Alignment.@"16".forward(@as(usize, @intCast(-self.local_offset))));
        if (frame > 0) try self.adjustSp(frame, true);
        try self.assembler.appendInsnSlice(emitted);
        try self.assembler.mov(.sp, fp_reg);
        try self.assembler.ldp(fp_reg, .x30, .sp, 0);
        try self.adjustSp(16, false);
        try self.assembler.ret();
    }

    fn adjustSp(self: *Lower, bytes: u32, subtract: bool) !void {
        var left: u32 = bytes;
        while (left > 0) {
            if (left <= 0xfff) {
                const imm: u12 = @intCast(left);
                if (subtract)
                    try self.assembler.sub_imm(.sp, .sp, imm)
                else
                    try self.assembler.add_imm(.sp, .sp, imm);
                return;
            }
            if (left & 0xfff == 0 and (left >> 12) <= 0xfff) {
                const disp: i32 = @intCast(left);
                try self.assembler.lea(.sp, .sp, if (subtract) -disp else disp);
                return;
            }
            if (subtract)
                try self.assembler.sub_imm(.sp, .sp, 0xfff)
            else
                try self.assembler.add_imm(.sp, .sp, 0xfff);
            left -= 0xfff;
        }
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
                try self.assembler.mov_imm(dest, b);
            },
            .pointer => |p| {
                try self.takeGp(dest);
                try self.assembler.mov_imm(dest, @intFromPtr(p));
            },
        }
    }

    fn loadVregToGp(self: *Lower, dest: Register, v: ir.VReg, word: usize) !void {
        const ty = self.slots[v.int()].type;
        const add = memberOff(ty, word);
        const size = memberSize(ty, word);
        const already = switch (self.slots[v.int()].where) {
            .gp => |r| word == 0 and r.withBitSize(8) == dest.withBitSize(8),
            else => false,
        };
        if (!already) try self.takeGp(dest);
        switch (self.slots[v.int()].where) {
            .gp => |r| {
                std.debug.assert(word == 0);
                try self.gpCopy(dest, r);
                if (word == 0) try self.zeroExtendIfSmall(dest, ty);
            },
            .stack => |d| try self.loadAt(dest, fp_reg, d + add, @max(size, 1)),
            .fp => |r| {
                std.debug.assert(word == 0);
                const scratch = self.ensureScratch();
                try self.storeFp(fp_reg, scratch, r, @max(ty.size, 1));
                try self.loadAt(dest, fp_reg, scratch, @max(ty.size, 1));
            },
            .none => {
                std.debug.assert(self.used(v));
                try self.spill(v);
                try self.loadAt(dest, fp_reg, self.slots[v.int()].home.? + add, @max(size, 1));
            },
        }
    }

    fn loadMemberToGp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        switch (arg.ref) {
            .virtual => |v| try self.loadVregToGp(dest, v, word),
            .immediate => |bits| {
                std.debug.assert(word == 0);
                try self.takeGp(dest);
                try self.assembler.mov_imm(dest, bits);
            },
            .pointer => |p| {
                std.debug.assert(word == 0);
                try self.takeGp(dest);
                try self.assembler.mov_imm(dest, @intFromPtr(p));
            },
        }
    }

    fn loadMemberToFp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        const size = memberSize(arg.type, word);
        const add = memberOff(arg.type, word);
        switch (arg.ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .fp => |r| {
                    std.debug.assert(word == 0);
                    try self.fpCopy(dest, r, size);
                },
                .stack => |d| try self.loadFp(dest, fp_reg, d + add, size),
                .gp => |r| {
                    const scratch = self.ensureScratch();
                    try self.storeAt(fp_reg, scratch, r, @max(self.slots[v.int()].type.size, 1));
                    try self.loadFp(dest, fp_reg, scratch, size);
                },
                .none => {
                    try self.spill(v);
                    try self.loadMemberToFp(dest, arg, word);
                },
            },
            .immediate => |bits| {
                try self.takeGp(tmp);
                try self.assembler.mov_imm(tmp, bits);
                const scratch = self.ensureScratch();
                try self.storeAt(fp_reg, scratch, tmp, @max(size, 1));
                try self.loadFp(dest, fp_reg, scratch, size);
            },
            .pointer => unreachable,
        }
    }

    fn fpCopy(self: *Lower, dest: Register, src: Register, size: usize) !void {
        const bits = fpWidth(size);
        const d = dest.withBitSize(bits);
        const s = src.withBitSize(bits);
        if (d == s) return;
        try self.takeFp(dest);
        try self.assembler.fmov(d, s);
    }

    fn copyMem(self: *Lower, src_base: Register, src_off: i32, dst_base: Register, dst_off: i32, size: usize) !void {
        try self.takeGp(tmp);
        var done: usize = 0;
        while (done < size) {
            const left = size - done;
            const chunk: usize = if (left >= 8) 8 else if (left >= 4) 4 else if (left >= 2) 2 else 1;
            const sd = src_off + @as(i32, @intCast(done));
            const dd = dst_off + @as(i32, @intCast(done));
            try self.loadAt(tmp, src_base, sd, chunk);
            try self.storeAt(dst_base, dd, tmp, chunk);
            done += chunk;
        }
    }

    fn copyRefToMem(self: *Lower, ref: ir.Ref, ty: common.Type, dst_base: Register, dst_off: i32) !void {
        switch (ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .stack => |d| try self.copyMem(fp_reg, d, dst_base, dst_off, @max(ty.size, 1)),
                .gp => |r| try self.storeAt(dst_base, dst_off, r, @max(ty.size, 1)),
                .fp => |r| try self.storeFp(dst_base, dst_off, r, @max(ty.size, 1)),
                .none => {
                    try self.spill(v);
                    try self.copyRefToMem(ref, ty, dst_base, dst_off);
                },
            },
            .immediate => |bits| {
                try self.takeGp(tmp);
                try self.assembler.mov_imm(tmp, bits);
                try self.storeAt(dst_base, dst_off, tmp, @max(ty.size, 1));
            },
            .pointer => |p| {
                try self.takeGp(tmp);
                try self.assembler.mov_imm(tmp, @intFromPtr(p));
                try self.storeAt(dst_base, dst_off, tmp, 8);
            },
        }
    }

    fn offsetFits(size: usize, disp: i32) bool {
        const step: i32 = switch (size) {
            1 => 1,
            2 => 2,
            3...4 => 4,
            5...8 => 8,
            else => 16,
        };
        if (disp >= 0 and @rem(disp, step) == 0) {
            const scaled = @divExact(disp, step);
            if (scaled <= 0xfff) return true;
        }
        return disp >= -256 and disp <= 255;
    }

    fn accessBase(self: *Lower, base: Register, disp: i32, size: usize) EmitError!struct { Register, i32 } {
        if (offsetFits(size, disp)) return .{ base, disp };
        try self.takeGp(addr_tmp);
        try self.assembler.lea(addr_tmp, base, disp);
        return .{ addr_tmp, 0 };
    }

    fn loadAt(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) EmitError!void {
        const where = try self.accessBase(base, disp, size);
        switch (size) {
            1 => try self.assembler.ldrb(dest, where[0], where[1]),
            2 => try self.assembler.ldrh(dest, where[0], where[1]),
            3...4 => try self.assembler.ldr(dest.withBitSize(4), where[0], where[1]),
            else => try self.assembler.ldr(dest.withBitSize(8), where[0], where[1]),
        }
    }

    fn storeAt(self: *Lower, base: Register, disp: i32, src: Register, size: usize) EmitError!void {
        const where = try self.accessBase(base, disp, size);
        switch (size) {
            1 => try self.assembler.strb(src, where[0], where[1]),
            2 => try self.assembler.strh(src, where[0], where[1]),
            3...4 => try self.assembler.str(src.withBitSize(4), where[0], where[1]),
            else => try self.assembler.str(src.withBitSize(8), where[0], where[1]),
        }
    }

    fn loadFp(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) EmitError!void {
        const bits = fpWidth(size);
        const where = try self.accessBase(base, disp, @min(size, 16));
        try self.assembler.ldr_fp(dest.withBitSize(bits), where[0], where[1]);
    }

    fn storeFp(self: *Lower, base: Register, disp: i32, src: Register, size: usize) EmitError!void {
        const bits = fpWidth(size);
        const where = try self.accessBase(base, disp, @min(size, 16));
        try self.assembler.str_fp(src.withBitSize(bits), where[0], where[1]);
    }
};

fn requireAarch64() !void {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
}

fn f64Bits(v: f64) u64 {
    return @bitCast(v);
}

fn jitFn(bytes: []const u8) !mem.Block {
    const dynm = try mem.Block.initWithBytes(bytes);
    try dynm.executable();
    return dynm;
}

test "aarch64 code call through param1 noargs" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{ .pointer, .pointer }, .void);
    defer c.deinit();

    _ = c.param(0);
    const fn_ptr = c.param(1);
    _ = try c.call(.value(fn_ptr), &.{}, .void);

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);

    // sub sp, sp, #16
    // stp x29, x30, [sp]
    // mov x29, sp
    // mov x11, x1
    // blr x11
    // mov sp, x29
    // ldp x29, x30, [sp]
    // add sp, sp, #16
    // ret
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0x43, 0x00, 0xD1,
        0xFD, 0x7B, 0x00, 0xA9,
        0xFD, 0x03, 0x00, 0x91,
        0xEB, 0x03, 0x01, 0xAA,
        0x60, 0x01, 0x3F, 0xD6,
        0xBF, 0x03, 0x00, 0x91,
        0xFD, 0x7B, 0x40, 0xA9,
        0xFF, 0x43, 0x00, 0x91,
        0xC0, 0x03, 0x5F, 0xD6,
    }, bytes);
}

test "aarch64 code identity i64" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int64}, .int64);
    defer c.deinit();
    const a = c.param(0);
    const bytes = try c.compileAlloc(allocator, a);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (i64) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 5), f(5));
    try std.testing.expectEqual(@as(i64, -1), f(-1));
}

test "aarch64 code call add(i64, i64) i64" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: i64, b: i64) callconv(.c) i64 {
            return a + b;
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, .int64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const x = Value.imm(.int64, 40);
    const y = Value.imm(.int64, 2);
    const sum = (try c.call(.value(fn_ptr), &.{ x, y }, .int64)).?;
    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 42), f(&add));
}

test "aarch64 code call add(f64, f64) f64" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: f64, b: f64) callconv(.c) f64 {
            return a + b;
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, .float64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const x = Value.imm(.float64, @bitCast(@as(f64, 1.5)));
    const y = Value.imm(.float64, @bitCast(@as(f64, 2.25)));
    const sum = (try c.call(.value(fn_ptr), &.{ x, y }, .float64)).?;
    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) f64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(f64, 3.75), f(&add));
}

test "aarch64 code hfa f32 pair arg and return" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const Pair = extern struct { a: f32, b: f32 };
    const ty = try aarch64.createStruct(allocator, &.{ .float32, .float32 }, null);
    defer ty.free(allocator);
    const swap = struct {
        fn inner(p: Pair) callconv(.c) Pair {
            return .{ .a = p.b, .b = p.a };
        }
    }.inner;
    var c = try Code.init(allocator, &.{ .pointer, ty }, ty);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const arg = c.param(1);
    const got = (try c.call(.value(fn_ptr), &.{arg}, ty)).?;
    const bytes = try c.compileAlloc(allocator, got);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque, Pair) callconv(.c) Pair = @ptrCast(dynm.buffer);
    const out = f(&swap, .{ .a = 1.5, .b = 2.5 });
    try std.testing.expectEqual(@as(f32, 2.5), out.a);
    try std.testing.expectEqual(@as(f32, 1.5), out.b);
}

test "aarch64 code u8 param return zero-extends" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int8}, .int8);
    defer c.deinit();
    const a = c.param(0);
    const bytes = try c.compileAlloc(allocator, a);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (u8) callconv(.c) u8 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(u8, 0x42), f(0x42));
}

test "aarch64 code compileInto reuses buffer" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int64}, .int64);
    defer c.deinit();
    const a = c.param(0);
    const n = try c.machineCodeLen(a);
    const dynm = try mem.Block.init(n);
    defer dynm.deinit();
    try dynm.writable();
    const wrote = try c.compileInto(a, dynm.buffer);
    try std.testing.expectEqual(n, wrote);
    try dynm.executable();
    const f: *const fn (i64) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 42), f(42));
}

test "aarch64 code i64 stays in x0 after 8 f64" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, n: i64) callconv(.c) i64 {
            return n + @as(i64, @intFromFloat(a + b + c + d + e + f + g + h));
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, .int64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const args = [_]Value{
        .imm(.float64, f64Bits(1.5)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(0)),
        .imm(.float64, f64Bits(2.5)),
        .imm(.int64, 10),
    };
    const sum = (try c.call(.value(fn_ptr), &args, .int64)).?;
    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 14), f(&add));
}

test "aarch64 code hfa spill sets NSRN to 8" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const Pair = extern struct { a: f64, b: f64 };
    const ty = try aarch64.createStruct(allocator, &.{ .float64, .float64 }, null);
    defer ty.free(allocator);
    const add = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, pair: Pair, h: f64) callconv(.c) f64 {
            return a + b + c + d + e + f + g + pair.a + pair.b + h;
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, .float64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const pair = try c.alloc(ty);
    const pair_ptr = try c.addrOf(pair);
    try c.store(pair_ptr, 0, .imm(.float64, f64Bits(8)));
    try c.store(pair_ptr, 8, .imm(.float64, f64Bits(9)));
    const args = [_]Value{
        .imm(.float64, f64Bits(1)),
        .imm(.float64, f64Bits(2)),
        .imm(.float64, f64Bits(3)),
        .imm(.float64, f64Bits(4)),
        .imm(.float64, f64Bits(5)),
        .imm(.float64, f64Bits(6)),
        .imm(.float64, f64Bits(7)),
        pair,
        .imm(.float64, f64Bits(10)),
    };
    const sum = (try c.call(.value(fn_ptr), &args, .float64)).?;
    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) f64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(f64, 55), f(&add));
}

test "aarch64 code int struct spill sets NGRN to 8" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const Two = extern struct { a: i64, b: i64 };
    const ty = try aarch64.createStruct(allocator, &.{ .int64, .int64 }, null);
    defer ty.free(allocator);
    const add = struct {
        fn inner(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, pair: Two, h: i64) callconv(.c) i64 {
            return a + b + c + d + e + f + g + pair.a + pair.b + h;
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, .int64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const pair = try c.alloc(ty);
    const pair_ptr = try c.addrOf(pair);
    try c.store(pair_ptr, 0, .imm(.int64, 8));
    try c.store(pair_ptr, 8, .imm(.int64, 9));
    const args = [_]Value{
        .imm(.int64, 1),
        .imm(.int64, 2),
        .imm(.int64, 3),
        .imm(.int64, 4),
        .imm(.int64, 5),
        .imm(.int64, 6),
        .imm(.int64, 7),
        pair,
        .imm(.int64, 10),
    };
    const sum = (try c.call(.value(fn_ptr), &args, .int64)).?;
    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 55), f(&add));
}

test "aarch64 code large struct is a pointer" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const Big = extern struct { a: i64, b: i64, c: i64, d: i64 };
    const ty = try aarch64.createStruct(allocator, &.{ .int64, .int64, .int64, .int64 }, null);
    defer ty.free(allocator);
    const sum = struct {
        fn inner(s: Big) callconv(.c) i64 {
            return s.a + s.d;
        }
    }.inner;
    var c = try Code.init(allocator, &.{ .pointer, ty }, .int64);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const arg = c.param(1);
    const got = (try c.call(.value(fn_ptr), &.{arg}, .int64)).?;
    const bytes = try c.compileAlloc(allocator, got);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque, Big) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 5), f(&sum, .{ .a = 1, .b = 2, .c = 3, .d = 4 }));
}

test "aarch64 code large struct return uses x8" {
    try requireAarch64();
    const allocator = std.testing.allocator;
    const Big = extern struct { a: i64, b: i64, c: i64, d: i64 };
    const ty = try aarch64.createStruct(allocator, &.{ .int64, .int64, .int64, .int64 }, null);
    defer ty.free(allocator);
    const make = struct {
        fn inner() callconv(.c) Big {
            return .{ .a = 1, .b = 2, .c = 3, .d = 4 };
        }
    }.inner;
    var c = try Code.init(allocator, &.{.pointer}, ty);
    defer c.deinit();
    const fn_ptr = c.param(0);
    const got = (try c.call(.value(fn_ptr), &.{}, ty)).?;
    const bytes = try c.compileAlloc(allocator, got);
    defer allocator.free(bytes);
    const dynm = try jitFn(bytes);
    defer dynm.deinit();
    const f: *const fn (*const anyopaque) callconv(.c) Big = @ptrCast(dynm.buffer);
    const out = f(&make);
    try std.testing.expectEqual(@as(i64, 1), out.a);
    try std.testing.expectEqual(@as(i64, 2), out.b);
    try std.testing.expectEqual(@as(i64, 3), out.c);
    try std.testing.expectEqual(@as(i64, 4), out.d);
}
