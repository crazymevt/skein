# Skein Design Document

**Status:** Draft v0.1. This is the source of truth for language semantics and implementation architecture.
**Rule:** if the implementation needs to differ from this document, record the change in [`DECISIONS.md`](DECISIONS.md) and update this file in the same commit.

Sections marked **(Tentative)** are expected to change once there is implementation experience. Sections marked **(Deferred)** describe intent but are out of scope until a later phase.

---

## Contents

1. [Vision and non-goals](#1-vision-and-non-goals)
2. [Guiding principles](#2-guiding-principles)
3. [Reader and lexical syntax](#3-reader-and-lexical-syntax)
4. [Evaluation model, namespaces and phases](#4-evaluation-model-namespaces-and-phases)
5. [Special forms and core macros](#5-special-forms-and-core-macros)
6. [Data types](#6-data-types)
7. [Equality, hashing and sequences](#7-equality-hashing-and-sequences)
8. [Object system](#8-object-system)
9. [Value structs and typed arrays](#9-value-structs-and-typed-arrays)
10. [Conditions and restarts](#10-conditions-and-restarts)
11. [Macros](#11-macros)
12. [Types, declarations and optimization](#12-types-declarations-and-optimization)
13. [Concurrency](#13-concurrency)
14. [Foreign function interface](#14-foreign-function-interface)
15. [Live development](#15-live-development)
16. [Compiler architecture](#16-compiler-architecture)
17. [Runtime architecture (Phase 1+)](#17-runtime-architecture-phase-1)
18. [Memory management](#18-memory-management)
19. [Cross-platform build and distribution](#19-cross-platform-build-and-distribution)
20. [Tooling](#20-tooling)
21. [Standard library outline](#21-standard-library-outline)
22. [Open questions](#22-open-questions)

---

## 1. Vision and non-goals

**Vision.** Skein is a Lisp for building games and desktop applications. It aims for the interactive, live-modifiable development experience of Common Lisp, the safe concurrent data model of Clojure, and the disciplined compile-time model of Racket, all compiled to fast native executables for Windows, macOS and Linux.

**Primary users.** Solo developers and small teams making games, game tools and desktop apps.

**Goals**
- Native executables with no external VM, cross-compiled from a single host.
- Performance within roughly 1.5–3× of C on declared, hot code.
- Garbage collection whose pauses fit in a frame budget (target: under 1 ms typical, under 4 ms worst case for nursery collections).
- Live redefinition of functions, classes and methods in a running program.
- Concurrency that is safe by default and fast when needed.
- Calling C libraries should be routine, ideally starting from bindings generated from headers.

**Non-goals (for now)**
- A static type checker. Typing is dynamic with optional declarations; see §12. A gradual type system may come later, and the declaration syntax should not prevent it.
- JVM, CLR or JavaScript targets.
- Native OS GUI widget toolkits. Desktop UI goes through GPU-drawn UI (e.g. Dear ImGui) first.
- Binary compatibility with Common Lisp, Clojure or Racket code. Skein borrows ideas, not libraries.
- Embedded or microcontroller targets.

## 2. Guiding principles

When goals conflict, prefer the earlier item:

1. **Ship something playable early.** Prefer designs that a single developer can implement incrementally.
2. **Live development must never break.** Features that make redefinition unsafe are opt-in, for example sealing in release builds.
3. **Safe by default, fast on request.** Immutable data, checked declarations and bounds checks are the default. Speed comes from explicit declarations and policies.
4. **One obvious way.** When Common Lisp, Clojure and Racket each offer a different mechanism, pick one; don't ship all three.
5. **Data first.** Plain persistent data (maps, vectors) is the default modeling tool. Classes are for behavior, dispatch and identity.

## 3. Reader and lexical syntax

The reader follows **Clojure's conventions** unless noted.

| Syntax | Meaning |
|---|---|
| `(a b c)` | list / call form |
| `[a b c]` | persistent vector |
| `{:a 1 :b 2}` | persistent hash map |
| `#{1 2 3}` | persistent hash set |
| `:kw`, `:ns/kw` | keyword; `::kw` resolves to the current namespace |
| `sym`, `ns/sym` | symbol |
| `"text"` | string (UTF-8, immutable) |
| `\a`, `\newline`, `\λ`, `\u00e9` | character |
| `42`, `-7`, `0xFF`, `0b1010`, `1_000_000` | integer |
| `3.14`, `1e-9` | f64 float |
| `3.14f`, `1.0f` | f32 float |
| `##Inf`, `##-Inf`, `##NaN` | f64 infinities and NaN |
| `nil`, `true`, `false` | literals |
| `'x` | `(quote x)` |
| `` `x `` | syntax-quote (namespace-resolving; see §11) |
| `~x`, `~@xs` | unquote, unquote-splicing |
| `@x` | `(deref x)` |
| `^type x`, `^{:k v} x` | metadata / type hint on the next form |
| `#(+ % 1)` | anonymous function shorthand (`%`, `%1`, `%2`, `%&`) |
| `#_form` | discard the next form |
| `; comment` | line comment |
| `#\| ... \|#` | block comment (nestable) |
| `,` | whitespace |

Notes:
- Commas are whitespace. Unquote is `~`, as in Clojure, not `,` as in Common Lisp.
- Symbols are case-sensitive.
- The reader produces **syntax objects** that carry source location (file, line, column). The compiler uses them for error messages and for future hygiene (§11).
- There is no user-programmable readtable in v1. Tagged literals `#tag form` are reserved for later.

### 3.1 Literal details (D-029)
- **Integers:** decimal, `0x`/`0X` hex and `0b`/`0B` binary, with an optional `+` or `-` sign. `_` may appear only between two digits. Leading zeros are an error (`007`): there are no octal literals.
- **Floats:** a decimal point needs digits on both sides (`5.` and `.5` are not floats; `.5` reads as a symbol). The `f` suffix makes an `f32` and needs a float (`1.0f`, `1e5f`; `1f` is an error). Floats are correctly rounded. A literal too large for its type is an error; one too small rounds to zero.
- **Strings:** escapes are `\n \t \r \b \f \" \\` and `\uXXXX`. A UTF-16 surrogate pair of `\u` escapes combines into one code point; a lone surrogate is an error. A CRLF line ending inside a string literal reads as `\n`, so source files behave the same whatever line endings they were checked out with.
- **Characters:** `\x` for any single character, the names `newline space tab backspace formfeed return`, and `\uXXXX` (not a surrogate).
- **Symbols and keywords** may contain any character except whitespace, commas and `` " ; @ ^ ` ~ ( ) [ ] { } \ ``. Symbols compare by value (`=`), not identity. A symbol can't start with a digit, or with `+` or `-` followed by a digit, since that reads as a number. At most one `/` separates the namespace (`ns/name`); `/` alone and `ns//` name division. Parts may not start or end with `:` or contain `::`. `::alias/kw` uses an alias of the current namespace.
- **Metadata:** `^sym`, `^"str"` and `^(type form)` mean `{:tag ...}`; `^:kw` means `{:kw true}`; `^{...}` is used as is. Stacked metadata merges, with the outer (leftmost) entry winning. Metadata can be attached only to symbols and collections.
- **Prefix forms** read as lists: `'x` → `(quote x)`, `` `x `` → `(skein.core/syntax-quote x)`, `~x` → `(skein.core/unquote x)`, `~@x` → `(skein.core/unquote-splicing x)`, `@x` → `(skein.core/deref x)`.
- **`#(...)`** reads as `(fn [%1 %2 ...] body)`, with parameters up to the highest `%N` used, plus `& %&` if `%&` appears; `%` means `%1`. `#()` forms cannot nest.
- **Map and set literals** with duplicate keys or elements are read errors.

## 4. Evaluation model, namespaces and phases

### 4.1 Lisp-1
Skein is a **Lisp-1**: functions and variables share one namespace. `(f x)` evaluates `f` like any other expression.

### 4.2 Truthiness
Only `nil` and `false` are falsy. Everything else is truthy, including `0`, `""` and `()`.

### 4.3 Namespaces and vars
- Code lives in **namespaces**, declared with `ns`. One file holds one namespace, and the namespace `game.player` lives in `game/player.skn`.
- A top-level `def` creates a **var**: a named, mutable-by-redefinition cell. **References to global functions go through the var.** That is what makes live redefinition work (§15). Release builds may direct-link sealed vars (§12.5).
- `(ns game.player (:require [skein.math :as m] [game.world :refer [spawn-at]]))`
- Private definitions: `defn-` or `^:private`.
- **Dynamic vars** with thread/fiber-local rebinding: `(def ^:dynamic *log-level* :info)` and `(binding [*log-level* :debug] ...)`. Bindings are inherited by fibers spawned inside the `binding` form. Details (D-076): a task gets a copy of the bindings in force where it's spawned, so `set!` in it changes only what it (and the tasks it spawns later) sees; `(set! *x* v)` changes the innermost binding of `*x*` and is an error outside one; binding a var that isn't `^:dynamic` is an error. A var must be declared `^:dynamic` before code that reads it is compiled.

### 4.4 Phases
Following Racket, code runs either at **compile time (phase 1)**, which is macro expansion, or at **run time (phase 0)**.

- A macro body runs at phase 1. Any function a macro *calls* during expansion must come from `skein.core`, from the macro's own namespace (definitions earlier in the file), or from a namespace required **for syntax**, `(:require-for-syntax [my.helpers :as h])`, including what that namespace itself requires (D-033).
- The same namespace may be instantiated separately in each phase. State created at compile time is **not** visible at run time.
- **Why:** when cross-compiling, phase 1 runs on the build machine and phase 0 code is compiled for the target. Mixing them, as Common Lisp's `eval-when` does, causes subtle cross-compilation bugs.
- **Phase 0 implementation note:** the SBCL host runs both phases in one image. It must still *record* phase information and *warn* when phase-0 code is called during expansion without `:require-for-syntax`. Phase 1 of the roadmap (the native compiler) enforces the rule.
- **Native compiler (D-058):** at phase 1, the native compiler runs only a namespace's `ns` form, its `defmacro`s, its `def`s whose value is a function, and its struct, class and condition-type definitions, in every namespace it compiles, the program's and the ones it requires. Other top-level forms, such as a `println` or a `def` of computed data, run only at phase 0, in the built program. Phase-1 code runs in an interpreter (D-050).
- The native compiler warns about a phase violation as Phase 0 does, with the same message, and the macro still runs (D-061).

**Implementation status at the end of Phase 1** (M1.12, `docs/PHASE1-RETRO.md`): programs are compiled natively by `skeinc`, the compiler written in Skein, which compiles itself (`skein build`, `skein package`, for every §19.1 target). Native programs have the whole language and the libraries Driftrock uses: `skein.core`, conditions and restarts, the object system, value structs and typed arrays, tasks, nurseries and channels on OS threads, the FFI, `skein.math`, `skein.time`, `skein.jobs`, `skein.game` and `skein.io`. Live development (`skein run`, `dev` and `repl`) still runs on the Phase 0 SBCL host until Phase 2 brings fibers, a native REPL and reloading.

## 5. Special forms and core macros

### 5.1 Special forms (the compiler understands only these)

| Form | Purpose |
|---|---|
| `(quote x)` | literal datum |
| `(if test then else?)` | conditional |
| `(do e1 e2 ...)` | sequencing |
| `(def name value?)` | define or redefine a var |
| `(fn name? [params] body...)` | function; multiple arities `(fn ([x] ..) ([x y] ..))`; rest args `[x & more]` |
| `(let* [name val ...] body...)` | sequential local binding without destructuring |
| `(letfn* [(f [..] ..) ...] body...)` | mutually recursive local functions |
| `(loop* [name val ...] body...)` / `(recur ...)` | explicit tail loop |
| `(set! place value)` | assign a local declared `^:mutable`, a dynamic var binding, or an `:unsynchronized` cell |
| `(throw-condition c)` | signal the condition `c`; if no handler unwinds, it is unhandled (the primitive under `error`) |
| `(handler-bind* [type-expr handler ...] body...)`, `(restart-bind* [name fn report ...] body...)` | condition-system primitives (§10); restart names are unevaluated symbols |
| `(unwind-protect body cleanup...)` | guaranteed cleanup |
| `(block* tag body...)` / `(return-from* tag v)` | lexical non-local exit |
| `(values a b ...)` / `(let-values* [[a b] expr] body...)` | multiple values |
| `(the type expr)` | type assertion/hint |
| `(declare ...)` | declarations at the start of a body (§12) |
| `(%ffi-call ...)` | primitive foreign call (used by the FFI macros only) |

### 5.2 Core macros (defined in Skein, in `skein.core`)
`let` and `loop` with destructuring, `defn`, `defn-`, `defmacro`, `when`, `when-not`, `if-let`, `when-let`, `cond`, `case`, `and`, `or`, `->`, `->>`, `as->`, `some->`, `doto`, `dotimes`, `doseq`, `for` (lazy comprehension), `while`, `try` (sugar over `handler-case` + `unwind-protect`), `with-open`, `defclass`, `defgeneric`, `defmethod`, `defstruct`, `defcondition`, `with-nursery`, `binding`.

### 5.3 Tail calls
- `loop`/`recur` is the guaranteed way to write constant-stack iteration. `recur` must be in tail position, and the compiler checks this.
- General tail-call optimization is **best effort**. The native backend emits `musttail` where it can. Programs must not depend on general TCO.

### 5.4 Destructuring
Clojure-style destructuring in `let`, `fn` parameters, `loop` and `doseq`:
`[a b & rest :as all]`, `{:keys [x y] :or {y 0} :as m}`, `{:strs [...]}`, `{:syms [...]}`, `{x :x}`, namespaced keys (`{:keys [ns/a]}` or `{:ns/keys [a]}`), nested patterns, and keyword arguments (`[& {:keys [a]}]`). The front end's `destructure` function (callable from macros) turns a binding vector with patterns into one that binds only symbols; the `fn` special form destructures its parameters by wrapping its body in `let`.

## 6. Data types

### 6.1 Atoms (scalars)

| Type | Notes |
|---|---|
| `nil` | the absence of a value; also the empty seq |
| `boolean` | `true`, `false` |
| `integer` | arbitrary precision. A **fixnum** fast path covers 62-bit signed values and overflow promotes to a bignum. Declared machine types (`i32`, `i64`, `u8`, …) wrap or error according to policy (§12) |
| `f64`, `f32` | IEEE floats; `f64` is the default literal type |
| `char` | a Unicode scalar value |
| `string` | immutable, UTF-8; indexed by code point (§6.5) |
| `keyword` | interned; usable as a function on maps and objects: `(:pos s)` |
| `symbol` | interned name with optional namespace |

**Arithmetic:** `+ - *` follow numeric contagion: integer op integer gives an integer; any float makes the result a float; `f32` op `f64` gives `f64`. **`/` on integers always returns `f64`.** Use `quot`, `rem` and `mod` for integer division. There are **no ratios** in v1 (D-026).

**Conversions** are named after the type they produce (D-040): `(f32 x)`, `(f64 x)`, and `(int x)`, which truncates toward zero. As in Clojure, `(int \a)` gives a character's code point (97) and `(char 97)` the character with a code point (D-048). `(rand)` and `(rand n)` give an `f64` in [0, n); `(rand-int n)` an integer in [0, n). `(parse-long s)` reads a decimal integer, or returns `nil`.

**Integer overflow:** arithmetic on values known only to be `integer` always promotes to a bignum on fixnum overflow, at every optimization policy, including `speed 3` (D-023). Fixnum-only arithmetic happens only when operands and result are declared or inferred `fixnum` or a machine integer type; overflow of those follows §12.3.

### 6.2 Persistent collections (immutable, structurally shared)

| Type | Implementation | Complexity |
|---|---|---|
| list | singly linked cons cells | O(1) `cons`/`first`/`rest` |
| vector | 32-way trie with tail (Clojure `PersistentVector`) | O(log₃₂ n) access, update and append |
| hash-map | HAMT (hash array mapped trie) | O(log₃₂ n) |
| hash-set | HAMT | O(log₃₂ n) |
| sorted-map / sorted-set | persistent red-black tree **(Deferred)** | O(log n) |
| queue | persistent queue **(Deferred)** | amortized O(1) |

- Small maps of up to 8 entries use an **array map** representation for speed.
- **Transients** (`transient`, `conj!`, `assoc!`, `persistent!`) provide fast batch construction. A transient is owned by the fiber that created it; using it from another fiber is an error in safe mode.
- Maps and sets keep no insertion order. (Array maps happen to iterate in insertion order; programs must not rely on it.)
- Collections carry no runtime metadata in v1; metadata is a property of syntax (§3) (D-032).
- Map entries are two-element vectors: `(first {:a 1})` is `[:a 1]`.

### 6.3 Mutable and reference types

| Type | Purpose |
|---|---|
| `atom` | a single value updated by compare-and-swap: `swap!`, `reset!`, `compare-and-set!`; read with `@a` |
| `ref` | an STM-managed cell **(Deferred; name reserved)** |
| `volatile` | an unsynchronized fast box for single-fiber use |
| `array` | a mutable, fixed-length, typed array (§9) |
| `chan` | a channel (§13) |

### 6.4 Functions
Functions are first-class closures with multiple arities and variadic arguments. Keywords, maps, sets and vectors are callable: `(m :k)`, `(:k m)`, `(v 0)`, `(s x)`.

### 6.5 Strings
Strings are immutable UTF-8. String operations (`nth`, `count`, `subs`, `seq`) work in **code points** (D-019).
- `count` is O(1): the code-point count is recorded when the string is created.
- Indexing is O(1) for pure-ASCII strings (also recorded at creation) and O(n) otherwise.
- `skein.string` provides byte-offset cursors (`string/cursor`, `string/next`, …) for walking non-ASCII text quickly, e.g. in parsers.

## 7. Equality, hashing and sequences

- `=` is **value equality** for scalars, strings, persistent collections and value structs. `(= [1 2] '(1 2))` is `true`, as in Clojure: sequential collections compare by elements.
- Integers and floats are **not** `=` (`(= 1 1.0)` is `false`). `f32` and `f64` compare by value (`(= 1.0 1.0f)` is `true`). `==` is numeric equality across types.
- **Class instances** compare by **identity** unless the generic function `equiv` has a method for that class. If `equiv` is specialized, `hash-of` must be too, and the compiler warns when only one is.
- `identical?` is pointer identity.
- `hash-of` is consistent with `=`.

**Sequences.** `seq` returns `nil` or a sequence view of any collection, string, array or `nil` ("nil punning": `(first nil)` is `nil`). Lazy sequences are supported (`lazy-seq`, `map`, `filter`, `range`, …). They are realized **one element at a time**, never in chunks, so `(first (map f xs))` calls `f` once (D-032). **Transducers** (`map`, `filter` and friends called with no collection, plus `comp`, `transduce`, `into`, `sequence`, `eduction`) are the preferred tool in performance-sensitive code, because they allocate no intermediate sequences.

## 8. Object system

The object system is CLOS-inspired, with two departures: **slots are immutable by default** and the syntax is Clojure-flavored.

### 8.1 Classes

```clojure
(defclass entity []
  (id :type uuid :init (uuid/random) :reader entity-id))

(defclass ship [entity]                       ; superclasses in a vector; multiple inheritance allowed
  (pos   :type vec2 :init (vec2 0.0f 0.0f))
  (angle :type f32  :init 0.0f)
  (hp    :type i32  :cell :atom :init 100)    ; mutable via an atom
  (scratch :type (array f32) :cell :unsynchronized))  ; fiber-local mutation
```

Slot options:

| Option | Meaning |
|---|---|
| `:type` | declared type; checked in safe mode and used by the optimizer |
| `:init` | default value expression, evaluated per instance |
| `:reader` | defines a reader function (a generic function) |
| `:cell` | makes the slot mutable. Value: `:atom`, `:ref` (deferred), or `:unsynchronized` |
| `:doc` | documentation string |

**Class precedence list:** C3 linearization, as in Dylan and Python. It is more predictable than the CLOS algorithm in edge cases.

### 8.2 Instances
- `(make ship :pos (vec2 1.0f 2.0f))` creates an instance and calls the generic function `initialize`.
- `(:pos s)` or `(slot s :pos)` reads a slot. For a cell slot this returns the cell's **current value** (D-041). `(set-slot! s :hp 50)` sets a cell slot and `(update-slot! s :hp - 5)` updates it; on an `:atom` cell both are atomic, `update-slot!` retrying like `swap!`. Both return the new value. `(cell s :hp)` returns the atom itself, for `add-watch` or passing the cell around. Immutable slots cannot be set or updated.
- `(with s :angle 1.5f :pos p)` returns a **new instance** with the given immutable slots changed. Cell slots are copied *by reference*, so the new and old instance share the cell. To give the copy fresh cells, use `(with s ... :fresh-cells true)`.
- Instances are not maps, but they support `keys`, `get` and destructuring with `{:keys [pos angle]}`.
- An `:unsynchronized` slot is changed with `set-slot!`/`update-slot!` or with `set!` on the slot, `(set! (:scratch s) arr)`, and has no cell object. In safe mode, the runtime records the owning fiber and signals an error if another fiber mutates it.

### 8.3 Generic functions and methods

```clojure
(defgeneric collide [a b]
  "Resolve a collision between two game objects.")

(defmethod collide [(a ship) (b asteroid)] ...)
(defmethod collide [(a ship) (b (= :wall))] ...)   ; eql specializer
(defmethod collide :before [(a ship) b] (log/debug "ship hit" b))
(defmethod collide :around [a b]
  (when (alive? a) (call-next-method)))
```

- **Multiple dispatch** on the classes of all required arguments. Built-in types have classes too (`integer`, `f32`, `string`, `vector`, `hash-map`, `keyword`, `nil-class`, …).
- **Standard method combination:** `:before`, `:after`, `:around` and primary methods, with `call-next-method` and `next-method?`.
- **User-defined method combinations (Deferred).**
- **Dispatch performance:** each generic function keeps a per-call-signature dispatch cache that is invalidated on redefinition. Sealed generics can be dispatched at compile time (§12.5).
- A `defn` function is not generic. Converting one into a generic function is a redefinition and is allowed at the REPL.

Details (D-035):
- A class name in a specializer (or in `make`, `instance?`) is a class defined with `defclass`, a condition type, or one of the built-in names: `any`, `object`, `nil-class`, `integer`, `float`, `f32`, `f64`, `number`, `char`, `string`, `keyword`, `symbol`, `vector`, `hash-map`, `hash-set`, `list`, `seq`, `fn`, `atom`, `condition`, `error`, `warning`. `true` and `false` have no class of their own; specialize on them with `(= true)`.
- `defmethod` creates the generic function if there is none; its parameters must match the generic function's (same number of required parameters, and a rest parameter or not).
- The generic function `initialize` is called by `make` after the slots are filled. `equiv` and `hash-of` are generic functions whose default methods use identity for instances; a warning is given at the end of a file that specializes one but not the other for a class.
- `(with s :hp 7)` on a cell slot gives the copy a fresh cell holding 7.
- `:type` is recorded but not checked until declarations arrive (M0.8). Custom metaclasses written in Skein, and `:cell :ref`, are not supported yet.
- Natively (Phase 1, D-054), every value has a class: defclass classes, the built-in classes above (with `list` under `seq`, `f32` and `f64` under `float`, and `float` and `integer` under `number`), and a class per condition type. A generic function is a closure over its methods and a dispatch cache keyed by the classes of the required arguments; a generic function with eql specializers skips the cache. Precedence lists end in `object` and `any`.

### 8.4 Redefinition
Redefining a class at the REPL **updates existing instances**:
- Added slots get their `:init` value.
- Removed slots are dropped.
- The generic function `update-instance-for-redefined-class` can be specialized to migrate data. Its parameters are the instance, a vector of added slot keywords, a vector of discarded slot keywords, and a map of the discarded slots' values.
- Changing a slot from immutable to cell (or the reverse) wraps or unwraps its current value.

### 8.5 Meta-object protocol
Classes, generic functions, methods and slot definitions are themselves instances (`standard-class`, `standard-generic-function`, …). The MOP exposes:
- introspection: `class-of`, `class-slots`, `class-precedence-list`, `generic-methods`, …
- extension: custom metaclasses (`:metaclass`) that can customize slot access, instance allocation and validation.

The MOP is **introspection-first** in Phase 0. Metaclass customization is supported in the SBCL host because it maps onto CLOS's MOP, and is kept to a documented subset in the native runtime.

## 9. Value structs and typed arrays

These are the tools for hot loops: no per-element allocation, no pointer chasing.

### 9.1 Value structs

```clojure
(defstruct vec2 :value
  (x f32) (y f32))

(defstruct particle :value
  (pos vec2) (vel vec2) (life f32))
```

- **Immutable, unboxed and stored inline** when the type is known: in arrays, in other structs, and in typed slots and locals.
- There is no inheritance and no identity, and `=` compares fields.
- The constructor is positional, `(vec2 1.0f 2.0f)`, or keyword-based, `(vec2 :x 1.0f :y 2.0f)`. Accessors are `(:x v)` and `(vec2-x v)`; `with` makes an updated copy. `(vec2? x)` tests the type (D-041).
- They can be specialized on by methods (`(defmethod draw [(v vec2)] ...)`). Passing a value struct where its type is unknown **boxes** it, and the compiler emits an efficiency note.
- Field types must be primitive types or other value structs.
- `(defstruct name ...)` without `:value` defines a plain record class: a heap object with immutable fields and no MOP overhead.

### 9.2 Typed arrays

```clojure
(def verts (make-array f32 4096))           ; mutable, fixed length, zero-initialized
(aset! verts 0 1.5f)
(aget verts 0)
(def ps (make-array particle 10000))        ; array of inline value structs
(update! ps i :life - dt)                   ; in-place field update
```

- The element type is any primitive or value-struct type, or `any` for boxed values.
- Arrays are **mutable**, and by convention owned by one fiber at a time. Handing an array to a job transfers ownership; this is checked in safe mode where practical.
- Bounds are checked unless `(safety 0)`.
- **Struct-of-arrays layout:**

```clojure
(defsoa particles
  (pos vec2) (vel vec2) (life f32))

(def ps (make-particles 10000))
(pos ps i)                  ; read field of element i
(update! ps i :pos v+ dv)   ; update in place
```

`defsoa` generates parallel arrays and accessors. It is the building block for an ECS (entity–component–system) library.

### 9.3 Memory views
`(view arr start end)` gives a zero-copy slice. `(as-bytes arr)` gives a byte view for passing to C or GPU APIs. Views keep the underlying array alive.

### 9.4 Phase 0 details (D-036)
- Value structs and records are CL structs with typed, read-only slots. A value struct inside another is stored as a pointer, not flattened; arrays of value structs store every primitive field inline, one specialized array per field.
- The keyword constructor form names every field: `(vec2 :x 1.0f :y 2.0f)`. Records (plain `defstruct`) compare by their fields, like value structs.
- Redefining a struct with different fields creates a new layout and warns; existing values and code compiled against the old layout keep using it until reloaded (§15).
- `(array T)` declares a simple (non-view) array. `view` works on arrays of primitive types and returns a slice that `aget`, `aset!` and `count` accept but `(array T)` declarations do not.
- `update!` is `(update! coll i :field f args...)` for arrays of value structs and `defsoa` collections, and `(update! array i f args...)` for arrays of primitives. `defsoa name` defines an element value struct `name.element`, `make-name`, and a function `(field coll i)` per field.
- `as-bytes` works on arrays and views of primitive types; `count` of a byte view is its size in bytes.

### 9.5 Native details (D-055)
- A struct value is a runtime object holding its definition and fields; constructors check field types as Phase 0's typed slots do.
- Arrays of primitive types pack their elements at their natural width. Arrays of value structs keep one primitive array per leaf field, nested value structs flattened.
- `defstruct` and `defsoa` run on the host at compile time, and the C backend sets the vars they define (constructor, predicate, accessors, `make-name`, field functions) explicitly.

## 10. Conditions and restarts

Skein adopts the **Common Lisp condition system**, which separates *signaling* a problem, *deciding* what to do about it, and *recovering*.

```clojure
(defcondition asset-missing [error]
  (path :reader asset-path))

(defn load-texture [path]
  (restart-case
    (if (exists? path)
      (gpu/upload (image/read path))
      (error 'asset-missing :path path))
    (use-placeholder [] placeholder-texture)
    (retry [] (load-texture path))
    (use-path [p] (load-texture p))))

(handler-bind [asset-missing (fn [c] (invoke-restart 'use-placeholder))]
  (load-level "level-1"))
```

| Operation | Meaning |
|---|---|
| `signal` | announce a condition; returns `nil` if no handler takes action |
| `warn` | signal, then print a warning if unhandled |
| `error` | signal, then enter the debugger (dev) or the fiber's supervisor (release) if unhandled |
| `handler-bind` | handlers run *without unwinding*, so restarts are still available |
| `handler-case` / `try` | unwinding handlers, like conventional exceptions |
| `restart-case` | establish named restarts |
| `invoke-restart`, `find-restart`, `compute-restarts` | choose recovery |

Details (D-034):
- `(defcondition name [parents] doc? (slot :reader f :initform expr)... (:report f)?)` defines a condition type and a var `name` holding it. Parents default to `[condition]`. Slots are also readable with keywords: `(:path c)`.
- `(error x & args)`, `(signal x & args)` and `(warn x & args)` take a condition, a condition type (or a symbol naming one, looked up in the current namespace, then globally if the name is unique) followed by keyword initargs, or a message string whose arguments are joined like `println`'s. `signal` returns `nil` when no handler takes action.
- Built-in types include `condition`, `error`, `warning`, `arithmetic-error`, `type-error`, `index-error`, `arity-error` and `unbound-var-error`. Host errors such as division by zero are conditions of these types. Natively, a fiber that runs out of stack signals the error `stack-overflow` (M2.2, D-024).
- `(handler-case expr (type [c] body...)...)`, and `(try body... (catch type e body...)... (finally body...))` as in Clojure.
- `(restart-case expr (name [params] :report "text"? body...)...)`; `invoke-restart`, `find-restart`, `compute-restarts`, `restart-name` and `restart-report`. CL's standard restarts (`abort`, `continue`, `muffle-warning`, `use-value`, `store-value`) can be invoked by name. A restart value can safely outlive its `restart-case`; invoking it afterwards is an error. Restarts match by their **plain name**, ignoring any namespace: a restart a syntax-quoted macro establishes as `skein.game/retry-frame` is found by `(invoke-restart 'retry-frame)` (D-041). As in CL, the innermost restart with a name wins.
- When `skein run` meets an unhandled error, it prints the message and the restarts that were active.
- Natively (Phase 1, D-047), handler and restart clusters, blocks and unwind-protects are frames on a per-thread chain kept in compiled code's C stack frames. Unwinding uses setjmp/longjmp, which on Windows unwinds through SEH. The runtime's own errors (division by zero, bad indexes, arity errors, ...) are conditions of the built-in types. An unhandled error prints as under `skein run` and exits with status 1.

**Conditions and concurrency.** This is the feature that sets Skein apart.
- Each fiber has its own handler and restart stack.
- An unhandled `error` in a fiber **suspends the fiber** and reports it to the fiber's **supervisor**. By default that's the enclosing nursery, and ultimately the root supervisor.
- In **development**, the root supervisor opens the debugger at the REPL: inspect the stack, redefine code, then pick a restart. The fiber resumes.
- In **release builds**, supervisors apply a policy: `:cancel-siblings` (the default for nurseries), `:restart-fiber`, `:ignore` or `:crash`.
- A nursery's policy is its option map's `:on-error`: `(with-nursery [n {:on-error :restart-fiber}] ...)` (M2.8, D-088). `:cancel-siblings` cancels the other tasks and re-signals the failure where the nursery joins; `:ignore` lets the task fail alone and prints one line on stderr; `:crash` reports the error as an unhandled one and exits with status 1; `:restart-fiber` runs the task's function again from the start, with a line on stderr, at most `:max-restarts` times (3) within `:within` seconds (5.0), then fails as `:cancel-siblings`. Other keys, or another policy, are errors; detached `future`s have no nursery and keep their error for `deref`. In `skein dev` the debugger comes first, in the failing task's fiber; its `abort` restart fails the task, and then the policy applies. A failed task's `deref` re-signals its error under every policy.
- The game loop helper (`skein.game/run-loop`) establishes `retry-frame` and `skip-frame` restarts around each frame.

## 11. Macros

### 11.1 Phase 0–1: `defmacro` with namespace-resolving syntax-quote
- `defmacro` receives its arguments as **plain data** (lists, vectors, maps, symbols) and returns data, as in Clojure (D-033). The expander keeps the source location and metadata of every symbol and collection the macro passes through unchanged; new forms get the location of the macro call. Syntax objects stay internal until hygienic macros arrive (§11.2).
- The built-in bootstrap macros are `ns`, `defmacro`, `defn` and `defn-`. The other core macros (§5.2) are written in Skein in `lib/skein/core.skn`.
- **Syntax-quote** (`` ` ``) resolves symbols to their fully qualified names at the macro's definition site, as Clojure does. `` `(when ~x (log ~y)) `` expands to `skein.core/when` and `my.ns/log`, so macros don't accidentally capture or get shadowed by the user's local names.
- `x#` inside syntax-quote generates a unique symbol (an auto-gensym).
- `&form` and `&env` are available, as in Clojure.
- `macroexpand-1`, `macroexpand` and `macroexpand-all` are available at the REPL.

### 11.2 Later: full hygiene (Deferred)
Syntax objects already carry source locations and are designed to gain **scope sets** (Racket's sets-of-scopes model) in Phase 3, after the front end is self-hosted (D-021), so `define-syntax`/`syntax-parse`-style hygienic macros can be added without changing the reader or expander interfaces. `defmacro` will remain supported.

### 11.3 No `#lang`
Skein has no `#lang` or per-file reader/expander selection (D-025). Domain-specific languages are written as macros.

## 12. Types, declarations and optimization

Skein is **dynamically typed**. Declarations are optional, and they serve two purposes:
1. **Assertions:** checked at run time under the default policy.
2. **Optimization hints:** trusted under `(safety 0)`.

### 12.1 Type specifiers

| Specifier | Meaning |
|---|---|
| `i8 i16 i32 i64 u8 u16 u32 u64` | machine integers |
| `f32 f64` | floats |
| `fixnum`, `integer`, `number` | numeric types |
| `bool`, `char`, `string`, `keyword`, `symbol` | scalar types |
| `vector`, `hash-map`, `hash-set`, `list`, `seq` | collection types |
| `(array T)`, `(array T n)` | typed arrays |
| class names, value-struct names | user types |
| `(or A B)`, `(and A B)`, `(member :a :b)`, `(maybe T)` | combinators; `(maybe T)` = `(or nil T)` |
| `(fn [A B] R)` | function type (documentation only in v1) |
| `any` | anything |
| `ptr`, `(ptr T)` | foreign pointer (§14) |

### 12.2 Declaring

```clojure
(defn dot ^f32 [^vec2 a ^vec2 b]                 ; return and parameter hints
  (+ (* (:x a) (:x b)) (* (:y a) (:y b))))

(defn step! [ps dt]
  (declare (type particles ps) (type f32 dt)
           (optimize (speed 3) (safety 1)))
  ...)

(let [^i32 n (count xs)] ...)
(the f32 (compute))
(declaim (ftype (fn [f32 f32] f32) lerp))       ; global declaration
```

### 12.3 Optimization policy
There are four qualities, each with a level from 0 to 3: `speed`, `safety`, `debug` and `space`.

| Profile | Policy |
|---|---|
| dev (default) | speed 1, safety 3, debug 2 |
| release | speed 3, safety 1, debug 0 |
| `(safety 0)` | must be requested locally; never applied by a profile |

Behavior at each safety level:
- `safety ≥ 1`: declarations are checked, array bounds are checked, and fixed-width integer overflow (`fixnum` and machine integer types) **signals an error**.
- `safety 0`: no checks, and fixed-width integer arithmetic wraps. (Phase 0: overflow at `safety 0` is unchecked but not guaranteed to wrap.)

`skein run --release` compiles with the release profile; the default is dev.

### 12.4 Inference and efficiency notes
- The compiler does **local type inference** within a function: it propagates declared and literal types, inlines arithmetic on known types, and unboxes floats and value structs.
- With `speed ≥ 2`, the compiler emits **efficiency notes** (as SBCL does) explaining why something couldn't be optimized: "generic `+`: argument type unknown", "boxing f32 to return", "allocation in loop". These notes are essential to the performance workflow and are surfaced in the REPL and the editor.
- Phase 0 (D-036): local inference is SBCL's own; the backend turns Skein declarations into CL declarations and inlines the core arithmetic, comparison and array functions (`+`, `<`, `aget`, `aset!`, `count`, …) and value-struct constructors and accessors. Efficiency notes are SBCL's notes, placed at the Skein form they concern and given in Skein type names; they appear for code that itself declares `(optimize (speed 2))` or more, not for everything compiled with the release profile.
- `(declaim (ftype (fn [arg-types] return-type) name...))` records a function's type; calls to it are known to return `return-type`.
- Natively (Phase 1, D-056), the C backend keeps locals declared `f64`, `f32` or `fixnum` unboxed, as C `double`, `float` and `int64_t`. So are immutable `let` locals whose init has such a type, unless it is integer arithmetic.
  - Arithmetic, comparisons, `sqrt`, and `aget`/`aset!`/`count` on `(array f64)`, `(array f32)` and `(array fixnum)` compile to C. Bounds and fixnum overflow are checked unless `(safety 0)`.
  - Values are boxed where they reach code without a known type. Declared parameters and stores are checked as Phase 0 checks them.
  - Integer arithmetic is unboxed only where a typed integer is required, so results past 64 bits still become bignums.
  - Floating-point results are exactly Phase 0's: there are no fused multiply-adds.

### 12.5 Sealing (release builds)
- `(seal class-name)` forbids new subclasses. `(seal-generic g)` forbids new methods. A `^:sealed` var cannot be redefined.
- In release builds, the project's `:seal` option seals everything that isn't marked `^:open`. Sealed calls can be direct-linked and inlined, and sealed generics dispatched statically when the argument types are known.
- Dev builds never seal automatically.

## 13. Concurrency

### 13.1 Model
- **Fibers:** lightweight threads, scheduled M:N onto a pool of OS worker threads by a **work-stealing scheduler**.
- **Shared heap.** Immutable data is shared freely. Mutation happens only through atoms, channels, `:unsynchronized` cells, arrays and transients, the last three owned by one fiber.
- **Structured concurrency** is the default way to start work.

**Phase 0 note:** on the SBCL host, a "fiber" is a task on an OS-thread pool (via `lparallel`-style workers), and blocking operations block the worker thread. The API is identical. Real fibers arrive with the native runtime (Phase 2).

### 13.2 API

```clojure
;; structured concurrency
(with-nursery [n]
  (spawn n (load-textures))
  (spawn n (load-audio)))        ; waits for all children; the first error cancels siblings

(with-nursery [n {:on-error :restart-fiber}]   ; a supervision policy (§10)
  (spawn n (serve-clients)))

(let [f (future (expensive))]    ; detached task, joined with deref
  @f)

;; cancellation
(with-timeout 2.0 (fetch-thing)) ; signals 'timeout and cancels the work
(check-cancelled)                ; cooperative cancellation point (also implicit at channel ops/sleep)

;; channels: blocking ops park the fiber, not the OS thread
(def ch (chan 16))               ; buffered; (chan) is unbuffered
(>! ch msg)                      ; put
(<! ch)                          ; take
(alts! [ch1 ch2 timeout-ch])     ; select
(close! ch)

;; atoms
(def score (atom 0))
(swap! score + 10)

;; data parallelism
(pmap f coll)
(preduce + 0 xs)                 ; tree-shaped reduction over persistent vectors
(pdotimes [i n] (update! ps i ...))   ; split index range across workers

;; job graphs (game frames)
(jobs/graph
  {:physics  (job (physics/step! world dt))
   :ai       (job (ai/step! world dt))
   :anim     (job {:after [:physics]} (anim/step! world dt))})

;; thread affinity
(on-main-thread (sdl/create-window "Game" 1280 720 0))
(spawn-pinned :main ...)
```

- There is **no `go` macro**. Since fibers are real, `<!` and `>!` work in any fiber.
- **Main-thread affinity** is required for windowing on macOS and some graphics APIs. The program's entry point runs on the main OS thread, and `on-main-thread` marshals work to it.

Phase 0 details (D-037):
- Tasks run on a cached pool of OS threads that grows when no worker is idle, so a blocked task never keeps another from running. Each task inherits the current namespace and output streams of the code that started it.
- Cancellation is cooperative. Channel operations, `sleep`, `deref` of a task, nursery joins and `check-cancelled` are cancellation points, and a blocked one notices cancellation within about 20 ms. Cancellation signals `cancelled`, which is **not** an error, so `(catch error e ...)` does not swallow it; `deref` of a cancelled task signals `task-cancelled-error`. `with-timeout` signals the error `timeout`.
- `@task` waits; `(deref task seconds timeout-value)` waits at most that long. `cancel!`, `done?`, `cancelled?` and `task?` work on any task. `sleep` takes seconds.
- Channels: `(chan)` is unbuffered, `(chan n)` buffered; nil cannot be put. `>!` returns false on a closed channel, `<!` returns nil once a closed channel is empty. `alts!` takes channels and `[channel value]` puts, tries them in random order, and returns `[value channel]`. `(timeout-chan seconds)` closes after that long.
- `pmap` is eager and returns a list. `preduce` reduces chunks from `init` and combines the results with the same function, so the function must be associative and `init` its identity. `pdotimes` splits the range across CPUs.
- The main thread runs work queued by `on-main-thread` and `(spawn-pinned :main ...)` whenever it waits, and when it calls `drain-main-thread!`.
- `skein.jobs`: `(job {:after [names]} body...)` and `(graph {name job ...})`, which returns a map of results; a missing dependency or a cycle is an error before anything runs. `(graph jobs options)` gives the jobs' nursery `with-nursery`'s option map (M2.8, D-088): `{:on-error :restart-fiber}` runs a failed job again. A job after a failed one fails too.

Native details (Phase 1, D-057; fibers since M2.3, D-075): the runtime has Phase 0's model and messages. Each task runs in a fiber on the work-stealing scheduler; waiting for a task, a channel, a nursery's tasks or a sleep parks the fiber, and the task, channel or timer wakes it, as does a cancellation, at once. Code that isn't in a fiber (the main thread's `-main`) blocks instead, waking at least every 20 ms to run the main thread's queue. Tasks and channels share one lock. The running code's cancellation scopes are frames on the condition chain (§10), so a non-local exit leaves them as it leaves handlers. A task starts with its spawner's cancellation scopes and dynamic bindings (D-076).

Supervisors natively (M2.8, D-088): a task's failure is handled by its nursery's policy where the task ends (§10). In a program with the debugger (`skein dev`, `skein repl`) an error that no handler in the task handles first opens the debugger in the task's fiber, through a task runner the runtime calls every task's function with; its `abort` restart, "Fail the task", hands the failure to the policy. The REPL's and Swank's own fibers aren't wrapped.

### 13.3 STM (Deferred)
Clojure-style refs with `dosync`/`alter`/`commute` are planned once the native runtime exists. The `:cell :ref` slot kind and the `ref` name are reserved.

### 13.4 Memory model
- Writes to an atom or a channel *happen-before* subsequent reads that observe them.
- Persistent data structures are immutable once published.
- Mutation of fiber-owned objects from a non-owner fiber is undefined behavior at `(safety 0)` and an error otherwise (detected where practical).

## 14. Foreign function interface

### 14.1 Declarative layer

```clojure
(ns sdl3.raw (:require [skein.ffi :as ffi]))

(ffi/deflibrary sdl3
  {:macos "libSDL3.dylib" :linux ["libSDL3.so.0" "libSDL3.so"] :windows "SDL3.dll"})

(ffi/defcstruct sdl-frect
  (x f32) (y f32) (w f32) (h f32))

(ffi/defcenum sdl-init-flags
  (:video 0x20) (:audio 0x10))

(ffi/defcfun init "SDL_Init" bool
  [flags u32])

(ffi/defcfun create-window "SDL_CreateWindow" (ptr sdl-window)
  [title c-string, w i32, h i32, flags u64])

(ffi/defcfun ^:blocking wait-event "SDL_WaitEvent" bool
  [event (ptr sdl-event)])

(ffi/defcallback audio-cb void [userdata ptr, stream (ptr u8), len i32]
  ...)
```

**Foreign types:** the primitive types from §12.1 plus `void`, `bool` (C `_Bool`), `c-string` (converted to and from Skein strings), `ptr`, `(ptr T)`, foreign structs (by pointer or by value), enums, function pointers and fixed arrays.

**Memory and values** (all in `skein.ffi`):

```clojure
(ffi/alloc f32 1024)             ; zeroed C memory for 1024 floats; (ffi/alloc sdl-frect) for one struct
(ffi/get p f32 3)                ; read element 3; (ffi/put! p f32 1.5 3) writes it
(ffi/field r sdl-frect :x)       ; read a field; (ffi/put-field! r sdl-frect :x 1.0f) writes it
(ffi/sizeof sdl-event)           ; size in bytes
(ffi/ptr+ p 16) (ffi/address p)  ; pointer arithmetic, the address as an integer
(ffi/null) (ffi/null? p) (ffi/ptr? x)
(ffi/c-string p)                 ; read a NUL-terminated UTF-8 string
(ffi/enum-value sdl-flags [:a :b]) ; a key, a collection of keys ORed together, or an integer
```

Phase 0 details (D-038):
- C `NULL` is `nil`, both as a result and as an argument (including `c-string`).
- `(ptr T)` documents the pointee; all pointers are passed alike. Function pointers are `ptr`; `defcallback` makes one.
- Structs and unions are passed to and from functions by pointer only; by-value struct arguments and results are not supported yet. M2.13 adds them, calls through C function pointers and variadic calls (D-090). Inside structs they are stored inline. Reading a field that holds a struct, union or array returns its address.
- C code runs with float traps masked. A callback that signals an error warns and returns zero, since errors cannot unwind through C. No other non-local exit can leave a callback either: invoking a restart or returning from a block established outside the C call, or a handler outside that unwinds, is stopped where C called the callback, which warns and returns zero (D-068).
- Libraries are searched in `SKEIN_LIBRARY_PATH` (`:`-separated, `;` on Windows), then `/opt/homebrew/lib` and `/usr/local/lib` on macOS, `/usr/local/lib` on Linux, then the OS search path.

Native details (Phase 1, D-064, D-065): the same API and rules. `deflibrary` loads the library when the program runs, a C function is looked up when first called (in the loaded libraries, then the whole process), and the C backend compiles each call to a typed C call. Struct and union layouts follow C's alignment rules. Native FFI programs are built by `skeinc`; `./skein build` doesn't compile them. A callback is a C function of the exact C type; it converts its arguments, calls the Skein function and converts the result inside an error handler, so an error warns (naming the callback and the zero it returns) and never unwinds through C (D-068). On Linux the process's symbols include libm's (D-067).

### 14.2 Ownership and memory
Return-value annotations:
- `^:owned (ptr T)` means the caller must free it. Skein attaches a finalizer, and `with-foreign` releases it deterministically.
- `^:borrowed (ptr T)`, the default, means no ownership is transferred.
- `(ffi/own p)` attaches the same finalizer to a pointer; `(ffi/free p)` frees one now.

Further rules:
- `(ffi/with-foreign [buf (ffi/alloc f32 1024)] ...)` gives scoped allocation.
- Passing a Skein typed array or view to C **pins** it for the duration of the call. `(ffi/pin arr ...)` pins it longer, which is needed when C keeps the pointer.
- **Handles:** `(ffi/handle obj)` produces a stable integer token that C can hold and later turn back into the Skein object. Use this instead of raw pointers to GC objects.

### 14.3 Blocking calls and threads
- A call marked `^:blocking` releases its worker thread to the scheduler, which starts a replacement if needed (natively: if the call lasts a millisecond while fibers wait, D-075). Unmarked calls are assumed to be short. In dev mode, unmarked calls that take longer than 10 ms produce a warning.
- Phase 0 (D-038) has no scheduler to hand the thread to, so `^:blocking` only silences the warning; unmarked calls warn once per function.
- **Callbacks from foreign threads:** a C thread entering Skein through a callback is attached to the runtime on first entry and runs the callback as a temporary fiber. Natively (M2.3, D-075) the callback runs as a fiber on the scheduler while the C thread waits for it; a callback made during a `^:blocking` call runs on that call's thread, which leaves the blocking state while it runs (D-068).

### 14.4 Binding generator

```sh
skein bindgen /path/to/SDL3/SDL.h --prefix SDL_ --ns sdl3.raw --out lib/sdl3/raw.skn
```

- The generator reads C headers via libclang and emits `deflibrary`/`defcstruct`/`defcenum`/`defcfun` forms. Its output is plain Skein source, meant to be committed and hand-wrapped in an idiomatic layer (`sdl3` on top of `sdl3.raw`).
- Phase 0 may use an existing C header parser (e.g. `c2ffi` JSON output) as the front end.
- C++ is out of scope. Use C wrappers such as cimgui.

Phase 0 details (D-038):

```sh
skein bindgen SDL_video.h SDL_render.h ... -I /opt/homebrew/include --prefix SDL_ --ns sdl3.raw \
  --library sdl3 --lib macos=libSDL3.dylib --lib linux=libSDL3.so.0 --lib windows=SDL3.dll \
  --blocking SDL_WaitEvent --out lib/sdl3/raw.skn
```

- The front end is `clang` itself (its JSON AST dump and `-E -dD` output), so generating needs clang on the `PATH` (or `SKEIN_CLANG`); using the output does not.
- Only declarations from the headers named on the command line, whose names start with the prefix, are emitted; structs they hold by value come along. `make sdl3-bindings` regenerates `lib/sdl3/raw.skn`.
- Naming: types keep the prefix (`SDL_FRect` → `sdl-frect`); functions and constants drop it (`SDL_CreateWindow` → `create-window`, `SDL_INIT_VIDEO` → `init-video`). If that name is taken, the prefixed name is used.
- Each enum becomes a `defcenum` (keys without the common prefix, e.g. `:quit`) and also one integer constant per enumerator (`event-quit`), for struct fields that hold enum values as integers. Constant `#define`s become `def`s.
- Variadic and inline functions, by-value structs, bit fields and anonymous members are skipped with a `;; skipped` comment.

## 15. Live development

Live development is a first-class requirement, not an add-on.

- **REPL connected to the running program.** In Phase 0 this is Skein's own text REPL, on the terminal and on a localhost socket (`skein dev`). From Phase 2, the `skein` runtime has its own REPL server speaking the **Swank** protocol, so SLIME (and, after a compatibility check, SLY) connect to it directly (D-018).
- **Redefinition semantics:**
  - `defn`/`def`: the var is rebound, and every call through it sees the new definition on its next call. Frames already executing keep running the old code.
  - `defclass`: existing instances are updated (§8.4).
  - `defmethod`: dispatch caches are invalidated.
  - `defstruct :value`: changing the layout invalidates code compiled against the old layout. Dependents are recompiled when they're reloaded, and the REPL warns about live arrays with the old layout.
  - `defmacro`: affects only code expanded afterwards. The REPL can list dependents to recompile.
- **File reload:** `(reload 'game.enemies)` re-evaluates a namespace. A file watcher (`skein dev`) reloads changed files automatically.
- **Error recovery:** unhandled errors suspend the fiber and open the debugger (§10). Restarts include `retry-frame`, `skip-frame`, `use-value` and `abort-fiber`.
- **Inspector:** inspect any object, including class instances, value structs and arrays.
- **State preservation:** `defonce` defines a var only if it's unbound, so world state survives reloads.

Phase 0 details (D-039):
- **Program entry:** `skein run` and `skein dev` load the main file, then call its namespace's `-main` with the remaining command-line arguments, if it defines one. Reloading a file re-runs its top-level forms but not `-main`, so a game starts its loop in `-main`.
- **`skein dev [--port N | --no-server] file.skn args...`** runs the program, reloads loaded source files when they change (checking every 0.25 s), and serves the REPL on the terminal and on `localhost:5555`. The REPL protocol is plain text with a `namespace=> ` prompt per form. Editor setup is in [`docs/EDITORS.md`](EDITORS.md).
- **REPL:** `*1`, `*2`, `*3` hold the last values and `*e` the last error; `(ns name)` or `(in-ns 'name)` switches namespace; `:quit` leaves.
- **Debugger:** an unhandled error prints the active Skein restarts, numbered innermost first. Type a number to invoke one, `:bt` for the Skein functions on the stack, or any form to evaluate it. An error in the program's thread pauses that thread; the REPL attaches to it, and forms typed there run in the failing thread, so its restarts and state are available. Errors in spawned tasks still go to their nursery.
- **Reload:** `(reload 'ns)` loads the namespace's file again. Vars keep their identity, so callers see new definitions; definitions deleted from the file remain until restart.
- **Game loop:** `skein.game/run-loop` takes `:frame` (once per frame, e.g. input), `:update` (called with the fixed timestep `:step`, default 1/60 s, as often as the clock requires, at most `:max-steps` times per frame, default 5), `:render` (once per frame, with the fraction of a step left over), and `:running?`. Each call runs inside `(skein.game/with-frame-restarts ...)`, which establishes `retry-frame` (run that call again) and `skip-frame` (give up on it) (D-040).
- **Source root:** if the main file declares a namespace that matches its path (`src/game/main.skn` declaring `game.main`), `skein run` and `skein dev` also look for namespaces under that root (`src/`) (D-040).

Natively (M2.6, D-081): `skein run` and `skein dev` build the program with skeinc (dev profile, `--eval`) into `.skein-cache/`, reusing it while its sources are unchanged, and run it; the REPL, debugger and dev loop behave as Phase 0's above, and an error with no handler suspends its fiber for the debugger. `skein host run|dev|repl` runs Phase 0 on SBCL. From M2.7 (D-082) native `skein dev` also serves Swank on `localhost:4005` (`--swank-port N`, `--no-swank`) for SLIME, with `editors/skein-slime.el`: Emacs's packages are Skein's namespaces, and a request evaluates in the namespace of the buffer it comes from, or the listener's. An error in what Emacs evaluates, or in the program with no handler, opens SLIME's debugger (SLDB) in the fiber where it happened, with Skein's restarts and backtrace; forms evaluated there run in that fiber, and a restart resumes it (D-084). Completion, argument lists at the cursor, documentation, `M-.` and the inspector work for compiled code as for code evaluated at the REPL: `def` records each var's argument lists and location beside its docstring (D-086). From M2.8 (D-088) an error that no handler in a task handles also opens the debugger, in the task's fiber, with an `abort` restart ("Fail the task"); if no console is free and no Emacs is connected, the task fails at once. Each REPL or Swank evaluation has its own current namespace, which its `ns` and `in-ns` forms change, so that evaluations running at the same time don't change each other's (D-083).

Evaluating code (M2.5, D-078):
- **`(eval form)`** evaluates a form given as data in the current namespace and returns its value; **`(load-file path)`** evaluates a file's forms in order and returns the last value; **`(reload 'ns)`** loads a namespace's source file again (above). All three are in skein.core.
- **Native programs** can evaluate code when they are built with `skeinc build --eval` (dev profile only), which includes the reader, the expander and an evaluator (a closure compiler in the runtime), and registers the program's namespaces and vars at start-up. In other builds these functions, and `macroexpand`, `macroexpand-1` and `macroexpand-all`, signal an error saying they need `--eval`. Compiled code can't name a var that only evaluated code defines, and keeps the expansions of the macros it was built with (D-079). Reloaded code runs in the evaluator until hot reload of compiled code (M2.9); where it declares types, the evaluator computes them unboxed. From M2.9 (D-091) native `skein dev` checks for changed files every 0.1 s, evaluates a saved file at once (`; reloaded x.skn`), then compiles its namespace in the background into a shared library that it loads, rebinding the namespace's vars to compiled code (`; compiled x.skn`); `(reload 'ns)` does the same. A compile error is reported and the evaluated code stays. Forms from the REPL and SLIME stay evaluated until their file is saved. Redefining a value struct with a different layout warns that code compiled against the old layout, and values and arrays made with it, keep the old one.

## 16. Compiler architecture

```
source (.skn)
  │  reader
  ▼
syntax objects (data + source locations)
  │  expander (macros, phase tracking, namespace resolution)
  ▼
Core IR (only the special forms of §5.1, fully resolved; ANF before the C backend)
  │  analysis passes: free variables, closure conversion, mutability,
  │  type inference, inlining, constant folding, escape analysis (later)
  ▼
Backend
  ├─ CL backend (Phase 0): Core IR → Common Lisp forms → SBCL `compile`
  ├─ C backend  (Phase 1): Core IR → C11 + runtime calls → zig cc → native
  └─ LLVM/Cranelift (Deferred, only if C is a bottleneck)
```

**Key rule: the reader, expander, Core IR and analysis passes are shared by all backends.** Phase 0 is therefore not throwaway: it is the front end of the real compiler with a temporary backend.

- **Core IR** is a small, fully macro-expanded, alpha-renamed tree, documented in [`docs/CORE-IR.md`](CORE-IR.md). Every node carries a source location. In Phase 0 it is a plain tree; an ANF (A-normal form) pass runs before the C backend in Phase 1 (D-030).
- **Phase 0:** the front end is written in Common Lisp.
- **Phase 1:** the front end is ported to Skein (self-hosting), bootstrapped by running the Phase 0 implementation.
  - The reader is `skein.compiler.reader` (`lib/skein/compiler/reader.skn`, D-048). Its syntax objects are maps: `{:kind :datum :loc}`, plus `:meta` when there is metadata. The datum of a compound form is a vector of syntax objects, and a location is a map `{:file :line :column :end-line :end-column}`.
  - The expander is `skein.compiler.expander` (`lib/skein/compiler/expander.skn`, D-049). It produces Core IR as maps (`docs/CORE-IR.md`), and reaches the image's namespaces and vars, and calls macros, through internal `%` functions of skein.core (`host/src/runtime/compile-env.lisp` in Phase 0).
  - The C backend is `skein.compiler.c` (`lib/skein/compiler/c.skn`, D-059). It turns those maps into the same C as the Lisp backend, keeping its state in a map passed down each call rather than in dynamic vars.
  - Natively, the compiler's namespaces and vars are a model in `skein.compiler.env` (`lib/skein/compiler/env.skn`, D-060), separate from the vars of the compiler itself, so compiling a program never changes the running compiler. Its skein.core holds the runtime's functions, the library's, and the macros of `core.skn`, which are compiled into any program that includes the model.
  - Phase-1 code, a program's own macros and the functions they call, runs in `skein.compiler.interp` (`lib/skein/compiler/interp.skn`, D-061), which evaluates the expander's Core IR maps. Interpreted functions are ordinary functions, so compiled code calls them directly.
  - The driver is `skein.compiler.main` (`lib/skein/compiler/main.skn`, D-062); built natively it is `skeinc`. It translates a program as the Lisp C backend does, loading required namespaces at phase 1 and running zig. Since M1.11, `skein build` and `skein package` are skeinc's (D-069).
- **Compilation unit:** the namespace. Compiled output is cached per namespace, keyed by a source hash plus the hashes of its macro dependencies.

## 17. Runtime architecture (Phase 1+)

The runtime is written in **Zig**, chosen for cross-compilation with `zig cc`, C ABI compatibility and explicit memory control.

### 17.1 Value representation
Values are 64-bit tagged words, with the tag in the low 3 bits:

| Tag | Meaning |
|---|---|
| `x00` | fixnum (62-bit payload; low bits 00 let add and subtract skip untagging) |
| `001` | pointer to a heap object (object header holds the type) |
| `011` | immediate: char, bool, nil, unbound marker |
| `101` | immediate f32 (upper 32 bits) |
| `010`, `110`, `111` | reserved |

f64 values are boxed unless the compiler unboxes them. Declared code keeps f64 unboxed in registers, locals, typed slots and arrays.

Details (D-043, `runtime/src/value.zig`):
- A fixnum `n` is `n << 2`, so both `000` and `100` are fixnum tags. Its range is −2⁶¹ to 2⁶¹−1.
- A heap pointer is the 8-byte-aligned address plus 1.
- Immediates keep their kind in bits 3–7: nil 0, false 1, true 2, unbound 3, char 4. A char keeps its code point in bits 32–52.
- Only nil and false are falsey.

### 17.2 Object layout
Every heap object has one header word: type ID, GC bits, size class and a hash-cache flag. Class instances have a header, a class-wrapper pointer (used for redefinition and dispatch) and slots.

The header (D-043, `runtime/src/object.zig`), from the low bits up:

| Bits | Field |
|---|---|
| 0–15 | type ID |
| 16–23 | GC bits: marked, forwarded, pinned, old |
| 24–31 | size class |
| 32–39 | flags, such as hash cached |
| 40–63 | payload length in 64-bit words |

Objects of 32 KiB and more live in the large-object space (§18.1), so 24 bits of length is enough.

### 17.3 Functions and calls
- Closures are a code pointer plus captured values.
- Global calls load from the var cell and call through it (one indirection). Sealed calls are direct.
- The calling convention passes the argument count in a register for arity checks. Multiple values come back in registers plus an overflow area.

Phase 1 details (D-044, D-046):
- **Closures** keep their captured values in the function object after its code pointer and name; the C backend works out which locals a `fn` captures from the Core IR, and `letfn` fills in its closures' references to each other after making them.
- **Calling convention:** every compiled function has one C entry point, `sk_value f(sk_value self, uint32_t argc, const sk_value *argv)`. It picks the arity by `argc`, and `self` is the function object, through which it calls itself and, later, reaches captured values. A function object is a heap object holding the code pointer and the function's name.
- **Vars** are runtime objects (made at startup, never moved), referenced from a C array of the program's globals; `def` returns the var, as in Phase 0. Reading one checks that it is bound. Calls to `skein.core`'s arithmetic, comparisons and printing compile to inline C (fixnum cases from `runtime/include/skein.h`); other core functions are function objects in the runtime (`runtime/src/core.zig`), which compiled code calls and passes around like any function.
- **Programs** (M1.8, D-051): a native program includes every namespace it requires, translated in load order (each namespace after the ones it uses), plus `skein.core.native`, skein.core's functions written in Skein. A call to a skein.core function goes to the Zig runtime if it has the function, else to the library's definition.
- **Seqs** (M1.8, D-052): `runtime/src/seq.zig` gives every collection a seq.
  - Lists are their own seqs. Vectors and strings get index seqs, and maps and sets a list of their entries or elements, in Phase 0's order.
  - Cons cells and lazy seqs are runtime objects; a lazy seq runs its thunk once.
  - `reduce` stops at `reduced`.
  - The seq functions and transducers are written in Skein (`skein.core.native`), as ports of Phase 0's, with the same laziness.
- **Multiple values** (M1.8, D-053) follow Common Lisp's rules, as in Phase 0.
  - A function returns its first value as usual, and leaves the count and the values in thread-local registers (`sk_mv_count`, `sk_mv_values`, up to 64).
  - A `values` in tail position sets them, a call in tail position leaves them to its callee, and any other return marks one value.
  - Values pass through the tails of `if`, `do`, `let`, loops, blocks and `unwind-protect`, whose cleanup preserves them.
  - `let-values*` reads them right after its init.
- **Data:** symbols and keywords are interned, permanent objects. Collections are ports of Phase 0's (vector trie with tail, array maps up to 8 entries, then a HAMT; sets on maps; edit-token transients), with the same hash functions, so maps and sets iterate in the same order natively and on the host. Strings keep their length in characters, so `count` is O(1).

### 17.4 Fibers and scheduler
- Each fiber has its own fixed-size stack: reserved virtual memory with a guard page, committed by the OS only as pages are touched. The default reservation is 256 KB, configurable per spawn. Overflow signals a `stack-overflow` error in that fiber (§10). Freed stacks are pooled (D-024). Fibers switch stacks with hand-written assembly per architecture on macOS and Linux (arm64, x86_64 System V), and with Windows' fiber API on Windows, which keeps the stack bounds that Windows' unwinder and stack growth check (D-074). On a stack overflow the fiber continues in a reserve below its stack (a 64 KB soft guard zone on POSIX, Windows' stack guarantee) long enough to signal `stack-overflow`; the reserve is closed again once the stack is shallow.
- Each OS worker has a work-stealing deque, plus a global injection queue.
- Channel operations, `sleep`, `deref` of futures and nursery joins park the fiber.
- `^:blocking` FFI calls hand off the worker thread (§14.3).

## 18. Memory management

**Requirements:** the GC must be automatic, cope with high allocation rates of short-lived objects, keep pauses inside a frame budget, and cooperate with the FFI.

### 18.1 Design (Phase 1+)
- **Allocation:** each worker thread has a thread-local allocation buffer (TLAB) with bump-pointer allocation.
- **Nursery:** copying collection with **conservative stack scanning** and **precise heap scanning**. Objects referenced from a stack are pinned in place, Bartlett's "mostly-copying" approach (which SBCL's gencgc also uses). This avoids needing precise stack maps from the C compiler.
- **Old generation:** a non-moving mark-sweep using segregated size-class free lists, with **incremental marking** in budgeted slices and a write barrier (card marking or remembered set).
- **Large objects** of 32 KB and up go in a separate non-moving space.
- **Pinned and foreign-visible objects** live in non-moving spaces.

Phase 1 details (D-045, `runtime/src/gc.zig`):
- **Arena:** the heap is one reserved 16 GiB address range of 256 KiB segments, each with a metadata record.
- **Nursery:** each thread bump-allocates in its own nursery segment and sets a bit per object in the segment's start bitmap, which lets a conservative pointer find its object, interior pointers included.
- **Minor collection:**
  - It runs after 32 nursery segments (8 MiB), or the equivalent in large objects, have been handed out.
  - It scans every thread's stack and spilled registers conservatively, pinning what they point at.
  - It copies everything else reachable from the registered roots, the remembered set and the pinned objects into old-generation size classes.
  - A nursery segment that holds pinned objects is promoted whole, keeping only those objects.
- **Old generation:** 43 size classes (one class per segment), promoted segments, and large runs of 32 KiB and up. Large objects start young and are promoted in place.
- **Major collection:** a minor collection, then mark from the roots and stacks, then sweep. It runs when the old generation passes twice its live size after the last major collection (32 MiB at first). Marking is stop-the-world for now; incremental marking comes later.
- **Write barrier:** a remembered set. Storing a young object into an old one records the old object.
- **Threads:**
  - Threads stop at safepoints: when taking a new nursery segment, when compiled code sees `sk_gc_pending` (polled at function entry and loop back-edges), and around blocking calls, which run with their registers spilled.
  - A program registers its globals as roots.
  - `SKEIN_GC_STATS=1` prints collection statistics at exit. `SKEIN_GC_VERIFY=1` makes every collection major and the nursery one segment, and after each collection checks every root, heap object and runtime table for pointers to objects that are gone (D-073).

### 18.2 Game-oriented controls

```clojure
(gc/collect-young)                  ; run a nursery collection now (e.g. end of frame)
(gc/set-budget! :incremental-ms 1.0)
(gc/stats)                          ; pauses, rates, heap sizes
(with-frame-arena                   ; bump-allocate temporaries; freed wholesale at exit
  (build-render-list world))
```

- **Arena safety:** an object allocated in an arena must not escape it. In safe mode, a write barrier check detects stores of arena pointers into the heap and signals an error. Escape analysis may later allocate in arenas automatically.

### 18.3 Phase 0
SBCL's own GC is used. The `gc/` API exists, with `collect-young` mapped to `(sb-ext:gc)` and the other functions as no-ops or approximations, so game code written in Phase 0 keeps working.

## 19. Cross-platform build and distribution

### 19.1 Targets

| Target | Triple (zig) | Priority |
|---|---|---|
| macOS arm64 | `aarch64-macos` | P0 (the primary dev machine) |
| Windows x86_64 | `x86_64-windows-gnu` | P0 |
| Linux x86_64 | `x86_64-linux-gnu` | P0 |
| macOS x86_64 | `x86_64-macos` | P1 |
| Linux arm64 | `aarch64-linux-gnu` | P2 |
| Windows arm64 | `aarch64-windows-gnu` | P2 |

### 19.2 Build pipeline (Phase 1+)
```
skein build --target x86_64-windows-gnu --profile release
  → front end on the host (phase 1 code runs here)
  → C files + runtime
  → zig cc -target x86_64-windows-gnu
  → dist/x86_64-windows/game.exe + bundled .dlls + assets
```

### 19.3 Platform rules
- OS-specific code lives **only** in `runtime/platform/<os>/` (native) or `host/src/platform/` (Phase 0) behind a common interface. macOS and Linux share `runtime/platform/posix/`; Windows has `runtime/platform/windows/` (D-043).
- **Windows:** use SEH-compatible unwinding in the runtime (mingw's `longjmp` unwinds through `RtlUnwindEx`, D-047). There's no `fork`. Paths must handle backslashes and drive letters, and console versus GUI subsystem is a build flag.
- **macOS:** apps ship as `.app` bundles. Code signing and notarization go in `skein package`. Dev-mode JIT and dynamic loading need the `com.apple.security.cs.allow-jit` and `disable-library-validation` entitlements. The main thread is required for Cocoa/SDL windowing.
- **Linux:** link against an old glibc baseline via zig's glibc versioning for wide compatibility.

### 19.4 Packaging
`skein package --target ...` produces a distributable folder or archive: the executable, bundled dynamic libraries (with rpath/install names fixed), and assets. It should be Steam-depot friendly.

Phase 1 (D-069): `dist/<target>/<name>/` holds the executable, the target's `:native` libraries next to it and the `:assets` directories; a macOS target gets `dist/<target>/<name>.app` (`Contents/MacOS`, `Contents/Frameworks`, `Contents/Resources`, and an `Info.plist` whose bundle identifier is `:bundle-id`, default `skein.<name>`). `skein package` builds with the release profile unless `--profile` says otherwise. Native programs look for C libraries in their own directory first, and in `../Frameworks` on macOS, and find their assets with `skein.io/resource-dir`. Signing, notarization and archives come later.

## 20. Tooling

### 20.1 `skein` command-line tool

| Command | Purpose |
|---|---|
| `skein new <name> [--template game\|app\|lib]` | scaffold a project |
| `skein repl` | start a REPL |
| `skein run <file-or-ns>` | run a program |
| `skein dev` | run with file watching, hot reload and a REPL server (§15) |
| `skein host run\|dev\|repl ...` | the same on the Phase 0 SBCL host, as a reference (Phase 2, D-081) |
| `skein test` | run tests |
| `skein build [--target T] [--profile P]` | compile a native executable (Phase 1: `skein build [file.skn] [-o FILE] [--target T] [--profile dev\|release]`, by skeinc; with no file, the project in the current directory; D-069) |
| `skein package` | create distributables |
| `skein bindgen` | generate FFI bindings from C headers |
| `skein fmt` | format code (Deferred) |

### 20.2 Project file: `project.skn`

```clojure
{:name    "asteroids"
 :version "0.1.0"
 :main    asteroids.main/-main
 :paths   ["src"]
 :assets  ["assets"]
 :deps    {skein/sdl3 {:git "https://github.com/skein-lang/sdl3" :tag "v0.1.0"}}
 :native  {:libs {:macos ["vendor/macos/libSDL3.dylib"]
                  :windows ["vendor/windows/SDL3.dll"]
                  :linux ["vendor/linux/libSDL3.so.0"]}}
 :profiles {:dev     {:policy {:speed 1 :safety 3 :debug 2}}
            :release {:policy {:speed 3 :safety 1 :debug 0} :seal true}}
 :targets [:aarch64-macos :x86_64-windows-gnu :x86_64-linux-gnu]}
```

`:paths` lists where namespaces are found (default `["src"]`); `:assets` lists directories copied into a package as they are; `:main` is the function called with the command-line arguments. The file is read as data, and `skein build` with no file builds the project in the current directory (D-069). `:deps` names libraries from git repositories (GitHub's included, pinned to a tag or a commit) and from local files and folders (M2.12, D-085). A package registry is deferred.

### 20.3 Testing
`skein.test` follows the style of `clojure.test`: `deftest`, `is`, `testing`, fixtures. There is also property-based testing with `skein.test.check` (Deferred).

## 21. Standard library outline

| Namespace | Contents | Phase |
|---|---|---|
| `skein.core` | special-form wrappers, core macros, collections, seqs, transducers, atoms, numbers, strings basics | 0 |
| `skein.string` | string operations, builders, formatting | 0 (M2.11, D-089) |
| `skein.math` | scalar math; `vec2/3/4`, `quat`, `mat3/4` value structs; lerp, clamp, noise | 0 |
| `skein.conc` | nurseries, futures, channels, timeouts, job graphs | 0 |
| `skein.ffi` | FFI | 0 |
| `skein.gc` | GC controls, arenas | 0 (stubs) |
| `skein.io` | files, paths, streams, bytes | 0 |
| `skein.time` | monotonic clocks, sleep, frame timers | 0 |
| `skein.log` | leveled logging | 0 |
| `skein.test` | testing | 0 |
| `skein.repl` | REPL helpers, inspector | 0 |
| `skein.game` | game loop, fixed timestep, restarts, input mapping | 0 (demo) |
| `skein.ecs` | entity–component–system on `defsoa` | 1+ |
| `skein.json`, `skein.edn` | data formats | 1+ |
| `skein.net` | sockets, HTTP client | Deferred |
| `skein.ui` | native desktop UIs: widgets backed by Cocoa, Win32 and GTK 4 controls, events, layout, menus and dialogs; a headless backend for tests | 2 (M2.14, D-090) |

Phase 0 status (D-040):
- **Done:** `skein.core`, `skein.ffi`, `skein.jobs` (job graphs; the rest of `skein.conc` is in `skein.core`) and `skein.math`. `skein.time` has `now` and `now-ns`, with `sleep` in `skein.core`. `skein.game` has `run-loop` and the frame restarts, but no input mapping yet.
- **Not started:** `skein.string`, `skein.gc`, `skein.log` and `skein.test`. The REPL is in the host rather than `skein.repl`.
- **`skein.io`** starts in M1.9 (D-050, D-058) with what the native compiler needs:
  - `(read-file path)` returns the file's contents as a string (UTF-8); `(write-file path string)` writes one, replacing the file; `(file-exists? path)`.
  - `(run-process [program arg ...])` and `(run-process [program arg ...] {:dir path})` run a program directly, without a shell, wait for it, and return `{:exit code :out stdout :err stderr}`.
  - Failures signal `skein.io/io-error`, whose `path` is the file or program: a missing or unreadable file, one that can't be written, or a program that can't be started. A program that exits with a failure status is not an error.
  - `(resource-dir)` returns the directory holding the program's assets (`project.skn`'s `:assets`), ending with `/`: natively the executable's directory, or a macOS app's `Contents/Resources`; run from source, the nearest directory at or above the main file with a `project.skn`, else the main file's directory (D-073). Read an asset with `(read-file (str (resource-dir) "assets/level1.txt"))`.
- **`skein.math`:**
  - The operations on its types are generic functions: `v+ v- v* vdiv negate dot length length-sq distance normalize lerp` for vectors, and `m* transform transpose determinant inverse` for matrices and quaternions. Functions such as `cross`, `rotate`, `quat-rotate`, `slerp` and `mat3-translation` cover the rest.
  - Matrices are column-major: field `mCR` is column C, row R.
  - Projections (`perspective`, `ortho`) map depth to [0, 1], as Vulkan, Metal and SDL's GPU API expect.
  - Scalar functions keep float types; integer arguments give `f64`.
  - Natively (M1.12, D-070), the runtime has the scalar functions, `noise`, and `skein.time`'s `now` and `now-ns`, with Phase 0's results: they call the system's libm, as SBCL does, and an `f32` is computed as an `f64` and rounded.

Bindings shipped as separate libraries: `sdl3` (windowing, input, the 2D renderer and the GPU API; D-020), `miniaudio`, `cimgui`, `box2d`, `stb`.

## 22. Open questions

None are open right now. New questions go here; once resolved, they move to `DECISIONS.md` and the table below.

**Resolved**

| # | Question | Answer | Decision |
|---|---|---|---|
| 1 | License | MIT | D-017 |
| 2 | REPL protocol for the native runtime | Swank | D-018 |
| 3 | String indexing | By code point; O(1) `count`; O(1) indexing for ASCII strings; byte cursors in `skein.string` | D-019 |
| 4 | Graphics layer for demos | SDL3 (2D renderer and GPU API) | D-020 |
| 5 | Hygiene timeline | Phase 3, after self-hosting | D-021 |
| 6 | Persistent collections in Phase 0 | Our own implementation | D-022 |
| 7 | Integer overflow on fixnum types | Always promote to bignum | D-023 |
| 8 | Fiber stack size and growth | Fixed size, lazily committed, guard page, 256 KB default | D-024 |
| 9 | `#lang` support | No | D-025 |
| 10 | Ratios | Not in v1 | D-026 |
| 11 | Mutable slot access (from the Phase 0 retrospective) | `(:pos e)` gives a cell slot's value; `set-slot!`, `update-slot!`; `(cell e :pos)` for the cell | D-041 |
| 12 | Restart names in macros | Restarts match by plain name, ignoring the namespace | D-041 |
| 13 | Struct type tests | `defstruct` defines `name?` | D-041 |
| 14 | `/` in symbol names | Not allowed after the namespace separator; use `/`-free names such as `vdiv` | D-041 |
