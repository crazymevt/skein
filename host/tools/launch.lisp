;;;; Loaded by the `skein` and `skein.cmd` launchers, which then call (skein.cli:toplevel)
;;;; outside LOAD, so SBCL does not add load context to the program's messages.

(load (merge-pathnames "bootstrap.lisp" *load-truename*))

(skein-quickload "skein")
