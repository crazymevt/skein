;;;; The native compiler's driver (lib/skein/compiler/main.skn, M1.9 step 5, D-062): on
;;;; the host it translates every program to the same C as `skein build`.

(in-package #:skein.tests)

(def-suite skein.driver :in all
  :description "The driver of the native compiler, checked against skein build.")

(in-suite skein.driver)

(defun driver-function (name)
  "The function skein.compiler.main/NAME, loading the namespace the first time."
  (let ((ns (skein.runtime:find-namespace "skein.compiler.main")))
    ;; Translating the file to C (other suites) makes the namespace and its vars without
    ;; values, so load it unless the var has one.
    (unless (and ns (skein.runtime:find-own-var ns name)
                 (skein.runtime:var-bound-p (skein.runtime:find-own-var ns name)))
      (skein.runtime::remove-namespace "skein.compiler.main")
      (ev "(ns driver-bridge (:require [skein.compiler.main]))")
      (setf ns (skein.runtime:find-namespace "skein.compiler.main")))
    (skein.runtime:var-get (skein.runtime:find-own-var ns name) nil)))

(defun directory-string (dir)
  (let ((s (uiop:native-namestring (uiop:ensure-directory-pathname dir))))
    (substitute #\/ #\\ s)))

(defun driver-outcome (path)
  "The Skein driver's C for PATH (canonical), with skein build's source paths, or the
error message."
  (handler-case
      (canonical-gensyms
       (canonical-c
        (funcall (driver-function "translate-file")
                 (namestring path)
                 (skein.runtime:vector-from-list
                  (mapcar #'directory-string (skein.backend.cl:program-source-paths path))))))
    (error (e) (list :error (princ-to-string e)))))

(defun lisp-outcome (path)
  (handler-case (canonical-gensyms
                 (canonical-c (let ((skein.runtime:*source-paths*
                                      (skein.backend.cl:program-source-paths path)))
                                (skein.backend.c:translate-file path))))
    (error (e) (list :error (princ-to-string e)))))

(test driver-translates-programs-as-skein-build-does
  (dolist (path (native-programs))
    (let ((lisp (lisp-outcome path))
          (skein (driver-outcome path)))
      (unless (and (consp lisp) (search "build FFI programs with skeinc" (second lisp)))
       (is (equal lisp skein) "~A: the driver differs~%~A" (file-namestring path)
          (if (and (stringp lisp) (stringp skein))
              (first-difference lisp skein)
              (format nil "Lisp: ~S~%Skein: ~S" (if (stringp lisp) "C text" lisp)
                      (if (stringp skein) "C text" skein))))))))

(test driver-paths
  (flet ((call (name &rest args) (apply (driver-function name) args)))
    (is (string= "a/b-c.skn" (call "namespace-file-name" "a.b-c")))
    (is (string= "skein/core/native.skn" (call "namespace-file-name" "skein.core.native")))))

(test driver-targets-and-profiles
  ;; --target takes DESIGN §19.1's triples and --profile dev or release (M1.11, D-069).
  ;; Cross builds themselves are checked by host/tools/bootstrap.sh.
  (driver-function "target-os")
  (flet ((out (source)
           (ev-output (format nil "(ns driver-targets (:require [skein.compiler.main :as m]))
                                   ~A" source))))
    (is (string= (format nil "[:macos :windows :linux :macos :linux :windows]~%")
                 (out "(prn (mapv m/target-os m/targets))")))
    (is (search "unknown target sparc-solaris; use one of aarch64-macos, x86_64-windows-gnu"
                (out "(prn (try (m/build-program \"x.skn\" {:target \"sparc-solaris\"})
                             (catch error e (condition-message e))))")))
    (is (search "unknown profile fast; use dev or release"
                (out "(prn (try (m/build-program \"x.skn\" {:profile \"fast\"})
                             (catch error e (condition-message e))))")))))
