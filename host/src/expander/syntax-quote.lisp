;;;; Syntax-quote (DESIGN §11.1): `form builds data at run time, with symbols resolved to
;;;; fully qualified names in the namespace where the syntax-quote appears.

(in-package #:skein.expander)

(defvar *auto-gensyms* nil
  "Within one syntax-quote, a table from x# names to their generated names.")

(defun core-head-p (syntax name)
  "Return true if SYNTAX is a list whose head is the symbol skein.core/NAME."
  (and (list-form-p syntax) (items syntax)
       (let ((s (sym-datum (first (items syntax)))))
         (and s (equal (sym-namespace s) "skein.core") (string= (sym-name s) name)))))

(defun unquote-form-p (syntax)
  (or (core-head-p syntax "unquote") (core-head-p syntax "unquote-splicing")))

(defun contains-unquote-p (syntax)
  (or (unquote-form-p syntax)
      (core-head-p syntax "syntax-quote")
      (and (not (eq (syntax-kind syntax) :atom))
           (some #'contains-unquote-p (items syntax)))))

(defun unquoted-arg (syntax)
  (unless (= (length (items syntax)) 2)
    (compile-error syntax "~A takes exactly one form"
                   (if (core-head-p syntax "unquote") "~" "~@")))
  (second (items syntax)))

(defun resolve-quoted-symbol (syntax env)
  "Return the symbol that SYNTAX (a symbol) stands for inside syntax-quote."
  (let* ((s (sym-datum syntax))
         (name (sym-name s))
         (ns-name (sym-namespace s))
         (ns (env-namespace env)))
    (cond ((and (null ns-name) (> (length name) 1) (char= (char name (1- (length name))) #\#))
           (or (gethash name *auto-gensyms*)
               (setf (gethash name *auto-gensyms*)
                     (intern-sym (skein.runtime:gensym-name
                                  (format nil "~A__" (subseq name 0 (1- (length name)))))))))
          ;; Special forms, &, and try's catch and finally stay unqualified, as in Clojure.
          ((and (null ns-name) (or (special-form-p name)
                                   (member name '("&" "catch" "finally") :test #'string=)))
           s)
          (ns-name (let ((target (find-alias ns ns-name)))
                     (if target (intern-sym name (namespace-name target)) s)))
          (t (let ((var (resolve-var ns name)))
               (if var
                   (intern-sym (var-name var) (namespace-name (var-namespace var)))
                   (intern-sym name (namespace-name ns))))))))

(defun resolve-quoted (syntax env)
  "Return SYNTAX with every symbol resolved as syntax-quote does."
  (if (eq (syntax-kind syntax) :atom)
      (if (sym-datum syntax)
          (make-syntax :kind :atom :datum (resolve-quoted-symbol syntax env)
                       :location (loc syntax))
          syntax)
      (make-syntax :kind (syntax-kind syntax)
                   :datum (mapcar (lambda (x) (resolve-quoted x env)) (items syntax))
                   :location (loc syntax))))

(defun expand-syntax-quote (form env)
  "Return the code that FORM, a (skein.core/syntax-quote x) form, stands for."
  (unless (= (length (items form)) 2)
    (compile-error form "syntax-quote takes exactly one form"))
  (let ((*auto-gensyms* (make-hash-table :test 'equal)))
    (sq (second (items form)) env)))

(defun sq (x env)
  (let ((l (loc x)))
    (flet ((core (name) (core-sym name l))
           (parts ()
             (loop for item in (items x)
                   collect (if (core-head-p item "unquote-splicing")
                               (unquoted-arg item)
                               (s-list l (core-sym "list" l) (sq item env))))))
      (cond ((core-head-p x "unquote") (unquoted-arg x))
            ((core-head-p x "unquote-splicing")
             (compile-error x "~~@ is only allowed directly inside a list, vector, map or set"))
            ((core-head-p x "syntax-quote") (sq (expand-syntax-quote x env) env))
            ((not (contains-unquote-p x))
             (s-list l (s-sym "quote" l) (resolve-quoted x env)))
            (t (let ((concat (apply #'s-list l (core "concat") (parts))))
                 (ecase (syntax-kind x)
                   (:list (s-list l (core "seq") concat))
                   (:vector (s-list l (core "apply") (core "vector") concat))
                   (:map (s-list l (core "apply") (core "hash-map") concat))
                   (:set (s-list l (core "apply") (core "hash-set") concat)))))))))
