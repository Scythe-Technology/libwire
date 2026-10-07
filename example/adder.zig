const std = @import("std");
const wire = @import("wire");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const add = struct {
        fn inner(a: i8, b: i8) callconv(.c) i8 {
            return a + b;
        }
    }.inner;

    var pool: wire.mem.Pool = .init(allocator);
    defer pool.deinit();

    const mem = try wire.ffi.prepareCallInfo(
        allocator,
        &pool,
        &.{ .int8, .int8 },
        .int8,
    );

    const call_fn_ffi: *const wire.ffi.CallFn = @ptrCast(mem.pointer());

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    std.debug.print("Result: {}\n", .{res});
}
