# Phase 0 retrospective

Phase 0 built Skein on SBCL in twelve milestones (M0.1–M0.12). It ends with **Driftrock**
(`examples/driftrock/`), a rock-field shooter that plays at 60 fps on macOS, Windows and
Linux and can be edited while it runs. This document records what worked, what felt bad,
what was slow, and the design changes that Phase 0 suggests. The language changes were
decided right after (D-041).

**By the numbers** (November 2026):
- About 10,600 lines of host Common Lisp and 1,200 lines of Skein library.
- 1,755 test checks in 18 suites; CI on all three platforms from M0.1.
- Driftrock is about 500 lines of Skein in five namespaces.

## What worked

- **The front-end architecture.** Reader → syntax objects → expander → Core IR → CL
  backend held up across every milestone. New features (declarations, the object system,
  the FFI) were expander and runtime work; the reader barely changed after M0.2. This
  pipeline is what Phase 1 keeps, so that is the most important result.
- **Conditions and restarts in the game loop.** The M0.11 exit test shows the payoff: a
  frame fails, the game pauses, the code is fixed and saved, and `retry-frame` resumes
  exactly where it stopped, with `defonce` state intact. No other mainstream game
  language offers this. It also made debugging Driftrock itself pleasant.
- **Live development.** Calling through vars, `defonce`, `-main` as the entry point and
  the file watcher together make "edit, save, see it" work without any editor support.
- **Value structs, typed arrays and declarations.** The n-body benchmark runs at 1.11×
  hand-written SBCL (M0.8). Driftrock's sparks live in a `defsoa` with no per-spark
  objects.
- **The FFI and clang-based bindgen.** The SDL3 bindings (15 headers, about 2,200 lines)
  generate in 1.5 s with no tools beyond clang, and all 53 generated structs match C's
  sizes. Writing a game against `sdl3.raw` directly was workable.
- **Nurseries and job graphs.** Driftrock runs each 60 Hz update as a five-job graph
  (ship, rocks and bullets in parallel, then the rules, then the sparks) in a dozen lines.
- **CI on three platforms from the start.** It caught bugs that would have been painful
  later:
  - NaN comparisons trapping on x86-64;
  - Windows not keeping float modes, and lacking `usleep`;
  - condition waits returning without their mutex;
  - Windows `accept` returning no connection;
  - Linux not ending a socket that another thread is reading.

## What felt bad

1. **Mutable object state is noisy.** Entity slots that change are `:cell :atom`, so
   Driftrock is full of `@(:pos e)` and `(swap! (:vel e) v+ ...)`: about 30 places in
   500 lines. Atoms are needed because the job graph moves entities on worker threads,
   where `:unsynchronized` cells are not allowed. Reading a slot should not need `@`.
   (Proposal 1.)
2. **Restart names inside macros.** `retry-frame` in a syntax-quoted macro became
   `skein.game/retry-frame`, so `(invoke-restart 'retry-frame)` didn't find it; the macro
   needs `~'retry-frame`. Restart names behave like vars but are used like keywords.
   (Proposal 2.)
3. **Small standard-library gaps surfaced late.** Number conversions, trigonometry,
   random numbers, a clock and `parse-long` only arrived in M0.11 and M0.12, when the
   demos needed them. A short "can I write a game?" checklist in M0.5 would have caught
   them earlier.
4. **Struct ergonomics.** There is no `vec2?` predicate, and `instance?` didn't accept
   struct names until M0.12. `(:x v)` isn't inlined, so hot code uses `vec2-x`. `v/`
   cannot be a symbol name (the slash), so vector division is `vdiv`. (Proposal 3.)
5. **Host wording leaks into errors.** Host conditions read like
   `arithmetic error DIVISION-BY-ZERO signalled`, CL type names appear in type errors,
   and arity errors point at the definition, not the call.
6. **Debugging freezes the game window.** Phase 0 pauses the whole main thread in the
   debugger, so the window stops redrawing and the OS may show a busy cursor. Phase 2's
   fibers fix this by pausing only the failing fiber.
