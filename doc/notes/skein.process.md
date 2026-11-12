Require it with an alias, in the style of babashka.process:

```skein
(ns my.tool
  (:require [skein.process :as p]
            [skein.io :as io]))

(let [git (p/process ["git" "status" "--short"] {:dir "."})]
  (doseq [line (io/line-seq (:out git))]
    (println line))
  (:exit @git))
```

`@p` waits for a process to end and gives the process, with its `:exit`; `(deref p
seconds timeout-value)` waits at most so long. Native only. For a program you only need to
run to its end, `skein.io/run-process` is simpler.

## process
### Arguments and values
- `cmd`: a vector of the program, found on the `PATH`, and its arguments, all strings.
- `opts`: a map. `:dir`, the directory to run it in. `:env`, its whole environment, or `:extra-env`, added to this program's (maps of strings). `:in`, `:out`, `:err`: `:pipe` (the default), `:inherit`, `:discard` or `{:file path}` (`:append true` too for `:out` and `:err`); a string `:in` is text to write to its stdin, then close; `:err :out` merges the error output into the output.
- Returns the process at once. Its `:in` is a `skein.io` writer and its `:out` and `:err` are readers, or nil when not piped; `@p` waits for it to end.

### Notes
No shell runs the program, so arguments need no quoting; run `sh -c` explicitly for a pipeline. A pipe keeps a descriptor until it is read to the end or closed, so close the streams you don't read (or `:discard` them). Waiting parks the fiber, not a thread, so a program can talk to many processes at once from fibers.

See also: deref, alive?, destroy!, skein.io/run-process

## process?
### Arguments and values
- `x`: any value.
- Returns true if it is a process `process` started.

See also: process, subprocess

## subprocess
### Arguments and values
- The class of processes, with the slots `:cmd`, `:pid`, `:in`, `:out`, `:err` and `:exit` (nil until it has ended and been waited for).

See also: process, process?

## alive?
### Arguments and values
- `p`: a process, from `process`.
- Returns true if the program is still running.

See also: deref, destroy!

## pid
### Arguments and values
- `p`: a process, from `process`.
- Returns its process id.

See also: process

## signal!
### Arguments and values
- `p`: a process, from `process`.
- `kind`: `:interrupt` (SIGINT), `:terminate` (SIGTERM) or `:kill` (SIGKILL); on Windows `:terminate` and `:kill` end it and `:interrupt` is an error for now.
- Does nothing once it has ended. Returns `p`.

See also: destroy!, destroy-tree!

## destroy!
### Arguments and values
- `p`: a process, from `process`.
- Ends it, as `(signal! p :terminate)`.
- Returns `p`.

See also: destroy-tree!, signal!

## destroy-tree!
### Arguments and values
- `p`: a process, from `process`.
- Ends it and the programs it started: its process group on Unix, its job object on Windows.
- Returns `p`.

See also: destroy!

