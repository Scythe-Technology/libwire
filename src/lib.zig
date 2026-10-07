const std = @import("std");
const builtin = @import("builtin");

const common = @import("common.zig");

pub const asmb = switch (builtin.cpu.arch) {
    .x86_64 => @import("asm/x86_64.zig"),
    .aarch64 => @import("asm/aarch64.zig"),
    .riscv64 => @import("asm/riscv64.zig"),
    else => Unsupported,
};

pub const mem = @import("mem.zig");
pub const ffi = @import("ffi.zig");

const code_backend = switch (builtin.cpu.arch) {
    .x86_64 => @import("code/x86_64.zig"),
    .aarch64 => @import("code/aarch64.zig"),
    .riscv64 => @import("code/riscv64.zig"),
    else => Unsupported,
};

const Unsupported = struct {};

pub const Code = code_backend.Code;

test {
    _ = mem;
    _ = ffi;
    // The file, not `Code`: the tests live beside the backend, and `Code`
    // is the shared builder instantiated from that file.
    _ = code_backend;
    // Encoding tests compare bytes. AArch64 and RISC-V parcels are
    // little-endian, same as this host, so they run here without executing
    // that code.
    if (comptime builtin.cpu.arch.endian() == .little) {
        _ = @import("asm/aarch64.zig");
        _ = @import("asm/riscv64.zig");
        _ = @import("code/aarch64.zig");
        _ = @import("code/riscv64.zig");
    }
}

pub const Type = common.Type;

test "mmap" {
    if (comptime builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .riscv64) return error.SkipZigTest;

    // const mem = try genCallx86_64(allocator, &[_]u8{ 8, 8 }, 8);
    // defer allocator.free(mem);

    // const mem2 = try builder.genCallx86_64v2(allocator, &[_]u8{ 8, 8 }, 8);
    // defer allocator.free(mem2);
    // std.debug.print("=====\n", .{});
    // const mem4 = try builder.genCallx86_64v2(allocator, &[_]u8{ 8, 8, 8, 8, 8, 8, 8 }, 8);
    // defer allocator.free(mem4);
    // std.debug.print("=====\n", .{});
    // // const mem3 = try genCallx86_64v2(allocator, &[_]u8{ 8, 8 }, 8);
    // // defer allocator.free(mem3);

    // // std.debug.print("{x}\n", .{mem});
    // std.debug.print("{x}\n", .{mem2});
    // // std.debug.print("{x}\n", .{mem3});
    // std.debug.print("{x}\n", .{mem4});

    // std.debug.print("[ Generated Caller Function ]\n", .{});

    // {
    //     const dynm = try mem.Block.init(mem2.len);
    //     defer dynm.deinit();
    //     try dynm.writeable();
    //     const inst = dynm.mem;
    //     @memcpy(inst[0..mem2.len], mem2);
    //     try dynm.executable();

    //     const call_fn_ffi: *const CallerFn = @ptrCast(dynm.mem);

    //     var a: i64 = 5;
    //     var b: i64 = 7;
    //     var res: i64 = 0;
    //     call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);
    //     std.debug.print("result: {d}\n", .{res});
    // }

    // {
    //     std.debug.print("LARGE PARAMS (uses stack)\n", .{});
    //     const dynm = try mem.Block.init(mem4.len);
    //     defer dynm.deinit();
    //     try dynm.writeable();
    //     const inst = dynm.mem;
    //     @memcpy(inst[0..mem4.len], mem4);
    //     try dynm.executable();

    //     const call_fn_ffi: *const CallerFn = @ptrCast(dynm.mem);

    //     var a: i64 = 5;
    //     var b: i64 = 7;
    //     var c: i64 = 9;
    //     var d: i64 = 11;
    //     var e: i64 = 13;
    //     var f: i64 = 15;
    //     var g: i64 = 17;
    //     var res: i64 = 0;
    //     call_fn_ffi(@ptrCast(&addmore), &.{ &a, &b, &c, &d, &e, &f, &g }, &res);
    //     std.debug.print("result2: {d}\n", .{res});
    // }

    // std.debug.print("[ Add Function ]\n", .{});

    // Allocate executable memory
    const dynm = try mem.Block.init(5);
    defer dynm.deinit();
    try dynm.writable();
    const inst = dynm.buffer;
    inst[0] = 0x48; // REX (W=1) (R=0) (X=0) (B=0)
    inst[1] = 0x8d; // lea
    inst[2] = 0x04; // ModRM register to register
    inst[3] = 0x37; // SIB: rdi + rsi * 1
    inst[4] = 0xc3; // ret
    try dynm.executable();

    const AddFn = *const fn (a: i64, b: i64) callconv(.c) i64;
    const add_fn: AddFn = @ptrCast(dynm.buffer.ptr);
    try testing.expectEqual(@as(i64, 12), add_fn(5, 7));
}

const testing = std.testing;

