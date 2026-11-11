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

    /// Wake one waiter, if any.
    pub fn signal(cond: *Condition) void {
        _ = c.pthread_cond_signal(&cond.inner);
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
    /// The soft guard zone above the hard guard page (fibers.c); empty for a thread's own
    /// stack. `overflowed` while it's open after a stack overflow.
    soft_low: usize = 0,
    soft_high: usize = 0,
    overflowed: bool = false,
};

/// Bytes between the hard guard page and the usable stack that a stack overflow opens,
/// so the fiber has room to signal the error (fibers.c).
const soft_zone_size: usize = 64 * 1024;

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
    const soft = std.mem.alignForward(usize, soft_zone_size, pageSize());
    const usable = std.mem.alignForward(usize, size, pageSize());
    const mem = try reserve(guard + soft + usable);
    errdefer release(mem);
    try commit(@alignCast(mem[guard + soft ..]));
    const low = @intFromPtr(mem.ptr);
    ctx.* = .{
        .stack = mem,
        .high = low + mem.len,
        .soft_low = low + guard,
        .soft_high = low + guard + soft,
    };
    ctx.sp = initialFrame(ctx.high, entry, arg);
}

extern fn sk_fiber_prepare_thread() void;
extern fn sk_fiber_set_zone(low: usize, high: usize, overflowed: c_int) void;
extern fn sk_fiber_overflowed_now() c_int;

/// Before the calling thread first runs fibers (fibers.c): an alternate signal stack, and
/// the stack overflow handler.
pub fn prepareThreadForFibers() void {
    sk_fiber_prepare_thread();
}

/// The running fiber `ctx` is being switched away from, with its stack at `sp`: note an
/// overflow, and close its soft zone again once nothing on the stack is in it.
pub fn fiberSwitchingOut(ctx: *FiberContext, sp: usize) void {
    if (sk_fiber_overflowed_now() != 0) ctx.overflowed = true;
    if (ctx.overflowed and sp > ctx.soft_high) {
        _ = c.mprotect(@ptrFromInt(ctx.soft_low), ctx.soft_high - ctx.soft_low, .{});
        ctx.overflowed = false;
    }
}

/// `ctx` is about to run on this thread: the fault handler watches its soft zone.
pub fn fiberSwitchingIn(ctx: *const FiberContext) void {
    sk_fiber_set_zone(ctx.soft_low, ctx.soft_high, @intFromBool(ctx.overflowed));
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
/// resume the stack at `load` (fibers.c).
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

/// The first code a new fiber runs (fibers.c): it calls `entry(arg)`.
extern fn sk_fiber_start() callconv(.c) void;

// ---------------------------------------------------------------------------------------
// Processes (skein.process, M3.1, D-103)

var pipes_prepared = std.atomic.Value(bool).init(false);

/// Before the first program starts: ignore SIGPIPE, so that writing to a pipe whose reader
/// has gone fails rather than ending the program (as Python and Rust do). Children inherit
/// it ignored.
pub fn prepareForProcesses() void {
    if (pipes_prepared.swap(true, .acq_rel)) return;
    var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &act, null);
}

/// On Unix a program stays in this program's process group: destroy-tree! finds what it
/// started by walking the process table (descendants), as Java's ProcessHandle does,
/// which reaches programs that make groups of their own too.
pub fn processGroupOptions(options: *std.process.SpawnOptions, own_group: bool) void {
    _ = options;
    _ = own_group;
}

/// After it starts: Windows puts the program in a job object; nothing here.
pub fn startedProcess(child: *std.process.Child) ?*anyopaque {
    _ = child;
    return null;
}

pub fn releaseProcessJob(job: ?*anyopaque) void {
    _ = job;
}

pub fn childProcessId(child: *const std.process.Child) i64 {
    return child.id.?;
}

/// Whether this program ignores SIGINT, as one a shell started in the background does:
/// the programs it starts inherit that, and an interrupt doesn't reach them.
pub fn interruptIgnored() bool {
    var old: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.INT, null, &old);
    return old.handler.handler == posix.SIG.IGN;
}

/// The program's handle for signaling it (Windows's process handle; nothing on Unix).
pub fn childHandle(child: *const std.process.Child) ?*anyopaque {
    _ = child;
    return null;
}

