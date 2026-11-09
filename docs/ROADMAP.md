# Skein Roadmap

Work proceeds **one milestone at a time, in order**, unless a milestone says otherwise. Each milestone has **exit criteria**. A milestone is done only when all of them pass and the status table below is updated.

## Current status

| Milestone | Status |
|---|---|
| M0.1 Repository scaffolding | ✅ |
| M0.2 Reader | ✅ |
| M0.3 Core IR, expander skeleton, CL backend | ✅ |
| M0.4 Persistent collections and seqs | ⬜ |
| M0.5 Macros and `skein.core` | ⬜ |
| M0.6 Conditions and restarts | ⬜ |
| M0.7 Object system | ⬜ |
| M0.8 Declarations, value structs, typed arrays | ⬜ |
| M0.9 Concurrency | ⬜ |
| M0.10 FFI and bindgen | ⬜ |
| M0.11 REPL, reload and dev loop | ⬜ |
| M0.12 Demo game | ⬜ |

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
- Document editor setup for Emacs (SLY) and VS Code (Alive).
- Unhandled errors in the game loop offer `retry-frame` and `skip-frame` restarts.

**Exit:** a recorded manual test: change a function while the demo runs, and the change appears without a restart; cause an error, fix it, choose `retry-frame`, and the game continues.

### M0.12 Demo game
- An Asteroids clone using SDL3, `skein.math`, value structs, a job graph per frame and `defclass` entities.
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
- M0.4: add `##Inf`, `##-Inf` and `##NaN` to the reader and printer when printing of all values lands (D-029). The runtime `pr-str` should reuse `skein.runtime:print-atom`.
- M0.3/M0.5: support `::alias/kw` keywords once namespace aliases exist; the reader needs a way to resolve aliases.
- M0.4: replace the temporary CL-list rest arguments with persistent lists or seqs, and `=` with full value equality (D-031).
- M0.4/M0.5: support collection literals and quoting collections in the expander; they are compile errors until persistent collections exist.
- Dynamic vars: `binding`, and `set!` of a dynamic binding (D-031).
- Arity errors name where the function was defined, not the call site; consider reporting the call site too (M0.6 or M0.11).
- Errors raised inside CL primitives (e.g. `(+ 1 "a")`) have no Skein source location yet; map them to the calling form (M0.6).
- M0.8: calls currently go through `&rest` argument lists and a dispatch on the count; give fixed-arity functions direct CL lambda lists for speed.
- `skein run` looks for required namespaces next to the main file and in the current directory; use `project.skn` `:paths` once it exists.
- Consider `#!` shebang lines so `.skn` files can be executable scripts.
- First shader-using demo: pick shader cross-compilation tooling for the SDL3 GPU API, e.g. SDL_shadercross (D-020).
