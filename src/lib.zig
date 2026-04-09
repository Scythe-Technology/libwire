const std = @import("std");
const builtin = @import("builtin");

const builder = @import("x86_64.zig");

const mmap_u8 = []align(std.heap.page_size_min) u8;

pub const CallFn = builder.CallFn;
pub const DataType = builder.DataType;
pub const createStruct = builder.createStruct;
pub const generateAsmCall = builder.generateAsmCall;

pub const type_i8 = builder.type_i8;
pub const type_i16 = builder.type_i16;
pub const type_i32 = builder.type_i32;
pub const type_i64 = builder.type_i64;
pub const type_void = builder.type_void;
pub const type_f32 = builder.type_f32;
pub const type_f64 = builder.type_f64;
pub const type_ptr = builder.type_ptr;

pub const ExecutableMemory = struct {
    allocator: std.mem.Allocator,
    mem: []align(std.heap.page_size_min) u8,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ExecutableMemory {
        const mem = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
        return .{
            .allocator = allocator,
            .mem = mem,
        };
    }

    pub fn initWithBytes(allocator: std.mem.Allocator, bytes: []const u8) !ExecutableMemory {
        const exec = try ExecutableMemory.init(allocator, bytes.len);
        @memcpy(exec.mem[0..bytes.len], bytes);
        return exec;
    }

    pub fn deinit(self: ExecutableMemory) void {
        self.writeable() catch {};
        self.allocator.free(self.mem);
    }

    pub fn executable(self: ExecutableMemory) !void {
        try std.posix.mprotect(self.mem, std.posix.PROT.EXEC | std.posix.PROT.READ);
    }

    pub fn writeable(self: ExecutableMemory) !void {
        try std.posix.mprotect(self.mem, std.posix.PROT.READ | std.posix.PROT.WRITE);
    }
};

test "mmap" {
    const allocator = std.testing.allocator;

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
    //     const dynm = try ExecutableMemory.init(mem2.len);
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
    //     const dynm = try ExecutableMemory.init(mem4.len);
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
    const dynm = try ExecutableMemory.init(allocator, 5);
    defer dynm.deinit();
    try dynm.writeable();
    const inst = dynm.mem;
    inst[0] = 0x48; // REX (W=1) (R=0) (X=0) (B=0)
    inst[1] = 0x8d; // lea
    inst[2] = 0x04; // ModRM register to register
    inst[3] = 0x37; // SIB: rdi + rsi * 1
    inst[4] = 0xc3; // ret
    try dynm.executable();

    // Define a function pointer
    const AddFn = fn (a: i64, b: i64) i64;
    const add_fn: *const AddFn = @ptrCast(dynm.mem);

    // Call the dynamically generated function
    const result = add_fn(5, 7);
    std.debug.print("Result: {}\n", .{result});

    // Unmap the memory (cleanup)

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

    const mem = try generateAsmCall(allocator, &.{ type_i8, type_i8 }, type_i8);
    const dynm = ExecutableMemory{
        .allocator = allocator,
        .mem = mem,
    };
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    try testing.expectEqual(12, res);
    try testing.expectEqual(5, a);
    try testing.expectEqual(7, b);
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

    const mem = try generateAsmCall(allocator, &.{ type_i8, type_i8 }, type_i8);
    const dynm = ExecutableMemory{
        .allocator = allocator,
        .mem = mem,
    };
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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
        fn inner(callable: *const CallFn) callconv(.c) void {
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

    const mem = try generateAsmCall(allocator, &.{ type_i16, type_i16 }, type_i16);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_i32, type_i32 }, type_i32);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_i64, type_i64 }, type_i64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
    }, type_i64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_i8, type_i16, type_i32, type_i64 }, type_i64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

    var a: i8 = 5;
    var b: i16 = 7;
    var c: i32 = 9;
    var d: i64 = 11;
    var res: i28 = 0;

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

    const sample_struct = try createStruct(allocator, &.{
        type_i32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i64,
        type_i64,
        type_i64,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{ sample_struct, type_i64 }, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

    var a: sample = .{ .a = 5, .b = 7, .c = 9, .d = 11, .e = 13, .f = 15, .g = 17, .h = 19 };
    var b: i64 = 21;

    // std.debug.print("bytes: {x}\n", .{@as([64]u8, @bitCast(a))});

    call_fn_ffi(@ptrCast(&Test), &.{ &a, &b }, null);
}

test "Test (i64, ...half, struct(16)) void" {
    const allocator = std.testing.allocator;

    const sample = extern struct {
        a: i8,
        b: i16,
        c: i32,
        d: i64,
    };

    const Test = switch (builder.CallingConvention) {
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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = switch (builder.CallingConvention) {
        .SystemV => try generateAsmCall(allocator, &.{ type_i64, type_i64, type_i64, type_i64, type_i64, sample_struct }, type_void),
        .Windows => try generateAsmCall(allocator, &.{ type_i64, type_i64, type_i64, sample_struct }, type_void),
    };
    defer allocator.free(mem);

    // std.debug.print("{x}\n", .{mem});

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

    switch (builder.CallingConvention) {
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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, type_i64,
        type_i64, sample_struct,
    }, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{ type_i8, type_i16, type_i32, type_i64 }, sample_struct);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_i8,
        type_i16,
        type_i32,
        type_i64,
        type_i64,
        type_i64,
        type_i64,
        type_i64,
        type_i64,
        type_i64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{ type_i8, type_i16, type_i32, type_i64 }, sample_struct);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_f32, type_f32 }, type_f32);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_f64, type_f64 }, type_f64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const mem = try generateAsmCall(allocator, &.{ type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64 }, type_f64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_f64,
        type_f64,
    }, null);
    defer sample_struct.free(allocator);

    const mem = try generateAsmCall(allocator, &.{ type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, type_f64, sample_struct }, type_f64);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_f64,
        type_f64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_f32,
        type_f64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_f32,
        type_f32,
        type_f64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{sample_struct}, type_void);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

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

    const sample_struct = try createStruct(allocator, &.{
        type_f64,
        type_f64,
    }, null);
    defer sample_struct.free(allocator);

    try testing.expectEqual(@sizeOf(sample), sample_struct.size);
    try testing.expectEqual(@alignOf(sample), sample_struct.alignment);

    const mem = try generateAsmCall(allocator, &.{}, sample_struct);
    defer allocator.free(mem);

    const dynm = try ExecutableMemory.initWithBytes(allocator, mem);
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const CallFn = @ptrCast(dynm.mem);

    var ret: sample = undefined;

    call_fn_ffi(@ptrCast(&Test), null, &ret);

    try testing.expectEqual(1.2345, ret.a);
    try testing.expectEqual(6.789, ret.b);
}
