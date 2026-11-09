;;;; Run every Skein test suite and exit non-zero on failure. Used by `make test`.

(load (merge-pathnames "bootstrap.lisp" *load-truename*))

(skein-quickload "skein/tests")

(uiop:quit (handler-case (progn (asdf:test-system "skein") 0)
             (error (e)
               (format *error-output* "~&~A~%" e)
               1)))
