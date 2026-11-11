//! Concurrency on OS threads (DESIGN §13, M1.8 step 6, D-057), matching Phase 0
//! (host/src/runtime/concurrency.lisp and channels.lisp, D-037).
//!
//! A task runs on a cached pool of worker threads: a new thread starts whenever no worker
//! is idle, so a task that blocks never stops another from running. Idle workers exit
//! after 30 seconds.
//!
//! Cancellation is cooperative. The running code's cancellation scopes (its task, the
//! nurseries around it and with-timeout deadlines) are scope frames on the condition
//! frame chain (cond.zig), so a non-local exit drops them with everything else. Every
//! wait is a cancellation point, and so is check-cancelled.
//!
//! One lock and one wake-up condition serve every task, nursery and channel; waiters
//! wake at least every 20 ms to run main-thread work and check for cancellation. The
//! lock is only ever waited for inside `gc.blocking`, so a thread holding it may allocate
//! (and so collect) while others wait for it.

const std = @import("std");
const platform = @import("platform");
const rt = @import("rt.zig");
const gc = @import("gc.zig");
const coll = @import("coll.zig");
const cond = @import("cond.zig");
const func = @import("func.zig");
const num = @import("num.zig");
const names = @import("names.zig");
const print = @import("print.zig");
const stm = @import("stm.zig");
const seq = @import("seq.zig");
const hash = @import("hash.zig");
const sched = @import("sched.zig");
const wait = @import("wait.zig");
const dynamic = @import("dynamic.zig");
const Value = @import("value.zig").Value;

extern fn sk_try_call(f: Value, argc: u32, argv: [*]const Value, ntypes: u32, types: [*]Value) Value;

const tick_ns: u64 = 20 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------------------
// Objects

// A task: [fn, state, result, condition, cancel requested, nursery, scopes, hash, fiber,
// bindings].
const t_fn = 0;
const t_state = 1;
const t_result = 2;
const t_condition = 3;
const t_cancel = 4;
const t_nursery = 5;
const t_scopes = 6;
const t_hash = 7;
/// The fiber running the task (its address), so cancelling it can wake it; nil when it
/// isn't running.
const t_fiber = 8;
/// The dynamic bindings in force where it was spawned, which it starts with (D-076).
const t_bindings = 9;
/// Under :restart-fiber, the times (monotonic nanoseconds) it was restarted, or nil.
const t_restarts = 10;
/// With a task runner installed (skein dev), a nursery's task records the restarts active
/// in its spawner when it was spawned, as [restarts spawned-on-the-main-thread?], so its
/// debugger can offer them (D-101); nil otherwise.
const t_spawner_restarts = 11;
/// The spawner's restart chosen in the task's debugger, which its nursery invokes in the
/// spawner once its tasks have finished; nil if none was (D-101).
const t_chosen = 12;

const State = enum(i64) { pending, running, done, failed, cancelled };

// A nursery: [cancelled, failure (the first child's error) or nil, children, hash].
const n_cancelled = 0;
const n_failure = 1;
const n_children = 2;
const n_hash = 3;
/// The fiber running the nursery's body, if it runs in one: a failing child wakes it.
const n_owner = 4;
/// Its supervision policy (D-088): what a task's failure does.
const n_policy = 5;
/// Under :restart-fiber, how many restarts a task may have within n_within nanoseconds.
const n_max_restarts = 6;
const n_within = 7;
/// The first spawner's restart chosen in a child's debugger, invoked when the nursery ends.
const n_chosen = 8;

const Policy = enum(i64) { cancel_siblings, ignore, crash, restart_fiber };

// A channel: [capacity, items (vector), head (index of the next item), closed, takes,
// puts, takers waiting, hash].
const c_capacity = 0;
const c_items = 1;
const c_head = 2;
const c_closed = 3;
const c_takes = 4;
const c_puts = 5;
const c_takers = 6;
const c_hash = 7;

// A with-timeout deadline: [monotonic nanoseconds, seconds as given].
const d_time = 0;
const d_seconds = 1;

var identity_counter = std.atomic.Value(u32).init(0);

fn identity() Value {
    return Value.fromFixnum(hash.mix32(identity_counter.fetchAdd(1, .monotonic) +% 1));
}

fn get(v: Value, i: usize) Value {
    return coll.get(v, i);
}

fn set(v: Value, i: usize, x: Value) void {
    coll.set(v, i, x);
}

fn fx(n: usize) Value {
    return coll.fx(n);
}

fn ux(v: Value) usize {
    return coll.ux(v);
}

fn readable(v: Value) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    print.write(v, &buf, true);
    return buf.items;
}

pub fn isTask(v: Value) bool {
    return v.isObjectOf(.task);
}

pub fn isChan(v: Value) bool {
    return v.isObjectOf(.chan);
}

pub fn isNursery(v: Value) bool {
    return v.isObjectOf(.nursery);
}

/// The identity hash of a task, nursery or channel.
pub fn hashOf(v: Value) u32 {
    const i: usize = switch (v.toObject().type_id) {
        .task => t_hash,
        .nursery => n_hash,
        .chan => c_hash,
        else => unreachable,
    };
    return @intCast(get(v, i).toFixnum());
}

/// #<task done>, #<chan>, #<chan closed>, #<nursery>.
pub fn write(v: Value, out: *std.ArrayList(u8)) void {
    switch (v.toObject().type_id) {
        .task => {
            print.put(out, "#<task ");
            print.put(out, @tagName(stateOf(v)));
            print.put(out, ">");
        },
        .chan => print.put(out, if (get(v, c_closed) == Value.true) "#<chan closed>" else "#<chan>"),
        .nursery => print.put(out, "#<nursery>"),
        else => print.put(out, "#<object>"),
    }
}

fn checkTask(v: Value, comptime what: []const u8) void {
    if (!isTask(v)) rt.raise(.type_error, what ++ " needs a task, not {s}", .{readable(v)});
}

// ---------------------------------------------------------------------------------------
// The lock

var sched_lock: platform.Mutex = .{};

fn lock() void {
    // It's held briefly: try a few times before blocking (which lets collections go on,
    // but takes the GC's lock).
    for (0..64) |_| {
        if (sched_lock.tryLock()) return;
        std.atomic.spinLoopHint();
    }
    gc.blocking(lockBlocking, null);
}

fn lockBlocking(_: ?*anyopaque) void {
    sched_lock.lock();
}

fn unlock() void {
    sched_lock.unlock();
}

// Wait queue keys (wait.zig): what is waited for, by its identity number.
fn identityOf(v: Value, i: usize) u64 {
    return @intCast(get(v, i).toFixnum());
}
fn taskKey(t: Value) u64 {
    return (1 << 40) | identityOf(t, t_hash);
}
fn takeKey(ch: Value) u64 {
    return (2 << 40) | identityOf(ch, c_hash);
}
fn putKey(ch: Value) u64 {
    return (3 << 40) | identityOf(ch, c_hash);
}
/// The main thread waits under this too, so work queued for it wakes it.
const main_key: u64 = 4 << 40;

