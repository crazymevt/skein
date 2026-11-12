//! The platform layer for Windows (DESIGN §19.3): virtual memory, a mutex, a monotonic
//! clock and console output, on the Win32 API. platform/posix/ provides the same
//! declarations for macOS and Linux.

const std = @import("std");
const builtin = @import("builtin");

pub const page_size_min = std.heap.page_size_min;

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_DECOMMIT: u32 = 0x4000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_NOACCESS: u32 = 0x01;
const PAGE_READWRITE: u32 = 0x04;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };
const INFINITE: u32 = 0xFFFFFFFF;

extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, allocation_type: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, free_type: u32) callconv(.winapi) i32;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(cv: *CONDITION_VARIABLE, lock: *SRWLOCK, milliseconds: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn WakeAllConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn WakeConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn TryAcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) u8;
extern "kernel32" fn SwitchToThread() callconv(.winapi) i32;
extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, parameter: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetActiveProcessorCount(group: u16) callconv(.winapi) u32;
extern "kernel32" fn WriteFile(file: ?*anyopaque, buffer: [*]const u8, count: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

/// The size of a virtual memory page.
pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const MemoryError = error{OutOfMemory};

/// Reserve `len` bytes of address space (a multiple of the page size) with no access.
/// Touching it faults until `commit` makes it usable.
pub fn reserve(len: usize) MemoryError![]align(page_size_min) u8 {
    const p = VirtualAlloc(null, len, MEM_RESERVE, PAGE_NOACCESS) orelse return error.OutOfMemory;
    return @as([*]align(page_size_min) u8, @ptrCast(@alignCast(p)))[0..len];
}

/// Make reserved memory readable and writable. Newly committed pages read as zero.
pub fn commit(mem: []align(page_size_min) u8) MemoryError!void {
    if (VirtualAlloc(mem.ptr, mem.len, MEM_COMMIT, PAGE_READWRITE) == null)
        return error.OutOfMemory;
}

/// Give committed memory back to the OS but keep the address range reserved.
pub fn decommit(mem: []align(page_size_min) u8) void {
    _ = VirtualFree(mem.ptr, mem.len, MEM_DECOMMIT);
}

/// Return reserved memory (committed or not) to the OS.
pub fn release(mem: []align(page_size_min) u8) void {
    _ = VirtualFree(mem.ptr, 0, MEM_RELEASE);
}

/// A mutual-exclusion lock that blocks in the OS when contended.
pub const Mutex = struct {
    inner: SRWLOCK = .{},

    pub fn lock(m: *Mutex) void {
        AcquireSRWLockExclusive(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        ReleaseSRWLockExclusive(&m.inner);
    }

    /// Lock `m` if it is free; return whether it did.
    pub fn tryLock(m: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&m.inner) != 0;
    }
};

/// Give up the rest of this thread's time slice.
pub fn yieldThread() void {
    _ = SwitchToThread();
}

/// A condition variable, used with `Mutex`.
pub const Condition = struct {
    inner: CONDITION_VARIABLE = .{},

    /// Atomically unlock `m` and wait; `m` is locked again on return. Wakeups can be
    /// spurious, so callers re-check their condition in a loop.
    pub fn wait(cond: *Condition, m: *Mutex) void {
        _ = SleepConditionVariableSRW(&cond.inner, &m.inner, INFINITE, 0);
    }

    pub fn broadcast(cond: *Condition) void {
        WakeAllConditionVariable(&cond.inner);
    }

    /// Wake one waiter, if any.
    pub fn signal(cond: *Condition) void {
        WakeConditionVariable(&cond.inner);
    }

    /// Like `wait`, but return after at most `nanos` nanoseconds.
    pub fn timedWait(cond: *Condition, m: *Mutex, nanos: u64) void {
        const ms: u32 = @intCast(@max(1, @min(nanos / std.time.ns_per_ms, 0xFFFFFFFE)));
        _ = SleepConditionVariableSRW(&cond.inner, &m.inner, ms, 0);
    }
};

const ThreadStart = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

const ThreadArg = struct { f: ThreadStart, arg: ?*anyopaque };

fn threadMain(p: ?*anyopaque) callconv(.winapi) u32 {
    const a: *ThreadArg = @ptrCast(@alignCast(p));
    const f = a.f;
    const arg = a.arg;
    std.heap.page_allocator.destroy(a);
    _ = f(arg);
    return 0;
}

/// Start a detached thread running `f(arg)` with a stack of `stack_size` bytes.
pub fn spawnThread(f: ThreadStart, arg: ?*anyopaque, stack_size: usize) bool {
    const a = std.heap.page_allocator.create(ThreadArg) catch return false;
    a.* = .{ .f = f, .arg = arg };
    const h = CreateThread(null, stack_size, threadMain, a, 0, null) orelse {
        std.heap.page_allocator.destroy(a);
        return false;
    };
    _ = CloseHandle(h);
    return true;
}

/// The number of CPUs online.
pub fn cpuCount() usize {
    const n = GetActiveProcessorCount(0xFFFF);
    return if (n > 0) n else 1;
}

/// The address range of the current thread's stack: [low, high). Stacks grow down.
pub const StackBounds = struct { low: usize, high: usize };

pub fn currentStackBounds() StackBounds {
    var low: usize = 0;
    var high: usize = 0;
    GetCurrentThreadStackLimits(&low, &high);
    return .{ .low = low, .high = high };
}

/// Nanoseconds from a monotonic clock with an arbitrary start.
pub fn monotonicNanos() u64 {
    var count: i64 = 0;
    var frequency: i64 = 1;
    _ = QueryPerformanceCounter(&count);
    _ = QueryPerformanceFrequency(&frequency);
    const ns = @as(u128, @intCast(count)) * std.time.ns_per_s / @as(u128, @intCast(frequency));
    return @intCast(ns);
}

/// Write bytes to standard output, ignoring errors.
pub fn writeStdout(bytes: []const u8) void {
    writeAll(GetStdHandle(STD_OUTPUT_HANDLE), bytes);
}

/// Write bytes to standard error, ignoring errors.
pub fn writeStderr(bytes: []const u8) void {
    writeAll(GetStdHandle(STD_ERROR_HANDLE), bytes);
}

fn writeAll(handle: ?*anyopaque, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const chunk: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
        var written: u32 = 0;
        if (WriteFile(handle, rest.ptr, chunk, &written, null) == 0 or written == 0) return;
        rest = rest[written..];
    }
}

