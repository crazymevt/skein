;;;; The built-in macros that lib/skein/core.skn needs before it can define the rest:
;;;; ns, defmacro, defn and defn-. Each is a skein.core var whose macro flag is :SYNTAX
;;;; and whose value is a CL function of (form env) that returns a syntax object.

(in-package #:skein.expander)

(defmacro define-builtin-macro (name (form env) &body body)
  `(let ((var (intern-var +core+ ,name)))
     (def-var var (sb-int:named-lambda ,(format nil "skein.core/~A" name) (,form ,env)
                    (declare (ignorable ,env))
                    ,@body))
     (setf (var-macro-p var) :syntax)))


(defun macro-args (form) (rest (items form)))

;;; ns

(defun quoted (syntax)
  (s-list (loc syntax) (s-sym "quote" (loc syntax)) syntax))

(defun require-calls (spec loader)
  "Return the calls that load one :require spec: a.b or [a.b :as c :refer [x y]].
LOADER is \"%require\" or \"%require-for-syntax\"."
  (let ((l (loc spec)))
    (cond ((sym-datum spec)
           (list (s-list l (core-sym loader l) (quoted spec) (s-atom nil l))))
          ((vector-form-p spec)
           (destructuring-bind (name &rest options) (items spec)
             (unless (plain-name name)
               (compile-error name "expected a namespace name, not ~A"
                              (syntax-to-string name)))
             (let ((alias nil) (refers '()))
               (loop while options
                     do (let* ((key (pop options))
                               (k (and (eq (syntax-kind key) :atom)
                                       (kw-p (syntax-datum key))
                                       (kw-name (syntax-datum key)))))
                          (unless options
                            (compile-error key "~A needs a value" (syntax-to-string key)))
                          (let ((value (pop options)))
                            (cond ((equal k "as")
                                   (binding-name value "an alias")
                                   (setf alias value))
                                  ((equal k "refer")
                                   (unless (vector-form-p value)
                                     (compile-error value ":refer needs a vector of names"))
                                   (dolist (r (items value))
                                     (binding-name r "a referred name")
                                     (push r refers)))
                                  (t (compile-error key "unknown require option ~A"
                                                    (syntax-to-string key)))))))
               (cons (s-list l (core-sym loader l) (quoted name)
                             (if alias (quoted alias) (s-atom nil l)))
                     (loop for r in (nreverse refers)
                           collect (s-list l (core-sym "%refer" l) (quoted name)
                                           (quoted r)))))))
          (t (compile-error spec "expected a namespace name or [name :as alias ...], not ~A"
                            (syntax-to-string spec))))))

(define-builtin-macro "ns" (form env)
  (let* ((args (macro-args form))
         (name (or (first args) (compile-error form "ns needs a namespace name"))))
    (binding-name name "a namespace name")
    (let ((clauses (rest args)))
      ;; An optional docstring.
      (when (and clauses (eq (syntax-kind (first clauses)) :atom)
                 (stringp (syntax-datum (first clauses))))
        (pop clauses))
      (apply #'s-list (loc form) (s-sym "do" (loc form))
             (s-list (loc form) (core-sym "%in-ns" (loc form)) (quoted name))
             (loop for clause in clauses
                   append (let ((k (and (list-form-p clause) (items clause)
                                        (kw-p (syntax-datum (first (items clause))))
                                        (kw-name (syntax-datum (first (items clause)))))))
                            (unless (member k '("require" "require-for-syntax") :test #'equal)
                              (compile-error clause "unknown ns clause ~A; expected ~
                                                     (:require ...)"
                                             (syntax-to-string clause)))
                            (loop for spec in (rest (items clause))
                                  append (require-calls spec (if (equal k "require")
                                                                 "%require"
                                                                 "%require-for-syntax")))))))))

;;; defn, defn-

(defun meta-entry (key value location)
  (list (s-atom (intern-kw key) location) value))

(defun defn-expansion (form private-p)
  (let* ((args (macro-args form))
         (name (or (first args) (compile-error form "defn needs a name")))
         (rest (rest args))
         (l (loc form))
         (entries '()))
    (binding-name name "a function name")
    (when (and rest (eq (syntax-kind (first rest)) :atom) (stringp (syntax-datum (first rest))))
      (setf entries (append entries (meta-entry "doc" (pop rest) l))))
    (when (and rest (eq (syntax-kind (first rest)) :map))
      (setf entries (append entries (items (pop rest)))))
    (when private-p
      (setf entries (append entries (meta-entry "private" (s-atom t l) l))))
    (let* ((old (and (syntax-meta name) (items (syntax-meta name))))
           (meta (append entries old))
           (def-name (make-syntax :kind :atom :datum (syntax-datum name) :location (loc name)
                                  :meta (and meta (make-syntax :kind :map :datum meta
                                                               :location l)))))
      (s-list l (s-sym "def" l) def-name
              (apply #'s-list l (s-sym "fn" l) (s-sym (plain-name name) (loc name)) rest)))))

(define-builtin-macro "defn" (form env) (defn-expansion form nil))
(define-builtin-macro "defn-" (form env) (defn-expansion form t))

;;; defmacro: (defmacro name doc? attr-map? [params] body...) or with several arities.
;;; Each arity gets &form and &env parameters in front of the user's.

(define-builtin-macro "defmacro" (form env)
  (let* ((args (macro-args form))
         (name (or (first args) (compile-error form "defmacro needs a name")))
         (rest (rest args))
         (l (loc form))
         (doc nil))
    (binding-name name "a macro name")
    (when (and rest (eq (syntax-kind (first rest)) :atom) (stringp (syntax-datum (first rest))))
      (setf doc (pop rest)))
    (when (and rest (eq (syntax-kind (first rest)) :map))
      (pop rest))
    (flet ((with-implicit-params (vector)
             (unless (vector-form-p vector)
               (compile-error vector "defmacro parameters must be a vector, not ~A"
                              (syntax-to-string vector)))
             (s-vector (loc vector) (list* (s-sym "&form" (loc vector)) (s-sym "&env" (loc vector))
                                           (items vector)))))
      (let ((arities
              (cond ((null rest) (compile-error form "defmacro needs a parameter vector"))
                    ((vector-form-p (first rest))
                     (list (apply #'s-list l (with-implicit-params (first rest)) (rest rest))))
                    (t (loop for clause in rest
                             collect (progn
                                       (unless (and (list-form-p clause) (items clause))
                                         (compile-error clause "expected an arity like ~
                                                                ([params] body...)"))
                                       (apply #'s-list (loc clause)
                                              (with-implicit-params (first (items clause)))
                                              (rest (items clause)))))))))
        (s-list l (s-sym "do" l)
                (apply #'s-list l (s-sym "def" l) name
                       (append (and doc (list doc))
                               (list (apply #'s-list l (s-sym "fn" l)
                                            (s-sym (plain-name name) (loc name)) arities))))
                (s-list l (core-sym "%set-macro!" l) (quoted name)))))))
