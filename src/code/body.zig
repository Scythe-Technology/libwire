const std = @import("std");

const common = @import("../common.zig");
const ir = @import("ir.zig");

/// Straight-line IR builder shared by the architecture backends.
///
/// `Backend` is the architecture file. It classifies C arguments and owns
/// `Lower`, which emits them. This file builds the instruction list and runs
/// the last-use scan. Register assignment and the prologue stay in `Backend`:
/// the three ABIs do not choose the same registers or stack slots.
///
/// `Backend` provides `AssemblyBuilder`, `Slot`, `Lower`, `isStructureReturn`,
/// `needsByPointer`, and `isObject`. `Lower` is constructed with `assembler`,
/// `slots`, and `last`, then `bindIncoming`, `emitInst`, `emitReturn`, and
/// `wrapFrame` are called in that order.
pub fn Code(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Value = ir.Value;
        pub const isStructureReturn = Backend.isStructureReturn;

        const AssemblyBuilder = Backend.AssemblyBuilder;

        assembler: AssemblyBuilder,
        param_types: []const common.Type,
        param_values: []Value,
        return_type: common.Type,
        instructions: std.ArrayList(ir.Inst),
        vreg_types: std.ArrayList(common.Type),
        structure_return_vreg: ?ir.VReg = null,
        @"return": ?Value = null,
        finished: bool = false,

        pub fn init(allocator: std.mem.Allocator, params: []const common.Type, return_type: common.Type) !Self {
            var assembler = try AssemblyBuilder.initCapacity(allocator, 64);
            errdefer assembler.deinit();

            const param_values = try assembler.allocator.alloc(Value, params.len);
            errdefer assembler.allocator.free(param_values);

            var instructions = try std.ArrayList(ir.Inst).initCapacity(allocator, 16);
            errdefer instructions.deinit(allocator);
            var vreg_types = try std.ArrayList(common.Type).initCapacity(allocator, params.len + 4);
            errdefer vreg_types.deinit(allocator);

            var self: Self = .{
                .assembler = assembler,
                .param_types = params,
                .param_values = param_values,
                .return_type = return_type,
                .instructions = instructions,
                .vreg_types = vreg_types,
            };

            const sret = isStructureReturn(return_type);
            for (params, 0..) |ty, i| {
                const vty: common.Type = if (Backend.needsByPointer(ty)) .pointer else ty;
                self.param_values[i] = .{
                    .type = vty,
                    .location = .{ .virtual = try self.newVirt(vty) },
                };
            }
            if (sret) self.structure_return_vreg = try self.newVirt(.pointer);
            return self;
        }

        pub fn deinit(self: *Self) void {
            const a = self.assembler.allocator;
            for (self.instructions.items) |inst| switch (inst) {
                .call => |c| a.free(c.arguments),
                else => {},
            };
            self.instructions.deinit(a);
            self.vreg_types.deinit(a);
            a.free(self.param_values);
            self.assembler.deinit();
        }

        pub fn builder(self: *Self) *AssemblyBuilder {
            return &self.assembler;
        }

        pub fn param(self: *const Self, i: usize) Value {
            return self.param_values[i];
        }

        pub fn alloc(self: *Self, ty: common.Type) !Value {
            const dst = try self.newVirt(ty);
            try self.instructions.append(self.gpa(), .{
                .allocate = .with(dst, ty),
            });
            return .{
                .type = ty,
                .location = .vreg(dst),
            };
        }

        pub fn addrOf(self: *Self, v: Value) !Value {
            const src = switch (v.location) {
                .virtual => |r| r,
                else => return error.NotInMemory,
            };
            const dst = try self.newVirt(.pointer);
            try self.instructions.append(self.gpa(), .{
                .address_of = .with(dst, src),
            });
            return .{
                .type = .pointer,
                .location = .vreg(dst),
            };
        }

        pub fn addrOfParam(self: *Self, v: Value, ty: common.Type) !Value {
            if (Backend.needsByPointer(ty)) return v;
            return try self.addrOf(v);
        }

        pub fn load(self: *Self, ptr: Value, byte_off: i32, ty: common.Type) !Value {
            const dst = try self.newVirt(ty);
            try self.instructions.append(self.gpa(), .{
                .load = .with(dst, ptr.location, byte_off, ty),
            });
            return .{
                .type = ty,
                .location = .vreg(dst),
            };
        }

        pub fn loadCallArg(self: *Self, ptr: Value, byte_off: i32, ty: common.Type) !Value {
            if (Backend.needsByPointer(ty)) return ptr;
            return try self.load(ptr, byte_off, ty);
        }

        pub fn store(self: *Self, ptr: Value, byte_off: i32, v: Value) !void {
            try self.instructions.append(self.gpa(), .{
                .store = .with(ptr.location, byte_off, v.location, v.type),
            });
        }

        pub fn index(self: *Self, base: Value, i: usize, elem_ty: common.Type) !Value {
            const off: i32 = @intCast(i * elem_ty.size);
            return self.load(base, off, elem_ty);
        }

        pub fn indexAddr(self: *Self, base: Value, i: usize, elem_ty: common.Type) !Value {
            const off: i32 = @intCast(i * elem_ty.size);
            const dst = try self.newVirt(.pointer);
            try self.instructions.append(self.gpa(), .{
                .load_effective_address = .{
                    .destination = dst,
                    .base = base.location,
                    .offset = off,
                },
            });
            return .{
                .type = .pointer,
                .location = .vreg(dst),
            };
        }

        pub fn call(self: *Self, callee: ir.Callee, args: []const Value, return_type: common.Type) !?Value {
            if (return_type.size == 0) {
                try self.recordCall(callee, args, return_type, null, null);
                return null;
            }
            if (isStructureReturn(return_type)) {
                const slot = try self.alloc(return_type);
                const dest = try self.addrOf(slot);
                try self.recordCall(callee, args, return_type, dest, null);
                return slot;
            }
            const dst = try self.newVirt(return_type);
            try self.recordCall(callee, args, return_type, null, dst);
            return .{
                .type = return_type,
                .location = .{ .virtual = dst },
            };
        }

        pub fn callInto(self: *Self, callee: ir.Callee, args: []const Value, return_type: common.Type, dest: Value) !void {
            if (return_type.size == 0) return error.InvalidReturnType;
            if (isStructureReturn(return_type)) {
                try self.recordCall(callee, args, return_type, dest, null);
                return;
            }
            const dst = try self.newVirt(return_type);
            try self.recordCall(callee, args, return_type, null, dst);
            try self.store(dest, 0, .{
                .type = return_type,
                .location = .vreg(dst),
            });
        }

        pub fn finish(self: *Self, ret: ?Value) !void {
            if (self.finished) return;
            if (self.return_type.size == 0) {
                if (ret != null) return error.TypeMismatch;
            } else {
                _ = ret orelse return error.MissingReturnValue;
            }
            self.@"return" = ret;
            try self.lower();
            self.finished = true;
        }

        pub fn machineCodeLen(self: *Self, ret: ?Value) !usize {
            try self.finish(ret);
            return self.assembler.encodedSize();
        }

        pub fn compileAlloc(self: *Self, allocator: std.mem.Allocator, ret: ?Value) ![]u8 {
            try self.finish(ret);
            const len = self.assembler.encodedSize();
            const slice = try allocator.alloc(u8, len);
            errdefer allocator.free(slice);
            const n = try self.assembler.encodeInto(slice);
            std.debug.assert(n == len);
            return slice;
        }

        pub fn compileInto(self: *Self, ret: ?Value, buf: []u8) !usize {
            try self.finish(ret);
            return self.assembler.encodeInto(buf);
        }

        fn gpa(self: *Self) std.mem.Allocator {
            return self.assembler.allocator;
        }

        fn newVirt(self: *Self, ty: common.Type) !ir.VReg {
            const id: ir.VReg = .fromInt(@intCast(self.vreg_types.items.len));
            try self.vreg_types.append(self.gpa(), ty);
            return id;
        }

        fn recordCall(
            self: *Self,
            callee: ir.Callee,
            args: []const Value,
            return_type: common.Type,
            sret_dest: ?Value,
            dst: ?ir.VReg,
        ) !void {
            std.debug.assert(args.len <= 32);
            const copy = try self.gpa().alloc(ir.Arg, args.len);
            errdefer self.gpa().free(copy);
            for (args, 0..) |a, i|
                copy[i] = .{ .ref = a.location, .type = a.type };
            try self.instructions.append(self.gpa(), .{
                .call = .stage(
                    dst,
                    callee,
                    copy,
                    return_type,
                    if (sret_dest) |d| d.location else null,
                ),
            });
        }

        fn lower(self: *Self) !void {
            const a = self.gpa();
            // `emitReturn` reads these after the last instruction. Without
            // this, last-use would drop a virtual return or the hidden
            // structure-return pointer before that read.
            var extra_buf: [2]ir.VReg = undefined;
            var n_extra: usize = 0;
            if (self.@"return") |r| {
                if (r.location == .virtual) {
                    extra_buf[n_extra] = r.location.virtual;
                    n_extra += 1;
                }
            }
            if (self.structure_return_vreg) |v| {
                extra_buf[n_extra] = v;
                n_extra += 1;
            }

            const last = try ir.lastUse(a, self.instructions.items, self.vreg_types.items.len, extra_buf[0..n_extra]);
            defer a.free(last);

            const slots = try a.alloc(Backend.Slot, self.vreg_types.items.len);
            defer a.free(slots);
            for (slots, self.vreg_types.items) |*s, ty| {
                s.* = .{
                    .type = ty,
                    .is_object = Backend.isObject(ty),
                };
            }

            var l: Backend.Lower = .{
                .assembler = &self.assembler,
                .slots = slots,
                .last = last,
            };
            try l.bindIncoming(self.param_types, self.param_values, self.structure_return_vreg, isStructureReturn(self.return_type));

            for (self.instructions.items, 0..) |inst, i| {
                l.instruction_idx = @intCast(i);
                try l.emitInst(inst);
            }
            l.instruction_idx = @intCast(self.instructions.items.len);
            try l.emitReturn(self.return_type, self.@"return", self.structure_return_vreg);
            try l.wrapFrame();
        }
    };
}
