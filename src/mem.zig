const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.os.tag;
const native_arch = builtin.cpu.arch;

pub const PROT = packed struct(u32) {
    READ: bool = false,
    WRITE: bool = false,
    EXEC: bool = false,
    _: u29 = 0,

    fn bits(prot: PROT) u32 {
        return @bitCast(prot);
    }
};

pub const Error = std.process.ProtectMemoryError;

pub const BlockAlignment = 16;

pub const Buffer = []align(BlockAlignment) const u8;

pub const Block = struct {
    buffer: []align(BlockAlignment) u8,

    pub fn init(size: usize) !Block {
        const len = std.mem.alignForward(usize, @max(size, 1), std.heap.pageSize());
        const mem_ptr = std.heap.page_allocator.rawAlloc(len, .fromByteUnits(std.heap.pageSize()), @returnAddress()) orelse
            return error.OutOfMemory;
        const mem = mem_ptr[0..len];
        return .{
            .buffer = @alignCast(mem),
        };
    }

    pub fn initWithBytes(bytes: []const u8) !Block {
        const exec = try Block.init(bytes.len);
        @memcpy(exec.buffer[0..bytes.len], bytes);
        return exec;
    }

    pub fn from(mem: Buffer) Block {
        return .{
            .buffer = mem,
        };
    }

    pub fn deinit(self: Block) void {
        const page_alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
        std.debug.assert(page_alignment.check(@intFromPtr(self.buffer.ptr)));
        self.writable() catch {};
        std.heap.page_allocator.free(self.buffer);
    }

    pub fn executable(self: Block) !void {
        const page_alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
        std.debug.assert(page_alignment.check(@intFromPtr(self.buffer.ptr)));
        try makeExecutable(@alignCast(self.buffer));
    }

    pub fn writable(self: Block) !void {
        const page_alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
        std.debug.assert(page_alignment.check(@intFromPtr(self.buffer.ptr)));
        try makeWritable(@alignCast(self.buffer));
    }
};

pub fn makeExecutable(buffer: Buffer) !void {
    try mprotect(@alignCast(buffer), .{ .READ = true, .EXEC = true });
}

pub fn makeWritable(buffer: Buffer) !void {
    try mprotect(@alignCast(buffer), .{ .READ = true, .WRITE = true });
}

pub const Pool = struct {
    pages: std.ArrayList(Page) = .empty,
    gpa: std.mem.Allocator = if (builtin.link_libc)
        std.heap.c_allocator
    else
        std.heap.smp_allocator,

    const Page = struct {
        fixed_allocator: std.heap.FixedBufferAllocator,
        writable: bool = true,
    };

    pub fn init(gpa: std.mem.Allocator) Pool {
        return .{
            .pages = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.pages.items) |page| {
            makeWritable(@alignCast(page.fixed_allocator.buffer)) catch {};
            std.heap.page_allocator.free(page.fixed_allocator.buffer);
        }
        self.pages.deinit(self.gpa);
    }

    /// Copy `bytes` onto a page and return that copy.
    ///
    /// The page is read/exec on success, including every block already stored
    /// on it. A page is made writable only for the copy, then sealed before
    /// this returns, so the caller never observes a published block whose
    /// page is still writable. The source may be freed immediately. It must
    /// not already live in this pool: the copy would overlap itself.
    pub fn executable(self: *Pool, bytes: []const u8) ![]align(BlockAlignment) const u8 {
        if (bytes.len == 0) return error.Empty;
        std.debug.assert(!self.contains(bytes.ptr));

        if (try self.place(bytes)) |slice| return slice;

        const page = try self.addPage(bytes.len);
        const slice = copy(page, bytes) orelse return error.OutOfMemory;
        try seal(page);
        return slice;
    }

    fn place(self: *Pool, bytes: []const u8) !?[]align(BlockAlignment) const u8 {
        for (self.pages.items) |*page| {
            if (!fits(page, bytes.len)) continue;

            // Open before the bump moves. A failed flip must not consume the slot.
            if (!page.writable) {
                try makeWritable(@alignCast(page.fixed_allocator.buffer));
                page.writable = true;
            }

            const slice = copy(page, bytes) orelse {
                // Room disappeared after the fit check. Seal so earlier
                // blocks on this page are callable again, then try the next.
                try seal(page);
                continue;
            };
            try seal(page);
            return slice;
        }
        return null;
    }

    fn contains(self: *Pool, ptr: [*]const u8) bool {
        for (self.pages.items) |*page| {
            if (page.fixed_allocator.ownsPtr(@constCast(ptr))) return true;
        }
        return false;
    }

    fn fits(page: *const Page, len: usize) bool {
        const fba = &page.fixed_allocator;
        const adjust = std.mem.alignPointerOffset(fba.buffer.ptr + fba.end_index, BlockAlignment) orelse return false;
        const start = std.math.add(usize, fba.end_index, adjust) catch return false;
        const end = std.math.add(usize, start, len) catch return false;
        return end <= fba.buffer.len;
    }

    fn copy(page: *Page, bytes: []const u8) ?[]align(BlockAlignment) const u8 {
        const ptr = page.fixed_allocator.allocator().rawAlloc(bytes.len, .fromByteUnits(BlockAlignment), @returnAddress()) orelse
            return null;
        const dest: []align(BlockAlignment) u8 = @alignCast(ptr[0..bytes.len]);
        @memcpy(dest, bytes);
        return dest;
    }

    /// Leave the page read/exec. `writable` stays true when protection fails,
    /// so a later publish can try again and `deinit` still knows the mapping.
    fn seal(page: *Page) !void {
        if (!page.writable) return;
        try makeExecutable(@alignCast(page.fixed_allocator.buffer));
        page.writable = false;
    }

    fn addPage(self: *Pool, size: usize) !*Page {
        const block = try Block.init(size);
        errdefer block.deinit();
        try self.pages.append(self.gpa, .{
            .fixed_allocator = .init(block.buffer),
            .writable = true,
        });
        return &self.pages.items[self.pages.items.len - 1];
    }
};