test "Add (i8, i8) i8" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i8, b: i8) callconv(.c) i8 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            return a + b;
        }
    }.inner;

    const result = add(5, 7);
    try testing.expectEqual(12, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int8, .int8 }, .int8);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(12, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
}

test "Closure Add (i8, i8) i8" {
    const allocator = std.testing.allocator;
    const handler = struct {
        fn inner(_: *const anyopaque, args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
            const a: *const i8 = @ptrCast(@alignCast(args.?[0]));
            const b: *const i8 = @ptrCast(@alignCast(args.?[1]));
            const r: *i8 = @ptrCast(@alignCast(ret.?));
            r.* = a.* + b.*;
        }
    }.inner;

    var code, const slot = try ffi.buildClosureInvocator(allocator, &.{ .int8, .int8 }, .int8, handler, null);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, slot);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const f: *const fn (i8, i8) callconv(.c) i8 = @ptrCast(dynm.buffer);
    try testing.expectEqual(@as(i8, 12), f(5, 7));
}

test "Add (i8, i8)  C" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i8, b: i8) callconv(.c) i8 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            return a + b;
        }
    }.inner;

    const result = add(5, 7);
    try testing.expectEqual(12, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int8, .int8 }, .int8);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    {
        var a: i8 = 5;
        var b: i8 = 7;
        var res: i8 = 0;

        call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

        try testing.expectEqual(12, res);
        try testing.expectEqual(5, a);
        try testing.expectEqual(7, b);
    }

    const c_test = struct {
        fn inner(callable: *const ffi.CallFn) callconv(.c) void {
            var a: i8 = 5;
            var b: i8 = 7;
            var res: i8 = 0;

            callable(@ptrCast(&add), &.{ &a, &b }, &res);

            testing.expectEqual(12, res) catch @panic("res != 12");
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
        }
    }.inner;

    @call(.never_inline, c_test, .{call_fn_ffi});
}

test "Add (i16, i16) i16" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i16, b: i16) callconv(.c) i16 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            return a + b;
        }
    }.inner;

    const result = add(5, 7);
    try testing.expectEqual(12, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int16, .int16 }, .int16);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i16 = 5;
    var b: i16 = 7;
    var res: i16 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(12, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
}

test "Add (i32, i32) i32" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i32, b: i32) callconv(.c) i32 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            return a + b;
        }
    }.inner;

    const result = add(5, 7);
    try testing.expectEqual(12, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int32, .int32 }, .int32);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i32 = 5;
    var b: i32 = 7;
    var res: i32 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(12, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
}

test "Add (i64, i64) i64" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i64, b: i64) callconv(.c) i64 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            return a + b;
        }
    }.inner;

    const result = add(5, 7);
    try testing.expectEqual(12, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int64, .int64 }, .int64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i64 = 5;
    var b: i64 = 7;
    var res: i64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(12, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
}

test "Add (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) i64" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64, j: i64) callconv(.c) i64 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            testing.expectEqual(9, c) catch @panic("c != 9");
            testing.expectEqual(11, d) catch @panic("d != 11");
            testing.expectEqual(13, e) catch @panic("e != 13");
            testing.expectEqual(15, f) catch @panic("f != 15");
            testing.expectEqual(17, g) catch @panic("g != 17");
            testing.expectEqual(19, h) catch @panic("h != 19");
            testing.expectEqual(21, i) catch @panic("i != 21");
            testing.expectEqual(23, j) catch @panic("j != 23");
            return a + b + c + d + e + f + g + h + i + j;
        }
    }.inner;

    const result = add(5, 7, 9, 11, 13, 15, 17, 19, 21, 23);
    try testing.expectEqual(140, result);

    var code = try ffi.buildCallInvoker(allocator, &.{
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
    }, .int64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i64 = 5;
    var b: i64 = 7;
    var c: i64 = 9;
    var d: i64 = 11;
    var e: i64 = 13;
    var f: i64 = 15;
    var g: i64 = 17;
    var h: i64 = 19;
    var i: i64 = 21;
    var j: i64 = 23;
    var res: i64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j }, &res);

    try testing.expectEqual(140, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
    try testing.expectEqual(9, c);
    try testing.expectEqual(11, d);
    try testing.expectEqual(13, e);
    try testing.expectEqual(15, f);
    try testing.expectEqual(17, g);
    try testing.expectEqual(19, h);
    try testing.expectEqual(21, i);
    try testing.expectEqual(23, j);
}

test "Add (i8, i16, i32, i64) i64" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i8, b: i16, c: i32, d: i64) callconv(.c) i64 {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            testing.expectEqual(9, c) catch @panic("c != 9");
            testing.expectEqual(11, d) catch @panic("d != 11");
            return a + b + c + d;
        }
    }.inner;

    const result = add(5, 7, 9, 11);
    try testing.expectEqual(32, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int8, .int16, .int32, .int64 }, .int64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i8 = 5;
    var b: i16 = 7;
    var c: i32 = 9;
    var d: i64 = 11;
    var res: i64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d }, &res);

    try testing.expectEqual(32, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
    try testing.expectEqual(9, c);
    try testing.expectEqual(11, d);
}

