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
| M2.7 Swank server | ✅ |
| M2.8 Supervisors | ✅ |
| M2.9 Hot reload of compiled code | ✅ |
| M2.10 STM | ✅ |
| M2.11 Standard library | ✅ |
| M2.12 Package management | ✅ |
| M2.13 FFI additions | ✅ |
| M2.14 UI library | ✅ |
| M2.15 Driftrock developed live, natively | ✅ |
| M2.16 skein-ui on Windows | ⬜ |
| M3.1 Processes | ✅ |
| M3.2 Data formats and bytes | ✅ |
| M3.3 Regular expressions | 🟨 |
| M3.4 Networking and the Swank client | ⬜ |
| M3.5 Files and the system | ⬜ |
| M3.6 skein-ui for the IDE | ⬜ |
| M3.7 Skein Studio's core | ⬜ |
| M3.8 Agents | ⬜ |
| M3.9 Source control | ⬜ |
| M3.10 C sources in projects | ⬜ |
| M3.11 SQLite and the Databases view | ⬜ |
| M3.12 The terminal | ⬜ |
| M3.13 Markdown and documentation | ⬜ |
| M3.14 HTTP and the API workbench | ⬜ |
| M3.15 Shipping Skein Studio | ⬜ |

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

**Order (D-072):** the riskiest part first, as in Phase 1: fibers and the scheduler (M2.2–M2.4), on which the debugger and REPL depend. Then evaluating code in a native program and the REPL (M2.5–M2.7), supervisors (M2.8), hot reload of compiled code (M2.9), STM (M2.10), the standard library (M2.11, D-089), package management (M2.12, D-085), the FFI additions and UI library that desktop apps need (M2.13–M2.14, D-090), Driftrock developed live (M2.15), and skein-ui's Windows backend (M2.16, D-101), which waits for Jessie to work on Windows.

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
  4. ✅ `editors/skein-slime.el`, `docs/EDITORS.md`, and the scripted SLIME session in the Linux CI job (D-087).

**Exit:** a scripted SLIME session against native `skein dev` passes in CI.

