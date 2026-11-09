;;;; Compile errors, the lexical environment and syntax helpers.

(in-package #:skein.expander)

(define-condition compile-error (skein.runtime:skein-error) ()
  (:documentation "Signaled when a form is malformed or refers to something that does not
exist. The location is the offending form's."))

(defun compile-error (syntax control &rest args)
  "Signal a COMPILE-ERROR about SYNTAX (a syntax object or NIL)."
  (error 'compile-error :location (and syntax (syntax-location syntax))
                        :message (apply #'format nil control args)))

(defstruct (env (:copier copy-env))
  "The lexical environment of the form being expanded."
  (namespace *current-namespace*)
  ;; Alist of name string -> local, innermost first.
  (locals '())
  ;; Alist of name string -> block-tag.
  (blocks '())
  ;; The node RECUR jumps to (a loop-node or arity) and how many values it takes.
  (recur nil)
  (recur-count 0))

(setf (documentation 'env-namespace 'function)
      "Return the namespace that an expander environment resolves names in."
      (documentation 'make-env 'function)
      "Make an expander environment. NAMESPACE defaults to the current namespace.")

(defun lookup-local (env name)
  (cdr (assoc name (env-locals env) :test #'string=)))

(defun with-locals (env locals)
  "Return ENV extended with LOCALS (later ones shadow earlier ones)."
  (let ((new (copy-env env)))
    (dolist (l locals new)
      (push (cons (local-name l) l) (env-locals new)))))

;;; Syntax helpers

(defun loc (syntax) (syntax-location syntax))
(defun items (syntax) (syntax-datum syntax))

(defun sym-datum (syntax)
  "Return SYNTAX's symbol if it is a symbol atom, else NIL."
  (and (eq (syntax-kind syntax) :atom)
       (sym-p (syntax-datum syntax))
       (syntax-datum syntax)))

(defun plain-name (syntax)
  "Return the name of SYNTAX if it is an unqualified symbol, else NIL."
  (let ((s (sym-datum syntax)))
    (and s (null (sym-namespace s)) (sym-name s))))

(defun list-form-p (syntax) (eq (syntax-kind syntax) :list))
(defun vector-form-p (syntax) (eq (syntax-kind syntax) :vector))

(defun head-name (syntax)
  "Return the unqualified name at the head of a list form, or NIL."
  (and (list-form-p syntax) (items syntax) (plain-name (first (items syntax)))))

(defun binding-name (syntax what)
  "Check that SYNTAX is an unqualified symbol suitable as a binding and return its name."
  (or (plain-name syntax)
      (compile-error syntax "~A must be an unqualified symbol, not ~A"
                     what (syntax-to-string syntax))))

(defun meta-flag-p (syntax key)
  "Return true if SYNTAX's metadata maps the keyword KEY to a true value."
  (let ((meta (syntax-meta syntax)))
    (and meta
         (loop for (k v) on (items meta) by #'cddr
               thereis (and (eq (syntax-kind k) :atom)
                            (kw-p (syntax-datum k))
                            (string= (kw-name (syntax-datum k)) key)
                            (eq (syntax-kind v) :atom)
                            (truthy-p (syntax-datum v)))))))

(defun meta-string (syntax key)
  "Return the string that SYNTAX's metadata maps the keyword KEY to, or NIL."
  (let ((meta (syntax-meta syntax)))
    (and meta
         (loop for (k v) on (items meta) by #'cddr
               when (and (eq (syntax-kind k) :atom)
                         (kw-p (syntax-datum k))
                         (string= (kw-name (syntax-datum k)) key)
                         (eq (syntax-kind v) :atom)
                         (stringp (syntax-datum v)))
                 return (syntax-datum v)))))

(defun make-binding-local (syntax what)
  (make-local (binding-name syntax what) :mutable-p (meta-flag-p syntax "mutable")))

;;; Building syntax, for macros

(defun s-sym (name location &optional namespace)
  (make-syntax :kind :atom :datum (intern-sym name namespace) :location location))

(defun core-sym (name location)
  "A symbol naming a skein.core var, qualified so user definitions cannot shadow it."
  (s-sym name location "skein.core"))

(defun s-atom (value location)
  (make-syntax :kind :atom :datum value :location location))

(defun s-list (location &rest items)
  (make-syntax :kind :list :datum items :location location))

(defun s-vector (location items)
  (make-syntax :kind :vector :datum items :location location))

(defvar *auto-name-counter* 0)

(defun s-gensym (prefix location)
  "Return a fresh, unqualified symbol syntax object for a macro's temporary binding."
  (s-sym (format nil "~A__~D__auto" prefix (incf *auto-name-counter*)) location))
