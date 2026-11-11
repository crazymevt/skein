# Editor setup

Skein's tools are editor-neutral (D-039):

- `./skein dev game.skn` runs a program, **reloads each source file when you save it**,
  and serves a REPL on the terminal and on `localhost:5555`, and Swank, SLIME's
  protocol, on `localhost:4005` (D-082).
- `./skein repl` starts a REPL without a program.

So the basic loop needs no editor support at all: edit, save, watch the change appear. An
editor connection adds evaluating a single form without saving, and answering the
debugger from the editor.

The REPL protocol is plain text: you send forms, and it prints each result after a
`namespace=> ` prompt, like a Clojure socket REPL. Skein syntax is close enough to Clojure
that Clojure editor modes highlight and indent it well.

## Emacs: SLIME

`skein dev` serves Swank, so SLIME works with a running Skein program: evaluating and
compiling code, the REPL, the debugger (SLDB) with Skein's restarts and backtrace,
completion, argument lists as you type, documentation, `M-.` and the inspector.
`editors/skein-slime.el` sets SLIME up for Skein.

Install SLIME (from MELPA, or a checkout on `load-path`) and, for highlighting,
`clojure-mode`. Then add:

```elisp
(add-to-list 'load-path "/path/to/skein/editors")
(require 'skein-slime)
(slime-setup '(slime-fancy))
```

`skein-slime.el` opens `.skn` files in `clojure-mode` (or `lisp-mode` without it) with
`slime-mode` on, gives SLIME each buffer's namespace from its `ns` form, and connects to
Skein without SLIME's "Versions differ" question.

Start the program from Emacs with **`M-x skein-slime`** in its source buffer: it runs
`skein dev` on the file in the buffer `*skein-dev*` (the program's terminal and text REPL)
and connects SLIME once the program is running. Or run `./skein dev game.skn` in a
terminal and **`M-x skein-slime-connect`** (port 4005; with `C-u`, ask for another). It
connects to `127.0.0.1`, as the server listens on IPv4 only. Set `skein-slime-program`
if the `skein` launcher isn't in the file's directory, one above it, or on the `PATH`, and
`skein-slime-program-args` to pass arguments to the program's `-main` (Driftrock's
`("--autopilot")`, say).

| Key | Does |
|---|---|
| `C-c C-c` | compile and load the top-level form at point; errors appear as notes at their place |
| `C-c C-k` | load the file |
| `C-x C-e`, `C-M-x` | evaluate the form before point, or the top-level form |
| `C-c C-z` | switch to the REPL |
| `TAB`, `M-TAB` | complete a name: the namespace's own, `skein.core`'s, `alias/name` |
| `C-c C-d d` | describe a var: argument lists, docstring and where it's defined |
| `M-.` | go to a definition (`M-,` goes back) |
| `C-c I` | inspect a value |

The argument list of the call around the cursor shows in the echo area as you type.

**Debugger.** An error in code you evaluate opens SLDB with the error, Skein's restarts
and the Skein functions on the stack. So does an error in the running program that nothing
handles, in its main thread or in a task: that thread waits in SLDB, as it would at the
terminal. A task's SLDB has an `abort` restart, "Fail the task", after which its nursery
handles the failure. In SLDB, a number
or `RET` on a restart invokes it, `a` aborts, `q` returns to the top level, `v` on a frame
shows its function's definition, `e` evaluates a form in the failing thread and `C`
inspects the condition. If Emacs isn't connected, or disconnects first, the program's error
goes to the text REPL as before.

**What isn't there yet** (ROADMAP's notes, D-084, D-086): restarts that take arguments
can't be chosen; `C-c C-c` in the REPL doesn't interrupt a running evaluation; frames
show no local variables; the runtime's functions written in Zig (`str`, `count`, ...)
have no argument lists or docstrings; and the inspector has no actions.

SLY (Slynk) isn't supported yet.

## Emacs: clojure-mode and inf-clojure

inf-clojure speaks to the plain-text REPL on port 5555, without SLIME's debugger and
documentation.

Install `clojure-mode` and `inf-clojure` from MELPA, then add:

```elisp
(add-to-list 'auto-mode-alist '("\\.skn\\'" . clojure-mode))
(setq inf-clojure-custom-repl-type 'clojure)  ; skip inf-clojure's REPL detection
(add-hook 'clojure-mode-hook #'inf-clojure-minor-mode)
```

Connect to a running `skein dev`:

1. In a terminal, run `./skein dev game.skn`.
2. In Emacs, `M-x inf-clojure-connect`, host `localhost`, port `5555`.

Then:

| Key | Does |
|---|---|
| `C-M-x` | evaluate the top-level form at point (e.g. a changed `defn`) |
| `C-x C-e` | evaluate the form before point |
| `C-c C-z` | switch to the REPL buffer |

**Debugger.** When the program hits an error, the REPL buffer shows the error and its
numbered restarts, such as `0: retry-frame`. Fix the code (save the file, or `C-M-x` the
fixed function), then type the restart's number in the REPL buffer. Type `:bt` for a
backtrace. Any other form runs in the thread that failed.

inf-clojure's documentation and completion commands send Clojure-specific code, so they
don't work with Skein. Its `load-file` command is unnecessary, because `skein dev` reloads
saved files itself.

Without a running program, `M-x inf-clojure` with the command `./skein repl` starts a
REPL inside Emacs.

## VS Code

1. Associate `.skn` files with Clojure for highlighting. In `settings.json`:

   ```json
   "files.associations": { "*.skn": "clojure" }
   ```

2. Run `./skein dev game.skn` in the integrated terminal (``Ctrl+` ``). Saved files reload
   automatically, and errors show the debugger there.

3. To evaluate a selection without saving, bind *Terminal: Run Selected Text In Active
   Terminal* to a key. In `keybindings.json`:

   ```json
   { "key": "ctrl+enter",
     "command": "workbench.action.terminal.runSelectedText",
     "when": "editorTextFocus && editorLangId == 'clojure'" }
   ```

   Select a form (`Shift+Alt+→` expands the selection), press the key, and the form is
   evaluated by the program's REPL.

Calva (VS Code) and CIDER (Emacs) speak nREPL, which Skein doesn't serve in Phase 0.

## The REPL commands

| Input | Does |
|---|---|
| a form | evaluate it; `*1`, `*2`, `*3` hold the last values, `*e` the last error |
| `(ns name)`, `(in-ns 'name)` | switch namespace |
| `(reload 'name)` | load a namespace's file again |
| `:quit` | leave the REPL (at the `skein dev` terminal: also stop the program) |

In the debugger (the prompt starts with `debug[...]`):

| Input | Does |
|---|---|
| a number | invoke that restart |
| `:bt` | show the Skein functions on the stack |
| `:quit` | abort to the top level |
| a form | evaluate it in the failing thread, where its restarts are active |

## Testing the SLIME setup

CI's Linux job runs a scripted SLIME session against native `skein dev`
(`editors/tests/slime-session.el`, with `editors/tests/demo.skn`). To run it locally, with
SLIME checked out somewhere:

```sh
emacs --batch -Q -L /path/to/slime -L editors -l editors/tests/slime-session.el
```
