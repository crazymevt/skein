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
  "Look KW up in TARGET, as calling a keyword does. Phase 0 has no maps until M0.4, so
only nil is supported: the result is DEFAULT."
  (if (null target)
      default
      (skein-error 'skein-error nil "cannot look up ~A in ~A" (atom-to-string kw)
                   (readable-string target))))

(defun invoke-other (f location &rest args)
  "Call F, which is not a CL function, with ARGS. Keywords look themselves up in their
first argument; anything else signals NOT-CALLABLE-ERROR reporting LOCATION."
  (cond ((kw-p f)
         (unless (<= 1 (length args) 2)
           (skein-error 'arity-error location "keyword ~A called with ~D arguments; ~
                                               expected 1 or 2"
                        (atom-to-string f) (length args)))
         (apply #'kw-lookup f args))
        (t (skein-error 'not-callable-error location "cannot call ~A" (readable-string f)))))

(defun arity-error (name count location)
  "Signal ARITY-ERROR for function NAME called with COUNT arguments. LOCATION is where
the function was defined; the message names it, since the call site is not known."
  (skein-error 'arity-error nil "wrong number of arguments (~D) passed to ~A~@[ (defined at ~A)~]"
               count name (and location (skein.syntax:format-location location))))
