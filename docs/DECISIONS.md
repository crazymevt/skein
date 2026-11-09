# Decision Log

Each entry records a decision, the alternatives considered and why. **Never edit a past decision's content; supersede it with a new entry** and mark the old one `Superseded by D-NNN`.

Format:

```
## D-NNN: Title
Date: YYYY-MM-DD · Status: Accepted | Superseded by D-MMM | Proposed
Context / Decision / Alternatives / Consequences
```

---

## D-001: Name the language Skein; source extension `.skn`
Date: 2026-11-09 · Status: Accepted
- **Context:** The language twists three Lisp strands together, and its runtime is built on threads and fibers.
- **Decision:** The language is named **Skein**, and source files use `.skn`.
- **Alternatives:** Spindle (collides with an existing Spindle Lisp DSL that has a Racket package), Braid (collides with a well-known indie game), Plait (collides with Racket's `#lang plait`).
- **Consequences:** Searches should use "Skein lang" or "Skein Lisp" to avoid the Skein hash function. Check `.skn` for clashes before 1.0.

## D-002: Primary use case is desktop apps and games
Date: 2026-11-09 · Status: Accepted
- **Decision:** Optimize the design for games and desktop apps by a solo developer or small team. Servers and numeric work come later.
- **Consequences:** GC pause budgets, value structs, typed arrays, main-thread affinity, job graphs and hot reload get priority. STM and networking are deferred.

## D-003: Dynamic typing with optional declarations
Date: 2026-11-09 · Status: Accepted
- **Decision:** Use the SBCL model: dynamic typing, declarations checked or trusted by policy, local inference and efficiency notes.
- **Alternatives:** Gradual typing as in Typed Racket; a static ML-style type system.
- **Consequences:** Keep the declaration syntax regular enough that an optional checker could be added later.

## D-004: Lisp-1
Date: 2026-11-09 · Status: Accepted
- **Decision:** Functions and variables share one namespace.
- **Alternatives:** Lisp-2, as in Common Lisp.
- **Consequences:** Fits a functional style and higher-order code better. CLOS-style generics still work fine.

## D-005: Clojure reader conventions
Date: 2026-11-09 · Status: Accepted
- **Decision:** Use `[]`, `{}` and `#{}` literals, treat commas as whitespace, use `~` and `~@` for unquote, and make keywords callable.
- **Consequences:** Familiar to Clojure users. Unquote differs from Common Lisp.

## D-006: Only `nil` and `false` are falsy
Date: 2026-11-09 · Status: Accepted (Clojure semantics)

## D-007: Class slots are immutable by default; mutability is opt-in per slot via `:cell`
Date: 2026-11-09 · Status: Accepted
- **Context:** CLOS objects are mutable bags of slots, which conflicts with safe sharing across fibers.
- **Decision:** Slots are immutable by default. `with` creates updated copies. Mutable slots declare `:cell :atom`, `:cell :ref` (deferred) or `:cell :unsynchronized` (owned by one fiber).
- **Consequences:** The compiler knows what's mutable. Instances can be shared across fibers safely unless they have unsynchronized cells.

## D-008: Bootstrap on SBCL (Phase 0)
Date: 2026-11-09 · Status: Accepted
- **Decision:** Prototype Skein as a reader, expander and compiler that emits CL code, running on SBCL. This provides a native compiler, GC, threads, CFFI and an editor REPL from the start.
- **Alternatives:** Start directly on a native compiler; host on Chez Scheme.
- **Consequences:** The front end must be portable to Skein. Phase 0 concurrency uses OS threads, not fibers.

## D-009: Native compiler emits C; cross-compile with `zig cc`; runtime written in Zig
Date: 2026-11-09 · Status: Accepted
- **Decision:** The Phase 1 backend emits C11. `zig cc` cross-compiles to every target.
- **Alternatives:** LLVM (slow builds and harder precise GC), Cranelift, a custom backend.
- **Consequences:** No guaranteed general TCO (see D-010). Fibers need stack switching in the runtime. LLVM stays possible later if C becomes a bottleneck.

## D-010: Guaranteed iteration via `loop`/`recur`; general TCO is best effort
Date: 2026-11-09 · Status: Accepted

## D-011: Conservative stack scanning, precise heap scanning, mostly-copying nursery
Date: 2026-11-09 · Status: Accepted
- **Decision:** Avoid precise stack maps by treating stack words as possible pointers and pinning what they reference, as SBCL's gencgc does.
- **Consequences:** Much simpler with a C backend. There can be slight memory retention from false pointers.

## D-012: Integers are arbitrary precision with a fixnum fast path; `/` on integers returns f64; no ratios
Date: 2026-11-09 · Status: Accepted (open question 7 resolved by D-023; no ratios confirmed by D-026)

## D-013: Macros use `defmacro` plus namespace-resolving syntax-quote; full hygiene is deferred
Date: 2026-11-09 · Status: Accepted
- **Consequences:** Syntax objects carry source locations from day one so scope sets can be added later.

## D-014: Racket-style phase separation, warn-only in Phase 0 and enforced from Phase 1
Date: 2026-11-09 · Status: Accepted

## D-015: Concurrency uses fibers, structured concurrency, channels, atoms and job graphs; STM is deferred
Date: 2026-11-09 · Status: Accepted

## D-016: Phase 0 test framework is FiveAM
Date: 2026-11-09 · Status: Accepted

## D-017: License is MIT
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 1 in DESIGN §22.
- **Decision:** Skein is released under the MIT license. The license text is in `LICENSE` at the repository root.
- **Alternatives:** Apache-2.0 (adds an explicit patent grant, but is longer and is not compatible with GPLv2); dual MIT/Apache-2.0, as Rust does.
- **Consequences:** Contributions are accepted under MIT. Libraries that ship with Skein (the `sdl3` bindings and others) should also use MIT or a compatible permissive license.

## D-018: The native runtime's REPL server speaks Swank
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 2 in DESIGN §22. Phase 0 already uses SBCL's own Swank through SLIME/SLY.
- **Decision:** From Phase 2, the native `skein` runtime runs a Swank-compatible REPL server. SLIME is the reference client.
- **Alternatives:** nREPL (CIDER and Calva support it, but it has no model for the restart-based debugger that is central to Skein's dev loop); a custom protocol plus an LSP server (most work, no existing clients).
- **Consequences:** Swank's debugger (SLDB) maps directly onto Skein's conditions and restarts. The server has to answer requests that use Common Lisp names (`swank:` functions, CL package designators) and translate them to Skein namespaces. SLY uses Slynk, a fork of Swank, so SLY support needs a compatibility check. VS Code support for the native runtime is not covered: Alive now uses its own LSP server, so it will need a Swank-speaking extension or an LSP server, decided in Phase 2. The server listens on localhost only, since Swank has no authentication.

## D-019: Strings index by code point; `count` is O(1) and ASCII strings index in O(1)
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 3 in DESIGN §22. Strings are stored as UTF-8, so finding the n-th code point is O(n) in general.
- **Decision:** String operations (`nth`, `count`, `subs`, `seq`) work in code points. Each string records its code-point count and whether it is pure ASCII when it is created, which is possible because strings are immutable. `count` is always O(1). Indexing is O(1) for ASCII strings and O(n) otherwise. `skein.string` also offers byte-offset cursors (`string/cursor`, `string/next`, …) for parsers and other code that walks non-ASCII text quickly.
- **Alternatives:** Always O(n) indexing (simplest, but slow for the common case of ASCII identifiers and asset names); a cached index of breadcrumbs every K code points, as PyPy does (more memory and runtime code, and only needed if O(n) indexing of non-ASCII strings shows up in profiles); UTF-32 or Python-style flexible storage (wastes memory and makes C interop harder).
- **Consequences:** The breadcrumb index can be added later without changing semantics. In Phase 0 on SBCL, strings are CL strings with O(1) indexing, which gives the same results. The reader must reject surrogate code points, since `char` is a Unicode scalar value.

## D-020: Demos use SDL3 for graphics, including its GPU API
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 4 in DESIGN §22. SDL3 is already the windowing, input and audio-device layer.
- **Decision:** Demos use SDL3 for graphics too: SDL's 2D renderer for simple 2D demos (such as the M0.12 demo) and the SDL3 GPU API for anything that needs shaders.
- **Alternatives:** sokol_gfx (small and portable, but a second library alongside SDL3); wgpu-native (a large Rust build dependency and a fast-moving API).
- **Consequences:** One native dependency covers windows, input and graphics. The SDL3 GPU API backs onto Vulkan, Metal and Direct3D 12, so shaders need cross-compiling (for example with SDL_shadercross); that tooling is decided when a demo first needs shaders. `sokol` and `wgpu` bindings are dropped from the shipped-bindings list.

## D-021: Full hygiene (sets of scopes) lands after Phase 1 self-hosting, in Phase 3
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 5 in DESIGN §22.
- **Decision:** Sets-of-scopes hygiene is implemented in Phase 3, in the self-hosted Skein expander, as ROADMAP Phase 3 already lists.
- **Alternatives:** Before self-hosting, in the Phase 0 CL expander (it would be written twice, once in CL and again when ported, and it would slow down the milestones that validate the rest of the design).
- **Consequences:** Until then, macros rely on namespace-resolving syntax-quote and auto-gensyms (D-013), which in Clojure's experience handle nearly all capture problems. Syntax objects must keep room for scope information so that adding it doesn't change the reader or expander interfaces.

## D-022: Phase 0 persistent collections are our own implementation
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 6 in DESIGN §22.
- **Decision:** Write the persistent vector, HAMT, sets and transients ourselves in CL for Phase 0, rather than wrapping FSet or another library.
- **Alternatives:** Wrap FSet (faster to start, but its algorithms and semantics differ from Clojure-style collections and would not port to the native runtime).
- **Consequences:** M0.4 is larger, but the algorithms, tests and benchmarks port directly to the native runtime. Randomized tests against reference models are required (CLAUDE.md §5).

## D-023: Generic integer arithmetic always promotes to bignum, at every policy
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 7 in DESIGN §22, raised by D-012.
- **Decision:** Arithmetic on values typed only as `integer` promotes to a bignum on fixnum overflow at every `speed` and `safety` level, including `speed 3`. Fixnum-only arithmetic happens only when the operands and result are declared or inferred as `fixnum` or a machine integer type (`i64`, `i32`, …). Overflow of those follows the safety policy in DESIGN §12.3.
- **Alternatives:** Make fixnum-only arithmetic the default at `speed 3` (faster without declarations, but a program could give different answers in release than in dev).
- **Consequences:** Release builds compute the same values as dev builds. Fast integer loops need declarations, and the efficiency notes at `speed ≥ 2` point out generic integer arithmetic.

## D-024: Fiber stacks are fixed-size, lazily committed and guarded
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 8 in DESIGN §22.
- **Decision:** Each fiber gets a fixed-size stack region: reserved virtual memory with a guard page, with physical pages committed by the OS only as they are touched. The default reservation is 256 KB, configurable per spawn. Overflowing it signals a `stack-overflow` error in that fiber, which is handled like any other unhandled error (DESIGN §10). Freed stacks are pooled and reused.
- **Alternatives:** Segmented stacks (Go dropped them because of the "hot split" slowdown at segment boundaries, and C code called through the FFI can't grow them); growable copied stacks, as Go uses now (moving a stack requires precise knowledge of every pointer into it, which conflicts with conservative stack scanning (D-011) and the C backend (D-009)).
- **Consequences:** Memory per idle fiber stays small (a few pages), while deep recursion still has room. On 64-bit targets, address space is not a constraint for tens of thousands of fibers. FFI calls into C code that needs a large stack may need a bigger stack on that fiber, or need to run on the worker thread's own stack; this is decided in Phase 2.

## D-025: No `#lang`
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 9 in DESIGN §22. `#lang` was reserved for per-file readers and expanders.
- **Decision:** Skein does not support `#lang`, and the syntax is no longer reserved.
- **Alternatives:** Keep it reserved for Phase 3 or later.
- **Consequences:** Domain-specific languages are written with macros inside ordinary Skein files. One reader and one expander cover all Skein source, which keeps tooling simple.

## D-026: No ratios in v1
Date: 2026-11-09 · Status: Accepted
- **Context:** Open question 10 in DESIGN §22, confirming D-012.
- **Decision:** v1 has no ratio type. `/` on integers returns `f64`.
- **Alternatives:** Ratios as in Common Lisp and Clojure.
- **Consequences:** If a community (for example scientific or exact-arithmetic users) later needs ratios, they come as a separate library type with its own functions. Changing what `/` returns would be a breaking change, so it stays as it is.

## D-027: Phase 0 loads dependencies through Quicklisp; CI pins SBCL 2.5.10
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.1 needs `make test`, `make repl` and the `skein` launchers to find FiveAM and the other allowed libraries on macOS, Windows and Linux.
- **Decision:** `host/tools/bootstrap.lisp` loads Quicklisp from `~/quicklisp` (or `QUICKLISP_HOME`), registers `host/skein.asd` with ASDF and loads systems with `ql:quickload`. Batch commands run SBCL with `--no-userinit` so personal init files don't affect results. CI installs the official SBCL 2.5.10 binaries on Linux and Windows and Homebrew's SBCL on macOS.
- **Alternatives:** Vendoring the libraries as git submodules (more to maintain); qlot or ocicl for pinned versions (another tool for every contributor to install).
- **Consequences:** Library versions follow the current Quicklisp dist rather than a lockfile. If that causes breakage, switch to qlot or pin a dist version.
