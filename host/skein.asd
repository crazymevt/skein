;;;; skein.asd: Phase 0 Skein, hosted on SBCL.

(defsystem "skein"
  :description "Skein, a Lisp for games and desktop apps (Phase 0: hosted on SBCL)."
  :version "0.0.1"
  :author "Jessie Hughart"
  :license "MIT"
  :depends-on ("closer-mop")
  :pathname "src/"
  :serial t
  ;; One package per module (src/<module>/package.lisp). Files are listed in load order:
  ;; syntax objects come first because runtime errors report source locations.
  :components ((:file "platform/package")
               (:file "platform/cpu")
               (:file "syntax/package")
               (:file "syntax/syntax")
               (:file "runtime/package")
               (:file "runtime/data")
               (:file "runtime/numbers")
               (:file "runtime/print")
               (:file "runtime/errors")
               (:file "runtime/namespaces")
               (:file "runtime/coll-types")
               (:file "runtime/vector")
               (:file "runtime/map")
               (:file "runtime/seq")
               (:file "runtime/equality")
               (:file "runtime/conditions")
               (:file "runtime/invoke")
               (:file "runtime/display")
               (:file "runtime/core")
               (:file "runtime/core-coll")
               (:file "runtime/core-conditions")
               (:file "runtime/atoms")
               (:file "runtime/objects")
               (:file "runtime/inline")
               (:file "runtime/arrays")
               (:file "runtime/structs")
               (:file "runtime/types")
               (:file "runtime/concurrency")
               (:file "runtime/channels")
               (:file "syntax/print")
               (:file "reader/package")
               (:file "reader/reader")
               (:file "ir/package")
               (:file "ir/ir")
               (:file "expander/package")
               (:file "expander/env")
               (:file "expander/data")
               (:file "expander/syntax-quote")
               (:file "expander/destructure")
               (:file "expander/expander")
               (:file "expander/macros")
               (:file "backend-cl/package")
               (:file "backend-cl/compile")
               (:file "backend-cl/driver")
               (:file "cli/package")
               (:file "cli/cli"))
  :in-order-to ((test-op (test-op "skein/tests"))))

(defsystem "skein/tests"
  :description "FiveAM test suites for Skein."
  :depends-on ("skein" "fiveam")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "smoke")
               (:file "runtime")
               (:file "syntax")
               (:file "reader")
               (:file "eval")
               (:file "collections")
               (:file "seqs")
               (:file "macros")
               (:file "conditions")
               (:file "objects")
               (:file "types")
               (:file "concurrency")
               (:file "cli"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run!
                                       (uiop:find-symbol* :all :skein.tests))
               (error "Skein test suite failed."))))
