;;;; skein.asd: Phase 0 Skein, hosted on SBCL.

(defsystem "skein"
  :description "Skein, a Lisp for games and desktop apps (Phase 0: hosted on SBCL)."
  :version "0.0.1"
  :author "Jessie Hughart"
  :license "MIT"
  :depends-on ()
  :pathname "src/"
  :serial t
  :components ((:module "runtime" :serial t :components ((:file "package")
                                               (:file "data")
                                               (:file "numbers")
                                               (:file "print")))
               (:module "syntax" :serial t :components ((:file "package")
                                              (:file "syntax")
                                              (:file "print")))
               (:module "reader" :serial t :components ((:file "package")
                                              (:file "reader")))
               (:module "ir" :serial t :components ((:file "package")))
               (:module "expander" :serial t :components ((:file "package")))
               (:module "backend-cl" :serial t :components ((:file "package")))
               (:module "cli" :serial t :components ((:file "package")
                                           (:file "cli"))))
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
               (:file "cli"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :fiveam :run!
                                       (uiop:find-symbol* :all :skein.tests))
               (error "Skein test suite failed."))))
