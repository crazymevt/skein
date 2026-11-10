//! The platform layer for macOS and Linux (DESIGN §19.3): virtual memory, a mutex, a
//! monotonic clock and console output, on POSIX and libc. The Windows layer in
//! platform/windows/ provides the same declarations.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

pub const page_size_min = std.heap.page_size_min;

/// The size of a virtual memory page.
pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const MemoryError = error{OutOfMemory};

/// Reserve `len` bytes of address space (a multiple of the page size) with no access.
/// Touching it faults until `commit` makes it usable.
pub fn reserve(len: usize) MemoryError![]align(page_size_min) u8 {
    return posix.mmap(null, len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
        error.OutOfMemory;
}

/// Make reserved memory readable and writable. Newly committed pages read as zero.
pub fn commit(mem: []align(page_size_min) u8) MemoryError!void {
    if (c.mprotect(@ptrCast(mem.ptr), mem.len, .{ .READ = true, .WRITE = true }) != 0)
        return error.OutOfMemory;
}

/// Give committed memory back to the OS but keep the address range reserved.
pub fn decommit(mem: []align(page_size_min) u8) void {
    // Mapping fresh no-access pages over the range drops the old ones.
    _ = posix.mmap(mem.ptr, mem.len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0) catch {};
}

/// Return reserved memory (committed or not) to the OS.
pub fn release(mem: []align(page_size_min) u8) void {
    posix.munmap(mem);
}

/// A mutual-exclusion lock that blocks in the OS when contended.
pub const Mutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn lock(m: *Mutex) void {
        _ = c.pthread_mutex_lock(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        _ = c.pthread_mutex_unlock(&m.inner);
    }

    /// Lock `m` if it is free; return whether it did.
    pub fn tryLock(m: *Mutex) bool {
        return c.pthread_mutex_trylock(&m.inner) == .SUCCESS;
    }
};

/// Give up the rest of this thread's time slice.
pub fn yieldThread() void {
    _ = c.sched_yield();
}

/// A condition variable, used with `Mutex`.
pub const Condition = struct {
    inner: c.pthread_cond_t = .{},

    /// Atomically unlock `m` and wait; `m` is locked again on return. Wakeups can be
    /// spurious, so callers re-check their condition in a loop.
    pub fn wait(cond: *Condition, m: *Mutex) void {
        _ = c.pthread_cond_wait(&cond.inner, &m.inner);
    }

    pub fn broadcast(cond: *Condition) void {
        _ = c.pthread_cond_broadcast(&cond.inner);
    }

    /// Like `wait`, but return after at most `nanos` nanoseconds.
    pub fn timedWait(cond: *Condition, m: *Mutex, nanos: u64) void {
        var now: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK.REALTIME, &now);
        const total = @as(u64, @intCast(now.nsec)) + nanos;
        var until: c.timespec = now;
        until.sec += @intCast(total / std.time.ns_per_s);
        until.nsec = @intCast(total % std.time.ns_per_s);
        _ = c.pthread_cond_timedwait(&cond.inner, &m.inner, &until);
    }
};

/// Start a detached thread running `f(arg)` with a stack of `stack_size` bytes.
pub fn spawnThread(f: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque, stack_size: usize) bool {
    var attr: c.pthread_attr_t = undefined;
    if (c.pthread_attr_init(&attr) != .SUCCESS) return false;
    defer _ = c.pthread_attr_destroy(&attr);
    _ = c.pthread_attr_setstacksize(&attr, stack_size);
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, &attr, f, arg) != .SUCCESS) return false;
    _ = c.pthread_detach(thread);
    return true;
}

extern "c" fn sysconf(name: c_int) c_long;

/// The number of CPUs online.
pub fn cpuCount() usize {
    const name: c_int = if (builtin.os.tag == .macos) 58 else 84; // _SC_NPROCESSORS_ONLN
    const n = sysconf(name);
    return if (n > 0) @intCast(n) else 1;
}

/// The address range of the current thread's stack: [low, high). Stacks grow down.
pub const StackBounds = struct { low: usize, high: usize };