/// Change protection on the pages covering `bytes`.
///
/// `bytes.ptr` must be page-aligned. Length is rounded up to a whole page
/// because every supported kernel only tracks protection at page granularity.
///
/// When `prot.EXEC` is set, the instruction cache is synchronized so the
/// bytes are safe to call on architectures with split I/D caches.
pub fn mprotect(bytes: []align(std.heap.page_size_min) const u8, prot: PROT) Error!void {
    if (bytes.len == 0) return;

    const len = std.mem.alignForward(usize, bytes.len, std.heap.pageSize());
    const addr = @intFromPtr(bytes.ptr);

    switch (comptime native_os) {
        .linux => try LinuxImpl.mprotect(addr, len, prot),
        .freebsd => try FreebsdImpl.mprotect(addr, len, prot),
        .windows => try WindowsImpl.mprotect(addr, len, prot),
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => try DarwinImpl.mprotect(addr, len, prot),
        else => @compileError("mem.mprotect: unsupported OS " ++ @tagName(native_os)),
    }

    if (prot.EXEC)
        clearCache(bytes);
}

pub const LinuxImpl = struct {
    fn mprotect(addr: usize, len: usize, prot: PROT) Error!void {
        const linux_prot: std.os.linux.PROT = .{
            .READ = prot.READ,
            .WRITE = prot.WRITE,
            .EXEC = prot.EXEC,
        };
        return switch (std.os.linux.errno(std.os.linux.mprotect(@ptrFromInt(addr), len, linux_prot))) {
            .SUCCESS => {},
            .PERM => error.PermissionDenied,
            .ACCES => error.AccessDenied,
            .NOMEM => error.OutOfMemory,
            else => error.Unexpected,
        };
    }
};

pub const FreebsdImpl = struct {
    /// SYS_mprotect is 74 on every FreeBSD architecture.
    const freebsd_sys_mprotect: usize = 74;

    fn mprotect(addr: usize, len: usize, prot: PROT) Error!void {
        const rc = freebsdSyscall3(freebsd_sys_mprotect, addr, len, prot.bits());
        if (rc.failed) {
            const e: u16 = std.math.cast(u16, rc.value) orelse return error.Unexpected;
            return switch (@as(std.os.linux.E, @fromBackingInt(@intCast(e)))) {
                .PERM => error.PermissionDenied,
                .NOMEM => error.OutOfMemory,
                .ACCES, .FAULT => error.AccessDenied,
                else => error.Unexpected,
            };
        }
    }

    const SyscallResult = struct {
        value: usize,
        failed: bool,
    };

    fn freebsdSyscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) SyscallResult {
        // BSD reports failure via the carry flag (not Linux-style negative errno).
        if (comptime native_arch == .x86_64) {
            var value: usize = undefined;
            var failed: u8 = undefined;
            asm volatile (
                \\syscall
                \\setc %[failed]
                : [value] "={rax}" (value),
                  [failed] "=r" (failed),
                : [number] "{rax}" (number),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true });
            return .{ .value = value, .failed = failed != 0 };
        } else if (comptime native_arch == .aarch64) {
            var value: usize = undefined;
            var failed: u8 = undefined;
            asm volatile (
                \\svc #0
                \\cset %[failed], cs
                : [value] "={x0}" (value),
                  [failed] "={x1}" (failed),
                : [number] "{x8}" (number),
                  [arg1] "{x0}" (arg1),
                  [arg2] "{x1}" (arg2),
                  [arg3] "{x2}" (arg3),
                : .{ .memory = true });
            return .{ .value = value, .failed = failed != 0 };
        } else if (comptime native_arch == .riscv64) {
            // FreeBSD/riscv returns errno in a0 and sets t0=1 on failure.
            var value: usize = undefined;
            var failed: usize = undefined;
            asm volatile (
                \\ecall
                : [value] "={x10}" (value),
                  [failed] "={x5}" (failed),
                : [number] "{x17}" (number),
                  [arg1] "{x10}" (arg1),
                  [arg2] "{x11}" (arg2),
                  [arg3] "{x12}" (arg3),
                : .{ .memory = true });
            return .{ .value = value, .failed = failed != 0 };
        } else {
            @compileError("mem.mprotect: unsupported FreeBSD arch " ++ @tagName(native_arch));
        }
    }
};

