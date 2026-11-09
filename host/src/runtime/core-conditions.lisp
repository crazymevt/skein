;;;; skein.core functions for conditions and restarts (DESIGN §10).

(in-package #:skein.runtime)

(defcore "error" (x &rest args) (throw-condition (to-condition x args :error)))
(defcore "signal" (x &rest args) (signal (to-condition x args :signal)) nil)
(defcore "warn" (x &rest args) (warn (to-condition x args :warning)) nil)
(defcore "make-condition" (type &rest initargs) (make-skein-condition type initargs))
(defcore "condition?" (x) (bool (typep x 'condition)))
(defcore "error?" (x) (bool (typep x 'error)))
(defcore "condition-message" (c) (condition-report c))
(defcore "condition-type" (c) (condition-type-of c))
(defcore "condition-type-name" (type)
  (let* ((name (condition-type-name (find-condition-type type)))
         (slash (position #\/ name)))
    (intern-sym (subseq name (1+ slash)) (subseq name 0 slash))))

(defcore "invoke-restart" (restart &rest args)
  (let ((r (active-restart restart nil)))
    (unless r
      (skein-error 'skein-error nil "no restart ~A is active"
                   (readable-string (if (skein-restart-p restart)
                                        (skein-restart-name restart)
                                        restart))))
    (apply #'invoke-restart r args)))
(defcore "find-restart" (name &optional condition)
  (let ((r (active-restart name condition))) (and r (wrap-restart r))))
(defcore "compute-restarts" (&optional condition)
  (list-from-cl (skein-compute-restarts condition)))
(defcore "restart-name" (restart) (skein-restart-name restart))
(defcore "restart-report" (restart) (skein-restart-report restart))

;;; Used by the condition macros in lib/skein/core.skn.

(defcore "%condition-type" (name namespace-name) (find-condition-type name namespace-name))
(defcore "%define-condition" (name parents slots report)
  (define-condition-type name (seq-to-cl parents)
    (mapcar (lambda (v) (list (vector-nth v 0) (vector-nth v 1))) (seq-to-cl slots))
    report))
(defcore "%condition-slot" (c slot) (condition-slot c (sym-name slot)))
(defcore "%current-namespace-name" () (namespace-name *current-namespace*))
