;;;; The REPL, debugger, file watcher and REPL server (DESIGN §15, M0.11).

(defpackage #:skein.repl
  (:use #:cl)
  (:import-from #:skein.runtime
                #:*current-namespace* #:*source-paths* #:ensure-namespace #:find-namespace
                #:namespace-name #:namespace-file #:namespace-loaded-p #:all-namespaces
                #:readable-string #:skein-error #:namespace-error #:intern-var #:def-var
                #:+core+ #:sym-p #:sym-name #:sym-namespace #:kw-p #:kw-name)
  (:export #:run-repl #:run-dev #:reload-namespace #:start-server #:stop-server
           #:server-port #:*watch-interval*)
  (:documentation "Interactive development for Skein: a REPL (on the terminal or over a
localhost socket), a debugger that lists Skein restarts, a file watcher that reloads
changed source files, and the `skein repl` and `skein dev` commands.

A console reads forms on its own thread. When an error goes unhandled in a program thread
(not a console's), that thread opens a debug session and waits; a console attaches to it
and sends it forms, which the failing thread evaluates, so its restarts (retry-frame,
skip-frame, ...) can be invoked."))
