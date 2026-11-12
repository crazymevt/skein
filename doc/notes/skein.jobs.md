Job graphs: named pieces of work with dependencies, run in parallel where they allow, typically once per game frame.

```skein
(ns my.game
  (:require [skein.jobs :as jobs]))
```

## job
### Arguments and values
- `{:after [names]}`: an optional map naming the jobs this one waits for.
- `body`: the job's work.
- Returns the job, `{:after [names] :run f}`, for `graph`.

See also: graph

## graph
### Arguments and values
- `jobs`: a map of names to jobs.
- `options`: `with-nursery`'s option map for the jobs' nursery, such as `{:on-error :restart-fiber}`.
- Returns a map of names to the jobs' results.

### Notes
Each job starts as soon as the ones it comes after have finished, and independent jobs run in parallel on the worker threads. A missing dependency or a cycle is an error before anything runs; a failure cancels the others and is signaled again, and a job after a failed one fails too.

See also: job, with-nursery, pmap

