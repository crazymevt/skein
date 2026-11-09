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

## Phase 1: Native compiler (outline)

To be broken into milestones after the Phase 0 retrospective.

1. Port the front end (reader, expander, IR, analysis) to Skein; it is self-hosted on the Phase 0 implementation.
2. Runtime in Zig: value representation, allocator, nursery GC with conservative stack scanning, old-generation mark-sweep, core data structures, conditions and unwinding, platform layer.
3. C backend: Core IR → C11; compile with `zig cc`.
4. `skein build --target` for the three P0 targets; `skein package`.
5. FFI in the native runtime: direct C calls generated by the C backend.
6. The demo game builds natively for all P0 targets.

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
- Phase 0 retrospective follow-ups (`docs/PHASE0-RETRO.md`): inline keyword access to value-struct fields when the type is known; Skein wording for host condition messages; optionally a saved SBCL core with `skein.core` and big bindings precompiled (startup is 0.74 s, plus 0.8 s for `sdl3.raw`); decide DESIGN §22 questions 11–14.
- `skein.game`: input mapping (DESIGN §21). Driftrock reads SDL's keyboard state directly.
- First shader-using demo: pick shader cross-compilation tooling for the SDL3 GPU API, e.g. SDL_shadercross (D-020).
- FFI: passing and returning structs by value is not supported (D-038). The SDL3 headers bound so far don't need it; CFFI's libffi support (`cffi-libffi`, which needs libffi installed) could add it if a library does.
- bindgen: `long` is assumed to be 64 bits; handle LLP64 (Windows) if a bound library uses `long`. Typedefs of anonymous structs (`typedef struct { ... } X;`) and anonymous members are skipped; add them when a library needs them.
- bindgen: generate `sdl3.raw` for the rest of SDL3 (GPU, audio, gamepad, properties, ...) when the milestones that use them start, and hand-write the idiomatic `sdl3` layer on top.
- FFI callbacks from foreign threads work as SBCL allows; DESIGN §14.3's attach-as-fiber behavior waits for Phase 2.
