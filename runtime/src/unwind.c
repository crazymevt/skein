/* The parts of the condition system that need setjmp and longjmp, which Zig can't call
 * safely (D-047), and the multiple-values registers (D-053), which are C thread-locals.
 * Compiled into the runtime library by build.zig.
 *
 * On Windows (x86_64-windows-gnu) mingw's longjmp unwinds through RtlUnwindEx, so it
 * walks the SEH unwind tables of every frame it crosses: Skein's C, the runtime's Zig and
 * any C library in between. */

#include "skein.h"

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
_Thread_local int32_t sk_mv_count = SK_MV_SINGLE;
_Thread_local sk_value sk_mv_values[SK_MV_MAX];

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
