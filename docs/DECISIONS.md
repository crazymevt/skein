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

## D-028: Phase 0 value representation and syntax objects
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.2's reader has to produce values before persistent collections exist (M0.4), and Skein's `nil`, `false` and `()` are all distinct.
- **Decision:** In Phase 0, Skein `nil` is CL `NIL` and `true` is CL `T`. `false` is a unique singleton (`skein.runtime:+false+`). Integers, f64, f32, chars and strings are the corresponding CL types. Symbols and keywords are interned structs with an optional namespace, separate from CL symbols. The reader returns syntax objects with a kind (`:atom`, `:list`, `:vector`, `:map`, `:set`), a datum (the atom, or a CL list of child syntax objects), a source location (start and end line and column) and optional metadata (a map syntax object). Compound syntax doesn't need runtime collections; turning syntax into runtime data waits for M0.4.
- **Alternatives:** Represent `false` as CL `NIL` and Skein `nil` as a sentinel (makes nil-punning interop with CL harder); produce runtime collections directly from the reader (blocked on M0.4, and loses per-element locations).
- **Consequences:** Truthiness tests in the CL backend must check for both `NIL` and `+false+`. The empty list `()` is a distinct value from `nil` and needs its own representation in M0.4.

## D-029: Reader literal rules
Date: 2026-11-09 · Status: Accepted (user-visible choices approved by Jessie)
- **Context:** DESIGN §3 says the reader follows Clojure unless noted, but some Clojure behaviors are surprising or conflict with Skein's design.
- **Decision:** Numbers are strict: no leading zeros (no octal), a decimal point needs digits on both sides, and the `f` suffix needs a float literal. Float literals too large for their type are errors, and `##Inf`-style literals wait for M0.4. Type hints accept compound type forms (`^(array f32) xs`). CRLF inside string literals reads as LF. Strings combine `\u` surrogate pairs and reject lone surrogates, since `char` is a Unicode scalar value. The reader expands `#(...)` to `(fn [%1 ...] ...)` using the `%N` names as parameters. Prefix forms other than `quote` expand to `skein.core/`-qualified symbols. The details are in DESIGN §3.1.
- **Alternatives:** Clojure's behavior for each: octal `007`, `5.` as `5.0`, `1e400` as Infinity, symbol-only type hints, and strings kept byte-for-byte.
- **Consequences:** Some valid Clojure literals are read errors in Skein, each with a message that says what to write instead.

## D-030: Phase 0 Core IR is a tree; ANF comes before the C backend
Date: 2026-11-09 · Status: Accepted
- **Context:** DESIGN §16 described Core IR as ANF (A-normal form). The CL backend gains nothing from ANF, since SBCL does its own normalization.
- **Decision:** The expander produces a fully resolved, alpha-renamed tree whose call arguments may be any node (docs/CORE-IR.md). An ANF pass is added in Phase 1, before the C backend.
- **Alternatives:** ANF from the start (more code and harder-to-read output in Phase 0, for no benefit until the C backend).
- **Consequences:** Analysis passes written before Phase 1 must not assume ANF.

## D-031: Phase 0 evaluation model
Date: 2026-11-09 · Status: Accepted (calling convention revised by D-036)
- **Context:** M0.3 needs a concrete way to compile and run Core IR on SBCL, and some semantics that DESIGN leaves to Clojure convention.
- **Decision:**
  - Each top-level form is read, macro-expanded, analyzed, compiled with `compile` and run before the next is read. A top-level `(do ...)` is split into top-level forms, so `ns` affects the forms after it.
  - `def` interns its var when the form is expanded, so a function can refer to itself. Referring to a symbol that resolves to nothing is a compile error, as in Clojure. `(def x)` leaves an existing value unchanged.
  - Every global reference reads the var at run time; this is what makes redefinition visible to existing callers.
  - Skein functions are CL closures taking `&rest` arguments and dispatching on the count. Until M0.4, a rest parameter is bound to a CL list (`nil` when empty).
  - A special-form name in operator position always means the special form, even if a local shadows it, as in Clojure.
  - `ns` is a built-in macro that expands to `skein.core/%in-ns`, `%require` and `%refer` calls. A namespace `a.b-c` is loaded from `a/b-c.skn` on `*source-paths*`; a namespace whose file fails to load can be required again.
  - Built-in macros (`ns`, `defn`, `defn-`, `let`, `loop`, `when`, `when-not`, `cond`, `and`, `or`) are CL functions in skein.core vars until M0.5.
- **Alternatives:** compile a whole file at once (breaks `ns` and macro definitions that later forms use); resolve unknown symbols at run time (hides typos until the code runs).
- **Consequences:** Calls cost an `&rest` list and a count dispatch; M0.8 revisits this. Dynamic binding and `set!` of vars are not implemented yet.

## D-032: Persistent collections and seqs in Phase 0
Date: 2026-11-09 · Status: Accepted (lazy-seq realization and metadata approved by Jessie)
- **Context:** M0.4 implements DESIGN §6.2 and §7. Some details are not fixed by DESIGN or differ from Clojure.
- **Decision:**
  - Lazy seqs are realized one element at a time; there is no chunking. `(first (map f xs))` calls `f` once.
  - Collections carry no runtime metadata (`with-meta`, `meta`); metadata stays on syntax. Quoting a form drops its metadata.
  - `f32` and `f64` values are `=` when numerically equal, and hash alike. Integers and floats are never `=`. NaN is not `=` to itself.
  - Map entries are two-element vectors. Calling a keyword on a value that isn't a collection returns `nil`, as `get` does.
  - Hashes are 32-bit. Integers hash by folding their 32-bit chunks, so values like `a * (2^32 + 1)` collide; collision nodes keep them correct. The tests use these keys to exercise collision handling.
  - The vector, HAMT and transient algorithms follow Clojure's PersistentVector and PersistentHashMap, with one code path for persistent and transient updates (edit tokens). Maps of up to 8 entries are array maps, and transient maps keep that representation while small, so small maps built with `into` keep insertion order. There is no ArrayNode.
  - A transient records its owning thread and signals `transient-error` when used from another thread or after `persistent!`.
  - Vector, map and set literals whose elements are constants are built at compile time.
  - The seq library and transducers are written in CL for Phase 0 speed, using a closed set of seq types; `seq` dispatches with `typecase`. Class-based extension arrives with the object system (M0.7).
  - The reader and printer support `##Inf`, `##-Inf` and `##NaN` (completing D-029).
- **Alternatives:** Clojure-style 32-element chunked seqs (faster lazy pipelines, but side effects run ahead); runtime metadata as in Clojure; writing the seq library in Skein now (portable, but slow until M0.8).
- **Consequences:** Lazy pipelines are slower than Clojure's chunked ones; transducers are the fast path (`bench/README.md`). The seq library has to be ported or rewritten for the native runtime.

## D-033: Macros see plain data; phase rules for macro helpers
Date: 2026-11-09 · Status: Accepted (both choices approved by Jessie). Revises DESIGN §11.1 and §4.4.
- **Context:** DESIGN §11.1 said `defmacro` "receives syntax objects and returns syntax". That would make ordinary Clojure macros (using `first`, `seq?`, `symbol?` on their arguments) need syntax accessors. DESIGN §4.4 required every function a macro calls to come from a namespace required for syntax, which rules out helper functions defined next to the macro.
- **Decision:**
  - Macros written in Skein receive and return plain data. Before calling a macro, the expander converts its form to data, giving each symbol and collection a fresh identity and recording the syntax it came from in a table. Afterwards, any object the macro passed through unchanged gets its original syntax back, so locations and metadata (`^:private`, `^i32`, `^:mutable`) survive; new forms get the macro call's location. Symbols therefore compare by value, not identity.
  - Errors a macro signals without a location are reported at the macro call. Macro arity errors give the user's argument count, without `&form` and `&env`.
  - Syntax-quote is expanded by the expander, not the reader, in the namespace where it appears: special forms and `&` stay unqualified, aliases are resolved, other symbols are qualified with their var's namespace or the current one, and `x#` names are replaced consistently within one syntax-quote.
  - During expansion, a macro defined in namespace M may use vars from `skein.core`, from M itself, and from M's `:require-for-syntax` namespaces and everything they require. Other uses produce a `phase-warning`, once per macro and var, at the macro call's location. The check runs in `var-get` only while a macro is running.
  - `ns`, `defmacro`, `defn` and `defn-` stay built into the host to bootstrap `lib/skein/core.skn`, which defines the other core macros in Skein and loads when the system loads.
  - Destructuring is a front-end function, `skein.core/destructure`, used by the `let`, `loop`, `doseq` and `for` macros; the `fn` special form destructures parameters by wrapping its body in `let`.
- **Alternatives:** Racket-style macros over syntax objects with explicit accessors; strict phase rules that require helper functions to live in a separate namespace.
- **Consequences:** Clojure macros port with little change. Hygienic `define-syntax` (Phase 3) will work on syntax objects alongside `defmacro`. The native compiler must instantiate a macro's namespace (its earlier forms) at compile time, as Clojure's compiler does.

## D-034: Conditions and restarts on the CL condition system
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.6 implements DESIGN §10, which fixes the semantics but not every detail of the surface syntax or the Phase 0 representation.
- **Decision:**
  - A Skein condition type is a runtime object wrapping a CL condition class; `defcondition` creates or redefines the class at run time. Handlers match with `typep`, so host errors (division by zero, type errors) are Skein conditions too.
  - `defcondition` takes `[parents]`, slots `(name :reader f :initform expr)` and an optional `(:report f)`; parents default to `[condition]`. Slots can be read with keywords. Unknown initargs are errors.
  - `error`, `signal` and `warn` accept a condition, a type, a symbol naming a type, or a message string. Message arguments are joined with spaces, like `println`. A message given to `signal` makes a plain (non-error) condition, as in CL. A quoted type name is looked up in the current namespace, then globally if only one namespace defines it; passing the type itself (`(error asset-missing ...)`) always works.
  - `handler-case` clauses are `(type [c] body...)`; `try` uses Clojure's `catch`/`finally`. `handler-case`, `try` and `restart-case` are macros in `lib/skein/core.skn` over `block*`, `return-from*`, `handler-bind*` and `restart-bind*`.
  - Restart names are symbols, mapped to CL symbols in the `SKEIN-RESTARTS` package. Because SBCL allocates restarts on the stack, Skein code only ever sees copies (name and report); using one after its `restart-case` has exited is a Skein error rather than a crash.
  - `skein run` detects unhandled errors through SBCL's debugger hook, not a catch-all handler, so signals and handlers inside the program behave exactly as they would at a REPL; it prints the message and the restarts active at that point. The launchers call the CLI after loading, so SBCL adds no load context to messages.
- **Alternatives:** One CL condition class holding a Skein map (simpler redefinition, but handlers would need custom matching and host errors would not fit); CL-style format strings in `error`.
- **Consequences:** M0.7 should fold condition types into the object system. A Skein REPL (M0.11) can list and invoke the same restarts.

## D-035: The object system on CLOS
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.7 implements DESIGN §8 on CLOS via closer-mop. Some details are open, and `:cell :atom` slots need atoms, which were planned for M0.9.
- **Decision:**
  - Skein classes use the metaclass `skein-class`, whose class precedence list is computed with C3; inconsistent hierarchies are errors. Superclasses must be Skein classes.
  - Slots are CLOS slots holding immutable values, atoms (`:cell :atom`) or plain values (`:cell :unsynchronized`). `make` fills every slot itself (initargs, then `:init`), records the creating thread as the owner, and calls the generic function `initialize`. Only the owner may `set!` an `:unsynchronized` slot; other slot kinds cannot be set.
  - Generic functions are CLOS generic functions. A method is a Skein function that receives `call-next-method` and `next-method?` before its own parameters; a small CL method created with `ensure-method` passes them in. Standard method combination and eql specializers come from CLOS.
  - Specializer names are resolved as class names (built-in names first, then vars holding classes or condition types), because names like `vector` and `list` are also functions. Abstract base structs were added so methods can dispatch on any map, list or seq.
  - `equiv` and `hash-of` are generic functions. Runtime equality and hashing call them only for instances whose class has a more specific method (cached per class); otherwise instances compare by identity. A warning at the end of each loaded file flags classes that specialize only one of the two.
  - Redefinition relies on CLOS's instance updating. When a slot only changes between immutable and `:atom`, the class forces an update; values are then wrapped or unwrapped, and the Skein generic `update-instance-for-redefined-class` is called.
  - Atoms (`atom`, `swap!`, `reset!`, `compare-and-set!`, `@`) are added now, implemented with compare-and-swap.
- **Alternatives:** A Skein-only object system with its own dispatch (portable to the native runtime, but much more work now, and the roadmap asks for CLOS); resolving specializers as vars (would make `vector` mean the function).
- **Consequences:** The native runtime will need its own dispatch and redefinition machinery that matches this behavior. If an instance is not touched between two class redefinitions, it is updated only once, against the most recent change of cell kinds.

## D-036: Declarations, inlining and value structs in Phase 0
Date: 2026-11-09 · Status: Accepted (record equality, inlining and the deferrals approved by Jessie)
- **Context:** M0.8 must make declared numeric code run within 2× of hand-written SBCL code, and implement DESIGN §9 and §12.
- **Decision:**
  - Skein type specifiers are translated to CL types; `^type` hints, `(declare (type ...))`, return-type hints on parameter vectors and `the` become CL declarations, so SBCL does the type inference. `(declare (optimize ...))` becomes a CL `locally`. Every top-level form is compiled with the dev profile (speed 1, safety 3, debug 2) or, with `skein run --release`, the release profile (speed 3, safety 1, debug 0).
  - Calls to skein.core's arithmetic, comparison, `count`, `sqrt` and array primitives, and to value-struct constructors and accessors, are compiled inline while their var still holds the original function, as Clojure does. Redefining one of them affects only code compiled afterwards. A call to such a primitive with an impossible argument count is a compile-time arity error.
  - Functions take `&optional` parameters with supplied-p flags plus `&rest`, instead of a `&rest` list, so calls allocate nothing (revises D-031).
  - The floating-point invalid-operation trap is masked process-wide, so NaN behaves as IEEE says without per-comparison masking.
  - Value structs and records are CL structs created at run time with typed read-only slots; records compare by their fields. Arrays of value structs keep one specialized array per primitive field. Nested value structs are stored as pointers; `as-bytes` waits for the FFI; overflow at `(safety 0)` is not guaranteed to wrap.
  - Efficiency notes are SBCL's compiler notes, mapped back to the Skein form that produced the CL form and rewritten with Skein type names, shown only for code that declares speed 2 or more.
  - defclass slot `:type`s are checked by `make` and `with`.
- **Alternatives:** A Skein type-inference pass (needed for the C backend, but SBCL already does this well); never inlining core functions (the 2× target would not be met).
- **Consequences:** The n-body benchmark runs at 1.1× the SBCL reference (`bench/README.md`). The C backend will need its own inference and inlining. Threads created in M0.9 must mask the same floating-point trap.

## D-037: Concurrency on a cached thread pool
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.9 implements the DESIGN §13.2 API on OS threads. In Phase 0 a blocking operation blocks its thread, so a fixed-size pool can deadlock when tasks wait for tasks that are still queued.
- **Decision:**
  - Tasks run on a cached pool: a new worker starts whenever none is idle, and idle workers exit after 30 seconds. Every worker masks the floating-point invalid trap (D-036). A task inherits the spawner's namespace, source paths and output streams.
  - Cancellation is cooperative through cancellation scopes: the task itself, enclosing nurseries and `with-timeout` deadlines. Blocking operations wait in 20 ms slices and check them each time. Cancellation is the non-error condition `cancelled`, so ordinary error handlers cannot swallow it; a deadline signals the error `timeout`.
  - `with-nursery` waits for every child. The first child failure cancels the siblings and the body; after the join, that failure is re-signaled in the nursery's thread. A body error, or a cancellation or timeout that arrives while joining, cancels the children, waits for them, and is then re-signaled.
  - Channels use one global lock and wake-up queue, which keeps `alts!` simple. The timeout channel is named `timeout-chan`, because `timeout` names the condition `with-timeout` signals.
  - `on-main-thread` queues work that the main thread runs while it waits on tasks, channels or `sleep`, or when it calls `drain-main-thread!`.
  - `skein.jobs/graph` is written in Skein: it checks the graph, then spawns each job in dependency order into a nursery; a job first waits for the tasks it comes after.
  - The CPU count, used to split `pmap`, `preduce` and `pdotimes`, comes from platform code in `host/src/platform/`.
