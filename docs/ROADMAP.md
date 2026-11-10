# Skein Roadmap

Work proceeds **one milestone at a time, in order**, unless a milestone says otherwise. Each milestone has **exit criteria**. A milestone is done only when all of them pass and the status table below is updated.

## Current status

| Milestone | Status |
|---|---|
| M0.1 Repository scaffolding | ✅ |
| M0.2 Reader | ✅ |
| M0.3 Core IR, expander skeleton, CL backend | ✅ |
| M0.4 Persistent collections and seqs | ✅ |
| M0.5 Macros and `skein.core` | ✅ |
| M0.6 Conditions and restarts | ✅ |
| M0.7 Object system | ✅ |
| M0.8 Declarations, value structs, typed arrays | ✅ |
| M0.9 Concurrency | ✅ |
| M0.10 FFI and bindgen | ✅ |
| M0.11 REPL, reload and dev loop | ✅ |
| M0.12 Demo game | ✅ |
| M1.1 Zig toolchain and runtime skeleton | ✅ |
| M1.2 C backend, first slice | ✅ |
| M1.3 Garbage collector | ✅ |
| M1.4 Core data in the runtime | ✅ |
| M1.5 Conditions and unwinding | ✅ |
| M1.6 Reader in Skein | ✅ |
| M1.7 Expander and Core IR in Skein | ✅ |
| M1.8 Native `skein.core` | ✅ |
| M1.9 Self-hosting | ✅ |
| M1.10 Native FFI | ✅ |
| M1.11 `skein build` and `skein package` | ✅ |
| M1.12 Driftrock native | ✅ |
| M2.1 Phase 1 follow-ups | ✅ |
| M2.2 Fibers | ✅ |
| M2.3 Work-stealing scheduler | ✅ |
| M2.4 Dynamic vars natively | ✅ |
| M2.5 Evaluating code in native programs | ✅ |
| M2.6 Native REPL and `skein dev` | ✅ |
| M2.7 Swank server | 🟨 |
| M2.8 Supervisors | ⬜ |
| M2.9 Hot reload of compiled code | ⬜ |
| M2.10 STM | ⬜ |
| M2.11 Package management | ⬜ |
| M2.12 Driftrock developed live, natively | ⬜ |

Legend: ⬜ not started · 🟨 in progress · ✅ done

---

## Phase 0: Skein-on-SBCL

**Goal:** a working Skein language hosted on SBCL, good enough to write a small game with hot reload, so the design can be validated before building a native compiler.

**Rules for Phase 0**
- The implementation language is Common Lisp (SBCL 2.4+).
- Allowed dependencies: `alexandria`, `cffi`, `bordeaux-threads`, `closer-mop`, `fiveam`, `trivial-garbage`, `lparallel`. Ask before adding anything else.
- The front end (reader → expander → Core IR → analysis) must be written so it can be ported to Skein later. Don't lean on CL-specific tricks in the front end; the CL backend may use anything.
- Don't build a GC, a fiber runtime or a C backend in Phase 0.

### M0.1 Repository scaffolding
- `host/skein.asd` with systems `skein` and `skein/tests`.
- Package layout: `skein.reader`, `skein.syntax`, `skein.expander`, `skein.ir`, `skein.backend.cl`, `skein.runtime`, `skein.cli`.
- Test runner: `make test` runs the FiveAM suites non-interactively and exits non-zero on failure.
- `make repl` starts SBCL with the system loaded.
- A `./skein` launcher script (bash, plus `skein.cmd` for Windows) that runs `skein run <file>`.
- CI: a GitHub Actions matrix on macOS (arm64), Windows and Linux runs `make test`. On Windows, SBCL is installed via Chocolatey or the MSI.
- `.editorconfig`.

**Exit:** `make test` passes with one trivial test on all three CI platforms.

### M0.2 Reader
- Implement every row of DESIGN §3.
- Output is syntax objects: a datum plus a source location (file, line, column, span).
- Errors include the location, e.g. "unterminated string at foo.skn:12:5".
- The reader is a standalone function over a character stream. It must not use the CL reader or readtables, because it gets ported to Skein later.

**Exit:** reader tests cover every syntax row, nesting, error cases and round-tripping through a printer (`pr-str`) for data.

### M0.3 Core IR, expander skeleton, CL backend
- Write `docs/CORE-IR.md` defining the IR nodes for DESIGN §5.1.
- Expander: namespaces and vars, symbol resolution, local scoping, special-form parsing to IR, and a macro-expansion hook (built-in macros are written in CL for now).
- The CL backend translates IR to CL forms. Vars are represented as objects holding a value, and global calls go through the var.
- The Lisp-1 call semantics work: `(f x)` where `f` is a local, a var or a keyword.
- `skein run hello.skn` prints "hello".

**Exit:** tests for each special form; `examples/hello.skn` and `examples/fib.skn` run; redefining a `defn` at the REPL changes the behavior of an existing caller.

### M0.4 Persistent collections and seqs
- Persistent list, vector (32-way trie with tail), hash map (HAMT, with array maps for small sizes), hash set, and transients.
- `=`, `hash-of` and `identical?` per DESIGN §7.
- Seq abstraction, lazy seqs, the core seq library, and transducers.
- Printing of all data types.

**Exit:** unit tests plus randomized tests against reference models (e.g. a persistent map compared with a CL hash table over 10k random operations); benchmarks recorded in `bench/` (no hard target yet).

