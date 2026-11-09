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
