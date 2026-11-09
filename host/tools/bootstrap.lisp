;;;; Load Quicklisp and register the Skein system with ASDF.
;;;; Used by `make test`, `make repl` and the `skein` launchers.

(in-package #:cl-user)

(require :asdf)

#-quicklisp
(let* ((home (uiop:getenv "QUICKLISP_HOME"))
       (setup (if (and home (plusp (length home)))
                  (merge-pathnames "setup.lisp" (uiop:ensure-directory-pathname home))
                  (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))))
  (unless (probe-file setup)
    (format *error-output*
            "~&skein: Quicklisp not found at ~A~%~
             Install it from https://www.quicklisp.org or set QUICKLISP_HOME.~%"
            (namestring setup))
    (uiop:quit 1))
  (load setup))

(defparameter *skein-host-directory*
  (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname *load-truename*))
  "The `host/` directory of the Skein checkout.")

(asdf:load-asd (merge-pathnames "skein.asd" *skein-host-directory*))

(defun skein-quickload (system)
  "Load SYSTEM quietly, fetching its dependencies with Quicklisp if needed."
  (uiop:symbol-call :ql :quickload system :silent t))
