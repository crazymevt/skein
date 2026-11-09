;;;; Compare n-body natively compiled from nbody.skn with the same program in C (M1.8's
;;;; exit criterion: within 1.5x). Run with `make bench`. Prints a Markdown table.

(load (merge-pathnames "../../host/tools/bootstrap.lisp" *load-truename*))
(skein-quickload "skein")

(defparameter *steps* "5000000")
(defparameter *runs* 5)

(defvar *here* (uiop:pathname-directory-pathname *load-truename*))
(defvar *out* (uiop:ensure-directory-pathname
               (merge-pathnames "skein-bench-nbody/" (uiop:temporary-directory))))
(ensure-directories-exist *out*)

(defun exe (name)
  (merge-pathnames (format nil "~A~:[~;.exe~]" name
                           (string= (skein.platform:os-name) "windows"))
                   *out*))

(defun best-time (exe)
  "Best wall-clock seconds of *RUNS* runs of EXE, and its output."
  (let ((best nil) (output nil))
    (dotimes (i *runs* (values best output))
      (let ((start (get-internal-real-time)))
        (setf output (uiop:run-program (list (uiop:native-namestring exe) *steps*)
                                       :output :string))
        (let ((s (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
          (setf best (if best (min best s) s)))))))

(uiop:run-program (list (or (uiop:getenv "SKEIN_ZIG") "zig") "cc" "-O2"
                        "-o" (uiop:native-namestring (exe "nbody-c"))
                        (uiop:native-namestring (merge-pathnames "nbody.c" *here*)) "-lm")
                  :output t :error-output t)
(let ((*default-pathname-defaults* *here*))
  (skein.backend.c:build-program (merge-pathnames "main.skn" *here*)
                                 :output (uiop:native-namestring (exe "nbody-skein"))
                                 :profile :release))

(multiple-value-bind (c c-out) (best-time (exe "nbody-c"))
  (multiple-value-bind (skein skein-out) (best-time (exe "nbody-skein"))
    (format t "~%| n-body, ~A steps | Best of ~D (s) |~%|---|---|~%| C (zig cc -O2) | ~,3F |~%~
               | Skein, native release build | ~,3F |~%| Ratio | ~,2Fx |~%~%C: ~ASkein: ~A"
            *steps* *runs* c skein (/ skein c) c-out skein-out)))
