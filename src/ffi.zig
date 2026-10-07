const std = @import("std");

const wire = @import("lib.zig");
const common = @import("common.zig");
const mem = @import("mem.zig");

pub const CallFn = fn (ptr: ?*const anyopaque, args: ?[*]const *anyopaque, ?*anyopaque) callconv(.c) void;
pub const CallInfo = struct {
    buffer: []align(mem.BlockAlignment) const u8,

    pub fn pointer(self: CallInfo) *const anyopaque {
        return @ptrCast(@alignCast(self.buffer.ptr));
    }
};

pub const ClosureInfo = struct {
    buffer: []align(mem.BlockAlignment) const u8,

    pub fn pointer(self: ClosureInfo) *const anyopaque {
        return @ptrCast(@alignCast(self.buffer.ptr));
    }
};

pub fn buildCallInvoker(
    allocator: std.mem.Allocator,
    param_types: []const common.Type,
    return_type: common.Type,
) !wire.Code {
    var c: wire.Code = try .init(allocator, &.{ .pointer, .pointer, .pointer }, .void);
    errdefer c.deinit();

    const fn_ptr = c.param(0);
    const args_arr = c.param(1);
    const ret_ptr = c.param(2);

    const call_args = try allocator.alloc(wire.Code.Value, param_types.len);
    defer allocator.free(call_args);

    for (param_types, 0..) |ty, i| {
        call_args[i] = try c.loadCallArg(try c.index(args_arr, i, .pointer), 0, ty);
    }

    if (return_type.size == 0) {
        _ = try c.call(.value(fn_ptr), call_args, .void);
    } else if (wire.Code.isStructureReturn(return_type)) {
        try c.callInto(.value(fn_ptr), call_args, return_type, ret_ptr);
    } else {
        const r = (try c.call(.value(fn_ptr), call_args, return_type)).?;
        try c.store(ret_ptr, 0, r);
    }

    return c;
}

/// The returned bytes are a C function with signature
/// `(param_types...) callconv(.c) return_type`. A call packs incoming
/// arguments into an array of pointers and invokes `handler` with the same
/// convention as `CallFn`: `handler(user_data, args, ret)`.
///
/// `user_data` is baked as a pointer value (the pointee may change later).
/// `handler` is baked as an absolute address.
pub fn buildClosureInvocator(
    allocator: std.mem.Allocator,
    param_types: []const common.Type,
    return_type: common.Type,
    handler: *const anyopaque,
    user_data: ?*anyopaque,
) !struct { wire.Code, ?wire.Code.Value } {
    var c: wire.Code = try .init(allocator, param_types, return_type);
    errdefer c.deinit();

    const ud: wire.Code.Value = if (user_data) |p|
        .symbol(p)
    else
        .imm(.pointer, 0);

    const args_ptr: wire.Code.Value = if (param_types.len == 0) .imm(.pointer, 0) else blk: {
        const arr_type: common.Type = .{
            .size = param_types.len * 8,
            .alignment = .@"8",
        };
        const arr = try c.alloc(arr_type);
        const arr_ptr = try c.addrOf(arr);
        for (param_types, 0..) |ty, i| {
            // Match buildCallInvoker: CallFn args[i] is a pointer to the value,
            // except Windows-by-pointer aggregates where args[i] *is* that pointer.
            const p = try c.addrOfParam(c.param(i), ty);
            try c.store(arr_ptr, @intCast(i * 8), p);
        }
        break :blk arr_ptr;
    };

    var return_slot: ?wire.Code.Value = null;
    const ret_ptr: wire.Code.Value = if (return_type.size == 0) .imm(.pointer, 0) else blk: {
        const slot = try c.alloc(return_type);
        return_slot = slot;
        break :blk try c.addrOf(slot);
    };

    _ = try c.call(
        .imm(handler),
        &.{ ud, args_ptr, ret_ptr },
        .void,
    );

    return .{ c, return_slot };
}

pub fn prepareCallInfo(
    allocator: std.mem.Allocator,
    pool: *mem.Pool,
    param_types: []const common.Type,
    return_type: common.Type,
) !CallInfo {
    var code = try buildCallInvoker(
        allocator,
        param_types,
        return_type,
    );
    defer code.deinit();
    return .{
        .buffer = try publish(allocator, pool, &code, null),
    };
}

