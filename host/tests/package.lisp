;;;; Test package and root suite.

(defpackage #:skein.tests
  (:use #:cl #:fiveam)
  (:export #:all)
  (:documentation "FiveAM test suites for Skein. Run them with `make test`."))

(in-package #:skein.tests)

(def-suite all
  :description "Every Skein test suite. Each module adds a child suite.")
