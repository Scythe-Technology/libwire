const std = @import("std");
const ffi = @import("ffi-asm");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const add = struct {
        fn inner(a: i8, b: i8) callconv(.c) i8 {
            return a + b;
        }
    }.inner;

    const mem = try ffi.generateAsmCall(allocator, &.{ ffi.type_i8, ffi.type_i8 }, ffi.type_i8);
    const dynm = ffi.ExecutableMemory{
        .allocator = allocator,
        .mem = mem,
    };
    defer dynm.deinit();

    try dynm.executable();

    const call_fn_ffi: *const ffi.CallFn = @ptrCast(dynm.mem);

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    std.debug.print("Result: {}\n", .{res});
}