/// The process's environment, for spawning programs (std.process wants it passed in).
pub fn processEnviron() std.process.Environ {
    return .{ .block = .global };
}

// ---------------------------------------------------------------------------------------
// C libraries (the FFI, M1.10)

/// The permissions of a file or directory only its owner may use (D-107): Windows' defaults,
/// since a user's files and %TEMP% are already only theirs; owner-only! does nothing.
pub fn ownerOnlyPermissions(directory: bool) std.Io.File.Permissions {
    _ = directory;
    return .default_file;
}

/// A file's permission bits: none on Windows.
pub fn modeBits(permissions: std.Io.File.Permissions) ?u32 {
    _ = permissions;
    return null;
}

/// Whether owner-only! changes anything here.
pub const has_owner_only = false;

/// "windows": which entry of a deflibrary spec applies.
pub const os_name = "windows";

/// The separator of SKEIN_LIBRARY_PATH's directories.
pub const path_list_separator = ';';

/// Directories searched for C libraries before the system's places: none on Windows.
pub const library_directories: []const []const u8 = &.{};

/// Where a program's assets are, relative to the directory of its executable
/// (skein.io/resource-dir, D-073): the executable's own directory.
pub fn resourceSubdirectory(exe_dir: []const u8) []const u8 {
    _ = exe_dir;
    return "";
}

