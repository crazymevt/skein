/* Stack overflow in a fiber on Windows (M2.2, D-074). The vectored exception handler in
 * platform.zig pushes the faulting address as a return address and continues here, so
 * Windows' unwinder (which mingw's longjmp uses, D-047) can walk from sk_stack_overflow
 * back through the fiber's frames: this frame has unwind information, and its caller is
 * the code that overflowed. It aligns the stack and calls sk_stack_overflow, which
 * signals the error and never returns. build.zig compiles this file for Windows. */

#if defined(__x86_64__)
__asm__(
    ".text\n"
    ".globl sk_stack_overflow_trampoline\n"
    ".def sk_stack_overflow_trampoline; .scl 2; .type 32; .endef\n"
    ".seh_proc sk_stack_overflow_trampoline\n"
    "sk_stack_overflow_trampoline:\n"
    "  pushq %rbp\n"
    "  .seh_pushreg %rbp\n"
    "  movq %rsp, %rbp\n"
    "  .seh_setframe %rbp, 0\n"
    "  .seh_endprologue\n"
    "  andq $-16, %rsp\n"
    "  subq $32, %rsp\n"
    "  callq sk_stack_overflow\n"
    "  ud2\n"
    ".seh_endproc\n");
#endif