- **Alternatives:** lparallel's fixed-size kernel (allowed, but it can deadlock on blocking tasks and has its own cancellation model); a thread per task (simpler, but costs a thread creation for every task).
- **Consequences:** Behavior matches DESIGN §13 apart from performance: each blocked task holds a thread, and cancellation of a blocked task takes up to 20 ms. Stress tests repeat each scenario 100 times. Phase 2's fibers replace the pool without changing the API.

## D-038: FFI on CFFI, and bindgen from clang's JSON AST
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.10 implements DESIGN §14 in Phase 0 and generates `sdl3.raw` from the SDL3 headers. DESIGN suggested c2ffi or libclang for the generator; neither is an allowed dependency, and c2ffi must be built from source.
- **Decision:**
  - `skein.ffi` sits on CFFI. `defcfun` resolves its types when it is defined, compiles a wrapper, and looks the C symbol up on the first call, so a missing function is an error at the call site. `bool` is C's one-byte `_Bool`. C `NULL` is `nil` in both directions, also for `c-string`.
  - `(ptr T)` documents what a pointer points to; every pointer is passed the same way. Structs and unions are passed by pointer; by-value struct arguments and results are not supported in Phase 0. Reading a field that holds a struct, union or array returns its address, so it can be read further; writing one is an error.
  - Skein typed arrays, views and byte views (`as-bytes`) passed to C are pinned for the call; `ffi/pin` pins one for longer. `alloc` returns zeroed C memory; `free` and `with-foreign` release it; `^:owned` results and `ffi/own` get a finalizer that calls `free`.
  - C code runs with every float trap masked, as C expects; callbacks re-enable Skein's traps while Skein code runs. A callback that signals an error warns and returns zero, because the error cannot unwind through C frames.
  - In Phase 0 there is no scheduler to hand a worker to (§14.3), so `^:blocking` only marks the call as allowed to take long: unmarked calls slower than 10 ms warn once per function.
  - Libraries load from `SKEIN_LIBRARY_PATH`, then the usual package-manager directories (`/opt/homebrew/lib` and `/usr/local/lib`), then the OS search path.
  - `skein bindgen` runs `clang -Xclang -ast-dump=json` (filtered by the prefix) for declarations and `clang -E -dD` for `#define`s with their files; a second clang pass resolves typedef names from outside the filter, such as `Uint32`. It emits declarations only from the headers named on the command line. Names: types keep the prefix (`sdl-frect`), functions and constants drop it (`create-window`, `init-video`); a name that would collide falls back to the prefixed form. Each enum becomes a `defcenum` plus one integer constant per enumerator, because C structs often store enum values in plain integer fields (`SDL_Event.type`). Object-like macros that evaluate to integer, float or string constants become `def`s; others are skipped. Variadic and inline functions, bit fields, anonymous members and by-value structs are skipped with a comment. `long` is taken to be 64 bits.
- **Alternatives:** c2ffi (an extra tool to build on every platform); libclang through CFFI (needs libclang installed at a known path, and more code); hand-written SDL bindings (do not scale to the GPU API).
- **Consequences:** Regenerating bindings needs clang, but using them does not: the output is committed (`make sdl3-bindings` rebuilds `lib/sdl3/raw.skn`). Generating on Windows, where `long` is 32 bits, would differ for headers that use `long`; SDL3 does not. Phase 1's C backend can keep the same `skein.ffi` surface.

## D-039: Phase 0 REPL, debugger and dev loop
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.11 needs a REPL connected to the running program, reloading, and recovery from errors in the game loop. The roadmap suggested SLY and Alive, but those talk Common Lisp to the SBCL host, and SDL needs the process's main thread, which SLY's REPL doesn't run on. Jessie chose a plain Skein REPL with a socket, and `-main` as the program entry.
- **Decision:**
  - `skein repl` runs a Skein REPL on the terminal. `skein dev file.skn args...` runs the program and serves the same REPL on the terminal and on `localhost:5555` (`--port N`, `--no-server`). The protocol is plain text, with a `namespace=> ` prompt per form, so Clojure tools that speak to socket REPLs (inf-clojure) work. `*1`, `*2`, `*3` and `*e` are skein.core vars, shared by all REPLs in Phase 0.
  - Program entry: `skein run` and `skein dev` load the file, then call its namespace's `-main` with the remaining arguments if it defines one. Reloading re-runs top-level forms but not `-main`, so the game loop belongs in `-main`.
  - `(reload 'ns)` loads a namespace's file again. Vars keep their identity, so callers see the new definitions; definitions removed from the file stay until restart. A namespace remembers the file its `ns` form was loaded from. `skein dev` polls the loaded files every 0.25 s and reloads changed ones on a watcher thread. Expanding and compiling take one global lock, so the program, the watcher and REPLs can load code at the same time.
  - The debugger lists the active Skein restarts, innermost first, numbered: a number invokes one, `:bt` shows the Skein functions on the stack, and any other form is evaluated. An error in a REPL's own thread opens a nested `debug[N]` level there. An error in any other thread (the program, usually its main thread) opens a debug session: the thread waits, a REPL attaches, and the forms typed there are evaluated in the failing thread, in that REPL's namespace, so its restarts can be invoked and its state inspected. With no REPL attached, the error is printed and the program is stopped through its "Stop the program" restart. Errors in spawned tasks still go to their nursery (D-037).
  - `skein.game/run-loop` (options `:frame` and `:running?`) runs each frame inside `with-frame-restarts`, which establishes `retry-frame` and `skip-frame`. M0.12 adds the fixed timestep.
  - In `skein dev` the program and the REPLs write to the terminal through one locked stream, and `print`/`println` write each call's output at once, so lines don't interleave mid-line.
  - `parse-long`, from Clojure, is added to skein.core for command-line arguments.
- **Alternatives:** SLY/Swank in the SBCL host (needs main-thread workarounds for SDL, and speaks CL rather than Skein); nREPL for Calva and CIDER (a bencode protocol and session model, which is more work than Phase 0 needs); suspending only the failing task, which needs Phase 2's fibers.
- **Consequences:** Editor support is plain text over a socket or terminal, documented in `docs/EDITORS.md`. Swank remains the plan for the native runtime (D-018). While the program waits in the debugger its main thread is stopped, so the window doesn't redraw.