### M0.5 Macros and `skein.core`
- `defmacro`, syntax-quote with namespace resolution, auto-gensym (`x#`), `&form`/`&env`, and `macroexpand*`.
- Phase tracking: `:require-for-syntax`, with a warning on violations (DESIGN §4.4).
- Move the built-in macros from CL into `lib/skein/core.skn` where possible.
- Destructuring (DESIGN §5.4).

**Exit:** `skein.core` loads from `.skn` source; tests for each core macro and for destructuring.

### M0.6 Conditions and restarts
- DESIGN §10 on top of the CL condition system: `defcondition`, `signal`, `warn`, `error`, `handler-bind`, `handler-case`, `try`, `restart-case`, `invoke-restart`, `compute-restarts`.
- Unhandled errors at the REPL show the restarts.

**Exit:** tests covering non-unwinding handlers, restart selection, and `unwind-protect` ordering.

### M0.7 Object system
- `defclass` (immutable slots plus `:cell` slots), `make`, `with`, keyword slot access, `defgeneric`, `defmethod` with qualifiers, eql specializers, `call-next-method`, C3 linearization.
- Implemented on CLOS via `closer-mop` with a custom metaclass.
- Class redefinition updates instances (DESIGN §8.4).
- `equiv`/`hash-of` integration.

**Exit:** tests for dispatch, combinations, immutability errors, `with`, cell semantics and redefinition.

### M0.8 Declarations, value structs, typed arrays
- Type specifiers (DESIGN §12.1), `declare`/`the`/hints mapped to CL declarations, and an optimization-policy mapping.
- `defstruct :value`, plain `defstruct`, `make-array` with element types (mapped to CL specialized arrays where possible), `defsoa`, `update!`, `view`.
- Surface SBCL efficiency notes in Skein terms where feasible.

**Exit:** a float-heavy benchmark (an n-body simulation or particle integration) with declarations runs within 2× of the equivalent hand-written, declared SBCL code.

### M0.9 Concurrency
- DESIGN §13.2 API on OS threads: nurseries, `spawn`, futures, channels (`>!`, `<!`, `alts!`, `close!`), atoms, `pmap`, `preduce`, `pdotimes`, `jobs/graph`, `on-main-thread`, cancellation and timeouts.
- Supervisors: an unhandled error in a spawned task cancels its siblings and propagates to the nursery.

**Exit:** concurrency tests, including stress tests run 100× without failure; a job-graph example.

### M0.10 FFI and bindgen
- `skein.ffi` (DESIGN §14.1–14.2) on top of CFFI.
- A bindgen spike: generate `sdl3.raw` from the SDL3 headers (via c2ffi JSON or a libclang script) and commit the generated output.

**Exit:** an example opens an SDL3 window and clears it to a color on all three platforms.

### M0.11 REPL, reload and dev loop
- `skein repl`, `(reload 'ns)`, `skein dev` with a file watcher, `defonce`.
- Document editor setup for Emacs and VS Code (`docs/EDITORS.md`; plain text REPL over a socket instead of SLY/Alive, D-039).
- Unhandled errors in the game loop offer `retry-frame` and `skip-frame` restarts.

**Exit:** a recorded manual test: change a function while the demo runs, and the change appears without a restart; cause an error, fix it, choose `retry-frame`, and the game continues.

### M0.12 Demo game
- A rock-field shooter (Driftrock, `examples/driftrock/`, an original game in the Asteroids genre) using SDL3, `skein.math`, value structs, a job graph per frame and `defclass` entities.
- `skein.game/run-loop` with a fixed timestep.

**Exit:** playable on macOS, Windows and Linux at 60 fps. Write `docs/PHASE0-RETRO.md` covering what worked, what felt bad, what was slow and proposed design changes, and update DESIGN.md accordingly.

---

## Phase 1: Native compiler

**Goal:** Skein programs compile to native executables for macOS, Windows and Linux through a C backend and a runtime written in Zig, with the front end written in Skein. Driftrock builds and runs natively at the end.

**Order (D-042):** a thin native slice comes first (M1.1–M1.2), then the runtime's hard parts (GC, data, unwinding), then the front end's port to Skein (M1.6–M1.7), native `skein.core` (M1.8) and self-hosting on it (M1.9, swapped by D-050), then FFI and tooling. Running native code early tests the riskiest parts while the Phase 0 front end is still a stable reference.

**Rules for Phase 1**
- The runtime is Zig, built with Zig **0.17.1** (pinned in M1.1, D-043; upgrade deliberately). Generated code is C11 compiled with `zig cc`. Ask before adding other dependencies or tools.
- Platform code lives only in `runtime/platform/<os>/` (DESIGN §19.3).
- The Phase 0 host keeps working and stays the reference: native results are tested against it. Native tests run alongside `make test`, and CI runs both on all three platforms.
- Concurrency stays on OS threads (as in Phase 0); fibers and the work-stealing scheduler are Phase 2. Live redefinition at the REPL is Phase 2 too; Phase 1 binaries are built ahead of time.
- Keep the Core IR (`docs/CORE-IR.md`) the contract between front end and backends; change it only with a DECISIONS entry.

### M1.1 Zig toolchain and runtime skeleton
- Pin a Zig version; `runtime/` builds with `zig build`. CI installs Zig on all three platforms.
- Value representation (DESIGN §17.1): tagged words for fixnums, chars, booleans, nil, f32; boxed f64 and heap objects with the header of §17.2.
- An allocator for the heap (bump allocation in thread-local buffers, §18.1) without collection yet, and the platform layer (memory mapping, threads, time, console output).

