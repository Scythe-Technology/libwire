const std = @import("std");

const common = @import("../common.zig");
const x86_64 = @import("../asm/x86_64.zig");
const mem = @import("../mem.zig");

pub const ir = @import("ir.zig");

const code_body = @import("body.zig");

pub const Value = ir.Value;

pub const AssemblyBuilder = x86_64.AssemblyBuilder;
const Register = AssemblyBuilder.Register;
const Instruction = AssemblyBuilder.Instruction;
const CallingConvention = x86_64.CallingConvention;
const ArgumentRegistery = x86_64.ArgumentRegistery;
const FloatingPointRegistery = x86_64.FloatingPointRegistery;

const gp_regs = ArgumentRegistery;
const sse_regs = FloatingPointRegistery;

const Place = union(enum) {
    gp: usize,
    sse: usize,
    /// SysV argument whose eightbytes do not all use one register file.
    /// `gp` and `sse` are the first free register of that file. A file the
    /// value does not use stays unused.
    split: struct { gp: usize, sse: usize },
    stack: usize,
};

const RegUse = struct { gp: usize = 0, sse: usize = 0 };

fn wordBytes(ty: common.Type, word: usize) usize {
    const start = word * 8;
    if (start >= ty.size) return if (ty.size == 0) 8 else 0;
    return @min(8, ty.size - start);
}

/// How many GP and XMM registers a SysV value needs. `.none` padding and
/// `.mem` chunks consume neither; the caller handles MEMORY before this.
fn returnGpReg(idx: usize) Register {
    return switch (idx) {
        0 => .rax,
        else => .rdx,
    };
}

fn regUse(ty: common.Type) RegUse {
    var use: RegUse = .{};
    const n = @max(eightbytes(ty.size), 1);
    for (0..n) |w| switch (ty.eightbyte(w)) {
        .sse => use.sse += 1,
        .int => use.gp += 1,
        .none, .mem => {},
    };
    return use;
}

fn eightbytes(size: usize) usize {
    if (size == 0) return 0;
    return @divCeil(size, 8);
}

/// Windows passes aggregates > 8 bytes by address. SysV MEMORY-class
/// arguments are copied onto the stack (not passed as a hidden pointer).
pub fn needsByPointer(ty: common.Type) bool {
    if (comptime CallingConvention != .Windows) return false;
    return ty.size > 8;
}

pub fn isMemoryClass(ty: common.Type) bool {
    if (ty.class == .mem)
        return true;
    if (comptime CallingConvention == .Windows)
        return false;
    return ty.size > 16;
}

pub fn isStructureReturn(ty: common.Type) bool {
    if (ty.size == 0)
        return false;
    if (ty.class == .mem)
        return true;
    if (comptime CallingConvention == .Windows)
        return ty.size > 8;
    return ty.size > 16;
}

pub fn incomingStackBase() comptime_int {
    // `push rbp; mov rbp, rsp`: return address is [rbp+8].
    // SysV stack args start at [rbp+16]. Windows home is 32 bytes more.
    if (comptime CallingConvention == .Windows)
        return 16 + 32;
    return 16;
}

/// Classify user arguments for a C call. `sret` consumes the first GP slot.
pub fn classify(args: []const common.Type, sret: bool) [32]Place {
    var places: [32]Place = undefined;
    std.debug.assert(args.len <= places.len);

    var gp: usize = if (sret) 1 else 0;
    var sse: usize = 0;
    var stack: usize = 0;

    for (args, 0..) |arg, i| {
        const by_ptr = needsByPointer(arg);
        const words: usize = if (by_ptr) 1 else @max(eightbytes(arg.size), 1);

        if (comptime CallingConvention == .Windows) {
            // One slot per argument; GP and XMM share rcx/rdx/r8/r9.
            if (gp < gp_regs.len) {
                if (arg.class == .sse and !by_ptr) {
                    places[i] = .{ .sse = gp };
                } else {
                    places[i] = .{ .gp = gp };
                }
                gp += 1;
            } else {
                places[i] = .{ .stack = stack };
                stack += 8;
            }
            continue;
        }

        // SysV MEMORY: copy on the stack; does not consume GP/SSE and does
        // not force later register-class args onto the stack.
        if (isMemoryClass(arg) and !by_ptr) {
            stack = arg.alignment.max(.@"8").forward(stack);
            places[i] = .{ .stack = stack };
            stack += words * 8;
            continue;
        }

        // Each eightbyte takes the next register of its own file. If either
        // file cannot hold every chunk, the whole argument goes to memory.
        const use = regUse(arg);
        if (gp + use.gp <= gp_regs.len and sse + use.sse <= sse_regs.len) {
            places[i] = .{ .split = .{ .gp = gp, .sse = sse } };
            gp += use.gp;
            sse += use.sse;
        } else {
            places[i] = .{ .stack = stack };
            stack += words * 8;
        }
    }
    return places;
}

pub fn outgoingBytes(args: []const common.Type, places: []const Place, sret: bool) u32 {
    _ = sret;
    var stack_end: usize = 0;
    for (args, 0..) |arg, i| {
        switch (places[i]) {
            .stack => |off| {
                const by_ptr = needsByPointer(arg);
                const words: usize = if (by_ptr) 1 else @max(eightbytes(arg.size), 1);
                stack_end = @max(stack_end, off + words * 8);
            },
            else => {},
        }
    }
    if (comptime CallingConvention == .Windows)
        stack_end += 32;
    return @intCast(std.mem.Alignment.@"16".forward(stack_end));
}

/// SystemV: `[rsp]`, Windows: `[rsp+32]`.
fn outgoingStackDisp(off: usize) i32 {
    const shadow: usize = if (comptime CallingConvention == .Windows) 32 else 0;
    return @intCast(off + shadow);
}

pub const Code = code_body.Code(@This());

pub fn isObject(ty: common.Type) bool {
    return ty.size > 8 or ty.class == .mem;
}

