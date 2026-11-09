# Benchmarks

Run with `make bench`. Each case runs 5 times after a full GC; the table shows the best time. There are no performance targets yet (ROADMAP M0.4). The numbers are for spotting regressions and comparing approaches, not for comparison across machines.

## Collections (M0.4)

Recorded 2026-11-09 on Apple M4, SBCL 2.6.10, macOS, by `bench/collections.lisp`.

| Benchmark | Best of 5 (ms) |
|---|---|
| vector: conj 1M (persistent) | 27.4 |
| vector: conj! 1M (transient) | 10.3 |
| CL baseline: vector-push-extend 1M | 6.4 |
| vector: nth 1M | 36.7 |
| vector: assoc 100k | 14.7 |
| vector: reduce + over 1M | 48.0 |
| map: assoc 100k integer keys (persistent) | 39.7 |
| map: assoc! 100k integer keys (transient) | 19.2 |
| CL baseline: hash table puthash 100k | 2.1 |
| map: get 1M (100k-entry map) | 65.4 |
| map: dissoc 100k | 40.6 |
| map: assoc 100k keyword keys | 39.6 |
| set: into #{} 100k | 23.5 |
| seq: (reduce + (filter odd? (map inc (range 1M)))) | 267.5 |
| transducer: (transduce (comp (map inc) (filter odd?)) + (range 1M)) | 99.6 |
| transducer over a 1M vector: (into [] (map inc) v) | 49.8 |
| equality: = on two 100k vectors | 7.3 |
| hashing: hash-of a 100k vector (uncached) | 5.0 |

Notes:
- Persistent updates cost about 2–20× the host's mutable structures; transients close much of the gap for batch building.
- The lazy pipeline realizes one element at a time (D-032) and allocates a lazy seq and a cons per element per stage; the transducer version avoids that and runs about 2.5–3× faster.
- Calls into Skein functions still go through `&rest` dispatch (D-031); M0.8 revisits this.

## N-body (M0.8)

The M0.8 exit criterion: a float-heavy program with declarations runs within 2× of the equivalent hand-written, declared SBCL code. `bench/nbody/nbody.skn` and `bench/nbody/nbody.lisp` are the same Benchmarks Game algorithm on parallel `f64` arrays with `(optimize (speed 3) (safety 1))`; `bench/nbody/compare.lisp` checks that they compute the same energies, then times both.

Recorded 2026-11-09 on Apple M4, SBCL 2.6.10, macOS:

| n-body, 5,000,000 steps | Best of 5 (s) |
|---|---|
| hand-written SBCL (bench/nbody/nbody.lisp) | 0.268 |
| Skein (bench/nbody/nbody.skn) | 0.296 |
| ratio (target: at most 2.0) | 1.11 |

What made the difference: inlined arithmetic, comparisons and array access (D-036), calls that allocate no argument lists, and inlining `count` on arrays so SBCL knows loop bounds are fixnums. Before the last change the ratio was 2.5×.

## n-body natively (M1.8)

Recorded 2026-11-09 on Apple M4, Zig 0.17.1, macOS, by `bench/nbody/native.lisp`: `nbody.skn` built natively with the release profile, and the same algorithm in C (`nbody.c`, `zig cc -O2`). Both compute the same energies. M1.8's exit criterion is a ratio of at most 1.5.

| n-body, 5,000,000 steps | Best of 5 (s) |
|---|---|
| C (zig cc -O2) | 0.184 |
| Skein, native release build | 0.249 |
| Ratio | 1.35x |