pub const DarwinImpl = struct {
    const KernE = enum(c_int) {
        SUCCESS = 0,
        INVALID_ADDRESS = 1,
        PROTECTION_FAILURE = 2,
        NO_SPACE = 3,
        INVALID_ARGUMENT = 4,
        FAILURE = 5,
        RESOURCE_SHORTAGE = 6,
        _,
    };

    fn mprotect(addr: usize, len: usize, prot: PROT) Error!void {
        const vm_prot: std.macho.vm_prot_t = .{
            .READ = prot.READ,
            .WRITE = prot.WRITE,
            .EXEC = prot.EXEC,
        };
        const res: KernE = @fromBackingInt(std.c.mach_vm_protect(
            std.c.mach_task_self(),
            addr,
            len,
            0,
            vm_prot,
        ));
        return switch (res) {
            .SUCCESS => return,
            .INVALID_ADDRESS => error.AccessDenied,
            .PROTECTION_FAILURE => error.AccessDenied,
            .NO_SPACE, .RESOURCE_SHORTAGE => error.OutOfMemory,
            else => error.Unexpected,
        };
    }
    extern "c" fn sys_icache_invalidate(start: *const anyopaque, len: usize) void;

    fn clearCache(bytes: []const u8) void {
        sys_icache_invalidate(@ptrCast(bytes.ptr), bytes.len);
    }
};

pub const WindowsImpl = struct {
    fn mprotect(addr: usize, len: usize, prot: PROT) Error!void {
        const windows = std.os.windows;
        const page = windows.PAGE.fromProtection(.{
            .read = prot.READ,
            .write = prot.WRITE,
            .execute = prot.EXEC,
        }) orelse return error.AccessDenied;

        var base: ?windows.PVOID = @ptrFromInt(addr);
        var size: windows.SIZE_T = len;
        var old: windows.PAGE = undefined;

        // NtCurrentProcess is the canonical -1 pseudo-handle; ntdll is not libc.
        switch (windows.ntdll.NtProtectVirtualMemory(
            windows.current_process,
            &base,
            &size,
            page,
            &old,
        )) {
            .SUCCESS => {},
            .INVALID_ADDRESS,
            .INVALID_PARAMETER,
            .ACCESS_DENIED,
            .CONFLICTING_ADDRESSES,
            .INVALID_PAGE_PROTECTION,
            => return error.AccessDenied,
            .INSUFFICIENT_RESOURCES, .NO_MEMORY => return error.OutOfMemory,
            else => |st| return windows.unexpectedStatus(st),
        }
    }
};

fn clearCache(bytes: []const u8) void {
    if (bytes.len == 0) return;

    switch (comptime native_os) {
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => return DarwinImpl.clearCache(bytes),
        else => {},
    }

    if (comptime native_arch == .x86_64 or native_arch == .x86) {
        // x86 I and D caches are coherent; a compiler barrier is enough.
        asm volatile ("" ::: .{ .memory = true });
        return;
    }

    if (comptime native_arch == .aarch64) {
        // Split I/D caches: clean D to Point of Unification, invalidate I,
        // then ISB so this PE fetches the new instructions.
        // CTR_EL0.{DminLine,IminLine} are log2 of words (4 bytes) per line.
        const ctr = asm volatile ("mrs %[reg], ctr_el0"
            : [reg] "=r" (-> u64),
        );
        const dminline: u4 = @truncate(ctr >> 16);
        const iminline: u4 = @truncate(ctr);
        const line_size = @min(@as(usize, 4) << dminline, @as(usize, 4) << iminline);
        const start = @intFromPtr(bytes.ptr);
        const end = start + bytes.len;
        var addr = std.mem.alignBackward(usize, start, line_size);
        while (addr < end) : (addr += line_size) {
            asm volatile ("dc cvau, %[reg]"
                :
                : [reg] "r" (addr),
                : .{ .memory = true });
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });
        addr = std.mem.alignBackward(usize, start, line_size);
        while (addr < end) : (addr += line_size) {
            asm volatile ("ic ivau, %[reg]"
                :
                : [reg] "r" (addr),
                : .{ .memory = true });
        }
        asm volatile (
            \\dsb ish
            \\isb
            ::: .{ .memory = true });
        return;
    }

    if (comptime native_arch == .riscv64) {
        asm volatile ("fence.i" ::: .{ .memory = true });
        return;
    }
}