**Exit:** runtime unit tests (Zig's `test` blocks) pass on macOS, Windows and Linux in CI.

### M1.2 C backend, first slice
- `skein.backend.c`: the Phase 0 front end turns Core IR into C11 for integers, floats, `if`, `let`, `loop`/`recur`, functions, global vars and calls, plus the few primitives these need.
- `skein build file.skn` (host side) writes C, compiles it with `zig cc` against the runtime and produces an executable.

**Exit:** `examples/hello.skn` and `examples/fib.skn` build natively and print the same output as `skein run` on all three platforms.

### M1.3 Garbage collector
- Nursery: copying with conservative stack scanning and precise heap scanning, pinning what stacks refer to (DESIGN §18.1). Old generation: non-moving mark-sweep with size classes; a large-object space.
- Write barrier for old-to-young pointers; root registration for globals.

**Exit:** a GC stress test (deep and wide allocation, cycles, survivors across many collections) runs clean, with randomized tests against a reference model, on all three platforms.

### M1.4 Core data in the runtime
- Strings (UTF-8, §6.5), symbols and keywords (interned), vars and namespaces, closures, the persistent vector, hash map and set, transients, atoms. Whether the collections are written in Zig or compiled from Skein is decided when this milestone starts.

**Exit:** the collection tests and randomized model tests from Phase 0 pass against the native implementation.

### M1.5 Conditions and unwinding
- `handler-bind`, `handler-case`/`try`, `restart-case`, `unwind-protect`/`finally` and non-local exits across native frames, using SEH-compatible unwinding on Windows (§19.3). Restarts listed and invoked as in Phase 0 (D-034, D-041).

**Exit:** `examples/conditions.skn` and the condition tests pass natively on all three platforms.

### M1.6 Reader in Skein
- Port `skein.reader` to Skein (`lib/skein/compiler/reader.skn` or similar), running on the Phase 0 host.

**Exit:** the Skein reader reads every `.skn` file in the repository to the same syntax objects (data and locations) as the CL reader, and the reader tests pass against it.

### M1.7 Expander and Core IR in Skein
- Port the expander, environments, syntax-quote, destructuring and Core IR construction to Skein.

**Exit:** for every `.skn` file in the repository, the Skein expander produces the same Core IR as Phase 0.

### M1.8 Native `skein.core`
- `core.skn`, seqs, transducers, the object system (classes, generic functions with dispatch caches), value structs and typed arrays, declarations, and concurrency on OS threads, compiled natively.
- The runtime (Zig) keeps the foundations: the seq protocol over every collection, lazy-seq cells, objects and generic-function dispatch, typed arrays and threads. The library built on them (`map`, `filter`, `partition`, transducers, `group-by`, ...) is written in Skein as `skein.core.native`, compiled into every native program, and tested against Phase 0 (D-051).
- Steps, in order:
  1. ✅ Programs of several namespaces: a native program includes every namespace it requires, and `skein.core.native`.
  2. ✅ Seqs: `seq`/`first`/`rest` over every collection, lazy seqs, the seq library, `reduced` and transducers.
  3. ✅ The rest of skein.core's functions, and multiple values.
  4. ✅ The object system: classes, instances, generic functions with dispatch caches.
  5. ✅ Value structs, typed arrays and `defsoa`; declarations compiled to unboxed code (n-body).
  6. ✅ Concurrency on OS threads: nurseries, tasks, futures, channels, `pmap`, `skein.jobs`.

**Exit:** every example with an `.expected` file passes natively on all three platforms; the n-body benchmark is within 1.5× of C.

### M1.9 Self-hosting
- The Skein front end plus the C backend compile the compiler itself to a native executable (bootstrapped by Phase 0). It comes after native `skein.core` because the compiler uses most of it (D-050).
- skein.core's macros are compiled into the compiler; a program's own macros run in a Core IR interpreter written in Skein, on the build machine (DESIGN §4.4, D-050).
- The compiler reads and writes files and runs zig through a new `skein.io` namespace (D-050).
- The native compiler is a separate executable, `build/skeinc`, made by `make compiler` and run as `skeinc build file.skn [-o out]`; `./skein` is unchanged (D-058).
- At compile time (phase 1) it runs, in every namespace, only `ns`, `defmacro`, defs whose value is a function, and struct, class and condition definitions (D-058).
- Steps, in order:
  1. ✅ `skein.io`: `read-file`, `write-file`, `file-exists?` and `run-process`, in Phase 0 and natively.
  2. ✅ The C backend in Skein, running on the host on the Skein expander's IR: the same C as the Lisp backend for every example and native fixture.
  3. ✅ The compile-time environment natively: namespaces and vars at run time, symbol copies, identity tables, calling macros, and skein.core's macros compiled into the compiler.
  4. ✅ A Core IR interpreter in Skein for phase-1 code: a program's macros and the functions they call.
  5. ✅ The driver in Skein (`skeinc build`): finding namespaces, running phase 1, writing C and running zig. On the host it gives the same C as `skein build`.
  6. ✅ Bootstrapping: Phase 0 builds a first compiler, which builds `skeinc`; `skeinc` rebuilds itself twice and the two builds' C is identical (D-062 explains why the first compiler's output differs), and `skeinc` builds every example to the same output. CI runs it on all three platforms.

**Exit:** the native compiler rebuilds itself, and the second build's output is identical to the first.

