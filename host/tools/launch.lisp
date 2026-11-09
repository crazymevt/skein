;;;; Entry point for the `skein` and `skein.cmd` launchers.

(load (merge-pathnames "bootstrap.lisp" *load-truename*))

(skein-quickload "skein")

(skein.cli:toplevel)
