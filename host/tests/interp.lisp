;;;; The interpreter of phase-1 code (lib/skein/compiler/interp.skn, M1.9 step 4, D-061):
;;;; programs run by it, after the Skein expander, print what `skein run` prints.

(in-package #:skein.tests)

(def-suite skein.interp :in all
  :description "The interpreter of phase-1 code, checked against Phase 0.")

(in-suite skein.interp)

(defun interp-function (name)
  "The function skein.compiler.interp/NAME, loading the namespace the first time."
  (let ((ns (skein.runtime:find-namespace "skein.compiler.interp")))
    ;; Translating the file to C (other suites) makes the namespace and its vars without
    ;; values, so load it unless the var has one.
    (unless (and ns (skein.runtime:find-own-var ns name)
                 (skein.runtime:var-bound-p (skein.runtime:find-own-var ns name)))
      (skein.runtime::remove-namespace "skein.compiler.interp")
      (ev "(ns interp-bridge (:require [skein.compiler.interp]))")
      (setf ns (skein.runtime:find-namespace "skein.compiler.interp")))
    (skein.runtime:var-get (skein.runtime:find-own-var ns name) nil)))

(defun interpret-toplevel (form)
  "Expand FORM (a Skein syntax map) with the Skein expander and run it with the
interpreter; the forms of a (do ...) expansion are top-level forms."
  (let* ((ns skein.runtime:*current-namespace*)
         (expanded (call-skein-expander "macroexpand" form
                                        (call-skein-expander "make-env" ns))))
    (if (skein.runtime:truthy-p (call-skein-expander "toplevel-do?" expanded))
        (dolist (sub (rest (skein.runtime:seq-to-cl (skein-get expanded "datum"))))
          (interpret-toplevel sub))
        (funcall (interp-function "evaluate")
                 (call-skein-expander "analyze-toplevel" expanded ns)))))

(defun interpret-file (path)
  "What the program at PATH prints when the interpreter runs it, -main included."
  (with-output-to-string (*standard-output*)
    (let ((skein.runtime:*source-paths* (skein.backend.cl:program-source-paths path))
          (skein.runtime:*current-namespace* (skein.runtime:ensure-namespace "user")))
      (with-open-file (s path :external-format :utf-8)
        (let ((reader (skein.reader:make-reader
                       s :file (namestring path) :namespace "user"
                       :resolve-alias (lambda (alias)
                                        (let ((ns (skein.runtime:find-alias
                                                   skein.runtime:*current-namespace* alias)))
                                          (and ns (skein.runtime:namespace-name ns)))))))
          (loop
            (setf (skein.reader:reader-namespace reader)
                  (skein.runtime:namespace-name skein.runtime:*current-namespace*))
            (let ((form (skein.reader:read-form reader :eof-value :eof)))
              (when (eq form :eof) (return))
              (interpret-toplevel (to-skein-syntax form))))))
      (let ((main (skein.runtime:find-own-var skein.runtime:*current-namespace* "-main"))
            ;; As in skein run, -main runs in user.
            (skein.runtime:*current-namespace* (skein.runtime:ensure-namespace "user")))
        (when (and main (skein.runtime:var-bound-p main))
          (skein.runtime::scall (skein.runtime:var-value main)))))))

(defun interpreted-programs ()
  "The native test programs, without the typed one: the interpreter doesn't check
declared types, and that fixture tests their errors. Nor the dynamic and eval ones: the
interpreter has no binding yet (D-077)."
  (remove-if (lambda (p) (member (pathname-name p) '("native-typed" "main" "native-io"
                                                      "native-dynamic" "native-eval")
                                 :test #'string=))
             (native-programs)))

(test interpreter-runs-programs-as-phase-0-does
  (dolist (path (interpreted-programs))
    (let ((expected (phase0-output path))
          (actual (handler-case (interpret-file path)
                    (error (e) (format nil "error: ~A" e)))))
      (is (string= expected actual) "~A: the interpreter differs~%~A" (file-namestring path)
          (first-difference expected actual)))))