test "Test (struct(4)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i32,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(8)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
            testing.expectEqual(7, a.b) catch @panic("a.b != 7");
            testing.expectEqual(9, a.c) catch @panic("a.c != 9");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5, .b = 7, .c = 9 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(16)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
            testing.expectEqual(7, a.b) catch @panic("a.b != 7");
            testing.expectEqual(9, a.c) catch @panic("a.c != 9");
            testing.expectEqual(11, a.d) catch @panic("a.d != 11");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(32)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
            testing.expectEqual(7, a.b) catch @panic("a.b != 7");
            testing.expectEqual(9, a.c) catch @panic("a.c != 9");
            testing.expectEqual(11, a.d) catch @panic("a.d != 11");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int64,
        .int64,
        .int64,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(64)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
        e: i64,
        f: i64,
        g: i64,
        h: i64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
            testing.expectEqual(7, a.b) catch @panic("a.b != 7");
            testing.expectEqual(9, a.c) catch @panic("a.c != 9");
            testing.expectEqual(11, a.d) catch @panic("a.d != 11");
            testing.expectEqual(13, a.e) catch @panic("a.e != 13");
            testing.expectEqual(15, a.f) catch @panic("a.f != 15");
            testing.expectEqual(17, a.g) catch @panic("a.g != 17");
            testing.expectEqual(19, a.h) catch @panic("a.h != 19");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11, .e = 13, .f = 15, .g = 17, .h = 19 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(64), i64) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
        e: i64,
        f: i64,
        g: i64,
        h: i64,
    };

    const Test = struct {
        fn inner(a: sample, b: i64) callconv(.c) void {
            // std.debug.print("bytes: {x}\n", .{@as([64]u8, @bitCast(a))});
            testing.expectEqual(5, a.a) catch @panic("a.a != 5");
            testing.expectEqual(7, a.b) catch @panic("a.b != 7");
            testing.expectEqual(9, a.c) catch @panic("a.c != 9");
            testing.expectEqual(11, a.d) catch @panic("a.d != 11");
            testing.expectEqual(13, a.e) catch @panic("a.e != 13");
            testing.expectEqual(15, a.f) catch @panic("a.f != 15");
            testing.expectEqual(17, a.g) catch @panic("a.g != 17");
            testing.expectEqual(19, a.h) catch @panic("a.h != 19");

            testing.expectEqual(21, b) catch @panic("b != 21");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{ sample_struct, .int64 }, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11, .e = 13, .f = 15, .g = 17, .h = 19 };
    var b: i64 = 21;

    // std.debug.print("bytes: {x}\n", .{@as([64]u8, @bitCast(a))});

    call_fn_ffi(@ptrCast(&Test), &.{ &a, &b }, null);
}

test "Test (i64, ...half, struct(16)) void" {
    if (comptime builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .riscv64) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
    };

    const Test = switch (asmb.CallingConvention) {
        .SystemV => struct {
            fn inner(a: i64, b: i64, c: i64, d: i64, e: i64, f: sample) callconv(.c) void {
                testing.expectEqual(0, a) catch @panic("a != 0");
                testing.expectEqual(0, b) catch @panic("b != 0");
                testing.expectEqual(0, c) catch @panic("c != 0");
                testing.expectEqual(0, d) catch @panic("d != 0");
                testing.expectEqual(0, e) catch @panic("e != 0");

                testing.expectEqual(5, f.a) catch @panic("f.a != 5");
                testing.expectEqual(7, f.b) catch @panic("f.b != 7");
                testing.expectEqual(9, f.c) catch @panic("f.c != 9");
                testing.expectEqual(11, f.d) catch @panic("f.d != 11");
            }
        }.inner,
        .Windows => struct {
            fn inner(a: i64, b: i64, c: i64, d: sample) callconv(.c) void {
                testing.expectEqual(0, a) catch @panic("a != 0");
                testing.expectEqual(0, b) catch @panic("b != 0");
                testing.expectEqual(0, c) catch @panic("c != 0");

                testing.expectEqual(5, d.a) catch @panic("d.a != 5");
                testing.expectEqual(7, d.b) catch @panic("d.b != 7");
                testing.expectEqual(9, d.c) catch @panic("d.c != 9");
                testing.expectEqual(11, d.d) catch @panic("d.d != 11");
            }
        }.inner,
    };

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = switch (asmb.CallingConvention) {
        .SystemV => try ffi.buildCallInvoker(allocator, &.{ .int64, .int64, .int64, .int64, .int64, sample_struct }, .void),
        .Windows => try ffi.buildCallInvoker(allocator, &.{ .int64, .int64, .int64, sample_struct }, .void),
    };

    // std.debug.print("{x}\n", .{mem});

    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    switch (asmb.CallingConvention) {
        .SystemV => {
            var a: i64 = 0;
            var b: i64 = 0;
            var c: i64 = 0;
            var d: i64 = 0;
            var e: i64 = 0;
            var f: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11 };

            call_fn_ffi(@ptrCast(&Test), &.{ &a, &b, &c, &d, &e, &f }, null);
        },
        .Windows => {
            var a: i64 = 0;
            var b: i64 = 0;
            var c: i64 = 0;
            var d: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11 };

            call_fn_ffi(@ptrCast(&Test), &.{ &a, &b, &c, &d }, null);
        },
    }
}