### M1.10 Native FFI
- The C backend emits direct C calls for `defcfun`, callbacks as C functions, pinning, owned pointers and handles (DESIGN §14). `sdl3.raw` works unchanged.
- Libraries are loaded when the program runs and each C function is looked up on its first call, as in Phase 0; the calls themselves are typed C calls (D-064).
- Native FFI is added to the C backend written in Skein only. The Lisp C backend is frozen as the bootstrap compiler: `./skein build` reports FFI programs as unsupported and points to `skeinc` (D-064).
- Steps, in order:
  1. ✅ The runtime's FFI: foreign pointers, loading libraries and finding symbols, structs, unions and enums with C layouts, memory access, handles, and owned pointers freed by the GC. skein.ffi's functions natively.
  2. ✅ `defcfun` in `skeinc`: typed C calls with Phase 0's conversions (C strings, enums, `nil` as NULL), arrays pinned for the call, `^:owned` results, `^:blocking` calls that let the GC run, and the slow-call warning.
  3. ✅ `defcallback`: C functions that call Skein; an error warns and returns zero, as in Phase 0.
  4. ✅ `examples/sdl/window.skn`, built by `skeinc`, runs natively on all three platforms in CI.

**Exit:** `examples/sdl/window.skn` runs natively on all three platforms.

### M1.11 `skein build` and `skein package`
- `skein build --target T --profile P` cross-compiles for the three P0 targets (§19.1); `skein package` makes a folder with the executable, bundled libraries and assets (§19.4). `project.skn` (§20.2) supplies `:main`, `:paths` and `:native`.
- Both commands are `skeinc`'s; `./skein` hands them to it (D-069).
- Steps, in order:
  1. ✅ `--target` and `--profile` in `skeinc build`: the runtime and the program cross-compiled for each §19.1 target, Linux against glibc 2.28; `dev` and `release` profiles.
  2. ✅ `project.skn`: `skeinc build` with no file builds the project's `:main`, finding namespaces in `:paths`.
  3. ✅ `./skein build` and `./skein package` run `skeinc`, bootstrapping it if needed; the Lisp backend moves behind an internal command.
  4. ✅ `skein package`: a folder with the executable, its `:native` libraries and its `:assets`, or a `.app` for macOS; the runtime finds libraries next to the executable first.
  5. ✅ CI packages `hello` for all three targets on Linux and runs each package on its platform.

**Exit:** from one machine, packaged `hello` builds for all three targets run on their platforms in CI.

