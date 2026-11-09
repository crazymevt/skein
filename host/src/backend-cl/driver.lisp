;;;; The compiler driver: read, expand, compile and run top-level forms; load files.

(in-package #:skein.backend.cl)

(defun eval-toplevel (form)
  "Expand, compile and run the top-level syntax object FORM in the current namespace and
return its value. A (do ...) form's subforms are each treated as top-level forms, so a
form that changes the namespace (like ns) affects the forms after it."
  (let* ((env (skein.expander:make-env :namespace *current-namespace*))
         (expanded (skein.expander:macroexpand form env)))
    (if (skein.expander:toplevel-do-p expanded)
        (let ((value nil))
          (dolist (sub (rest (skein.syntax:syntax-datum expanded)) value)
            (setf value (eval-toplevel sub))))
        (eval-node (skein.expander:analyze-toplevel expanded *current-namespace*)))))

(defun load-stream (stream &key file)
  "Read and evaluate every form on STREAM, naming FILE in locations. Returns the value of
the last form. The current namespace is restored afterwards."
  (let* ((*current-namespace* *current-namespace*)
         (reader (skein.reader:make-reader stream :file file
                                                  :namespace (namespace-name
                                                              *current-namespace*)))
         (eof '#:eof)
         (value nil))
    (loop
      (setf (skein.reader:reader-namespace reader) (namespace-name *current-namespace*))
      (let ((form (skein.reader:read-form reader :eof-value eof)))
        (when (eq form eof) (return value))
        (setf value (eval-toplevel form))))))

(defun load-string (string &key file namespace)
  "Evaluate every form in STRING and return the last value. NAMESPACE (a string) is the
namespace to start in; it defaults to the current one."
  (let ((*current-namespace* (if namespace (ensure-namespace namespace) *current-namespace*)))
    (with-input-from-string (s string)
      (load-stream s :file file))))

(defun load-file (path)
  "Evaluate every form in the UTF-8 file at PATH and return the last value."
  (with-open-file (s path :external-format :utf-8)
    (load-stream s :file (if (stringp path) path (namestring path)))))

(defun find-namespace-file (name)
  (loop for dir in *source-paths*
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

(defun run-file (path)
  "Run the Skein program in the file at PATH, as `skein run` does. Namespaces it requires
are looked up next to it and in the current directory. Returns the last value."
  (let* ((*source-paths* (remove-duplicates
                          (list (uiop:pathname-directory-pathname (merge-pathnames path))
                                (uiop:getcwd))
                          :test #'equal :key #'uiop:native-namestring :from-end t))
         (*current-namespace* (ensure-namespace "user")))
    (prog1 (load-file path)
      (finish-output *standard-output*))))