test "Test (i64, i64, i64, i64, i64, i64, i64, i64, i64, struct(16)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
    };

    const Test = struct {
        fn inner(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64, j: sample) callconv(.c) void {
            testing.expectEqual(0, a) catch @panic("a != 0");
            testing.expectEqual(0, b) catch @panic("b != 0");
            testing.expectEqual(0, c) catch @panic("c != 0");
            testing.expectEqual(0, d) catch @panic("d != 0");
            testing.expectEqual(0, e) catch @panic("e != 0");
            testing.expectEqual(0, f) catch @panic("f != 0");
            testing.expectEqual(0, g) catch @panic("g != 0");
            testing.expectEqual(0, h) catch @panic("h != 0");
            testing.expectEqual(0, i) catch @panic("i != 0");

            testing.expectEqual(5, j.a) catch @panic("j.a != 5");
            testing.expectEqual(7, j.b) catch @panic("j.b != 7");
            testing.expectEqual(9, j.c) catch @panic("j.c != 9");
            testing.expectEqual(11, j.d) catch @panic("j.d != 11");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, .int64,
        .int64, sample_struct,
    }, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i64 = 0;
    var b: i64 = 0;
    var c: i64 = 0;
    var d: i64 = 0;
    var e: i64 = 0;
    var f: i64 = 0;
    var g: i64 = 0;
    var h: i64 = 0;
    var i: i64 = 0;
    var j: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11 };

    call_fn_ffi(@ptrCast(&Test), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j }, null);
}

test "Test (i8, i16, i32, i64) struct(16)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
    };

    const Test = struct {
        fn inner(a: i8, b: i16, c: i32, d: i64) callconv(.c) sample {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            testing.expectEqual(9, c) catch @panic("c != 9");
            testing.expectEqual(11, d) catch @panic("d != 11");
            return .{ .a = 10, .b = 14, .c = 18, .d = 22 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int8, .int16, .int32, .int64 }, sample_struct);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i8 = 5;
    var b: i16 = 7;
    var c: i32 = 9;
    var d: i64 = 11;
    var res: sample = .{ .a = 0, .b = 0, .c = 0, .d = 0 };
    call_fn_ffi(@ptrCast(&Test), &.{ &a, &b, &c, &d }, &res);

    try testing.expectEqual(10, res.a);
    try testing.expectEqual(14, res.b);
    try testing.expectEqual(18, res.c);
    try testing.expectEqual(22, res.d);

    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
    try testing.expectEqual(9, c);
    try testing.expectEqual(11, d);
}

test "Test (i8, i16, i32, i64) struct(64)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
        e: i64,
        f: i64,
        g: i64,
        h: i64,
        i: i64,
        j: i64,
    };

    const Test = struct {
        fn inner(a: i8, b: i16, c: i32, d: i64) callconv(.c) sample {
            testing.expectEqual(5, a) catch @panic("a != 5");
            testing.expectEqual(7, b) catch @panic("b != 7");
            testing.expectEqual(9, c) catch @panic("c != 9");
            testing.expectEqual(11, d) catch @panic("d != 11");
            return .{ .a = 10, .b = 14, .c = 18, .d = 22, .e = 26, .f = 30, .g = 34, .h = 38, .i = 42, .j = 46 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int8,
        .int16,
        .int32,
        .int64,
        .int64,
        .int64,
        .int64,
        .int64,
        .int64,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int8, .int16, .int32, .int64 }, sample_struct);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i8 = 5;
    var b: i16 = 7;
    var c: i32 = 9;
    var d: i64 = 11;
    var res: sample = .{ .a = 0, .b = 0, .c = 0, .d = 0, .e = 0, .f = 0, .g = 0, .h = 0, .i = 0, .j = 0 };
    call_fn_ffi(@ptrCast(&Test), &.{ &a, &b, &c, &d }, &res);

    try testing.expectEqual(10, res.a);
    try testing.expectEqual(14, res.b);
    try testing.expectEqual(18, res.c);
    try testing.expectEqual(22, res.d);
    try testing.expectEqual(26, res.e);
    try testing.expectEqual(30, res.f);
    try testing.expectEqual(34, res.g);
    try testing.expectEqual(38, res.h);
    try testing.expectEqual(42, res.i);
    try testing.expectEqual(46, res.j);

    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
    try testing.expectEqual(9, c);
    try testing.expectEqual(11, d);
}

