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

;;; ex-info (M2.11, D-093): an error carrying a map. Natively it's a built-in type whose
;;; message is the condition's own; here the message is a hidden slot that its report
;;; shows.

(define-condition-type (intern-sym "ex-info" "skein.core") (list (builtin-type "error"))
  (list (list (intern-sym "data") nil) (list (intern-sym "cause") nil)
        (list (intern-sym "%message") nil))
  (lambda (c) (condition-slot c "%message")))

(defcore "ex-info" (message data &optional cause)
  (unless (stringp message)
    (skein-error 'skein-error nil "ex-info needs a message string, not ~A"
                 (readable-string message)))
  (unless (map-p data)
    (skein-error 'skein-error nil "ex-info needs a map of data, not ~A" (readable-string data)))
  (make-skein-condition (find-condition-type (intern-sym "ex-info" "skein.core"))
                        (list (intern-kw "data") data (intern-kw "cause") cause
                              (intern-kw "%message") message)))

(defun ex-info-p (x)
  (let ((type (and (typep x 'condition) (defined-type-of x))))
    (and type (string= (condition-type-name type) "skein.core/ex-info"))))

(defcore "ex-data" (x) (and (ex-info-p x) (condition-slot x "data")))
(defcore "ex-cause" (x) (and (typep x 'condition) (condition-slot x "cause" nil)))
(defcore "ex-message" (x) (and (typep x 'condition) (condition-report x)))

;;; Metadata (M2.11, D-093) is native only: Phase 0's values carry none.

(defcore "meta" (x) (declare (ignore x)) nil)
(defcore "with-meta" (x m) (declare (ignore m)) x)