const Where = union(enum) {
    none,
    gp: Register,
    sse: Register,
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

    /// Still needed at this inst (as a source) or later.
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
        if (self.slots[v.int()].home) |h|
            return h;
        const h = self.allocHome(self.slots[v.int()].type);

        self.slots[v.int()].home = h;

        return h;
    }

    fn ensureScratch(self: *Lower) i32 {
        if (self.scratch) |s|
            return s;
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

    fn occupantSse(self: Lower, reg: Register) ?ir.VReg {
        for (self.slots, 0..) |s, i| {
            switch (s.where) {
                .sse => |r| if (r == reg) return @fromBackingInt(@intCast(i)),
                else => {},
            }
        }
        return null;
    }

    /// Drop or spill whoever is in `reg` so it can be overwritten.
    fn takeGp(self: *Lower, reg: Register) !void {
        if (self.occupantGp(reg)) |v| {
            if (self.liveHere(v))
                try self.spill(v)
            else
                self.slots[v.int()].where = .none;
        }
    }

    fn takeSse(self: *Lower, reg: Register) !void {
        if (self.occupantSse(reg)) |v| {
            if (self.liveHere(v))
                try self.spill(v)
            else
                self.slots[v.int()].where = .none;
        }
    }

    fn bindGp(self: *Lower, v: ir.VReg, reg: Register) void {
        const r = reg.withBitSize(8);
        if (self.occupantGp(r)) |old| {
            if (old != v)
                self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .gp = r };
    }

    fn bindSse(self: *Lower, v: ir.VReg, reg: Register) void {
        if (self.occupantSse(reg)) |old| {
            if (old != v)
                self.slots[old.int()].where = .none;
        }
        self.slots[v.int()].where = .{ .sse = reg };
    }

    /// `mov dest, src` with dest in the ModRM.reg field so r8-r15 encode REX.R.
    fn gpCopy(self: *Lower, dest: Register, src: Register) !void {
        if (dest.withBitSize(8) == src.withBitSize(8)) return;
        try self.assembler.mov(.load, dest.withBitSize(8), src.withBitSize(8), null);
    }

    fn gpZeroExtend(self: *Lower, dest: Register, src: Register, size: u8) !void {
        try self.assembler.movzx(dest.withBitSize(8), src.withBitSize(size), null, size);
    }

    fn gpCopySized(self: *Lower, dest: Register, src: Register, size: usize) !void {
        return switch (size) {
            1, 2 => try self.gpZeroExtend(dest, src, @intCast(size)),
            else => try self.gpCopy(dest, src),
        };
    }

    fn gpLoadSized(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) !void {
        return switch (size) {
            1, 2 => try self.assembler.movzx(dest.withBitSize(8), base, disp, @intCast(size)),
            else => try self.assembler.mov(.load, dest.withBitSize(8), base, disp),
        };
    }

    fn zeroExtendIfSmall(self: *Lower, reg: Register, ty: common.Type) !void {
        if (ty.class != .int) return;
        if (ty.size > 2) return;
        try self.gpZeroExtend(reg, reg, @intCast(ty.size));
    }

    fn spill(self: *Lower, v: ir.VReg) !void {
        const home = self.ensureHome(v);
        switch (self.slots[v.int()].where) {
            .gp => |r| try self.assembler.mov(.store, .rbp, r.withBitSize(8), home),
            .sse => |r| {
                if (self.slots[v.int()].type.size <= 4)
                    try self.assembler.movss(.store, .rbp, r, home)
                else
                    try self.assembler.movsd(.store, .rbp, r, home);
            },
            .stack, .none => {},
        }
        self.slots[v.int()].where = .{ .stack = home };
    }

    fn spillLiveAcrossCall(self: *Lower) !void {
        for (self.slots, 0..) |s, i| {
            const v: ir.VReg = @fromBackingInt(@intCast(i));
            if (!self.liveAfter(v))
                continue;
            switch (s.where) {
                .gp, .sse => try self.spill(v),
                else => {},
            }
        }
    }

    fn clobberCallerSaved(self: *Lower) void {
        for (self.slots) |*s| {
            switch (s.where) {
                .gp, .sse => s.where = if (s.home) |h| .{ .stack = h } else .none,
                else => {},
            }
        }
    }

    fn spillEightbytesFromArgs(self: *Lower, ty: common.Type, home: i32, gp_base: usize, sse_base: usize) !void {
        var gp_idx = gp_base;
        var sse_idx = sse_base;
        const n = @max(eightbytes(ty.size), 1);
        for (0..n) |w| {
            const disp = home + @as(i32, @intCast(w * 8));
            const chunk = wordBytes(ty, w);
            switch (ty.eightbyte(w)) {
                .sse => {
                    const reg = sse_regs[sse_idx];
                    sse_idx += 1;
                    if (chunk <= 4)
                        try self.assembler.movss(.store, .rbp, reg, disp)
                    else
                        try self.assembler.movsd(.store, .rbp, reg, disp);
                },
                .int => {
                    const reg = gp_regs[gp_idx];
                    gp_idx += 1;
                    try self.storeSized(.rbp, disp, reg, @max(chunk, 1));
                },
                .none, .mem => {},
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
        if (sret_vreg) |v| self.bindGp(v, gp_regs[0]);

        for (param_types, 0..) |ty, i| {
            const v = param_values[i].location.virtual;
            if (!self.used(v)) continue;
            const by_ptr = needsByPointer(ty);
            switch (places[i]) {
                .gp => |g| {
                    if (self.slots[v.int()].is_object and !by_ptr) {
                        // Multi-word incoming: park it in a home now so later
                        // uses do not need both original arg registers.
                        const home = self.ensureHome(v);
                        const n = @max(eightbytes(ty.size), 1);
                        for (0..n) |w| {
                            try self.assembler.mov(
                                .store,
                                .rbp,
                                gp_regs[g + w].withBitSize(8),
                                home + @as(i32, @intCast(w * 8)),
                            );
                        }
                        self.slots[v.int()].where = .{ .stack = home };
                    } else {
                        self.bindGp(v, gp_regs[g]);
                        try self.zeroExtendIfSmall(gp_regs[g], ty);
                    }
                },
                .sse => |s| {
                    if (self.slots[v.int()].is_object) {
                        const home = self.ensureHome(v);
                        const n = @max(eightbytes(ty.size), 1);
                        for (0..n) |w| {
                            const d = home + @as(i32, @intCast(w * 8));
                            if (ty.size == 4 and w == 0)
                                try self.assembler.movss(.store, .rbp, sse_regs[s + w], d)
                            else
                                try self.assembler.movsd(.store, .rbp, sse_regs[s + w], d);
                        }
                        self.slots[v.int()].where = .{ .stack = home };
                    } else {
                        self.bindSse(v, sse_regs[s]);
                    }
                },
                .split => |s| {
                    // One register: keep it there. Two chunks: the value is an
                    // object, so park each eightbyte from its own register.
                    if (!self.slots[v.int()].is_object) {
                        switch (ty.eightbyte(0)) {
                            .sse => self.bindSse(v, sse_regs[s.sse]),
                            else => {
                                self.bindGp(v, gp_regs[s.gp]);
                                try self.zeroExtendIfSmall(gp_regs[s.gp], ty);
                            },
                        }
                    } else {
                        const home = self.ensureHome(v);
                        try self.spillEightbytesFromArgs(ty, home, s.gp, s.sse);
                        self.slots[v.int()].where = .{ .stack = home };
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
                try self.takeGp(.rax);
                try self.assembler.lea(.rax, .rbp, disp);
                self.bindGp(i.destination, .rax);
            },
            .load => |i| try self.emitLoad(i.destination, i.pointer, i.offset, i.type),
            .store => |i| {
                try self.takeGp(.r10);
                try self.loadRefTo(.r10, i.pointer);
                try self.copyRefToMem(i.source, i.type, .r10, i.offset);
            },
            .load_effective_address => |i| {
                try self.takeGp(.r10);
                try self.loadRefTo(.r10, i.base);
                try self.takeGp(.rax);
                try self.assembler.lea(.rax, .r10, i.offset);
                self.bindGp(i.destination, .rax);
            },
            .call => |c| try self.emitCall(c),
        }
    }

    fn emitCall(self: *Lower, c: ir.Inst.Call) !void {
        try self.materializeCallee(c.callee);
        try self.spillLiveAcrossCall();

        var arg_types: [32]common.Type = undefined;
        for (c.arguments, 0..) |arg, i|
            arg_types[i] = arg.type;
        const sret = c.structure_return_dest != null and isStructureReturn(c.return_type);
        const places = classify(arg_types[0..c.arguments.len], sret);
        const outgoing = outgoingBytes(arg_types[0..c.arguments.len], places[0..c.arguments.len], sret);

        if (outgoing > 0)
            try self.assembler.imm32(.sub, .rsp, outgoing);

        if (sret) try self.loadRefTo(gp_regs[0], c.structure_return_dest.?);

        for (c.arguments, 0..) |arg, i| {
            try self.marshalArg(arg, places[i], c.arguments[i + 1 ..]);
        }

        try self.assembler.call(.r11);
        if (outgoing > 0)
            try self.assembler.imm32(.add, .rsp, outgoing);

        self.clobberCallerSaved();
        if (c.destination) |dst|
            try self.bindCallResult(dst, c.return_type);
    }

    fn materializeCallee(self: *Lower, callee: ir.Callee) !void {
        switch (callee) {
            .immediate => |p| try self.assembler.mov_imm(.r11, @intFromPtr(p)),
            .virtual => |v| try self.loadVregToGp(.r11, v, 0),
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
                const n = @max(eightbytes(arg.type.size), 1);
                for (0..n) |w| {
                    try self.evictForDest(.{ .gp = gp_regs[g + w] }, arg.ref, later);
                    try self.loadEightbyteToGp(gp_regs[g + w], arg, w);
                }
            },
            .sse => |s| {
                const n = @max(eightbytes(arg.type.size), 1);
                for (0..n) |w| {
                    try self.evictForDest(.{ .sse = sse_regs[s + w] }, arg.ref, later);
                    try self.loadEightbyteToSse(sse_regs[s + w], arg, w);
                }
            },
            .split => |s| {
                var gp_idx = s.gp;
                var sse_idx = s.sse;
                const n = @max(eightbytes(arg.type.size), 1);
                for (0..n) |w| switch (arg.type.eightbyte(w)) {
                    .sse => {
                        try self.evictForDest(.{ .sse = sse_regs[sse_idx] }, arg.ref, later);
                        try self.loadEightbyteToSse(sse_regs[sse_idx], arg, w);
                        sse_idx += 1;
                    },
                    .int => {
                        try self.evictForDest(.{ .gp = gp_regs[gp_idx] }, arg.ref, later);
                        try self.loadEightbyteToGp(gp_regs[gp_idx], arg, w);
                        gp_idx += 1;
                    },
                    .none, .mem => {},
                };
            },
            .stack => |off| {
                const n: usize = if (by_ptr) 1 else @max(eightbytes(arg.type.size), 1);
                const disp = outgoingStackDisp(off);
                if (by_ptr) {
                    try self.loadArgPointer(.rax, arg);
                    try self.assembler.mov(.store, .rsp, .rax, disp);
                    return;
                }
                for (0..n) |w| {
                    try self.loadEightbyteToGp(.rax, arg, w);
                    try self.assembler.mov(.store, .rsp, .rax, disp + @as(i32, @intCast(w * 8)));
                }
            },
        }
    }

    /// If `dest` still holds a later arg, bounce it to r10 (or spill).
    fn evictForDest(self: *Lower, dest: Where, src: ir.Ref, later: []const ir.Arg) !void {
        const occ: ?ir.VReg = switch (dest) {
            .gp => |r| self.occupantGp(r),
            .sse => |r| self.occupantSse(r),
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
                // r10 is the marshal bounce; only one value at a time.
                if (self.occupantGp(.r10)) |cur| {
                    if (cur != v) try self.spill(cur);
                }
                try self.gpCopy(.r10, dest.gp);
                self.bindGp(v, .r10);
            },
            .sse => try self.spill(v),
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
                try self.assembler.lea(dest, .rbp, d);
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
            self.bindSse(dst, .xmm0);
            return;
        }
        self.bindGp(dst, .rax);
        try self.zeroExtendIfSmall(.rax, ty);
    }

    fn storeReturnToDisp(self: *Lower, ty: common.Type, d: i32) !void {
        // Return registers are numbered per class, not per chunk: the first
        // INTEGER eightbyte is rax even when it is the high chunk.
        var gp_i: usize = 0;
        var sse_i: usize = 0;
        const n = @max(eightbytes(ty.size), 1);
        for (0..n) |w| {
            const disp = d + @as(i32, @intCast(w * 8));
            const chunk = wordBytes(ty, w);
            switch (ty.eightbyte(w)) {
                .sse => {
                    const reg = sse_regs[sse_i];
                    sse_i += 1;
                    if (chunk <= 4)
                        try self.assembler.movss(.store, .rbp, reg, disp)
                    else
                        try self.assembler.movsd(.store, .rbp, reg, disp);
                },
                .int => {
                    const reg = returnGpReg(gp_i);
                    gp_i += 1;
                    try self.storeSized(.rbp, disp, reg, @max(chunk, 1));
                },
                .none, .mem => {},
            }
        }
    }

    fn emitLoad(self: *Lower, dst: ir.VReg, ptr: ir.Ref, off: i32, ty: common.Type) !void {
        try self.takeGp(.r10);
        try self.loadRefTo(.r10, ptr);
        self.slots[dst.int()].type = ty;
        if (isObject(ty)) {
            const home = self.ensureHome(dst);
            self.slots[dst.int()].is_object = true;
            try self.copyMemToDisp(.r10, off, home, ty.size);
            self.slots[dst.int()].where = .{ .stack = home };
        } else if (ty.class == .sse) {
            try self.takeSse(.xmm0);
            if (ty.size <= 4)
                try self.assembler.movss(.load, .xmm0, .r10, off)
            else
                try self.assembler.movsd(.load, .xmm0, .r10, off);
            self.bindSse(dst, .xmm0);
        } else {
            try self.takeGp(.rax);
            try self.loadSized(.rax, .r10, off, @max(ty.size, 1));
            self.bindGp(dst, .rax);
        }
    }

    pub fn emitReturn(self: *Lower, return_type: common.Type, ret: ?Value, sret_vreg: ?ir.VReg) !void {
        if (return_type.size == 0) return;
        const v = ret.?;
        if (isStructureReturn(return_type)) {
            const dest = sret_vreg orelse return error.MissingReturnValue;
            try self.takeGp(.r10);
            try self.loadVregToGp(.r10, dest, 0);
            try self.copyRefToMem(v.location, v.type, .r10, 0);
            try self.takeGp(.rax);
            try self.gpCopy(.rax, .r10);
            return;
        }
        try self.loadValueToReturnRegs(v);
    }

    fn loadValueToReturnRegs(self: *Lower, v: Value) !void {
        const arg: ir.Arg = .{
            .ref = v.location,
            .type = v.type,
        };
        var gp_i: usize = 0;
        var sse_i: usize = 0;
        const n = @max(eightbytes(v.type.size), 1);
        for (0..n) |w| switch (v.type.eightbyte(w)) {
            .sse => {
                try self.loadEightbyteToSse(sse_regs[sse_i], arg, w);
                sse_i += 1;
            },
            .int => {
                try self.loadEightbyteToGp(returnGpReg(gp_i), arg, w);
                gp_i += 1;
            },
            .none, .mem => {},
        };
    }

    pub fn wrapFrame(self: *Lower) !void {
        const a = self.assembler.allocator;
        const emitted = try self.assembler.array.toOwnedSlice(a);
        defer a.free(emitted);

        self.assembler.array = try std.ArrayList(Instruction).initCapacity(a, emitted.len + 6);
        try self.assembler.push(.rbp);
        try self.assembler.mov(.store, .rbp, .rsp, null);
        const frame: u32 = @intCast(std.mem.Alignment.@"16".forward(@as(usize, @intCast(-self.local_offset))));
        // Empty frame: rsp is already 16-aligned after `push rbp`.
        if (frame > 0)
            try self.assembler.imm32(.sub, .rsp, frame);
        try self.assembler.appendInsnSlice(emitted);
        try self.assembler.mov(.store, .rsp, .rbp, null);
        try self.assembler.pop(.rbp);
        try self.assembler.ret();
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
            .immediate => |b| try self.assembler.mov_imm(dest, b),
            .pointer => |p| try self.assembler.mov_imm(dest, @intFromPtr(p)),
        }
    }

    fn loadVregToGp(self: *Lower, dest: Register, v: ir.VReg, word: usize) !void {
        const add: i32 = @intCast(word * 8);
        const size: usize = if (word == 0) self.slots[v.int()].type.size else 8;
        const already_here = switch (self.slots[v.int()].where) {
            .gp => |r| word == 0 and r.withBitSize(8) == dest.withBitSize(8),
            else => false,
        };
        if (!already_here) try self.takeGp(dest);
        switch (self.slots[v.int()].where) {
            .gp => |r| {
                std.debug.assert(word == 0);
                try self.gpCopySized(dest, r, size);
            },
            .stack => |d| try self.gpLoadSized(dest, .rbp, d + add, size),
            .sse => |r| {
                std.debug.assert(word == 0);
                const scratch = self.ensureScratch();
                if (self.slots[v.int()].type.size <= 4)
                    try self.assembler.movss(.store, .rbp, r, scratch)
                else
                    try self.assembler.movsd(.store, .rbp, r, scratch);
                try self.assembler.mov(.load, dest.withBitSize(8), .rbp, scratch);
            },
            .none => {
                // Dead unused vreg should never be loaded.
                std.debug.assert(self.used(v));
                try self.spill(v);
                try self.gpLoadSized(dest, .rbp, self.slots[v.int()].home.? + add, size);
            },
        }
    }

    fn loadEightbyteToGp(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        switch (arg.ref) {
            .virtual => |v| try self.loadVregToGp(dest, v, word),
            .immediate => |bits| {
                std.debug.assert(word == 0);
                try self.assembler.mov_imm(dest, bits);
            },
            .pointer => |p| {
                std.debug.assert(word == 0);
                try self.assembler.mov_imm(dest, @intFromPtr(p));
            },
        }
    }

    fn loadEightbyteToSse(self: *Lower, dest: Register, arg: ir.Arg, word: usize) !void {
        const add: i32 = @intCast(word * 8);
        const scalar_ss = arg.type.size == 4 and word == 0;
        switch (arg.ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .sse => |r| {
                    std.debug.assert(word == 0);
                    if (r == dest) return;
                    if (scalar_ss)
                        try self.assembler.movss(.load, dest, r, null)
                    else
                        try self.assembler.movsd(.load, dest, r, null);
                },
                .stack => |d| {
                    if (scalar_ss)
                        try self.assembler.movss(.load, dest, .rbp, d + add)
                    else
                        try self.assembler.movsd(.load, dest, .rbp, d + add);
                },
                .gp => |r| {
                    const scratch = self.ensureScratch();
                    try self.assembler.mov(.store, .rbp, r.withBitSize(8), scratch);
                    if (scalar_ss)
                        try self.assembler.movss(.load, dest, .rbp, scratch)
                    else
                        try self.assembler.movsd(.load, dest, .rbp, scratch);
                },
                .none => {
                    try self.spill(v);
                    try self.loadEightbyteToSse(dest, arg, word);
                },
            },
            .immediate => |bits| {
                try self.assembler.mov_imm(.rax, bits);
                const scratch = self.ensureScratch();
                try self.assembler.mov(.store, .rbp, .rax, scratch);
                if (scalar_ss)
                    try self.assembler.movss(.load, dest, .rbp, scratch)
                else
                    try self.assembler.movsd(.load, dest, .rbp, scratch);
            },
            .pointer => unreachable,
        }
    }

    fn copyMemToDisp(self: *Lower, src_base: Register, src_off: i32, dst_disp: i32, size: usize) !void {
        try self.takeGp(.rax);
        const words = eightbytes(size);
        var w: usize = 0;
        while (w + 1 <= words) : (w += 1) {
            const left = size - w * 8;
            const chunk: usize = if (left >= 8) 8 else left;
            const sd = src_off + @as(i32, @intCast(w * 8));
            const dd = dst_disp + @as(i32, @intCast(w * 8));
            try self.loadSized(.rax, src_base, sd, chunk);
            try self.storeSized(.rbp, dd, .rax, chunk);
        }
        if (size > 0 and words == 0) {
            try self.loadSized(.rax, src_base, src_off, size);
            try self.storeSized(.rbp, dst_disp, .rax, size);
        }
    }

    fn copyRefToMem(self: *Lower, ref: ir.Ref, ty: common.Type, dst_base: Register, dst_off: i32) !void {
        switch (ref) {
            .virtual => |v| switch (self.slots[v.int()].where) {
                .stack => |d| {
                    try self.takeGp(.rax);
                    const size = ty.size;
                    const words = eightbytes(@max(size, 1));
                    for (0..words) |w| {
                        const left = if (size > w * 8) size - w * 8 else 8;
                        const chunk: usize = if (left >= 8) 8 else if (size == 0) 8 else left;
                        const sd = d + @as(i32, @intCast(w * 8));
                        const dd = dst_off + @as(i32, @intCast(w * 8));
                        try self.loadSized(.rax, .rbp, sd, if (size == 0) 8 else chunk);
                        try self.storeSized(dst_base, dd, .rax, if (size == 0) 8 else chunk);
                    }
                },
                .gp => |r| try self.storeSized(dst_base, dst_off, r, @max(ty.size, 1)),
                .sse => |r| {
                    if (ty.size <= 4)
                        try self.assembler.movss(.store, dst_base, r, dst_off)
                    else
                        try self.assembler.movsd(.store, dst_base, r, dst_off);
                },
                .none => {
                    try self.spill(v);
                    try self.copyRefToMem(ref, ty, dst_base, dst_off);
                },
            },
            .immediate => |bits| {
                try self.takeGp(.rax);
                try self.assembler.mov_imm(.rax, bits);
                try self.storeSized(dst_base, dst_off, .rax, @max(ty.size, 1));
            },
            .pointer => |p| {
                try self.takeGp(.rax);
                try self.assembler.mov_imm(.rax, @intFromPtr(p));
                try self.assembler.mov(.store, dst_base, .rax, dst_off);
            },
        }
    }

    fn loadSized(self: *Lower, dest: Register, base: Register, disp: i32, size: usize) !void {
        switch (size) {
            1, 2 => try self.assembler.movzx(dest.withBitSize(8), base, disp, @intCast(size)),
            3...4 => try self.assembler.mov(.load, dest.withBitSize(4), base, disp),
            else => try self.assembler.mov(.load, dest.withBitSize(8), base, disp),
        }
    }

    fn storeSized(self: *Lower, base: Register, disp: i32, src: Register, size: usize) !void {
        switch (size) {
            1 => try self.assembler.mov(.store, base, src.withBitSize(1), disp),
            2 => try self.assembler.mov(.store, base, src.withBitSize(2), disp),
            3...4 => try self.assembler.mov(.store, base, src.withBitSize(4), disp),
            else => try self.assembler.mov(.store, base, src.withBitSize(8), disp),
        }
    }
};

