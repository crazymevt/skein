/* The parts of the condition system that need setjmp and longjmp, which Zig can't call
 * safely (D-047), and the multiple-values registers (D-053), which are C thread-locals.
 * Compiled into the runtime library by build.zig.
 *
 * On Windows (x86_64-windows-gnu) mingw's longjmp unwinds through RtlUnwindEx, so it
 * walks the SEH unwind tables of every frame it crosses: Skein's C, the runtime's Zig and
 * any C library in between. */

#include "skein.h"
#include <string.h>

/* Jump to frame f, whose setjmp then returns 1. */
_Noreturn void sk_jump(sk_frame *f) {
    SK_LONGJMP(f->jb);
}

sk_value sk_muffle_warning_name(void);
void sk_signal_condition(sk_value condition);
void sk_report_warning(sk_value condition);

/* warn: signal the condition with a muffle-warning restart established; if no handler
 * invokes it, print the warning. */
void sk_warn_condition(sk_value condition) {
    sk_frame f;
    sk_value names[1] = {sk_muffle_warning_name()};
    const sk_value fns[1] = {SK_NIL}; /* nil: invoking the restart returns to this frame */
    const sk_value reports[1] = {SK_NIL};
    sk_frame_push_restarts(&f, 1, names, fns, reports);
    if (SK_SETJMP(f.jb) == 0) {
        sk_signal_condition(condition);
        sk_frame_pop(&f);
        sk_report_warning(condition);
    } else {
        sk_frame_pop(&f);
    }
}

/* Multiple values: see skein.h. */
static _Thread_local int32_t mv_count = SK_MV_SINGLE;
static _Thread_local sk_value mv_values[SK_MV_MAX];

/* Not inlined, so every use finds the running thread's registers (skein.h). */
__attribute__((noinline)) int32_t *sk_mv_count_address(void) { return &mv_count; }
__attribute__((noinline)) sk_value *sk_mv_values_address(void) { return mv_values; }

_Noreturn void sk_too_many_values(uint32_t count);

/* (values ...) in a position whose values matter: store them; return the first, or nil. */
sk_value sk_mv_set(uint32_t count, const sk_value *values) {
    if (count > SK_MV_MAX) sk_too_many_values(count);
    for (uint32_t i = 0; i < count; i++) sk_mv_values[i] = values[i];
    sk_mv_count = (int32_t)count;
    return count > 0 ? values[0] : SK_NIL;
}

/* This thread's buffer, which the garbage collector scans. */
sk_value *sk_mv_buffer(void) { return sk_mv_values; }

/* Call fn with the arguments, catching conditions of the given types as handler-case
 * does: returns [-1 value] if fn returned, or [i condition] if a condition of types[i]
 * was signaled (M1.8 step 6: tasks and nurseries catch errors and cancellation). */
static sk_value sk_catch_code(sk_value self, uint32_t argc, const sk_value *argv) {
    (void)argc;
    const sk_value pair[2] = {SK_CAPTURED(self, 1), argv[0]};
    sk_return_from(SK_CAPTURED(self, 0), sk_vector_of(2, pair));
}

sk_value sk_try_call(sk_value fn, uint32_t argc, const sk_value *argv, uint32_t ntypes,
                     sk_value *types) {
    sk_frame block;
    sk_frame_push(&block, SK_FRAME_BLOCK);
    volatile sk_value result = SK_NIL;
    if (SK_SETJMP(block.jb) == 0) {
        sk_value handlers[8];
        for (uint32_t i = 0; i < ntypes && i < 8; i++) {
            const sk_value captured[2] = {SK_BLOCK_TOKEN(block), SK_FIXNUM(i)};
            handlers[i] = sk_closure(sk_catch_code, "catch", 2, captured);
        }
        sk_frame cluster;
        sk_frame_push_handlers(&cluster, ntypes, types, handlers);
        sk_value v = sk_call(fn, argc, argv);
        sk_frame_pop(&cluster);
        const sk_value pair[2] = {SK_FIXNUM(-1), v};
        result = sk_vector_of(2, pair);
        sk_frame_pop(&block);
    } else {
        result = block.value;
        sk_frame_pop(&block);
    }
    return result;
}

sk_value sk_try_call_stopping_exits(sk_value fn, uint32_t argc, const sk_value *argv,
                                    uint32_t ntypes, sk_value *types) {
    sk_frame barrier;
    sk_frame_push(&barrier, SK_FRAME_BARRIER);
    volatile sk_value result = SK_NIL;
    if (SK_SETJMP(barrier.jb) == 0) result = sk_try_call(fn, argc, argv, ntypes, types);
    /* After a stopped exit the unwind has already taken the frame off the chain; popping
     * it again leaves the same chain. */
    sk_frame_pop(&barrier);
    return result;
}

/* For the interpreter's %call-with-values (runtime/src/compiler.zig): the registers'
 * count, and starting a call from one value. */
int32_t sk_mv_count_get(void) { return sk_mv_count; }
void sk_mv_clear(void) { sk_mv_count = SK_MV_SINGLE; }

/* For the evaluator (runtime/src/eval/, M2.5, D-079), which is Zig and can't call setjmp:
 * the block* and unwind-protect frames of evaluated code, as the C backend compiles them
 * (lib/skein/compiler/c.skn). */

typedef sk_value (*sk_eval_thunk)(void *ctx);

/* block*: store the frame's token (which return-from* names it by) in *token, then run
 * body; its value, or the value a return-from* delivered. */
sk_value sk_eval_block(sk_eval_thunk body, void *ctx, sk_value *token) {
    sk_frame f;
    sk_frame_push(&f, SK_FRAME_BLOCK);
    *token = SK_BLOCK_TOKEN(f);
    if (SK_SETJMP(f.jb) == 0) {
        sk_value v = body(ctx);
        sk_frame_pop(&f);
        return v;
    }
    sk_frame_pop(&f);
    return f.value;
}

/* unwind-protect: run body, then cleanup however body exits, keeping the values of the
 * body (or of the unwind it interrupted); an unwind then continues. */
sk_value sk_eval_unwind_protect(sk_eval_thunk body, sk_eval_thunk cleanup, void *ctx) {
    sk_frame f;
    sk_frame_push(&f, SK_FRAME_UNWIND);
    volatile int unwinding = 0;
    volatile sk_value result = SK_NIL;
    if (SK_SETJMP(f.jb) == 0) {
        result = body(ctx);
        sk_frame_pop(&f);
    } else {
        unwinding = 1;
    }
    sk_value saved[SK_MV_MAX];
    int32_t saved_count = sk_mv_count;
    if (saved_count > 0) memcpy(saved, sk_mv_values, sizeof(sk_value) * (size_t)saved_count);
    (void)cleanup(ctx);
    sk_mv_count = saved_count;
    if (saved_count > 0) memcpy(sk_mv_values, saved, sizeof(sk_value) * (size_t)saved_count);
    if (unwinding) sk_continue_unwind(&f);
    return result;
}
