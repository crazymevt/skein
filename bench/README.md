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