pub fn prepareClosureInfo(
    allocator: std.mem.Allocator,
    pool: *mem.Pool,
    param_types: []const common.Type,
    return_type: common.Type,
    handler: *const fn (ud: ?*anyopaque, args: ?[*]const *anyopaque, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) !ClosureInfo {
    var code, const slot = try buildClosureInvocator(
        allocator,
        param_types,
        return_type,
        @ptrCast(@alignCast(handler)),
        user_data,
    );
    defer code.deinit();
    return .{
        .buffer = try publish(allocator, pool, &code, slot),
    };
}

fn publish(
    allocator: std.mem.Allocator,
    pool: *mem.Pool,
    code: *wire.Code,
    ret: ?wire.Code.Value,
) ![]align(mem.BlockAlignment) const u8 {
    const bytes = try code.compileAlloc(allocator, ret);
    defer allocator.free(bytes);
    return try pool.executable(bytes);
}

pub fn call(call_info: *CallInfo, fn_ptr: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) void {
    const call_fn_ffi: *const CallFn = @ptrCast(call_info.buffer);
    call_fn_ffi(fn_ptr, args, ret);
}

test "prepareCallInfo and prepareClosureInfo publish into one pool" {
    const allocator = std.testing.allocator;
    var pool: mem.Pool = .init(allocator);
    defer pool.deinit();

    const add = struct {
        fn inner(a: i8, b: i8) callconv(.c) i8 {
            return a + b;
        }
    }.inner;
    var call_info = try prepareCallInfo(allocator, &pool, &.{ .int8, .int8 }, .int8);

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;
    call(&call_info, @ptrCast(&add), &.{ &a, &b }, &res);
    try std.testing.expectEqual(@as(i8, 12), res);

    const handler = struct {
        fn inner(_: ?*anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const x = closureArg(i8, args.?, 0);
            const y = closureArg(i8, args.?, 1);
            closureRet(i8, ret.?).* = x.* + y.*;
        }
    }.inner;
    const closure = try prepareClosureInfo(allocator, &pool, &.{ .int8, .int8 }, .int8, handler, null);
    const f: *const fn (i8, i8) callconv(.c) i8 = @ptrCast(closure.pointer());
    try std.testing.expectEqual(@as(i8, 12), f(5, 7));
    try std.testing.expectEqual(@as(usize, 1), pool.pages.items.len);
}

fn closureArg(comptime T: type, args: [*]const *anyopaque, i: usize) *const T {
    return @ptrCast(@alignCast(args[i]));
}

fn closureRet(comptime T: type, ret: *anyopaque) *T {
    return @ptrCast(@alignCast(ret));
}

test "closure Add (i8, i8) i8" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const a = closureArg(i8, args.?, 0);
            const b = closureArg(i8, args.?, 1);
            std.testing.expectEqual(@as(i8, 5), a.*) catch @panic("a");
            std.testing.expectEqual(@as(i8, 7), b.*) catch @panic("b");
            closureRet(i8, ret.?).* = a.* + b.*;
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{ .int8, .int8 }, .int8, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (i8, i8) callconv(.c) i8 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i8, 12), f(5, 7));
}

test "closure user_data is visible and pointee can change" {
    const allocator = std.testing.allocator;
    const Box = struct {
        extra: i64,
        fn handler(ptr: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const box: *const @This() = @ptrCast(@alignCast(ptr));
            const a = closureArg(i64, args.?, 0);
            closureRet(i64, ret.?).* = a.* + box.extra;
        }
    };
    var box: Box = .{ .extra = 10 };

    var code, const slot = try buildClosureInvocator(allocator, &.{.int64}, .int64, Box.handler, @ptrCast(&box));
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (i64) callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 15), f(5));
    box.extra = 100;
    try std.testing.expectEqual(@as(i64, 105), f(5));
}

test "closure void no-args" {
    const allocator = std.testing.allocator;
    const box = struct {
        var n: i64 = 0;
        fn handler(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            std.testing.expect(args == null) catch @panic("args");
            std.testing.expect(ret == null) catch @panic("ret");
            n += 1;
        }
    };

    var code, const slot = try buildClosureInvocator(allocator, &.{}, .void, box.handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn () callconv(.c) void = @ptrCast(dynm.buffer);
    box.n = 0;
    f();
    f();
    try std.testing.expectEqual(@as(i64, 2), box.n);
}

test "closure no-args i64 return" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, _: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            closureRet(i64, ret.?).* = 42;
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{}, .int64, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn () callconv(.c) i64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 42), f());
}

