# Phase 1 retrospective

Phase 1 made Skein native in twelve milestones (M1.1–M1.12). A Zig runtime, a C backend
and a front end written in Skein turn programs into executables for macOS, Windows and
Linux; `skeinc`, the compiler, compiles itself. It ends where Phase 0 did, with
**Driftrock**: built by `skein package` with SDL3 inside, it plays at 60 fps on all three
platforms in CI, and its `-main` starts about 10 ms after launch. This document records
what worked, what felt bad, what was slow, and the changes Phase 1 suggests.

**By the numbers** (November 2026):
- About 13,700 lines of runtime (Zig, C and the header), 4,900 lines of compiler in
  Skein (`lib/skein/compiler/`) and 2,000 lines of library in Skein.
- 3,300 host test checks, 65 runtime tests, and the bootstrap test, which rebuilds
  `skeinc` twice and builds every example, fixture and package with it. CI runs all of
  it on the three platforms for every commit.
- 30 decisions (D-042–D-071), recorded as they were made.

## What worked

- **A native slice first** (D-042). Generating C for a tiny subset in M1.2, with the
  Phase 0 front end, put every native risk (C generation, the GC, unwinding on Windows,
  cross-compiling) in front of us before the large port. None of them forced a redesign.
- **Phase 0 as the reference.** Every native feature was tested by running the same
  program both ways and comparing output, and the C backend in Skein was tested by
  comparing its C with the Lisp backend's, byte for byte. Most bugs showed up as a
  one-line diff with an obvious cause.
- **Mostly-copying GC with conservative stack scanning** (D-045). Compiled C needs no
  stack maps, C code can hold pointers on its stack, and arrays passed to C stay pinned
  for free. Driftrock collects about 5 times a second, with pauses of 3 ms at most.
- **setjmp/longjmp unwinding** (D-047). Conditions, restarts, `unwind-protect` and
  non-local exits map onto frames in C stack frames; mingw's `longjmp` unwinds through
  SEH on Windows. Callbacks stop exits at the C boundary (D-068).
- **Self-hosting with a fixed point** (D-062, D-063). `skeinc` rebuilt by itself gives
  byte-identical C, which caught nondeterminism (gensym numbering) early.
- **Zig as the toolchain.** One download builds the runtime and cross-compiles C for six
  targets, signs macOS binaries ad hoc, and links Linux against an old glibc. Packages
  built on Linux run on all three platforms with nothing else installed (M1.11).
- **Typed C calls for the FFI** (D-066). Each `defcfun` becomes a C function with the
  exact signature: no libffi, and `sdl3.raw`'s 400 functions compile like any code.

## What felt bad

1. **Two compilers, two front ends.** Until M1.9 every feature went into the Lisp C
   backend and its Skein port; after it, the Lisp backend froze (D-064), and the
   comparison tests need a growing list of things to skip (`skeinc-only-p`). The Phase 0
   host still runs `skein run`, `dev` and `repl`, so the language has two
   implementations whose messages differ (CL wording in Phase 0).
2. **GC bugs from stores the collector doesn't see.** Three times a young object was
   stored where a collection missed it: an atom's compare-and-set without the write
   barrier (M1.8), C types storing young parts into permanent objects (M1.10), and a
   table of generic functions that isn't scanned (M1.12). Each failed far from its cause,
   and only after enough allocation. A GC verification mode would catch these at once
   (proposal 3).
3. **The phase-1 rule is subtle** (D-058). Which top-level forms run at compile time
   (`ns`, `defmacro`, function `def`s, `%define-` forms) is a list, and each new kind of
   definition needs a decision: `primitive-types` in `skein.ffi` had to become a function,
   and class names needed qualifying at phase 1 (D-070).
4. **Zig's compiler_rt shadows libm.** The runtime's own math comes from compiler_rt, so
   `-lm` was dropped on Linux (D-067), and calling `sin` from Zig gets compiler_rt's
   copy, which can differ from SBCL's libm in the last bit (D-070). Both needed lookups
   by name.
5. **Debugging native crashes.** ReleaseSafe stack traces are often mis-symbolized, and
   every program called `main.skn` writes `.skein-cache/main.c`, so the C a trace points
   into may have been overwritten. `lldb` and a copy of `skeinc` kept with `--keep-c` were
   needed (proposal 4).
6. **CI on three platforms is slow and occasionally flaky.** A full run takes about 20
   minutes, the private repository ran out of minutes (it is public now), and a DNS
   failure on a Windows runner failed one run.

## What was slow

Measured on an M-series MacBook (macOS) unless noted.

| What | Native | Phase 0 |
|---|---|---|
| Driftrock start-up, until `-main` | ~10 ms | ~1.65 s |
| Driftrock first frame (dummy video driver) | ~50 ms | ~1.7 s |
| Driftrock frame work (release, dummy video driver) | mean 1.8–2.3 ms, p99 ~3.2 ms, worst ~5 ms | mean ~1.4 ms, p99 ~3.2 ms, worst ~16 ms |
| Driftrock GC | ~5 minor collections a second, pauses ≤3 ms | one every ~13 s, 3–7 ms |
| `skeinc build hello.skn` | 1.2 s | — |
| `skeinc` building itself | 17 s | 25–35 s for the whole bootstrap |
| Executable size | 1.6 MB (`hello`), 2.2 MB (Driftrock) | — |

Takeaways:
- Start-up was Phase 0's worst number and is now negligible; on a real window SDL and
  the OS take about 120 ms before the first frame, which Skein can't shorten (D-071).
- Frame work is about the same as SBCL's, but with the dummy video driver SDL's software
  renderer does the drawing, and it dominates; the worst frames are much better natively
  (5 ms rather than 16 ms), because collections are small and frequent. Native code has
  no escape analysis, frame arenas or incremental marking yet (DESIGN §18), and
  allocation is still what the GC spends its time on; the plans in §18 stand.
- Every program links the whole runtime and skein.core library, so even `hello` is
  1.6 MB. Dead-code elimination of the library would help small tools, not games.

## Proposed changes

Jessie decided these right after Phase 1 (D-073): all four are in M2.1, with the
function named `skein.io/resource-dir`.

1. **Finding assets.** A packaged program can't find its assets: its working directory
   isn't its folder, and a `.app` keeps them in `Contents/Resources`. Add a function that
   returns the program's resource directory (`skein.io/resource-dir`, say).
2. **Retire the Lisp C backend's role as a test reference.** Compare `skeinc` with
   Phase 0 by program output only, and keep the Lisp backend just to bootstrap.
3. **A GC verification mode** (`SKEIN_GC_VERIFY=1`): collect at every safepoint and check
   that no heap or table slot points into freed or moved memory.
4. **Unique cache names.** Name `.skein-cache/` files by the program's full path, not its
   file name, and keep the C of the last build of each program.

Implementation notes that need no decision are in the ROADMAP notes.
