;;;; Declared types in the C backend (DESIGN §12, M1.8 step 5, D-056). Locals declared
;;;; or inferred to be f64, f32 or fixnum become C double, float and int64_t variables;
;;;; arithmetic, comparisons, sqrt and the access functions of typed arrays on them
;;;; compile to plain C. A value is boxed only where it reaches code that doesn't know
;;;; its type. Declared types are checked where values enter typed code (parameters,
;;;; stores to declared locals, the), as Phase 0 does at safety 1 and above.
;;;;
;;;; Static types: :f64 :f32 :int (any int64_t, fixnum or not), :bool (a C condition),
;;;; (:array . element) for a primitive array of :f64, :f32 or :int (fixnum), or NIL for
;;;; a boxed value of unknown type.

(in-package #:skein.backend.c)

(defvar *safety* 1
  "The safety level of the code being emitted: 0 drops bounds and overflow checks.")

(defun scalar-type-p (type) (member type '(:f64 :f32 :int :bool)))
(defun numeric-type-p (type) (member type '(:f64 :f32 :int)))

(defun c-type (type)
  "The C type that holds a value of TYPE."
  (case type (:f64 "double") (:f32 "float") (:int "int64_t") (:bool "int") (t "sk_value")))

(defun decl-type (type)
  "The C type of a local of TYPE in the function being emitted (volatile if it calls
setjmp)."
  (format nil "~:[~;volatile ~]~A" (ctx-volatile *ctx*) (c-type type)))

(defun declared-type (data)
  "The static type for the Skein type DATA (as from ^type or declare), or NIL."
  (cond ((and (sym-p data) (null (sym-namespace data)))
         (let ((name (sym-name data)))
           (cond ((string= name "f64") :f64)
                 ((string= name "f32") :f32)
                 ((string= name "fixnum") :int))))
        ((skein.runtime::plist-p data)
         (let ((items (skein.runtime:seq-to-cl data)))
           (and (sym-p (first items)) (string= (sym-name (first items)) "array")
                (let ((element (declared-type (second items))))
                  (and element (cons :array element))))))))

(defun declared-fixnum-p (local)
  (let ((data (local-type local)))
    (and (sym-p data) (null (sym-namespace data)) (string= (sym-name data) "fixnum"))))

(defun local-static-type (local)
  (gethash local (ctx-types *ctx*)))

;;; Inference: the type of each local, before the function's code is emitted.

(defun infer-locals (node)
  "Record the static types of the locals that NODE binds (outside nested functions): a
declared type, or for an immutable let local, the type of its init."
  (labels ((note (local type) (when type (setf (gethash local (ctx-types *ctx*)) type)))
           (walk (n)
             (typecase n
               (let-node
                (loop for (l . init) in (let-node-bindings n)
                      do (walk init)
                         (note l (or (declared-type (local-type l))
                                     (and (not (local-mutable-p l))
                                          (let ((ty (node-type init)))
                                            (and (or (numeric-type-p ty) (consp ty))
                                                 (not (overflowing-p init))
                                                 ty))))))
                (walk (let-node-body n)))
               (loop-node
                (loop for (l . init) in (loop-node-bindings n)
                      do (walk init)
                         (note l (declared-type (local-type l))))
                (walk (loop-node-body n)))
               (fn-node nil)
               (t (mapc #'walk (node-children n))))))
    (walk node)))

(defun note-parameter-types (arities)
  (dolist (a arities)
    (dolist (p (arity-params a))
      (let ((type (declared-type (local-type p))))
        (when type (setf (gethash p (ctx-types *ctx*)) type))))))

(defun overflowing-p (node)
  "True if NODE is integer arithmetic, whose result may not fit in an int64_t: Skein
integers become bignums, so such a result is only unboxed where a typed integer is
required (a fixnum local, an index, a comparison), never into an inferred local or a
boxed value."
  (and (eq (node-type node) :int)
       (call-node-p node)
       (member (primitive-name node) '("+" "-" "*" "inc" "dec") :test #'string=)))

(defun join-types (a b)
  (cond ((eq a :recur) b)
        ((eq b :recur) a)
        ((equal a b) a)))

(defun primitive-name (call)
  (let ((fn (call-node-fn call)))
    (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
         (var-name (var-ref-node-var fn)))))

(defun contagion (types)
  (cond ((member :f64 types) :f64)
        ((member :f32 types) :f32)
        (t :int)))

(defun node-type (node)
  "The static type of NODE's value, :RECUR if it always jumps, or NIL."
  (typecase node
    (const-node (let ((v (const-node-value node)))
                  (cond ((and (integerp v) (<= (- (expt 2 61)) v (1- (expt 2 61)))) :int)
                        ((typep v 'double-float) :f64)
                        ((typep v 'single-float) :f32))))
    (local-ref-node (local-static-type (local-ref-node-local node)))
    (the-node (or (declared-type (the-node-type node)) (node-type (the-node-expr node))))
    (locally-node (node-type (locally-node-body node)))
    (let-node (node-type (let-node-body node)))
    (do-node (node-type (car (last (do-node-forms node)))))
    (if-node (join-types (node-type (if-node-then node)) (node-type (if-node-else node))))
    (loop-node (let ((ty (node-type (loop-node-body node)))) (if (eq ty :recur) nil ty)))
    (recur-node :recur)
    (call-node (primitive-type node))))

(defun primitive-type (call)
  "The static type of a call to a skein.core primitive with typed arguments, or NIL."
  (let* ((name (primitive-name call))
         (args (call-node-args call))
         (types (mapcar #'node-type args))
         (n (length args)))
    (flet ((is (&rest names) (member name names :test #'string=))
           (numeric () (every #'numeric-type-p types)))
      (when name
        (cond ((is "+" "*" "-") (and (>= n 1) (numeric) (contagion types)))
              ((is "/") (and (= n 2) (numeric)
                             (if (every (lambda (ty) (eq ty :int)) types) :f64 (contagion types))))
              ((is "inc" "dec") (and (= n 1) (numeric) (first types)))
              ((is "<" ">" "<=" ">=" "==") (and (>= n 2) (numeric) :bool))
              ((is "zero?" "pos?" "neg?") (and (= n 1) (numeric) :bool))
              ((is "not") (and (= n 1) (eq (first types) :bool) :bool))
              ((is "sqrt") (and (= n 1) (case (first types) (:f32 :f32) ((:f64 :int) :f64))))
              ((is "aget") (and (= n 2) (consp (first types)) (eq (second types) :int)
                                (cdr (first types))))
              ((is "aset!") (and (= n 3) (consp (first types)) (eq (second types) :int)
                                 (eq (third types) (cdr (first types)))
                                 (third types)))
              ((is "count") (and (= n 1) (consp (first types)) :int)))))))

;;; Converting between boxed values and typed C values

(defun location-literal (node) (c-string-literal (location-string node)))

(defun box (expr type)
  "EXPR, a C value of TYPE, as an sk_value."
  (case type
    (:f64 (temp (format nil "sk_f64(~A)" expr)))
    (:f32 (format nil "sk_from_f32(~A)" expr))
    (:int (format nil "sk_from_i64(~A)" expr))
    (:bool (format nil "SK_BOOL(~A)" expr))
    (t expr)))

(defun unbox (expr type node)
  "EXPR, an sk_value, as a C value of TYPE, checking that it has that type."
  (cond ((null type) expr)
        ((consp type) (format nil "sk_check_array(~A, ~D, ~A)" expr
                              (ecase (cdr type) (:f64 9) (:f32 8) (:int 10))
                              (location-literal node)))
        (t (ecase type
             (:f64 (format nil "sk_to_f64(~A, ~A)" expr (location-literal node)))
             (:f32 (format nil "sk_to_f32(~A, ~A)" expr (location-literal node)))
             (:int (format nil "sk_to_fixnum(~A, ~A)" expr (location-literal node)))
             (:bool (format nil "SK_TRUTHY(~A)" expr))))))

(defun convert (expr have want node strict)
  "EXPR, a C value of static type HAVE, as WANT. Arithmetic converts numbers by
contagion; with STRICT (a declared type), a different type is a type error, checked by
boxing and unboxing as Phase 0 checks it at run time."
  (cond ((equal have want) expr)
        ((null want) (box expr have))
        ((and (not strict) (eq want :f64) (member have '(:int :f32)))
         (format nil "((double)(~A))" expr))
        ((and (not strict) (eq want :f32) (eq have :int))
         (format nil "((float)(~A))" expr))
        ((eq want :bool) (format nil "((void)(~A), 1)" expr))
        (t (unbox (box expr have) want node))))

(defun emit-as (node want &key strict)
  "Emit NODE; return a C expression for its value as WANT (a static type, NIL for an
sk_value, or :VOID when the value is not needed), or :RECUR if it jumped."
  (let ((have (node-type node)))
    (cond ((eq want :void)
           ;; Typed expressions can have effects (aset!), so they become statements.
           (if (or (scalar-type-p have) (consp have))
               (let ((expr (emit-typed node have)))
                 (when (stringp expr) (stmt "(void)~A;" expr)))
               (emit node))
           nil)
          ((and (or (scalar-type-p have) (consp have))
                ;; Integer arithmetic going into a boxed value may need a bignum.
                (not (and (null want) (overflowing-p node))))
           (let ((expr (emit-typed node have)))
             (if (eq expr :recur) :recur (convert expr have want node strict))))
          (t (let ((expr (emit node)))
               (if (eq expr :recur) :recur (unbox expr want node)))))))

(defun typed-temp (expr type)
  (let ((name (fresh "v")))
    (stmt "~A ~A = ~A;" (c-type type) name expr)
    name))

(defun typed-literal (value type)
  (ecase type
    (:int (format nil "INT64_C(~D)" value))
    (:f64 (format nil "sk_bits_f64(UINT64_C(0x~16,'0X))"
                  (ldb (byte 64 0) (sb-kernel:double-float-bits value))))
    (:f32 (format nil "sk_bits_f32(UINT32_C(0x~8,'0X))"
                  (ldb (byte 32 0) (sb-kernel:single-float-bits value))))))

(defun emit-typed (node type)
  "Emit NODE, whose static type is TYPE; return a C expression of TYPE's C type."
  (let ((*tail-mv* nil))
    (etypecase node
      (const-node (typed-literal (const-node-value node) type))
      (local-ref-node (gethash (local-ref-node-local node) (ctx-locals *ctx*)))
      (the-node (emit-as (the-node-expr node) type :strict t))
      (locally-node (let ((*safety* (policy-safety (locally-node-policy node))))
                      (emit-typed (locally-node-body node) type)))
      (let-node (emit-let (let-node-bindings node))
       (emit-typed (let-node-body node) type))
      (do-node (loop for (f . more) on (do-node-forms node)
                     do (if more (emit-as f :void) (return (emit-typed f type)))))
      (if-node (emit-if node type))
      (loop-node (emit-loop node type))
      (call-node (emit-typed-primitive node type)))))

(defun array-count-var (node)
  "The C variable holding the length of the typed array local that NODE reads, if any."
  (and (local-ref-node-p node)
       (gethash (local-ref-node-local node) (ctx-array-counts *ctx*))))

(defun note-array-count (local name)
  "After LOCAL (a typed array) is bound to the C variable NAME, read its length once."
  (when (consp (local-static-type local))
    (let ((count (format nil "~A_count" name)))
      (stmt "const int64_t ~A = sk_prim_count(~A);" count name)
      (setf (gethash local (ctx-array-counts *ctx*)) count))))

(defun policy-safety (policy)
  (let ((entry (assoc "safety" policy :test #'equal)))
    (if entry (cdr entry) *safety*)))

(defun local-store (local value-node)
  "A C expression for VALUE-NODE's value as stored in LOCAL: of LOCAL's static type,
checked against its declared type."
  (let* ((type (local-static-type local))
         (declared (declared-type (local-type local)))
         (expr (emit-as value-node type :strict (and declared t))))
    (if (and (not (eq expr :recur)) (eq type :int) (declared-fixnum-p local) (> *safety* 0)
             (not (eq (node-type value-node) :recur)))
        (format nil "sk_fixnum_range(~A, ~A)" expr (location-literal value-node))
        expr)))

(defun emit-typed-primitive (node type)
  "A call to a skein.core primitive whose arguments have static types (primitive-type)."
  (let* ((name (primitive-name node))
         (args (call-node-args node))
         (types (mapcar #'node-type args))
         (checked (> *safety* 0)))
    (flet ((is (&rest names) (member name names :test #'string=))
           (operands (ty) (mapcar (lambda (a) (typed-temp (emit-as a ty) ty)) args))
           (fold (fn vals) (reduce (lambda (acc v) (format nil fn acc v)) vals)))
      (cond
        ((is "+" "*" "-")
         (let ((vals (operands type))
               (op (cond ((is "+") "+") ((is "*") "*") (t "-"))))
           (cond ((and (is "-") (= (length vals) 1))
                  (if (eq type :int)
                      (format nil "~:[(-~A)~;sk_sub_i64(0, ~A)~]" checked (first vals))
                      (format nil "(-~A)" (first vals))))
                 ((= (length vals) 1) (first vals))
                 ((eq type :int)
                  (if checked
                      (fold (format nil "sk_~A_i64(~~A, ~~A)"
                                    (cond ((is "+") "add") ((is "*") "mul") (t "sub")))
                            vals)
                      (fold (format nil "((int64_t)((uint64_t)~~A ~A (uint64_t)~~A))" op) vals)))
                 (t (fold (format nil "(~~A ~A ~~A)" op) vals)))))
        ((is "/")
         (let ((vals (operands type)))
           (fold (if checked (format nil "sk_div_~(~A~)(~~A, ~~A)" type) "(~A / ~A)") vals)))
        ((is "inc" "dec")
         (let ((v (first (operands type)))
               (sign (if (is "inc") "+" "-")))
           (if (eq type :int)
               (if checked
                   (format nil "sk_~A_i64(~A, 1)" (if (is "inc") "add" "sub") v)
                   (format nil "(~A ~A 1)" v sign))
               (format nil "(~A ~A 1)" v sign))))
        ((is "<" ">" "<=" ">=" "==")
         (let ((vals (operands (contagion types)))
               (op (if (is "==") "==" name)))
           (format nil "(~{~A~^ && ~})"
                   (loop for (a b) on vals while b collect (format nil "~A ~A ~A" a op b)))))
        ((is "zero?" "pos?" "neg?")
         (let ((v (first (operands (first types)))))
           (format nil "(~A ~A 0)" v (cond ((is "zero?") "==") ((is "pos?") ">") (t "<")))))
        ((is "not") (format nil "(!~A)" (emit-as (first args) :bool)))
        ((is "sqrt")
         (let ((v (first (operands type))))
           (format nil "~:[sqrt~;sqrtf~](~A)" (eq type :f32) v)))
        ((is "aget" "aset!" "count")
         (let* ((count-var (array-count-var (first args)))
                (array (typed-temp (emit-as (first args) (first types)) nil))
                ;; An array's length never changes, so a typed local's is read once.
                (count (or count-var (format nil "sk_prim_count(~A)" array)))
                (element (string-downcase (symbol-name (cdr (first types))))))
           (cond ((is "count") count)
                 ((is "aget")
                  (let ((i (typed-temp (emit-as (second args) :int) :int)))
                    (when checked (stmt "sk_index_check(~A, ~A);" i count))
                    (format nil "sk_aget_~A_unchecked(~A, ~A)" element array i)))
                 (t (let ((i (typed-temp (emit-as (second args) :int) :int))
                          (v (typed-temp (emit-as (third args) type) type)))
                      (when checked (stmt "sk_index_check(~A, ~A);" i count))
                      (format nil "sk_aset_~A_unchecked(~A, ~A, ~A)" element array i v))))))
        (t (unsupported node "internal error: no typed form of skein.core/~A" name))))))