/// Where a packaged program keeps its C libraries, relative to the executable's directory
/// (D-069): beside it.
pub const executable_library_directories: []const []const u8 = &.{""};

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn K32EnumProcessModules(process: *anyopaque, modules: [*]?*anyopaque, size: u32, needed: *u32) callconv(.winapi) i32;

/// Load the C library at `path` (UTF-8); null if it can't be loaded, with the reason in
/// `why` when there is room.
pub fn loadLibrary(path: [:0]const u8, why: []u8) ?*anyopaque {
    var wide: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[n] = 0;
    if (LoadLibraryW(@ptrCast(&wide))) |h| return h;
    const msg = std.fmt.bufPrint(why[0 .. why.len - 1], "error {d}", .{GetLastError()}) catch "";
    why[msg.len] = 0;
    return null;
}

/// The address of `name` in the library `handle`, or null.
pub fn librarySymbol(handle: *anyopaque, name: [:0]const u8) ?*anyopaque {
    return GetProcAddress(handle, name.ptr);
}

/// The address of `name` in any module the process has loaded, or null.
pub fn processSymbol(name: [:0]const u8) ?*anyopaque {
    var modules: [512]?*anyopaque = undefined;
    var needed: u32 = 0;
    if (K32EnumProcessModules(GetCurrentProcess(), &modules, @sizeOf(@TypeOf(modules)), &needed) == 0) return null;
    const count = @min(needed / @sizeOf(?*anyopaque), modules.len);
    for (modules[0..count]) |m| {
        if (m) |module| if (GetProcAddress(module, name.ptr)) |p| return p;
    }
    return null;
}

// ---------------------------------------------------------------------------------------
// Fibers (M2.2, D-074): Windows' own fibers, which keep the stack bounds in the thread
// information block that the unwinder (and so mingw's longjmp) and stack growth check.

