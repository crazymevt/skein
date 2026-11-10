;;;; Compare n-body compiled and evaluated in one native program built with skeinc --eval
;;;; (M2.5's exit criterion, D-078). Run with `make bench`, from the repository root,
;;;; after `make compiler`. bench/nbody/eval.skn prints the Markdown table.

(load (merge-pathnames "../../host/tools/bootstrap.lisp" *load-truename*))
(skein-quickload "skein")

(defvar *windows* (string= (skein.platform:os-name) "windows"))
(defvar *skeinc* (format nil "build/skeinc~:[~;.exe~]" *windows*))
(defvar *exe* (uiop:native-namestring
               (merge-pathnames (format nil "skein-bench-nbody/nbody-eval~:[~;.exe~]" *windows*)
                                (uiop:temporary-directory))))

(unless (probe-file *skeinc*)
  (error "~A is missing: run make compiler first" *skeinc*))
(ensure-directories-exist *exe*)
(uiop:run-program (list *skeinc* "build" "bench/nbody/eval.skn" "--eval" "-o" *exe*)
                  :output nil :error-output t)
(format t "~%~A" (uiop:run-program (list *exe* "200000") :output :string :error-output t))