fn jitFn(bytes: []const u8) !mem.Block {
    const dynm = try mem.Block.initWithBytes(bytes);
    try dynm.executable();
    return dynm;
}

test "code call through param1 noargs is mov r11, rsi" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{ .pointer, .pointer }, .void);
    defer c.deinit();

    _ = c.param(0);
    const fn_ptr = c.param(1);
    _ = try c.call(.value(fn_ptr), &.{}, .void);

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);

    // param1 is rsi on SysV and rdx on Windows. A Windows call also reserves
    // the 32-byte shadow space even when every argument is in a register.
    const expected: []const u8 = switch (CallingConvention) {
        .SystemV => &.{
            0x55, // push rbp
            0x48, 0x89, 0xE5, // mov rbp, rsp
            0x4C, 0x8B, 0xDE, // mov r11, rsi
            0x41, 0xFF, 0xD3, // call r11
            0x48, 0x89, 0xEC, // mov rsp, rbp
            0x5D, // pop rbp
            0xC3, // ret
        },
        .Windows => &.{
            0x55, // push rbp
            0x48, 0x89, 0xE5, // mov rbp, rsp
            0x4C, 0x8B, 0xDA, // mov r11, rdx
            0x48, 0x81, 0xEC, 0x20, 0x00, 0x00, 0x00, // sub rsp, 32
            0x41, 0xFF, 0xD3, // call r11
            0x48, 0x81, 0xC4, 0x20, 0x00, 0x00, 0x00, // add rsp, 32
            0x48, 0x89, 0xEC, // mov rsp, rbp
            0x5D, // pop rbp
            0xC3, // ret
        },
    };
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "windows outgoing stack args start after shadow space" {
    if (comptime CallingConvention != .Windows) return error.SkipZigTest;

    const args: [6]common.Type = @splat(.int64);
    const places = classify(&args, false);
    try std.testing.expectEqual(Place{ .gp = 0 }, places[0]);
    try std.testing.expectEqual(Place{ .gp = 3 }, places[3]);
    // classify counts from 0. outgoingStackDisp adds the 32-byte home.
    try std.testing.expectEqual(Place{ .stack = 0 }, places[4]);
    try std.testing.expectEqual(Place{ .stack = 8 }, places[5]);
    try std.testing.expectEqual(@as(i32, 32), outgoingStackDisp(0));
    try std.testing.expectEqual(@as(i32, 40), outgoingStackDisp(8));
    // 32-byte home plus two 8-byte slots, rounded to 16.
    try std.testing.expectEqual(@as(u32, 48), outgoingBytes(&args, &places, false));
}