const max_keys = max_alts + 1;

fn now() u64 {
    return platform.monotonicNanos();
}

/// The monotonic time `seconds` (a non-negative number) from now.
fn nanosFromNow(seconds: Value) u64 {
    if (num.kind(seconds) == .other) rt.raise(.type_error, "a number of seconds is needed, not {s}", .{readable(seconds)});
    const s = @max(num.toF64(seconds), 0.0);
    const ns = @min(s * 1e9, 1e18);
    return now() + @as(u64, @intFromFloat(ns));
}

/// Wait until `ctx.ready()` (called with the lock held) is true, and return true with the
/// lock still held. Returns false, without the lock, if `deadline` passes first. A fiber
/// parks until something it waits for changes (`ctx.keys`), a deadline of its scopes
/// passes or it's cancelled; a thread that isn't a worker also wakes every 20 ms, and the
/// main thread runs the work queued for it. Before signaling a cancellation it calls
/// `ctx.abort()` (M2.3, D-075).
fn waitFor(ctx: anytype, deadline: ?u64) bool {
    while (true) {
        const scope_deadline = nearestScopeDeadline();
        lock();
        if (ctx.ready()) return true;
        if (deadline) |d| {
            if (now() >= d) {
                unlock();
                return false;
            }
        }
        var keys: [max_keys]u64 = undefined;
        var n = ctx.keys(keys[0..max_alts]);
        if (onMainThreadNow()) {
            keys[n] = main_key;
            n += 1;
        }
        // A cancellation sets its flag before it takes the lock to wake the waiter: so
        // either it's seen here, or it finds the waiter attached below.
        if (pendingCancellation()) |c| {
            unlock();
            ctx.abort();
            cond.signalError(c);
        }
        var primary = wait.Waiter.init();
        wait.attach(&primary);
        var stand_ins: [max_keys]wait.Waiter = undefined;
        for (keys[0..n], 0..) |k, i| {
            stand_ins[i] = wait.Waiter.standIn(&primary);
            wait.enqueue(k, &stand_ins[i]);
        }
        unlock();
        var until = deadline;
        if (scope_deadline) |d| until = if (until) |u| @min(u, d) else d;
        _ = wait.block(&primary, until, if (primary.fiber == null) tick_ns else null);
        for (stand_ins[0..n]) |*w| wait.remove(w);
        drainMainThread();
        if (pendingCancellation()) |c| {
            ctx.abort();
            cond.signalError(c);
        }
    }
}

/// The earliest with-timeout deadline of the running code's scopes, its inherited ones
/// included, or null.
fn nearestScopeDeadline() ?u64 {
    var best: ?u64 = null;
    var f = cond.topFrame();
    walk: while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(cond.Kind.scope)) continue;
        switch (fr.count) {
            scope_one => best = earlier(best, scopeDeadline(fr.value)),
            scope_list => {
                var it = seq.seq(fr.value);
                while (it != Value.nil) : (it = seq.seqNext(it)) best = earlier(best, scopeDeadline(seq.seqFirst(it)));
                break :walk;
            },
            else => break :walk,
        }
    }
    return best;
}

fn scopeDeadline(scope: Value) ?u64 {
    return if (scope.toObject().type_id == .deadline) ux(get(scope, d_time)) else null;
}

fn earlier(a: ?u64, b: ?u64) ?u64 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

// ---------------------------------------------------------------------------------------
// Cancellation scopes

/// How a scope frame's value is read (its `count`).
const scope_one = 0; // one scope: a task, nursery or deadline
const scope_list = 1; // a list of scopes, innermost first (a task's inherited ones)
const scope_barrier = 2; // no scopes from here out

fn pushScope(f: *cond.Frame, v: Value, how: u32) void {
    cond.pushFrame(f, .scope);
    f.value = v;
    f.count = how;
}

fn scopeCondition(scope: Value) ?Value {
    switch (scope.toObject().type_id) {
        .deadline => {
            if (now() < ux(get(scope, d_time))) return null;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(rt.scratch);
            print.put(&out, "timed out after ");
            print.write(get(scope, d_seconds), &out, false);
            print.put(&out, " seconds");
            return cond.makeBuiltin(.timeout, out.items);
        },
        .task => if (@atomicLoad(Value, &coll.slots(scope)[t_cancel], .acquire) == Value.nil) return null,
        .nursery => if (@atomicLoad(Value, &coll.slots(scope)[n_cancelled], .acquire) == Value.nil) return null,
        else => return null,
    }
    return cond.makeBuiltin(.cancelled, "the task was cancelled");
}