test "Add (f32, f32) f32" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: f32, b: f32) callconv(.c) f32 {
            testing.expectEqual(1.5, a) catch @panic("a != 1.5");
            testing.expectEqual(2.5, b) catch @panic("b != 2.5");
            return a + b;
        }
    }.inner;

    const result = add(1.5, 2.5);
    try testing.expectEqual(4, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .float32, .float32 }, .float32);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f32 = 1.5;
    var b: f32 = 2.5;
    var res: f32 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(4, res);
    try testing.expectEqual(1.5, a);
    try testing.expectEqual(2.5, b);
}

test "Add (f64, f64) f64" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: f64, b: f64) callconv(.c) f64 {
            testing.expectEqual(1.5, a) catch @panic("a != 1.5");
            testing.expectEqual(2.5, b) catch @panic("b != 2.5");
            return a + b;
        }
    }.inner;

    const result = add(1.5, 2.5);
    try testing.expectEqual(4, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .float64, .float64 }, .float64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f64 = 1.5;
    var b: f64 = 2.5;
    var res: f64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(4, res);
    try testing.expectEqual(1.5, a);
    try testing.expectEqual(2.5, b);
}

test "Add (f64, f64, f64, f64, f64, f64, f64, f64, f64, f64) f64" {
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64) callconv(.c) f64 {
            testing.expectEqual(1.5, a) catch @panic("a != 1.5");
            testing.expectEqual(2.5, b) catch @panic("b != 2.5");
            testing.expectEqual(3.5, c) catch @panic("c != 3.5");
            testing.expectEqual(4.5, d) catch @panic("d != 4.5");
            testing.expectEqual(5.5, e) catch @panic("e != 5.5");
            testing.expectEqual(6.5, f) catch @panic("f != 6.5");
            testing.expectEqual(7.5, g) catch @panic("g != 7.5");
            testing.expectEqual(8.5, h) catch @panic("h != 8.5");
            testing.expectEqual(9.5, i) catch @panic("i != 9.5");
            testing.expectEqual(10.5, j) catch @panic("j != 10.5");
            return a + b + c + d + e + f + g + h + i + j;
        }
    }.inner;

    const result = add(1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5);
    try testing.expectEqual(60, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64 }, .float64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f64 = 1.5;
    var b: f64 = 2.5;
    var c: f64 = 3.5;
    var d: f64 = 4.5;
    var e: f64 = 5.5;
    var f: f64 = 6.5;
    var g: f64 = 7.5;
    var h: f64 = 8.5;
    var i: f64 = 9.5;
    var j: f64 = 10.5;
    var res: f64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j }, &res);

    try testing.expectEqual(60, res);
    try testing.expectEqual(1.5, a);
    try testing.expectEqual(2.5, b);
    try testing.expectEqual(3.5, c);
    try testing.expectEqual(4.5, d);
    try testing.expectEqual(5.5, e);
    try testing.expectEqual(6.5, f);
    try testing.expectEqual(7.5, g);
    try testing.expectEqual(8.5, h);
    try testing.expectEqual(9.5, i);
    try testing.expectEqual(10.5, j);
}

test "Add (f64, f64, f64, f64, f64, f64, f64, f64, f64, f64, struct(f64, f64)) f64" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: f64,
    };

    const add = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64, base: sample) callconv(.c) f64 {
            testing.expectEqual(1.5, a) catch @panic("a != 1.5");
            testing.expectEqual(2.5, b) catch @panic("b != 2.5");
            testing.expectEqual(3.5, c) catch @panic("c != 3.5");
            testing.expectEqual(4.5, d) catch @panic("d != 4.5");
            testing.expectEqual(5.5, e) catch @panic("e != 5.5");
            testing.expectEqual(6.5, f) catch @panic("f != 6.5");
            testing.expectEqual(7.5, g) catch @panic("g != 7.5");
            testing.expectEqual(8.5, h) catch @panic("h != 8.5");
            testing.expectEqual(9.5, i) catch @panic("i != 9.5");
            testing.expectEqual(10.5, j) catch @panic("j != 10.5");
            testing.expectEqual(11.5, base.a) catch @panic("base.a != 11.5");
            testing.expectEqual(12.5, base.b) catch @panic("base.b != 12.5");
            return a + b + c + d + e + f + g + h + i + j + base.a + base.b;
        }
    }.inner;

    const result = add(1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5, .{ .a = 11.5, .b = 12.5 });
    try testing.expectEqual(84, result);

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    var code = try ffi.buildCallInvoker(allocator, &.{ .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64, .float64, sample_struct }, .float64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f64 = 1.5;
    var b: f64 = 2.5;
    var c: f64 = 3.5;
    var d: f64 = 4.5;
    var e: f64 = 5.5;
    var f: f64 = 6.5;
    var g: f64 = 7.5;
    var h: f64 = 8.5;
    var i: f64 = 9.5;
    var j: f64 = 10.5;
    var base: sample = .{ .a = 11.5, .b = 12.5 };
    var res: f64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j, &base }, &res);

    try testing.expectEqual(84, res);
    try testing.expectEqual(1.5, a);
    try testing.expectEqual(2.5, b);
    try testing.expectEqual(3.5, c);
    try testing.expectEqual(4.5, d);
    try testing.expectEqual(5.5, e);
    try testing.expectEqual(6.5, f);
    try testing.expectEqual(7.5, g);
    try testing.expectEqual(8.5, h);
    try testing.expectEqual(9.5, i);
    try testing.expectEqual(10.5, j);
    try testing.expectEqual(11.5, base.a);
    try testing.expectEqual(12.5, base.b);
}

