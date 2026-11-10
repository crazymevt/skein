/* Fibers on macOS and Linux (M2.2, D-074): switching stacks, for arm64 and x86_64 System
 * V, and turning a stack overflow into an error. In C (with top-level assembly) so every
 * Zig backend links it: build.zig compiles this file into the runtime for POSIX targets.
 * platform.zig lays out a new fiber's first frame to match.
 *
 * sk_switch_stacks(save, load): save the callee-saved registers on the current stack,
 * store the stack pointer in *save, load the stack pointer `load`, restore the registers
 * saved there and return into that context.
 *
 * sk_fiber_start: where a new fiber starts; calls entry(arg), which never returns. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

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

/* Stack overflow. Below each fiber's usable stack is a soft guard zone, and below that a
 * hard guard page, both inaccessible. A fault in the running fiber's soft zone runs
 * on_fault on the thread's alternate signal stack: it opens the zone, which gives the
 * fiber room to signal the error, and makes the fiber continue in sk_stack_overflow as
 * if it had called it. platform.zig closes the zone again once the fiber's stack is
 * shallow, and keeps these thread-locals right for the running fiber. */

/* The running fiber's soft zone [low, high); 0 when the thread runs on its own stack. */
_Thread_local uintptr_t sk_fiber_soft_low, sk_fiber_soft_high;
/* Set once its soft zone is open (until platform.zig closes it). */
_Thread_local int sk_fiber_overflowed;

void sk_stack_overflow(void); /* fiber.zig: signals stack-overflow, never returns */

static struct sigaction previous_segv, previous_bus;

static void on_fault(int sig, siginfo_t *info, void *context) {
    uintptr_t address = (uintptr_t)info->si_addr;
    if (sk_fiber_soft_high != 0 && !sk_fiber_overflowed && address >= sk_fiber_soft_low &&
        address < sk_fiber_soft_high) {
        mprotect((void *)sk_fiber_soft_low, sk_fiber_soft_high - sk_fiber_soft_low,
                 PROT_READ | PROT_WRITE);
        sk_fiber_overflowed = 1;
        ucontext_t *uc = context;
        /* Continue in sk_stack_overflow with the stack aligned as at a function's entry,
         * the faulting code as its caller. */
#if defined(__APPLE__) && defined(__aarch64__)
        uc->uc_mcontext->__ss.__sp &= ~(uint64_t)15;
        uc->uc_mcontext->__ss.__lr = uc->uc_mcontext->__ss.__pc;
        uc->uc_mcontext->__ss.__pc = (uint64_t)(uintptr_t)sk_stack_overflow;
#elif defined(__APPLE__) && defined(__x86_64__)
        uc->uc_mcontext->__ss.__rsp = (uc->uc_mcontext->__ss.__rsp & ~(uint64_t)15) - 8;
        uc->uc_mcontext->__ss.__rip = (uint64_t)(uintptr_t)sk_stack_overflow;
#elif defined(__aarch64__)
        uc->uc_mcontext.sp &= ~(uint64_t)15;
        uc->uc_mcontext.regs[30] = uc->uc_mcontext.pc;
        uc->uc_mcontext.pc = (uint64_t)(uintptr_t)sk_stack_overflow;
#elif defined(__x86_64__)
        uc->uc_mcontext.gregs[REG_RSP] = (uc->uc_mcontext.gregs[REG_RSP] & ~(greg_t)15) - 8;
        uc->uc_mcontext.gregs[REG_RIP] = (greg_t)(uintptr_t)sk_stack_overflow;
#endif
        return;
    }
    /* Anything else: put the previous handling back, so the fault happens again and is
     * handled as it would have been without this handler. */
    sigaction(sig, sig == SIGSEGV ? &previous_segv : &previous_bus, NULL);
}

static void install_handler(void) {
    struct sigaction action = {0};
    action.sa_sigaction = on_fault;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, &previous_segv);
    sigaction(SIGBUS, &action, &previous_bus);
}

static pthread_once_t handler_once = PTHREAD_ONCE_INIT;
static _Thread_local int thread_prepared;

/* Before a thread first runs fibers: give it an alternate signal stack, and install the
 * fault handler once per process. */
void sk_fiber_prepare_thread(void) {
    if (thread_prepared) return;
    thread_prepared = 1;
    pthread_once(&handler_once, install_handler);
    stack_t alt = {0};
    alt.ss_size = 64 * 1024;
    alt.ss_sp = malloc(alt.ss_size);
    if (alt.ss_sp != NULL) sigaltstack(&alt, NULL);
}

/* platform.zig: the zone of the fiber about to run, and whether it's open. */
void sk_fiber_set_zone(uintptr_t low, uintptr_t high, int overflowed) {
    sk_fiber_soft_low = low;
    sk_fiber_soft_high = high;
    sk_fiber_overflowed = overflowed;
}

int sk_fiber_overflowed_now(void) { return sk_fiber_overflowed; }