### M1.12 Driftrock native
- Build and package Driftrock natively.
- Steps, in order:
  1. ✅ `skein.time` and `skein.math`'s host functions natively, with Phase 0's results (the system's libm, as SBCL uses).
  2. ✅ Driftrock builds and runs natively; CI runs it with `--check-60fps` on all three platforms.
  3. ✅ Start-up under 0.1 s: Driftrock measures the time from the program's start until `-main` runs (D-071), and CI checks it.
  4. ✅ Driftrock packaged with its SDL3 on each platform in CI, and the package runs.
  5. ✅ `docs/PHASE1-RETRO.md` (its proposals wait for Jessie's decision), and DESIGN.md brought up to date.

**Exit:** native Driftrock plays at 60 fps on macOS, Windows and Linux and starts in under 0.1 s (until `-main` runs, D-071). Write `docs/PHASE1-RETRO.md` and update DESIGN.md.

## Phase 2: Native live development

**Goal:** everything Phase 0 does for live development, natively: fibers on a work-stealing scheduler, a REPL and `skein dev` in the running native program, SLIME through a Swank server, supervisors, hot reload of compiled code and STM. At the end `./skein run`, `dev` and `repl` run on the native runtime, and SBCL only bootstraps the compiler (D-072).

**Order (D-072):** the riskiest part first, as in Phase 1: fibers and the scheduler (M2.2–M2.4), on which the debugger and REPL depend. Then evaluating code in a native program and the REPL (M2.5–M2.7), supervisors (M2.8), hot reload of compiled code (M2.9), STM (M2.10), package management (M2.11, D-085), and Driftrock developed live (M2.12).

**Rules for Phase 2**
- Phase 1's rules still apply (Zig 0.17.1, C11 with `zig cc`, platform code only in `runtime/platform/<os>/`, the Core IR as the contract).
- The Phase 0 host stays a test reference by program output: a native result is tested against what `skein run` on SBCL prints, which from M2.6 is `skein host run` (D-081), besides the expected-output files and fixtures. The Lisp C backend only builds the first compiler (D-073).
- New native features go into the runtime and the compiler in Skein; nothing new goes into the Phase 0 host unless a test reference needs it.

### M2.1 Phase 1 follow-ups
- `skein.io/resource-dir`: the directory holding the program's `:assets` (the package folder, a `.app`'s `Contents/Resources`, or the project directory when run from source) (D-073).
- Retire the tests that compare the Lisp C backend's C with `skeinc`'s; compare programs by output (D-073).
- `SKEIN_GC_VERIFY=1`: collect often (every 256 KiB, always major) and check every root, table and heap slot after each collection.
- Name `.skein-cache/` files after the program's file and a hash of its path, so builds of different programs don't overwrite each other's C.

**Exit:** a packaged example loads an asset through `resource-dir` on all three platforms in CI, and the native test suites pass with `SKEIN_GC_VERIFY=1`.

### M2.2 Fibers
- Fiber stacks: reserved virtual memory with a guard page, committed as touched, pooled (DESIGN §17.4, D-024); stack overflow signals an error in the fiber.
- Context switching per architecture (arm64, x86_64 System V, x86_64 Windows).
- The GC scans each fiber's stack; conditions, handlers and restarts are per fiber.
- A scheduler on one thread first.
- Steps, in order (D-074):
  1. ✅ Fiber stacks (reserved, guarded, committed as touched, pooled) and switching: hand-written for arm64 and x86_64 on macOS and Linux, Windows' fiber API on Windows.
  2. ✅ The GC scans every fiber's stack; condition frames are per fiber; errors, restarts and unwinding work inside fibers.
  3. ✅ Stack overflow: the guard page becomes a `stack-overflow` error in the fiber, which can handle it and go on.
  4. ✅ A scheduler on one thread: spawning, yielding, a run queue, fibers finishing; the exit test.

**Exit:** 100,000 fibers that yield and allocate under collections run on all three platforms in CI.

### M2.3 Work-stealing scheduler
- Worker threads with work-stealing deques and an injection queue (DESIGN §13.1).
- Tasks, nurseries, channels, `sleep`, futures and nursery joins park fibers instead of OS threads; `^:blocking` C calls hand their worker off (§14.3); callbacks from foreign threads run as temporary fibers.

- Steps, in order (D-075):
  1. ✅ Worker threads (one per CPU) with work-stealing deques and an injection queue; fibers move between workers; a fiber that runs for about 10 ms yields at its next safepoint.
  2. ✅ Waiting on fibers: wait queues per task and channel, a timer queue for sleeps and deadlines, cancellation that wakes a parked fiber; threads that aren't workers (the main thread, foreign threads) wait on a condition variable.
  3. ✅ Tasks, nurseries, futures, channels, `alts!`, `sleep`, timeouts and the main thread's queue on fibers, with Phase 0's semantics.
  4. ✅ `^:blocking` C calls hand their worker off; callbacks from foreign threads run as temporary fibers; Driftrock's job graph on fibers; the exit tests.

**Exit:** the native concurrency fixtures pass on fibers, a million channel messages pass between 10,000 fibers, and Driftrock's job graph runs on fibers, on all three platforms.

### M2.4 Dynamic vars natively
- `^:dynamic` vars and `binding`, fiber-local and inherited by fibers spawned inside the `binding` (DESIGN §4.3). Phase 0 never had `binding`, so it comes to both (D-076).
- Steps, in order (D-076):
  1. ✅ Phase 0: `binding`, `set!` of a binding, bindings copied into the tasks spawned inside one, and the errors; host tests.
  2. ✅ Native: binding frames on the condition chain, reads of dynamic vars, `set!`, and the copy a task gets; the C backend compiles them.
  3. ✅ A native fixture (bindings, nested and in tasks, non-local exits, `set!`, the errors) prints what `skein run` prints.

**Exit:** the new host tests pass, and the fixture prints the same natively as with `skein run`, on all three platforms.

### M2.5 Evaluating code in native programs
- Dev builds include the compiler's front end and a closure-compiling interpreter (Core IR to closures), so a running native program can `eval`, load a file and `(reload 'ns)`.
- Redefinition follows DESIGN §15: `defn`/`def` rebind vars, `defclass` updates instances, `defmethod` clears dispatch caches, `defonce` keeps state.
- Steps, in order (D-078):
  1. ✅ Phase 0: `eval`, `load-file` and `reload` in skein.core; host tests.
  2. ✅ The program's namespaces: `skeinc build --eval` (dev profile) includes the reader, the expander and skein.core's macros, compiles the program's own macros in, and registers the program's namespaces and vars, from which `skein.compiler.env` builds its model; `macroexpand` and its relatives natively; without `--eval`, `eval` and its relatives are errors.
  3. ✅ The closure compiler (`runtime/src/eval/`, D-079): every Core IR node (functions and closures, loops, `letfn`, `def`, `set!`, blocks, `unwind-protect`, handlers and restarts, multiple values, dynamic vars, the FFI's type definitions; a re-evaluated `defcfun` keeps its compiled function); `eval`, `load-file`, `reload` and `require` from source natively; a fixture that evaluates code prints what `skein run` prints.
  4. ✅ Redefinition (DESIGN §15, D-080): `defclass` updates existing instances natively, subclasses included, `defmethod` clears dispatch caches, `defonce` keeps state; a native program reloads a changed namespace and runs the new code.
  5. ✅ Typed closures: unboxed `f64` and integer paths for declared types; `make bench` compares n-body interpreted and compiled in the same dev build (about 20×, D-079).

**Exit:** a native program reloads a changed namespace from source and runs the new code; interpreted code runs within 25× of compiled code on the n-body benchmark (both in a dev build). The target was 10×; Jessie changed it when about 20× was measured, since hot reload of compiled code (M2.9) gives reloaded hot code native speed (D-079).

### M2.6 Native REPL and `skein dev`
- The REPL on the terminal and on a localhost socket, the file watcher and the debugger (an unhandled error suspends its fiber; restarts and a backtrace), with Phase 0's behavior (D-039).
- `./skein run`, `dev` and `repl` run on the native runtime; SBCL only bootstraps, and runs `./skein host ...` as a reference.
- Steps, in order (D-081):
  1. ✅ The runtime: a localhost TCP server, file modification dates, reading the terminal without blocking a worker, an unhandled error calling an installed debugger in its fiber, and backtraces (compiled functions' names and locations in `--eval` builds; interpreted frames).
  2. ✅ The REPL (`skein.dev`) natively, with Phase 0's behavior: prompts, `*1` `*2` `*3` `*e`, `:quit`, read errors, the debugger (numbered restarts, `:bt`, nested levels); `skein repl`.
  3. ✅ `skein dev` natively: the server on `localhost:5555`, the file watcher, an error in the program's fiber suspended and debugged from an attached REPL, output that doesn't interleave mid-line.
  4. ✅ The command line: `./skein run`, `dev`, `repl`, `build` and `package` natively through skeinc (programs built with `--eval`, cached by their sources), `./skein host ...` on SBCL; the bootstrap check's references from `skein host run`; M0.11's exit test natively.

**Exit:** M0.11's live-development exit test passes natively on all three platforms.

### M2.7 Swank server
- A Swank-compatible server in the native runtime (D-018): evaluation, loading files, completion, argument lists, the debugger (SLDB) with Skein's restarts and backtrace, and the inspector. SLIME is the reference client.
- Steps, in order (D-082):
  1. ✅ The protocol (`skein.swank`): framing, reading and printing the Common Lisp data SLIME sends, `connection-info`, the listener (`create-repl`, `listener-eval`), evaluating and compiling forms and regions, loading files, namespaces for SLIME's packages; `skein dev` serves it on `localhost:4005` (`--swank-port`, `--no-swank`); host tests that speak the protocol.
  2. ✅ The debugger: SLDB for errors in the listener and in the program (Skein's restarts, the shadow stack's backtrace, evaluating in a frame's fiber, abort and continue).
  3. ✅ Completion, argument lists (autodoc), documentation and the inspector.
  4. `editors/skein-slime.el`, `docs/EDITORS.md`, and the scripted SLIME session in the Linux CI job.

**Exit:** a scripted SLIME session against native `skein dev` passes in CI.

### M2.8 Supervisors
- Unhandled errors go to the fiber's supervisor: in development the root supervisor opens the debugger; in release builds the policies `:cancel-siblings`, `:restart-fiber`, `:ignore` and `:crash` apply (DESIGN §10).

**Exit:** each policy is tested natively.

### M2.9 Hot reload of compiled code
- `skein dev` compiles a changed namespace to a shared library and loads it into the running program, rebinding its vars; changing a value struct's layout warns about code and arrays compiled against the old one (DESIGN §15).

**Exit:** an edit to Driftrock is running as compiled code within a second of saving, without a dropped frame, on all three platforms.

### M2.10 STM
- Refs with `dosync`, `alter`, `commute` and `ensure`, and `:cell :ref` slots (DESIGN §13.3).

**Exit:** randomized tests against a model, and a concurrent transfer test that keeps its total, pass natively.

### M2.11 Package management
- `project.skn`'s `:deps` (DESIGN §20.2, D-085): a project uses libraries from git repositories, GitHub's included, pinned to a tag or a commit, and from local files and folders. `skein build`, `run`, `dev` and `package` find their namespaces; a library's `:native` libraries and `:assets` go into packages.
- To settle when preparing it, in DESIGN and DECISIONS:
  - the `:deps` syntax for git and local dependencies, and whether a local one is a folder with its own `project.skn`, a source folder, or a single `.skn` file;
  - how sources are fetched: the `git` command, or GitHub's HTTPS archives, which need an HTTP client and archive extraction natively;
  - where fetched sources are cached, and a lock file that pins the commits a build used;
  - transitive dependencies and conflicting versions of one library;
  - building offline from the cache, and a command to fetch or update dependencies.
- Steps are planned when the milestone starts.

**Exit:** a project that depends on a library in a git repository (a local repository in the tests, and one on GitHub in CI) and on a local folder builds, runs with `skein run` and `skein dev`, and packages with its dependencies' native libraries and assets, on all three platforms.

### M2.12 Driftrock developed live, natively
- Develop and debug Driftrock with native `skein dev` and SLIME: fix a crash in the debugger and resume, edit while playing, reload compiled code.

**Exit:** Driftrock is developed live on the native runtime on all three platforms. Write `docs/PHASE2-RETRO.md` and update DESIGN.md.

## Phase 3: Optimization and polish (outline)
Sealing; inlining across namespaces; escape analysis and arena inference; SIMD for `vec`/`mat`; optional LLVM backend; full hygienic macros; `skein fmt`; package registry; documentation site.

---

## Notes for later
Ideas and follow-ups noticed during work, kept here so they don't derail the current milestone.

- Phase 2: decide VS Code support for the native runtime's Swank server (a Swank-speaking extension or an LSP server); check SLY/Slynk compatibility (D-018).
- Phase 2: decide whether FFI calls run on the fiber stack or the worker thread's native stack (D-024).
- Phase 1: the seq library is written in CL for Phase 0 speed (D-032); port it to Skein (`lib/skein/core.skn`) with the front end, or reimplement it in the Zig runtime.
- `volatile` (DESIGN §6.3) has no milestone yet.
- The HAMT has no Clojure-style ArrayNode for wide nodes; add one if map benchmarks call for it.
- Sorted maps and sets, and persistent queues, are deferred (DESIGN §6.2).
- Dynamic vars: `binding`, and `set!` of a dynamic binding (D-031). Tasks must inherit the bindings in effect when they are spawned (DESIGN §4.3).
- Phase 2: an unhandled error in a spawned task should suspend it and open the debugger in development, with restarts (DESIGN §10). Phase 0 fails the task and reports to its nursery; only errors in the program's own threads open the debugger (D-039).
- REPL: an inspector (DESIGN §15), and a list of a macro's dependents to recompile. `*1`/`*2`/`*3`/`*e` are shared by all REPL connections; make them per connection once dynamic vars exist.
- REPL: completion and documentation lookup for editors (inf-clojure's commands send Clojure code); consider nREPL if Calva/CIDER support is wanted before Phase 2.
- Error messages for host conditions are still CL's (`arithmetic error DIVISION-BY-ZERO signalled`); give them Skein wording.
- Concurrency in Phase 0 (D-037) is simple rather than fast: all channels share one lock, blocked operations poll every 20 ms for cancellation, the worker pool has no upper bound, and an `alts!` put on an unbuffered channel is only ready when a `<!` taker is already waiting. Real fibers and a work-stealing scheduler come in Phase 2.
- Type errors from declarations show CL type names and generated variable names; translate them to Skein terms and add locations.
- Hot-path gaps: keyword access to value-struct fields (`(:x v)`) and `defsoa` field functions are not inlined; use the `vec2-x` accessors and arrays of primitives in hot code. `(aget structs i)` allocates the struct it returns.
- Flatten nested value structs inline (DESIGN §9.1), and make `(safety 0)` integer overflow wrap (DESIGN §12.3).
- Startup: `lib/skein/core.skn` is compiled on every start, adding about 0.15 s (0.3 s total for `skein run`). Cache it, e.g. in a saved SBCL core, if this becomes annoying.
- `defn` and `defn-` stay built in because they attach metadata (docstrings, `^:private`) to the name; move them to Skein if runtime metadata or a metadata helper for macros is added.
- Core macros from DESIGN §5.2 that wait on later milestones: `defclass`, `defgeneric`, `defmethod` (M0.7), `defstruct` (M0.8), `with-nursery` (M0.9), `with-open` (needs a `close` protocol, M0.7 or with `skein.io`), `binding` (dynamic vars).
- Methods can specialize on condition types (M0.7), but `defcondition` still makes plain CL condition classes rather than Skein classes; unify them if conditions need slots with cells, `with`, or inheritance from Skein classes.
- Custom metaclasses written in Skein (DESIGN §8.5) and `:cell :ref` (STM) are not supported yet.
- Generic function arity errors come from CLOS without a Skein location.
- Arity errors name where the function was defined, not the call site; consider reporting the call site too.
- Errors raised inside CL primitives (e.g. `(+ 1 "a")`) have no Skein source location yet; map them to the calling form, e.g. by recording the current form in the debugger hook.
- `skein run` looks for required namespaces next to the main file and in the current directory; use `project.skn` `:paths`, as `skeinc build` does (M1.11).
- Consider `#!` shebang lines so `.skn` files can be executable scripts.
- Phase 0 retrospective follow-ups (`docs/PHASE0-RETRO.md`): inline keyword access to value-struct fields when the type is known; Skein wording for host condition messages; optionally a saved SBCL core with `skein.core` and big bindings precompiled (startup is 0.74 s, plus 0.8 s for `sdl3.raw`). (DESIGN §22 questions 11–14 were decided in D-041.)
- `skein.game`: input mapping (DESIGN §21). Driftrock reads SDL's keyboard state directly.
- First shader-using demo: pick shader cross-compilation tooling for the SDL3 GPU API, e.g. SDL_shadercross (D-020).
- FFI: passing and returning structs by value is not supported (D-038). The SDL3 headers bound so far don't need it; CFFI's libffi support (`cffi-libffi`, which needs libffi installed) could add it if a library does.
- bindgen: `long` is assumed to be 64 bits; handle LLP64 (Windows) if a bound library uses `long`. Typedefs of anonymous structs (`typedef struct { ... } X;`) and anonymous members are skipped; add them when a library needs them.
- bindgen: generate `sdl3.raw` for the rest of SDL3 (GPU, audio, gamepad, properties, ...) when the milestones that use them start, and hand-write the idiomatic `sdl3` layer on top.
- Native runtime (D-046): atoms and functions hash by identity differently from Phase 0, so maps keyed by them iterate in a different order natively. Seqs over maps and sets, lazy seqs, `reduced` and most of skein.core wait for M1.8; `first`/`rest` work on lists, vectors and strings. Vars are made per compiled program, not looked up by name (namespaces at run time come with multi-file programs, M1.9).
- GC (D-045): a nursery segment promoted for one pinned object keeps its whole 256 KiB until the next major collection; consider moving pinned objects' neighbors out, or smaller pinning granularity. Marking is stop-the-world; incremental marking (DESIGN §18.1) and `with-frame-arena` (§18.2) are still to do.
- FFI callbacks from foreign threads work as SBCL allows; DESIGN §14.3's attach-as-fiber behavior waits for Phase 2.
- Reader in Skein (D-048): `skein run` still uses the CL reader until the front end is self-hosted.
- `skein build` loads a program's required namespaces on the host, running their top-level code, because their macros must exist to expand the program. Self-hosting (M1.9) should load them for syntax only (phase 1).
- C backend in Skein (D-059): the lists of native skein.core functions and condition types are written in both backends until the Lisp one retires.
- The native compiler's environment (D-060), for the next steps of M1.9:
  - `declaim` doesn't compile natively yet (`%declaim`). `defonce` does (M1.12).
  - A program that includes `skein.compiler.env` registers every public var of skein.core.native at startup, and the model copies them into its skein.core.
