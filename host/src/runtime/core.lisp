;;;; Primitive functions of skein.core, written in CL for Phase 0.
;;;; M0.4 and M0.5 add collections, seqs and the macros written in Skein.

(in-package #:skein.runtime)

(defmacro defcore (name lambda-list &body body)
  "Define the skein.core function NAME (a string) as a CL function."
  `(def-var (intern-var +core+ ,name)
            (sb-int:named-lambda ,(format nil "skein.core/~A" name) ,lambda-list
              ,@body)))

;;; = and not= are in core-coll.lisp.

(defcore "identical?" (x y) (bool (eq x y)))

;;; Arithmetic (DESIGN §6.1): integer op integer is an integer, any float makes a float,
;;; and / on integers returns f64.

(defcore "+" (&rest xs) (apply #'+ xs))
(defcore "-" (x &rest xs) (apply #'- x xs))
(defcore "*" (&rest xs) (apply #'* xs))

(defcore "/" (x &rest xs)
  (let ((args (cons x xs)))
    (if (every #'integerp args)
        (apply #'/ (mapcar (lambda (n) (coerce n 'double-float)) args))
        (apply #'/ args))))

(defcore "quot" (n d)
  (if (and (integerp n) (integerp d)) (values (truncate n d)) (values (ftruncate n d))))
(defcore "rem" (n d) (rem n d))
(defcore "mod" (n d) (mod n d))
(defcore "inc" (x) (1+ x))
(defcore "dec" (x) (1- x))
(defcore "max" (x &rest xs) (without-nan-traps (apply #'max x xs)))
(defcore "min" (x &rest xs) (without-nan-traps (apply #'min x xs)))
(defcore "abs" (x) (abs x))

;;; Comparisons mask the invalid-operation trap so NaN compares false on every platform.
(defcore "<" (x &rest xs) (bool (without-nan-traps (apply #'< x xs))))
(defcore ">" (x &rest xs) (bool (without-nan-traps (apply #'> x xs))))
(defcore "<=" (x &rest xs) (bool (without-nan-traps (apply #'<= x xs))))
(defcore ">=" (x &rest xs) (bool (without-nan-traps (apply #'>= x xs))))
(defcore "==" (x &rest xs) (bool (without-nan-traps (apply #'= x xs))))

(defcore "zero?" (x) (bool (without-nan-traps (zerop x))))
(defcore "pos?" (x) (bool (without-nan-traps (plusp x))))
(defcore "neg?" (x) (bool (without-nan-traps (minusp x))))
(defcore "even?" (x) (bool (evenp x)))
(defcore "odd?" (x) (bool (oddp x)))

;;; Logic and identity

(defcore "not" (x) (bool (not (truthy-p x))))
(defcore "nil?" (x) (bool (null x)))
(defcore "some?" (x) (bool (not (null x))))
(defcore "true?" (x) (bool (eq x t)))
(defcore "false?" (x) (bool (false-p x)))
(defcore "identity" (x) x)
(defcore "boolean" (x) (bool (truthy-p x)))

;;; Macro support

(defvar *skein-gensym-counter* 0)

(defun gensym-name (prefix)
  "Return a fresh symbol name: PREFIX followed by a unique number."
  (format nil "~A~D" prefix (incf *skein-gensym-counter*)))

(defcore "gensym" (&optional (prefix "G__"))
  (intern-sym (gensym-name (if (sym-p prefix) (sym-name prefix) prefix))))

(defcore "%error" (message &rest args)
  (skein-error 'skein-error nil "~A" (if args
                                         (format nil "~{~A~^ ~}" (mapcar #'display-string
                                                                         (cons message args)))
                                         message)))

(defcore "%no-matching-case" (value)
  (skein-error 'skein-error nil "no case clause matches ~A" (readable-string value)))

(defcore "%declaim" (spec)
  (let ((kind (and (plist-p spec) (sym-p (first* spec)) (sym-name (first* spec)))))
    (unless (equal kind "ftype")
      (skein-error 'skein-error nil "declaim supports (ftype (fn [arg-types] return-type) ~
                                     names...), not ~A"
                   (readable-string spec)))
    (let ((type (first* (rest* spec))))
      (dolist (name (seq-to-cl (rest* (rest* spec))))
        (setf (var-ftype (intern-var *current-namespace* (sym-string name "a function name")))
              type)))
    nil))

(defcore "%set-macro!" (name)
  (let ((var (find-own-var *current-namespace* (sym-string name "a macro name"))))
    (setf (var-macro-p var) t)
    var))

;;; Strings and printing

(defcore "str" (&rest xs)
  (with-output-to-string (s)
    (dolist (x xs)
      (cond ((null x))
            ((or (stringp x) (characterp x)) (print-value x s))
            (t (print-value x s :readably t))))))

(defun print-values (xs readably newline)
  (loop for (x . more) on xs
        do (print-value x *standard-output* :readably readably)
           (when more (write-char #\Space *standard-output*)))
  (when newline (terpri *standard-output*))
  nil)

(defcore "print" (&rest xs) (print-values xs nil nil))
(defcore "println" (&rest xs) (print-values xs nil t))
(defcore "pr" (&rest xs) (print-values xs t nil))
(defcore "prn" (&rest xs) (print-values xs t t))
(defcore "pr-str" (&rest xs)
  (format nil "~{~A~^ ~}" (mapcar #'readable-string xs)))

;;; Namespaces. The `ns` macro expands into calls to these.

(defun sym-string (x what)
  (unless (and (sym-p x) (null (sym-namespace x)))
    (skein-error 'namespace-error nil "expected an unqualified symbol for ~A, got ~A"
                 what (display-string x)))
  (sym-name x))

(defcore "%in-ns" (name)
  (let ((ns (ensure-namespace (sym-string name "a namespace name"))))
    (setf (namespace-loaded-p ns) t
          *current-namespace* ns)
    ns))

(defcore "%require" (name alias)
  (let ((ns (require-namespace (sym-string name "a namespace name"))))
    (pushnew ns (namespace-requires *current-namespace*))
    (when alias
      (setf (gethash (sym-string alias "an alias") (namespace-aliases *current-namespace*))
            ns))
    nil))

(defcore "%require-for-syntax" (name alias)
  (let ((ns (require-namespace (sym-string name "a namespace name"))))
    (pushnew ns (namespace-syntax-requires *current-namespace*))
    (when alias
      (setf (gethash (sym-string alias "an alias") (namespace-aliases *current-namespace*))
            ns))
    nil))

(defcore "%refer" (ns-name name)
  (let* ((ns (require-namespace (sym-string ns-name "a namespace name")))
         (var-name (sym-string name "a referred name"))
         (var (find-own-var ns var-name)))
    (unless (and var (not (var-private-p var)))
      (skein-error 'namespace-error nil "~A/~A ~:[does not exist~;is private~]"
                   (namespace-name ns) var-name var))
    (setf (gethash var-name (namespace-refers *current-namespace*)) var)
    nil))