test "Test (struct(f64, f64)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: f64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(1.2345, a.a) catch @panic("a.a != 1.2345");
            testing.expectEqual(6.789, a.b) catch @panic("a.b != 6.789");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 1.2345, .b = 6.789 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(f32, f64)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(1.2345, a.a) catch @panic("a.a != 1.2345");
            testing.expectEqual(6.789, a.b) catch @panic("a.b != 6.789");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 1.2345, .b = 6.789 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (struct(f32, f32, f64)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f32,
        c: f64,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(1.2345, a.a) catch @panic("a.a != 1.2345");
            testing.expectEqual(6.789, a.b) catch @panic("a.b != 6.789");
            testing.expectEqual(12.3456789, a.c) catch @panic("a.c != 12.3456789");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float32,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 1.2345, .b = 6.789, .c = 12.3456789 };

    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (void) struct(f64, f64)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: f64,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            return .{ .a = 1.2345, .b = 6.789 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = undefined;

    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(1.2345, ret.a);
    try testing.expectEqual(6.789, ret.b);
}

test "Test (void) i64" {
    const allocator = std.testing.allocator;

    const Test = struct {
        fn inner() callconv(.c) i64 {
            return 42;
        }
    }.inner;

    var code = try ffi.buildCallInvoker(allocator, &.{}, .int64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var res: i64 = 0;
    call_fn_ffi(@ptrCast(&Test), null, &res);

    try testing.expectEqual(42, res);
}

test "Test (void) f32" {
    const allocator = std.testing.allocator;

    const Test = struct {
        fn inner() callconv(.c) f32 {
            return 3.14;
        }
    }.inner;

    var c = try ffi.buildCallInvoker(allocator, &.{}, .float32);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var res: f32 = 0;
    call_fn_ffi(@ptrCast(&Test), null, &res);

    try testing.expectEqual(3.14, res);
}

test "Test (void) struct(i64, i64)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i64,
        b: i64,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            return .{ .a = 111, .b = 222 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int64,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = undefined;
    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(111, ret.a);
    try testing.expectEqual(222, ret.b);
}

test "Add (i64, f64, i64, f64) f64" {
    // Verifies that integer and floating-point argument register counters advance independently.
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: i64, b: f64, c: i64, d: f64) callconv(.c) f64 {
            testing.expectEqual(10, a) catch @panic("a != 10");
            testing.expectEqual(1.5, b) catch @panic("b != 1.5");
            testing.expectEqual(20, c) catch @panic("c != 20");
            testing.expectEqual(2.5, d) catch @panic("d != 2.5");
            return @as(f64, @floatFromInt(a + c)) + b + d;
        }
    }.inner;

    const result = add(10, 1.5, 20, 2.5);
    try testing.expectEqual(34, result);

    var code = try ffi.buildCallInvoker(allocator, &.{ .int64, .float64, .int64, .float64 }, .float64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: i64 = 10;
    var b: f64 = 1.5;
    var c: i64 = 20;
    var d: f64 = 2.5;
    var res: f64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d }, &res);

    try testing.expectEqual(34, res);
    try testing.expectEqual(10, a);
    try testing.expectEqual(1.5, b);
    try testing.expectEqual(20, c);
    try testing.expectEqual(2.5, d);
}

