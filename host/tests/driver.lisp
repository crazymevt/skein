;;;; The native compiler's driver (lib/skein/compiler/main.skn, M1.9 step 5, D-062): its
;;;; options, targets, projects and packages, checked on the host. What it builds is
;;;; checked by program output in host/tools/bootstrap.sh (D-073).

(in-package #:skein.tests)

(def-suite skein.driver :in all
  :description "The driver of the native compiler: options, targets and projects.")

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

(defun replace-all (text old new)
  (with-output-to-string (s)
    (loop with start = 0
          for p = (search old text :start2 start)
          do (write-string text s :start start :end (or p (length text)))
             (if p (progn (write-string new s) (setf start (+ p (length old)))) (return)))))

(defun project-outcome (files expr)
  "Write FILES ((relative-path text) ...) into a fresh directory, evaluate the Skein EXPR
there (DIR stands for the directory, with / separators), and return what it printed, or
the error message."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "skein-project-~D-~D/" (get-universal-time)
                                       (random 1000000))
                               (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (loop for (name text) in files
                 do (let ((p (merge-pathnames name dir)))
                      (ensure-directories-exist p)
                      (with-open-file (s p :direction :output :if-exists :supersede)
                        (write-string text s))))
           (driver-function "read-project")
           ;; Translating a program on the host needs skein.core.native's vars, which
           ;; translating a program with the Lisp backend makes.
           (ignore-errors (skein.backend.c:translate-file (first (native-programs))))
           (ev-output
            (format nil "(ns driver-projects (:require [skein.compiler.main :as m]))
                         (prn (try ~A (catch error e (condition-message e))))"
                    (replace-all expr "DIR" (directory-string dir)))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(test driver-package-checks-its-arguments
  ;; skein package (M1.11) packages the project in the current directory, nothing else.
  (driver-function "package-project")
  (flet ((main-error (&rest args)
           (ev-output (format nil "(ns driver-package (:require [skein.compiler.main :as m]))
                                   (prn (try (m/-main ~{~S~^ ~})
                                             (catch error e (condition-message e))))"
                              args))))
    (is (search "takes only --target and --profile" (main-error "package" "x.skn")))
    (is (search "takes only --target and --profile" (main-error "package" "-o" "out")))
    (is (search "Usage: skeinc build" (main-error "pack")))))

(test driver-projects
  ;; project.skn (M1.11, D-069): read as data and checked; :paths default to ["src"].
  (let ((out (project-outcome
              '(("project.skn" "{:name \"app\" :main app.main/-main :version \"1.0\"}"))
              "(let [p (m/read-project \"DIRproject.skn\")]
                 [(:name p) (:main p) (:paths p) (:assets p) (:version p)])")))
    (is (search "[\"app\" app.main/-main [\"" out) "~A" out)
    (is (search "/src/\"] [] \"1.0\"]" out) "~A" out))
  (flet ((fails-with (text message)
           (let ((out (project-outcome `(("project.skn" ,text))
                                       "(m/read-project \"DIRproject.skn\")")))
             (is (search message out) "~S: ~A" text out))))
    (fails-with "[:name \"app\"]" "expected a map, like {:name")
    (fails-with "" "expected a map")
    (fails-with "{:name \"a\" :main a.main/-main} {}" "expected one map, with nothing after it")
    (fails-with "{:main a.main/-main}" ":name must be a string")
    (fails-with "{:name \"a\" :main -main}" ":main must be a qualified symbol")
    (fails-with "{:name \"a\" :main a.main/-main :paths \"src\"}"
                ":paths must be a vector of directories")
    (fails-with "{:name \"a\" :main a.main/-main :assets [:x]}"
                ":assets must be a vector of directories")
    (dolist (native '("[]" "{:libs []}" "{:libs {:beos [\"x\"]}}" "{:libs {:linux \"x.so\"}}"
                      "{:libs {:linux [:x]}}"))
      (fails-with (format nil "{:name \"a\" :main a.main/-main :native ~A}" native)
                  ":native must look like {:libs {:macos [")))
  ;; The :main namespace must be on the :paths, and define the :main function.
  (let ((out (project-outcome '(("project.skn" "{:name \"a\" :main nope.main/-main}"))
                              "(m/build-project \"DIRproject.skn\" {})")))
    (is (search "cannot find namespace nope.main in :paths" out) "~A" out))
  (let ((out (project-outcome '(("project.skn" "{:name \"a\" :main a.main/start}")
                                ("src/a/main.skn" "(ns a.main) (defn -main [] nil)"))
                              "(m/build-project \"DIRproject.skn\" {})")))
    (is (search "doesn't define start, the project's :main" out) "~A" out)))