test "code identity i64" {
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

test "code test" {
    const allocator = std.testing.allocator;
    var code = try Code.init(allocator, &.{ .pointer, .pointer }, .void);
    defer code.deinit();

    _ = code.param(0);
    const fn_ptr = code.param(1);
    _ = try code.call(.value(fn_ptr), &.{}, .void);

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const block = try mem.Block.initWithBytes(bytes);
    defer block.deinit();
    try block.executable();
}

test "code compileInto reuses buffer" {
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

test "code call add(i64,i64) i64" {
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: i64, b: i64) callconv(.c) i64 {
            return a + b;
        }
    }.inner;

    var c = try Code.init(allocator, &.{ .int64, .int64 }, .int64);
    defer c.deinit();

    const r = try c.call(.imm(@ptrCast(&add)), &.{ c.param(0), c.param(1) }, .int64);

    const bytes = try c.compileAlloc(allocator, r);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn (i64, i64) callconv(.c) i64 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(i64, 12), f(5, 7));
}

test "code nested call return feeds next arg" {
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: i64, b: i64) callconv(.c) i64 {
            return a + b;
        }
    }.inner;

    var c = try Code.init(allocator, &.{}, .int64);
    defer c.deinit();

    const one: Code.Value = .imm(.int64, 1);
    const two: Code.Value = .imm(.int64, 2);
    const three: Code.Value = .imm(.int64, 3);
    const inner = (try c.call(.imm(@ptrCast(&add)), &.{ one, two }, .int64)).?;
    const r = try c.call(.imm(@ptrCast(&add)), &.{ inner, three }, .int64);

    const bytes = try c.compileAlloc(allocator, r);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i64 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(i64, 6), f());
}

