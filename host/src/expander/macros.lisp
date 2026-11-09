;;;; Built-in macros, written in CL until M0.5 moves them into lib/skein/core.skn.
;;;; Each is a skein.core var flagged as a macro whose value is a CL function of
;;;; (form env) that returns a syntax object.

(in-package #:skein.expander)

(defmacro define-builtin-macro (name (form env) &body body)
  `(let ((var (intern-var +core+ ,name)))
     (def-var var (sb-int:named-lambda ,(format nil "skein.core/~A" name) (,form ,env)
                    (declare (ignorable ,env))
                    ,@body))
     (setf (var-macro-p var) t)))

(defun core-sym (name location)
  "A symbol naming a skein.core var, qualified so user definitions cannot shadow it."
  (s-sym name location "skein.core"))

(defun macro-args (form) (rest (items form)))

;;; ns

(defun quoted (syntax)
  (s-list (loc syntax) (s-sym "quote" (loc syntax)) syntax))

(defun require-calls (spec)
  "Return the calls that load one :require spec: a.b or [a.b :as c :refer [x y]]."
  (let ((l (loc spec)))
    (cond ((sym-datum spec)
           (list (s-list l (core-sym "%require" l) (quoted spec) (s-atom nil l))))
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
               (cons (s-list l (core-sym "%require" l) (quoted name)
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
                            ;; Phase tracking for :require-for-syntax arrives in M0.5;
                            ;; until then it loads like :require.
                            (unless (member k '("require" "require-for-syntax") :test #'equal)
                              (compile-error clause "unknown ns clause ~A; expected ~
                                                     (:require ...)"
                                             (syntax-to-string clause)))
                            (loop for spec in (rest (items clause))
                                  append (require-calls spec))))))))

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

;;; let, loop. Destructuring arrives in M0.5; until then they are let* and loop*.

(define-builtin-macro "let" (form env)
  (apply #'s-list (loc form) (s-sym "let*" (loc form)) (macro-args form)))

(define-builtin-macro "loop" (form env)
  (apply #'s-list (loc form) (s-sym "loop*" (loc form)) (macro-args form)))

;;; lazy-seq

(define-builtin-macro "lazy-seq" (form env)
  (let ((l (loc form)))
    (s-list l (core-sym "%lazy-seq" l)
            (apply #'s-list l (s-sym "fn" l) (s-vector l '()) (macro-args form)))))

;;; Conditionals

(define-builtin-macro "when" (form env)
  (let ((args (macro-args form)) (l (loc form)))
    (unless args (compile-error form "when needs a test"))
    (s-list l (s-sym "if" l) (first args) (apply #'s-list l (s-sym "do" l) (rest args)))))

(define-builtin-macro "when-not" (form env)
  (let ((args (macro-args form)) (l (loc form)))
    (unless args (compile-error form "when-not needs a test"))
    (s-list l (s-sym "if" l) (first args) (s-atom nil l)
            (apply #'s-list l (s-sym "do" l) (rest args)))))

(define-builtin-macro "cond" (form env)
  (let ((args (macro-args form)) (l (loc form)))
    (when (oddp (length args))
      (compile-error form "cond needs an even number of forms"))
    (if (null args)
        (s-atom nil l)
        (s-list l (s-sym "if" l) (first args) (second args)
                (apply #'s-list l (core-sym "cond" l) (cddr args))))))

(define-builtin-macro "and" (form env)
  (let ((args (macro-args form)) (l (loc form)))
    (cond ((null args) (s-atom t l))
          ((null (rest args)) (first args))
          (t (let ((g (s-gensym "and" l)))
               (s-list l (s-sym "let*" l) (s-vector l (list g (first args)))
                       (s-list l (s-sym "if" l) g
                               (apply #'s-list l (core-sym "and" l) (rest args))
                               g)))))))

(define-builtin-macro "or" (form env)
  (let ((args (macro-args form)) (l (loc form)))
    (cond ((null args) (s-atom nil l))
          ((null (rest args)) (first args))
          (t (let ((g (s-gensym "or" l)))
               (s-list l (s-sym "let*" l) (s-vector l (list g (first args)))
                       (s-list l (s-sym "if" l) g g
                               (apply #'s-list l (core-sym "or" l) (rest args)))))))))
