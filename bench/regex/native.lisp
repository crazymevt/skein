;;;; Search a large file with regular expressions natively (M3.3's exit criterion): builds
;;;; search.skn with the native compiler and the release profile (the regex functions are
;;;; native only, D-105) and runs it, which prints a Markdown table. Run with `make bench`.

(require :asdf)

(defvar *root* (merge-pathnames "../../" (uiop:pathname-directory-pathname *load-truename*)))
(defvar *out* (uiop:ensure-directory-pathname
               (merge-pathnames "skein-bench-regex/" (uiop:temporary-directory))))
(ensure-directories-exist *out*)

(defvar *exe* (merge-pathnames (if (uiop:os-windows-p) "search.exe" "search") *out*))

(uiop:run-program (list (uiop:native-namestring (merge-pathnames "skein" *root*))
                        "build" (uiop:native-namestring
                                 (merge-pathnames "bench/regex/search.skn" *root*))
                        "-o" (uiop:native-namestring *exe*) "--profile" "release")
                  :directory *root* :output t :error-output t)

(let ((log (merge-pathnames "search.log" *out*)))
  (uiop:run-program (list (uiop:native-namestring *exe*) (uiop:native-namestring log))
                    :output t :error-output t)
  (delete-file log))