test "code Callee.value function pointer param" {
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: i64, b: i64) callconv(.c) i64 {
            return a + b;
        }
    }.inner;

    var c = try Code.init(allocator, &.{ .pointer, .int64, .int64 }, .int64);
    defer c.deinit();

    const r = try c.call(.value(c.param(0)), &.{ c.param(1), c.param(2) }, .int64);
    const bytes = try c.compileAlloc(allocator, r);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn (*const fn (i64, i64) callconv(.c) i64, i64, i64) callconv(.c) i64 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(i64, 12), f(&add, 5, 7));
}

test "code void inner call and void compile" {
    const allocator = std.testing.allocator;
    const box = struct {
        var n: i64 = 0;
        fn bump() callconv(.c) void {
            n += 1;
        }
    };

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    _ = try c.call(.imm(@ptrCast(&box.bump)), &.{}, .void);
    _ = try c.call(.imm(@ptrCast(&box.bump)), &.{}, .void);

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);

    box.n = 0;
    f();

    try std.testing.expectEqual(@as(i64, 2), box.n);
}

test "code addrOf passes pointer into same frame" {
    const allocator = std.testing.allocator;
    const write = struct {
        fn inner(p: *i64) callconv(.c) void {
            p.* = 99;
        }
    }.inner;

    var c = try Code.init(allocator, &.{}, .int64);
    defer c.deinit();

    const slot = try c.alloc(.int64);
    const p = try c.addrOf(slot);
    _ = try c.call(.imm(@ptrCast(&write)), &.{p}, .void);

    const bytes = try c.compileAlloc(allocator, slot);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i64 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(i64, 99), f());
}

