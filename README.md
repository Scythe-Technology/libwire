# libwire

A JIT. A foreign function interface, a code builder, an assembler, and executable memory.

Docs: [no pages yet]

Project status: **alpha**

## `wire.ffi`

The libffi alternative. Compiles a signature into executable machine code through `wire.Code`.

`prepareCallInfo`: signature → load arguments → call the target → store the return → executable

The body takes three pointers: the target, the argument array, and the return slot. `call` runs the result.

`prepareClosureInfo`: signature → pack arguments → call the handler → return the result → executable

The body is the C function. Incoming arguments are packed into a pointer array for the handler.

## `wire.Code`

Straight-line IR for one function. Virtual registers, no branches.

IR → IR lowering → assembly builder → machine code

### Calling conventions

- [x] cdecl (c)
- [ ] stdcall (windows only)
- [ ] fastcall

## `wire.asmb`

The host assembler. One instruction list for that architecture. Struct classification is mostly for the C ABI.

instructions → encode → machine code

## `wire.mem`

Pages for executable machine code.

## Targets

| OS | Architectures |
| --- | --- |
| Linux | x86_64, aarch64, riscv64 |
| FreeBSD | x86_64, aarch64, riscv64 |
| macOS | x86_64, aarch64 |
| Windows | x86_64 |

## Example

```zig
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

    const mem = try wire.ffi.prepareCallInfo(allocator, &pool, &.{ .int8, .int8 }, .int8);

    const call_fn_ffi: *const wire.ffi.CallFn = @ptrCast(mem.pointer());

    var a: i8 = 5;
    var b: i8 = 7;
    var res: i8 = 0;

    call_fn_ffi(@ptrCast(&add), &.{ &a, &b }, &res);

    std.debug.print("Result: {}\n", .{res});
}
```

## License

MIT. See [LICENSE](LICENSE).