/// Signal a program by intent: 0 interrupt (SIGINT), 1 terminate (SIGTERM), 2 kill
/// (SIGKILL), while it runs; with `tree`, its descendants first. Once it has ended, its
/// pid may be another program's, and its children belong to init: nothing is signaled.
pub fn signalProcess(pid: i64, handle: ?*anyopaque, job: ?*anyopaque, kind: u8, tree: bool, own_group: bool, ended: bool) void {
    _ = handle;
    _ = job;
    _ = own_group;
    if (ended) return;
    const sig: posix.SIG = switch (kind) {
        0 => .INT,
        1 => .TERM,
        else => .KILL,
    };
    const target: c.pid_t = @intCast(pid);
    if (tree) {
        // On the heap: this may run on a fiber's small stack.
        const buf = std.heap.c_allocator.alloc(c.pid_t, 4096) catch return;
        defer std.heap.c_allocator.free(buf);
        const n = descendants(target, buf);
        for (buf[0..n]) |d| _ = std.c.kill(d, sig);
    }
    _ = std.c.kill(target, sig);
}

extern "c" fn proc_listchildpids(ppid: c.pid_t, buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn readdir(dir: *c.DIR) ?*c.dirent;

/// The descendants of `pid` (children, theirs, and so on), into `out`; how many.
fn descendants(pid: c.pid_t, out: []c.pid_t) usize {
    var n: usize = 0;
    if (builtin.os.tag == .macos) {
        // Breadth first: out[i] for i < n are found, and each one's children follow.
        var queue_from: usize = 0;
        var parent = pid;
        while (true) {
            const room = out.len - n;
            if (room == 0) break;
            const got = proc_listchildpids(parent, @ptrCast(out[n..].ptr), @intCast(room * @sizeOf(c.pid_t)));
            if (got > 0) n += @min(@as(usize, @intCast(got)), room);
            if (queue_from == n) break;
            parent = out[queue_from];
            queue_from += 1;
        }
        return n;
    }
    // Linux: every process's parent, from /proc/<pid>/stat, then breadth first.
    const pids = std.heap.c_allocator.alloc(c.pid_t, 16384) catch return 0;
    defer std.heap.c_allocator.free(pids);
    const parents = std.heap.c_allocator.alloc(c.pid_t, 16384) catch return 0;
    defer std.heap.c_allocator.free(parents);
    var count: usize = 0;
    const dir = c.opendir("/proc") orelse return 0;
    defer _ = c.closedir(dir);
    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        const p = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        if (count == pids.len) break;
        pids[count] = p;
        parents[count] = parentOf(p) orelse continue;
        count += 1;
    }
    var queue_from: usize = 0;
    var parent = pid;
    while (true) {
        for (0..count) |i| {
            if (parents[i] == parent and n < out.len) {
                out[n] = pids[i];
                n += 1;
            }
        }
        if (queue_from == n) break;
        parent = out[queue_from];
        queue_from += 1;
    }
    return n;
}

/// A process's parent, from /proc/<pid>/stat on Linux ("pid (name) state ppid ..."; the
/// name may hold spaces and parentheses, so the fields after its last ')').
fn parentOf(pid: c.pid_t) ?c.pid_t {
    var path_buf: [64]u8 = undefined;
    const printed = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "/proc/{d}/stat", .{pid}) catch return null;
    path_buf[printed.len] = 0;
    const path: [:0]const u8 = path_buf[0..printed.len :0];
    const fd = c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const got = c.read(fd, &buf, buf.len);
    if (got <= 0) return null;
    const text = buf[0..@intCast(got)];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // the state
    return std.fmt.parseInt(c.pid_t, fields.next() orelse return null, 10) catch null;
}

/// A pipe, [read end, write end], which programs started later don't inherit (a
/// program's stderr merged into its stdout), or null.
pub fn makePipe() ?[2]std.Io.File {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return .{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

/// Move an open file's position to its end (a program's output appended to a file).
pub fn seekToEnd(handle: std.posix.fd_t) void {
    _ = std.c.lseek(handle, 0, std.c.SEEK.END);
}
