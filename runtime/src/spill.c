/* Spill the CPU's registers onto the stack, then call fn(arg). The garbage collector
 * scans a thread's stack conservatively (DESIGN §18.1); values that live only in
 * callee-saved registers must be in memory when it does. Portable C, compiled into the
 * runtime library by build.zig. */

#include <setjmp.h>

void sk_spill_registers_and_call(void (*fn)(void *), void *arg) {
    jmp_buf registers;
    __builtin_unwind_init(); /* save every callee-saved register in this frame */
    setjmp(registers);       /* and copy the rest of the register state */
    fn(arg);
    /* Keep the buffer alive across the call. */
    __asm__ volatile("" : : "r"(&registers) : "memory");
}