- The native compiler's driver (D-062): `skeinc` finds the Skein checkout from `SKEIN_HOME` or by looking in the current directory and its parents, and keeps the runtime and the C file in the checkout's `.skein-cache/`. M1.11 should give it an install layout.
- Native FFI calls (D-066): an arity or type error in a call to a C function has Skein's wording natively; Phase 0's comes from SBCL and CFFI. Struct and union arguments by value aren't supported, as in Phase 0.
- Native FFI (D-065): pointers print as `#<ptr 0x...>` (Phase 0 prints SBCL's form), and owned and borrowed pointers are both of class `any`. The GC frees an owned pointer some time after it becomes unreachable, as Phase 0's finalizers do.
- The interpreter (D-061): declared types aren't checked in phase-1 code, and a handler or restart cluster holds at most 64 entries. Its speed hasn't been measured; macros are usually small.
- Native concurrency (D-057):
  - Tasks, nurseries and channels share one lock, and waiters poll every 20 ms; fine for Phase 1's thread pool, replaced by the fiber scheduler in Phase 2.
  - Tasks, nurseries and channels are of class `any` natively, and print as in Phase 0.
  - Other runtime locks (names, classes, condition types) are taken without `gc.blocking`. Code that holds one must not allocate, or a collection could wait for a thread that is waiting for that lock.
- Native typed code (D-056):
  - Only `f64`, `f32`, `fixnum` and `(array f64/f32/fixnum)` are unboxed. Other declared types (`i32`, `u8`, classes, structs) are neither unboxed nor checked natively yet.
  - Inference is per function and simple: declared locals, plus immutable `let` locals whose init has a float type, or an integer type that can't overflow.
  - n-body is 1.35× of C. The rest is mostly aliasing: C knows its global arrays are distinct.
- Native structs and arrays (D-055): struct values are boxed natively; DESIGN §9.1's inline storage holds in arrays (one column per field), not yet in locals or other structs. Phase 0's char arrays are CL strings, so they print and behave as strings; natively they are arrays. An out-of-bounds index on a primitive array is an `index-error` natively, CL's own error in Phase 0.
- Native object system (D-054):
  - When one redefinition changes both a superclass's slots and a cell kind, Phase 0 (SBCL's CLOS) updates a subclass's instances twice and wraps the cell twice; natively they're updated once (D-080).
  - Slot `:type`s aren't checked natively yet.
  - Every generic function call allocates its cache key. An inline cache per call site would avoid that if dispatch shows up in profiles.
  - Built-in classes print with Skein's names (`integer`, `string`), not Phase 0's CL ones (`fixnum`, `simple-character-string`).