### M2.8 Supervisors
- Unhandled errors go to the fiber's supervisor: in development the root supervisor opens the debugger; in release builds the policies `:cancel-siblings`, `:restart-fiber`, `:ignore` and `:crash` apply (DESIGN §10).
- Steps, in order (D-088):
  1. ✅ The debugger for tasks: in `skein dev`, an error that no handler in a task (spawned or `future`) handles opens the debugger in the task's fiber before the task fails, in the text REPL or SLDB as the main fiber's errors do, with an `abort` restart that fails the task. Fixing the code and choosing another restart resumes the task. Native dev fixtures and a Swank host test.
  2. ✅ Policies: `(with-nursery [n {:on-error p}] ...)`, where `p` is `:cancel-siblings` (the default, as today), `:ignore` (the task fails alone, with one line on stderr), `:crash` (report the error as an unhandled one and exit with status 1) or `:restart-fiber` (run the task's function again from the start, at most `:max-restarts` 3 times within `:within` 5 seconds, then fail as `:cancel-siblings`). In `skein dev` a policy applies once the debugger's `abort` fails the task. Native fixtures for each policy, on all three platforms.
  3. ✅ DESIGN §10 and §13 brought up to date with what was built; `skein.jobs` and `skein.game` checked against the policies.

**Exit:** each policy is tested natively.

### M2.9 Hot reload of compiled code
- `skein dev` compiles a changed namespace to a shared library and loads it into the running program, rebinding its vars; changing a value struct's layout warns about code and arrays compiled against the old one (DESIGN §15).
- Steps, in order (D-091):
  1. ✅ Loading compiled code: a program built with `--eval` includes the C backend, translates a namespace from its live model to C as a module (the program's init and body as an exported init function, its vars found by name), has `zig cc` build a shared library from it, and loads it (`dlopen`, `LoadLibrary`), which rebinds the namespace's vars to compiled code. Executables export the runtime's functions for modules, on all three platforms (on Windows through an import library). Native tests: a reloaded namespace's functions are compiled, callers see them, `defonce` keeps its value.
  2. ✅ `skein dev` and `reload`: a saved file is evaluated at once, as now (`; reloaded x.skn`), then compiled in the background and swapped in (`; compiled x.skn`); `(reload 'ns)` does the same. A compile error is reported and the evaluated code stays. Changing a value struct's layout warns about compiled code and live arrays that use the old one. Forms from the REPL and SLIME stay evaluated until their file is saved.
  3. ✅ Fast enough: the module build reuses the runtime's headers and flags and compiles one namespace in well under a second; a CI step on all three platforms edits Driftrock while it plays (`--autopilot --check-60fps`) and checks that the change runs compiled within a second of saving, without a dropped frame.

**Exit:** an edit to Driftrock is running as compiled code within a second of saving, without a dropped frame, on all three platforms.

### M2.10 STM
- Refs with `dosync`, `alter`, `commute` and `ensure`, and `:cell :ref` slots (DESIGN §13.3).
- Steps, in order (D-092):
  1. ✅ Refs and transactions in the runtime: `ref`, `deref` (a transaction sees its own consistent view), `dosync`, `alter`, `ref-set`, `commute`, `ensure` and `io!`. Serializable: a global version clock, each ref's version and lock word, reads validated at commit, writes buffered and applied under short locks, commutes applied at commit; a conflict retries the body, yielding the fiber with backoff, up to 10,000 times, then signals an error. A nested `dosync` joins the outer one; an error abandons the transaction. Inside a transaction `io!`, channel operations, `sleep` and `on-main-thread` signal an error. Native tests: randomized transactions against a sequential model, and a concurrent transfer test that keeps its total.
  2. ✅ `:cell :ref` slots: reading the slot reads the ref (inside a transaction, its view), `set-slot!` and `update-slot!` inside `dosync` are `ref-set` and `alter`, and `(cell obj :k)` gives the ref; outside a transaction they signal an error. Class redefinition keeps the refs.
  3. ✅ `retry-transaction`: `dosync` establishes a restart that runs the body again from the start, which the debugger offers in `skein dev` (fix the code, then retry); nothing a transaction wrote is visible before it commits. DESIGN §8 and §13.3 brought up to date.

**Exit:** randomized tests against a model, and a concurrent transfer test that keeps its total, pass natively.

### M2.11 Standard library
- Fill the gaps in `skein.core` and start the namespaces DESIGN §21 lists but nobody began (D-089), natively and in Skein where possible, with docstrings and argument lists for SLIME.
- Parts:
  - **`skein.core`:** the missing Clojure functions and macros: `cond->`, `cond->>`, `condp`, `when-first`, `lazy-cat`, `time`, `with-out-str`; `partition-by`, `take-nth`, `take-last`, `drop-last`, `keep-indexed`, `reductions`, `tree-seq`, `shuffle`, `rand-nth`, `subvec`, `rseq`, `update-vals`, `update-keys`, `run!`, `distinct?`; `some-fn`, `every-pred`, `memoize`, `trampoline`, `max-key`, `min-key`; `delay`/`force`, `promise`/`deliver`, `volatile!`, watches and validators on atoms, `swap-vals!`, `reset-vals!`; sorted maps and sets; `parse-double`, `parse-boolean`, `int?`, `pos-int?`, `nat-int?`, `double?`, `hash`, `random-uuid`, the `bit-` operations; `format`, `prn-str`, `print-str`, `read-string`, `slurp`, `spit`; and `*print-length*`, so printing an infinite seq ends.
  - **`skein.string`:** `split`, `join`, `upper-case`, `lower-case`, `trim`, `starts-with?`, `ends-with?`, `includes?`, `index-of`, `replace`, `blank?`, a string builder, and D-019's byte-offset cursors (`cursor`, `next`, ...), which the reader and the Swank server then use (ROADMAP's note on non-ASCII text).
  - **`skein.io`:** directory listing, path helpers (join, file name, directory, extension, absolute path), bytes, and streams. **`skein.log`:** leveled logging.
  - **`skein.test`:** `deftest`, `is`, `testing` and fixtures (DESIGN §20.3), and a `skein test` command.
- Settled (D-093): collections and symbols carry metadata (`meta`, `with-meta`, `vary-meta`); `ex-info`, `ex-data` and `ex-message` over conditions; docstrings and argument lists for the runtime's Zig functions from a table in Skein.
- Steps, in order (D-093):
  1. ✅ `skein.test` (`deftest`, `is`, `testing`, `are`, fixtures, reports) and `skein test`, which runs a project's tests natively; the later steps' tests use it.
  2. ✅ `skein.string`, with D-019's byte-offset cursors and a string builder; the reader and the Swank server use the cursors (the note on non-ASCII text).
  3. ✅ `skein.core`'s macros and seq and function helpers: `cond->` ... `with-out-str`, `partition-by` ... `distinct?`, `some-fn` ... `min-key`.
  4. ✅ Numbers and printing: parsing, predicates, `hash`, `random-uuid`, the `bit-` operations, `format`, `prn-str`, `print-str`, `read-string`, `slurp`, `spit`, and `*print-length*`.
  5. ✅ References and collections: `delay`/`force`, `promise`/`deliver`, `volatile!`, watches and validators on atoms and refs, `swap-vals!`, `reset-vals!`, and sorted maps and sets (randomized tests against a model).
  6. ✅ Metadata on collections and symbols, and `ex-info`, `ex-data` and `ex-message`.
  7. ✅ `skein.io` (directories, paths, bytes, streams) and `skein.log`.
  8. ✅ Docstrings and argument lists for the runtime's Zig functions, which `--eval` builds register for SLIME and describe.

**Exit:** every function and macro above exists natively with tests (randomized against a model where it fits), the Phase 0 host has the ones that fixtures compare with it, and `skein test` runs a project's tests on all three platforms.

### M2.12 Package management
- `project.skn`'s `:deps` (DESIGN §20.2, D-085): a project uses libraries from git repositories, GitHub's included, pinned to a tag or a commit, and from local files and folders. `skein build`, `run`, `dev` and `package` find their namespaces; a library's `:native` libraries and `:assets` go into packages.
- Settled (D-094): `{:git url :tag t}`, `{:git url :sha s}` or `{:local "folder"}`, a local folder with or without its own `project.skn`; fetched with the `git` command into a user-level cache, one checkout per commit; `skein.lock` pins commits; builds fetch only what is missing and work offline from the cache; `skein deps` and `skein deps update [lib]`; transitive `:deps` followed, two versions of one library an error unless the project names it.
- Steps, in order (D-094):
  1. ✅ Reading `:deps` and resolving local folders, transitively, with the conflict rule: the project's source paths, `:native` libraries and `:assets` grow by its dependencies' in `build`, `run`, `dev`, `test` and `package`.
  2. ✅ Git dependencies: the cache, fetching and checking out with `git`, `:tag` and `:sha`, and `skein deps`; tests with local repositories made by `git`.
  3. ✅ `skein.lock`: written when dependencies are first resolved, used after, and rewritten by `skein deps update [lib]`; offline builds from the cache; clear errors when git is missing or a fetch fails.
  4. ✅ Transitive git dependencies with the conflict rule, and packages carrying dependencies' native libraries and assets, on all three platforms; a dependency on a public GitHub repository in CI: the SDL3 bindings, moved to crazymevt/skein-sdl3 (D-095), which the SDL examples and Driftrock depend on.

**Exit:** a project that depends on a library in a git repository (a local repository in the tests, and one on GitHub in CI) and on a local folder builds, runs with `skein run` and `skein dev`, and packages with its dependencies' native libraries and assets, on all three platforms.

### M2.13 FFI additions
- What native desktop UIs need from `skein.ffi` (DESIGN §14, D-090), natively: structs and unions **by value** as arguments and results, of C functions and of callbacks; **calling a C function pointer** with a declared signature (Objective-C's `objc_msgSend` with each message's own signature, COM vtables); and **variadic** C functions, called with the types of each call. `skein bindgen` stops skipping by-value structs and variadic functions.
- Settled (D-096): a by-value struct or union argument takes a pointer or a map of its fields, and a result is an owned pointer to a copy; `(ffi/defcfun-ptr name return [params])` calls a function pointer given as the first argument, and `defcfun` may bind one C symbol under several signatures (`objc_msgSend`); a variadic function is declared once per call shape, with `&` before the variadic parameters; native only, Phase 0 unchanged.
- Steps, in order (D-096):
  1. ✅ Structs and unions by value as `defcfun` arguments (a pointer or a map, nested maps for nested structs) and results (an owned pointer to a copy), in the C backend; native fixtures with a small C library, including structs C passes in registers and ones it passes in memory.
  2. ✅ By value in callbacks: `defcallback` parameters (as owned pointers) and results (a pointer or a map).
  3. ✅ `defcfun-ptr`, and one C symbol under several names with different signatures.
  4. ✅ Variadic shapes with `&`, including floats and small integers that C promotes.
  5. ✅ `skein bindgen` emits by-value structs and variadic functions; skein-sdl3 is regenerated and tagged v0.2.0, and the examples' locks move to it; all of it on the three platforms in CI.

**Exit:** native tests pass structs by value to and from C functions and callbacks, call through function pointers and call variadic functions, on all three platforms, and the SDL3 bindings (crazymevt/skein-sdl3, D-095) are regenerated with the declarations that were skipped.

### M2.14 UI library
- `skein.ui`: native desktop user interfaces from Skein objects and events (D-090), in its own repository, `skein-ui`, which programs use with `:deps` (D-097). Widgets are classes backed by the platform's own controls, so programs look and behave as their users expect (native controls, dark mode, accessibility, standard menus and dialogs). Properties are cell slots, read with keywords and changed with `set-slot!` and `update-slot!`; events are objects that handlers connected with `on` and methods on `handle-event` receive, some of them vetoable (a window close); layout is boxes and grids with expansion, alignment and margins; menus with shortcuts, the platform's alerts and file choosers, timers and the clipboard. Calls from any fiber are handed to the UI thread, so a window can be built and changed from the REPL or SLIME while the program runs.
- Backends: Cocoa on macOS (AppKit through the Objective-C runtime), Win32 and Common Controls on Windows, GTK 4 on Linux, and a headless one for tests. Namespaces `skein.ui` (objects, events, layout, the backend protocol), `skein.ui.headless`, `skein.ui.cocoa`, `skein.ui.win32` and `skein.ui.gtk`.
- It is a port of the design of Jessie's Common Lisp toolkit (LGT), written for Skein rather than translated line by line, with LGT's whole widget set, the web view included (D-097).
- Settled (D-097): its own repository; LGT's widgets but the web view; properties as cell slots; `on` handlers and `handle-event` methods; skein-ui's CI checks out Skein's main branch and bootstraps it; headless first, then one backend at a time.
- Steps, in order (D-097), in skein-ui:
  1. ✅ The repository: a library `project.skn`, CI on the three platforms that checks out Skein's main and runs `skein test`; the core: the widget class, properties as cell slots with `property-changed`, events (`on`, `off`, `handle-event`, vetoes), the backend protocol, the headless backend, and `ui` to build trees of widgets.
  2. ✅ Layout (boxes and grids: expansion, alignment, margins, spacing) and the simple controls (labels, buttons, toggles and checks, radio buttons, entries, sliders, spin buttons, progress bars and spinners, combo boxes, images, frames), on the headless backend.
  3. ✅ The rest of the widgets on the headless backend: the text view, list boxes, sortable tables, trees, color and date pickers, tabs, split panes, scrolled windows, the canvas and drawing; menus, alerts, file choosers, timers and the clipboard.
  4. ✅ The Cocoa backend (AppKit through the Objective-C runtime, with M2.13's by-value structs and `objc_msgSend` shapes), and calls from any fiber handed to the main thread.
  5. ✅ The GTK 4 backend, in Linux CI under Xvfb (before Win32, since GTK 4 also runs on macOS, where it is developed; D-097).
  6. ✅ The rest of LGT, the web view included, on the headless, Cocoa and GTK 4 backends, then LGT's examples and widget explorer, ported to skein-ui's `examples/` with a launcher, each built by a test on the headless backend (Jessie's: the missing parts first, so the examples are faithful). In parts:
     - ✅ A. Every widget's font, context menu, focus and input events (keys, text input, mouse), labels' text and background colors, user data; windows' position, size limits, resizability, `:closed`, hiding, centering, modal runs and snapshots; the application's name, version, icon, menu bar and quitting when the last window closes; blocking handlers.
     - ✅ B. Appearance (light, dark, inherited), color palettes, control sizes and surface roles.
     - ✅ C. Stacks (with a page list or sidebar) and tabbed panes (closable, reorderable and draggable tabs, accessories).
     - ✅ D. Surfaces: popovers, completion popups and custom dialogs (`run-dialog`, `respond`).
     - ✅ E. Text buffers (undo, redo, positions) and code views (line numbers, styles, selections).
     - ✅ F. Images from bytes, system and glyph images, font families and font files, and icons in lists, tables and trees.
     - ✅ G. Window state: saving and restoring a window's frame.
     - ✅ H. The web view (Jessie's: a program of Jessie's needs it): WKWebView on Cocoa, WebKitGTK 6.0 on GTK 4 (Linux only: Homebrew has no WebKitGTK), and WebView2 with the Win32 backend; loading URLs and HTML, running scripts, messages between the page and Skein, and navigation events.
     - ✅ I. The examples and the widget explorer, all of LGT's.
  7. The Win32 backend and the demo moved to M2.16 (D-101).

**Exit:** the core's tests pass on the headless backend on all three platforms, and the Cocoa and GTK 4 backends' tests and the examples' in skein-ui's CI (GTK under Xvfb on Linux). The demo on three backends moved to M2.16 with the Win32 backend (D-101).

### M2.15 Driftrock developed live, natively
- Develop and debug Driftrock with native `skein dev` and SLIME: fix a crash in the debugger and resume, edit while playing, reload compiled code.
- Settled (D-101): a task's debugger also offers the restarts of the fiber that spawned it, so a crash in one of Driftrock's jobs is fixed and resumed with `retry-frame` in one debugger; `run-loop` keeps the window alive while a frame waits in the debugger (`:paused`); the exit is scripted sessions in CI plus Jessie's own session with SLIME on her Mac.
- Steps, in order (D-101):
  1. ✅ Dependable CI for live development: an error in a task while another debug session is ending waits for the console instead of failing at once (`dev-task-errors-natively` fails now and then on Linux); the live-edit check judges the median of three edits against its 1 s limit, since a shared macOS runner took 1.02 s and 1.24 s now and then (Jessie's choice); a first module after `skein dev` starts doesn't pay for an empty zig cache (1.7 s); retries for CI's apt installs.
  2. ✅ Parent restarts: in a program with the debugger, a task of a nursery (`spawn`, `skein.jobs` graphs) offers, after its own restarts and before "Fail the task", the restarts that were active in its spawner when it was spawned, which the nursery keeps alive while the task runs, each reported with its fiber. Choosing one fails the task without a second debugger in the spawner, and the spawner invokes that restart once its nursery has ended. In the text REPL and SLDB; native dev fixtures and a Swank host test.
  3. ✅ Paused frames: `run-loop`'s `:paused` (a function called about 60 times a second on the loop's thread while one of its calls waits in the debugger, in its own fiber or in a task it waits for); Driftrock pumps SDL's events in it and presents its last frame, dropping input. A native test, and a check by hand on macOS that the window doesn't show the spinning cursor.
  4. ✅ The scripted session (`host/tools/live-debug.lisp`, on all three platforms in CI): Driftrock under native `skein dev` with `--autopilot`; a bug saved into one of its jobs crashes it; the debugger offers `retry-frame`; the fix is saved and runs compiled; `retry-frame` resumes the game, `:paused` having run meanwhile; the game finishes with no frame over budget after it resumed. M2.9's live edit stays as it is.
  5. ✅ The same through SLIME in Linux CI (`editors/tests/driftrock-session.el`): SLDB for the crash, the fix with `C-c C-c`, `retry-frame`, and the game going on.
  6. ✅ Jessie develops Driftrock live through SLIME on her Mac; what that finds is fixed here.

**Exit:** the scripted sessions pass in CI on all three platforms (through SLIME on Linux), and Jessie develops Driftrock live through SLIME on her Mac.

Steps 4 and 5 passed in CI: the live-debugging session on macOS and Linux in run #121 and on Windows in #118, and the SLIME session on Linux in #121. Phase 2 ends with M2.16, which waits for Jessie to work on Windows.

### M2.16 skein-ui on Windows
- M2.14's last steps (D-101), when Jessie works on Windows (a UTM virtual machine is set up); Phase 3 goes ahead meanwhile (D-102). In skein-ui:
  1. The Win32 backend (Common Controls, GDI+ drawing, task dialogs and the modern file dialogs), and WebView2 for the web view.
  2. The demo (a window with a form, a list, a menu and a dialog) on all three backends in CI, and changed live from SLIME.

**Exit:** one demo program (a window with a form, a list, a menu and a dialog) runs on Cocoa, Win32 and GTK 4 in skein-ui's CI (under Xvfb on Linux), and is changed live from SLIME. Write `docs/PHASE2-RETRO.md` and update DESIGN.md.

## Phase 3: Skein Studio

**Goal:** Skein Studio, an IDE for Skein written in Skein (D-102): Lisp Studio's design on skein-ui, editing Skein with Skein's own reader and driving programs through `skein dev`'s Swank, with AI agents, source control, a terminal, databases, Markdown and offline docs; and the libraries it needs, the general ones in Skein's standard library and the specialized ones in repositories of their own. Then the optimization and polish of the earlier outline.

**Order (D-102):** the libraries first, in the order the IDE needs them (M3.1–M3.6); then the IDE's core (M3.7), and its features one milestone each (M3.8–M3.14), each with the library it needs; then shipping it (M3.15). The optimization and polish milestones follow, or come forward when the IDE needs one.

**Rules for Phase 3**
- Phase 2's rules still apply.
- Skein Studio is in its own repository, `skein-studio`, which uses Skein, skein-ui and the new libraries through `:deps`; its CI checks out Skein's main branch, as skein-ui's does. This repository's ROADMAP tracks its milestones.
- A library that isn't general goes into a repository of its own (as skein-sdl3), not into `lib/`.
- Syntax and names visible in the language (a regex literal, a namespace's name) are settled with Jessie when a milestone is prepared.

### M3.1 Processes
- `skein.io` starts programs without waiting for them: stdin, stdout and stderr as streams that a fiber reads and writes without blocking a worker, line by line or in bytes; the environment and working directory; the pid, the exit status, waiting with a timeout; signals, and stopping a process and what it started (a process group, or the job object on Windows). Programs are found on the `PATH` and started without a shell. What the IDE needs for its inferior programs, the agents' CLIs and git.

- Settled (D-103): a new namespace, `skein.process`, in babashka.process's style: `(process [program arg...] opts)` returns a process whose `:in`, `:out` and `:err` are `skein.io` streams, `@p` waits and gives `{:exit n}`, with `alive?`, `pid`, `destroy!`, `destroy-tree!` and `(signal! p :interrupt|:terminate|:kill)`; options `:dir`, `:env`, `:extra-env`, and `:in`/`:out`/`:err` as `:pipe`, `:inherit`, `:discard` or `{:file path}`, a string `:in` being text to write, with `:err :out`; `@p` through `deref-object`, a core generic that makes `deref` extensible. Native only. `skein.io/run-process` stays.
- Steps, in order (D-103):
  1. ✅ The runtime: starting a program with pipes on Unix and Windows (in a job object), found on the `PATH`, with its directory and environment; its pipes as `skein.io` streams; waiting for it as a blocking call that parks the fiber; its pid and whether it's alive. Native tests with a small Skein program as the child, so they need nothing installed.
  2. ✅ `skein.process`: `process` with its options and redirections, `deref` with a timeout, `alive?`, `pid`, `destroy!`; DESIGN §21 and the docstrings.
  3. ✅ Signals and trees: `signal!` by intent and `destroy-tree!` on the three platforms (descendants from the process table on Unix, the job object on Windows; `:interrupt` not yet on Windows), tested with a child that starts children of its own.
  4. ✅ Many at once: fibers that talk to several programs while others run, a stress test, and a check that nothing leaks (pipes, handles, zombies).

**Exit:** native tests on the three platforms start a program, talk to it over its stdin and stdout from fibers while others run, and stop a process tree.

### M3.2 Data formats and bytes
- `skein.json` (reading and writing, keyword keys, pretty printing that keeps key order, one value per line for streams), an EDN reader in every build (`skein.edn`; today `read-string` needs `--eval`), and bytes: base64, hex, UTF-8 encoding of byte arrays, and SHA-1, SHA-256 and MD5.

- Settled (D-104): `skein.json` in clojure.data.json's shape (`read-str`, `read`, `write-str`, `write`; `:key-fn`, `:value-fn`, `:pretty`, `:escape-unicode`), with `reformat` to re-indent JSON text keeping its keys' order; `skein.edn` in clojure.edn's (`read-string`, `read`; `:readers`, `:default`, `:eof`) in every build; `skein.bytes` (`utf8`, `utf8-string`, `base64`, `unbase64`, `hex`, `unhex`, `sha1`, `sha256`, `md5`). JSON and the bytes are runtime functions in Zig; EDN uses Skein's own reader.
- Steps, in order (D-104):
  1. ✅ `skein.bytes`: UTF-8, base64, hex and the three hashes, as runtime functions; tests against the RFCs' and NIST's test vectors.
  2. ✅ `skein.json`'s reading: `read-str` and `read` (one value from a reader, as a stream-json line), numbers, escapes and surrogate pairs, errors with their place; `:key-fn` and `:value-fn`.
  3. ✅ `skein.json`'s writing: `write-str` and `write`, `:pretty` and `:escape-unicode`, and `reformat`; randomized round trips against a reference model.
  4. ✅ `skein.edn`: `read-string` and `read` from Skein's reader in every build, with `:readers`, `:default` and `:eof`; round trips with `pr-str`, checked against `read-string` in a build with `--eval`.

**Exit:** native tests round-trip JSON and EDN against a reference model, read JSON a line at a time from a process, and check the hashes against published test vectors.

### M3.3 Regular expressions
- A regex engine of Skein's own, compiled natively (D-102): Java's common syntax (classes, groups, named groups, alternation, greedy and lazy quantifiers, anchors, `(?i)` and other flags), and Clojure's functions (`re-pattern`, `re-find`, `re-seq`, `re-matches`, `re-groups`) with `skein.string/replace` and `split` taking a pattern.
- Settled (D-105): Clojure's literal, `#"..."`, and the functions in `skein.core`, as Clojure's. The engine is a backtracking matcher in the runtime; Phase 0 reads the literal, but its regex functions are native only. The reference model is a table generated with Python's `re` over the syntax Java and Python share.
- Steps, in order (D-105):
  1. ✅ The engine in the runtime: parsing Java's common syntax and compiling it, and a backtracking matcher over code points with groups, back references and lookahead; the table of cases (`host/tools/regex-cases.py` and what it writes) and a native test that runs them.
  2. ✅ The pattern type and `skein.core`'s functions: `re-pattern`, `re-find`, `re-seq`, `re-matches`, `re-groups` and `re-matcher` (with `re-find` on a matcher), and printing a pattern as `#"..."`.
  3. ✅ The literal: `#"..."` in Skein's reader and Phase 0's, the printer, and the C backend (a constant compiled at start-up).
  4. ✅ `skein.string`: `replace` and `replace-first` with a pattern (a replacement string with `$1` and `${name}`, or a function of the match) and `split` with a pattern; a benchmark of searching a large file.

**Exit:** native tests against a reference model of the syntax, randomized, and a benchmark of searching a large file.

### M3.4 Networking and the Swank client
- `skein.net`: TCP client sockets (connect, read and write as streams, timeouts) beside the server sockets the REPL uses, now public. A Swank client library (`skein.swank.client`), with the reader and printer of Common Lisp data that `skein.swank` already has: connecting, evaluating, completion, argument lists, the debugger's and inspector's requests, and the events the server sends.

**Exit:** a native test drives `skein dev` through the Swank client: evaluates, completes, gets SLDB's events for an error and invokes a restart.

### M3.5 Files and the system
- Walking a directory tree with ignore rules (`.gitignore`'s), noticing files changed on disk (the platforms' watchers, or polling), temporary files and directories, owner-only permissions; `skein.system`'s per-application data directory (Application Support, AppData, XDG) and opening a file or URL with its default application; ISO-8601 text for `skein.time`'s calendar times, both ways.

**Exit:** native tests on the three platforms.

### M3.6 skein-ui for the IDE
- In skein-ui: a rich text widget for chat and Markdown, built on code-view's styled runs (paragraphs, headings, inline code, links, lists, code blocks, simple tables; D-102); the row of a list, tree or table at a point (`item-at-point`); a text buffer's revision count, for unsaved changes; window snapshots; editing a table's cells; code-view fast enough to highlight a large file as it's edited.

**Exit:** skein-ui's tests for each on the headless, Cocoa and GTK backends.

### M3.7 Skein Studio's core
- The repository, its CI and a launcher; Lisp Studio's workbench on skein-ui: the editor (Skein's reader for highlighting, brackets by depth, indentation by Skein's forms, completion and argument hints), tabs and split editors, the explorer, the command palette, settings and themes, find and find in files; the REPL, debugger, inspector and problems through `skein dev`'s Swank (M3.4), with evaluating and compiling forms and files, and going to definitions. Languages are registered, as Lisp Studio's are.

**Exit:** Skein Studio opens a Skein project, runs it under `skein dev`, and edits, evaluates and debugs it, on macOS and Linux; a scripted session checks it in CI.

### M3.8 Agents
- Claude Code (stream-json) and Codex (app-server, JSON-RPC over stdio) through their CLIs, with the IDE's tools (evaluate in the program, describe, the problems, the open file), approvals and questions, models and effort, as Lisp Studio has.

**Exit:** a scripted session with a stand-in CLI that speaks each protocol; the real CLIs tried by Jessie.

### M3.9 Source control
- git through its CLI: the changes and their diffs, staging, committing, branches, pull and push, and the explorer's status colors.

**Exit:** tests against a scratch repository.

### M3.10 C sources in projects
- `skeinc` compiles the C sources a project lists, with `zig cc`, for each target, so a library can ship SQLite's amalgamation or libvterm rather than prebuilt libraries.

**Exit:** a library with C sources builds and packages on the three platforms.

### M3.11 SQLite and the Databases view
- `skein-sqlite` in its own repository (bindings and an idiomatic layer, with SQLite's amalgamation as its C source); the Databases view: connections, the schema, a query editor and a results grid, editing rows, export.

**Exit:** the library's tests on the three platforms, and the view's in Skein Studio.

### M3.12 The terminal
- `skein-term` in its own repository: a pseudo-terminal (forkpty, ConPTY) and libvterm's emulator, and a skein-ui widget that draws it; the IDE's terminal panel.

**Exit:** a shell runs in the panel on macOS and Linux, with its tests in CI.

### M3.13 Markdown and documentation
- `skein-markdown` (CommonMark and GFM's tables into a tree) shown in the rich text widget (M3.6), with the editor's Source, Split and Preview; `skein-docset` for Dash docsets, searched and shown in the IDE.
- A docset for Skein, built from Skein's own sources rather than downloaded (Jessie's): every public var of the standard library with its argument lists, docstring and source location, from the compiler's model of the namespaces (as Swank's documentation and `M-.` use it), and the language reference from DESIGN.md; generated by a tool in this repository and rebuilt with each release, so it matches the Skein it documents. It is a Dash docset (the SQLite index and HTML pages, so Dash and Zeal open it too), with each entry also kept as data beside the pages (name, argument lists, docstring as Markdown, source location), which Skein Studio shows natively. Libraries (skein-ui and the others) can build theirs the same way.

**Exit:** the CommonMark spec's examples pass; Skein's docset is generated from the checkout and covers every public var; docs open from the editor.

### M3.14 HTTP and the API workbench
- `skein-curl` in its own repository (libcurl: HTTPS, redirects, proxies, streaming bodies); Xeon Studio's API workbench (`.http` collections, environments with secrets, the response view).

**Exit:** tests against a local server on the three platforms.

### M3.15 Shipping Skein Studio
- Packages for macOS, Linux and Windows (once skein-ui has its Win32 backend, M2.16), with code signing and notarization on macOS (D-069's open question); Xeon Studio's further features (docks, inline results, team chat) as far as Jessie wants them.

**Exit:** Skein Studio installs and runs from its package on each platform, and Jessie uses it to work on Skein.

### Later in Phase 3
- The optimization and polish of the earlier outline, in an order to settle then: sealing; inlining across namespaces; escape analysis and arena inference; SIMD for `vec`/`mat`; an optional LLVM backend; full hygienic macros; `skein fmt` (sooner, if the IDE's Format Document needs it); a package registry; a documentation site.

---

## Notes for later
Ideas and follow-ups noticed during work, kept here so they don't derail the current milestone.

- Regex searches (D-105) try the pattern at each position; skipping ahead to a literal first character or prefix (`memchr`, or a substring search) would make searches for words several times faster (bench/README.md).
- `skein.process` (D-103): output a program writes that is never read holds a pipe's descriptor until its stream is closed (stdin and output read to the end are released by themselves), and the process table keeps a small entry per program. Finalizers for runtime handles would let the GC release both, as `ffi/own` pointers are.
- Windows: `skein.process`'s `:interrupt`, `:err :out` and `{:file path :append true}` need Skein's own `CreateProcessW` spawn: with `CREATE_NEW_PROCESS_GROUP`, and the handles given as they are (Zig's spawn reopens a file, which a pipe can't be and an append loses its place in) (D-103); with Windows work (M2.16).
- Programs can't read their own standard input through a public API: the REPL reads the terminal through `%stdin` and `%read-text`. `skein.io` could give stdin, stdout and stderr as streams (`*in*`, or `(io/stdin)`), which a child program of `skein.process` would want; the names need Jessie's OK (M3.1).

- skein-ui step 2 showed two small gaps in Skein itself, left for a decision (a var is declared before its definition with `(def name)`, as Clojure's `declare` does): `skein.math/round`, `floor` and `ceil` return floats for floats, where Clojure's `clojure.math/round` returns an integer (callers write `(int (math/round x))`); and nothing reads a number from bytes (a big-endian `u32` from a `u8` array, as for a PNG header), which binary file formats in games will want. Step 4 showed two more: `skein.core` has no `flush` (Clojure's, for `*out*`) and no `*err*`, so a program can't flush standard output or write to standard error without `skein.log`.
- skein-ui part F (M2.14): Skein's finalizers only free foreign memory (`ffi/own`); a finalizer that runs Skein code (on the UI thread, queued) when an object is collected would let images release their native images by themselves, as LGT's do with trivial-garbage, rather than only through `free-image!`.
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
- Core macros from DESIGN §5.2 that wait on later milestones: `defclass`, `defgeneric`, `defmethod` (M0.7), `defstruct` (M0.8), `with-nursery` (M0.9), `with-open` (built in M2.11 with a `close` generic function), `binding` (dynamic vars).
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
- The Swank server (D-082): `connection-info` reports no process id. (Its reader and the Skein reader walk text by cursors since M2.11, so long non-ASCII text no longer reads in quadratic time.)
- SLIME's names and inspector (D-086): the runtime's functions written in Zig (`str`, `count`, `conj`...) have no argument lists or docstrings; autodoc has nothing for special forms and built-in macros (`let`, `if`, `defn`); the inspector has no actions, and printing a small collection that holds an infinite lazy seq doesn't end (there is no `*print-length*`).
- Hot reload (D-091): `.skein-cache/modules/` keeps every module's C and library; nothing deletes old ones yet.
- SLDB (D-084): no frame locals; restarts with parameters can't be invoked from either debugger (restarts would need a way to ask for their arguments, like CL's `:interactive`); `:emacs-interrupt` (interrupting a running evaluation) isn't handled, since the runtime can't signal a running fiber.
- The scheduler (D-075): tasks and channels share one lock, and wait queues another, as D-057 had one; with many workers they're contended (the million-message ring test spends most of its time waiting for them, about 4 µs a message on an M-series Mac). Per-channel locks and sharded wait queues would help.
- skein.test: run tests in parallel on fibers, as a nursery of tasks with each test's report buffered and printed whole. Opt-in (`skein test --parallel`, `(run-tests {:parallel true} ...)`), since tests sharing atoms or files interfere; namespaces in parallel and a namespace's tests in order (`:once` fixtures assume it); `^:serial` on a namespace or test to opt out. The syntax needs Jessie's OK.
- make test: the Swank and REPL host tests each build their own `--eval` program (about 12 s each, 13 of them); sharing one build per suite would cut Swank, now the longest part, but changes the programs some tests check backtraces of. Compiling the evaluator's C once per skeinc and linking it into each `--eval` program would speed those builds, and `skein run` and `dev`, everywhere.
