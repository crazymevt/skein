;;;; The `skein` command-line interface.

(defpackage #:skein.cli
  (:use #:cl)
  (:export #:main
           #:toplevel
           #:cli-error
           #:cli-error-exit-code
           #:+exit-ok+
           #:+exit-failure+
           #:+exit-usage+)
  (:documentation "The `skein` command-line tool: argument parsing and command dispatch."))