extern "c" fn pthread_get_stackaddr_np(thread: c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: c.pthread_t, attr: *c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(attr: *const c.pthread_attr_t, addr: *?*anyopaque, size: *usize) c_int;

pub fn currentStackBounds() StackBounds {
    const self = c.pthread_self();
    switch (builtin.os.tag) {
        .macos => {
            const high = @intFromPtr(pthread_get_stackaddr_np(self));
            return .{ .low = high - pthread_get_stacksize_np(self), .high = high };
        },
        else => {
            var attr: c.pthread_attr_t = undefined;
            var addr: ?*anyopaque = null;
            var size: usize = 0;
            if (pthread_getattr_np(self, &attr) != 0) @panic("pthread_getattr_np failed");
            defer _ = c.pthread_attr_destroy(&attr);
            _ = pthread_attr_getstack(&attr, &addr, &size);
            return .{ .low = @intFromPtr(addr), .high = @intFromPtr(addr) + size };
        },
    }
}

/// Nanoseconds from a monotonic clock with an arbitrary start.
pub fn monotonicNanos() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Write bytes to standard output, ignoring errors.
pub fn writeStdout(bytes: []const u8) void {
    writeAll(1, bytes);
}

/// Write bytes to standard error, ignoring errors.
pub fn writeStderr(bytes: []const u8) void {
    writeAll(2, bytes);
}

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

/// The process's environment, for spawning programs (std.process wants it passed in).
pub fn processEnviron() std.process.Environ {
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    return .{ .block = .{ .slice = std.mem.span(env) } };
}

// ---------------------------------------------------------------------------------------
// C libraries (the FFI, M1.10)

/// "macos" or "linux": which entry of a deflibrary spec applies.
pub const os_name = if (builtin.os.tag == .macos) "macos" else "linux";

/// The separator of SKEIN_LIBRARY_PATH's directories.
pub const path_list_separator = ':';

/// Directories searched for C libraries before the system's places (as Phase 0's
/// skein.platform:library-directories).
pub const library_directories: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/opt/homebrew/lib/", "/usr/local/lib/" }
else
    &.{"/usr/local/lib/"};

/// Where a program's assets are, relative to the directory of its executable `exe_dir`
/// (skein.io/resource-dir, D-073): a macOS app's Contents/Resources when it runs in one,
/// else the executable's own directory.
pub fn resourceSubdirectory(exe_dir: []const u8) []const u8 {
    if (builtin.os.tag == .macos and std.mem.endsWith(u8, exe_dir, ".app/Contents/MacOS"))
        return "../Resources/";
    return "";
}

/// Where a packaged program keeps its C libraries, relative to the executable's directory
/// (D-069): beside it, and in a macOS app's Contents/Frameworks.
pub const executable_library_directories: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "", "../Frameworks/" }
else
    &.{""};

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;

const RTLD_NOW: c_int = 2;
const RTLD_GLOBAL: c_int = if (builtin.os.tag == .macos) 8 else 0x100;
const RTLD_DEFAULT: ?*anyopaque = if (builtin.os.tag == .macos) @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))) else null;

/// Load the C library at `path` (a file name the system searches for, or a path); null if
/// it can't be loaded, with the reason in `why` when there is room.
pub fn loadLibrary(path: [:0]const u8, why: []u8) ?*anyopaque {
    if (dlopen(path.ptr, RTLD_NOW | RTLD_GLOBAL)) |h| return h;
    if (dlerror()) |e| {
        const msg = std.mem.span(e);
        const n = @min(msg.len, why.len);
        @memcpy(why[0..n], msg[0..n]);
        if (n < why.len) why[n] = 0;
    }
    return null;
}

/// The address of `name` in the library `handle`, or null.
pub fn librarySymbol(handle: *anyopaque, name: [:0]const u8) ?*anyopaque {
    return dlsym(handle, name.ptr);
}

/// libm's handle once opened (Linux only), or 0.
var libm_handle: std.atomic.Value(usize) = .init(0);

/// The address of `name` in any library the process has loaded, or null. On Linux that
/// includes libm (D-067).
pub fn processSymbol(name: [:0]const u8) ?*anyopaque {
    if (dlsym(RTLD_DEFAULT, name.ptr)) |p| return p;
    if (builtin.os.tag != .linux) return null;
    // On Linux the math functions are in libm, which a native program doesn't load: the
    // runtime's own math comes from Zig's compiler_rt. SBCL's process has libm, so open
    // it the first time a symbol isn't found elsewhere. (Opening it twice is harmless.)
    var h = libm_handle.load(.acquire);
    if (h == 0) {
        h = @intFromPtr(dlopen("libm.so.6", RTLD_NOW) orelse return null);
        libm_handle.store(h, .release);
    }
    return dlsym(@ptrFromInt(h), name.ptr);
}

