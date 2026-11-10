;;;; Analysis: syntax objects to Core IR (DESIGN §5.1, docs/CORE-IR.md).

(in-package #:skein.expander)

;;; ------------------------------------------------------------------------------------
;;; Entry points

(defun analyze (form env &optional tail)
  "Return the Core IR node for the syntax object FORM in ENV. TAIL is true when FORM is
in tail position of the innermost loop* or fn arity, where recur is allowed."
  (ecase (syntax-kind form)
    (:atom (analyze-atom form env))
    (:list (analyze-list form env tail))
    ((:vector :map :set) (analyze-collection form env))))

(defun core-var (name)
  (find-own-var +core+ name))

(defun analyze-collection (form env)
  "Analyze a vector, map or set literal. If every element is a constant the collection is
built now; otherwise it becomes a call to skein.core/vector, %map-literal or %set-literal."
  (let ((items (mapcar (lambda (x) (analyze x env)) (items form)))
        (var (core-var (ecase (syntax-kind form)
                         (:vector "vector") (:map "%map-literal") (:set "%set-literal")))))
    (if (every #'const-node-p items)
        (make-const-node
         :location (loc form)
         :value (handler-case (apply (var-value var) (mapcar #'const-node-value items))
                  (skein.runtime:skein-error (e)
                    (compile-error form "~A" (skein.runtime:skein-error-message e)))))
        (make-call-node :location (loc form)
                        :fn (make-var-ref-node :location (loc form) :var var)
                        :args items))))

(defun syntax-value (syntax)
  "Return the runtime value that SYNTAX denotes when quoted. Metadata is dropped."
  (let ((items (and (not (eq (syntax-kind syntax) :atom))
                    (mapcar #'syntax-value (items syntax)))))
    (ecase (syntax-kind syntax)
      (:atom (syntax-datum syntax))
      (:list (skein.runtime:list-from-cl items))
      (:vector (skein.runtime:vector-from-list items))
      (:map (skein.runtime:map-from-pairs items))
      (:set (skein.runtime:set-from-cl items)))))

(defun analyze-toplevel (form &optional (namespace *current-namespace*))
  "Return the Core IR node for the top-level syntax object FORM in NAMESPACE."
  (analyze form (make-env :namespace namespace)))

(defun toplevel-do-p (form)
  "Return true if FORM is a (do ...) form, whose subforms are treated as top-level forms."
  (equal (head-name form) "do"))

;;; ------------------------------------------------------------------------------------
;;; Symbols

(defun analyze-atom (form env)
  (if (sym-datum form)
      (analyze-symbol form env)
      (make-const-node :location (loc form) :value (syntax-datum form))))

(defun analyze-symbol (form env)
  (let* ((s (sym-datum form))
         (local (and (null (sym-namespace s)) (lookup-local env (sym-name s)))))
    (if local
        (make-local-ref-node :location (loc form) :local local)
        (make-var-ref-node :location (loc form) :var (resolve-global form env)))))

(defun resolve-global (form env &key (errorp t))
  "Return the var that the symbol FORM names in ENV's namespace. If there is none,
signal a COMPILE-ERROR, or return NIL when ERRORP is false."
  (let* ((s (sym-datum form))
         (ns (env-namespace env))
         (name (sym-name s))
         (ns-name (sym-namespace s)))
    (flet ((fail (control &rest args)
             (if errorp (apply #'compile-error form control args) (return-from resolve-global))))
      (if (null ns-name)
          (or (resolve-var ns name)
              (fail "unable to resolve symbol `~A`" name))
          (let ((target (or (find-alias ns ns-name) (find-namespace ns-name))))
            (unless target
              (fail "no namespace `~A` (is it required?)" ns-name))
            (let ((var (find-own-var target name)))
              (unless var
                (fail "no var `~A` in namespace `~A`" name ns-name))
              (when (and (var-private-p var) (not (eq target ns)))
                (fail "var ~A is private" (var-qualified-name var)))
              var))))))

;;; ------------------------------------------------------------------------------------
;;; Lists: special forms, macros and calls

(defparameter *special-forms* (make-hash-table :test 'equal)
  "Map from special form name to its analyzer, a function of (form env tail).")

(defmacro define-special-form (name (form env tail) &body body)
  `(setf (gethash ,name *special-forms*)
         (lambda (,form ,env ,tail)
           (declare (ignorable ,form ,env ,tail))
           ,@body)))

(defun special-form-p (name)
  "Return true if NAME (a string) is the name of a special form."
  (nth-value 1 (gethash name *special-forms*)))

(defun macro-var (form env)
  "If FORM is a call to a macro, return the macro's var."
  (when (and (list-form-p form) (items form))
    (let* ((head (first (items form)))
           (s (sym-datum head)))
      (when (and s
                 (not (and (null (sym-namespace s)) (special-form-p (sym-name s))))
                 (not (and (null (sym-namespace s)) (lookup-local env (sym-name s)))))
        (let ((var (resolve-global head env :errorp nil)))
          (and var (var-macro-p var) var))))))

(defun macroexpand-1 (form env)
  "Expand FORM once if it is a macro call. Returns the expansion and T, or FORM and NIL.
Built-in macros (written in CL) work on syntax; macros written in Skein see plain data."
  (let ((var (macro-var form env)))
    (cond ((null var) (values form nil))
          ((eq (var-macro-p var) :syntax) (values (funcall (var-value var) form env) t))
          (t (values (expand-data-macro var form env) t)))))

(defun macroexpand (form env)
  "Expand FORM until its head is no longer a macro. Returns the result and whether any
expansion happened."
  (loop with expanded-p = nil
        do (multiple-value-bind (new expanded) (macroexpand-1 form env)
             (unless expanded (return (values form expanded-p)))
             (setf form new expanded-p t))))

(defun analyze-list (form env tail)
  (let ((forms (items form)))
    (when (null forms)
      (return-from analyze-list
        (make-const-node :location (loc form) :value skein.runtime:+empty-list+)))
    (let* ((head (first forms))
           (name (plain-name head))
           (special (and name (gethash name *special-forms*))))
      (cond (special (funcall special form env tail))
            ((core-head-p form "syntax-quote")
             (analyze (expand-syntax-quote form env) env tail))
            ((unquote-form-p form)
             (compile-error form "~A is only allowed inside syntax-quote"
                            (if (core-head-p form "unquote") "~ (unquote)"
                                "~@ (unquote-splicing)")))
            ((macro-var form env)
             (analyze (macroexpand-1 form env) env tail))
            (t (make-call-node :location (loc form)
                               :fn (analyze head env)
                               :args (mapcar (lambda (a) (analyze a env)) (rest forms))))))))

;;; ------------------------------------------------------------------------------------
;;; Bodies

(defun declare-form-p (form env)
  (and (equal (head-name form) "declare")
       (not (lookup-local env "declare"))))

(defun analyze-seq (forms env tail location)
  "Analyze FORMS in order; the last one is in tail position if TAIL is true."
  (cond ((null forms) (make-const-node :location location :value nil))
        ((null (rest forms)) (analyze (first forms) env tail))
        (t (make-do-node :location location
                         :forms (loop for (f . more) on forms
                                      collect (analyze f env (and tail (null more))))))))

(defparameter *policy-qualities* '("speed" "safety" "debug" "space")
  "The optimization qualities of DESIGN §12.3.")

(defun parse-declaration (spec env)
  "Apply one declaration SPEC from (declare ...). Type declarations set the type of
locals; optimize declarations are returned as a list of (quality . level)."
  (let* ((parts (and (list-form-p spec) (items spec)))
         (head (and parts (plain-name (first parts)))))
    (cond ((equal head "type")
           (unless (>= (length parts) 3)
             (compile-error spec "(type T name...) needs a type and at least one name"))
           (let ((type (syntax-value (second parts))))
             (dolist (name-form (cddr parts))
               (let* ((name (binding-name name-form "a declared name"))
                      (local (or (lookup-local env name)
                                 (compile-error name-form "no local named ~A to declare" name))))
                 (setf (local-type local) type))))
           '())
          ((equal head "optimize")
           (loop for q in (rest parts)
                 collect (multiple-value-bind (quality level)
                             (if (list-form-p q)
                                 (values (plain-name (first (items q)))
                                         (syntax-datum (second (items q))))
                                 (values (plain-name q) 3))
                           (unless (and (member quality *policy-qualities* :test #'equal)
                                        (typep level '(integer 0 3)))
                             (compile-error q "optimize takes qualities speed, safety, debug and ~
                                               space with levels 0 to 3, not ~A"
                                            (syntax-to-string q)))
                           (cons quality level))))
          (t (compile-error spec "unknown declaration ~A; expected (type ...) or (optimize ...)"
                            (syntax-to-string spec))))))

(defun analyze-body (forms env tail location)
  "Like ANALYZE-SEQ, but first apply leading (declare ...) forms (DESIGN §12.2). An
optimize declaration wraps the body in a locally-node."
  (let ((policy '()))
    (loop while (and forms (declare-form-p (first forms) env))
          do (dolist (spec (rest (items (pop forms))))
               (setf policy (append policy (parse-declaration spec env)))))
    (let ((body (analyze-seq forms env tail location)))
      (if policy
          (make-locally-node :location location :policy policy :body body)
          body))))

(defun check-arg-count (form min &optional (max min))
  "Check that the special form FORM has between MIN and MAX arguments (MAX NIL: no limit)."
  (let ((n (1- (length (items form)))))
    (unless (and (>= n min) (or (null max) (<= n max)))
      (compile-error form "~A expects ~A, got ~D"
                     (plain-name (first (items form)))
                     (cond ((null max) (format nil "at least ~D argument~:P" min))
                           ((= min max) (format nil "~D argument~:P" min))
                           (t (format nil "~D to ~D arguments" min max)))
                     n))))

(defun binding-pairs (form vector what)
  "Check that VECTOR is a binding vector with an even number of forms; return the pairs."
  (declare (ignore form))
  (unless (vector-form-p vector)
    (compile-error vector "~A needs a binding vector, not ~A" what (syntax-to-string vector)))
  (let ((forms (items vector)))
    (when (oddp (length forms))
      (compile-error vector "~A binding vector needs an even number of forms" what))
    (loop for (name init) on forms by #'cddr collect (cons name init))))

;;; ------------------------------------------------------------------------------------
;;; Special forms

(define-special-form "quote" (form env tail)
  (check-arg-count form 1)
  (make-const-node :location (loc form) :value (syntax-value (second (items form)))))

(define-special-form "if" (form env tail)
  (check-arg-count form 2 3)
  (destructuring-bind (test then &optional else) (rest (items form))
    (make-if-node :location (loc form)
                  :test (analyze test env)
                  :then (analyze then env tail)
                  :else (if else
                            (analyze else env tail)
                            (make-const-node :location (loc form) :value nil)))))

(define-special-form "do" (form env tail)
  (analyze-seq (rest (items form)) env tail (loc form)))

(define-special-form "def" (form env tail)
  (check-arg-count form 1 3)
  (destructuring-bind (name-form &optional (doc nil init-p) (init nil three-p))
      (rest (items form))
    (let* ((s (or (sym-datum name-form)
                  (compile-error name-form "def needs a symbol, not ~A"
                                 (syntax-to-string name-form))))
           (ns (env-namespace env)))
      (when (and (sym-namespace s) (string/= (sym-namespace s) (namespace-name ns)))
        (compile-error name-form "cannot def ~A outside its namespace ~A"
                       (syntax-to-string name-form) (namespace-name ns)))
      (when three-p
        (unless (and (eq (syntax-kind doc) :atom) (stringp (syntax-datum doc)))
          (compile-error doc "def with three arguments needs a docstring second")))
      (let ((var (intern-var ns (sym-name s)))
            (init (cond (three-p init) (init-p doc))))
        (setf (var-macro-p var) nil
              (var-dynamic-p var) (meta-flag-p name-form "dynamic")
              (var-private-p var) (meta-flag-p name-form "private"))
        (setf (skein.runtime:var-doc var)
              (if three-p (syntax-datum doc) (meta-string name-form "doc")))
        (make-def-node :location (loc form) :var var
                       :init (and init (analyze init env)))))))

;;; fn

(defun parse-params (vector)
  "Parse a parameter vector into (values param-locals rest-local patterns). A parameter
that is a destructuring pattern gets a fresh local; PATTERNS lists (pattern . local)."
  (unless (vector-form-p vector)
    (compile-error vector "fn parameters must be a vector, not ~A" (syntax-to-string vector)))
  (let ((params '()) (rest nil) (patterns '()) (forms (items vector)))
    (flet ((param (p what)
             (if (member (syntax-kind p) '(:vector :map))
                 (let ((local (make-local (skein.runtime:gensym-name "p__"))))
                   (push (cons p local) patterns)
                   local)
                 (make-binding-local p what))))
      (loop while forms
            do (let ((p (pop forms)))
                 (cond ((equal (plain-name p) "&")
                        (unless (= (length forms) 1)
                          (compile-error p "& must be followed by exactly one parameter"))
                        (setf rest (param (pop forms) "a rest parameter")))
                       (t (push (param p "a parameter") params))))))
    (values (nreverse params) rest (nreverse patterns))))

(defun destructuring-body (patterns body location)
  "Wrap BODY so that each (pattern . local) in PATTERNS is destructured with let."
  (if (null patterns)
      body
      (list (apply #'s-list location (core-sym "let" location)
                   (s-vector location (loop for (pattern . local) in patterns
                                            append (list pattern
                                                         (s-sym (local-name local) location))))
                   body))))

(defun analyze-arity (vector body env location)
  (multiple-value-bind (params rest patterns) (parse-params vector)
    (setf body (destructuring-body patterns body location))
    (let* ((arity (make-arity :location location :params params :rest rest
                              :return-type (type-hint vector)))
           (inner (with-locals env (append params (and rest (list rest))))))
      (setf (env-recur inner) arity
            (env-recur-count inner) (+ (length params) (if rest 1 0))
            (arity-body arity) (analyze-body body inner t location))
      arity)))

(defun check-arities (form arities)
  (let ((variadic (remove-if-not #'arity-rest arities))
        (fixed (remove-if #'arity-rest arities)))
    (when (> (length variadic) 1)
      (compile-error form "a fn can have only one variadic arity"))
    (let ((counts (mapcar (lambda (a) (length (arity-params a))) fixed)))
      (when (/= (length counts) (length (remove-duplicates counts)))
        (compile-error form "a fn cannot have two arities with the same number of parameters"))
      (when (and variadic counts
                 (> (reduce #'max counts) (length (arity-params (first variadic)))))
        (compile-error form "a fixed arity cannot have more parameters than the variadic one")))))

(defun analyze-fn-tail (form parts env name self)
  "Analyze the part of a fn form after its name: [params] body... or ([params] body...)+."
  (let* ((inner (if self (with-locals env (list self)) env))
         (arities
           (cond ((null parts) (compile-error form "fn needs a parameter vector"))
                 ((vector-form-p (first parts))
                  (list (analyze-arity (first parts) (rest parts) inner (loc form))))
                 (t (loop for clause in parts
                          collect (progn
                                    (unless (and (list-form-p clause) (items clause))
                                      (compile-error clause "expected an arity like ~
                                                             ([params] body...), not ~A"
                                                     (syntax-to-string clause)))
                                    (analyze-arity (first (items clause))
                                                   (rest (items clause))
                                                   inner (loc clause))))))))
    (check-arities form arities)
    (make-fn-node :location (loc form) :name name :self self :arities arities)))

(define-special-form "fn" (form env tail)
  (let* ((parts (rest (items form)))
         (name (and parts (plain-name (first parts))))
         (self (and name (make-local name))))
    (analyze-fn-tail form (if name (rest parts) parts) env (or name "fn") self)))

;;; let*, letfn*, loop*

(defun analyze-sequential-bindings (form env what)
  "Analyze the binding vector of FORM. Returns (values bindings new-env)."
  (let ((bindings '()))
    (dolist (pair (binding-pairs form (second (items form)) what))
      (let ((init (analyze (cdr pair) env))
            (local (make-binding-local (car pair) "a binding name")))
        (push (cons local init) bindings)
        (setf env (with-locals env (list local)))))
    (values (nreverse bindings) env)))

(define-special-form "let*" (form env tail)
  (check-arg-count form 1 nil)
  (multiple-value-bind (bindings inner) (analyze-sequential-bindings form env "let*")
    (make-let-node :location (loc form) :bindings bindings
                   :body (analyze-body (cddr (items form)) inner tail (loc form)))))

(define-special-form "loop*" (form env tail)
  (check-arg-count form 1 nil)
  (multiple-value-bind (bindings inner) (analyze-sequential-bindings form env "loop*")
    ;; Copy: with no bindings, INNER is ENV itself, whose recur target must not change.
    (let ((node (make-loop-node :location (loc form) :bindings bindings))
          (inner (copy-env inner)))
      (setf (env-recur inner) node
            (env-recur-count inner) (length bindings)
            (loop-node-body node) (analyze-body (cddr (items form)) inner t (loc form)))
      node)))

(define-special-form "letfn*" (form env tail)
  (check-arg-count form 1 nil)
  (let ((vector (second (items form))))
    (unless (vector-form-p vector)
      (compile-error vector "letfn* needs a vector of function definitions"))
    (let* ((clauses (items vector))
           (locals (loop for c in clauses
                         collect (progn
                                   (unless (and (list-form-p c) (items c))
                                     (compile-error c "letfn* expects (name [params] body...), ~
                                                       not ~A"
                                                    (syntax-to-string c)))
                                   (make-binding-local (first (items c)) "a function name"))))
           (inner (with-locals env locals)))
      (make-letfn-node
       :location (loc form)
       :bindings (loop for c in clauses
                       for l in locals
                       collect (cons l (analyze-fn-tail c (rest (items c)) inner
                                                        (local-name l) nil)))
       :body (analyze-body (cddr (items form)) inner tail (loc form))))))

(define-special-form "recur" (form env tail)
  (let ((target (env-recur env))
        (args (rest (items form))))
    (cond ((null target) (compile-error form "recur is only allowed inside loop* or fn"))
          ((not tail) (compile-error form "recur must be in tail position")))
    (unless (= (length args) (env-recur-count env))
      (compile-error form "recur expects ~D argument~:P, got ~D"
                     (env-recur-count env) (length args)))
    (etypecase target
      (loop-node (setf (loop-node-recur-p target) t))
      (arity (setf (arity-recur-p target) t)))
    (make-recur-node :location (loc form) :target target
                     :args (mapcar (lambda (a) (analyze a env)) args))))

;;; set!

(define-special-form "set!" (form env tail)
  (check-arg-count form 2)
  (destructuring-bind (place value) (rest (items form))
    (let* ((name (plain-name place))
           (local (and name (lookup-local env name))))
      (cond (local
             (unless (local-mutable-p local)
               (compile-error place "cannot set! the immutable local ~A; declare it ^:mutable"
                              name))
             (make-set-node :location (loc form) :local local :value (analyze value env)))
            ((sym-datum place)
             ;; (set! *x* v) changes the innermost binding of a ^:dynamic var (D-076).
             (let ((var (resolve-global place env)))
               (unless (var-dynamic-p var)
                 (compile-error place "cannot set! ~A: it isn't ^:dynamic, and only ~
                                       dynamic vars can be set!"
                                (var-qualified-name var)))
               (make-call-node :location (loc form)
                               :fn (make-var-ref-node :location (loc form)
                                                      :var (core-var "%set-dynamic!"))
                               :args (list (make-const-node
                                            :location (loc place)
                                            :value (intern-sym
                                                    (var-name var)
                                                    (namespace-name (var-namespace var))))
                                           (analyze value env)))))
            ((and (list-form-p place) (= (length (items place)) 2)
                  (eq (syntax-kind (first (items place))) :atom)
                  (kw-p (syntax-datum (first (items place)))))
             ;; (set! (:slot obj) value) sets an :unsynchronized cell slot (DESIGN §8.2).
             (make-call-node :location (loc form)
                             :fn (make-var-ref-node :location (loc form)
                                                    :var (core-var "%set-slot!"))
                             :args (list (analyze (second (items place)) env)
                                         (analyze (first (items place)) env)
                                         (analyze value env))))
            (t (compile-error place "set! needs a ^:mutable local or a slot like (:name obj), ~
                                     not ~A"
                              (syntax-to-string place)))))))

;;; unwind-protect, block*, return-from*

(define-special-form "unwind-protect" (form env tail)
  (check-arg-count form 1 nil)
  (make-unwind-protect-node
   :location (loc form)
   :body (analyze (second (items form)) env)
   :cleanup (analyze-seq (cddr (items form)) env nil (loc form))))

(define-special-form "block*" (form env tail)
  (check-arg-count form 1 nil)
  (let* ((tag (make-block-tag (binding-name (second (items form)) "a block name")))
         (inner (copy-env env)))
    (push (cons (block-tag-name tag) tag) (env-blocks inner))
    (make-block-node :location (loc form) :tag tag
                     :body (analyze-seq (cddr (items form)) inner tail (loc form)))))

(define-special-form "return-from*" (form env tail)
  (check-arg-count form 1 2)
  (destructuring-bind (tag-form &optional value) (rest (items form))
    (let* ((name (binding-name tag-form "a block name"))
           (tag (or (cdr (assoc name (env-blocks env) :test #'string=))
                    (compile-error tag-form "no enclosing block* named ~A" name))))
      (make-return-from-node :location (loc form) :tag tag
                             :value (if value
                                        (analyze value env)
                                        (make-const-node :location (loc form) :value nil))))))

;;; values, let-values*, the

(define-special-form "values" (form env tail)
  (make-values-node :location (loc form)
                    :args (mapcar (lambda (a) (analyze a env)) (rest (items form)))))

(define-special-form "let-values*" (form env tail)
  (check-arg-count form 1 nil)
  (let ((bindings '()) (inner env))
    (dolist (pair (binding-pairs form (second (items form)) "let-values*"))
      (unless (vector-form-p (car pair))
        (compile-error (car pair) "let-values* binds a vector of names, like [a b]"))
      (let ((init (analyze (cdr pair) inner))
            (locals (mapcar (lambda (n) (make-binding-local n "a binding name"))
                            (items (car pair)))))
        (push (cons locals init) bindings)
        (setf inner (with-locals inner locals))))
    (make-let-values-node :location (loc form) :bindings (nreverse bindings)
                          :body (analyze-body (cddr (items form)) inner tail (loc form)))))

(define-special-form "the" (form env tail)
  (check-arg-count form 2)
  (make-the-node :location (loc form) :type (syntax-value (second (items form)))
                 :expr (analyze (third (items form)) env tail)))

;;; Forms that are reserved for later milestones

(define-special-form "declare" (form env tail)
  (compile-error form "declare is only allowed at the start of a body"))

;;; Conditions (DESIGN §10). The macros in lib/skein/core.skn build on these.

(define-special-form "throw-condition" (form env tail)
  (check-arg-count form 1)
  (make-throw-condition-node :location (loc form)
                             :condition (analyze (second (items form)) env)))

(define-special-form "handler-bind*" (form env tail)
  ;; (handler-bind* [type-expr handler-expr ...] body...): handlers run without unwinding.
  (check-arg-count form 1 nil)
  (make-handler-bind-node
   :location (loc form)
   :bindings (loop for (type . handler) in (binding-pairs form (second (items form))
                                                          "handler-bind*")
                   collect (cons (analyze type env) (analyze handler env)))
   :body (analyze-seq (cddr (items form)) env nil (loc form))))

(define-special-form "restart-bind*" (form env tail)
  ;; (restart-bind* [name fn-expr report-expr ...] body...): NAME is an unevaluated symbol.
  (check-arg-count form 1 nil)
  (let ((vector (second (items form))))
    (unless (and (vector-form-p vector) (zerop (mod (length (items vector)) 3)))
      (compile-error vector "restart-bind* needs a vector of name, function and report triples"))
    (make-restart-bind-node
     :location (loc form)
     :bindings (loop for (name fn report) on (items vector) by #'cdddr
                     collect (list (or (sym-datum name)
                                       (compile-error name "a restart name must be a symbol"))
                                   (analyze fn env)
                                   (analyze report env)))
     :body (analyze-seq (cddr (items form)) env nil (loc form)))))

(define-special-form "%ffi-call" (form env tail)
  (compile-error form "%ffi-call is not supported until the FFI arrives (M0.10)"))
