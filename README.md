# Skein

**A fast, concurrent, live-coded Lisp for games and desktop apps.**

Skein winds three strands of the Lisp family into one language:

- **Common Lisp**: CLOS-style multiple dispatch, the condition/restart system, optional type declarations that make code fast, and image-style live development.
- **Clojure**: immutable persistent data structures, literal syntax for vectors, maps and sets, seqs and transducers, and atoms and channels for managed state.
- **Racket**: phase-separated macros, a real module system, and a compiler architecture built for cross-compilation.

It compiles to **native executables** for **Windows, macOS and Linux**, cross-compiles from one machine, has **automatic memory management** tuned for frame-time budgets, and makes calling C libraries routine.

> **Status: design / pre-alpha.** Nothing runs yet. The design lives in [`docs/DESIGN.md`](docs/DESIGN.md) and the build plan in [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## A taste

```clojure
(ns asteroids.ship
  (:require [skein.math :as m]
            [sdl3 :as sdl]))

(defstruct vec2 :value            ; unboxed value type, stored inline
  (x f32) (y f32))

(defclass ship [entity]
  (pos   :type vec2 :init (vec2 0.0f 0.0f))
  (angle :type f32  :init 0.0f)
  (hp    :type i32  :cell :atom :init 100))   ; the only mutable slot, managed by an atom

(defgeneric collide [a b])

(defmethod collide [(s ship) (r asteroid)]
  (swap! (:hp s) - (damage r))
  (when (<= @(:hp s) 0)
    (signal 'ship-destroyed :ship s)))

(defn integrate! [^particles ps ^f32 dt]
  (declare (optimize (speed 3)))
  (dotimes [i (len ps)]
    (update! ps i :pos m/v+ (m/v* (vel ps i) dt))))

(defn frame [world dt]
  (with-nursery [n]                         ; structured concurrency
    (spawn n (integrate! (:particles world) dt))
    (spawn n (step-ai! (:enemies world) dt)))
  (render world))
```

If `frame` throws, the game **pauses instead of crashing**. You fix the function in your editor, pick the `retry-frame` restart, and play resumes from the same state.

## Goals

| Goal | How Skein approaches it |
|---|---|
| **Live development** | REPL connected to the running program; redefine functions and classes in place; condition/restart system for recoverable errors |
| **Speed** | Optional type declarations, local type inference, unboxed value structs and typed arrays, sealing for release builds |
| **Concurrency by design** | Immutable data by default, fibers on a work-stealing scheduler, structured concurrency, channels, atoms, job system |
| **Expressive objects** | CLOS-style classes, multiple dispatch, method combinations, a meta-object protocol; slots immutable unless declared otherwise |
| **Easy C interop** | Declarative FFI plus a binding generator that reads C headers |
| **Cross-platform native output** | Compiler emits C; `zig cc` cross-compiles to Windows, macOS (arm64/x86_64) and Linux |
| **Managed memory** | Generational GC with a cheap nursery, frame-boundary collection, frame arenas |

**Primary use case:** desktop apps and games built by a small team (initially one person).
**Later:** servers, tools, numeric work.

## How it gets built

Skein is built in phases so something playable exists early (see the [roadmap](docs/ROADMAP.md)):

0. **Skein-on-SBCL.** The language is prototyped on Steel Bank Common Lisp: a Skein reader and compiler emit Common Lisp, which SBCL compiles to native code. This phase validates the design by writing a real game in it.
1. **Native compiler.** The front end is reused, a C backend and a runtime written in Zig are added, and cross-compilation goes through `zig cc`.
2. **Native live development.** Fibers, an in-runtime interpreter for redefinitions, and hot reload in shipped-style builds.
3. **Optimization.** Sealing, unboxing, SIMD, and possibly an LLVM backend.

## Repository layout (planned)

```
skein/
├── README.md            ← you are here
├── CLAUDE.md            ← working instructions for AI coding agents
├── docs/
│   ├── DESIGN.md        ← language + implementation design (source of truth)
│   ├── ROADMAP.md       ← phases, milestones, exit criteria, current status
│   └── DECISIONS.md     ← decision log (why things are the way they are)
├── host/                ← Phase 0: Skein implemented on SBCL (Common Lisp)
│   ├── skein.asd
│   ├── src/
│   └── tests/
├── lib/                 ← Skein standard library written in Skein (.skn)
├── runtime/             ← Phase 1+: native runtime (Zig)
├── examples/            ← example programs; also run as tests
└── tools/               ← CLI, binding generator, editor support
```

## Getting started (Phase 0, once milestone M0.1 lands)

Requirements: [SBCL](https://www.sbcl.org/) 2.4+ and [Quicklisp](https://www.quicklisp.org/) (or ocicl).

```sh
make test            # run the full test suite
make repl            # start a Skein REPL on SBCL
./skein run examples/hello.skn
```

Editor support in Phase 0 is via SLIME/SLY (Emacs) or Alive (VS Code), since the prototype runs inside SBCL.

## File extension

Skein source files use **`.skn`**.

## License

MIT. See [`LICENSE`](LICENSE).
