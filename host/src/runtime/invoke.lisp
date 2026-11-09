;;;; Calling values, and truthiness.

(in-package #:skein.runtime)

(declaim (inline truthy-p))
(defun truthy-p (x)
  "Return true unless X is nil or false."
  (not (or (null x) (eq x +false+))))

(declaim (inline bool))
(defun bool (x)
  "Return Skein true (CL T) if X is true in CL, else Skein false."
  (if x t +false+))

(defun kw-lookup (kw target &optional default)
  "Look KW up in TARGET, as calling a keyword does: (get TARGET KW DEFAULT)."
  (coll-get target kw default))

(defun invoke-other (f location &rest args)
  "Call F, which is not a CL function, with ARGS (DESIGN §6.4). Keywords look themselves
up in their argument; maps and sets look up their argument; vectors return the element
at an index. Anything else signals NOT-CALLABLE-ERROR reporting LOCATION."
  (cond ((typep f '(or kw array-map hash-map hash-set))
         (unless (<= 1 (length args) 2)
           (skein-error 'arity-error location "~A called with ~D arguments; expected 1 or 2"
                        (readable-string f) (length args)))
         (if (kw-p f)
             (apply #'kw-lookup f args)
             (coll-get f (first args) (second args))))
        ((pvector-p f)
         (unless (= (length args) 1)
           (skein-error 'arity-error location "a vector called with ~D arguments; expected 1"
                        (length args)))
         (vector-nth f (first args)))
        (t (skein-error 'not-callable-error location "cannot call ~A" (readable-string f)))))

(defun arity-error (name count location)
  "Signal ARITY-ERROR for function NAME called with COUNT arguments. LOCATION is where
the function was defined; the message names it, since the call site is not known."
  (error 'arity-error
         :function-name name :argument-count count
         :message (format nil "wrong number of arguments (~D) passed to ~A~@[ (defined at ~A)~]"
                          count name (and location (skein.syntax:format-location location)))))