test "closure Add (f64, f64) f64" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const a = closureArg(f64, args.?, 0);
            const b = closureArg(f64, args.?, 1);
            closureRet(f64, ret.?).* = a.* + b.*;
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{ .float64, .float64 }, .float64, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (f64, f64) callconv(.c) f64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(f64, 12.5), f(5.0, 7.5));
}

test "closure mixed i64 f64" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const a = closureArg(i64, args.?, 0);
            const b = closureArg(f64, args.?, 1);
            const c = closureArg(i64, args.?, 2);
            const d = closureArg(f64, args.?, 3);
            closureRet(f64, ret.?).* = @as(f64, @floatFromInt(a.* + c.*)) + b.* + d.*;
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(
        allocator,
        &.{ .int64, .float64, .int64, .float64 },
        .float64,
        handler,
        null,
    );
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (i64, f64, i64, f64) callconv(.c) f64 = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(f64, 10.5), f(1, 2.5, 3, 4.0));
}

test "closure small struct arg and return" {
    const allocator = std.testing.allocator;
    const Pair = extern struct { a: i64, b: i64 };
    const pair_ty: common.Type = try .@"struct"(allocator, &.{ .int64, .int64 }, null);
    defer pair_ty.free(allocator);

    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const in = closureArg(Pair, args.?, 0);
            closureRet(Pair, ret.?).* = .{ .a = in.a + 1, .b = in.b + 2 };
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{pair_ty}, pair_ty, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (Pair) callconv(.c) Pair = @ptrCast(dynm.buffer);

    const got = f(.{ .a = 5, .b = 7 });
    try std.testing.expectEqual(@as(i64, 6), got.a);
    try std.testing.expectEqual(@as(i64, 9), got.b);
}

test "closure large struct by memory" {
    const allocator = std.testing.allocator;
    const Big = extern struct { a: i64, b: i64, c: i64, d: i64 };
    const big_ty: common.Type = try .@"struct"(allocator, &.{
        .int64, .int64, .int64, .int64,
    }, null);
    defer big_ty.free(allocator);

    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const in = closureArg(Big, args.?, 0);
            std.testing.expectEqual(@as(i64, 5), in.a) catch @panic("a");
            std.testing.expectEqual(@as(i64, 7), in.b) catch @panic("b");
            std.testing.expectEqual(@as(i64, 9), in.c) catch @panic("c");
            std.testing.expectEqual(@as(i64, 11), in.d) catch @panic("d");
            closureRet(Big, ret.?).* = .{ .a = in.a + 1, .b = in.b, .c = in.c, .d = in.d };
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{big_ty}, big_ty, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (Big) callconv(.c) Big = @ptrCast(dynm.buffer);
    const got = f(.{ .a = 5, .b = 7, .c = 9, .d = 11 });
    try std.testing.expectEqual(@as(i64, 6), got.a);
    try std.testing.expectEqual(@as(i64, 7), got.b);
}

test "closure ten i64 args spill to stack" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            var sum: i64 = 0;
            for (0..10) |i| sum += closureArg(i64, args.?, i).*;
            closureRet(i64, ret.?).* = sum;
        }
    }.inner;

    const tys: [10]common.Type = @splat(.int64);
    var code, const slot = try buildClosureInvocator(allocator, &tys, .int64, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const F = *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;

    const f: F = @ptrCast(dynm.buffer);
    try std.testing.expectEqual(@as(i64, 55), f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10));
}

test "closure is callable through buildCallInvoker" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            closureRet(i8, ret.?).* = closureArg(i8, args.?, 0).* + closureArg(i8, args.?, 1).*;
        }
    }.inner;

    var code, const slot = try buildClosureInvocator(allocator, &.{ .int8, .int8 }, .int8, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const clos_mem = try mem.Block.initWithBytes(bytes);
    defer clos_mem.deinit();
    try clos_mem.executable();

    var tramp_code = try buildCallInvoker(allocator, &.{ .int8, .int8 }, .int8);
    defer tramp_code.deinit();

    const tramp_bytes = try tramp_code.compileAlloc(allocator, null);
    defer allocator.free(tramp_bytes);
    const tramp_mem = try mem.Block.initWithBytes(tramp_bytes);
    defer tramp_mem.deinit();
    try tramp_mem.executable();

    const call_fn: *const CallFn = @ptrCast(tramp_mem.buffer);
    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;
    call_fn(@ptrCast(clos_mem.buffer), &.{ &a, &b }, &res);
    try std.testing.expectEqual(@as(i8, 12), res);
}