test "Add (f32, f32, f32, f32, f32, f32, f32, f32, f32, f32) f32" {
    // 8 f32 args consume all FP registers; 9th and 10th go on the stack.
    // Darwin PCS packs those slots at 4 bytes; AAPCS64 uses 8-byte slots.
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: f32, b: f32, c: f32, d: f32, e: f32, f: f32, g: f32, h: f32, i: f32, j: f32) callconv(.c) f32 {
            testing.expectEqual(1.0, a) catch @panic("a != 1.0");
            testing.expectEqual(2.0, b) catch @panic("b != 2.0");
            testing.expectEqual(3.0, c) catch @panic("c != 3.0");
            testing.expectEqual(4.0, d) catch @panic("d != 4.0");
            testing.expectEqual(5.0, e) catch @panic("e != 5.0");
            testing.expectEqual(6.0, f) catch @panic("f != 6.0");
            testing.expectEqual(7.0, g) catch @panic("g != 7.0");
            testing.expectEqual(8.0, h) catch @panic("h != 8.0");
            testing.expectEqual(9.0, i) catch @panic("i != 9.0");
            testing.expectEqual(10.0, j) catch @panic("j != 10.0");
            return a + b + c + d + e + f + g + h + i + j;
        }
    }.inner;

    const result = add(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    try testing.expectEqual(55, result);

    var code = try ffi.buildCallInvoker(allocator, &.{
        .float32, .float32, .float32, .float32, .float32,
        .float32, .float32, .float32, .float32, .float32,
    }, .float32);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f32 = 1;
    var b: f32 = 2;
    var c: f32 = 3;
    var d: f32 = 4;
    var e: f32 = 5;
    var f: f32 = 6;
    var g: f32 = 7;
    var h: f32 = 8;
    var i: f32 = 9;
    var j: f32 = 10;
    var res: f32 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j }, &res);

    try testing.expectEqual(55, res);
    try testing.expectEqual(1, a);
    try testing.expectEqual(10, j);
}

