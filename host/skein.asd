;;;; skein.asd: Phase 0 Skein, hosted on SBCL.

(defsystem "skein"
  :description "Skein, a Lisp for games and desktop apps (Phase 0: hosted on SBCL)."
  :version "0.0.1"
  :author "Jessie Hughart"
  :license "MIT"
  :depends-on ()
  :pathname "src/"
  :serial t
  :components ((:module "syntax" :components ((:file "package")))
               (:module "reader" :components ((:file "package")))
               (:module "ir" :components ((:file "package")))
               (:module "expander" :components ((:file "package")))
               (:module "runtime" :components ((:file "package")))
               (:module "backend-cl" :components ((:file "package")))
               (:module "cli" :components ((:file "package")
                                           (:file "cli"))))
  :in-order-to ((test-op (test-op "skein/tests"))))

(defsystem "skein/tests"
  :description "FiveAM test suites for Skein."
  :depends-on ("skein" "fiveam")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "smoke")
               (:file "cli"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run!
                                       (uiop:find-symbol* :all :skein.tests))
               (error "Skein test suite failed."))))
