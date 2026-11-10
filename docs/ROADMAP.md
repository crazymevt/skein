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
| M1.10 Native FFI | ⬜ |
| M1.11 `skein build` and `skein package` | ⬜ |
| M1.12 Driftrock native | ⬜ |

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

**Exit:** `examples/sdl/window.skn` runs natively on all three platforms.

### M1.11 `skein build` and `skein package`
- `skein build --target T --profile P` cross-compiles for the three P0 targets (§19.1); `skein package` makes a folder with the executable, bundled libraries and assets (§19.4). `project.skn` (§20.2) supplies `:main`, `:paths` and `:native`.

**Exit:** from one machine, packaged `hello` builds for all three targets run on their platforms in CI.

### M1.12 Driftrock native
- Build and package Driftrock natively.

**Exit:** native Driftrock plays at 60 fps on macOS, Windows and Linux and starts in under 0.1 s. Write `docs/PHASE1-RETRO.md` and update DESIGN.md.

## Phase 2: Native live development (outline)
Fibers and a work-stealing scheduler; channels on fibers; a closure-compiling interpreter for REPL redefinitions; a Swank-compatible REPL server (D-018); hot reload of native code via shared libraries; supervisors and the debugger over the REPL protocol; STM.

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
- `skein run` looks for required namespaces next to the main file and in the current directory; use `project.skn` `:paths` once it exists.
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
  - `declaim` and `defonce` don't compile natively yet (`%declaim`, `%var-bound?`).
  - A program that includes `skein.compiler.env` registers every public var of skein.core.native at startup, and the model copies them into its skein.core.
- The native compiler's driver (D-062): `skeinc` finds the Skein checkout from `SKEIN_HOME` or by looking in the current directory and its parents, and keeps the runtime and the C file in the checkout's `.skein-cache/`. M1.11 should give it an install layout. It doesn't support `--target` yet.
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
  - Redefining a class affects new instances only; existing ones keep their layout, and `update-instance-for-redefined-class` isn't called.
  - Slot `:type`s aren't checked natively yet.
  - Every generic function call allocates its cache key. An inline cache per call site would avoid that if dispatch shows up in profiles.
  - Built-in classes print with Skein's names (`integer`, `string`), not Phase 0's CL ones (`fixnum`, `simple-character-string`).
- Native multiple values (D-053):
  - A runtime function that calls compiled code (`reduce`, `apply`, lazy seqs) passes on whatever values that code's last call left. `apply` does so on purpose, as in CL. For `reduce`, in the rare case of a reducing function that returns several values, the caller sees them instead of one value.
- Native conditions (D-047):
  - No top-level `abort`/`continue`/`exit` restarts exist natively; Phase 0's come from `skein run` and SBCL.
  - A condition type named by a symbol at run time (`(error 'foo)`) is found by its unique unqualified name, until namespaces exist at run time (M1.8).
  - Some native messages differ from Phase 0's, where Phase 0 shows CL's wording (index errors, returning to an exited block).
  - M1.10 (native FFI) must decide what unwinding through foreign C frames does, as in a Skein callback that signals into a `handler-case` outside the C call. longjmp skips foreign cleanups on POSIX and needs unwind tables on Windows.