test "code alloc [3]f32 + addrOf" {
    const allocator = std.testing.allocator;
    const vec3 = try x86_64.createStruct(allocator, &.{ .float32, .float32, .float32 }, null);
    defer vec3.free(allocator);

    const fill = struct {
        fn inner(p: [*]f32) callconv(.c) void {
            p[0] = 1.5;
            p[1] = 2.5;
            p[2] = 3.5;
        }
    }.inner;

    const read0 = struct {
        fn inner(p: [*]const f32) callconv(.c) f32 {
            return p[0] + p[1] + p[2];
        }
    }.inner;

    var c = try Code.init(allocator, &.{}, .float32);
    defer c.deinit();

    const buf = try c.alloc(vec3);
    const p = try c.addrOf(buf);
    _ = try c.call(.imm(@ptrCast(&fill)), &.{p}, .void);
    const sum = try c.call(.imm(@ptrCast(&read0)), &.{p}, .float32);

    const bytes = try c.compileAlloc(allocator, sum);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) f32 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(f32, 7.5), f());
}

test "code multi-call body with baked array (lua-shaped)" {
    const allocator = std.testing.allocator;

    const ctx = struct {
        var seen_l: usize = 0;
        var seen_res: i32 = 0;
        fn ext1(l: usize) callconv(.c) i32 {
            std.testing.expectEqual(@as(usize, 0x11), l) catch @panic("ext1 L");
            return 3;
        }
        fn ext2(l: usize) callconv(.c) i8 {
            std.testing.expectEqual(@as(usize, 0x11), l) catch @panic("ext2 L");
            return 4;
        }
        fn ext3(l: usize, res: i32) callconv(.c) void {
            seen_l = l;
            seen_res = res;
        }
        fn target(a: i32, b: i8, p: usize) callconv(.c) i32 {
            std.testing.expectEqual(@as(i32, 3), a) catch @panic("target a");
            std.testing.expectEqual(@as(i8, 4), b) catch @panic("target b");
            std.testing.expectEqual(@as(usize, 0x22), p) catch @panic("target p");
            return a + b;
        }
    };

    var table = [_]usize{0x22};
    const L: usize = 0x11;

    var c = try Code.init(allocator, &.{ .pointer, .pointer }, .void);
    defer c.deinit();

    const l = c.param(0);
    const fn_ptr = c.param(1);
    const a = (try c.call(.imm(@ptrCast(&ctx.ext1)), &.{l}, .int32)).?;
    const b = (try c.call(.imm(@ptrCast(&ctx.ext2)), &.{l}, .int8)).?;
    const arr: Code.Value = .symbol(@ptrCast(&table));
    const p = try c.index(arr, 0, .pointer);
    const res = (try c.call(.value(fn_ptr), &.{ a, b, p }, .int32)).?;
    _ = try c.call(.imm(@ptrCast(&ctx.ext3)), &.{ l, res }, .void);

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn (usize, *const fn (i32, i8, usize) callconv(.c) i32) callconv(.c) void = @ptrCast(dynm.buffer);

    ctx.seen_l = 0;
    ctx.seen_res = 0;
    f(L, &ctx.target);
    try std.testing.expectEqual(L, ctx.seen_l);
    try std.testing.expectEqual(@as(i32, 7), ctx.seen_res);
}

test "code call add(f64, f64) f64" {
    const allocator = std.testing.allocator;
    const add = struct {
        fn inner(a: f64, b: f64) callconv(.c) f64 {
            return a + b;
        }
    }.inner;

    var c = try Code.init(allocator, &.{ .float64, .float64 }, .float64);
    defer c.deinit();

    const r = try c.call(.{ .immediate = @ptrCast(&add) }, &.{ c.param(0), c.param(1) }, .float64);

    const bytes = try c.compileAlloc(allocator, r);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn (f64, f64) callconv(.c) f64 = @ptrCast(dynm.buffer);

    try std.testing.expectEqual(@as(f64, 12.5), f(5.0, 7.5));
}

test "code i8 store does not clobber neighbor" {
    const allocator = std.testing.allocator;
    const set = struct {
        fn inner(p: *i8) callconv(.c) void {
            p.* = 7;
        }
    }.inner;

    const Pair = extern struct { a: i8, b: i8 };
    const pair_ty = try x86_64.createStruct(allocator, &.{ .int8, .int8 }, null);
    defer pair_ty.free(allocator);

    var c = try Code.init(allocator, &.{}, pair_ty);
    defer c.deinit();

    const pair = try c.alloc(pair_ty);
    // Zero the pair, then write only the first byte through a C call.
    try c.store(try c.addrOf(pair), 0, .imm(.int16, 0x1111));
    const p0 = try c.addrOf(pair);
    _ = try c.call(.imm(@ptrCast(&set)), &.{p0}, .void);

    const bytes = try c.compileAlloc(allocator, pair);
    defer allocator.free(bytes);

    const dynm = try jitFn(bytes);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) Pair = @ptrCast(dynm.buffer);

    const got = f();
    try std.testing.expectEqual(@as(i8, 7), got.a);
    try std.testing.expectEqual(@as(i8, 0x11), got.b);
}

fn execCode(c: *Code, ret: ?Value) !mem.Block {
    const bytes = try c.compileAlloc(std.testing.allocator, ret);
    defer std.testing.allocator.free(bytes);
    return jitFn(bytes);
}

/// Writes xmm0 and rax so a later reload cannot pass by leaving the
/// caller's registers untouched.
fn wipeCallerSaved(x: f64, n: i64) callconv(.c) i64 {
    _ = x;
    _ = n;
    return 0;
}

fn sysvSplit() !void {
    if (comptime CallingConvention == .Windows) return error.SkipZigTest;
}

test "code struct(f32, f32, i32, i32) arg" {
    // Low chunk SSE, high chunk INTEGER. The call must use xmm0 and a GPR.
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f32, b: f32, c: i32, d: i32 };
    const take = struct {
        fn inner(s: Sample) callconv(.c) void {
            std.testing.expectEqual(@as(f32, 1.5), s.a) catch @panic("s.a");
            std.testing.expectEqual(@as(f32, 2.5), s.b) catch @panic("s.b");
            std.testing.expectEqual(@as(i32, 7), s.c) catch @panic("s.c");
            std.testing.expectEqual(@as(i32, 9), s.d) catch @panic("s.d");
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float32, .float32, .int32, .int32 }, null);
    defer ty.free(allocator);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, ty.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.int, ty.eightbytes.high);
    try std.testing.expectEqual(common.Type.Class.int, ty.class);
    try std.testing.expectEqual(@sizeOf(Sample), ty.size);

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    const slot = try c.alloc(ty);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.float32, @as(u32, @bitCast(@as(f32, 1.5)))));
    try c.store(p, 4, .imm(.float32, @as(u32, @bitCast(@as(f32, 2.5)))));
    try c.store(p, 8, .imm(.int32, 7));
    try c.store(p, 12, .imm(.int32, 9));
    _ = try c.call(.imm(@ptrCast(&take)), &.{slot}, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    f();
}