/// The condition a cancellation point would signal now, or null: cancelled if an
/// enclosing scope was cancelled, timeout if a with-timeout deadline has passed.
fn pendingCancellation() ?Value {
    var f = cond.topFrame();
    while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(cond.Kind.scope)) continue;
        switch (fr.count) {
            scope_one => if (scopeCondition(fr.value)) |c| return c,
            scope_list => {
                var s = seq.seq(fr.value);
                while (s != Value.nil) : (s = seq.seqNext(s)) {
                    if (scopeCondition(seq.seqFirst(s))) |c| return c;
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

/// A cancellation point.
pub fn checkCancelled() void {
    if (pendingCancellation()) |c| cond.signalError(c);
}

/// The running code's scopes as a list, innermost first (what a spawned task inherits).
fn currentScopes() Value {
    var buf: [256]Value = undefined;
    var n: usize = 0;
    var tail = coll.listOf(&.{});
    var f = cond.topFrame();
    walk: while (f) |fr| : (f = fr.prev) {
        if (fr.kind != @intFromEnum(cond.Kind.scope)) continue;
        switch (fr.count) {
            scope_one => {
                if (n == buf.len) rt.raise(.unsupported_operation_error, "more than {d} nested cancellation scopes", .{buf.len});
                buf[n] = fr.value;
                n += 1;
            },
            scope_list => {
                tail = fr.value;
                break :walk;
            },
            else => break :walk,
        }
    }
    var result = tail;
    while (n > 0) {
        n -= 1;
        result = coll.cons(buf[n], result);
    }
    return result;
}

// ---------------------------------------------------------------------------------------
// Tasks

fn makeTask(f: Value, nursery: Value, scopes: Value) Value {
    return coll.make(.task, &.{ f, Value.fromFixnum(@intFromEnum(State.pending)), Value.nil, Value.nil, Value.nil, nursery, scopes, identity(), Value.nil, dynamic.capture(), Value.nil, Value.nil, Value.nil });
}

fn stateOf(t: Value) State {
    return @enumFromInt(get(t, t_state).toFixnum());
}

fn isFinished(t: Value) bool {
    return switch (stateOf(t)) {
        .done, .failed, .cancelled => true,
        else => false,
    };
}

fn finishTask(t: Value, state: State, v: Value) void {
    // A failure is recorded in the nursery in the same step that marks the task
    // finished: a nursery joining its tasks must not see them all finished before it
    // sees the failure (it would return normally).
    const n = get(t, t_nursery);
    lock();
    set(t, t_state, Value.fromFixnum(@intFromEnum(state)));
    var first_failure = false;
    switch (state) {
        .done => set(t, t_result, v),
        .failed => {
            set(t, t_condition, v);
            const chosen = get(t, t_chosen);
            // Under :ignore a task fails alone, unless it failed for a restart of its
            // spawner, which the nursery invokes whatever its policy (D-101).
            if (n != Value.nil and (policyOf(t) != .ignore or chosen != Value.nil) and
                get(n, n_failure) == Value.nil)
            {
                set(n, n_failure, v);
                first_failure = true;
            }
            if (n != Value.nil and chosen != Value.nil and get(n, n_chosen) == Value.nil)
                set(n, n_chosen, chosen);
        },
        else => {},
    }
    set(t, t_fiber, Value.nil);
    wait.notifyAll(taskKey(t));
    unlock();
    // The first failure cancels the other tasks.
    if (first_failure) cancelNursery(n);
}

/// [the task runner]: nil, or a function that every task's function is called through,
/// (runner f task), in the task's fiber: skein.dev's, which gives an error that no handler
/// in the task handles to the debugger before the task fails (M2.8, D-088), and offers
/// the spawner's restarts there (D-101).
var task_runner: [1]Value = .{Value.nil};
var task_runner_ready = false;

fn installTaskRunner(f: Value) void {
    lock();
    defer unlock();
    if (!task_runner_ready) {
        gc.addRoots(&task_runner);
        task_runner_ready = true;
    }
    @atomicStore(Value, &task_runner[0], f, .release);
}

/// The body of every task: a cancellation point, then the task's function (through the
/// task runner, if one is installed).
fn taskBody(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    checkCancelled();
    const runner = @atomicLoad(Value, &task_runner[0], .acquire);
    if (runner != Value.nil) return func.call(runner, 2, argv);
    return func.call(argv[0], 0, argv);
}

/// Call `f` with `args`, catching conditions of `types` (handler-case style): returns
/// the index of the type caught (or -1 if `f` returned) and the condition or value.
fn tryCall(f: Value, args: []const Value, types: []const Value) struct { i64, Value } {
    var ts: [4]Value = undefined;
    @memcpy(ts[0..types.len], types);
    const r = sk_try_call(f, @intCast(args.len), args.ptr, @intCast(types.len), &ts);
    return .{ coll.vectorNth(r, 0).?.toFixnum(), coll.vectorNth(r, 1).? };
}

/// Run `t` on this thread, recording its result, error or cancellation.
fn runTask(t: Value) void {
    lock();
    if (stateOf(t) != .pending) {
        unlock();
        return;
    }
    set(t, t_state, Value.fromFixnum(@intFromEnum(State.running)));
    unlock();
    var inherited: cond.Frame = undefined;
    pushScope(&inherited, get(t, t_scopes), scope_list);
    var own: cond.Frame = undefined;
    pushScope(&own, t, scope_one);
    var bindings: cond.Frame = undefined;
    const bound = dynamic.pushCopy(&bindings, get(t, t_bindings));
    const types = [_]Value{ cond.builtinType(.cancelled), cond.builtinType(.@"error") };
    var r = tryCall(func.make(taskBody, "task"), &.{ get(t, t_fn), t }, &types);
    // :restart-fiber: run the function again from the start, while the limit allows; not
    // a task failed for a restart of its spawner (D-101).
    while (r[0] > 0 and get(t, t_chosen) == Value.nil and policyOf(t) == .restart_fiber and mayRestart(t)) {
        reportTaskError("error in task (restarting it): ", r[1]);
        r = tryCall(func.make(taskBody, "task"), &.{ get(t, t_fn), t }, &types);
    }
    if (bound) cond.popFrame(&bindings);
    cond.popFrame(&own);
    cond.popFrame(&inherited);
    switch (r[0]) {
        -1 => finishTask(t, .done, r[1]),
        0 => finishTask(t, .cancelled, Value.nil),
        else => {
            if (get(t, t_chosen) == Value.nil) {
                switch (policyOf(t)) {
                    .crash => cond.reportAndExit(r[1]),
                    .ignore => reportTaskError("error in task (ignored): ", r[1]),
                    else => {},
                }
            }
            finishTask(t, .failed, r[1]);
        },
    }
}

/// The policy of the nursery that owns `t` (a future has none: :cancel-siblings).
fn policyOf(t: Value) Policy {
    const n = get(t, t_nursery);
    if (n == Value.nil) return .cancel_siblings;
    return @enumFromInt(get(n, n_policy).toFixnum());
}

/// Under :restart-fiber: whether `t` may be restarted now, which counts as a restart.
fn mayRestart(t: Value) bool {
    const n = get(t, t_nursery);
    if (get(n, n_cancelled) != Value.nil) return false;
    const max = get(n, n_max_restarts).toFixnum();
    const within = get(n, n_within).toFixnum();
    const stamp: i64 = @intCast(platform.monotonicNanos());
    var recent = coll.vectorOf(&.{});
    const old = get(t, t_restarts);
    if (old != Value.nil) {
        for (0..coll.vectorCount(old)) |i| {
            const at = coll.vectorNth(old, i).?;
            if (stamp - at.toFixnum() < within) recent = coll.vectorConj(recent, at);
        }
    }
    if (@as(i64, @intCast(coll.vectorCount(recent))) >= max) return false;
    set(t, t_restarts, coll.vectorConj(recent, Value.fromFixnum(stamp)));
    return true;
}

/// A line on stderr about a task's error: prefix, then the error's report.
fn reportTaskError(prefix: []const u8, c: Value) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.scratch);
    print.put(&out, prefix);
    cond.writeReport(c, &out);
    print.put(&out, "\n");
    platform.writeStderr(out.items);
}

/// Ask `t` to stop at its next cancellation point. Returns true if it had not finished.
fn cancelTask(t: Value) bool {
    lock();
    defer unlock();
    // Whether it had finished when it was cancelled: decided before the flag is set, as
    // a task can see the flag and finish at once.
    const unfinished = !isFinished(t);
    @atomicStore(Value, &coll.slots(t)[t_cancel], Value.true, .release);
    // A parked task wakes to find its cancellation.
    interruptFiber(get(t, t_fiber));
    return unfinished;
}

/// Wake the fiber whose address `v` holds (nil: none), if it's blocked. With the lock
/// held, so it's still the fiber that the task or nursery runs in.
fn interruptFiber(v: Value) void {
    if (v == Value.nil) return;
    wait.interrupt(@ptrFromInt(@as(usize, @intCast(v.toFixnum()))));
}

fn fiberValue() Value {
    return if (sched.inFiber()) fx(@intFromPtr(sched.currentFiber())) else Value.nil;
}

// ---------------------------------------------------------------------------------------
// Promises and delays (M2.11, D-093): a promise is delivered once, and deref waits for it
// as for a task; a delay runs its body the first time it's dereferenced, while any other
// fiber that derefs it then waits, and keeps the value or the error.

const p_state = 0;
const p_value = 1;
const p_condition = 2;
const p_body = 3;
const p_hash = 4;
const p_owner = 5;
const p_pending = 0;
const p_running = 1;
const p_done = 2;
const p_failed = 3;

fn makePromise(t: @import("object.zig").TypeId, body: Value) Value {
    return coll.make(t, &.{ fx(p_pending), Value.nil, Value.nil, body, identity(), Value.nil });
}

fn promiseKey(p: Value) u64 {
    return (5 << 40) | identityOf(p, p_hash);
}

fn promiseState(p: Value) usize {
    return ux(get(p, p_state));
}

pub fn isPromiseLike(v: Value) bool {
    return v.isObjectOf(.promise) or v.isObjectOf(.delay);
}

/// realized? of a promise or delay: delivered, or the body has run.
pub fn promiseRealized(p: Value) bool {
    lock();
    defer unlock();
    return promiseState(p) >= p_done;
}

/// #<promise pending>, #<delay done 42>.
pub fn writePromise(v: Value, out: *std.ArrayList(u8)) void {
    print.put(out, if (v.isObjectOf(.promise)) "#<promise " else "#<delay ");
    lock();
    const state = promiseState(v);
    const value = get(v, p_value);
    unlock();
    print.put(out, switch (state) {
        p_pending => "pending",
        p_running => "running",
        p_done => "done ",
        else => "failed",
    });
    if (state == p_done) print.write(value, out, true);
    print.put(out, ">");
}

pub fn promiseHash(v: Value) u32 {
    return @intCast(get(v, p_hash).toFixnum());
}

/// (deliver p x): give p its value, waking what waits for it; p, or nil if it was
/// delivered already.
fn deliver(p: Value, x: Value) Value {
    if (!p.isObjectOf(.promise)) rt.raise(.type_error, "deliver needs a promise, not {s}", .{readable(p)});
    lock();
    defer unlock();
    if (promiseState(p) != p_pending) return Value.nil;
    set(p, p_value, x);
    set(p, p_state, fx(p_done));
    wait.notifyAll(promiseKey(p));
    return p;
}

const PromiseWait = struct {
    p: Value,
    fn ready(w: *const PromiseWait) bool {
        return promiseState(w.p) >= p_done;
    }
    fn keys(w: *const PromiseWait, out: []u64) usize {
        out[0] = promiseKey(w.p);
        return 1;
    }
    fn abort(_: *const PromiseWait) void {}
};

/// Who runs code here: the fiber, or on another thread the thread.
fn runnerId() Value {
    if (sched.inFiber()) return fiberValue();
    // A thread id is 32 bits on Windows, 64 elsewhere.
    const id: u64 = @intCast(std.Thread.getCurrentId());
    return Value.fromFixnum(-@as(i64, @intCast(id & 0xffffffffffff)) - 1);
}

/// deref of a promise or a delay: (deref p) or (deref p seconds timeout-value).
pub fn derefPromise(a: []const Value) Value {
    const p = a[0];
    const deadline: ?u64 = if (a.len >= 2) nanosFromNow(a[1]) else null;
    if (p.isObjectOf(.delay)) {
        lock();
        if (promiseState(p) == p_pending) {
            set(p, p_state, fx(p_running));
            set(p, p_owner, runnerId());
            unlock();
            runDelay(p);
        } else {
            const mine = promiseState(p) == p_running and get(p, p_owner) == runnerId();
            unlock();
            if (mine) rt.raise(.@"error", "a delay's body dereferenced the delay", .{});
        }
    }
    const w: PromiseWait = .{ .p = p };
    if (!waitFor(&w, deadline)) return if (a.len >= 3) a[2] else Value.nil;
    const state = promiseState(p);
    const value = get(p, p_value);
    const c = get(p, p_condition);
    unlock();
    if (state == p_failed) cond.signalError(c);
    return value;
}

/// Run a delay's body here, recording its value or its error. Cancelled, it is pending
/// again, so the next deref runs it.
fn runDelay(p: Value) void {
    const types = [_]Value{ cond.builtinType(.cancelled), cond.builtinType(.@"error") };
    const r = tryCall(get(p, p_body), &.{}, &types);
    lock();
    switch (r[0]) {
        -1 => {
            set(p, p_value, r[1]);
            set(p, p_state, fx(p_done));
            set(p, p_body, Value.nil);
        },
        0 => set(p, p_state, fx(p_pending)),
        else => {
            set(p, p_condition, r[1]);
            set(p, p_state, fx(p_failed));
            set(p, p_body, Value.nil);
        },
    }
    set(p, p_owner, Value.nil);
    wait.notifyAll(promiseKey(p));
    unlock();
    if (r[0] == 0) cond.signalError(r[1]);
}

const FinishedWait = struct {
    t: Value,
    fn ready(w: *const FinishedWait) bool {
        return isFinished(w.t);
    }
    fn keys(w: *const FinishedWait, out: []u64) usize {
        out[0] = taskKey(w.t);
        return 1;
    }
    fn abort(_: *const FinishedWait) void {}
};

/// Wait for `t` to finish; return its value, re-signal its error or signal
/// task-cancelled-error. Returns null if `deadline` passes first.
fn awaitTask(t: Value, deadline: ?u64) ?Value {
    const w: FinishedWait = .{ .t = t };
    if (!waitFor(&w, deadline)) return null;
    const state = stateOf(t);
    const result = get(t, t_result);
    const c = get(t, t_condition);
    const chosen = get(t, t_chosen);
    unlock();
    return switch (state) {
        .done => result,
        // Failed for a restart of its spawner: its nursery is being cancelled, and invokes
        // the restart once it ends; a second debugger here would be in the way (D-101).
        .failed => if (chosen != Value.nil)
            cond.signalError(cond.makeBuiltin(.cancelled, "the task was failed for a restart of its spawner"))
        else
            cond.signalError(c),
        else => rt.raise(.task_cancelled_error, "the task was cancelled", .{}),
    };
}

// ---------------------------------------------------------------------------------------
// Waiting for something else (process.zig's exits, D-103)

const KeyWait = struct {
    key: u64,
    ready_fn: *const fn (?*anyopaque) bool,
    arg: ?*anyopaque,
    fn ready(w: *const KeyWait) bool {
        return w.ready_fn(w.arg);
    }
    fn keys(w: *const KeyWait, out: []u64) usize {
        out[0] = w.key;
        return 1;
    }
    fn abort(_: *const KeyWait) void {}
};

/// Wait until `ready_fn(arg)` (asked under the scheduler's lock) is true, parking a fiber
/// rather than its worker, at most `seconds` (nil: no limit); true if it became ready.
/// Whatever makes it ready calls `notifyFromAnyThread(key)` afterwards. Cancellation
/// points apply, as in any wait.
pub fn waitForKey(key: u64, ready_fn: *const fn (?*anyopaque) bool, arg: ?*anyopaque, seconds: Value) bool {
    const w: KeyWait = .{ .key = key, .ready_fn = ready_fn, .arg = arg };
    const deadline: ?u64 = if (seconds == Value.nil) null else nanosFromNow(seconds);
    if (!waitFor(&w, deadline)) return false;
    unlock();
    return true;
}

/// Wake the waiters of `key`, from any thread, including one the runtime doesn't know
/// (which mustn't take the lock through gc.blocking).
pub fn notifyFromAnyThread(key: u64) void {
    sched_lock.lock();
    wait.notifyAll(key);
    sched_lock.unlock();
}

/// deref of a task: (deref task) or (deref task seconds timeout-value).
pub fn deref(a: []const Value) Value {
    const deadline: ?u64 = if (a.len >= 2) nanosFromNow(a[1]) else null;
    return awaitTask(a[0], deadline) orelse (if (a.len >= 3) a[2] else Value.nil);
}

// ---------------------------------------------------------------------------------------
// The worker pool and the main thread's queue

// GC roots: the queue of tasks waiting for a fiber, and the main thread's queue, each a
// vector and the index of its next task.
var roots: [4]Value = @splat(Value.nil);
const start_queue = 0;
const main_queue = 2;
threadlocal var is_main = false;

/// Whether this is the main thread (where sk_init ran). Not inlined (D-075).
pub noinline fn onMainThreadNow() bool {
    return is_main;
}

/// Set up the queues. sk_init calls this on the main thread.
pub fn init() void {
    roots = .{ coll.vectorOf(&.{}), fx(0), coll.vectorOf(&.{}), fx(0) };
    gc.addRoots(&roots);
    is_main = true;
}

// These run with the lock held.

fn queued(q: usize) usize {
    return coll.vectorCount(roots[q]) - ux(roots[q + 1]);
}

fn enqueue(q: usize, t: Value) void {
    roots[q] = coll.vectorConj(roots[q], t);
}

fn dequeue(q: usize) ?Value {
    const head = ux(roots[q + 1]);
    const n = coll.vectorCount(roots[q]);
    if (head >= n) return null;
    const t = coll.vectorNth(roots[q], head).?;
    if (head + 1 == n) {
        roots[q] = coll.vectorOf(&.{});
        roots[q + 1] = fx(0);
    } else {
        roots[q + 1] = fx(head + 1);
    }
    return t;
}

/// A fiber's job: run the next task waiting for one (the queue keeps tasks reachable
/// until a fiber has them).
fn startJob(_: ?*anyopaque) void {
    lock();
    const t = dequeue(start_queue).?;
    if (stateOf(t) == .pending) set(t, t_fiber, fiberValue());
    unlock();
    runTask(t);
}

/// Run `t` in a fiber of its own (M2.3, D-075).
fn submit(t: Value) Value {
    lock();
    enqueue(start_queue, t);
    unlock();
    sched.spawn(startJob, null);
    return t;
}

/// Run the work queued for the main thread. Does nothing on other threads.
pub fn drainMainThread() void {
    if (!onMainThreadNow()) return;
    while (true) {
        lock();
        const t = dequeue(main_queue);
        unlock();
        runTask(t orelse return);
    }
}

fn queueForMain(f: Value) Value {
    const t = makeTask(f, Value.nil, coll.listOf(&.{}));
    lock();
    enqueue(main_queue, t);
    wait.notifyAll(main_key);
    unlock();
    return t;
}

// ---------------------------------------------------------------------------------------
// Nurseries (structured concurrency)

fn cancelNursery(n: Value) void {
    @atomicStore(Value, &coll.slots(n)[n_cancelled], Value.true, .release);
    lock();
    const children = get(n, n_children);
    // The code waiting in the nursery's body, if parked, wakes to find it.
    interruptFiber(get(n, n_owner));
    unlock();
    for (0..coll.vectorCount(children)) |i| _ = cancelTask(coll.vectorNth(children, i).?);
}

/// spawn: start `f` as a task owned by the nursery `n`.
fn spawnIn(n: Value, f: Value) Value {
    if (!isNursery(n)) rt.raise(.@"error", "spawn needs a nursery, not {s}", .{readable(n)});
    const t = makeTask(f, n, currentScopes());
    // For the task's debugger (D-101): only skein dev installs a task runner.
    if (@atomicLoad(Value, &task_runner[0], .acquire) != Value.nil)
        set(t, t_spawner_restarts, coll.vectorOf(&.{ cond.computeRestarts(), Value.fromBool(onMainThreadNow()) }));
    lock();
    set(n, n_children, coll.vectorConj(get(n, n_children), t));
    unlock();
    if (get(n, n_cancelled) != Value.nil) _ = cancelTask(t);
    return submit(t);
}

fn firstUnfinished(n: Value) ?Value {
    lock();
    defer unlock();
    const children = get(n, n_children);
    for (0..coll.vectorCount(children)) |i| {
        const t = coll.vectorNth(children, i).?;
        if (!isFinished(t)) return t;
    }
    return null;
}

fn awaitFinished(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = self;
    _ = argc;
    const w: FinishedWait = .{ .t = argv[0] };
    _ = waitFor(&w, null);
    unlock();
    return Value.nil;
}

/// Wait until every task of `n` has finished. If the waiting code is cancelled or times
/// out meanwhile, cancel the tasks and keep waiting for them without further cancellation
/// checks; then return that interruption (a condition), or nil.
fn joinNursery(n: Value) Value {
    var interruption = Value.nil;
    while (firstUnfinished(n)) |child| {
        if (interruption != Value.nil) {
            var barrier: cond.Frame = undefined;
            pushScope(&barrier, Value.nil, scope_barrier);
            _ = awaitFinished(Value.nil, 1, &.{child});
            cond.popFrame(&barrier);
        } else {
            const r = tryCall(func.make(awaitFinished, "join"), &.{child}, &.{ cond.builtinType(.cancelled), cond.builtinType(.timeout) });
            if (r[0] >= 0) {
                cancelNursery(n);
                interruption = r[1];
            }
        }
    }
    return interruption;
}

/// [policy max-restarts within-nanoseconds] from with-nursery's options (nil or a map with
/// :on-error, :max-restarts and :within, D-088).
fn nurseryOptions(opts: Value) [3]Value {
    var policy: Policy = .cancel_siblings;
    var max: i64 = 3;
    var within: f64 = 5.0;
    if (opts != Value.nil) {
        if (!coll.isMap(opts)) rt.raise(.@"error", "with-nursery's options must be a map, not {s}", .{readable(opts)});
        var known: usize = 0;
        if (coll.mapGet(opts, names.keyword(null, "on-error"))) |p| {
            known += 1;
            policy = policyNamed(p);
        }
        if (coll.mapGet(opts, names.keyword(null, "max-restarts"))) |m| {
            known += 1;
            if (!m.isFixnum() or m.toFixnum() < 0) rt.raise(.@"error", "with-nursery's :max-restarts must be a count, not {s}", .{readable(m)});
            max = m.toFixnum();
        }
        if (coll.mapGet(opts, names.keyword(null, "within"))) |w| {
            known += 1;
            if (!num.isNumber(w) or !(num.toF64(w) > 0)) rt.raise(.@"error", "with-nursery's :within must be a number of seconds, not {s}", .{readable(w)});
            within = num.toF64(w);
        }
        if (known != coll.mapCount(opts)) rt.raise(.@"error", "with-nursery's options are :on-error, :max-restarts and :within, not {s}", .{readable(opts)});
    }
    return .{ Value.fromFixnum(@intFromEnum(policy)), Value.fromFixnum(max), Value.fromFixnum(@intFromFloat(@min(within, 1e9) * 1e9)) };
}

fn policyNamed(p: Value) Policy {
    if (names.isKeyword(p) and names.nsOf(p) == null) {
        const nm = names.nameOf(p);
        if (std.mem.eql(u8, nm, "cancel-siblings")) return .cancel_siblings;
        if (std.mem.eql(u8, nm, "ignore")) return .ignore;
        if (std.mem.eql(u8, nm, "crash")) return .crash;
        if (std.mem.eql(u8, nm, "restart-fiber")) return .restart_fiber;
    }
    rt.raise(.@"error", "with-nursery's :on-error must be :cancel-siblings, :ignore, :crash or :restart-fiber, not {s}", .{readable(p)});
}

/// with-nursery: run (body nursery) and wait for all its tasks. If one fails, cancel the
/// others and the body, then re-signal that failure; if the body fails, cancel the tasks
/// and re-signal its error.
fn withNursery(opts: Value, body: Value) Value {
    const policy = nurseryOptions(opts);
    const n = coll.make(.nursery, &.{ Value.nil, Value.nil, coll.vectorOf(&.{}), identity(), fiberValue(), policy[0], policy[1], policy[2], Value.nil });
    var frame: cond.Frame = undefined;
    pushScope(&frame, n, scope_one);
    const r = tryCall(body, &.{n}, &.{ cond.builtinType(.cancelled), cond.builtinType(.@"error") });
    cond.popFrame(&frame);
    var problem = Value.nil;
    switch (r[0]) {
        -1 => {},
        0 => problem = r[1],
        else => {
            problem = r[1];
            cancelNursery(n);
        },
    }
    const interruption = joinNursery(n);
    if (problem == Value.nil) problem = interruption;
    lock();
    const failure = get(n, n_failure);
    const chosen = get(n, n_chosen);
    set(n, n_owner, Value.nil);
    unlock();
    // A child failed for a restart of this fiber's, chosen in its debugger: invoke it now
    // that every task has finished, if it's still active (D-101).
    if (chosen != Value.nil and cond.findRestart(chosen) != Value.nil)
        return cond.invokeRestart(chosen, &.{});
    if (failure != Value.nil) cond.signalError(failure);
    if (problem != Value.nil) cond.signalError(problem);
    return r[1];
}

// ---------------------------------------------------------------------------------------
// Sleep, timeouts and the main thread

const Never = struct {
    fn ready(_: *const Never) bool {
        return false;
    }
    fn keys(_: *const Never, _: []u64) usize {
        return 0;
    }
    fn abort(_: *const Never) void {}
};

fn sleep(seconds: Value) void {
    stm.forbidInTransaction("sleep");
    const ok = switch (num.kind(seconds)) {
        .other => false,
        else => (num.compare("sleep", seconds, Value.fromFixnum(0)) orelse .lt) != .lt,
    };
    if (!ok) rt.raise(.@"error", "sleep needs a non-negative number of seconds, not {s}", .{readable(seconds)});
    const w: Never = .{};
    _ = waitFor(&w, nanosFromNow(seconds));
}

fn withTimeout(seconds: Value, body: Value) Value {
    const d = coll.make(.deadline, &.{ fx(nanosFromNow(seconds)), seconds });
    var frame: cond.Frame = undefined;
    pushScope(&frame, d, scope_one);
    const v = func.call(body, 0, &.{});
    cond.popFrame(&frame);
    return v;
}

fn onMainThread(f: Value) Value {
    stm.forbidInTransaction("on-main-thread");
    if (!sched.inFiber()) return func.call(f, 0, &.{});
    return awaitTask(queueForMain(f), null).?;
}

fn spawnPinned(where: Value, f: Value) Value {
    const main = names.isKeyword(where) and names.nsOf(where) == null and std.mem.eql(u8, names.nameOf(where), "main");
    if (!main) rt.raise(.@"error", "spawn-pinned supports only :main, not {s}", .{readable(where)});
    return queueForMain(f);
}

// ---------------------------------------------------------------------------------------
// Channels. All of them share the lock; every wait is a cancellation point.

fn makeChan(capacity: Value) Value {
    if (!capacity.isFixnum() or capacity.toFixnum() < 0)
        rt.raise(.@"error", "chan needs a non-negative buffer size, not {s}", .{readable(capacity)});
    return coll.make(.chan, &.{ capacity, coll.vectorOf(&.{}), fx(0), Value.nil, fx(0), fx(0), fx(0), identity() });
}

fn checkChan(x: Value, comptime what: []const u8) void {
    if (!isChan(x)) coll.unsupported(what ++ " needs a channel, not {s}", .{readable(x)});
}

// These run with the lock held.

fn itemCount(ch: Value) usize {
    return coll.vectorCount(get(ch, c_items)) - ux(get(ch, c_head));
}

fn isClosed(ch: Value) bool {
    return get(ch, c_closed) != Value.nil;
}

fn takeReady(ch: Value) bool {
    return itemCount(ch) > 0 or isClosed(ch);
}

/// Take a value (nil if the channel is closed and empty).
fn takeNow(ch: Value) Value {
    if (itemCount(ch) == 0) return Value.nil;
    const items = get(ch, c_items);
    const head = ux(get(ch, c_head));
    const v = coll.vectorNth(items, head).?;
    if (head + 1 == coll.vectorCount(items)) {
        set(ch, c_items, coll.vectorOf(&.{}));
        set(ch, c_head, fx(0));
    } else {
        set(ch, c_head, fx(head + 1));
    }
    set(ch, c_takes, fx(ux(get(ch, c_takes)) + 1));
    // Buffer space, or a taken unbuffered value: the putters look again.
    wait.notifyAll(putKey(ch));
    return v;
}

fn putReady(ch: Value) bool {
    if (isClosed(ch)) return true;
    const capacity = ux(get(ch, c_capacity));
    return if (capacity == 0) ux(get(ch, c_takers)) > itemCount(ch) else itemCount(ch) < capacity;
}

/// Put `v`; return its ticket, or null if the channel is closed.
fn putNow(ch: Value, v: Value) ?usize {
    if (isClosed(ch)) return null;
    set(ch, c_items, coll.vectorConj(get(ch, c_items), v));
    wait.notifyAll(takeKey(ch));
    const ticket = ux(get(ch, c_puts)) + 1;
    set(ch, c_puts, fx(ticket));
    return ticket;
}

/// >!: put `v` on `ch`, waiting for buffer space (or, unbuffered, for a taker). Returns
/// true, or false if `ch` is closed.
fn chanPut(ch: Value, v: Value) Value {
    stm.forbidInTransaction("a channel put (>!)");
    checkChan(ch, ">!");
    if (v == Value.nil) rt.raise(.@"error", "cannot put nil on a channel", .{});
    const Space = struct {
        ch: Value,
        fn ready(w: *const @This()) bool {
            const capacity = ux(get(w.ch, c_capacity));
            return isClosed(w.ch) or capacity == 0 or itemCount(w.ch) < capacity;
        }
        fn keys(w: *const @This(), out: []u64) usize {
            out[0] = putKey(w.ch);
            return 1;
        }
        fn abort(_: *const @This()) void {}
    };
    const space: Space = .{ .ch = ch };
    _ = waitFor(&space, null);
    const ticket = putNow(ch, v);
    const capacity = ux(get(ch, c_capacity));
    unlock();
    const t = ticket orelse return Value.false;
    if (capacity > 0) return Value.true;
    // Unbuffered: wait until the value has been taken.
    const Taken = struct {
        ch: Value,
        ticket: usize,
        fn ready(w: *const @This()) bool {
            return ux(get(w.ch, c_takes)) >= w.ticket or isClosed(w.ch);
        }
        fn keys(w: *const @This(), out: []u64) usize {
            out[0] = putKey(w.ch);
            return 1;
        }
        fn abort(_: *const @This()) void {}
    };
    const taken: Taken = .{ .ch = ch, .ticket = t };
    _ = waitFor(&taken, null);
    const done = ux(get(ch, c_takes)) >= t;
    unlock();
    return Value.fromBool(done);
}

/// <!: take a value from `ch`, waiting for one. Returns nil once `ch` is closed and
/// empty.
fn chanTake(ch: Value) Value {
    stm.forbidInTransaction("a channel take (<!)");
    checkChan(ch, "<!");
    lock();
    set(ch, c_takers, fx(ux(get(ch, c_takers)) + 1));
    // An unbuffered put waits for a taker.
    wait.notifyAll(putKey(ch));
    unlock();
    const Ready = struct {
        ch: Value,
        fn ready(w: *const @This()) bool {
            return takeReady(w.ch);
        }
        fn keys(w: *const @This(), out: []u64) usize {
            out[0] = takeKey(w.ch);
            return 1;
        }
        fn abort(w: *const @This()) void {
            lock();
            set(w.ch, c_takers, fx(ux(get(w.ch, c_takers)) - 1));
            unlock();
        }
    };
    const r: Ready = .{ .ch = ch };
    _ = waitFor(&r, null);
    const v = takeNow(ch);
    set(ch, c_takers, fx(ux(get(ch, c_takers)) - 1));
    unlock();
    return v;
}

/// close!: puts fail from now on, and takes return nil once the channel is empty.
fn chanClose(ch: Value) Value {
    checkChan(ch, "close!");
    lock();
    set(ch, c_closed, Value.true);
    wait.notifyAll(takeKey(ch));
    wait.notifyAll(putKey(ch));
    unlock();
    return Value.nil;
}

threadlocal var prng: ?std.Random.DefaultPrng = null;

fn random() std.Random {
    if (prng == null) prng = std.Random.DefaultPrng.init(now() ^ @intFromPtr(&prng));
    return prng.?.random();
}

const max_alts = 64;

const Op = struct { ch: Value, value: Value, put: bool };

/// alts!: perform the first ready operation among `ops`: a channel to take from, or
/// [channel value] to put. Returns [value channel]; for a put, the value is true, or
/// false if the channel was closed.
fn alts(ops_coll: Value) Value {
    stm.forbidInTransaction("alts!");
    var ops: [max_alts]Op = undefined;
    var n: usize = 0;
    var s = seq.seq(ops_coll);
    while (s != Value.nil) : (s = seq.seqNext(s)) {
        const op = seq.seqFirst(s);
        if (n == max_alts) coll.unsupported("alts! with more than {d} operations", .{max_alts});
        if (isChan(op)) {
            ops[n] = .{ .ch = op, .value = Value.nil, .put = false };
        } else if (coll.isVector(op) and coll.vectorCount(op) == 2 and isChan(coll.vectorNth(op, 0).?)) {
            ops[n] = .{ .ch = coll.vectorNth(op, 0).?, .value = coll.vectorNth(op, 1).?, .put = true };
        } else {
            coll.unsupported("alts! needs channels or [channel value] puts, not {s}", .{readable(op)});
        }
        n += 1;
    }
    if (n == 0) coll.unsupported("alts! needs at least one operation", .{});
    const Any = struct {
        ops: []Op,
        chosen: usize = 0,
        fn ready(w: *@This()) bool {
            // Try the operations in a random order, so that no channel is favored.
            random().shuffle(Op, w.ops);
            for (w.ops, 0..) |op, i| {
                if (if (op.put) putReady(op.ch) else takeReady(op.ch)) {
                    w.chosen = i;
                    return true;
                }
            }
            return false;
        }
        fn keys(w: *@This(), out: []u64) usize {
            for (w.ops, 0..) |op, i| out[i] = if (op.put) putKey(op.ch) else takeKey(op.ch);
            return w.ops.len;
        }
        fn abort(_: *@This()) void {}
    };
    var w: Any = .{ .ops = ops[0..n] };
    _ = waitFor(&w, null);
    const op = w.ops[w.chosen];
    const v = if (op.put) Value.fromBool(putNow(op.ch, op.value) != null) else takeNow(op.ch);
    unlock();
    return coll.vectorOf(&.{ v, op.ch });
}

fn timeoutChanBody(self: Value, argc: u32, argv: [*]const Value) callconv(.c) Value {
    _ = argc;
    _ = argv;
    sleep(func.capturedOf(self, 1));
    return chanClose(func.capturedOf(self, 0));
}

/// timeout-chan: a channel that closes after `seconds`.
fn timeoutChan(seconds: Value) Value {
    const ch = makeChan(fx(0));
    _ = submit(makeTask(func.closure(timeoutChanBody, "timeout-chan", &.{ ch, seconds }), Value.nil, coll.listOf(&.{})));
    return ch;
}

// ---------------------------------------------------------------------------------------
// skein.core functions (core.zig's table includes these)

const Args = []const Value;

pub const Entry = struct {
    name: []const u8,
    min: u32,
    max: ?u32,
    impl: *const fn (Args) Value,
};

fn e(name: []const u8, min: u32, max: ?u32, impl: *const fn (Args) Value) Entry {
    return .{ .name = name, .min = min, .max = max, .impl = impl };
}

pub const entries = [_]Entry{
    e("promise", 0, 0, struct {
        fn f(_: Args) Value {
            return makePromise(.promise, Value.nil);
        }
    }.f),
    e("deliver", 2, 2, struct {
        fn f(a: Args) Value {
            return deliver(a[0], a[1]);
        }
    }.f),
    // (%delay f): a delay of the body f (the delay macro).
    e("%delay", 1, 1, struct {
        fn f(a: Args) Value {
            if (!a[0].isObjectOf(.function)) rt.raise(.type_error, "%delay needs a function", .{});
            return makePromise(.delay, a[0]);
        }
    }.f),
    e("delay?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(a[0].isObjectOf(.delay));
        }
    }.f),
    // (%task-spawner-restarts task): [restarts main-thread?] of the task's spawner when it
    // was spawned, or nil (D-101).
    e("%task-spawner-restarts", 1, 1, struct {
        fn f(a: Args) Value {
            if (!isTask(a[0])) rt.raise(.type_error, "%task-spawner-restarts needs a task, not {s}", .{readable(a[0])});
            return get(a[0], t_spawner_restarts);
        }
    }.f),
    // (%choose-spawner-restart! task restart): the task is failing so that its nursery
    // invokes restart, one of its spawner's, in the spawner (D-101).
    e("%choose-spawner-restart!", 2, 2, struct {
        fn f(a: Args) Value {
            if (!isTask(a[0])) rt.raise(.type_error, "%choose-spawner-restart! needs a task, not {s}", .{readable(a[0])});
            if (!cond.isRestart(a[1])) rt.raise(.type_error, "%choose-spawner-restart! needs a restart, not {s}", .{readable(a[1])});
            lock();
            set(a[0], t_chosen, a[1]);
            unlock();
            return Value.nil;
        }
    }.f),
    // (%install-task-runner! f): call every task's function as (f task-fn task) (D-088).
    e("%install-task-runner!", 1, 1, struct {
        fn f(a: Args) Value {
            installTaskRunner(a[0]);
            return Value.nil;
        }
    }.f),
    // (%with-nursery body) or (%with-nursery options body)
    e("%with-nursery", 1, 2, struct {
        fn f(a: Args) Value {
            return if (a.len == 2) withNursery(a[0], a[1]) else withNursery(Value.nil, a[0]);
        }
    }.f),
    e("%spawn", 2, 2, struct {
        fn f(a: Args) Value {
            return spawnIn(a[0], a[1]);
        }
    }.f),
    e("%future", 1, 1, struct {
        fn f(a: Args) Value {
            return submit(makeTask(a[0], Value.nil, coll.listOf(&.{})));
        }
    }.f),
    e("%with-timeout", 2, 2, struct {
        fn f(a: Args) Value {
            return withTimeout(a[0], a[1]);
        }
    }.f),
    e("%on-main-thread", 1, 1, struct {
        fn f(a: Args) Value {
            return onMainThread(a[0]);
        }
    }.f),
    e("%spawn-pinned", 2, 2, struct {
        fn f(a: Args) Value {
            return spawnPinned(a[0], a[1]);
        }
    }.f),
    e("drain-main-thread!", 0, 0, struct {
        fn f(_: Args) Value {
            drainMainThread();
            return Value.nil;
        }
    }.f),
    e("check-cancelled", 0, 0, struct {
        fn f(_: Args) Value {
            checkCancelled();
            return Value.nil;
        }
    }.f),
    e("sleep", 1, 1, struct {
        fn f(a: Args) Value {
            sleep(a[0]);
            return Value.nil;
        }
    }.f),
    e("cancel!", 1, 1, struct {
        fn f(a: Args) Value {
            checkTask(a[0], "cancel!");
            return Value.fromBool(cancelTask(a[0]));
        }
    }.f),
    e("cancelled?", 1, 1, struct {
        fn f(a: Args) Value {
            checkTask(a[0], "cancelled?");
            lock();
            defer unlock();
            return Value.fromBool(stateOf(a[0]) == .cancelled);
        }
    }.f),
    e("done?", 1, 1, struct {
        fn f(a: Args) Value {
            checkTask(a[0], "done?");
            lock();
            defer unlock();
            return Value.fromBool(isFinished(a[0]));
        }
    }.f),
    e("task?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(isTask(a[0]));
        }
    }.f),
    e("cpu-count", 0, 0, struct {
        fn f(_: Args) Value {
            return fx(platform.cpuCount());
        }
    }.f),
    e("chan", 0, 1, struct {
        fn f(a: Args) Value {
            return makeChan(if (a.len == 1) a[0] else fx(0));
        }
    }.f),
    e("chan?", 1, 1, struct {
        fn f(a: Args) Value {
            return Value.fromBool(isChan(a[0]));
        }
    }.f),
    e(">!", 2, 2, struct {
        fn f(a: Args) Value {
            return chanPut(a[0], a[1]);
        }
    }.f),
    e("<!", 1, 1, struct {
        fn f(a: Args) Value {
            return chanTake(a[0]);
        }
    }.f),
    e("close!", 1, 1, struct {
        fn f(a: Args) Value {
            return chanClose(a[0]);
        }
    }.f),
    e("alts!", 1, 1, struct {
        fn f(a: Args) Value {
            return alts(a[0]);
        }
    }.f),
    e("timeout-chan", 1, 1, struct {
        fn f(a: Args) Value {
            return timeoutChan(a[0]);
        }
    }.f),
};