const testing = std.testing;

test "PROT bit layout matches POSIX" {
    try testing.expectEqual(@as(u32, 1), PROT.bits(.{ .READ = true }));
    try testing.expectEqual(@as(u32, 2), PROT.bits(.{ .WRITE = true }));
    try testing.expectEqual(@as(u32, 4), PROT.bits(.{ .EXEC = true }));
    try testing.expectEqual(@as(u32, 3), PROT.bits(.{ .READ = true, .WRITE = true }));
    try testing.expectEqual(@as(u32, 5), PROT.bits(.{ .READ = true, .EXEC = true }));
}

test "PROT bits match std.os.linux.PROT and std.macho.vm_prot_t" {
    const ours = PROT.bits(.{ .READ = true, .WRITE = true, .EXEC = true });
    const linux_prot: std.os.linux.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
    try testing.expectEqual(ours, @as(u32, @bitCast(linux_prot)) & 0x7);
    const macho_prot: std.macho.vm_prot_t = .{ .READ = true, .WRITE = true, .EXEC = true };
    try testing.expectEqual(ours, @as(u32, @bitCast(macho_prot)) & 0x7);
}

test "Block.init is page sized and writable" {
    var mem = try Block.init(1);
    defer mem.deinit();

    try testing.expectEqual(std.heap.pageSize(), mem.buffer.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mem.buffer.ptr) % std.heap.pageSize());

    mem.buffer[0] = 0xab;
    mem.buffer[mem.buffer.len - 1] = 0xcd;
    try testing.expectEqual(@as(u8, 0xab), mem.buffer[0]);
    try testing.expectEqual(@as(u8, 0xcd), mem.buffer[mem.buffer.len - 1]);
}

test "initWithBytes copies payload" {
    const payload = [_]u8{ 1, 2, 3, 4, 5 };
    var mem = try Block.initWithBytes(&payload);
    defer mem.deinit();
    try testing.expectEqualSlices(u8, &payload, mem.buffer[0..payload.len]);
}

test "mprotect read-write succeeds" {
    var mem = try Block.init(std.heap.pageSize());
    defer mem.deinit();

    try mprotect(@alignCast(mem.buffer), .{ .READ = true, .WRITE = true });
    mem.buffer[0] = 42;
    try testing.expectEqual(@as(u8, 42), mem.buffer[0]);
}

test "mprotect unmapped address fails" {
    const page = std.heap.pageSize();
    const bogus: []align(std.heap.page_size_min) u8 =
        @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(page))[0..page];
    if (mprotect(bogus, .{ .READ = true, .WRITE = true })) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "execute ret" {
    var mem = try Block.init(std.heap.pageSize());
    defer mem.deinit();
    try mem.writable();
    writeRet(mem.buffer);
    try mem.executable();

    const Fn = *const fn () callconv(.c) void;
    const f: Fn = @ptrCast(mem.buffer.ptr);
    f();
}

test "execute add" {
    var mem = try Block.init(std.heap.pageSize());
    defer mem.deinit();
    try mem.writable();
    writeAdd(mem.buffer);
    try mem.executable();

    const AddFn = *const fn (a: i64, b: i64) callconv(.c) i64;
    const add: AddFn = @ptrCast(mem.buffer.ptr);
    try testing.expectEqual(@as(i64, 12), add(5, 7));
    try testing.expectEqual(@as(i64, -3), add(-1, -2));
}

test "reprotect writeable after executable" {
    var mem = try Block.init(std.heap.pageSize());
    defer mem.deinit();

    try mem.writable();
    writeRet(mem.buffer);
    try mem.executable();
    const RetFn = *const fn () callconv(.c) void;
    const ret_fn: RetFn = @ptrCast(mem.buffer.ptr);
    ret_fn();

    try mem.writable();
    writeAdd(mem.buffer);
    try mem.executable();
    const AddFn = *const fn (a: i64, b: i64) callconv(.c) i64;
    const add: AddFn = @ptrCast(mem.buffer.ptr);
    try testing.expectEqual(@as(i64, 9), add(4, 5));
}

