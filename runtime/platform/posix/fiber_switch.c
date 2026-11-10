/* Switching fiber stacks on macOS and Linux (M2.2, D-074), for arm64 and x86_64 System V.
 * In C with top-level assembly so every Zig backend links it: build.zig compiles this
 * file into the runtime for POSIX targets. platform.zig lays out a new fiber's first
 * frame to match.
 *
 * sk_switch_stacks(save, load): save the callee-saved registers on the current stack,
 * store the stack pointer in *save, load the stack pointer `load`, restore the registers
 * saved there and return into that context.
 *
 * sk_fiber_start: where a new fiber starts; calls entry(arg), which never returns. */

#if defined(__APPLE__)
#define SYM(name) "_" #name
#else
#define SYM(name) #name
#endif

#if defined(__aarch64__)
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl " SYM(sk_switch_stacks) "\n"
    SYM(sk_switch_stacks) ":\n"
    "  sub sp, sp, #160\n"
    "  stp x19, x20, [sp, #0]\n"
    "  stp x21, x22, [sp, #16]\n"
    "  stp x23, x24, [sp, #32]\n"
    "  stp x25, x26, [sp, #48]\n"
    "  stp x27, x28, [sp, #64]\n"
    "  stp x29, x30, [sp, #80]\n"
    "  stp d8, d9, [sp, #96]\n"
    "  stp d10, d11, [sp, #112]\n"
    "  stp d12, d13, [sp, #128]\n"
    "  stp d14, d15, [sp, #144]\n"
    "  mov x2, sp\n"
    "  str x2, [x0]\n"
    "  mov sp, x1\n"
    "  ldp x19, x20, [sp, #0]\n"
    "  ldp x21, x22, [sp, #16]\n"
    "  ldp x23, x24, [sp, #32]\n"
    "  ldp x25, x26, [sp, #48]\n"
    "  ldp x27, x28, [sp, #64]\n"
    "  ldp x29, x30, [sp, #80]\n"
    "  ldp d8, d9, [sp, #96]\n"
    "  ldp d10, d11, [sp, #112]\n"
    "  ldp d12, d13, [sp, #128]\n"
    "  ldp d14, d15, [sp, #144]\n"
    "  add sp, sp, #160\n"
    "  ret\n"
    ".globl " SYM(sk_fiber_start) "\n"
    SYM(sk_fiber_start) ":\n"
    "  mov x0, x20\n"
    "  blr x19\n"
    "  brk #0\n");
#elif defined(__x86_64__)
__asm__(
    ".text\n"
    ".p2align 4\n"
    ".globl " SYM(sk_switch_stacks) "\n"
    SYM(sk_switch_stacks) ":\n"
    "  pushq %rbp\n"
    "  pushq %rbx\n"
    "  pushq %r12\n"
    "  pushq %r13\n"
    "  pushq %r14\n"
    "  pushq %r15\n"
    "  subq $8, %rsp\n"
    "  stmxcsr (%rsp)\n"
    "  fnstcw 4(%rsp)\n"
    "  movq %rsp, (%rdi)\n"
    "  movq %rsi, %rsp\n"
    "  ldmxcsr (%rsp)\n"
    "  fldcw 4(%rsp)\n"
    "  addq $8, %rsp\n"
    "  popq %r15\n"
    "  popq %r14\n"
    "  popq %r13\n"
    "  popq %r12\n"
    "  popq %rbx\n"
    "  popq %rbp\n"
    "  ret\n"
    ".globl " SYM(sk_fiber_start) "\n"
    SYM(sk_fiber_start) ":\n"
    "  movq %r13, %rdi\n"
    "  callq *%r12\n"
    "  ud2\n");
#else
#error "fibers support arm64 and x86_64"
#endif
