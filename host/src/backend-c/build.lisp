;;;; skein build: translate a Skein file to C with the Phase 0 front end, then compile it
;;;; with zig cc against the runtime (D-044).

(in-package #:skein.backend.c)

(defun form-head (form)
  "The unqualified name at the head of a list syntax object, or NIL."
  (and (eq (skein.syntax:syntax-kind form) :list)
       (skein.syntax:syntax-datum form)
       (let ((head (skein.syntax:syntax-datum (first (skein.syntax:syntax-datum form)))))
         (and (sym-p head) (null (sym-namespace head)) (sym-name head)))))

(defvar *translated* '()
  "The names of the namespaces already translated into the program being built.")

(defparameter *native-library* "skein.core.native"
  "The namespace of skein.core's functions written in Skein (D-051), which every native
program includes.")

(defvar *core-macro-mode* nil
  "True while lib/skein/core.skn is translated for a program that includes
skein.compiler.env: its macros are compiled into the program (D-060).")

(defun translate-form (form)
  "Translate one top-level syntax object. ns and defmacro forms run on the host at
compile time and produce no code; everything else becomes C. After an ns form, the
namespaces it requires are translated first."
  (let ((head (form-head form)))
    (cond ((and *core-macro-mode* (equal head "defmacro"))
           (translate-core-macro form))
          ((member head '("defstruct" "defsoa") :test #'equal)
           ;; Run on the host too, so the vars the struct defines exist for the forms
           ;; after it; the C backend then sets those vars natively (D-055).
           (skein.backend.cl:eval-toplevel form)
           (translate-compiled form))
          ((member head '("ns" "defmacro") :test #'equal)
           (skein.backend.cl:eval-toplevel form)
           (when (string= head "ns")
             (translate-requires *current-namespace*)))
          (t (translate-compiled form)))))

(defvar *translate-hook* nil
  "For the tests of the C backend written in Skein (M1.9): a function of an event and two
arguments. :form, each expanded top-level form and its namespace, just before the form is
emitted; :core-names, the names lib/skein/core.skn defines, when a program compiles its
macros; :core-macro, the fn form and the var of each such macro; and :program at the end,
with the -main var (or NIL) and the source file's name.")

(defun translate-compiled (form)
  "Translate FORM to C, expanding it; a (do ...) expansion's forms are top-level forms."
  (let* ((env (skein.expander:make-env :namespace *current-namespace*))
         (expanded (skein.expander:macroexpand form env)))
    (if (skein.expander:toplevel-do-p expanded)
        (dolist (sub (rest (skein.syntax:syntax-datum expanded)))
          (translate-form sub))
        (progn
          (when *translate-hook*
            (funcall *translate-hook* :form expanded *current-namespace*))
          (emit-toplevel (skein.expander:analyze-toplevel expanded *current-namespace*))))))

(defun translate-requires (namespace)
  "Translate the namespaces that NAMESPACE requires at run time and the program doesn't
include yet, in the order its ns form requires them. Each one's own requires come first,
so every namespace's code runs after the code of the namespaces it uses."
  (dolist (dep (reverse (skein.runtime:namespace-requires namespace)))
    (let ((name (namespace-name dep)))
      (unless (or (string= name "skein.core") (member name *translated* :test #'string=))
        (push name *translated*)
        (let ((path (skein.backend.cl::find-namespace-file name)))
          (unless path
            (error 'c-backend-error :location nil
                                    :message (format nil "cannot find namespace ~A" name)))
          ;; The native compiler's environment needs skein.core's macros compiled in.
          (when (string= name "skein.compiler.env")
            (translate-core-macros))
          (translate-source path))))))

(defun core-source-names (path)
  "The names that the top-level defmacro, defn, defn- and def forms of PATH define."
  (with-open-file (s path :external-format :utf-8)
    (let ((reader (skein.reader:make-reader s :file (namestring path) :namespace "skein.core"))
          (names '()))
      (loop
        (let ((form (skein.reader:read-form reader :eof-value :eof)))
          (when (eq form :eof) (return (nreverse names)))
          (when (member (form-head form) '("defmacro" "defn" "defn-" "def") :test #'equal)
            (push (sym-name (skein.syntax:syntax-datum
                             (second (skein.syntax:syntax-datum form))))
                  names)))))))

(defun translate-core-macros ()
  "Translate lib/skein/core.skn into the program with its macros compiled, so that
skein.compiler.env can give the native compiler's skein.core its macros (D-060)."
  (let* ((path (skein.backend.cl::find-namespace-file "skein.core"))
         (names (core-source-names path)))
    (setf (unit-env-p *unit*) t)
    (dolist (n names) (setf (gethash n (unit-core-defined *unit*)) t))
    (when *translate-hook* (funcall *translate-hook* :core-names names nil))
    (let ((*core-macro-mode* t))
      (translate-source path))))

(defun translate-core-macro (form)
  "Compile one defmacro of lib/skein/core.skn: only its function is analyzed, since
analyzing its def would clear the host var's macro flag."
  (let* ((env (skein.expander:make-env :namespace *current-namespace*))
         (expanded (skein.expander:macroexpand form env))
         (def-items (skein.syntax:syntax-datum (second (skein.syntax:syntax-datum expanded))))
         (name (sym-name (skein.syntax:syntax-datum (second def-items))))
         (fn-form (car (last def-items)))
         (var (skein.runtime:find-own-var *current-namespace* name)))
    (when *translate-hook*
      (funcall *translate-hook* :core-macro fn-form var))
    (emit-core-macro var (skein.expander:analyze-toplevel fn-form *current-namespace*))))

(defun translate-source (path)
  "Translate every form of the Skein file at PATH, starting in namespace user. Returns
the namespace current at its end."
  (let ((*current-namespace* (ensure-namespace "user")))
    (with-open-file (s path :external-format :utf-8)
      (let ((reader (skein.reader:make-reader
                     s :file (namestring path) :namespace "user"
                     :resolve-alias (lambda (alias)
                                      (let ((ns (skein.runtime:find-alias *current-namespace*
                                                                          alias)))
                                        (and ns (namespace-name ns)))))))
        (loop
          (setf (skein.reader:reader-namespace reader) (namespace-name *current-namespace*))
          (let ((form (skein.reader:read-form reader :eof-value :eof)))
            (when (eq form :eof) (return *current-namespace*))
            (translate-form form)))))))

(defun translate-file (path)
  "Translate the Skein program in PATH, with the namespaces it requires and skein.core's
library in Skein, to C source text. Its -main, if any, is called with the command-line
arguments after the top-level forms run."
  (let ((*unit* (make-unit))
        (*translated* (list *native-library*))
        (skein.runtime:*source-paths* (skein.backend.cl:program-source-paths path)))
    ;; Like every namespace a program requires, the library is loaded on the host too.
    (skein.runtime:require-namespace *native-library*)
    (translate-source (skein.backend.cl::find-namespace-file *native-library*))
    (let* ((ns (translate-source path))
           (main (skein.runtime:find-own-var ns "-main"))
           (main-c (and main (gethash main (unit-vars *unit*)))))
      (when *translate-hook*
        (funcall *translate-hook* :program main (file-namestring path)))
      (program-text *unit* (file-namestring path) main-c))))

;;; ------------------------------------------------------------------------------------
;;; Compiling with zig

(defun zig-program () (or (uiop:getenv "SKEIN_ZIG") "zig"))

(defun runtime-directory ()
  (merge-pathnames "runtime/" (uiop:pathname-parent-directory-pathname
                               (skein.backend.cl:library-directory))))

(defun native-target-name () "native")

(defun run-tool (args &key directory)
  "Run ARGS; signal a C-BACKEND-ERROR with its output if it fails."
  (multiple-value-bind (out err status)
      (handler-case (uiop:run-program args :output :string :error-output :string
                                           :ignore-error-status t :directory directory)
        (error (e)
          (error 'c-backend-error :location nil
                                  :message (format nil "could not run ~A: ~A (install Zig ~
                                                        0.17.1, or set SKEIN_ZIG)"
                                                   (first args) e))))
    (unless (zerop status)
      (error 'c-backend-error :location nil
                              :message (format nil "~A failed:~%~A~A" (first args) out err)))
    out))

(defun build-runtime (target optimize cache)
  "Build the runtime library for TARGET into CACHE; return its install prefix."
  (let ((prefix (merge-pathnames (format nil "runtime/~A-~(~A~)/" (or target "native") optimize)
                                 cache)))
    (run-tool (append (list (zig-program) "build"
                            (format nil "-Doptimize=~A" optimize)
                            "--prefix" (uiop:native-namestring prefix))
                      (when target (list (format nil "-Dtarget=~A" target))))
              :directory (runtime-directory))
    prefix))

(defun runtime-library (prefix)
  (let ((lib (merge-pathnames "lib/" prefix)))
    (or (probe-file (merge-pathnames "libskein_runtime.a" lib))
        (probe-file (merge-pathnames "skein_runtime.lib" lib))
        (error 'c-backend-error :location nil
                                :message (format nil "the runtime library is missing from ~A"
                                                 (uiop:native-namestring lib))))))

(defun build-program (path &key output target (profile :dev) keep-c)
  "Compile the Skein program in PATH to a native executable at OUTPUT (default: the
file's name, in the current directory). TARGET is a zig target triple, or NIL for this
machine. PROFILE :release optimizes more. Returns the executable's path. With KEEP-C,
the C source is left next to the executable."
  (let* ((stem (pathname-name path))
         (windows (or (and target (search "windows" target))
                      (and (null target) (string= (skein.platform:os-name) "windows"))))
         (output (or output (format nil "~A~:[~;.exe~]" stem windows)))
         (cache (merge-pathnames ".skein-cache/" (uiop:getcwd)))
         (c-file (if keep-c
                     (make-pathname :type "c" :defaults (merge-pathnames output))
                     (merge-pathnames (format nil "build/~A.c" stem) cache)))
         (c-source (translate-file path))
         (optimize (if (eq profile :release) "ReleaseFast" "ReleaseSafe"))
         (prefix (progn (ensure-directories-exist cache) (build-runtime target optimize cache))))
    (ensure-directories-exist c-file)
    (with-open-file (s c-file :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string c-source s))
    ;; No fused multiply-adds: floating-point results must be exactly Phase 0's.
    (run-tool (append (list (zig-program) "cc" "-std=c11" "-ffp-contract=off"
                            (if (eq profile :release) "-O2" "-O1")
                            "-I" (uiop:native-namestring (merge-pathnames "include/" prefix)))
                      (when target (list "-target" target))
                      (list (uiop:native-namestring c-file)
                            (uiop:native-namestring (runtime-library prefix))
                            "-o" (uiop:native-namestring (merge-pathnames output)))
                      (unless windows (list "-lm"))))
    (merge-pathnames output)))
