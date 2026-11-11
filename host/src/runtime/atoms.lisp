;;;; Atoms (DESIGN §6.3): a value updated by compare-and-swap. Used by :cell :atom slots.

(in-package #:skein.runtime)


;;; The SKEIN-ATOM struct is defined in coll-types.lisp.

(defun atom-validate (a new)
  "Signal an error unless A's validator, if any, accepts NEW (M2.11)."
  (let ((f (skein-atom-validator a)))
    (when (and f (not (truthy-p (skein-apply f (list new)))))
      (skein-error 'skein-error nil "the validator rejected the new value ~A"
                   (readable-string new)))))

(defun atom-notify (a old new)
  "Call A's watches for a change from OLD to NEW."
  (loop for (key . f) in (reverse (skein-atom-watches a))
        do (skein-apply f (list key a old new))))

(defun atom-swap (a f args)
  "Set the atom A to (apply F current ARGS), retrying if another thread changed it first.
Returns the old and new values."
  (loop
    (let* ((old (skein-atom-value a))
           (new (skein-apply f (cons old args))))
      (atom-validate a new)
      (when (eq old (sb-ext:compare-and-swap (skein-atom-value a) old new))
        (atom-notify a old new)
        (return (values new old))))))

(defun atom-reset (a new)
  "Set the atom A to NEW; returns the old value."
  (atom-validate a new)
  (loop
    (let ((old (skein-atom-value a)))
      (when (eq old (sb-ext:compare-and-swap (skein-atom-value a) old new))
        (atom-notify a old new)
        (return old)))))

(defun check-atom (a what)
  (unless (skein-atom-p a)
    (unsupported "~A needs an atom, not ~A" what (readable-string a))))

(defcore "atom" (value &rest options)
  (let ((a (make-skein-atom value)))
    (loop for (k v) on options by #'cddr
          do (unless (and (kw-p k) (string= (kw-name k) "validator"))
               (skein-error 'skein-error nil "atom has no option ~A (it takes :validator)"
                            (readable-string k)))
             (setf (skein-atom-validator a) v))
    (when (and (skein-atom-validator a)
               (not (truthy-p (skein-apply (skein-atom-validator a) (list value)))))
      (skein-error 'skein-error nil "the validator rejects the initial value"))
    a))
(defcore "atom?" (x) (bool (skein-atom-p x)))
(defcore "deref" (x &optional (timeout nil timeout-p) timeout-value)
  ;; Atoms give their value; tasks (futures, spawned tasks) wait for theirs. With a
  ;; timeout in seconds, a task that is not done by then gives TIMEOUT-VALUE.
  (cond ((skein-atom-p x) (skein-atom-value x))
        ((task-p x)
         (let ((v (await-task x :deadline (and timeout-p (seconds-from-now timeout)))))
           (if (eq v :timeout) timeout-value v)))
        ((skein-promise-p x)
         (deref-promise x (and timeout-p (seconds-from-now timeout)) timeout-value))
        ((skein-volatile-p x) (skein-volatile-value x))
        ;; An instance: its class's deref-object method (D-103), as Clojure's IDeref.
        ((instance-p x) (funcall (core-fn "deref-object") x timeout timeout-value))
        (t (unsupported "deref (@) needs an atom, a ref, a volatile, a promise, a delay or ~
                         a task, not ~A"
                        (readable-string x)))))
(defcore "reset!" (a value) (check-atom a "reset!") (atom-reset a value) value)
(defcore "swap!" (a f &rest args) (check-atom a "swap!") (values (atom-swap a f args)))
(defcore "reset-vals!" (a value)
  (check-atom a "reset-vals!")
  (vector-from-list (list (atom-reset a value) value)))
(defcore "swap-vals!" (a f &rest args)
  (check-atom a "swap-vals!")
  (multiple-value-bind (new old) (atom-swap a f args)
    (vector-from-list (list old new))))
(defcore "compare-and-set!" (a old new)
  (check-atom a "compare-and-set!")
  (atom-validate a new)
  (if (eq old (sb-ext:compare-and-swap (skein-atom-value a) old new))
      (progn (atom-notify a old new) (bool t))
      (bool nil)))
(defcore "add-watch" (a key f)
  (check-atom a "add-watch")
  (setf (skein-atom-watches a)
        (acons key f (remove key (skein-atom-watches a) :key #'car :test #'equiv)))
  a)
(defcore "remove-watch" (a key)
  (check-atom a "remove-watch")
  (setf (skein-atom-watches a) (remove key (skein-atom-watches a) :key #'car :test #'equiv))
  a)
(defcore "set-validator!" (a f)
  (check-atom a "set-validator!")
  (when (and f (not (truthy-p (skein-apply f (list (skein-atom-value a))))))
    (skein-error 'skein-error nil "the validator rejects the current value"))
  (setf (skein-atom-validator a) f)
  nil)
(defcore "get-validator" (a) (check-atom a "get-validator") (skein-atom-validator a))