// ---------------------------------------------------------------------------------------
// Fibers (M2.2, D-074): stacks of their own, switched by a routine per architecture that
// saves the callee-saved registers on the old stack and loads the new stack pointer.

/// A fiber's machine state: its stack (the whole reservation, guard page included) and,
/// while it isn't running, the stack pointer to resume at.
pub const FiberContext = struct {
    sp: usize = 0,
    stack: []align(page_size_min) u8 = &.{},
    /// The top of the stack (stacks grow down); 0 until known.
    high: usize = 0,
};

/// The entry point of a new fiber: called with the argument given to createFiber, on the
/// fiber's stack. It must never return.
pub const FiberEntry = *const fn (?*anyopaque) callconv(.c) noreturn;

/// Bytes below each fiber stack that fault when touched.
pub fn fiberGuardSize() usize {
    return pageSize();
}

/// Make `ctx` a new fiber with a stack of at least `size` bytes above a guard page, which
/// runs `entry(arg)` when it's first switched to. Pages are committed by the OS as the
/// fiber touches them.
pub fn createFiber(ctx: *FiberContext, size: usize, entry: FiberEntry, arg: ?*anyopaque) MemoryError!void {
    const guard = fiberGuardSize();
    const usable = std.mem.alignForward(usize, size, pageSize());
    const mem = try reserve(guard + usable);
    errdefer release(mem);
    try commit(@alignCast(mem[guard..]));
    ctx.* = .{ .stack = mem, .high = @intFromPtr(mem.ptr) + mem.len };
    ctx.sp = initialFrame(ctx.high, entry, arg);
}

/// Free a fiber's stack. It must not be running.
pub fn destroyFiber(ctx: *FiberContext) void {
    if (ctx.stack.len != 0) release(ctx.stack);
    ctx.* = .{};
}

/// Make `ctx` stand for the calling thread's own stack, so a fiber can switch back to it.
pub fn initThreadFiber(ctx: *FiberContext) void {
    ctx.* = .{ .high = currentStackBounds().high };
}

/// Save the running context into `from` and resume `to`. Returns when something switches
/// back to `from`.
pub fn switchFiber(from: *FiberContext, to: *FiberContext) void {
    switchStacks(&from.sp, to.sp);
}

/// Save the callee-saved registers on the current stack, store its pointer in `save`, and
/// resume the stack at `load` (fiber_switch.c).
extern fn sk_switch_stacks(save: *usize, load: usize) void;

fn switchStacks(save: *usize, load: usize) void {
    sk_switch_stacks(save, load);
}

/// Lay out a new fiber's first frame below `high` so that switching to it runs
/// `entry(arg)`; return its stack pointer.
fn initialFrame(high: usize, entry: FiberEntry, arg: ?*anyopaque) usize {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            // sk_switch_stacks pops x19-x30 and d8-d15 (160 bytes), then returns to x30.
            const sp = high - 160;
            const words: [*]usize = @ptrFromInt(sp);
            @memset(words[0..20], 0);
            words[0] = @intFromPtr(entry); // x19
            words[1] = @intFromPtr(arg); // x20
            words[11] = @intFromPtr(&sk_fiber_start); // x30
            return sp;
        },
        .x86_64 => {
            // sk_switch_stacks pops the float control words, r15, r14, r13, r12, rbx and
            // rbp, then returns. After the return the stack pointer is 16-aligned, so
            // sk_fiber_start's call enters `entry` with the usual alignment.
            const sp = high - 16 - 8 * 8;
            const words: [*]usize = @ptrFromInt(sp);
            @memset(words[0..8], 0);
            words[0] = 0x037F_0000_1F80; // MXCSR, then the x87 control word
            words[4] = @intFromPtr(entry); // r12
            words[3] = @intFromPtr(arg); // r13
            words[7] = @intFromPtr(&sk_fiber_start); // return address
            return sp;
        },
        else => @compileError("fibers support arm64 and x86_64"),
    }
}

/// The first code a new fiber runs (fiber_switch.c): it calls `entry(arg)`.
extern fn sk_fiber_start() callconv(.c) void;