## D-040: The demo game and the libraries it needed
Date: 2026-11-09 · Status: Accepted
- **Context:** M0.12 builds the demo game. The roadmap said "an Asteroids clone"; Jessie chose an original game in that genre, Driftrock, with its own name and look. Writing it needed number conversions, trigonometry, random numbers, a clock and `skein.math`, none of which existed. Jessie chose type-named conversions and the whole of `skein.math` from DESIGN §21.
- **Decision:**
  - `f32`, `f64` and `int` (truncating toward zero) convert numbers and are inlined. `rand`, `rand-int` (Clojure's) and `parse-long` (M0.11) join `skein.core`.
  - `skein.math` is mostly Skein source (`lib/skein/math.skn`). The value structs are `vec2`, `vec3`, `vec4`, `quat`, `mat3` and `mat4`, all of `f32`, with generic functions over them. Trigonometry, rounding, `pow`, `exp`, `log` and Perlin `noise` are host functions, inlined like core primitives. Matrices are column-major. Projections produce depth in [0, 1].
  - `skein.time/now` gives monotonic seconds as an `f64`; `now-ns` gives nanoseconds.
  - `skein.game/run-loop` gains `:update` with a fixed `:step` and `:max-steps`, and `:render` with the leftover fraction. The restarts wrap each call, so `retry-frame` repeats only the call that failed, not updates that already succeeded.
  - `skein run` and `skein dev` add the source root implied by the main file's `ns` name to the source paths, so a multi-file program runs from its main file.
  - `instance?` accepts a struct's name (its constructor). Structs and instances print their fields in declared order.
  - Driftrock is `examples/driftrock/`: `defclass` entities with `:atom` cells (moved by a per-update job graph), sparks in a `defsoa`, and drawing through `sdl3.raw`. `--autopilot --frames N --check-60fps` lets CI play it on all three platforms and fail if the 99th-percentile frame misses the 60 fps budget.
- **Alternatives:** Clojure-named conversions (`float`, `double`, `long`); only vectors and scalars in `skein.math` now; restarts around the whole frame (which would repeat updates that already ran).
- **Consequences:** Phase 0's retrospective (`docs/PHASE0-RETRO.md`) measured the game and lists language changes to decide, as DESIGN §22 open questions 11–14.

## D-041: Phase 0 retrospective decisions: slot values, restart names, struct predicates
Date: 2026-11-09 · Status: Accepted
- **Context:** The Phase 0 retrospective (`docs/PHASE0-RETRO.md`) proposed four language changes, DESIGN §22 questions 11–14. Jessie decided them.
- **Decision:**
  - **Slots (11):** reading a cell slot with `(:pos e)`, `slot`, `get` or destructuring gives its current value. `(set-slot! e :k v)` and `(update-slot! e :k f args...)` change a cell slot: atomically for `:atom`, with `update-slot!` retrying like `swap!`, and only from the owning thread for `:unsynchronized`. Both return the new value. `(cell e :k)` returns the atom of an `:atom` slot. `set!` on `(:k e)` now works for `:atom` slots too. Printing shows cell slots' values. This replaces D-035's "a cell slot gives its cell".
  - **Restart names (12):** restarts match by their plain name. `restart-case` and `invoke-restart` ignore a symbol's namespace, so restarts established in syntax-quoted macros need no `~'`, and `restart-name` gives the plain name. As in CL, the innermost restart with a name wins.
  - **Struct predicates (13):** `defstruct` defines `name?`, inlined like the accessors.
  - **Slash (14):** no reader change. `/` stays the namespace separator, and names such as `vdiv` avoid it.
- **Alternatives:** keeping cells visible (explicit, but noisy: about 30 `@`/`swap!` in Driftrock's 500 lines); restarts named by keywords (unambiguous, but every `restart-case` changes); `instance?` as the only type test; allowing `ns/name/` symbols.
- **Consequences:** Code that read `@(:hp s)` now reads `(:hp s)`. The tests, `examples/objects.skn` and Driftrock were updated. Two libraries that both establish a restart called `retry` can no longer be told apart by namespace; the innermost one is used.

## D-042: Phase 1 milestones, native slice first
Date: 2026-11-09 · Status: Accepted
- **Context:** The roadmap left Phase 1 as an outline to break into milestones after the Phase 0 retrospective. Its outline listed porting the front end to Skein first.
- **Decision:** Phase 1 has twelve milestones (ROADMAP). The order is:
  1. a thin end-to-end native slice: the Zig runtime skeleton, then the Phase 0 front end emitting C for a small subset (M1.1–M1.2);
  2. the runtime's hard parts: GC, core data, conditions and unwinding (M1.3–M1.5);
  3. porting the reader and expander to Skein and self-hosting (M1.6–M1.8);
  4. the native library, FFI, build and packaging, and Driftrock (M1.9–M1.12).
  Jessie approved the plan.
- **Alternatives:** porting the front end first, as the outline listed. That defers every native risk (C generation, GC, unwinding on Windows) until after a large port.
- **Consequences:** For most of Phase 1 the C backend is driven by the Phase 0 front end, which stays the reference that native results are tested against. The Zig version, where the persistent collections live (Zig or compiled Skein) and other choices are made as each milestone starts.

## D-043: The Zig runtime skeleton
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.1 starts the native runtime (DESIGN §17–§19). Jessie chose to pin Zig 0.17.1 (the latest stable release), to have CI install Zig from the official archives with checksums, and to install it locally with Homebrew.
- **Decision:**
  - **Layout:**
    - `runtime/` is a Zig package (`build.zig`, `build.zig.zon`, `minimum_zig_version` 0.17.1).
    - `src/` holds the portable runtime: `value.zig`, `object.zig` and `heap.zig`, with `runtime.zig` as the root.
    - `platform/posix/` serves macOS and Linux, and `platform/windows/` serves Windows; `build.zig` picks one as the `platform` module by target OS.
    - The runtime links libc everywhere.
  - **Platform layer:** page size, `reserve`/`commit`/`decommit`/`release` of virtual memory, an OS-backed `Mutex`, `monotonicNanos` and stdout/stderr writes. POSIX uses mmap, mprotect, pthreads and clock_gettime; Windows declares the few kernel32 functions it needs (VirtualAlloc, SRW locks, QueryPerformanceCounter, WriteFile). Platform code does not use `std.Io`, whose API is still changing.
  - **Values:** DESIGN §17.1 is no longer tentative. Fixnums are `n << 2`. Objects are an 8-byte-aligned address plus tag 001. Immediates carry their kind in bits 3–7 and a char's code point in bits 32–52. An f32 sits in the upper 32 bits.
  - **Object header:** one 64-bit word holding a 16-bit type ID, GC bits, a size class, flags and a 24-bit payload length in words. Boxed f64 is the first object type.
  - **Allocation:** each thread bump-allocates in a TLAB carved from 1 MiB chunks, which the heap maps and hands out under its mutex. Objects of 32 KiB and more get their own mapping in the large-object space. Nothing is freed until the GC (M1.3); fresh pages are zero, so payloads start zeroed.
  - **Builds and tests:** `make test` runs the host suites and then `zig build test` in `runtime/`. CI downloads the pinned Zig archive for each OS from ziglang.org, verifies its SHA-256 from Zig's download index, and caches it.
- **Alternatives:** an older Zig (0.16.0); the mlugg/setup-zig action; `std.Io` for clocks and output (the platform layer would follow its churn); separate `macos/` and `linux/` directories (they would duplicate the POSIX code).
- **Consequences:**
  - Windows and Linux builds are cross-compiled locally to catch errors, but they only run in CI.
  - Upgrading Zig means updating `build.zig.zon`, the CI checksums and the README, and re-running everything.
  - Platform-specific behavior beyond these primitives (stack guards, signals, fibers) comes with the milestones that need it.

## D-044: The C backend's first slice
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.2 compiles the first Skein programs natively: Core IR from the Phase 0 front end, turned into C11 and compiled with `zig cc` against the runtime.
- **Decision:**
  - **Emitter:** `skein.backend.c` (`host/src/backend-c/`) emits each IR node as C statements that leave its value in a fresh temporary. That is the ANF step CORE-IR.md planned, done during emission rather than as a separate IR pass. `if` becomes C `if`/`else`. `let` becomes C locals. `loop*` and `recur` become a label and a `goto` after the new values are computed. Nodes the slice doesn't cover are compile errors with the source location and the milestone that adds them: closures over locals and keywords in M1.4, conditions and non-local exits in M1.5, the rest of `skein.core` in M1.9.
  - **Functions** use the calling convention of DESIGN §17.3 (`self`, `argc`, `argv`); `fn` forms become static C functions with a function object made at startup. **Vars** are C globals initialized to `SK_UNBOUND`. Strings, f64s and bignum literals are made once at startup. Fixnums, chars, f32s, `nil` and booleans are C constants.
  - **Primitives:** calls to `skein.core` arithmetic, comparisons, `=`, `inc`/`dec`, predicates and `print`/`println`/`pr`/`prn` compile to runtime calls. `skein.h` inlines their fixnum fast paths on tagged words (overflow promotes to bignum through the runtime). Using a core function as a value is not supported yet.
  - **Runtime C ABI:** `runtime/src/api.zig`, declared in `runtime/include/skein.h`. It adds strings, bignums (on Zig's `std.math.big.int`, limbs stored in heap objects), the number tower with Phase 0's contagion, printing that matches Phase 0 (including SBCL's float format), and function objects.
  - **Compile time:** `skein build` runs `ns` and `defmacro` forms on the host at compile time and compiles everything else. Programs are one file, so requiring another namespace is an error until M1.9. A `-main` is called with no arguments after the top-level forms; a rest parameter is `nil` when there are no extra arguments.
  - **Building:** `zig build` builds the runtime library into `.skein-cache/runtime/<target>-<mode>/` (ReleaseSafe for dev, ReleaseFast for `--release`), then `zig cc -std=c11` links the program against it. `--target` passes a zig target triple.
  - **Errors:** until conditions exist (M1.5), a runtime error prints `error: <message>` (with the location where known) and exits with status 1.
- **Alternatives:** a separate ANF IR pass (more code for the same result now); one C function per arity with dispatch tables (faster calls, more machinery than this slice needs); compiling the runtime from source into each program (slower builds).
- **Consequences:**
  - Native programs are checked against `skein run`: the tests build programs with `skein build`, run them, and compare their output.
  - Natively, float overflow gives infinity where Phase 0 signals an error. Division by zero is an error in both.
  - Mixed integer/float comparisons convert to f64.
  - `fib 32` runs in 0.09 s natively, against 0.79 s for `skein run`, most of which is startup.

## D-045: A mostly-copying generational collector
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.3 builds the runtime's garbage collector to DESIGN §18.1. The C compiler gives no stack maps, so stacks must be scanned conservatively. Objects must be able to move, so the nursery can be compacted.
- **Decision:**
  - **Arena and segments:** the heap is one reserved arena (16 GiB of address space) of 256 KiB segments. A metadata table maps any address to its segment. Free segments are decommitted and come back zeroed. Each nursery segment has a bitmap of object starts.
  - **Minor collections (Bartlett's mostly-copying):**
    - Every thread's stack, from its parked stack pointer to its top, is scanned conservatively after the registers are spilled (`src/spill.c`: `__builtin_unwind_init` and `setjmp`). Any word that points into a young object, even into its middle, pins it.
    - Precise roots are copied into old-generation size-class cells, updating their slots. These roots are registered globals, the remembered set and the children of pinned objects.
    - A segment with pinned objects is promoted whole, with its bitmap rebuilt to list only them; the other nursery segments are freed.
    - Young large objects reachable from anywhere are promoted in place.
  - **Major collections:** a minor collection, then mark-sweep over everything, with an explicit worklist rather than recursion. Size-class cells go back on free lists, emptied segments go back to the OS, and promoted segments keep only marked objects.
  - **Triggers:** a minor collection after 8 MiB of nursery (`SKEIN_NURSERY_SEGMENTS` overrides the count). A major collection when the old generation reaches twice its live size after the last major collection (at least 32 MiB).
  - **Write barrier:** `gc.store` records an old object in the remembered set (once, using a header bit) when a young object is stored into it.
  - **Threads:**
    - Each thread that allocates is a mutator with its own nursery buffer.
    - A collection stops the world: the collecting thread waits until every other mutator is parked at a safepoint or in a blocking call (`gc.blocking`, which spills registers before blocking).
    - Compiled code polls `sk_gc_pending` at function entry and loop back-edges.
    - A thread detaches before exiting.
  - **Object layout:** every object has at least one payload word (for the forwarding address). The header gains a `remembered` bit, and a `tuple` type (all values) serves the tests and later closure environments.
- **Alternatives:** precise stack maps (not available from C); a non-moving collector everywhere (simpler, but fragments and makes allocation slower than bumping); card marking instead of a remembered set (better for heavily mutated old objects; this can change later); stopping threads with signals (more intrusive and platform-specific than polling).
- **Consequences:**
  - The C backend can keep values in ordinary C locals and registers.
  - Every object a stack might point to stays where it is, so runtime code may hold interior pointers across allocations.
  - A conservative collector can't promise to free a particular object, so tests check reclamation in aggregate.
  - A promoted segment keeps its whole 256 KiB until the next major collection (noted in the ROADMAP).
  - The GC is tested with random object graphs against a model, pinning by interior pointers, 200,000-node chains, cycles, large objects, the write barrier, and four threads collecting concurrently, in Debug, ReleaseSafe and ReleaseFast builds.
  - A compiled bignum loop that allocates about 96 MB runs in 21 MB of memory, with pauses under 0.2 ms.

## D-046: Core data in the native runtime
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.4 brings Skein's data to the native runtime: strings, symbols and keywords, vars and namespaces, closures, persistent vectors, maps and sets, transients and atoms. Jessie chose to write the collections in Zig as ports of Phase 0's, rather than in Skein compiled by the C backend.
- **Decision:**
  - **Same hashing as Phase 0.** Phase 0 hashed strings, floats and bignums with SBCL's `sxhash`, which nothing else can reproduce. It now uses portable functions:
    - strings: FNV-1a over the code points, then Murmur3's finalizer;
    - integers of any size: their 32-bit chunks XORed together;
    - floats: the bits of the value as an f64.
    `runtime/src/hash.zig` computes the same values, and a test checks them against values computed by Phase 0. Phase 0's tests all still pass.
  - **Same structures.** `runtime/src/coll.zig` ports Phase 0's vector trie (32-way with a tail), array map (up to 8 entries in insertion order), HAMT (bitmap and collision nodes), sets (maps from each element to itself), transients (edit tokens that record their owner thread) and lists (counted cons cells), algorithm for algorithm. Maps and sets therefore iterate, and print, in the same order natively. A 12-entry map is checked to print exactly as Phase 0 prints it.
  - **Layouts.** Each kind of data has its own object type. Every payload word is a Value, with raw integers stored as fixnums, so the GC scans them all uniformly. Writes into existing objects go through the write barrier, because any allocation in between may have promoted them. Symbols, keywords, vars and namespaces are permanent objects (`gc.allocPermanent`): never moved, always live.
  - **Strings** store their byte length and their character count, so `count` is O(1) (D-019). Indexing is O(1) for ASCII strings.
  - **`skein.core` natively:** about ninety functions in `runtime/src/core.zig` cover collections, strings and names, atoms, transients, predicates, `reduce`, `apply` and `into`, matching Phase 0's behavior. Each also has a function object, so they can be passed as values. A keyword in function position looks itself up. Seqs over maps and sets, laziness and the rest of skein.core come in M1.9.
  - **C backend:**
    - **Closures:** the captured locals of a `fn` come from a walk of its Core IR. A closure is a function object with the captured values after its code and name. `letfn` fills its closures' references to each other after making them.
    - **Vars** are runtime objects, and `def` returns the var.
    - **Constants:** keywords, symbols and collection constants are made at startup.
    - **Rest parameters** are lists.
    - **`-main`** receives the command-line arguments.
- **Alternatives:** collections written in Skein and compiled natively (dogfooding, but blocked on much more of the backend, and slower until it optimizes); new native hash functions with a different iteration order from Phase 0 (output could then no longer be compared exactly).
- **Consequences:**
  - The tests compare native and Phase 0 output for the whole core-function program, closures, and large collections built under GC.
  - The Zig model tests check vectors, maps with forced hash collisions, sets and transients against plain containers, across garbage collections, in all three build modes.
  - Atoms and functions hash by identity differently from Phase 0, so maps keyed by them may iterate in a different order (ROADMAP note).

## D-047: Conditions and non-local exits in native code
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.5 brings DESIGN §10 to the native runtime: `block*`/`return-from*`, `unwind-protect`, `handler-bind*`, `restart-bind*` and `throw-condition`, which the core macros (`handler-case`, `try`, `restart-case`, `defcondition`) expand into. Native code must unwind across compiled Skein frames and the runtime's own Zig frames, and DESIGN §19.3 asks for SEH-compatible unwinding on Windows.
- **Decision:**
  - **Frames.** Each thread has a chain of frames, innermost first (`runtime/src/cond.zig`). Compiled code allocates them as `sk_frame` locals in its own C stack frame and pushes and pops them through the runtime. There are four kinds:
    - a block (`block*`);
    - an unwind-protect;
    - a handler cluster (`handler-bind*`: types and handler functions in C arrays);
    - a restart cluster (`restart-bind*`: names, functions and reports).
    Every frame gets a per-thread serial number. A block's token, which closures capture to return from it, is its serial, so returning to a block that has already exited is an error rather than a jump to a reused address. Restart values hold the serial too, which is how they stay safe after their extent.
  - **Unwinding is setjmp/longjmp.**
    - A function that has a block or unwind-protect calls setjmp itself (`_setjmp` on macOS, which doesn't save the signal mask) and declares its locals `volatile`.
    - An unwind walks the chain from the top and lands at its target. At each unwind-protect on the way it first jumps there, storing the target and value in that frame; the cleanup then runs and continues the unwind. A cleanup that exits through blocks of its own doesn't lose the interrupted unwind.
    - `recur` may leave blocks (`block*` passes tail position through), so it pops them before jumping.
  - **Windows:** with `x86_64-windows-gnu`, mingw's `longjmp` unwinds through `RtlUnwindEx`, which walks the SEH unwind tables of every frame it crosses. That is the SEH-compatible unwinding §19.3 asks for, and it works over the frames M1.5 crosses: compiled Skein C, the runtime's Zig, and libc.
  - **Handlers follow CL.**
    - `signal` walks the chain and calls every matching handler, innermost first and in order within a cluster.
    - While a handler runs, its cluster and everything above it are disabled; a condition signaled inside the handler skips them.
    - A handler that returns declines.
  - **Errors:**
    - `error` and `throw-condition` signal, then report an unhandled error as `skein run` does: `error: <message>`, then `available restarts:` with one `name: report` line each, then exit with status 1.
    - `warn` signals with a `muffle-warning` restart established; if no handler takes it, it prints `WARNING: <message>`.
  - **The runtime's errors are conditions.** Division by zero, bad indexes, non-numbers, arity errors, unbound vars and calls of non-functions signal conditions of the built-in types (`arithmetic-error`, `index-error`, `type-error`, `arity-error`, `unbound-var-error`, `not-callable-error`, `unsupported-operation-error`). Only errors a program can't survive, such as running out of memory, are still fatal.
  - **Condition objects** are runtime objects: types (permanent, kept in a registry by qualified name; redefinition updates them in place), conditions (type, message, slot map) and restart values. Slots are read with readers, `%condition-slot` or keywords.
  - **Type names are resolved at compile time.** `condition-type-form` passes the namespace being compiled, but namespaces don't exist at run time yet. So the C backend qualifies the symbol in `(%condition-type 'name "ns")` itself, through the compiler's aliases and refers. A symbol passed at run time, as in `(error 'asset-missing ...)`, is looked up as `skein.core/name`, then by its unqualified name, which must be unique: Phase 0's fallback rule (§10).
- **Alternatives:**
  - Table-driven zero-cost unwinding (DWARF or SEH personality routines, or C++ exceptions). It would make setting up a block free, but it needs C++ or hand-written personality code per platform.
  - Zig error unions or a pending-exception flag checked after every call. That puts a cost on every call instead of on frames.
  - `__builtin_setjmp`/`__builtin_longjmp`. They are cheaper, but they skip SEH unwinding on Windows.
- **Consequences:**
  - `examples/conditions.skn` and all of Phase 0's condition tests (`host/tests/fixtures/native-conditions.skn`) print the same natively as on the host.
  - A block or unwind-protect costs a setjmp. A handler or restart cluster costs a frame push and no setjmp. 90,000 caught errors with restarts take 0.3 s in a release build.
  - Runtime code that may signal must not hold locks or rely on `defer`, because longjmp skips them (scratch buffers leak).
  - The runtime's scratch allocator is now malloc rather than the page allocator, and looking up an interned name no longer allocates. Both were a system call per error.
  - Natively, no restarts exist outside the program's own: Phase 0's `skein run` adds `abort`, `continue` and `exit`. Some messages differ from Phase 0's, where Phase 0 shows CL's wording (ROADMAP note).

## D-048: The reader in Skein
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.6 ports the reader to Skein, the first piece of the self-hosted front end. It runs on the Phase 0 host for now and must read every file to the same syntax objects as the CL reader. Later it has to compile natively (M1.8), before the rest of skein.core is native (M1.9).
- **Decision:**
  - **`skein.compiler.reader`** in `lib/skein/compiler/reader.skn` is a function-by-function port of `host/src/reader/reader.lisp`, with the same messages and locations.
  - **Data:**
    - Syntax objects are maps, `{:kind :datum :loc}`, with `:meta` when there is metadata. The datum of a compound form is a vector.
    - Locations are maps of file, line, column, end line and end column.
    - The reader reads from a string. Its state (position, line, column, namespace, `#()` arguments) is a map of atoms.
    - Plain data keeps the reader to the part of skein.core that is closest to native: no records, classes, seqs or laziness.
  - **Errors:** a `read-error` condition with `message` and `location` slots. It reports as `message at file:line:col`, as the CL reader's does.
  - **Two additions to skein.core:**
    - `(int \a)` → 97 and `(char 97)` → `\a`, as in Clojure. Jessie chose these over internal helpers. Both are in Phase 0 and the native runtime.
    - The internal `%decimal-to-float` exposes Phase 0's correctly rounded float construction to the reader.
  - **Forward references** use `(def name)`. Skein has no `declare` macro, and `declare` is the name of the body declaration form.
  - **Testing:**
    - Every reader test runs twice: once with the CL reader, and once with the Skein reader through a bridge that converts its maps and conditions to the CL reader's syntax objects and `read-error`s. That includes the randomized round-trip and float tests.
    - A second test reads every `.skn` file in the repository with both readers and compares data, metadata and every location.
- **Alternatives:**
  - Records or classes for syntax objects. They would pull the object system into the native compiler before M1.9.
  - Reading from a stream. Skein has no stream API yet, and whole files are small.
  - Threading the position through return values instead of atoms. That makes a less direct port.
- **Consequences:**
  - The Skein reader matches the CL reader on all 26 `.skn` files and passes the reader tests. A test that shifts one column is caught in every file.
  - `skein run` and `skein build` still use the CL reader until the front end is self-hosted (M1.8).
  - M1.7's expander in Skein consumes these maps.

## D-049: The expander in Skein
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.7 ports the expander to Skein: environments, special forms, macro calls, syntax-quote, destructuring, and the built-in `ns`, `defn`, `defn-` and `defmacro` macros. It must produce the same Core IR as Phase 0 for every `.skn` file in the repository. The IR is a set of CL structs that refer to each other, and the expander needs the image's namespaces and vars, and its macros, while it runs.
- **Decision:**
  - **`skein.compiler.expander`** in `lib/skein/compiler/expander.skn` ports `host/src/expander/` function by function, with the same messages. It works on the Skein reader's syntax maps (D-048).
  - **Core IR as data** (`docs/CORE-IR.md`):
    - Nodes are maps keyed by `:op`. Locals and block tags carry unique ids.
    - A recur names its loop or arity by id: immutable data can't point at the node that contains it.
    - A local's declared type is an atom, because `(declare (type ...))` sets it after the local is bound.
    - Whether a target is recurred to is tracked with an atom while its body is analyzed.
  - **The compile-time environment:** internal skein.core functions in `host/src/runtime/compile-env.lisp`. They give access to namespaces and vars, mark vars as def does, call macros (with the phase checks of DESIGN §4.4), copy symbols, and provide identity tables. Macros receive data, as in Phase 0 (D-033). The expander tracks where each piece of data came from in an identity table, and passes macros a lookup for `%syntax-meta`.
  - **`destructure`** is ported too. The core macros still call Phase 0's until the compiler is self-hosted.
  - **Testing:**
    - For every `.skn` file, each top-level form is expanded by both expanders on the same image. The expansion and the IR are printed as canonical text (ids and gensym numbers renumbered by order of appearance; every location included) and compared.
    - As `skein build` does, ns and defmacro forms, defs of functions, and `%define-` calls (structs, classes, condition types) are run after they are compared, so that later forms expand.
    - A new fixture, `host/tests/fixtures/expander-forms.skn`, exercises every special form.
    - The 82 `compile-fails` cases of the test suite must give the same message and location from both expanders.
    - `destructure` is compared on a table of patterns, errors included, and on 300 random ones.
- **Alternatives:**
  - Records for nodes. These need the object system natively before self-hosting (M1.9).
  - Keeping locations in a side table rather than in each node. That loses the IR's rule that every node carries its location.
  - Comparing IR by walking both trees in parallel instead of as text. That gives worse failure messages and is no stronger.
- **Consequences:**
  - The Skein expander matches Phase 0 on all 2,496 top-level forms of the repository's 29 `.skn` files, including the forms their expansions splice in, and on every compile error the tests check. Changing one location, one `recur-p` flag or one message is caught.
  - `skein run` and `skein build` still use the Phase 0 expander.
  - Self-hosting (M1.8) has three things to solve: native versions of the compile-time functions, running macros inside a native compiler, and the seq functions the compiler uses (ROADMAP notes).

## D-050: Native skein.core before self-hosting; macros interpreted at compile time; skein.io
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.8 was self-hosting and M1.9 native `skein.core`. Porting the reader and expander showed that the compiler uses most of skein.core: seq functions, and all of `core.skn`'s macros. A native compiler must also run macros while it compiles, and read and write files and run zig, which Skein has no API for.
- **Decision** (Jessie chose each):
  - **The milestones swap.** M1.8 is now native `skein.core` and M1.9 self-hosting, so the compiler self-hosts on a complete native core. Code and notes that pointed at the old numbers now use the new ones. Earlier DECISIONS entries keep the numbers they were written with.
  - **Macros at compile time:**
    - skein.core's macros are compiled into the native compiler.
    - A program's own macros (its `defmacro`s and the phase-1 code they call) run in a Core IR interpreter written in Skein.
    - Phase 1 therefore always runs on the build machine, as DESIGN §4.4 wants for cross-compiling.
  - **`skein.io`** (DESIGN §21) starts with `read-file`, `write-file`, `file-exists?` and `run-process`, which returns `{:exit :out :err}`. It is a public namespace, available to programs.
- **Alternatives:**
  - Keeping the order and bringing forward only the parts of skein.core the compiler uses.
  - Compiling macro code to shared libraries and loading them during a build. That would need zig mid-compile and is awkward with macOS code signing.
  - Supporting only skein.core's macros natively at first.
  - `slurp`/`spit` in skein.core, or compiler-only `%` functions.
- **Consequences:**
  - M1.8's exit is the old M1.9's: every example with an `.expected` file runs natively on all three platforms, and n-body is within 1.5× of C.
  - M1.9 adds the interpreter, `skein.io` and the C backend in Skein.

## D-051: Native skein.core in Zig and Skein
Date: 2026-11-09 · Status: Accepted
- **Context:** About 190 skein.core functions that Phase 0 implements in CL have no native version yet: seqs and laziness, transducers, the collection library, objects, structs and arrays, and concurrency. `core.skn` itself is almost all macros, which expand on the host.
- **Decision** (Jessie's choice):
  - **The Zig runtime keeps the foundations:** data representations, the seq protocol over every collection, lazy-seq cells, objects and generic-function dispatch, typed arrays and threads.
  - **The library on top is written in Skein:** the namespace `skein.core.native` (`lib/skein/core/native.skn`).
    - The C backend compiles it into every native program. A call to a skein.core function that the namespace defines goes to its definition there; any other call goes to the runtime's function.
    - On the host it loads as an ordinary namespace, so its functions are tested against Phase 0's CL versions.
  - **M1.8 has six steps** (ROADMAP), starting with programs made of several namespaces.
- **Alternatives:** porting every remaining function to Zig, as M1.4 did for collections. That gives faster library code but more Zig to keep in step with Phase 0, and it doesn't exercise the compiler.
- **Consequences:** Native programs carry the compiled library (until a later milestone links it once as a library). The library is written in the subset of Skein the C backend compiles at each step.

## D-052: Native seqs and the seq library
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 2 of M1.8 brings seqs, lazy seqs, the seq functions and transducers to native programs, split as D-051 says: foundations in Zig, the library in Skein.
- **Decision:**
  - **`runtime/src/seq.zig`:**
    - `seq`, `first`, `next` and `rest` over every collection.
    - New object types:
      - cons cells, whose rest is any seqable value;
      - lazy seqs: a thunk, run once, then its seq;
      - seqs over vectors and strings by index;
      - `reduced`;
      - eductions, which carry the functions that seq and reduce them.
    - Maps and sets are seq'd into a list of entries or elements, in the order Phase 0 uses. That allocates the whole list, unlike Phase 0's node seqs, but gives the same elements.
    - Printing, equality and hashing treat every seq as a list, as Phase 0 does.
    - `reduce` stops at a `reduced` value. `nth` walks a seq without counting it, since it may be infinite.
  - **`skein.core.native`** gains:
    - the seq functions (`map` to `dedupe`, `sort`, `group-by`, `some`, ...);
    - `into`, `sequence`, `transduce`, `eduction` and `comp`;
    - the function helpers.
    Each is a port of the corresponding function in Phase 0's `core-coll.lisp`, with the same laziness: lazy seqs realize one element at a time, and the transducers have the same state. `sort` is a stable merge sort, as Phase 0's `stable-sort` is.
  - The Zig versions of `into` and `mapv` gave way to the library's, which handle transducers and several collections.
  - The runtime gained `pr-str`, `hash-of`, `odd?` and `even?`. Phase 0 gained `%eduction`, so the library also runs on the host.
- **Testing:**
  - About 150 hand-written cases and 300 random ones (random collections through random seq functions and transducer stacks) give the same values with the library as with Phase 0's functions, on the host. The cases include errors and how much of a lazy seq gets realized.
  - A native program (`host/tests/fixtures/native-seqs.skn`) prints exactly what Phase 0 prints. It covers seqs over every collection, equality and hashing of seqs, every library function, laziness, and long and infinite seqs under garbage collection.
  - Zig tests cover the seq layer.
- **Consequences:** `examples/macros.skn` now runs natively and matches its `.expected` output. `examples/collections.skn` waits for step 3 (`select-keys`).

## D-053: The rest of skein.core natively, and multiple values
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 3 of M1.8: the skein.core functions still missing natively that aren't about objects, structs, arrays or concurrency (steps 4–6) or the compiler itself (M1.9), plus multiple values, which the C backend couldn't compile.
- **Decision:**
  - **In the runtime:**
    - `f32`, `f64`, `sqrt`, `rand`, `rand-int`, `gensym`, `parse-long`, `boolean`, `associative?`, `counted?` and `ifn?`, with Phase 0's results and messages.
    - `rand` uses a seeded PRNG from Zig's standard library.
    - Maps, sets and vectors can be called as functions, as in Phase 0.
  - **In `skein.core.native`:** `get-in`, `assoc-in`, `update-in`, `merge`, `merge-with`, `select-keys`, `zipmap`, `find`, `key`, `val`, `empty` and `not-empty`, ported from Phase 0.
  - **Multiple values**, with Common Lisp's rules, as Phase 0 compiles `values` to CL's:
    - A function returns its first value and leaves the count and the values in thread-local registers.
    - The C backend tracks which nodes' values matter: a function's body, a `let-values*` init, and the tail parts of `if`, `do`, `let`, `letfn`, loops, blocks (including `return-from` values), `unwind-protect`, handler and restart clusters, `the` and `locally`.
    - In such a position, a `values` sets the registers, and a call resets them before calling, so a compiled callee's values pass through while a runtime function's count as one. Anything else marks one value.
    - An `unwind-protect` saves the registers across its cleanup, on both the normal path and the unwinding one.
    - `let-values*` reads them right after its init.
- **Alternatives:**
  - Returning a struct of values from every function: a change of calling convention for a rarely used feature.
  - Boxing multiple values in an object. Every use of a value would then have to unbox it.
  - Supporting `values` only directly inside `let-values*`, which would differ from Phase 0.
- **Consequences:**
  - Every compiled function return that isn't a tail call or a `values` stores to a thread-local. fib(32) is no slower measurably.
  - Five of the eight examples with `.expected` files now run natively: hello, fib, conditions, collections and macros.
  - A fixture covering every function above and the multiple-value cases prints the same as Phase 0. The library's new functions are compared with Phase 0's on the host.

## D-054: The object system natively
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 4 of M1.8 brings DESIGN §8 to native programs. Phase 0 builds it on CLOS through closer-mop; native code needs its own classes, instances and dispatch, with the same results.
- **Decision:**
  - **Classes are runtime objects** (`runtime/src/objects.zig`), registered by qualified name.
    - Precedence lists are C3, as in Phase 0.
    - A class's slots are ordered as SBCL orders them: walk the precedence list from the most general class, and add each class's new slots in order. A slot's options come from the most specific class that defines it.
    - Every value has a class. Instances have their defclass class. Other values map to the built-in classes (`integer`, `string`, `seq`, `list`, `fn`, ...), and conditions to one class per condition type, under `condition`, `error` or `warning`.
  - **Instances** hold their class, the slot layout they were made with, their owner thread (for `:unsynchronized` cells), an identity hash and the slot values.
    - `make`, `with`, `slot`, `set-slot!`, `update-slot!`, `cell` and `set!` on a slot behave as in Phase 0, messages included.
    - `get`, `keys` and destructuring work on instances.
  - **Generic functions** are runtime closures over their state.
    - A call computes the classes of the required arguments, then looks up the effective method in a cache keyed by them. A generic function with an eql specializer skips the cache.
    - It runs standard method combination: around methods, then befores, then primaries with `call-next-method` and `next-method?`, then afters in reverse. Those two functions are runtime closures.
    - A method with the same qualifier and specializers replaces the old one.
  - **`equiv`, `hash-of`, `initialize` and `update-instance-for-redefined-class`** are generic functions natively too. `=` and hashing use `equiv` and `hash-of` for an instance whose class specializes them, else identity.
  - **Names resolved at compile time**, as for condition types (D-047):
    - `%class` symbols are qualified by the compiler.
    - `defmethod`'s generic function is found by the compiler using Phase 0's rule: a var holding a generic function, else the namespace's own var. The call becomes `sk_define_method` with that var, or with the skein.core generic function itself.
  - **Fix found along the way:** native map and set literals with keys or elements computed at run time now reject duplicates, as Phase 0 does.
- **Alternatives:**
  - Dispatch in Skein in `skein.core.native`. That would be slower on every call, and D-051 puts dispatch in the runtime.
  - Discriminating functions generated per generic function. That is faster, but much more code, and premature before profiling.
- **Consequences:**
  - `examples/objects.skn` runs natively. A fixture of classes, cells, multiple dispatch, eql specializers, method combination, `call-next-method` with arguments, rest parameters, `equiv`/`hash-of` and condition types prints the same as Phase 0.
  - Differences are listed in the ROADMAP notes: CL's class names and CL's error messages in Phase 0, class redefinition, and `:type` checks.

## D-055: Structs, typed arrays and defsoa natively
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 5 of M1.8 starts with DESIGN §9's data: value structs, records, typed arrays, views, byte views and `defsoa`. Phase 0 makes them from CL structs and specialized CL arrays. Its `defstruct` and `defsoa` define vars by name at run time, which native code can't.
- **Decision:**
  - **Runtime representation** (`runtime/src/structs.zig`):
    - A struct definition is a permanent object: its name, value-or-record flag and fields, with each field's primitive kind or nested value-struct type.
    - A struct value holds its definition and its fields, boxed. Constructors take the fields in order or as `:field value` pairs, and check them as Phase 0's typed CL slots do.
    - Equality is by definition and fields. `hash-of` computes Phase 0's value exactly (name hash, then 31h + each field's hash, mixed).
    - Methods can specialize on struct types: each struct gets a class.
  - **Arrays:**
    - Primitive arrays pack their elements at their natural width (`i8` to `u64`, `f32`, `f64`, `fixnum`, `char`). The GC doesn't scan their payload.
    - `any` arrays hold values.
    - An array of value structs keeps one primitive array per leaf field, as Phase 0 does, so its elements are inline. `defsoa` builds on it.
    - Views share their base array; byte views wrap a primitive array.
    - All of them have identity hashes, and seq'ing walks them by index.
  - **Compiling `defstruct` and `defsoa`:**
    - Like `ns` and `defmacro`, they run on the host at compile time, so their vars exist for later forms.
    - The C backend then compiles the `%define-struct`/`%define-soa` call into `sk_define_struct`/`sk_define_soa` plus a `sk_var_set` for each var the host made: the constructor, `name?`, each `name-field`, `make-name` and the field functions.
    - Struct types in fields and in `make-array` are qualified at compile time, so the runtime finds them by full name.
- **Alternatives:**
  - Unboxed struct values in locals and in other structs (DESIGN §9.1's "stored inline"). That needs the type-directed code generation that step 5 is starting; arrays already store structs inline.
  - Making the runtime create vars by name, which would need namespaces at run time.
- **Consequences:**
  - `examples/particles.skn` runs natively: seven of the eight examples now pass.
  - n-body runs natively with Phase 0's exact energies, still boxed; the rest of step 5 compiles declared code unboxed.
  - A fixture of structs, records, nested value structs, every array kind, views, `update!` and `defsoa` prints the same as Phase 0. The differences are noted in the ROADMAP: char arrays, and the error type for an out-of-bounds index.

## D-056: Declared types compiled to unboxed C
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.8's exit criterion includes n-body within 1.5× of C. Natively every number was boxed: 500k steps took 1.95s, about 120× slower than C. Phase 0 gets its speed from SBCL's inference over declared types (D-036).
- **Decision:** the C backend gets a typed layer (`host/src/backend-c/typed.lisp`).
  - **Static types:**
    - `f64`, `f32` and `int` values are held unboxed as C `double`, `float` and `int64_t`. A `:bool` is a C condition.
    - `(array f64)`, `(array f32)` and `(array fixnum)` are known primitive arrays, still held as values.
  - **Typed locals:** a pass over each function before it is emitted gives a static type to:
    - declared locals (`^type` or `declare`);
    - immutable `let` locals whose init has a float type, or an integer type that can't overflow (a literal, a local, `count`).
  - **Primitives:** with typed operands, `+ - * /`, `inc`, `dec`, the comparisons, `zero?`, `pos?`, `neg?`, `not`, `sqrt` and `aget`/`aset!`/`count` on typed arrays compile to C.
    - Numbers convert by contagion, as in Phase 0: integer `/` gives f64, f32 with f64 gives f64.
    - Bounds, division by zero and int64 overflow are checked unless `(safety 0)`. A typed array's length is read once, when it is bound.
  - **Boxing and checks:**
    - A value is boxed only where it reaches code without a known type.
    - Declared parameters are checked on entry, and stores to declared locals and `the` are checked, as Phase 0 checks at safety 1 and above. A declared `fixnum` checks the fixnum range.
  - **Integers past 64 bits:** integer arithmetic is unboxed only where a typed integer is required (a fixnum local, an index, a comparison). Elsewhere its result may be a bignum, so it stays on the boxed path.
  - **Exact floats:** programs compile with `-ffp-contract=off`, so C fuses no multiply-adds and floating-point results are bit for bit Phase 0's.
  - `bench/nbody/nbody.c` is the C reference: the same algorithm, layout and operation order. `make bench` compares it with the native build of `nbody.skn`.
- **Alternatives:**
  - Full type inference across a function, with types flowing through `if` and loop locals without declarations. More speed is possible, but each inferred type must be proven safe against Phase 0's semantics (bignums, contagion, declared checks), and it isn't needed for the target.
  - Keeping the raw data pointers of typed arrays in locals: the GC moves young objects, and stack pinning would have to cover derived pointers.
- **Consequences:**
  - n-body runs at 1.35× of C (0.249s against 0.184s for 5M steps), with Phase 0's exact energies.
  - A fixture of typed parameters, locals, contagion, typed arrays, closures over typed locals, `set!`, `the`, errors, `(safety 0)` and bignum results prints the same as Phase 0, in dev and release builds.

## D-057: Concurrency natively, on OS threads
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 6 of M1.8 brings DESIGN §13's API to native programs. Phase 0 runs it on a cached pool of SBCL threads with cancellation scopes in a special variable (D-037). Natively there are no special variables, the condition chain lives in C stack frames (D-047), and the GC must see every thread's heap pointers (D-045).
- **Decision:** the Zig runtime implements tasks, nurseries, cancellation, timeouts and channels (`runtime/src/tasks.zig`), with Phase 0's semantics and messages.
  - **Threads:** the same cached pool as Phase 0: a new worker starts when no worker is idle, and idle workers exit after 30 seconds. Each worker attaches to the GC and registers its multiple-values buffer as a root. The platform layer adds thread creation, timed condition waits and the CPU count.
  - **Cancellation scopes:** a new frame kind on the condition chain holds the running code's scopes: its task, enclosing nurseries and `with-timeout` deadlines. A non-local exit drops them with the other frames. A task starts with a frame holding the scopes it inherited from its spawner, then one for itself; a nursery join that was interrupted waits behind a barrier frame, so it is not cancelled again.
  - **Catching:** tasks and nurseries catch errors and `cancelled` through `sk_try_call` in `unwind.c`, a handler cluster inside a block, as `handler-case` does.
  - **One lock:** tasks, nurseries and channels share one lock and one wake-up condition, as Phase 0's channels do. Waiters wake at least every 20 ms to run main-thread work and check for cancellation. The lock is waited for only inside `gc.blocking`, so a thread that holds it may allocate, and so collect, while others wait for it.
  - `cancelled`, `timeout` and `task-cancelled-error` are built-in condition types of the runtime.
  - `pmap`, `preduce` and `pdotimes` are written in Skein in `skein.core.native`, on `with-nursery` and `spawn`, splitting the work as Phase 0 does.
- **Alternatives:**
  - A lock per task and per channel. Less contention, but `alts!` must then lock several channels in order; one lock is what Phase 0 does, and contention doesn't matter until fibers (Phase 2).
  - Waking waiters only by notification, without the 20 ms slices. Cancellation and the main thread's queue would then need their own wake-ups; Phase 2's scheduler replaces all of this.
- **Consequences:**
  - `examples/jobs.skn` runs natively, so all eight examples with an `.expected` file pass natively.
  - A fixture of nurseries, futures, cancellation, timeouts, channels, `alts!`, data parallelism, the main thread's queue, job graphs and stress runs prints the same as Phase 0, also with a one-segment nursery that collects thousands of times across threads.
  - Two native bugs that only threads show were fixed: an atom's compare-and-set stored its slot a second time, which could undo another thread's update; and using a transient from the wrong thread, or after `persistent!`, signaled `error` instead of `transient-error`.
  - A race found later by CI (macOS): a failing task was marked finished before its failure was recorded in its nursery, so a nursery joining at that moment could return normally. The failure is now recorded in the same step, natively and in Phase 0, which had the same order. A stress loop of nested failing nurseries catches the old code on every run.

## D-058: The native compiler's command, phase-1 rule and run-process
Date: 2026-11-09 · Status: Accepted
- **Context:** M1.9 builds a native compiler before M1.11 reworks `skein build`. It needs a command, a rule for which top-level forms run at compile time, and a `run-process` to call zig. Today `skein build` runs `ns`, `defmacro`, defs of functions and `%define-` forms of the program, but loads each required namespace by running all its top-level code.
- **Decision** (Jessie chose each):
  - **`skeinc`:** a separate executable, `build/skeinc`, built by `make compiler` and run as `skeinc build file.skn [-o out]`. `./skein` keeps running on SBCL; M1.11 can fold the two together.
  - **One phase-1 rule for every namespace:** the native compiler runs at compile time only `ns`, `defmacro`, `def`s whose value is a function, and struct, class and condition-type definitions. That holds for the program's namespace and the ones it requires; top-level side effects never happen at build time.
  - **`(run-process [program args...] opts?)`** runs a program without a shell and returns `{:exit :out :err}`. The only option for now is `:dir`.
  - **`skein.io/io-error`** is signaled when a file can't be read or written, or a program can't be started. Its `path` slot names the file or program. A program that starts and exits with a failure status is not an error: `run-process` returns its `:exit`.
  - **Implementation (internal):** `lib/skein/io.skn` signals the errors and wraps four internal functions, `%read-file`, `%write-file`, `%file-exists?` and `%run-process`, which return nil on failure. Phase 0 has them in `host/src/runtime/io.lisp`. The native runtime has them in `runtime/src/io.zig`, on Zig's `std.Io`, inside `gc.blocking`.
  - **M1.9 has six steps** (ROADMAP): `skein.io`; the C backend in Skein; the compile-time environment natively; the phase-1 interpreter; the driver; bootstrapping.
- **Alternatives:**
  - `./skein build --native`, with one command that falls back to SBCL.
  - Racket's rule: `:require-for-syntax` namespaces run all their forms at phase 1, and the current file only its macros and function definitions.
  - Running every top-level form at build time too, as Phase 0 effectively does.
  - A variadic `(run-process program arg...)` without options.
- **Consequences:**
  - A macro that reads a `def` of computed data, rather than calling a function, works in Phase 0 but not natively. The phase-1 interpreter reports it as an unbound var.
  - The C backend moves to Skein and is tested against the Lisp one, as the reader and expander were.

## D-059: The C backend in Skein
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 2 of M1.9 ports the C backend (`host/src/backend-c/emit.lisp` and `typed.lisp`, about 1,400 lines) to Skein, so the native compiler can include it. It must turn the Skein expander's Core IR maps (D-049) into the same C as the Lisp backend. The Lisp backend keeps its state in special variables, which native Skein doesn't have.
- **Decision:**
  - **`skein.compiler.c`** in `lib/skein/compiler/c.skn` ports both files function by function, with the same messages and the condition `c-backend-error`. Its interface is `make-unit`, `emit-toplevel` (a top-level form's IR and its namespace) and `program-text`.
  - **State as a map:** what the Lisp backend binds dynamically (`*mv*`, `*tail-mv*`, `*targets*`, `*frames*`, `*safety*`, the current namespace) is a map passed down every call and changed with `assoc`. The program being built and the function being emitted are atoms in it. Locals, block tags and recur targets are keyed by their ids.
  - **The image:** like the expander, the backend reaches namespaces, vars, struct definitions and generic functions through skein.core's `%` functions. Step 2 adds `%ensure-namespace`, `%generic?`, `%struct-def-name`, `%f64-bits` and `%f32-bits` to Phase 0; the native compiler needs them in step 3.
  - **Testing:**
    - The Lisp `translate-file` calls a test hook just before it emits each top-level form; the hook runs the Skein expander and backend on that form, with the image in the same state.
    - The two C programs must be identical once local names (`l_name_id`) and gensym numbers are renumbered: each expander numbers locals with its own counter, and the macros both call share one gensym counter.
    - A program that can't be built must fail with the same message and location from both.
    - This runs on every `.skn` file in the repository (33 give C, up to 1 MB of it; 7 fail the same way) and on every program the C backend tests build.
    - The tables of native functions and condition types exist in both backends until the Lisp one retires; a test checks that they are equal.
- **Alternatives:**
  - Records for the state. They would pull the object system into the compiler's hot path for no gain over maps.
  - Dynamic vars (`binding`) for the state. Native code doesn't support them yet.
  - Comparing generated programs by running them. That is weaker than comparing their text, and much slower.
- **Consequences:**
  - The port found a bug in the Lisp backend: `emit.lisp` bound `*safety*` before `typed.lisp` declared it special, so `(safety 0)` from a declaration was lost outside typed expressions. The variable is now declared in `emit.lisp`, with a regression test.
  - The compiler's own files don't build natively yet: the reader needs `%decimal-to-float` natively, and the expander needs the compile-time `%` functions (step 3).

## D-060: The native compiler's compile-time environment
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 3 of M1.9 runs the reader, expander and C backend natively. On the host they reach Phase 0's image through about 30 internal `%` functions (namespaces, vars, macro calls, symbol copies, identity tables), and skein.core's macros are host functions. Natively, the program being compiled must not share vars with the compiler compiling it (DESIGN §4.4): compiling the compiler would otherwise redefine the running compiler.
- **Decision:**
  - **`skein.compiler.env`** (`lib/skein/compiler/env.skn`) models namespaces and vars as atoms holding maps, with Phase 0's rules for resolving, interning, aliases, refers, `%in-ns`, `%require` and `%refer`. The expander requires it, and the C backend sends calls of the skein.core functions it defines there, as it sends the library's to skein.core.native.
  - **Its skein.core** is made on first use from:
    - the runtime's functions (`%core-function-names`, `%core-function`);
    - the public functions of skein.core.native, which also get their own namespace there, as on the host;
    - the macros of `lib/skein/core.skn` compiled into the program;
    - the built-in condition types;
    - unbound vars for the rest of Phase 0's public names (`%define-method` and others the C backend compiles itself);
    - the built-in macros `ns`, `defmacro`, `defn` and `defn-`, which the expander implements.
  - **Compiled core macros:** when a program includes `skein.compiler.env`, both backends first translate `core.skn` into it. Each `defmacro` becomes a `def` of its function, compiled without analyzing the `def`, which would clear the host var's macro flag. References to `core.skn`'s own helpers go to their compiled vars. At startup the program registers these macros and the library's public vars with the runtime (`sk_register_core_var`), for the model to read.
  - **Runtime support** (`runtime/src/compiler.zig`):
    - **Symbol copies:** `%copy-symbol` makes a symbol that is `=` to the original (equality compares the namespace and name of symbols that aren't identical) but not `identical?`.
    - **Identity tables:** keys and values are kept in tuples, with an open-addressing index keyed by address. The index is rebuilt when the GC's collection count has changed, because objects may have moved.
    - **Floats:** `%f64-bits`, `%f32-bits`, and `%decimal-to-float` on Zig's correctly rounded `parseFloat`.
    - **Errors:** arity errors carry the function's name and the argument count (`%arity-error-details`).
    - **Generic functions:** `%generic?`.
  - **`destructure`** moves from `skein.compiler.expander` to skein.core.native: the core macros call `skein.core/destructure`, which natively must be the library's.
- **Alternatives:**
  - Registering compiled programs' vars by name in the runtime and using them as the compile-time namespaces. Simpler, but it shares the compiler's vars with the program it compiles.
  - Writing the model in Zig. More code to keep in step with Phase 0's rules, and harder to test against them.
  - Identity tables that scan linearly, or that pin their keys. The first is quadratic for large forms; the second isn't possible with stack-only pinning.
- **Consequences:**
  - A test program translates samples that use every core macro: classes, typed code, conditions, concurrency, and errors. It prints the same C natively as under `skein run`, where the same code reaches Phase 0's image.
  - The work found two native bugs, now fixed with tests: `quot`, `rem` and `mod` on bignums went through floats, and `apply` was limited to 256 arguments.
  - Phase rules aren't checked natively yet; the interpreter (step 4) will check them.

## D-061: The interpreter of phase-1 code
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 4 of M1.9. The native compiler must run a program's own macros, and the functions they call, while it compiles the program (D-050, D-058). skein.core's macros are compiled in (D-060); the rest is Core IR that only the expander has produced.
- **Decision:**
  - **`skein.compiler.interp`** (`lib/skein/compiler/interp.skn`) evaluates Core IR maps directly. Its entry point is `evaluate`, for a top-level node.
    - Interpreted functions are Skein closures named after their `fn` (`%named-fn`), so compiled code, such as the expander calling a macro, calls them like any function.
    - A local's value is in the environment map; a `^:mutable` local or a `letfn` function is in an atom.
    - `recur` returns a marker to its loop or arity.
    - `block*` is Skein's own `block*`, with a closure that returns from it.
    - `unwind-protect` is `try`/`finally`.
    - Multiple values are carried as vectors in the positions where the C backend passes them on (`emit-tail`).
    - Declared types are not checked.
  - **New skein.core functions, internal to the compiler,** in Phase 0 and natively:
    - `%call-with-handlers` and `%call-with-restarts`, because restart names are unevaluated symbols in `restart-bind*`;
    - `%apply-values` and `%call-with-values`;
    - `%named-fn` and `%arity-error`, so that a macro called with the wrong number of arguments is reported as in Phase 0;
    - `%set-var-value!`, `%var-defined?` and `%check-phase`.
  - Natively, the model also gets `%define-method`, on a new runtime function `%add-method`.
  - **Phase rules** (DESIGN §4.4): while a macro runs, a var read by interpreted code is checked as Phase 0 checks it. A violation is warned about with Phase 0's message and the expansion goes on; Jessie chose warning over an error. Phase 0 no longer checks reads by the compiler's own namespaces (`skein.compiler.*`), which run while macros expand but aren't the macros' code.
  - The programs that include `skein.compiler.env` also register its `%` functions as skein.core functions, so interpreted code finds `%set-macro!`, `%in-ns` and the rest natively.
- **Alternatives:**
  - Compiling a program's macros to C and loading them during the build (rejected by D-050).
  - Closure conversion of the IR before interpreting. Faster, but not needed yet.
  - Errors for phase violations, as DESIGN §4.4 first said. Programs that Phase 0 builds with a warning would then stop building natively.
- **Consequences:**
  - On the host, every example and native fixture (all but the typed one) prints the same when the Skein expander and the interpreter run it as under `skein run`.
  - Natively, the native-compiler test program runs samples' own macros, with helpers, several arities, recursion, an arity error and a phase warning, and prints the same C as under `skein run`.
  - A program's own structs aren't available to its macros natively yet.

## D-062: The native compiler's driver
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 5 of M1.9 adds the driver, `skeinc build file.skn [-o out]` (D-058). It must read a program and the namespaces it requires, run their phase-1 code, translate them to the same C as `skein build`, and compile it with zig. Natively there is no `getcwd`, no `mkdir` and no image to load namespaces into.
- **Decision:**
  - **`skein.compiler.main`** (`lib/skein/compiler/main.skn`) ports `host/src/backend-c/build.lisp`: skein.core.native first, then the program; after each `ns` form, the namespaces it requires, in require order and each one's requires first; `core.skn`'s macros when the program includes `skein.compiler.env`.
  - **Phase 1:** `ns` and `defmacro` forms run in the interpreter and make no code. Other forms are compiled, and a def of a function not yet defined at phase 1, or a `%define-` form, also runs at phase 1 (D-058).
  - **Loading required namespaces:** natively, `skein.compiler.env`'s loader loads a required namespace at phase 1 (its `ns`, `defmacro` and phase-1 forms); translation then compiles it. On the host, Phase 0 loads it.
  - **Structs at phase 1:** natively, `skein.compiler.env` defines `%define-struct` and `%define-soa` on new runtime functions, making the same vars as Phase 0. `%struct-def-name` finds them.
  - **Building:**
    - The same zig commands and flags as `skein build`, with `--release` and `--keep-c`.
    - The runtime and the C file go in the checkout's `.skein-cache/`, which `zig build` creates: skein.io has no `mkdir`, and `zig build` runs in `runtime/`, where a path relative to the current directory would be wrong.
    - The checkout comes from `SKEIN_HOME`, or the current directory or a parent that has `lib/skein/core.skn`.
    - `%getenv` (internal) reads `SKEIN_HOME`, `SKEIN_ZIG` and `OS`.
  - **Testing:** on the host, the driver's C for every native test program equals `skein build`'s, up to local and gensym numbering.
- **Alternatives:**
  - `getcwd` and `mkdir` in skein.io. They are user-visible API, so they wait for skein.io's next additions.
  - A path baked into `skeinc` at build time. A moved checkout would break it, and the two bootstrap builds would differ by path.
- **Consequences:**
  - `skeinc`, built by Phase 0, builds every example natively, and each prints its `.expected` output. It builds itself in about 13 seconds.
  - **Bootstrapping:** the compiler that Phase 0 builds and the ones `skeinc` builds differ in one way. `core.skn`'s macros are compiled into each compiler, and the `x#` names in their syntax-quotes are numbered from the gensym counter of the process that compiled them: Phase 0's for the first, `skeinc`'s for the rest. So the first compiler's C output differs from later ones only in those local names. From `skeinc` on, rebuilding is a fixed point: the C of the second rebuild equals the first's. Step 6 bootstraps that way.

## D-063: Bootstrapping the native compiler
Date: 2026-11-09 · Status: Accepted
- **Context:** Step 6 of M1.9, its exit: the native compiler rebuilds itself, and the second build's output is identical to the first. D-062 found that the compiler Phase 0 builds differs from the ones `skeinc` builds in the gensym numbers baked into skein.core's macros.
- **Decision:**
  - **`make compiler`** builds `build/skeinc`: `./skein build` (Phase 0) makes `build/skeinc-stage1`, which builds `build/skeinc` from `lib/skein/compiler/main.skn`. It rebuilds when the libraries or the runtime change.
  - **`make test-compiler`**, part of `make test`:
    - `skeinc` builds itself to `skeinc-a`, which builds itself to `skeinc-b`, both keeping their C. The two C files must be byte-identical.
    - `skeinc` then builds every example with an `.expected` file, and each must print exactly that.
    - CI runs it on all three platforms with the rest of `make test`.
  - **What is compared:** the generated C, not the executables. Each executable embeds the name of its own C file, so `skeinc-a` and `skeinc-b` differ by that name.
- **Alternatives:**
  - Comparing the stage-1 compiler's output with `skeinc`'s. That needs gensym numbering that doesn't depend on the process, which would be a change to syntax-quote's semantics.
  - A separate CI step instead of `make test`. Keeping it in `make test` means the usual gate covers the native compiler too.
- **Consequences:** the bootstrap takes about a minute: four compiler builds and eight example builds. The compiler is self-hosting: from `skeinc` on, it compiles its own source to the same C every time.

## D-064: Native FFI: run-time loading, and only in skeinc
Date: 2026-11-10 · Status: Accepted
- **Context:** M1.10 brings DESIGN §14 to native programs. Phase 0 loads libraries with `deflibrary` when a program runs and looks each C function up on its first call (D-038). Native code could instead link libraries at build time. Separately, `skeinc` now compiles itself (M1.9), and every native feature so far was written twice, in the Lisp C backend and in the one in Skein.
- **Decision** (Jessie chose each):
  - **Run-time loading:** natively, `deflibrary` loads the library when the program runs (dlopen, LoadLibrary), and a `defcfun` finds its symbol on the first call. The call is a direct C call through a function pointer of the right C type, compiled by the C backend: no libffi. A missing library or function is an error when it is used, as in Phase 0. Builds need neither the library nor, on Windows, an import library.
  - **Only skeinc:** native FFI goes into the C backend written in Skein (`lib/skein/compiler/c.skn`) only. The Lisp C backend is frozen as the compiler that bootstraps `skeinc`: `./skein build` reports FFI programs as unsupported and points to `skeinc`. The Lisp-versus-Skein comparison tests skip programs that use the FFI, and native FFI is tested by building with `skeinc` and comparing with `skein run`.
  - **M1.10 has four steps** (ROADMAP): the runtime's FFI, `defcfun`, `defcallback`, and the SDL example in CI.
- **Alternatives:**
  - Linking libraries at build time (`-lSDL3`). Errors would come at build or start-up time, but every build would need the library and, on Windows, an import library.
  - Adding FFI to both backends, keeping byte-for-byte comparison for FFI code, at twice the work.
- **Consequences:**
  - Native features after M1.9 are written once. The Lisp backend still builds the first compiler, and its comparison tests keep checking everything up to M1.9.

## D-065: The native FFI's runtime
Date: 2026-11-10 · Status: Accepted
- **Context:** Step 1 of M1.10. skein.ffi's functions (`alloc`, `get`, `field`, `sizeof`, `own`, `handle`, ...) and its type definitions must work natively, with Phase 0's behavior and messages (D-038). Phase 0 builds them on CFFI and SBCL finalizers.
- **Decision:**
  - **`runtime/src/ffi.zig`** implements skein.ffi's functions. They are in the core table as `skein.ffi/<name>`, and `skeinc` sends calls of skein.ffi's vars there.
  - **Pointers:** a C pointer is a `foreign_ptr` object holding the address, and NULL is `nil`. `ffi/own` makes an `owned_ptr`. The GC now runs finalizers: a minor collection checks young objects after tracing, and a major one checks the mark bits before sweeping. An owned pointer's finalizer frees its memory.
  - **Types:**
    - A struct, union or enum is a permanent `ctype`, registered by qualified name. Layouts follow C's rules: each field at a multiple of its alignment, and the size rounded up to the largest alignment.
    - `skeinc` qualifies the type names in field types when it compiles, so the runtime finds them, and sets the var that `defcstruct`, `defcunion` or `defcenum` defines. `defcfun` and `defcallback` come in steps 2 and 3.
  - **Libraries:** the platform layers load them (dlopen; LoadLibraryW on Windows). The search order is `SKEIN_LIBRARY_PATH`, then the usual package-manager directories, then the system's. A symbol is looked up in the loaded libraries in load order, then in the whole process (`RTLD_DEFAULT`; every module on Windows).
  - **Phase 1:** the native compiler runs skein.ffi's `%define-` forms at phase 1, like skein.core's (D-058). skein.compiler.env makes real C types for them, so macros can use them; C functions and callbacks get placeholder functions that say they can't run while compiling, and libraries aren't loaded.
  - **`lib/skein/ffi.skn`:** its macros read a set of primitive types, which was a `def` of data. It is now a function, because natively phase 1 runs only function definitions (the consequence D-058 named).
- **Alternatives:**
  - Computing layouts in the C backend and emitting them as constants. Faster, but the runtime needs the layouts anyway for `field` and `sizeof` on types passed as values.
  - Owned pointers without finalization, freed only explicitly. That would differ from DESIGN §14.2 and Phase 0.
- **Consequences:**
  - A fixture of struct and union layouts, nested fields, memory, pointer arithmetic, 64-bit integers, C strings, owned pointers (20,000 left to the GC), enums, handles and errors prints the same built by `skeinc` as under `skein run`. `make test-compiler` checks it.
  - Phase 0 doesn't support `(sizeof (array T n))`; neither does the native runtime's test.

## D-066: Native C calls
Date: 2026-11-10 · Status: Accepted
- **Context:** Step 2 of M1.10. A `defcfun` must become a Skein function that calls the C function with Phase 0's conversions (D-038), loaded and looked up as D-064 says.
- **Decision:**
  - **`skeinc` compiles each `defcfun`** (`skein.ffi/%define-function` with constant arguments) into a C function, and sets the var named after it to that function. The C function:
    - checks the argument count;
    - looks the symbol up on the first call and keeps it;
    - converts each argument: integers keep their low bits, floats convert, `bool` is truthiness, a `c-string` is a NUL-terminated copy freed after the call, `ptr` takes `nil`, pointers and primitive arrays, and an enum takes keywords, collections of them or integers;
    - calls through a function pointer of the C function's exact type;
    - converts the result: `nil` for NULL, an owned pointer for `^:owned`.
  - **Type information:** the C types come from the parameter types at compile time. An enum's integer type comes from its C type, which phase 1 made (`%ctype-info`). A struct or union passed by value is a compile error with Phase 0's message.
  - **Pinning:** arrays passed as pointers stay pinned during the call, because the arguments are on the stack, which the GC scans conservatively.
  - **`^:blocking`:** the call runs from a struct of its arguments inside the GC's blocking section (`sk_ffi_blocking`), so other threads can collect while it waits.
  - **Slow calls:** any other call is timed, and warns once per function if it takes more than 10 ms, as in Phase 0.
- **Alternatives:**
  - libffi, or one generic call path for every signature. Slower, and it would need a dependency.
  - Converting arguments with the C backend's typed layer (D-056). Arguments arrive boxed anyway.
- **Consequences:**
  - The native FFI fixture calls `strlen`, `abs`, `getenv` (blocking), `exp`, `sqrtf`, `memset` (on pointers, views, byte views and pinned arrays) and `malloc` (owned and borrowed), and passes enums. It prints what `skein run` prints.
  - `examples/sdl/window.skn`, built by `skeinc`, runs on macOS with the dummy video driver.
  - Building it found a GC bug in step 1's code: a C type's young parts were stored into a permanent object without the write barrier, so a collection left stale pointers. A runtime test now reproduces it.


## D-067: libm in native programs on Linux
Date: 2026-11-10 · Status: Accepted
- **Context:** Step 2's CI failed on Linux: the native FFI fixture's `exp` wasn't found. On Linux the math functions are in libm, not libc. SBCL's process has libm, but a native program doesn't load it: the runtime's own math comes from Zig's compiler_rt, so the linker drops `-lm`, even with `--no-as-needed`, and referencing a libm function only finds compiler_rt's private copy.
- **Decision:** On Linux, when a symbol isn't found anywhere in the process, the runtime opens `libm.so.6` once and looks there. The lookup order of D-065 is otherwise unchanged.
- **Alternatives:**
  - Making the fixture load libm with `deflibrary`. Programs would then find math functions under `skein run` but not natively.
  - Keeping libm linked by naming a function only libm has. That depends on what compiler_rt provides.
- **Consequences:** C math functions are found natively on every platform, as in Phase 0. A runtime test checks `strlen`, `exp` and `cbrt`.

## D-068: Native callbacks
Date: 2026-11-10 · Status: Accepted
- **Context:** Step 3 of M1.10: `defcallback` natively. C calls the callback with C values, on any thread, sometimes during a `^:blocking` call. Natively, non-local exits unwind with `longjmp`, which skips C's cleanups (SDL could be left holding a lock) and on Windows depends on every frame's unwind tables. Phase 0 let exits other than errors unwind through C. Jessie chose to stop them at the boundary instead, in both phases.
- **Decision:**
  - **`skeinc` compiles each `defcallback`** (`skein.ffi/%define-callback` with constant name and types) into a C function of the exact C type, and sets the var named after it to a pointer to that function, as Phase 0 does. The Skein function is kept in a global.
  - **The C function** puts its arguments in a frame on its stack and calls `sk_ffi_callback` with a body: a compiled Skein function that converts the arguments, calls the Skein function and stores the converted result in the frame. Conversions are Phase 0's: an enum argument arrives as an integer, `nil` returns NULL, and a returned `c-string` is a copy C must free.
  - **Errors:** the body runs under a handler for `error` (`sk_try_call`), so an error in the function or in converting its result warns `callback ns/name signaled MSG; returning 0` (or `0.0` or `nil`; nothing for `void`) and C gets zero. Phase 0's warning names the zero the same way now, instead of printing a Lisp form.
  - **No exit crosses C:** the call runs inside a barrier, a new kind of frame (`SK_FRAME_BARRIER`). An unwind that reaches one stops there, as at an unwind-protect, but goes no further. So invoking a restart established outside the C call, returning from a block outside, or a handler outside that unwinds is stopped: the callback warns `callback ns/name tried to exit through C; returning 0` and C gets zero. Handlers outside still run. The warning is signaled inside a barrier too, so a handler that tries to exit for it is stopped silently. Phase 0 does the same with an `unwind-protect` whose cleanup returns from a block inside the callback, which abandons the exit.
  - **Threads and the GC:** on entry, a thread in a `^:blocking` call leaves the blocking state, waiting for any collection to finish, and goes back to it on return. A thread the runtime doesn't know is attached for the callback and detached when it returns, since it may exit while in C. A thread already running Skein (an unmarked call) just runs.
- **Alternatives:**
  - Keeping a foreign thread attached after its first callback, as DESIGN §14.3 describes with fibers. The collector would scan a stack that may no longer exist once the thread exits. Phase 2's fibers revisit this.
  - libffi closures. They need a dependency, and the C backend knows every callback's type.
  - Letting exits unwind through C, as Phase 0 did. It skips C's cleanups and may break with some libraries.
- **Consequences:**
  - The native FFI fixture sorts with `qsort` (directly and as a blocking call) and searches with `bsearch` using Skein comparators, one of them allocating enough to collect while C's frames are on the stack, and one that errors. A restart invoked from a callback and a handler outside catching a callback's warning are stopped at the boundary. Callbacks of the other types are compiled; the C library can't call them. `host/tools/bootstrap.sh` checks the warnings a fixture's `;; stderr:` comments give.
  - A runtime test enters callbacks from a blocking call and from threads the runtime doesn't know, collecting meanwhile.

## D-069: `skein build` and `skein package` in skeinc
Date: 2026-11-10 · Status: Accepted
- **Context:** M1.11 adds cross-compiling, profiles, `project.skn` and packaging. Two compilers exist: the frozen Lisp C backend behind `./skein build`, which has no FFI (D-064), and `skeinc`. A package must hold its C libraries and assets and run where it's unpacked, and macOS apps ship as `.app` bundles (DESIGN §19.3). DESIGN §20.2's `:paths` mixes sources and assets.
- **Decision** (Jessie chose the first three):
  - **skeinc owns both commands.** `./skein build` and `./skein package` (and `skein.cmd`) run `build/skeinc` with the same arguments, setting `SKEIN_HOME` to the checkout, so they work from any directory. They bootstrap it first if it's missing or older than its sources (`lib/`, `runtime/`). The Lisp backend stays only to build the first compiler, behind `./skein bootstrap`, which `make compiler` runs. skeinc's errors exit with status 1, usage errors included.
  - **Packages:** `skein package` makes `dist/<target>/<name>/`, with the executable, the target's `:native` libraries next to it, and the `:assets` directories. For a macOS target it makes `dist/<target>/<name>.app` instead: the executable in `Contents/MacOS`, the libraries in `Contents/Frameworks`, the assets in `Contents/Resources`, and an `Info.plist` (bundle identifier from an optional `:bundle-id`, default `skein.<name>`). An earlier package there is replaced, and zig's `.pdb` for a Windows executable is left out. skeinc copies with internal runtime functions (`%make-directories`, `%copy-file`, `%list-directory`, `%delete-tree`), which Phase 0 has too. The runtime looks for C libraries in the executable's directory first (and in `../Frameworks` on macOS), then as D-065 says.
  - **`:assets`:** a new `project.skn` key lists the directories copied into a package as they are. `:paths` is only where namespaces are found.
  - **Targets and profiles:** `--target` takes the zig triples of DESIGN §19.1; the default is the machine's own. Linux targets link against glibc 2.28, for older distributions. `--profile` is `dev` (the default for `build`: safety checks, ReleaseSafe runtime) or `release` (the default for `package`: ReleaseFast, `-O2`); `--release` stays as short for `--profile release`. Each target and profile gets its own runtime build in the cache.
  - **`project.skn`** supplies `:name`, `:version`, `:main` (the function to call with the command-line arguments, as `ns/-main`; any function of that namespace), `:paths` (default `["src"]`), `:native` and `:assets`. It's read as data: nothing in it runs. `skein build` with no file builds the project in the current directory: the `:main` namespace, found in `:paths`, into an executable named after `:name`. `:deps`, `:profiles` and `:targets` aren't read yet.
  - **This machine's triple** comes from a runtime function, `%host-target`, for the default target of `skein package`.
  - **M1.11 has five steps** (ROADMAP): targets and profiles; `project.skn`; `./skein` handing off to skeinc; `skein package`; and CI that packages `hello` for all three targets on Linux and runs each on its platform.
- **Alternatives:**
  - Keeping `./skein build` on the Lisp backend, with the new features only in `skeinc`. Two build commands that differ would stay around.
  - A plain folder on macOS too, with the `.app` later.
  - Copying every file in `:paths` that isn't Skein source. Stray files in source directories would ship.
- **Consequences:**
  - Building needs `build/skeinc`; the first `./skein build` bootstraps it, which takes a minute or two.
  - Code signing, notarization, archives and finding assets at run time (a packaged program's working directory isn't its folder, and a `.app`'s assets are in `Contents/Resources`) come later.

## D-070: skein.math and skein.time natively
Date: 2026-11-10 · Status: Accepted
- **Context:** Step 1 of M1.12. Driftrock needs `skein.time/now` and `skein.math`'s scalar functions, which Phase 0 defines in Lisp (`host/src/runtime/math.lisp`), so no native program could use `skein.math`. Building it also found several things `skeinc` didn't do yet.
- **Decision:**
  - **The runtime has them** (`runtime/src/mathtime.zig`), in its core table as `skein.math/<name>` and `skein.time/<name>`, as skein.ffi's are (D-065). The compiler's model puts each `<namespace>/<name>` entry in that namespace, and the C backend calls the runtime for them (`host-functions` in `c.skn`). `lib/skein/math.skn` and `time.skn` add the rest, as on the host.
  - **Phase 0's results:** the scalar functions call the system's libm, found as an FFI symbol (Zig's compiler_rt has copies that can differ in the last bit). An `f32` is computed as an `f64` and rounded, as SBCL does; a float to an integer power multiplies, as SBCL's `expt` does; `noise` is the same Perlin noise. `now` counts from the runtime's start (`sk_init`). Wrong argument types give Skein's messages; Phase 0's come from SBCL.
  - **Things `skeinc` now does, which Driftrock needed:**
    - A program's namespaces are also found from the root that its own namespace name implies (`examples/` for `examples/driftrock/main.skn` declaring `driftrock.main`), as Phase 0's `program-source-paths` does.
    - At phase 1, `%class` and `%condition-type` qualify the name through the model's aliases and refers first, as the C backend does when it compiles the call, so `(defmethod draw! [(s e/ship) ...])` finds `driftrock.entities/ship`.
    - `defonce`'s `(%var-bound? 'ns/name)` compiles to a check of the var: natively nothing is reloaded.
  - **A GC bug:** the runtime's table of generic functions held young closures, which a collection moved; compiling `skein.math`, with many `defgeneric`s, crashed. Generic functions are now permanent objects. A runtime test reproduces it.
- **Alternatives:**
  - Zig's `std.math` for the functions: no lookups, but results that can differ from Phase 0's in the last bit.
  - Writing the scalar functions in Skein over a few primitives. They are the hot path of games, and libm is what Phase 0 uses.
- **Consequences:**
  - A fixture (`native-skeinc-math.skn`) built by `skeinc` prints what `skein run` prints for every function. The Lisp-versus-Skein comparison tests skip programs that use these functions or `defonce`, as they skip FFI programs: the Lisp backend is frozen.
  - Driftrock builds natively, and runs at 60 fps with the dummy video driver on macOS.

## D-071: What "starts in under 0.1 s" measures
Date: 2026-11-10 · Status: Accepted
- **Context:** M1.12's exit says native Driftrock starts in under 0.1 s. Phase 0 took about 1.5 s before Driftrock's `-main` ran: SBCL's start-up and loading `sdl3.raw`. Natively, on a Mac with a real window, the first frame comes about 150 ms after the program starts, but Skein's part is about 10 ms; `SDL_Init` takes about 80 ms and creating the window about 35 ms, which no Skein change can shorten.
- **Decision** (Jessie chose): start-up is the time from the program's start until `-main` runs, which includes the runtime's start and every namespace's top-level code. Driftrock prints it and the time to its first frame; `--check-startup` fails if `-main` started more than 0.1 s in. `skein.time/now` counts from the runtime's start, so `(skein.time/now)` at the top of `-main` measures it.
- **Alternatives:** the time to the first frame with SDL's dummy video driver (about 60 ms; it includes SDL's software renderer), or with a real window and a limit of 0.25 s.
- **Consequences:** CI runs packaged Driftrock with `--check-60fps --check-startup` on all three platforms. `examples/driftrock/project.skn` packages it with SDL3 from `vendor/`, which CI fills from the installed SDL3.

## D-072: Phase 2 milestones, fibers first
Date: 2026-11-10 · Status: Accepted
- **Context:** The roadmap left Phase 2 (native live development) as an outline: fibers and a work-stealing scheduler, channels on fibers, an interpreter for REPL redefinitions, a Swank server (D-018), hot reload of native code, supervisors and the debugger, and STM. At the end of Phase 1, live development (`skein run`, `dev`, `repl`) still runs on SBCL.
- **Decision** (Jessie chose):
  - **Order:** fibers first. Phase 2 has eleven milestones (ROADMAP): Phase 1 follow-ups (M2.1); fibers, the work-stealing scheduler and dynamic vars (M2.2–M2.4); evaluating code in native programs, the native REPL and `skein dev`, and the Swank server (M2.5–M2.7); supervisors (M2.8); hot reload of compiled code (M2.9); STM (M2.10); and Driftrock developed live natively (M2.11).
  - **SBCL's role:** by the end of Phase 2, `./skein run`, `dev` and `repl` run on the native runtime (from M2.6), and the Phase 0 host only bootstraps the compiler and serves as a reference until then.
- **Alternatives:**
  - Live development first, on OS threads, with fibers after. Native live editing would work sooner, but the debugger and REPL would be reworked when fibers arrive, since an unhandled error suspends a fiber.
  - Keeping SBCL for `skein run` and `repl`, with only `dev` native. Two implementations would stay in daily use.
- **Consequences:** the debugger, REPL and supervisors are built once, on fibers. The Phase 0 host gets no new features in Phase 2.

## D-073: Phase 1 retrospective decisions
Date: 2026-11-10 · Status: Accepted
- **Context:** `docs/PHASE1-RETRO.md` proposed four changes.
- **Decision** (Jessie chose the first two; the others are internal):
  1. **`skein.io/resource-dir`** returns the directory holding the program's `:assets`: the package folder, a `.app`'s `Contents/Resources`, or the project directory when run from source (M2.1).
  2. **The C-text comparison tests retire.** `skeinc` is compared with Phase 0 by program output only, as the bootstrap's fixtures are; the Lisp C backend only builds the first compiler (M2.1).
  3. **`SKEIN_GC_VERIFY=1`**: every collection is major and the nursery is one segment (256 KiB), so collections come often; after each, the collector checks every root, permanent object, live heap object and the runtime's own tables (`runtime/src/verify.zig`) for pointers to objects that are gone, and stops the program naming where it found one (M2.1). It finds the generic-function bug of D-070 at once.
  4. **`.skein-cache/` files are named after the program's file and a hash of its path** (`main-1234567.c`), so programs that share a file name don't overwrite each other's C (M2.1).
- **Alternatives:** `skein.game/asset-path` returning one asset's full path; keeping the C comparisons with a growing list of skipped programs.
- **Consequences:** DESIGN §21 lists `resource-dir` in `skein.io` once M2.1 adds it.

## D-074: Fibers in the runtime
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.2 adds fibers to the native runtime (DESIGN §17.4, D-024): stacks of their own, switched in user space, which the GC must scan and the condition system must keep apart. Tasks still run on OS threads until M2.3.
- **Decision:**
  - **Steps:** stacks and switching; the GC and per-fiber state; stack overflow; a scheduler on one thread (ROADMAP).
  - **Stacks** are reserved address space with a guard page at the bottom, readable and writable above it and committed by the OS as touched; freed stacks are pooled.
  - **Switching:** on macOS and Linux, a hand-written routine per architecture (arm64, x86_64 System V) saves the callee-saved registers on the old stack and loads the new stack pointer. On Windows the runtime uses Windows' fiber API (`CreateFiberEx`, `SwitchToFiber`) instead of its own routine, because Windows keeps each stack's bounds in the thread's information block: its unwinder, which mingw's `longjmp` uses (D-047), and its stack growth check them, and the fiber API keeps them right.
  - **The GC** scans the stack the running fiber is on, from its current position, and every other fiber's stack from where it was suspended. Registers are spilled onto the stack before every switch, so values held only in registers are scanned too (on Windows the fiber API saves them elsewhere).
  - **Per-fiber state:** the chain of condition frames (handlers, restarts, blocks, cancellation scopes) is saved and restored on every switch; the multiple-values registers stay per thread, since no switch happens between a return and the code that reads its values.
- **Alternatives:**
  - Hand-written switching on Windows too, updating the thread information block's stack fields on every switch. It depends on undocumented layout details that the fiber API already handles.
  - `ucontext` (`swapcontext`) on POSIX: deprecated on macOS, and it makes a system call per switch to save the signal mask.
  - **Stack overflow** (step 3): below a fiber's usable stack is a reserve, a 64 KB soft guard zone above the hard guard page on POSIX and Windows' stack guarantee (64 KB) on Windows. Overflowing into it faults; a handler (a signal handler on the thread's alternate signal stack on POSIX, a vectored exception handler on Windows) opens the reserve and makes the fiber continue in `sk_stack_overflow`, as if it had called it, which signals the error `stack-overflow`. The fiber can handle it like any error. When the fiber is next switched away with its stack above the reserve, the reserve is closed again (`mprotect`; `_resetstkoflw` on Windows), so it can overflow again later. A fault anywhere else is handled as it would be without the handler.
  - **The scheduler** (step 4, `runtime/src/sched.zig`) runs a queue of ready fibers on one thread: `spawn` queues a job in a fiber, `yield` puts the running fiber back at the end of the queue, `park` stops it until `wake`. A fiber is reused from the pool when its job finishes. It is internal to the runtime until M2.3 moves tasks, channels and sleeps onto it and spreads it over worker threads.
- **Consequences:** DESIGN §17.4 says Windows uses its fiber API. A thread's own stack (the main thread's, a worker's) has no reserve: overflowing it still crashes. Linux limits a process's memory mappings (`vm.max_map_count`, 65,530 by default on many distributions, 1,048,576 on Ubuntu 24.04), and each fiber stack takes two (three while its reserve is open), which bounds how many fibers can exist at once there. So at most 256 idle fibers keep their stacks; the others give them back and get a new one when they're reused (M2.3: CI's Linux runner couldn't start the scheduler's threads after a test left 100,000 idle stacks).

## D-075: The work-stealing scheduler
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.3 moves tasks, nurseries, channels and sleeps from OS threads (D-057) onto the fibers of M2.2, over a pool of worker threads (DESIGN §13.1, §17.4). Today the pool grows whenever no worker is idle, so a busy or blocked task never keeps another from running, and waits poll every 20 ms under one lock.
- **Decision:**
  - **Steps:** worker threads with work stealing; waiting on fibers; tasks, channels and sleeps on fibers; blocking C calls, foreign callbacks and the exit tests (ROADMAP).
  - **Workers:** one per CPU, each with a work-stealing deque, plus a shared injection queue; an idle worker sleeps until there is work. Fibers move between workers.
  - **Preemption** (Jessie chose): a fiber that has run for about 10 ms yields at its next safepoint (a function's entry or a loop's back-edge, which compiled code already polls for the GC), so busy tasks share the workers and can't starve the others, as they couldn't on threads.
  - **The main thread** runs `-main` on its own stack, not in a fiber, and waits by blocking, running the work queued for it (`on-main-thread`, `spawn-pinned :main`) meanwhile, as now. So do foreign threads.
  - **Thread-local state after a switch:** a fiber may continue on another thread after any wait or yield, and compilers may keep a thread-local's address across a call. Runtime code that can switch fibers reads thread-local state again after the switch through functions that aren't inlined.
- **Alternatives:**
  - Purely cooperative fibers, switching only when they wait or yield: simpler, but N busy fibers on N CPUs would keep every other fiber waiting.
  - Running `-main` in a fiber pinned to the main thread: windowing code needs the main thread, and nothing needs `-main` to park rather than block.
  - **Step 1** (`runtime/src/sched.zig`): each worker's deque and the injection queue are behind locks of their own; parking is a state machine on the fiber (running, parking, parked, queued, wake-requested), so a wake that comes before the fiber has finished switching away isn't lost. The monitor thread sets `sk_gc_pending`'s second bit while a preemption request is outstanding; the GC uses the first. The multiple-values registers are reached through functions in generated C (`skein.h`), and the condition chain, the current fiber and the GC's per-thread state through functions that aren't inlined.
  - **Step 2** (`runtime/src/wait.zig`): a waiter is a record on the waiting code's stack, which parks its fiber or, on a thread that isn't a worker, waits on a condition variable. Waiters queue under the identity number of what they wait for (objects move; identities don't), and whoever changes it notifies one or all, under the lock that guards it. A notification that comes before the waiter blocks makes it return at once. Deadlines go in a timer queue that the monitor thread fires, sleeping until the next one is due. A fiber records the waiter it's blocked on, so cancelling it can wake it (`interrupt`). Nothing touches a waiter after setting its flag, and a wait group finishes under its lock: the waiting side may return and free them at once.
  - **Step 3** (`runtime/src/tasks.zig`): each task runs in a fiber of its own; a task waiting for one is kept reachable in a queue the collector scans. The waits of D-057 keep their lock and checks, but queue under what they wait for: a task's finishing, a channel's takers or putters (separately), or the main thread's queue. A task and a nursery record the fiber running them, and cancelling one wakes that fiber; the waiting code checks for cancellation and attaches its waiter under the tasks lock, and `cancel!` decides whether the task had finished under it too, so neither can slip between. Transients and `:unsynchronized` slots are owned by a fiber, not a thread.
  - **Step 4:** a `^:blocking` C call, and `skein.io`'s file and process functions, mark their worker as blocked (`sched.blocking`); when one has been blocked for a millisecond while fibers wait, the monitor starts a spare worker, up to 256 in all, and a spare that finds no work for a while exits once enough others are running. A C thread the runtime doesn't know that calls a callback hands it to the scheduler as a temporary fiber and waits for it, so the callback can wait like any fiber; the C code passes the address of the callback's global, read in the fiber, where the collector keeps it current (D-068's attach-for-the-call stays for threads the runtime knows). Driftrock's job graph runs on fibers through nurseries.
- **Consequences:** a task that runs for a long time without calling anything still keeps its worker: safepoints are at function entries and loop back-edges, which compiled loops have. Runtime tests check preemption (one more busy fiber than workers still lets another run; it hangs with preemption off) and fibers moving between workers with their own condition frames.

## D-076: Dynamic vars
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.4 brings DESIGN §4.3's dynamic vars to native code. Phase 0 records `^:dynamic` on a var but never implemented `binding`, and `set!` of a var is a compile error, so there were no host tests to pass natively.
- **Decision** (Jessie chose the first three):
  - **Both implementations** get `binding`: Phase 0, which runs `skein run` until M2.6, as well as native code. A native fixture must print what `skein run` prints.
  - **A spawned task gets a copy** of the bindings in force where it's spawned: `set!` in it changes only what it, and the tasks it spawns afterwards, see.
  - **Binding a var that isn't `^:dynamic` is an error**, at compile time when the var is known then, else when the `binding` runs. Reads of ordinary vars stay as they are.
  - **Forms:** `binding` is a macro over `%with-bindings`, which takes the vars' qualified names, their values and a function of the body; `(set! *x* v)` on a `^:dynamic` var compiles to `%set-dynamic!`, and is an error outside a binding of it. A read of a var that's `^:dynamic` when the code is compiled finds the innermost binding, else the root value. The Core IR keeps its nodes; a var-ref of a dynamic var reads its binding (`docs/CORE-IR.md`).
  - **Natively,** a binding is a frame on the condition chain (D-047), so non-local exits drop it and each fiber has its own (D-074); a task's copy is pushed as such a frame when it starts.
  - **Steps:** Phase 0; native; a fixture compared with `skein run` (ROADMAP).
- **Alternatives:**
  - Native only, tested against expected output; programs with `binding` couldn't run under `skein run` until M2.6.
  - Clojure's rule that a thread may only `set!` bindings it established; or one binding shared by the parent and its tasks, which needs synchronization and races by nature.
  - Letting any var be bound dynamically: every var read would have to look for a binding.
- **Consequences:** a var declared `^:dynamic` after code that reads it was compiled is read as an ordinary var by that code, as in Clojure.

## D-077: Dynamic bindings natively
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.4 step 2 compiles D-076's `binding`, reads of dynamic vars and `set!` natively. Native vars are objects the compiler makes, with no table to find them by name at run time, so `%with-bindings` can't resolve names when it runs as Phase 0 does.
- **Decision:**
  - **The C backend resolves the vars** of `(%with-bindings '[names] "ns" values fn)` when it compiles the call, as it does for `defmethod` (D-054), and calls `sk_with_bindings` with them. A name nothing defines yet gets a var of its own in that namespace.
  - **A var object records whether it's `^:dynamic`**: `def` of a `^:dynamic` var sets the flag when it runs. `sk_with_bindings` checks it, so a binding of a var that didn't exist when the binding was compiled fails when it runs, with Phase 0's message.
  - **A binding frame** (`SK_FRAME_DYNAMIC`, runtime/src/dynamic.zig) holds a vector `[var value ...]`. A read walks the chain for the innermost frame that binds the var; `set!` replaces the frame's vector with one whose value has changed. A task's copy is one such vector, one pair per var, stored in the task and pushed when the task starts.
  - `(set! *x* v)` compiles to `sk_set_dynamic` with the var resolved from its qualified name, and a read of a var that's `^:dynamic` when compiled to `sk_dynamic_get`.
- **Alternatives:** a run-time table of vars by qualified name, which M2.5's evaluator may need anyway; a hash map per fiber instead of frames, which non-local exits would have to restore.
- **Consequences:**
  - A read of a dynamic var walks the condition chain: its cost grows with the frames above it. Hot dynamic reads could cache the innermost binding per fiber later.
  - The interpreter of phase-1 code (D-061) doesn't support `binding` yet; M2.5's evaluator needs it.
  - A name that resolves to nothing when compiled is assumed to belong to the namespace being compiled; if a later `:refer` brings in a var of that name, the binding still means the namespace's own var.

## D-078: Evaluating code in native programs
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.5 lets a running native program evaluate code, which the native REPL and `skein dev` (M2.6) build on. Phase 0 has no `eval` in skein.core; its REPL defines `reload`. Native vars have no table by name (D-077), and skeinc's namespaces are a model separate from the running program's vars (D-060). The exit asks for interpreted code within 10× of compiled code on n-body, which an evaluator written in Skein can't reach: it boxes every float.
- **Decision** (Jessie chose the first three):
  - **API:** skein.core gets `(eval form)` (a form as data, evaluated in the current namespace; returns its value), `(load-file path)` (evaluates a file's forms in order; returns the last value) and `(reload 'ns)` (loads the namespace's source file again), in Phase 0 too, so native results can be compared with `skein run`.
  - **Dev builds with `--eval` only** (Jessie chose the opt-in in step 2, when including the front end turned out to add about 5 s to every build): `skeinc build --eval` (dev profile; M2.6's `skein dev` will pass it) includes the reader, the expander, skein.core's macros and the evaluator, and registers the program's namespaces and vars at start-up. In any other build `eval`, `load-file`, `reload` and the `macroexpand` functions signal an error saying they need `--eval`.
  - **A closure compiler in Zig** (`runtime/src/eval/`) turns the Core IR maps that the front end makes into a tree of closures, and runs them. Locals live in frame slots; interpreted functions are runtime function objects, so compiled code calls them like any other. Where code declares types (D-056), the closures compute `f64` and integer values unboxed, as the C backend does.
  - **The program's namespaces:** at start-up an `--eval` build registers its namespaces (name, file, requires, aliases, refers) and its vars (with their flags) with the runtime (`runtime/src/evaluate.zig`), which only stores them. The first time the front end runs, `skein.compiler.env` builds its model from them (D-060), each model var pointing at the program's real var, through which its value is read and set; so code evaluated in a program finds and defines the program's own vars, with the expander unchanged. skeinc, built without `--eval`, keeps its model of the program it compiles separate from its own vars. An `--eval` build compiles the program's own macros in, as functions, and makes each namespace current while its code runs (`-main` runs in `user`). `eval` and its relatives are runtime functions that call what `skein.compiler.eval` installs.
  - **Reloading** evaluates the namespace's file again with the closure compiler: its functions then run interpreted, until hot reload of compiled code (M2.9). Redefinition follows DESIGN §15.
- **Alternatives:**
  - No public `eval` (only `reload` and `load-file`), or the functions in a `skein.dev` namespace.
  - The evaluator in every build, or behind a project key.
  - The closure compiler written in Skein, with the n-body target relaxed to about 50×.
  - Compiling evaluated code with zig cc and loading it: that is M2.9, too slow for each REPL form.
- **Consequences:**
  - `--eval` builds take about 5 s longer and are about 0.4 MB bigger; registering their vars at start-up is cheap (the model is built on first use). Other builds are unchanged.
  - The current namespace is one for the whole program natively, not one per task as in Phase 0.
  - Two evaluators exist for a while: `interp.skn` runs phase-1 code in skeinc (D-061), the Zig one runs code in programs. The Zig one could replace `interp.skn`, which would also give phase-1 code `binding` (D-077).
  - A program's current namespace becomes runtime state, as in Phase 0: each namespace's top-level forms run in it, `-main` runs in `user` (as in Clojure), `ns` and `in-ns` change it, `load-file` restores it afterwards, and a task starts in its spawner's.

## D-079: The evaluator natively
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.5 step 3 runs code evaluated in a program built with `--eval` (D-078). The Skein front end produces Core IR as maps; the evaluator is in Zig (D-078) and must match compiled code: closures, recur, non-local exits, conditions, multiple values, dynamic vars.
- **Decision:**
  - **Two halves.** `skein.compiler.eval` lowers a top-level form's Core IR into vectors with every name resolved: each local to a slot of its function's frame or to a value its closure captured, a `^:mutable` local that a closure uses to a box, each var to the program's real var (a skein.core function to its value), and recur to the slots it rebinds. `runtime/src/eval/compile.zig` turns those into a tree of nodes, each a function pointer and its operands, and runs it.
  - **Frames on the C stack:** an interpreted function is a runtime closure (its first captured value points at its compiled code), so compiled code calls it like any function. A call's locals are an array on the stack, sized per function (8, 32, 128 or 1024 slots), which the collector scans. recur sets a flag that the innermost loop or function sees.
  - **The C backend's rules:** multiple values as D-053 (a node compiled for a position whose values matter leaves them in the registers); `block*` and `unwind-protect` through C helpers in `unwind.c`, since Zig can't call setjmp; handler and restart clusters pushed as compiled code pushes them; `binding`, `set!` of a dynamic var and `defonce` as D-077.
  - **The model does the rest:** in an `--eval` program every var that the model makes for the program gets a real var, so env.skn's phase-1 versions of `defmethod`, `defstruct`, `defsoa`, `%class` and `%condition-type` act on the running program. The FFI's type definitions run as at phase 1; a `defcfun` or `defcallback` needs compiled C, so evaluating one again (reloading its namespace) keeps the compiled function, and a new one is an error.
  - `eval`, `load-file` and `reload` are Phase 0's: `load-file` starts in the current namespace and restores it, records the file of a namespace it declares, and `reload` loads in `user`. `require` of a namespace the program doesn't include loads it from the program's source paths.
- **Alternatives:** walking the Core IR maps from Zig on every evaluation (slower, and Zig would have to understand locals and captures); the lowering in Zig (more code in the language that's harder to change); a frame on the heap per call (an allocation per call).
- **Consequences:**
  - Compiled code can't name a var that only evaluated code defines: skeinc can't know it will exist. Compiled code expands a macro when it's built, so redefining the macro later doesn't change it (Phase 0 expands each form after the one before has run).
  - An interpreted call takes a few hundred bytes of stack, more than compiled code: recursion in an evaluated function goes about 500 to 1,000 levels deep on a fiber's 256 KB stack.
  - Declared types are used and checked as the C backend uses them since step 5 (below): the lowering infers static types with c.skn's rules (:f64, :int, :bool, arrays of f64 or fixnums; f32 stays boxed), and typed nodes compute raw values with the C backend's checks. A local that a closure captures stays boxed. Quoted data has no metadata, so code evaluated from a quoted form has only its `(declare (type ...))` types; code loaded from source keeps its `^type` hints.
  - Measured on n-body (`make bench`, Apple M4): evaluated code ran 137× slower than compiled code in the same dev build before step 5, and about 20× after it (0.21 s against 0.0104 s for 200,000 steps). Most of the remaining cost is one call per node; Zig's own safety checks cost almost nothing. M2.5's exit asked for 10×; Jessie chose to accept about 20× and set the exit at 25×, rather than fuse whole expression trees for an uncertain gain: hot reload of compiled code (M2.9) gives reloaded hot code native speed.
  - Compiled closures are never freed; evaluating is for development.
  - Evaluated code that names a compiled struct type in `make-array` or a struct field uses the name as written: the model only knows the struct types that evaluated code defined.

## D-080: Class redefinition natively
Date: 2026-11-10 · Status: Accepted
- **Context:** DESIGN §8.4 says redefining a class updates existing instances. Natively (D-054) a redefinition affected only new instances: an instance kept its slot values inline, after the layout it was made with, so it couldn't grow. M2.5 step 4 needs Phase 0's behavior, since a reloaded namespace redefines its classes.
- **Decision:**
  - An instance holds its class, the layout it was made with, its layout version and a tuple of its values (one more indirection on a slot access). A class's version changes only when a redefinition changes its slots' names, order or cell kinds, as Phase 0 (CLOS) only updates instances then.
  - An instance whose version is out of date is brought up to date the next time it's used (a slot read or write, `with`, `keys`, printing), as CLOS does: added slots get their `:init`, discarded ones are dropped, a slot that changed between immutable and `:atom` is wrapped or unwrapped, and then `update-instance-for-redefined-class` gets the instance, the added and discarded slots' keywords and a map of the discarded values.
  - Redefining a class recomputes its subclasses' precedence lists and slots, and clears every generic function's dispatch cache.
- **Alternatives:** updating every instance at redefinition (the runtime doesn't track instances); keeping the values inline and moving an instance that grows (identity would break).
- **Consequences:**
  - When one redefinition changes both a superclass's slots and a cell kind, Phase 0 updates a subclass's instances twice and wraps the cell twice (SBCL makes them obsolete twice); natively they're updated once. Tests make the two changes in separate redefinitions.
  - Two fibers that touch the same out-of-date instance at once may both update it.

## D-081: The native REPL and `skein dev`
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.6 moves `./skein run`, `dev` and `repl` from the SBCL host to the native runtime, with Phase 0's REPL, debugger and dev loop (D-039). Natively a program must be compiled before it runs (D-078: evaluating it from source can't create `defcfun`s), an unhandled error should suspend its fiber, and the runtime has no sockets, file dates or backtraces yet.
- **Decision** (Jessie chose the first two):
  - **`skein run` and `skein dev` build the program** with skeinc (dev profile, `--eval`) into `.skein-cache/`, reusing the executable while no source file it was built from has changed, then run it with the arguments. `eval`, `load-file` and `reload` work in both, as in Phase 0. `skein repl` runs a REPL program that the bootstrap builds once.
  - **`./skein host run|dev|repl ...`** runs Phase 0 on SBCL, as a reference; otherwise SBCL only bootstraps the compiler. The bootstrap check's expected outputs come from `skein host run`.
  - **The launchers** (`skein`, `skein.cmd`) send `build`, `package`, `run`, `dev` and `repl` to `build/skeinc`, after `skeinc current` says it's newer than its sources (else SBCL bootstraps it first); skeinc builds the program, or reuses `.skein-cache/run/`, whose manifest lists every source file the build read with its date, and skeinc's, then runs it on the same terminal (`%run-attached`) and exits with its status. `skein run --release` builds with the release profile, without the evaluator.
  - **The REPL and dev loop are Skein code** (`skein.dev`) in every `--eval` build, with Phase 0's behavior and plain-text protocol: the `namespace=> ` prompt, `*1` `*2` `*3` `*e`, `:quit`, the debugger's numbered restarts, `:bt` and nested `debug[N]` levels, the server on `localhost:5555` (`--port`, `--no-server`), and the watcher that reloads changed files every 0.25 s. `skein dev` tells the program to start them through the environment, before `-main` runs.
  - **The debugger on fibers:** an error with no handler calls the debugger in the failing fiber, which waits there while a REPL attaches; forms typed then are evaluated in that fiber, so its restarts and state are available. Errors in tasks still go to their nursery (D-037).
  - **The runtime gains** a localhost TCP server, file modification dates and reading the terminal (through std.Io on every platform, each wait handing its worker off), and backtraces from a shadow stack: in an `--eval` build each compiled function records its name and location on entry (a wrapper around its body), the evaluator does the same for interpreted functions, and every frame on the condition chain remembers the shadow stack's top, which an unwind restores. Walking frame pointers was the first plan, but nothing reliably tells a compiled Skein function's code from the runtime's.
- **Alternatives:** building without the evaluator for `skein run`; evaluating programs from source with a prebuilt runner (fast start, but about 20× slower and no new C bindings); dropping the SBCL path from `./skein` entirely.
  - **How it starts:** an `--eval` build includes `skein.dev`, and its `main` calls `skein.dev/run-main` with `-main`, the arguments and the program's namespace; that calls `-main` unless `SKEIN_DEV` is set (to a port, or `none`), when it runs the dev loop around it. **Output:** what code prints goes to the function bound to `skein.dev/*out*`, which the runtime checks, so a REPL client sees the output of the code it evaluates, and of the tasks that code spawns (they get a copy of the binding); other output goes to standard output, in one write per call.
- **Consequences:** the first `skein run` of a changed program waits for a build (about 7 s with the evaluator); later runs start at once. Phase 0 stays for bootstrapping, `skein host`, and its own test suite. Natively the consoles share the program's current namespace, switching it to their own around each form they evaluate. Messages for no console go to standard output: the runtime can't write to standard error yet.

## D-082: The Swank server
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.7 gives native `skein dev` the Swank server that D-018 chose, with SLIME as the reference client: evaluation, loading files, completion, argument lists, the debugger (SLDB) with Skein's restarts and backtraces, and the inspector. M2.6 built the plain-text REPL server (D-081), which inf-clojure uses.
- **Decision** (Jessie chose the first three):
  - **Both servers:** `skein dev` serves the text REPL on `localhost:5555` and Swank on `localhost:4005`, SLIME's default port (`--swank-port N`, `--no-swank`).
  - **`editors/skein-slime.el`** ships in the repository: it turns on `slime-mode` in `.skn` buffers (which use `clojure-mode`) and gives SLIME each buffer's namespace from its `ns` form. `docs/EDITORS.md` documents it.
  - **Testing:** host tests speak the Swank protocol directly on all three platforms; the Linux CI job also runs a scripted SLIME session (Emacs in batch mode) against native `skein dev`.
  - **The server is Skein code** (`skein.swank`) in `--eval` builds, beside `skein.dev`: Swank's framing (a six-digit hex length, then an s-expression), a reader and printer for the Common Lisp data SLIME sends (package-qualified symbols, `t` and `nil`, keywords, strings), and the `swank:` requests SLIME uses, answered with Skein's evaluator, its conditions and restarts, the shadow stack's backtraces and Skein's namespaces in place of CL packages. Errors in the program open SLDB in the connected Emacs, as debug sessions open in the text REPL (D-081).
  - **Steps:** the protocol, evaluation and loading; the debugger; completion, argument lists, documentation and the inspector; the Emacs helper and the scripted SLIME session.
- **Alternatives:** Swank only with `--swank`, or Swank replacing the text REPL; setup lines in the docs instead of an elisp file; running the SLIME session on all three platforms.
- **Consequences:** SLY (Slynk) still needs a compatibility check (D-018). VS Code's plain-text setup stays as it is.

## D-083: Each REPL evaluation has its own current namespace
Date: 2026-11-10 · Status: Accepted
- **Context:** natively the current namespace was one atom for the whole program (D-078). The text REPL's consoles switched it around each evaluation and switched it back afterwards. Swank runs requests at the same time (M2.7, D-082): a `C-x C-e` in a buffer while the listener is still evaluating, for example a game loop started from the REPL. One evaluation then restores the other's namespace, and the listener ends up in the buffer's.
- **Decision:** `skein.compiler.env` takes the current namespace from a hook, `%set-namespace-cell-hook!`. skein.dev installs a function that returns its dynamic var `*namespace-cell*`, and every console or Swank evaluation (`skein.dev/call-in`) binds that var to an atom of its own, starting at the console's namespace. Tasks the evaluation starts copy the binding, so they share it. Other code (the program, the file watcher) uses the shared atom as before. The hook exists because Phase 0's C backend, which compiles `env.skn` for the first compiler, has no `binding`; Phase 0's `%set-namespace-cell-hook!` does nothing, since its REPL binds `*current-namespace*` per thread.
- **Alternatives:** a lock around each evaluation, which would make a long listener evaluation hold up every other one, the program's debugger sessions included; a dynamic var in `env.skn` itself, which Phase 0's C backend can't compile.
- **Consequences:** `%current-namespace` calls the hook in `--eval` programs (one dynamic var read). The program's own code still shares one current namespace between its tasks.

## D-084: SLDB natively
Date: 2026-11-10 · Status: Accepted
- **Context:** M2.7 step 2 gives Swank's debugger (D-082). Swank runs it in the thread where the error happened, and Emacs sends the debugger's requests to that thread.
- **Decision:**
  - **Requests:** an error in a request runs SLDB in the request's fiber, inside a handler, so the error's restarts and dynamic state are there. It sends `(:debug thread level condition restarts frames pending)` and `:debug-activate`, then answers the requests Emacs sends for that thread in that fiber until a restart unwinds out (`:debug-return`). Thread ids are per connection: the listener is 1, and other fibers get one when they first need debugging. Each request has an `abort` restart ("Return to SLIME's top level.", or "Return to sldb level N." inside the debugger), which answers `(:abort message)`.
  - **The program:** an error that no handler handles goes to `skein.dev`'s debugger, which first runs SLDB in the newest Swank connection, in the failing fiber. If no Emacs is connected, or it disconnects before a restart is chosen, the text REPL's debug session takes over, as in D-081.
  - **Read and compile errors** in what a request evaluates answer `(:abort message)` without the debugger: no code ran, and the backtrace would only show the compiler.
  - **Backtraces:** frames are the shadow stack's Skein functions between the error and the evaluator or the program's start; a frame's source location is where its function is defined. There are no frame locals yet.
  - **Restarts** keep Skein's names (`abort`, `use-value`), not CL's upper-case ones.
- **Alternatives:** sending program errors to the text REPL as well and letting the first console claim them; opening SLDB for read and compile errors, as SBCL's Swank does.
- **Consequences:** a restart that takes arguments can't be chosen from SLDB (or from the text REPL's debugger): Skein restarts can't say how to ask for their arguments. Interrupting a running evaluation (`C-c C-c` in the REPL) needs a way to signal a running fiber, which the runtime doesn't have yet.

## D-085: Package management before Driftrock is developed live
Date: 2026-11-10 · Status: Accepted
- **Context:** DESIGN §20.2 sketched `:deps` in `project.skn` ("git-based at first", a registry deferred), but no milestone built it. Jessie asked for package management: libraries downloaded from GitHub, or taken from local files and folders.
- **Decision** (Jessie's): a new milestone, M2.11 Package management, goes before Driftrock developed live, which becomes M2.12, so Phase 2 still ends with Driftrock and its retrospective (this changes D-072's order). Its syntax, fetching, cache, lock file and transitive dependencies are settled when it's prepared.
- **Alternatives:** next, after the Swank server; at the end of Phase 2; or in Phase 3, beside the package registry.
- **Consequences:** Phase 2 has twelve milestones. Libraries such as the SDL3 bindings can later move to repositories of their own.