- Native multiple values (D-053):
  - A runtime function that calls compiled code (`reduce`, `apply`, lazy seqs) passes on whatever values that code's last call left. `apply` does so on purpose, as in CL. For `reduce`, in the rare case of a reducing function that returns several values, the caller sees them instead of one value.
- Native conditions (D-047):
  - No top-level `abort`/`continue`/`exit` restarts exist natively; Phase 0's come from `skein run` and SBCL.
  - A condition type named by a symbol at run time (`(error 'foo)`) is found by its unique unqualified name, until namespaces exist at run time (M1.8).
  - Some native messages differ from Phase 0's, where Phase 0 shows CL's wording (index errors, returning to an exited block).
  - Unwinding through foreign C frames: decided in M1.10 (D-068). No non-local exit leaves a callback.
- Packages (D-069): code signing, notarization and archives are still to do. An unpackaged native build finds its assets beside its executable, so `skein build -o elsewhere/` doesn't see them.
- The evaluator (D-079): an interpreted call takes a few hundred bytes of stack (recursion goes about 500 to 1,000 levels deep on a fiber); evaluated code that names a compiled struct type in `make-array` or a struct field uses the name as written; compiled closures are never freed. Natively the current namespace is one for the whole program, not one per task (D-078), except in REPL and Swank evaluations, which have their own (D-083).
- Dynamic vars (D-077): the interpreter of phase-1 code (D-061) has no `binding` (`interp.lisp` leaves `native-dynamic.skn` out); M2.5's evaluator needs it. A read of a dynamic var walks the condition chain, so its cost grows with the frames above it; a per-fiber cache of the innermost binding would help if that shows up in profiles.
- The Swank server (D-082): its reader of Emacs's messages, like the Skein reader, indexes the text by character, and indexing a string that isn't all ASCII scans it from the start, so reading a long message (a big region for `C-c C-c`) with one non-ASCII character takes time quadratic in its length. A string cursor in the runtime would fix both. `connection-info` reports no process id.
- SLIME's names and inspector (D-086): the runtime's functions written in Zig (`str`, `count`, `conj`...) have no argument lists or docstrings; autodoc has nothing for special forms and built-in macros (`let`, `if`, `defn`); the inspector has no actions, and printing a small collection that holds an infinite lazy seq doesn't end (there is no `*print-length*`).
- SLDB (D-084): no frame locals; restarts with parameters can't be invoked from either debugger (restarts would need a way to ask for their arguments, like CL's `:interactive`); `:emacs-interrupt` (interrupting a running evaluation) isn't handled, since the runtime can't signal a running fiber.
- The scheduler (D-075): tasks and channels share one lock, and wait queues another, as D-057 had one; with many workers they're contended (the million-message ring test spends most of its time waiting for them, about 4 µs a message on an M-series Mac). Per-channel locks and sharded wait queues would help.
