The REPL, debugger and dev loop of programs built with `--eval` (DESIGN §15). Most programs use it through the commands rather than calling it:

```sh
./skein dev src/game.skn     # run with reloading, a REPL and Swank
./skein repl                 # a REPL on the terminal
```

At the REPL each form gets a `namespace=> ` prompt, and `*1`, `*2`, `*3` and `*e` hold the last values and error. An error opens the debugger with the active restarts numbered innermost first: type a number to invoke one, `:bt` for a backtrace, or any form to evaluate it where the error happened. An unhandled error in the program pauses its fiber the same way, until a console attaches.

## run-main
### Arguments and values
- `main-fn`: the program's `-main`, or nil.
- `args`: the command-line arguments.
- `ns-name`: the program's namespace.
- Under `skein dev` (`SKEIN_DEV` set) runs the dev loop: the REPL on the terminal and localhost, Swank, reloading changed files, and `-main` under a "Stop the program" restart; otherwise calls `main-fn` with `args`.

### Notes
Programs don't call it: `skeinc` builds a program with `--eval` to start through it.

See also: run-repl, skein.swank/start-server

## run-repl
### Arguments and values
- Runs `skein repl`: a REPL on the terminal, in `user`, until its input ends or `:quit`.

See also: console-loop, run-main

## console-loop
### Arguments and values
- `console`: a map with `:ns`, an atom holding a namespace's name, and `:output`, a function of printed text or nil. One from `terminal-console`, or a REPL client's.
- Runs the read-eval-print loop in this fiber until the input ends or `:quit`.

See also: run-repl, terminal-console

## terminal-console
### Arguments and values
- Returns the console on the terminal: standard input and output.

See also: console-loop

## call-in
### Arguments and values
- `console`: a map with `:ns`, an atom holding a namespace's name, and `:output`, a function of printed text or nil.
- `f`: a function of no arguments.
- Returns `(f)`'s value, called in the console's namespace (which follows the `ns` and `in-ns` forms it evaluates) with its printing going to `:output`.

See also: eval-in

## eval-in
### Arguments and values
- `console`: a map with `:ns`, an atom holding a namespace's name, and `:output`, a function of printed text or nil.
- `form`: a syntax form, from `skein.compiler.reader`.
- Returns its value, evaluated as `call-in` calls a function.

See also: call-in, eval

## show
### Arguments and values
- `x`: any value.
- Returns how the REPL prints it.

See also: pr-str

## record-value!
### Arguments and values
- `value`: any value.
- Makes it `*1`, and the earlier ones `*2` and `*3`.

See also: record-error!, *1

## record-error!
### Arguments and values
- `c`: a condition.
- Makes it `*e`.

See also: record-value!, *e

## announce
### Arguments and values
- `text`: a string.
- Prints it as a line on every console, or on standard output if there are none. Returns nil.

See also: skein.log/info

## starting-namespace
### Arguments and values
- Returns the name of the namespace new consoles start in: the program's under `skein dev`.

See also: call-in

## version
### Arguments and values
- Skein's version, a string.

See also: run-repl

## restart-label
### Arguments and values
- `r`: a restart.
- Returns its description as a debugger shows it, saying where a spawner's restart runs.

See also: restart-report, debugger-restarts

## debugger-restarts
### Arguments and values
- `c`: an error.
- Returns the restarts a debugger offers for it here, innermost first: in a task, its own, then its spawner's, then Fail the task.

See also: compute-restarts, invoke-debugger-restart

## invoke-debugger-restart
### Arguments and values
- `r`: a restart chosen in a debugger.
- Invokes it; a spawner's fails the task, and its nursery invokes `r` in the spawner once its tasks have finished.

See also: invoke-restart, debugger-restarts

## user-frames
### Arguments and values
- `frames`: a backtrace, `[name location]` each, innermost first.
- Returns the frames from the error up to the REPL's evaluator or the program's start.

See also: debugger-restarts

## service
### Arguments and values
- `body`: run as a task, as `future` does.
- For the tools' own tasks: their errors don't open the debugger. Returns the task.

See also: future, *debug-tasks*

## *debug-tasks*
### Arguments and values
- A dynamic var: whether the tasks started here give their unhandled errors to the debugger; true for the program's, false for the tools' own (`service`).

See also: service

## *level*
### Arguments and values
- A dynamic var: how many debugger loops are active in this console's fiber.

See also: debugger-restarts

## *out*
### Arguments and values
- A dynamic var: a function of a string that gets what the code running here prints, or nil for standard output.

See also: call-in, with-out-str

## *namespace-cell*
### Arguments and values
- A dynamic var: nil, or an atom holding the current namespace of the code a console evaluates, so consoles evaluating at the same time don't change each other's.

See also: call-in

## *task-restarts*
### Arguments and values
- A dynamic var: in a task whose errors go to the debugger, `{:task :spawner :main? :fail}`, its spawner's restarts and its own Fail the task; else nil.

See also: debugger-restarts

## install-swank!
### Arguments and values
- `start`: `(fn [port])`, which serves Swank and returns the server, or nil.
- `debug`: `(fn [c frames])`, which debugs an unhandled error in a connected Emacs.
- What loading `skein.swank` calls.

See also: skein.swank/start-server

