;;;; Compare the Skein n-body program with the hand-written SBCL one (M0.8 exit criterion:
;;;; within 2x). Run with `make bench`. Prints a Markdown table.

(load (merge-pathnames "../../host/tools/bootstrap.lisp" *load-truename*))
(skein-quickload "skein")

(defparameter *steps* 5000000)
(defparameter *runs* 5)

(defvar *here* (uiop:pathname-directory-pathname *load-truename*))

(load (compile-file (merge-pathnames "nbody.lisp" *here*)
                    :output-file (merge-pathnames "nbody-reference.fasl"
                                                  (uiop:temporary-directory))))
(skein.backend.cl:load-file (merge-pathnames "nbody.skn" *here*))

(defun skein-run (steps)
  (let ((v (funcall (skein.runtime:var-value
                     (skein.runtime:find-own-var (skein.runtime:find-namespace "nbody") "run"))
                    steps)))
    (values (skein.runtime:vector-nth v 0) (skein.runtime:vector-nth v 1))))

(defun best-time (fn)
  (let ((best nil))
    (dotimes (i *runs* best)
      (sb-ext:gc :full t)
      (let ((start (get-internal-real-time)))
        (funcall fn *steps*)
        (let ((s (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
          (setf best (if best (min best s) s)))))))

(multiple-value-bind (a b) (nbody-reference::run 1000)
  (multiple-value-bind (c d) (skein-run 1000)
    (unless (and (= a c) (= b d))
      (error "the Skein and SBCL programs disagree: ~A ~A vs ~A ~A" c d a b))))

(let ((reference (best-time #'nbody-reference::run))
      (skein (best-time #'skein-run)))
  (format t "~&| n-body, ~:D steps | Best of ~D (s) |~%|---|---|~%" *steps* *runs*)
  (format t "| hand-written SBCL (bench/nbody/nbody.lisp) | ~,3F |~%" reference)
  (format t "| Skein (bench/nbody/nbody.skn) | ~,3F |~%" skein)
  (format t "| ratio (target: at most 2.0) | ~,2F |~%" (/ skein reference)))
