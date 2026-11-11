;;;; Run the Skein test suites and exit non-zero on failure. Used by `make test-host`, and
;;;; by host/tools/test-all.sh (`make test`), which runs groups of suites side by side:
;;;;   sbcl ... --load host/tools/run-tests.lisp                     every suite
;;;;   ... --end-toplevel-options only skein.swank skein.repl        just these suites
;;;;   ... --end-toplevel-options except skein.swank skein.repl      every other suite

(load (merge-pathnames "bootstrap.lisp" *load-truename*))

(skein-quickload "skein/tests")

(defun suite-arguments ()
  "(mode suite-symbol...) from the command line after --end-toplevel-options, or nil.
(SBCL leaves only the program's name and those in *posix-argv*.)"
  (let ((args (rest sb-ext:*posix-argv*)))
    (when args
      (cons (intern (string-upcase (first args)) :keyword)
            (mapcar (lambda (name)
                      (or (find-symbol (string-upcase name) "SKEIN.TESTS")
                          (error "no test suite ~A" name)))
                    (rest args))))))

(defun all-suites ()
  "The suites in the suite ALL, in the order they were defined."
  (reverse (fiveam::%test-names (fiveam::tests (fiveam:get-test 'skein.tests::all)))))

(uiop:quit
 (handler-case
     (let ((args (suite-arguments)))
       (if (null args)
           (progn (asdf:test-system "skein") 0)
           (let* ((named (rest args))
                  (suites (ecase (first args)
                            (:only named)
                            (:except (remove-if (lambda (s) (member s named)) (all-suites))))))
             (let ((ok t))
               (dolist (suite suites)
                 (unless (fiveam:run! suite) (setf ok nil)))
               (if ok 0 1)))))
   (error (e)
     (format *error-output* "~&~A~%" e)
     1)))
