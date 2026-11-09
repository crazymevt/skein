# Editor setup (Phase 0)

Skein's Phase 0 tools are editor-neutral (D-039):

- `./skein dev game.skn` runs a program, **reloads each source file when you save it**,
  and serves a REPL on the terminal and on `localhost:5555`.
- `./skein repl` starts a REPL without a program.

So the basic loop needs no editor support at all: edit, save, watch the change appear. An
editor connection adds evaluating a single form without saving, and answering the
debugger from the editor.

The REPL protocol is plain text: you send forms, and it prints each result after a
`namespace=> ` prompt, like a Clojure socket REPL. Skein syntax is close enough to Clojure
that Clojure editor modes highlight and indent it well.

## Emacs: clojure-mode and inf-clojure

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

## Later

From Phase 2 the native runtime speaks Swank, so SLIME and SLY connect to it directly
(D-018).