test "Test (struct(f32, f32)) void" {
    // HFA struct with f32 fields — each field passes in its own FP register.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f32,
    };

    const Test = struct {
        fn inner(a: sample) callconv(.c) void {
            testing.expectEqual(1.5, a.a) catch @panic("a.a != 1.5");
            testing.expectEqual(2.5, a.b) catch @panic("a.b != 2.5");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: sample = .{ .a = 1.5, .b = 2.5 };
    call_fn_ffi(@ptrCast(&Test), &.{&a}, null);
}

test "Test (void) struct(f32, f32)" {
    // HFA struct with f32 fields returned via FP registers.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f32,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            return .{ .a = 1.5, .b = 2.5 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = .{ .a = 0, .b = 0 };
    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(1.5, ret.a);
    try testing.expectEqual(2.5, ret.b);
}

test "Test (struct(f64, f64), struct(f64, f64)) void" {
    // Two HFA structs; together they consume fa0-fa3 and must not corrupt each other.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: f64,
    };

    const Test = struct {
        fn inner(x: sample, y: sample) callconv(.c) void {
            testing.expectEqual(1.1, x.a) catch @panic("x.a != 1.1");
            testing.expectEqual(2.2, x.b) catch @panic("x.b != 2.2");
            testing.expectEqual(3.3, y.a) catch @panic("y.a != 3.3");
            testing.expectEqual(4.4, y.b) catch @panic("y.b != 4.4");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var code = try ffi.buildCallInvoker(allocator, &.{ sample_struct, sample_struct }, .void);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var x: sample = .{ .a = 1.1, .b = 2.2 };
    var y: sample = .{ .a = 3.3, .b = 4.4 };
    call_fn_ffi(@ptrCast(&Test), &.{ &x, &y }, null);
}

test "Add (f64, f64, f64, f64, f64, f64, f64, f64, f64, f64, f64, f64) f64" {
    // 8 f64s fill FP regs; 9th and 10th go to integer registers; 11th and 12th spill to stack.
    const allocator = std.testing.allocator;

    const add = struct {
        fn inner(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64, k: f64, l: f64) callconv(.c) f64 {
            testing.expectEqual(1.0, a) catch @panic("a != 1.0");
            testing.expectEqual(2.0, b) catch @panic("b != 2.0");
            testing.expectEqual(3.0, c) catch @panic("c != 3.0");
            testing.expectEqual(4.0, d) catch @panic("d != 4.0");
            testing.expectEqual(5.0, e) catch @panic("e != 5.0");
            testing.expectEqual(6.0, f) catch @panic("f != 6.0");
            testing.expectEqual(7.0, g) catch @panic("g != 7.0");
            testing.expectEqual(8.0, h) catch @panic("h != 8.0");
            testing.expectEqual(9.0, i) catch @panic("i != 9.0");
            testing.expectEqual(10.0, j) catch @panic("j != 10.0");
            testing.expectEqual(11.0, k) catch @panic("k != 11.0");
            testing.expectEqual(12.0, l) catch @panic("l != 12.0");
            return a + b + c + d + e + f + g + h + i + j + k + l;
        }
    }.inner;

    const result = add(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    try testing.expectEqual(78, result);

    var code = try ffi.buildCallInvoker(allocator, &.{
        .float64, .float64, .float64, .float64,
        .float64, .float64, .float64, .float64,
        .float64, .float64, .float64, .float64,
    }, .float64);
    defer code.deinit();

    const bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var a: f64 = 1;
    var b: f64 = 2;
    var c: f64 = 3;
    var d: f64 = 4;
    var e: f64 = 5;
    var f: f64 = 6;
    var g: f64 = 7;
    var h: f64 = 8;
    var i: f64 = 9;
    var j: f64 = 10;
    var k: f64 = 11;
    var l: f64 = 12;
    var res: f64 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j, &k, &l }, &res);

    try testing.expectEqual(78, res);
    try testing.expectEqual(1, a);
    try testing.expectEqual(12, l);
}

test "Test (struct(f32, f32, i32, i32)) void" {
    // Two eightbytes, SSE then INTEGER. SysV passes them in xmm0 and a GPR.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f32,
        c: i32,
        d: i32,
    };

    const Test = struct {
        fn inner(s: sample) callconv(.c) void {
            testing.expectEqual(1.5, s.a) catch @panic("s.a != 1.5");
            testing.expectEqual(2.5, s.b) catch @panic("s.b != 2.5");
            testing.expectEqual(7, s.c) catch @panic("s.c != 7");
            testing.expectEqual(9, s.d) catch @panic("s.d != 9");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float32,
        .int32,
        .int32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var s: sample = .{ .a = 1.5, .b = 2.5, .c = 7, .d = 9 };
    call_fn_ffi(@ptrCast(&Test), &.{&s}, null);
}

test "Test (struct(f64, i64)) void" {
    // SSE eightbyte followed by an INTEGER eightbyte.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: i64,
    };

    const Test = struct {
        fn inner(s: sample) callconv(.c) void {
            testing.expectEqual(1.5, s.a) catch @panic("s.a != 1.5");
            testing.expectEqual(42, s.b) catch @panic("s.b != 42");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var s: sample = .{ .a = 1.5, .b = 42 };
    call_fn_ffi(@ptrCast(&Test), &.{&s}, null);
}

test "Test (struct(i32, f64)) void" {
    // INTEGER eightbyte, then SSE. Alignment inserts 4 bytes of padding before the f64.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i32,
        b: f64,
    };

    const Test = struct {
        fn inner(s: sample) callconv(.c) void {
            testing.expectEqual(7, s.a) catch @panic("s.a != 7");
            testing.expectEqual(1.5, s.b) catch @panic("s.b != 1.5");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int32,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var s: sample = .{ .a = 7, .b = 1.5 };
    call_fn_ffi(@ptrCast(&Test), &.{&s}, null);
}

test "Test (struct(f32, i32)) void" {
    // Both fields share one eightbyte, which SysV merges to INTEGER.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: i32,
    };

    const Test = struct {
        fn inner(s: sample) callconv(.c) void {
            testing.expectEqual(1.5, s.a) catch @panic("s.a != 1.5");
            testing.expectEqual(7, s.b) catch @panic("s.b != 7");
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .int32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{sample_struct}, .void);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var s: sample = .{ .a = 1.5, .b = 7 };
    call_fn_ffi(@ptrCast(&Test), &.{&s}, null);
}

test "Test (void) struct(f32, f32, i32, i32)" {
    // Return path for SSE-then-INTEGER: xmm0 and rax, not rax and rdx.
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f32,
        b: f32,
        c: i32,
        d: i32,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            return .{ .a = 1.5, .b = 2.5, .c = 7, .d = 9 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float32,
        .float32,
        .int32,
        .int32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = undefined;
    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(1.5, ret.a);
    try testing.expectEqual(2.5, ret.b);
    try testing.expectEqual(7, ret.c);
    try testing.expectEqual(9, ret.d);
}

test "Test (void) struct(f64, i64)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: f64,
        b: i64,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            return .{ .a = 1.5, .b = 42 };
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .float64,
        .int64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = undefined;
    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(1.5, ret.a);
    try testing.expectEqual(42, ret.b);
}

test "Test (void) struct(i32, f64)" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i32,
        b: f64,
    };

    const Test = struct {
        fn inner() callconv(.c) sample {
            const result: sample = .{ .a = 7, .b = 1.5 };
            // // SysV returns this f64 in xmm0. A Debug epilogue otherwise leaves those
            // // bits in rdx, and a GPR-only trampoline would look correct by accident.
            // asm volatile ("xor %%rdx, %%rdx" ::: .{ .rdx = true });
            return result;
        }
    }.inner;

    const sample_struct: Type = try .@"struct"(allocator, &.{
        .int32,
        .float64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(std.mem.Alignment.of(sample), sample_struct.alignment);

    var c = try ffi.buildCallInvoker(allocator, &.{}, sample_struct);
    defer c.deinit();

    const bytes = try c.compileAlloc(allocator, null);
    defer allocator.free(bytes);
    const dynm = try mem.Block.initWithBytes(bytes);
    defer dynm.deinit();
    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.buffer);

    var ret: sample = undefined;
    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(7, ret.a);
    try testing.expectEqual(1.5, ret.b);
}
