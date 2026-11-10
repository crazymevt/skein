;;;; skein.io's primitives (DESIGN §21, M1.9, D-058): files and processes. lib/skein/io.skn
;;;; wraps them and signals io-error; the native runtime has the same ones (runtime/src/io.zig).
;;;; The names start with % because they are internal: they return nil on failure.

(in-package #:skein.runtime)

(defun native-path (path)
  "PATH, a Skein string, as a pathname taken literally (no wildcards)."
  (unless (stringp path)
    (unsupported "a path must be a string, not ~A" (readable-string path)))
  (uiop:parse-native-namestring path))

(defcore "%read-file" (path)
  ;; The file's contents as a string (UTF-8), or nil if it can't be read.
  (let ((p (native-path path)))
    (handler-case (with-open-file (s p :external-format :utf-8)
                    (let* ((text (make-string (file-length s)))
                           (n (read-sequence text s)))
                      (subseq text 0 n)))
      (error () nil))))

(defcore "%write-file" (path text)
  ;; Write TEXT (UTF-8) to the file, replacing it. True, or false if it can't be written.
  (unless (stringp text) (unsupported "write-file needs a string, not ~A" (readable-string text)))
  (let ((p (native-path path)))
    (bool (handler-case (with-open-file (s p :direction :output :if-exists :supersede
                                             :if-does-not-exist :create :external-format :utf-8)
                          (write-string text s)
                          t)
            (error () nil)))))

(defcore "%file-exists?" (path)
  ;; True if a file or directory exists at PATH.
  (bool (ignore-errors (probe-file (native-path path)))))

(defcore "%make-directories" (path)
  ;; Make the directory PATH and any missing parents. True, or false if it can't. (For
  ;; packaging, M1.11.)
  (bool (ignore-errors
         (ensure-directories-exist (uiop:ensure-directory-pathname (native-path path)))
         t)))

(defcore "%copy-file" (from to)
  ;; Copy the file FROM to TO, replacing it. True, or false if it can't.
  (bool (ignore-errors (uiop:copy-file (native-path from) (native-path to)) t)))

(defcore "%delete-tree" (path)
  ;; Delete the file or directory tree PATH. True, or false if it can't (or isn't there).
  (let ((p (native-path path)))
    (bool (ignore-errors
           (let ((dir (uiop:directory-exists-p p)))
             (if dir
                 (uiop:delete-directory-tree dir :validate t)
                 (delete-file p))
             t)))))

(defcore "%list-directory" (path)
  ;; The names in the directory PATH, sorted, each directory's ending with /; nil if it
  ;; can't be read.
  (let ((dir (uiop:directory-exists-p (native-path path))))
    (when dir
      (vector-from-list
       (sort (append (mapcar #'file-namestring (uiop:directory-files dir))
                     (mapcar (lambda (d) (format nil "~A/" (car (last (pathname-directory d)))))
                             (uiop:subdirectories dir)))
             #'string<)))))

(defcore "%run-process" (argv dir)
  ;; Run ARGV (a vector of strings: the program, then its arguments) without a shell, in
  ;; DIR (a string, or nil for the current directory). Returns {:exit :out :err}, or nil
  ;; if the program can't be started.
  (let ((args (seq-to-cl argv)))
    (unless (and args (every #'stringp args))
      (unsupported "run-process needs a vector of strings, not ~A" (readable-string argv)))
    (block run
      (multiple-value-bind (out err code)
          (handler-case (uiop:run-program args :output :string :error-output :string
                                               :ignore-error-status t :external-format :utf-8
                                               :directory (and dir (uiop:ensure-directory-pathname
                                                                    (native-path dir))))
            (error () (return-from run nil)))
        (map-from-pairs (list (intern-kw "exit") code (intern-kw "out") out
                              (intern-kw "err") err))))))
