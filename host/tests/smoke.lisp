;;;; Smoke tests: the system loads and every module package exists.

(in-package #:skein.tests)

(def-suite smoke :in all
  :description "The Skein system loads.")

(in-suite smoke)

(test module-packages-exist
  (dolist (name '("SKEIN.SYNTAX" "SKEIN.READER" "SKEIN.IR" "SKEIN.EXPANDER"
                  "SKEIN.RUNTIME" "SKEIN.BACKEND.CL" "SKEIN.CLI"))
    (is (find-package name) "package ~A is missing" name)))