test "code struct(f64, i64) arg" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f64, b: i64 };
    const take = struct {
        fn inner(s: Sample) callconv(.c) void {
            std.testing.expectEqual(@as(f64, 1.5), s.a) catch @panic("s.a");
            std.testing.expectEqual(@as(i64, 42), s.b) catch @panic("s.b");
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, ty.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.int, ty.eightbytes.high);

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    const slot = try c.alloc(ty);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.float64, @bitCast(@as(f64, 1.5))));
    try c.store(p, 8, .imm(.int64, 42));
    _ = try c.call(.imm(@ptrCast(&take)), &.{slot}, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    f();
}

test "code struct(i32, f64) arg" {
    // INTEGER chunk, then SSE. The f64 sits at offset 8.
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: i32, b: f64 };
    const take = struct {
        fn inner(s: Sample) callconv(.c) void {
            std.testing.expectEqual(@as(i32, 7), s.a) catch @panic("s.a");
            std.testing.expectEqual(@as(f64, 1.5), s.b) catch @panic("s.b");
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .int32, .float64 }, null);
    defer ty.free(allocator);
    try std.testing.expectEqual(common.Type.Eightbyte.int, ty.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.sse, ty.eightbytes.high);
    try std.testing.expectEqual(@sizeOf(Sample), ty.size);

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    const slot = try c.alloc(ty);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.int32, 7));
    try c.store(p, 8, .imm(.float64, @bitCast(@as(f64, 1.5))));
    _ = try c.call(.imm(@ptrCast(&take)), &.{slot}, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    f();
}

test "code struct(f32, i32) arg" {
    // Both fields share one eightbyte, merged to INTEGER.
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f32, b: i32 };
    const take = struct {
        fn inner(s: Sample) callconv(.c) void {
            std.testing.expectEqual(@as(f32, 1.5), s.a) catch @panic("s.a");
            std.testing.expectEqual(@as(i32, 7), s.b) catch @panic("s.b");
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float32, .int32 }, null);
    defer ty.free(allocator);
    try std.testing.expectEqual(common.Type.Eightbyte.int, ty.eightbytes.low);
    try std.testing.expectEqual(common.Type.Eightbyte.none, ty.eightbytes.high);

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    const slot = try c.alloc(ty);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.float32, @as(u32, @bitCast(@as(f32, 1.5)))));
    try c.store(p, 4, .imm(.int32, 7));
    _ = try c.call(.imm(@ptrCast(&take)), &.{slot}, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    f();
}

test "code struct(f32, f32, i32, i32) param" {
    // Park the incoming pair, wipe xmm0/rax, then return it in those registers.
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f32, b: f32, c: i32, d: i32 };
    const ty = try x86_64.createStruct(allocator, &.{ .float32, .float32, .int32, .int32 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{ty}, ty);
    defer c.deinit();

    const s = c.param(0);
    _ = try c.call(.imm(@ptrCast(&wipeCallerSaved)), &.{ .imm(.float64, 0), .imm(.int64, 0) }, .int64);

    const dynm = try execCode(&c, s);
    defer dynm.deinit();

    const f: *const fn (Sample) callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f(.{ .a = 1.5, .b = 2.5, .c = 7, .d = 9 });
    try std.testing.expectEqual(@as(f32, 1.5), got.a);
    try std.testing.expectEqual(@as(f32, 2.5), got.b);
    try std.testing.expectEqual(@as(i32, 7), got.c);
    try std.testing.expectEqual(@as(i32, 9), got.d);
}

test "code struct(f64, i64) param" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f64, b: i64 };
    const ty = try x86_64.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{ty}, ty);
    defer c.deinit();

    const s = c.param(0);
    _ = try c.call(.imm(@ptrCast(&wipeCallerSaved)), &.{ .imm(.float64, 0), .imm(.int64, 0) }, .int64);

    const dynm = try execCode(&c, s);
    defer dynm.deinit();

    const f: *const fn (Sample) callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f(.{ .a = 1.5, .b = 42 });
    try std.testing.expectEqual(@as(f64, 1.5), got.a);
    try std.testing.expectEqual(@as(i64, 42), got.b);
}

test "code struct(i32, f64) param" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: i32, b: f64 };
    const ty = try x86_64.createStruct(allocator, &.{ .int32, .float64 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{ty}, ty);
    defer c.deinit();

    const s = c.param(0);
    _ = try c.call(.imm(@ptrCast(&wipeCallerSaved)), &.{ .imm(.float64, 0), .imm(.int64, 0) }, .int64);

    const dynm = try execCode(&c, s);
    defer dynm.deinit();

    const f: *const fn (Sample) callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f(.{ .a = 7, .b = 1.5 });
    try std.testing.expectEqual(@as(i32, 7), got.a);
    try std.testing.expectEqual(@as(f64, 1.5), got.b);
}

test "code struct(f32, f32, i32, i32) return" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f32, b: f32, c: i32, d: i32 };
    const make = struct {
        fn inner() callconv(.c) Sample {
            return .{ .a = 1.5, .b = 2.5, .c = 7, .d = 9 };
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float32, .float32, .int32, .int32 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{}, ty);
    defer c.deinit();

    const r = try c.call(.imm(@ptrCast(&make)), &.{}, ty);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f();
    try std.testing.expectEqual(@as(f32, 1.5), got.a);
    try std.testing.expectEqual(@as(f32, 2.5), got.b);
    try std.testing.expectEqual(@as(i32, 7), got.c);
    try std.testing.expectEqual(@as(i32, 9), got.d);
}

test "code struct(f64, i64) return" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f64, b: i64 };
    const make = struct {
        fn inner() callconv(.c) Sample {
            return .{ .a = 1.5, .b = 42 };
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{}, ty);
    defer c.deinit();

    const r = try c.call(.imm(@ptrCast(&make)), &.{}, ty);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f();
    try std.testing.expectEqual(@as(f64, 1.5), got.a);
    try std.testing.expectEqual(@as(i64, 42), got.b);
}

test "code struct(i32, f64) return" {
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: i32, b: f64 };
    const make = struct {
        fn inner() callconv(.c) Sample {
            const result: Sample = .{ .a = 7, .b = 1.5 };
            // Debug builds leave the f64 bits in rdx. SysV returns that chunk in xmm0.
            asm volatile ("xor %%rdx, %%rdx" ::: .{ .rdx = true });
            return result;
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .int32, .float64 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{}, ty);
    defer c.deinit();

    const r = try c.call(.imm(@ptrCast(&make)), &.{}, ty);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) Sample = @ptrCast(dynm.buffer);
    const got = f();
    try std.testing.expectEqual(@as(i32, 7), got.a);
    try std.testing.expectEqual(@as(f64, 1.5), got.b);
}

