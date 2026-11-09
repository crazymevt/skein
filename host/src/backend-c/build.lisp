;;;; skein build: translate a Skein file to C with the Phase 0 front end, then compile it
;;;; with zig cc against the runtime (D-044).

(in-package #:skein.backend.c)

(defun form-head (form)
  "The unqualified name at the head of a list syntax object, or NIL."
  (and (eq (skein.syntax:syntax-kind form) :list)
       (skein.syntax:syntax-datum form)
       (let ((head (skein.syntax:syntax-datum (first (skein.syntax:syntax-datum form)))))
         (and (sym-p head) (null (sym-namespace head)) (sym-name head)))))

(defun translate-form (form)
  "Translate one top-level syntax object. ns and defmacro forms run on the host at
compile time and produce no code; everything else becomes C."
  (let ((head (form-head form)))
    (cond ((member head '("ns" "defmacro") :test #'equal)
           (skein.backend.cl:eval-toplevel form)
           (when (and (string= head "ns")
                      (remove-if (lambda (ns) (string= (namespace-name ns) "skein.core"))
                                 (skein.runtime:namespace-requires *current-namespace*)))
             (error 'c-backend-error
                    :location (skein.syntax:syntax-location form)
                    :message "programs that require other namespaces build natively from ~
                              M1.8; for now a native program is one file")))
          (t
           (let* ((env (skein.expander:make-env :namespace *current-namespace*))
                  (expanded (skein.expander:macroexpand form env)))
             (if (skein.expander:toplevel-do-p expanded)
                 (dolist (sub (rest (skein.syntax:syntax-datum expanded)))
                   (translate-form sub))
                 (emit-toplevel (skein.expander:analyze-toplevel expanded
                                                                 *current-namespace*))))))))

(defun translate-file (path)
  "Translate the Skein program in PATH to C source text. Its -main, if any, is called
with no arguments after the top-level forms run."
  (let ((*unit* (make-unit))
        (*current-namespace* (ensure-namespace "user"))
        (skein.runtime:*source-paths* (skein.backend.cl:program-source-paths path))
        (file (namestring path)))
    (with-open-file (s path :external-format :utf-8)
      (let ((reader (skein.reader:make-reader s :file file :namespace "user")))
        (loop
          (setf (skein.reader:reader-namespace reader) (namespace-name *current-namespace*))
          (let ((form (skein.reader:read-form reader :eof-value :eof)))
            (when (eq form :eof) (return))
            (translate-form form)))))
    (let* ((main (skein.runtime:find-own-var *current-namespace* "-main"))
           (main-c (and main (gethash main (unit-vars *unit*)))))
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
    (run-tool (append (list (zig-program) "cc" "-std=c11"
                            (if (eq profile :release) "-O2" "-O1")
                            "-I" (uiop:native-namestring (merge-pathnames "include/" prefix)))
                      (when target (list "-target" target))
                      (list (uiop:native-namestring c-file)
                            (uiop:native-namestring (runtime-library prefix))
                            "-o" (uiop:native-namestring (merge-pathnames output)))))
    (merge-pathnames output)))