test "Pool executable returns a callable copy" {
    var pool: Pool = .init(testing.allocator);
    defer pool.deinit();

    var src = retBytes();
    const rx = try pool.executable(&src);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(rx.ptr) % BlockAlignment);
    try testing.expectEqualSlices(u8, &src, rx);
    try testing.expectEqual(@as(usize, 1), pool.pages.items.len);

    src[0] = 0;
    const Fn = *const fn () callconv(.c) void;
    const f: Fn = @ptrCast(rx.ptr);
    f();
}

test "Pool second block reseals the first" {
    var pool: Pool = .init(testing.allocator);
    defer pool.deinit();

    const ret_rx = try pool.executable(&retBytes());
    const add_rx = try pool.executable(&addBytes());
    try testing.expectEqual(@as(usize, 1), pool.pages.items.len);
    try testing.expect(@intFromPtr(ret_rx.ptr) != @intFromPtr(add_rx.ptr));

    const RetFn = *const fn () callconv(.c) void;
    const ret_f: RetFn = @ptrCast(ret_rx.ptr);
    ret_f();

    const AddFn = *const fn (a: i64, b: i64) callconv(.c) i64;
    const add_f: AddFn = @ptrCast(add_rx.ptr);
    try testing.expectEqual(@as(i64, 12), add_f(5, 7));
}

test "Pool block larger than the tail takes a new page" {
    var pool: Pool = .init(testing.allocator);
    defer pool.deinit();

    const ret_rx = try pool.executable(&retBytes());

    const big = try testing.allocator.alloc(u8, std.heap.pageSize());
    defer testing.allocator.free(big);
    writeRet(big);

    const big_rx = try pool.executable(big);
    try testing.expectEqual(@as(usize, 2), pool.pages.items.len);

    const RetFn = *const fn () callconv(.c) void;
    const first: RetFn = @ptrCast(ret_rx.ptr);
    const second: RetFn = @ptrCast(big_rx.ptr);
    first();
    second();
}

test "Pool deinit unmaps a sealed page" {
    var pool: Pool = .init(testing.allocator);
    errdefer pool.deinit();
    _ = try pool.executable(&retBytes());
    try testing.expectEqual(@as(usize, 1), pool.pages.items.len);
    // deinit makes the sealed page writable, then unmaps it.
    pool.deinit();
}

test "Pool rejects an empty slice" {
    var pool: Pool = .init(testing.allocator);
    defer pool.deinit();
    try testing.expectError(error.Empty, pool.executable(""));
}

fn retBytes() [4]u8 {
    var buf: [4]u8 = @splat(0);
    writeRet(&buf);
    return buf;
}

fn addBytes() [8]u8 {
    var buf: [8]u8 = @splat(0);
    writeAdd(&buf);
    return buf;
}

fn writeRet(buf: []u8) void {
    switch (comptime native_arch) {
        .x86_64 => buf[0] = 0xc3,
        .aarch64 => std.mem.writeInt(u32, buf[0..4], 0xD65F03C0, .little), // RET x30
        .riscv64 => std.mem.writeInt(u32, buf[0..4], 0x00008067, .little), // jalr zero, ra, 0
        else => @compileError("mem tests: unsupported arch " ++ @tagName(native_arch)),
    }
}

fn writeAdd(buf: []u8) void {
    switch (comptime native_arch) {
        .x86_64 => {
            // lea rax, [arg0 + arg1]; ret. SysV: rdi+rsi. Windows: rcx+rdx.
            const bytes = switch (comptime native_os) {
                .windows => [_]u8{ 0x48, 0x8d, 0x04, 0x11, 0xc3 },
                else => [_]u8{ 0x48, 0x8d, 0x04, 0x37, 0xc3 },
            };
            @memcpy(buf[0..bytes.len], &bytes);
        },
        .aarch64 => {
            std.mem.writeInt(u32, buf[0..4], 0x8B010000, .little); // add x0, x0, x1
            std.mem.writeInt(u32, buf[4..8], 0xD65F03C0, .little); // ret
        },
        .riscv64 => {
            std.mem.writeInt(u32, buf[0..4], 0x00B50533, .little); // add a0, a0, a1
            std.mem.writeInt(u32, buf[4..8], 0x00008067, .little); // ret
        },
        else => @compileError("mem tests: unsupported arch " ++ @tagName(native_arch)),
    }
}