test "code struct(f64, i64) spills after 8 f64" {
    // xmm0–xmm7 are full, so the mixed struct goes to the stack as a whole.
    try sysvSplit();
    const allocator = std.testing.allocator;
    const Sample = extern struct { a: f64, b: i64 };
    const take = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, s: Sample) callconv(.c) void {
            std.testing.expectEqual(@as(f64, 1), a) catch @panic("a");
            std.testing.expectEqual(@as(f64, 2), b) catch @panic("b");
            std.testing.expectEqual(@as(f64, 3), c) catch @panic("c");
            std.testing.expectEqual(@as(f64, 4), d) catch @panic("d");
            std.testing.expectEqual(@as(f64, 5), e) catch @panic("e");
            std.testing.expectEqual(@as(f64, 6), f) catch @panic("f");
            std.testing.expectEqual(@as(f64, 7), g) catch @panic("g");
            std.testing.expectEqual(@as(f64, 8), h) catch @panic("h");
            std.testing.expectEqual(@as(f64, 9.5), s.a) catch @panic("s.a");
            std.testing.expectEqual(@as(i64, 42), s.b) catch @panic("s.b");
        }
    }.inner;

    const ty = try x86_64.createStruct(allocator, &.{ .float64, .int64 }, null);
    defer ty.free(allocator);

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    const nums = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var args: [9]Value = undefined;
    for (nums, 0..) |n, i|
        args[i] = .imm(.float64, @bitCast(n));

    const slot = try c.alloc(ty);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.float64, @bitCast(@as(f64, 9.5))));
    try c.store(p, 8, .imm(.int64, 42));
    args[8] = slot;
    _ = try c.call(.imm(@ptrCast(&take)), &args, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    f();
}

/// Zig writes a u8 return with `mov al, imm` in both Debug and ReleaseFast,
/// so bits 8–63 of rax stay whatever the caller left there. Fill them with
/// this pattern before the u8 return so leftover bits are a known value.
const u8_poison: u64 = 0xDEAD_BEEF_DEAD_BE00;
const u8_low: u8 = 0x42;

fn jitPoisonRax() !mem.Block {
    var b = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer b.deinit();

    try b.mov_imm(.rax, u8_poison | 0xFF);
    try b.ret();

    const bytes = try b.compile(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    return jitFn(bytes);
}

/// ReleaseFast `fn (in: u8) callconv(.c) i32 { return @intCast(in); }` is
/// `mov eax, edi` with no mask. Debug inserts `movzbl`, which hides the leak.
fn jitWidenFirstGp() !mem.Block {
    var b = try AssemblyBuilder.initCapacity(std.testing.allocator, 4);
    defer b.deinit();

    try b.mov(.load, .eax, gp_regs[0].withBitSize(4), null);
    try b.ret();

    const bytes = try b.compile(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    return jitFn(bytes);
}

test "code u8 return high bits no leak into next u8 arg" {
    const allocator = std.testing.allocator;
    const ret_u8 = struct {
        fn inner() callconv(.c) u8 {
            return u8_low;
        }
    }.inner;

    const poison = try jitPoisonRax();
    defer poison.deinit();
    const widen = try jitWidenFirstGp();
    defer widen.deinit();

    var c = try Code.init(allocator, &.{}, .int32);
    defer c.deinit();

    _ = try c.call(.imm(@ptrCast(poison.buffer.ptr)), &.{}, .int64);
    const v = (try c.call(.imm(@ptrCast(&ret_u8)), &.{}, .int8)).?;
    const r = try c.call(.imm(@ptrCast(widen.buffer.ptr)), &.{v}, .int32);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u8_low), f());
}

test "code u8 return into zig @intCast(u8) i32" {
    const allocator = std.testing.allocator;
    const box = struct {
        var b: i32 = 0;
        fn ret() callconv(.c) u8 {
            return u8_low;
        }
        fn take(in: u8) callconv(.c) void {
            b = @intCast(in);
        }
    };

    const poison = try jitPoisonRax();
    defer poison.deinit();

    var c = try Code.init(allocator, &.{}, .void);
    defer c.deinit();

    _ = try c.call(.imm(@ptrCast(poison.buffer.ptr)), &.{}, .int64);
    const v = (try c.call(.imm(@ptrCast(&box.ret)), &.{}, .int8)).?;
    _ = try c.call(.imm(@ptrCast(&box.take)), &.{v}, .void);

    const dynm = try execCode(&c, null);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    box.b = 0;
    f();
    try std.testing.expectEqual(@as(i32, u8_low), box.b);
}

test "code u8 load after dirty rax leaks into next u8 arg" {
    // `loadSized` of 1 byte is `mov al, [mem]`
    const allocator = std.testing.allocator;
    const poison = try jitPoisonRax();
    defer poison.deinit();
    const widen = try jitWidenFirstGp();
    defer widen.deinit();

    var c = try Code.init(allocator, &.{}, .int32);
    defer c.deinit();

    const slot = try c.alloc(.int8);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.int8, u8_low));
    _ = try c.call(.imm(@ptrCast(poison.buffer.ptr)), &.{}, .int64);
    const v = try c.load(p, 0, .int8);
    const r = try c.call(.imm(@ptrCast(widen.buffer.ptr)), &.{v}, .int32);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u8_low), f());
}

test "code u8 immediate arg no leak high bits" {
    const allocator = std.testing.allocator;
    const poison = try jitPoisonRax();
    defer poison.deinit();
    const widen = try jitWidenFirstGp();
    defer widen.deinit();

    var c = try Code.init(allocator, &.{}, .int32);
    defer c.deinit();

    _ = try c.call(.imm(@ptrCast(poison.buffer.ptr)), &.{}, .int64);
    const r = try c.call(.imm(@ptrCast(widen.buffer.ptr)), &.{.imm(.int8, u8_low)}, .int32);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u8_low), f());
}

test "code u8 param high bits no leak into next arg" {
    const allocator = std.testing.allocator;
    const widen = try jitWidenFirstGp();
    defer widen.deinit();

    var c = try Code.init(allocator, &.{.int8}, .int32);
    defer c.deinit();

    const r = try c.call(.imm(@ptrCast(widen.buffer.ptr)), &.{c.param(0)}, .int32);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn (u64) callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u8_low), f(u8_poison | u8_low));
}

test "code u8 param return zero-extends" {
    const allocator = std.testing.allocator;
    var c = try Code.init(allocator, &.{.int8}, .int32);
    defer c.deinit();

    const dynm = try execCode(&c, c.param(0));
    defer dynm.deinit();

    const f: *const fn (u64) callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u8_low), f(u8_poison | u8_low));
}

const u16_low: u16 = 0x1234;

test "code u16 load after dirty rax zero-extends into next arg" {
    const allocator = std.testing.allocator;
    const poison = try jitPoisonRax();
    defer poison.deinit();
    const widen = try jitWidenFirstGp();
    defer widen.deinit();

    var c = try Code.init(allocator, &.{}, .int32);
    defer c.deinit();

    const slot = try c.alloc(.int16);
    const p = try c.addrOf(slot);
    try c.store(p, 0, .imm(.int16, u16_low));
    _ = try c.call(.imm(@ptrCast(poison.buffer.ptr)), &.{}, .int64);
    const v = try c.load(p, 0, .int16);
    const r = try c.call(.imm(@ptrCast(widen.buffer.ptr)), &.{v}, .int32);

    const dynm = try execCode(&c, r);
    defer dynm.deinit();

    const f: *const fn () callconv(.c) i32 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i32, u16_low), f());
}
