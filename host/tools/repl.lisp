;;;; Start an SBCL REPL with Skein loaded. Used by `make repl`.

(load (merge-pathnames "bootstrap.lisp" *load-truename*))

(skein-quickload "skein/tests")

(format t "~&Skein ~A loaded. Run the tests with (asdf:test-system \"skein\").~%"
        (asdf:component-version (asdf:find-system "skein")))
