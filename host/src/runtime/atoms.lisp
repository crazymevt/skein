;;;; Atoms (DESIGN §6.3): a value updated by compare-and-swap. Used by :cell :atom slots.

(in-package #:skein.runtime)


;;; The SKEIN-ATOM struct is defined in coll-types.lisp.

(defun atom-swap (a f args)
  "Set the atom A to (apply F current ARGS), retrying if another thread changed it first.
Returns the new value."
  (loop
    (let* ((old (skein-atom-value a))
           (new (skein-apply f (cons old args))))
      (when (eq old (sb-ext:compare-and-swap (skein-atom-value a) old new))
        (return new)))))

(defun check-atom (a what)
  (unless (skein-atom-p a)
    (unsupported "~A needs an atom, not ~A" what (readable-string a))))

(defcore "atom" (value) (make-skein-atom value))
(defcore "atom?" (x) (bool (skein-atom-p x)))
(defcore "deref" (a) (check-atom a "deref (@)") (skein-atom-value a))
(defcore "reset!" (a value) (check-atom a "reset!") (setf (skein-atom-value a) value))
(defcore "swap!" (a f &rest args) (check-atom a "swap!") (atom-swap a f args))
(defcore "compare-and-set!" (a old new)
  (check-atom a "compare-and-set!")
  (bool (eq old (sb-ext:compare-and-swap (skein-atom-value a) old new))))