extern "kernel32" fn CreateFiberEx(commit: usize, reserve_size: usize, flags: u32, start: *const fn (?*anyopaque) callconv(.winapi) void, parameter: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn ConvertThreadToFiberEx(parameter: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;

const FIBER_FLAG_FLOAT_SWITCH: u32 = 1;

/// A fiber's machine state: Windows' fiber, and the top of its stack (0 until it first
/// runs, when Windows has made the stack).
pub const FiberContext = struct {
    handle: ?*anyopaque = null,
    high: usize = 0,
    entry: ?FiberEntry = null,
    arg: ?*anyopaque = null,
    /// A thread's own stack, rather than a fiber's.
    is_thread: bool = false,
    /// Set after a stack overflow until Windows' guard page is back.
    overflowed: bool = false,
};

/// The entry point of a new fiber: called with the argument given to createFiber, on the
/// fiber's stack. It must never return.
pub const FiberEntry = *const fn (?*anyopaque) callconv(.c) noreturn;

/// Bytes below each fiber stack that fault when touched (Windows' guard page).
pub fn fiberGuardSize() usize {
    return pageSize();
}

extern "kernel32" fn SetThreadStackGuarantee(size: *u32) callconv(.winapi) i32;
extern "kernel32" fn AddVectoredExceptionHandler(first: u32, handler: std.os.windows.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
extern "c" fn _resetstkoflw() c_int;

/// Room Windows keeps below a fiber's stack for handling its overflow: enough to signal
/// the error.
const overflow_guarantee: u32 = 64 * 1024;

fn fiberStart(parameter: ?*anyopaque) callconv(.winapi) void {
    const ctx: *FiberContext = @ptrCast(@alignCast(parameter));
    ctx.high = currentStackBounds().high;
    var guarantee = overflow_guarantee;
    _ = SetThreadStackGuarantee(&guarantee);
    ctx.entry.?(ctx.arg);
}

// Stack overflow: Windows raises EXCEPTION_STACK_OVERFLOW when a fiber's guard page is
// used up. In a fiber, the handler makes it continue in sk_stack_overflow (fiber.zig),
// which signals the error in the space of the stack guarantee; Windows' guard page is
// put back once the fiber's stack is shallow again (_resetstkoflw).

extern fn sk_stack_overflow() callconv(.c) noreturn;
/// fibers.c: calls sk_stack_overflow from a frame Windows' unwinder can walk (x86_64).
extern fn sk_stack_overflow_trampoline() callconv(.c) noreturn;

/// Whether this thread runs a fiber now (not its own stack), and whether it overflowed.
threadlocal var in_fiber = false;
threadlocal var overflowed_now = false;

fn onException(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;
    const EXCEPTION_CONTINUE_SEARCH: c_long = 0;
    if (info.ExceptionRecord.ExceptionCode != std.os.windows.EXCEPTION_STACK_OVERFLOW or
        !in_fiber or overflowed_now) return EXCEPTION_CONTINUE_SEARCH;
    overflowed_now = true;
    const ctx = info.ContextRecord;
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // As if the code that overflowed had called the trampoline.
            ctx.Rsp -= 8;
            @as(*u64, @ptrFromInt(ctx.Rsp)).* = ctx.Rip;
            ctx.Rip = @intFromPtr(&sk_stack_overflow_trampoline);
        },
        .aarch64 => {
            ctx.Sp &= ~@as(u64, 15);
            ctx.DUMMYUNIONNAME.X[30] = ctx.Pc;
            ctx.Pc = @intFromPtr(&sk_stack_overflow);
        },
        else => @compileError("fibers support arm64 and x86_64"),
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

var handler_installed = std.atomic.Value(bool).init(false);

/// Before the calling thread first runs fibers: install the stack overflow handler (once
/// per process).
pub fn prepareThreadForFibers() void {
    if (!handler_installed.swap(true, .acq_rel)) _ = AddVectoredExceptionHandler(1, onException);
}

/// The running fiber `ctx` is being switched away from, with its stack at `sp`: note an
/// overflow, and put Windows' guard page back once the stack is shallow.
pub fn fiberSwitchingOut(ctx: *FiberContext, sp: usize) void {
    _ = sp;
    if (overflowed_now) ctx.overflowed = true;
    if (ctx.overflowed and _resetstkoflw() != 0) ctx.overflowed = false;
}

/// `ctx` is about to run on this thread.
pub fn fiberSwitchingIn(ctx: *const FiberContext) void {
    in_fiber = !ctx.is_thread;
    overflowed_now = ctx.overflowed;
}

/// Make `ctx` a new fiber with a stack of at least `size` bytes, which runs `entry(arg)`
/// when it's first switched to. Windows commits its pages as the fiber touches them.
pub fn createFiber(ctx: *FiberContext, size: usize, entry: FiberEntry, arg: ?*anyopaque) MemoryError!void {
    ctx.* = .{ .entry = entry, .arg = arg };
    // The stack guarantee comes out of the reservation, so reserve it on top.
    const reserve_size = size + overflow_guarantee + 2 * pageSize();
    ctx.handle = CreateFiberEx(pageSize(), reserve_size, FIBER_FLAG_FLOAT_SWITCH, fiberStart, ctx) orelse
        return error.OutOfMemory;
}

/// Free a fiber and its stack. It must not be running.
pub fn destroyFiber(ctx: *FiberContext) void {
    if (ctx.handle) |h| DeleteFiber(h);
    ctx.* = .{};
}

/// This thread's own fiber (Windows makes the thread one the first time).
threadlocal var thread_fiber: ?*anyopaque = null;

/// Make `ctx` stand for the calling thread's own stack, so a fiber can switch back to it.
pub fn initThreadFiber(ctx: *FiberContext) void {
    if (thread_fiber == null) thread_fiber = ConvertThreadToFiberEx(null, FIBER_FLAG_FLOAT_SWITCH);
    ctx.* = .{ .handle = thread_fiber, .high = currentStackBounds().high, .is_thread = true };
}

/// Save the running context into `from` and resume `to`. Returns when something switches
/// back to `from`.
pub fn switchFiber(from: *FiberContext, to: *FiberContext) void {
    _ = from;
    SwitchToFiber(to.handle.?);
}

// ---------------------------------------------------------------------------------------
// Processes (skein.process, M3.1, D-103)

extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn AssignProcessToJobObject(job: *anyopaque, process: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(thread: *anyopaque) callconv(.winapi) u32;
extern "kernel32" fn GetProcessId(process: *anyopaque) callconv(.winapi) u32;

pub fn prepareForProcesses() void {}

/// Every program starts suspended, so that it joins its job object (startedProcess)
/// before it can start programs of its own.
pub fn processGroupOptions(options: *std.process.SpawnOptions, own_group: bool) void {
    _ = own_group;
    options.start_suspended = true;
}

/// Put the program in a job object of its own, which reaches what it starts, and let it
/// run. The job, or null if one couldn't be made.
pub fn startedProcess(child: *std.process.Child) ?*anyopaque {
    const job = CreateJobObjectW(null, null);
    if (job) |j| _ = AssignProcessToJobObject(j, child.id.?);
    _ = ResumeThread(child.thread_handle);
    return job;
}

extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: *anyopaque, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn QueryInformationJobObject(job: *anyopaque, class: c_int, info: *anyopaque, length: u32, returned: ?*u32) callconv(.winapi) i32;

/// JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.
const JobAccounting = extern struct {
    total_user_time: i64,
    total_kernel_time: i64,
    this_period_user_time: i64,
    this_period_kernel_time: i64,
    page_faults: u32,
    total_processes: u32,
    active_processes: u32,
    terminated_processes: u32,
};

/// Block until the program has ended.
pub fn awaitExit(child: *std.process.Child) void {
    _ = WaitForSingleObject(child.id.?, 0xFFFFFFFF); // INFINITE
}

/// Collect the ended program: its exit code; its process and thread handles are closed.
pub fn collectExit(child: *std.process.Child) i64 {
    var code: u32 = 0;
    _ = GetExitCodeProcess(child.id.?, &code);
    _ = CloseHandle(child.id.?);
    _ = CloseHandle(child.thread_handle);
    child.id = null;
    return code;
}

/// Once the program has ended: close the handle that signaled it, and its job object
/// unless programs it started still run in it (destroy-tree! can reach them then). The
/// job still needed, or null.
pub fn afterExit(handle: ?*anyopaque, job: ?*anyopaque) ?*anyopaque {
    if (handle) |h| _ = CloseHandle(h);
    const j = job orelse return null;
    var info: JobAccounting = undefined;
    if (QueryInformationJobObject(j, 1, &info, @sizeOf(JobAccounting), null) != 0 and info.active_processes == 0) {
        _ = CloseHandle(j);
        return null;
    }
    return j;
}

pub fn childProcessId(child: *const std.process.Child) i64 {
    return GetProcessId(child.id.?);
}

extern "kernel32" fn TerminateProcess(process: *anyopaque, code: u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(job: *anyopaque, code: u32) callconv(.winapi) i32;
extern "kernel32" fn DuplicateHandle(source_process: *anyopaque, source: *anyopaque, target_process: *anyopaque, target: *?*anyopaque, access: u32, inherit: i32, options: u32) callconv(.winapi) i32;

pub fn interruptIgnored() bool {
    return false;
}

/// The program's handle for signaling it: a copy of its process handle, which stays valid
/// after the reaper's wait closes the original.
pub fn childHandle(child: *const std.process.Child) ?*anyopaque {
    var copy: ?*anyopaque = null;
    const me = GetCurrentProcess();
    if (DuplicateHandle(me, child.id.?, me, &copy, 0, 0, 2) == 0) return null; // DUPLICATE_SAME_ACCESS
    return copy;
}

/// Signal a program by intent: 1 terminate and 2 kill (TerminateProcess); with `tree`,
/// its job object, which holds what it started, even once the program has ended. An
/// interrupt (0) isn't supported: skein.process refuses it, since a Ctrl-Break event only
/// reaches a program started in a console process group of its own, which Zig's spawn
/// can't do (D-103).
pub fn signalProcess(pid: i64, handle: ?*anyopaque, job: ?*anyopaque, kind: u8, tree: bool, own_group: bool, ended: bool) void {
    _ = pid;
    _ = own_group;
    if (kind == 0) return;
    if (tree) if (job) |j| {
        _ = TerminateJobObject(j, 1);
        return;
    };
    if (!ended) if (handle) |h| {
        _ = TerminateProcess(h, 1);
    };
}

const SECURITY_ATTRIBUTES = extern struct { length: u32, descriptor: ?*anyopaque, inherit: i32 };
extern "kernel32" fn CreatePipe(read: *?*anyopaque, write: *?*anyopaque, attributes: ?*const SECURITY_ATTRIBUTES, size: u32) callconv(.winapi) i32;
extern "kernel32" fn SetHandleInformation(handle: *anyopaque, mask: u32, flags: u32) callconv(.winapi) i32;

/// A pipe, [read end, write end], whose write end a program can inherit and whose read
/// end stays here (a program's stderr merged into its stdout), or null.
pub fn makePipe() ?[2]std.Io.File {
    var r: ?*anyopaque = null;
    var w: ?*anyopaque = null;
    const sa: SECURITY_ATTRIBUTES = .{ .length = @sizeOf(SECURITY_ATTRIBUTES), .descriptor = null, .inherit = 1 };
    if (CreatePipe(&r, &w, &sa, 0) == 0) return null;
    _ = SetHandleInformation(r.?, 1, 0); // HANDLE_FLAG_INHERIT off
    return .{
        .{ .handle = r.?, .flags = .{ .nonblocking = false } },
        .{ .handle = w.?, .flags = .{ .nonblocking = false } },
    };
}

extern "kernel32" fn SetFilePointerEx(file: *anyopaque, distance: i64, new_position: ?*i64, method: u32) callconv(.winapi) i32;

/// Move an open file's position to its end (a program's output appended to a file).
pub fn seekToEnd(handle: *anyopaque) void {
    _ = SetFilePointerEx(handle, 0, null, 2); // FILE_END
}

// ---------------------------------------------------------------------------------------
// File system watchers (M3.5, D-107): ReadDirectoryChangesW on the root, with its whole
// tree, read by a thread of the watcher's own, which an event wakes to stop. A watcher
// reports each change to a sink as a kind and a path relative to the root (with /); `rescan`
// says events were lost (the buffer overflowed), so the reader should look again. After
// stopWatch returns, the sink is never called again.

pub const WatchKind = enum(u8) { created, modified, deleted, rescan };

pub const WatchSink = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, kind: WatchKind, relative: []const u8) void,
};

const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadDirectoryChangesW(dir: *anyopaque, buffer: *anyopaque, length: u32, subtree: i32, filter: u32, returned: ?*u32, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual_reset: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(event: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const ?*anyopaque, wait_all: i32, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetOverlappedResult(file: *anyopaque, overlapped: *OVERLAPPED, transferred: *u32, wait: i32) callconv(.winapi) i32;
extern "kernel32" fn CancelIoEx(file: *anyopaque, overlapped: ?*OVERLAPPED) callconv(.winapi) i32;

const INVALID_HANDLE: usize = std.math.maxInt(usize);
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const FILE_SHARE_ALL: u32 = 0x1 | 0x2 | 0x4;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const NOTIFY_FILTER: u32 = 0x1 | 0x2 | 0x8 | 0x10 | 0x40; // file and directory names, size, last write, creation

const watch_alloc = std.heap.c_allocator;

pub const Watch = struct {
    dir: *anyopaque,
    io_event: *anyopaque,
    stop_event: *anyopaque,
    sink: WatchSink,
    buffer: [65536]u8 align(4) = undefined,
    lock: Mutex = .{},
    done_cond: Condition = .{},
    done: bool = false,
};

/// Start watching the directory tree at `root`; null if it can't be watched.
pub fn startWatch(root: [:0]const u8, sink: WatchSink) ?*Watch {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(watch_alloc, root) catch return null;
    defer watch_alloc.free(wide);
    const dir = CreateFileW(wide.ptr, FILE_LIST_DIRECTORY, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null) orelse return null;
    if (@intFromPtr(dir) == INVALID_HANDLE) return null;
    const io_event = CreateEventW(null, 1, 0, null) orelse {
        _ = CloseHandle(dir);
        return null;
    };
    const stop_event = CreateEventW(null, 1, 0, null) orelse {
        _ = CloseHandle(io_event);
        _ = CloseHandle(dir);
        return null;
    };
    const w = watch_alloc.create(Watch) catch return null;
    w.* = .{ .dir = dir, .io_event = io_event, .stop_event = stop_event, .sink = sink };
    if (!spawnThread(watchThread, w, 1 << 20)) {
        closeWatch(w);
        return null;
    }
    return w;
}

fn closeWatch(w: *Watch) void {
    _ = CloseHandle(w.dir);
    _ = CloseHandle(w.io_event);
    _ = CloseHandle(w.stop_event);
    watch_alloc.destroy(w);
}

fn watchThread(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const w: *Watch = @ptrCast(@alignCast(arg));
    while (true) {
        var ov: OVERLAPPED = .{ .event = w.io_event };
        if (ReadDirectoryChangesW(w.dir, &w.buffer, w.buffer.len, 1, NOTIFY_FILTER, null, &ov, null) == 0) break;
        const handles = [_]?*anyopaque{ w.io_event, w.stop_event };
        const which = WaitForMultipleObjects(2, &handles, 0, INFINITE);
        var n: u32 = 0;
        if (which != 0) {
            // Stopping: cancel the read and wait for it to end, so the buffer is free.
            _ = CancelIoEx(w.dir, &ov);
            _ = GetOverlappedResult(w.dir, &ov, &n, 1);
            break;
        }
        if (GetOverlappedResult(w.dir, &ov, &n, 0) == 0) break;
        resetEvent(w.io_event);
        if (n == 0) {
            // The changes didn't fit the buffer.
            w.sink.report(w.sink.context, .rescan, "");
            continue;
        }
        reportChanges(w, w.buffer[0..n]);
    }
    w.lock.lock();
    w.done = true;
    w.done_cond.signal();
    w.lock.unlock();
    return null;
}

extern "kernel32" fn ResetEvent(event: *anyopaque) callconv(.winapi) i32;

fn resetEvent(event: *anyopaque) void {
    _ = ResetEvent(event);
}

/// Report each FILE_NOTIFY_INFORMATION record in `data`.
fn reportChanges(w: *Watch, data: []const u8) void {
    var at: usize = 0;
    while (at + 12 <= data.len) {
        const next = std.mem.readInt(u32, data[at..][0..4], .little);
        const action = std.mem.readInt(u32, data[at + 4 ..][0..4], .little);
        const name_len = std.mem.readInt(u32, data[at + 8 ..][0..4], .little);
        const name_bytes = data[at + 12 .. @min(data.len, at + 12 + name_len)];
        var wide: [4096]u16 = undefined;
        const units = @min(name_bytes.len / 2, wide.len);
        for (0..units) |i| wide[i] = std.mem.readInt(u16, name_bytes[2 * i ..][0..2], .little);
        var utf8: [16384]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8, wide[0..units]) catch 0;
        const path = utf8[0..len];
        for (path) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        const kind: ?WatchKind = switch (action) {
            1, 5 => .created, // added, renamed to
            2, 4 => .deleted, // removed, renamed from
            3 => .modified,
            else => null,
        };
        if (kind) |k| if (len > 0) w.sink.report(w.sink.context, k, path);
        if (next == 0) break;
        at += next;
    }
}

/// Stop the watcher and free it.
pub fn stopWatch(w: *Watch) void {
    _ = SetEvent(w.stop_event);
    w.lock.lock();
    while (!w.done) w.done_cond.wait(&w.lock);
    w.lock.unlock();
    closeWatch(w);
}
