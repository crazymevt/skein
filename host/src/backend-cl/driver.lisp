;;;; The compiler driver: read, expand, compile and run top-level forms; load files.

(in-package #:skein.backend.cl)

(sb-ext:define-load-time-global **compile-lock**
    (sb-thread:make-mutex :name "Skein compiler")
  "Held while expanding and compiling a top-level form, so that a REPL, the file watcher
and the program can load code from different threads.")

(defun eval-toplevel (form)
  "Expand, compile and run the top-level syntax object FORM in the current namespace and
return its value. A (do ...) form's subforms are each treated as top-level forms, so a
form that changes the namespace (like ns) affects the forms after it."
  (multiple-value-bind (expanded subforms fn)
      (sb-thread:with-recursive-lock (**compile-lock**)
        (let* ((env (skein.expander:make-env :namespace *current-namespace*))
               (expanded (skein.expander:macroexpand form env)))
          (if (skein.expander:toplevel-do-p expanded)
              (values expanded (rest (skein.syntax:syntax-datum expanded)) nil)
              (values expanded nil
                      (compile-node (skein.expander:analyze-toplevel
                                     expanded *current-namespace*))))))
    (declare (ignore expanded))
    (if fn
        (progn (skein.runtime:ensure-float-modes)
               (funcall fn))
        (let ((value nil))
          (dolist (sub subforms value)
            (setf value (eval-toplevel sub)))))))

(defun load-stream (stream &key file)
  "Read and evaluate every form on STREAM, naming FILE in locations. Returns the value of
the last form and the namespace current at the end. The current namespace is restored
afterwards."
  (let* ((*current-namespace* *current-namespace*)
         (reader (skein.reader:make-reader
                  stream :file file
                         :namespace (namespace-name *current-namespace*)
                         :resolve-alias (lambda (alias)
                                          (let ((ns (skein.runtime:find-alias
                                                     *current-namespace* alias)))
                                            (and ns (namespace-name ns))))))
         (eof '#:eof)
         (value nil))
    (loop
      (setf (skein.reader:reader-namespace reader) (namespace-name *current-namespace*))
      (let ((form (skein.reader:read-form reader :eof-value eof)))
        (when (eq form eof)
          (skein.runtime:check-equiv-hash-methods)
          (return (values value *current-namespace*)))
        (setf value (eval-toplevel form))))))

(defun load-string (string &key file namespace)
  "Evaluate every form in STRING and return the last value. NAMESPACE (a string) is the
namespace to start in; it defaults to the current one."
  (let ((*current-namespace* (if namespace (ensure-namespace namespace) *current-namespace*)))
    (with-input-from-string (s string)
      (load-stream s :file file))))

(defun load-file (path)
  "Evaluate every form in the UTF-8 file at PATH. Returns the last value and the
namespace current at the end of the file. Namespaces declared in it record it as their
file, for reload."
  (let ((skein.runtime:*loading-file* (uiop:native-namestring (truename path))))
    (with-open-file (s path :external-format :utf-8)
      (load-stream s :file (if (stringp path) path (namestring path))))))

(defun find-namespace-file (name)
  "Return the path of the source file for namespace NAME on *SOURCE-PATHS* or in lib/,
or NIL."
  (loop for dir in (append *source-paths* (list (library-directory)))
        for path = (merge-pathnames (namespace-file-name name)
                                    (uiop:ensure-directory-pathname dir))
        when (probe-file path) return path))

(defun load-namespace (name)
  "Find the source file for namespace NAME on *SOURCE-PATHS* and load it."
  (let ((path (find-namespace-file name)))
    (unless path
      (skein-error 'namespace-error nil "cannot find namespace ~A: no ~A in ~{~A~^, ~}"
                   name (namespace-file-name name)
                   (or (mapcar #'uiop:native-namestring *source-paths*) '("(no source paths)"))))
    (let ((ok nil))
      (unwind-protect
           (progn (let ((*current-namespace* (ensure-namespace "user")))
                    (load-file path))
                  (setf ok t))
        ;; Let a later require retry a namespace whose file failed to load.
        (unless ok
          (let ((ns (find-namespace name)))
            (when ns (setf (namespace-loaded-p ns) nil))))))))

(setf *namespace-loader* 'load-namespace)

(defun library-directory ()
  "Return the lib/ directory of the Skein checkout, which holds Skein's own namespaces."
  (merge-pathnames "lib/" (uiop:pathname-parent-directory-pathname
                           (asdf:system-source-directory "skein"))))

(defun load-core-library ()
  "Load skein.core's Skein source, lib/skein/core.skn, into the image."
  (let ((*current-namespace* (ensure-namespace "user")))
    (load-file (merge-pathnames "skein/core.skn" (library-directory)))))

(defun program-source-paths (path)
  "The source paths for a program whose main file is PATH: its directory, the current
directory and lib/."
  (remove-duplicates (list (uiop:pathname-directory-pathname (merge-pathnames path))
                           (uiop:getcwd)
                           (library-directory))
                     :test #'equal :key #'uiop:native-namestring :from-end t))

(defun main-function (namespace)
  "Return the value of NAMESPACE's -main var if it is defined, else NIL."
  (let ((var (skein.runtime:find-own-var namespace "-main")))
    (and var (not (eq (skein.runtime:var-value var) skein.runtime:+unbound+))
         (skein.runtime:var-value var))))

(defun run-file (path &key (args '()) (call-main t) after-load)
  "Run the Skein program in the file at PATH, as `skein run` does: load it, then, if its
namespace defines -main and CALL-MAIN is true, call -main with ARGS (strings). AFTER-LOAD,
if given, is called with the file's namespace between loading and calling -main.
Namespaces it requires are looked up next to it, in the current directory and in lib/.
Returns the value of -main, or of the file's last form."
  (let* ((*source-paths* (program-source-paths path))
         (*current-namespace* (ensure-namespace "user")))
    (skein.runtime:ensure-float-modes)
    (multiple-value-bind (value namespace) (load-file path)
      (when after-load (funcall after-load namespace))
      (let ((main (and call-main (main-function namespace))))
        (prog1 (if main (skein.runtime::skein-apply main args) value)
          (finish-output *standard-output*))))))

;;; skein.core's macros are written in Skein, so load them whenever this system loads.
(load-core-library)
