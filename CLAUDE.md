# CLAUDE.md: working on Skein

Skein is a new Lisp for games and desktop apps. It is being built incrementally by AI coding agents under the direction of one human maintainer (Jessie). This file says how to work in this repository. **Read it fully at the start of every session.**

## 1. Before you write any code

1. Read `docs/ROADMAP.md` and find the **current milestone**: the first one that isn't ✅.
2. Read the sections of `docs/DESIGN.md` that the milestone touches. **DESIGN.md is the source of truth** for language semantics.
3. Skim `docs/DECISIONS.md` so you don't relitigate settled questions.
4. If the milestone is underspecified or contradicts DESIGN.md, **stop and ask** before building on a guess.

## 2. Scope discipline

- **Work only on the current milestone.** Don't start later milestones, and don't build Phase 1+ infrastructure (GC, fibers, C backend, Zig runtime) during Phase 0.
- Small, obviously needed helpers for the current milestone are fine. Speculative abstractions "for later" are not.
- If you notice something worth doing later, add it to the "Notes for later" section at the bottom of `docs/ROADMAP.md` instead of doing it.
- When a milestone's exit criteria all pass, update its row in the ROADMAP status table to ✅ and say so in your summary.

## 3. When the design must change

The design will be wrong in places. When implementation shows that:
1. Don't silently diverge from DESIGN.md.
2. Add a new entry to `docs/DECISIONS.md` (the next D-NNN): context, decision, alternatives, consequences.
3. Update DESIGN.md in the **same commit**.
4. For anything user-visible in the language (syntax, semantics, naming), **ask Jessie first**. Internal implementation choices you can make yourself; record them in DECISIONS.md.

## 4. Phase 0 technical rules (Skein-on-SBCL)

- **Host:** SBCL 2.4+, ASDF. The code lives in `host/`.
- **Allowed dependencies:** `alexandria`, `cffi`, `bordeaux-threads`, `closer-mop`, `fiveam`, `trivial-garbage`, `lparallel`. **Ask before adding any other.**
- **Keep the front end portable.** The reader, expander, Core IR and analysis passes will be ported to Skein in Phase 1, so in those modules:
  - don't use the CL reader, readtables or `eval` to implement Skein semantics;
  - prefer plain structs, vectors and hash tables over CLOS-heavy designs;
  - keep CL-specific tricks inside `skein.backend.cl` and `skein.runtime`.
- **Platform code** goes only in `host/src/platform/`. Everything else must work on macOS, Windows and Linux. Watch for path separators, line endings and library names.
- **Style:**
  - one package per module, named `skein.<module>`;
  - docstrings on every exported symbol;
  - `define-condition` for every error type the user can see;
  - lines up to 100 characters;
  - 2-space indentation as Emacs/SLIME indents it.
- **Error messages** must include the Skein source location (file:line:col) whenever one is available.

## 5. Testing

- `make test` must pass before you call any task done. Run it; don't assume.
- Every feature gets tests in the same change. Bug fixes get a regression test.
- Tests live in `host/tests/`, one FiveAM suite per module.
- Programs in `examples/` are also tests: each `examples/foo.skn` may have `examples/foo.expected` with the expected stdout, and the suite runs them.
- For data structures, add **randomized tests against a reference model**.
- Never delete or weaken a test to make it pass without asking.

## 6. Skein code (`.skn`) style

- Follow DESIGN.md syntax exactly. When in doubt, write what idiomatic Clojure would look like, then check it against DESIGN.md.
- Use kebab-case names, a `!` suffix for mutation/side effects, `?` for predicates, and `*earmuffs*` for dynamic vars.
- One namespace per file; the path mirrors the namespace (`game.player` → `game/player.skn`).

## 7. Commits

- Make small, focused commits with present-tense subjects: "Add HAMT node splitting".
- Reference the milestone in the body: `Milestone: M0.4`.
- Don't commit generated build artifacts (`*.fasl`, `build/`, `dist/`).

## 8. Commands

These are defined in M0.1; update this section if they change.

| Command | Purpose |
|---|---|
| `make test` | run all tests |
| `make repl` | SBCL with Skein loaded |
| `./skein run <file.skn>` | run a Skein program |
| `make bench` | run the benchmarks in `bench/` |
| `./skein bindgen <headers> --prefix P --ns NS ...` | generate FFI bindings from C headers (needs clang) |
| `make sdl3-bindings` | regenerate `lib/sdl3/raw.skn` |

## 9. When to ask Jessie

Ask when:
- a language-level design question isn't covered by DESIGN.md;
- you'd add a dependency or change the repo layout;
- exit criteria seem impossible or wrong;
- a change would be hard to reverse.

Otherwise, make a reasonable choice, record it if it's significant, and keep going.