7. **SDL wants the main thread.** REPL forms that call SDL must use `on-main-thread`,
   which is easy to forget.

## What was slow

Measured on an M-series MacBook (macOS, SBCL 2.6.10) unless noted.

| What | Measurement | Notes |
|---|---|---|
| Driftrock frame work | mean 1.4–1.9 ms, p99 2.7–5.6 ms, worst 16–22 ms | budget 16.67 ms; the game runs at the display rate (60 or 120 Hz) |
| One update step (5-job graph) | ~0.17 ms | 3,600 steps in 0.6 s, headless |
| Allocation | ~70 KB per update step | every vector operation allocates a struct |
| GC | one every ~13 s, 3–7 ms pauses | SBCL's nursery is 54 MB; this explains the worst frames |
| Generic `v+` vs typed function | 21 ns vs 11 ns | CLOS dispatch on value structs |
| `mat3` multiply | 2.8 µs → 48 ns | written element by element with closures at first; now spelled out |
| Empty 5-job graph | ~28 µs | thread-pool handoffs; fine per frame, too heavy for fine-grained jobs |
| Startup, `hello.skn` | 0.74 s | ASDF load plus compiling `core.skn` |
| Loading `sdl3.raw` | +0.8 s | ~400 `defcfun`s, each compiled separately |

Takeaways:
- Allocation, not computation, decides the worst frame. That confirms the Phase 1 plans
  for frame arenas, escape analysis and an incremental GC (DESIGN §18), and it argues for
  flattening value structs (§9.1) early.
- Compile-per-form costs show up in startup. Phase 1 caches compiled namespaces (DESIGN
  §16); Phase 0 could save an SBCL core with `core.skn` and `sdl3.raw` loaded if startup
  becomes annoying.
- Generic code over struct fields needs either macros or compile-time specialization.
  The closure-based `mat3` code was 60× slower than the spelled-out version.

## Proposed design changes

Language-visible proposals became DESIGN §22 questions 11–14. Jessie accepted 1–3 and
chose to keep `/`-free names for 4 (D-041); all four are now in DESIGN.md.

1. **Slot access without `@`.** `(:pos e)` on a cell slot returns the cell's value, and
   new functions change cells: `(set-slot! e :pos v)` and `(update-slot! e :pos f args...)`.
   `(cell e :pos)` gives the cell itself when needed (for `add-watch`, say).
2. **Restart names as keywords.** Name restarts with keywords (`:retry-frame`), or compare
   restart symbols by their unqualified name. Either way `invoke-restart` works from any
   namespace and inside macros without `~'`.
3. **Struct predicates.** `defstruct` also defines `name?` (`vec2?`).
4. **Division-like names.** Keep a `/`-free naming convention for division operators in
   `skein.math` (`vdiv` today), or let the reader accept `/` inside a symbol's name, after
   the namespace separator.

Implementation changes that need no decision. They are in the ROADMAP notes:
- Inline keyword access to value-struct fields when the struct type is known.
- Translate host condition messages into Skein wording, and report arity errors at the
  call site.
- Optionally cache a saved SBCL core with `skein.core` (and large bindings) compiled.
- Make `*1`/`*2`/`*3`/`*e` per REPL connection once dynamic vars exist.

## Changes made during M0.12

These are already in DESIGN.md (D-040):
- **Conversions:** `f32`, `f64` and `int`, named after their types.
- **Core:** `rand` and `rand-int`.
- **`skein.math`:** scalars, `vec2`/`vec3`/`vec4`, `quat`, `mat3`/`mat4`, noise.
- **`skein.time`:** `now` and `now-ns`.
- **Fixed timestep** in `skein.game/run-loop`.
- **Source root:** `run`/`dev` infer it from the main file's `ns` name.
- **`instance?`** accepts struct names.
- **Printing:** fields print in their declared order.
