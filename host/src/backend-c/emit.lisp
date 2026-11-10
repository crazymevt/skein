;;;; Core IR to C (D-044). The IR is a tree; C needs statements for if, let and loop, so
;;;; each node is emitted as statements that leave its value in a C expression (usually a
;;;; fresh temporary). That linearization is the ANF step that CORE-IR.md plans for the C
;;;; backend, done while emitting.

(in-package #:skein.backend.c)

(define-condition c-backend-error (skein-error) ()
  (:documentation "Signaled when a program uses something the C backend cannot compile
yet. The message names the milestone that adds it."))

(defun unsupported (node control &rest args)
  (error 'c-backend-error :location (and node (node-location node))
                          :message (apply #'format nil control args)))

;;; ------------------------------------------------------------------------------------
;;; The program being built

(defstruct (unit (:constructor make-unit ()))
  (counter 0)
  ;; Var -> C name of its global.
  (vars (make-hash-table :test 'eq))
  ;; (c-name . comment) in order.
  (var-decls '())
  ;; (c-name . init-expression) for constants made at startup, in order.
  (constants '())
  ;; Strings and f64s already made: (kind . value) -> C name.
  (constant-cache (make-hash-table :test 'equal))
  ;; Function definitions (C source) and their prototypes, in order.
  (functions '())
  (prototypes '())
  ;; (fobj-name code-name display-name) for function objects made at startup.
  (fn-objects '())
  ;; Statements of the program body (the top-level forms).
  (body (make-string-output-stream))
  ;; Block tag -> true if the block's multiple values matter (its return-froms set them).
  (block-mv (make-hash-table :test 'eq))
  ;; For a program that includes skein.compiler.env (D-060): the names lib/skein/core.skn
  ;; defines, whose vars the program compiles; the C names of its macros' vars, in order;
  ;; and whether the program includes the environment at all.
  (core-defined (make-hash-table :test 'equal))
  (core-macros '())
  (env-p nil))

(defvar *unit*)

(defun fresh (prefix)
  (format nil "~A~D" prefix (incf (unit-counter *unit*))))

;;; Per-function emission state.
(defstruct (ctx (:constructor make-ctx (&key out)))
  out
  (indent 1)
  ;; Local -> C expression naming it.
  (locals (make-hash-table :test 'eq))
  ;; Locals of enclosing functions that this function captured.
  (captured (make-hash-table :test 'eq))
  ;; Block tag -> C name of its frame, for the blocks of this function.
  (blocks (make-hash-table :test 'eq))
  ;; True if the function calls setjmp (it has a block* or unwind-protect), so its locals
  ;; are declared volatile: a longjmp back into it must see their current values.
  (volatile nil)
  ;; Local -> static type (typed.lisp) for locals held unboxed or known to be arrays.
  (types (make-hash-table :test 'eq))
  ;; Typed array local -> the C variable holding its length.
  (array-counts (make-hash-table :test 'eq)))

(defvar *ctx*)

(defun stmt (control &rest args)
  "Write one line of C at the current indentation."
  (let ((out (ctx-out *ctx*)))
    (dotimes (i (* 2 (ctx-indent *ctx*))) (write-char #\Space out))
    (apply #'format out control args)
    (terpri out)))

(defmacro with-block ((control &rest args) &body body)
  "Write CONTROL (ending in \"{\"), BODY one level in, then \"}\"."
  `(progn (stmt ,control ,@args)
          (incf (ctx-indent *ctx*))
          (unwind-protect (progn ,@body)
            (decf (ctx-indent *ctx*)))
          (stmt "}")))

(defun value-type ()
  "The C type of a local or temporary in the function being emitted."
  (if (ctx-volatile *ctx*) "volatile sk_value" "sk_value"))

(defun temp (expr)
  "Store EXPR in a fresh temporary and return its name."
  (let ((name (fresh "t")))
    (stmt "~A ~A = ~A;" (value-type) name expr)
    name))

(defun location-string (node)
  (skein.syntax:format-location (and node (node-location node))))

;;; ------------------------------------------------------------------------------------
;;; C text

(defun c-string-literal (string)
  "A C string literal for the UTF-8 encoding of STRING."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for byte across (sb-ext:string-to-octets string :external-format :utf-8)
          do (cond ((= byte (char-code #\")) (write-string "\\\"" out))
                   ((= byte (char-code #\\)) (write-string "\\\\" out))
                   ((<= 32 byte 126) (write-char (code-char byte) out))
                   ;; Octal escapes take at most three digits, so a following digit can't
                   ;; extend them, unlike \x.
                   (t (format out "\\~3,'0O" byte))))
    (write-char #\" out)))

(defun utf8-length (string)
  (length (sb-ext:string-to-octets string :external-format :utf-8)))

(defun c-comment (string)
  "STRING made safe inside /* */."
  (let ((s (copy-seq string)))
    (loop for i = (search "*/" s) while i do (setf (char s (1+ i)) #\_))
    s))

;;; ------------------------------------------------------------------------------------
;;; Constants and vars

(defun startup-constant (key init)
  "A global made once at startup by the C expression INIT; KEY dedupes it."
  (or (gethash key (unit-constant-cache *unit*))
      (let ((name (fresh "k")))
        (setf (unit-constants *unit*) (append (unit-constants *unit*) (list (cons name init)))
              (gethash key (unit-constant-cache *unit*)) name)
        name)))

(defun constant-expr (value node)
  (cond ((null value) "SK_NIL")
        ((eq value skein.runtime:+false+) "SK_FALSE")
        ((eq value t) "SK_TRUE")
        ((integerp value)
         (if (<= (- (expt 2 61)) value (1- (expt 2 61)))
             (format nil "SK_FIXNUM(INT64_C(~D))" value)
             (startup-constant (list :integer value) (format nil "sk_integer(\"~D\")" value))))
        ((typep value 'double-float)
         (startup-constant (list :f64 (sb-kernel:double-float-bits value))
                           (format nil "sk_f64(sk_bits_f64(UINT64_C(0x~16,'0X)))"
                                   (ldb (byte 64 0) (sb-kernel:double-float-bits value)))))
        ((typep value 'single-float)
         (format nil "SK_F32_BITS(UINT32_C(0x~8,'0X))"
                 (ldb (byte 32 0) (sb-kernel:single-float-bits value))))
        ((characterp value) (format nil "SK_CHAR(~D)" (char-code value)))
        ((stringp value)
         (startup-constant (list :string value)
                           (format nil "sk_string(~A, ~D)" (c-string-literal value)
                                   (utf8-length value))))
        ((skein.runtime:kw-p value)
         (startup-constant (list :keyword (skein.runtime:kw-namespace value)
                                 (skein.runtime:kw-name value))
                           (format nil "sk_keyword(~A, ~A)"
                                   (optional-c-string (skein.runtime:kw-namespace value))
                                   (c-string-literal (skein.runtime:kw-name value)))))
        ((sym-p value)
         (startup-constant (list :symbol (sym-namespace value) (sym-name value))
                           (format nil "sk_symbol(~A, ~A)"
                                   (optional-c-string (sym-namespace value))
                                   (c-string-literal (sym-name value)))))
        ((skein.runtime:pvector-p value)
         (collection-constant value "sk_vector_of" (skein.runtime:vector-to-list value) node))
        ((or (skein.runtime::plist-p value) (skein.runtime::empty-list-p value))
         (collection-constant value "sk_list_of" (skein.runtime:seq-to-cl value) node))
        ((skein.runtime::map-p value)
         (let ((kvs '()))
           (skein.runtime::map-reduce-kv value (lambda (acc k v) (push k kvs) (push v kvs) acc)
                                         nil)
           (collection-constant value "sk_map_of" (nreverse kvs) node)))
        ((skein.runtime::hash-set-p value)
         (collection-constant value "sk_set_of" (skein.runtime:seq-to-cl value) node))
        (t (unsupported node "the native backend can't compile the constant ~A yet"
                        (readable-string value)))))

(defun optional-c-string (string)
  (if string (c-string-literal string) "NULL"))

(defun collection-constant (value constructor elements node)
  "A startup constant built by CONSTRUCTOR from the constants ELEMENTS (made first)."
  (let ((exprs (mapcar (lambda (x) (constant-expr x node)) elements)))
    (startup-constant (list :collection (readable-string value))
                      (if exprs
                          (format nil "~A(~D, (const sk_value[]){~{~A~^, ~}})"
                                  constructor (length exprs) exprs)
                          (format nil "~A(0, NULL)" constructor)))))

(defun var-c-name (var)
  (or (gethash var (unit-vars *unit*))
      (let ((name (fresh "var")))
        (setf (gethash var (unit-vars *unit*)) name
              (unit-var-decls *unit*)
              (append (unit-var-decls *unit*)
                      (list (list name (namespace-name (var-namespace var)) (var-name var)))))
        name)))

(defun core-var-p (var)
  (string= (namespace-name (var-namespace var)) "skein.core"))

;;; ------------------------------------------------------------------------------------
;;; Nodes

(defvar *safety* 1
  "The safety level of the code being emitted: 0 drops bounds and overflow checks
(typed.lisp). Declared here, before emit-node binds it for a locally node; declared later,
that binding was lexical, so (safety 0) was lost outside typed expressions.")

(defvar *mv* nil
  "True while emitting a node whose multiple values matter (D-053): the body of a
function, the init of a let-values*, or a tail part of such a node.")

(defvar *tail-mv* nil
  "While a node's statements are emitted, whether its multiple values matter; its tail
parts are emitted with *MV* bound to this.")

(defun emit (node)
  "Emit NODE's statements; return a C expression for its value, or :RECUR if it jumped.
When *MV* is true, they also leave NODE's multiple values in the thread's registers."
  (let* ((*tail-mv* *mv*)
         (*mv* nil))
    (emit-node node)))

(defun emit-tail (node)
  "Emit NODE, a tail part of the node being emitted, whose values are that node's."
  (let ((*mv* *tail-mv*))
    (emit node)))

(defun single-value (expr)
  "EXPR, the value of a node that has one value: say so if its values matter."
  (when *tail-mv* (stmt "sk_mv_reset();"))
  expr)

(defun emit-node (node)
  (etypecase node
    (const-node (single-value (constant-expr (const-node-value node) node)))
    (local-ref-node
     (let ((local (local-ref-node-local node)))
       (single-value
        (box (or (gethash local (ctx-locals *ctx*))
                 (unsupported node "internal error: no C variable for the local ~A"
                              (local-name local)))
             (local-static-type local)))))
    (var-ref-node (single-value (emit-var-ref node)))
    (if-node (emit-if node))
    (do-node (let ((value "SK_NIL") (forms (do-node-forms node)))
               (loop for (f . more) on forms
                     do (setf value (if more (emit-as f :void) (emit-tail f)))
                        (when (eq value :recur) (return)))
               value))
    (def-node
     ;; def returns the var, as in Phase 0.
     (let ((name (var-c-name (def-node-var node))))
       (when (def-node-init node)
         (let ((init (emit (def-node-init node))))
           (stmt "sk_var_set(~A, ~A);" name init)))
       (single-value name)))
    (fn-node (single-value (values (emit-fn node))))
    (let-node (emit-let (let-node-bindings node))
     (emit-tail (let-node-body node)))
    (loop-node (emit-loop node))
    (recur-node (emit-recur node))
    (call-node (let ((type (node-type node)))
                 ;; A primitive on typed values is computed unboxed, then boxed.
                 (if (and (scalar-type-p type) (not (overflowing-p node)))
                     (single-value (box (emit-typed node type) type))
                     (emit-call node))))
    (the-node (let ((type (declared-type (the-node-type node))))
                (if (scalar-type-p type)
                    (single-value (box (emit-as (the-node-expr node) type :strict t) type))
                    (emit-tail (the-node-expr node)))))
    (locally-node (let ((*safety* (policy-safety (locally-node-policy node))))
                    (emit-tail (locally-node-body node))))
    (letfn-node (emit-letfn node))
    (set-node
     (let ((local (set-node-local node)))
       (when (gethash local (ctx-captured *ctx*))
         (unsupported node "a closure can't set! the ^:mutable local ~A of an enclosing ~
                            function yet" (local-name local)))
       (let ((v (local-store local (set-node-value node))))
         (stmt "~A = ~A;" (gethash local (ctx-locals *ctx*)) v)
         (single-value (box v (local-static-type local))))))
    (block-node (emit-block node))
    (return-from-node (emit-return-from node))
    (unwind-protect-node (emit-unwind-protect node))
    (handler-bind-node (emit-handler-bind node))
    (restart-bind-node (emit-restart-bind node))
    (throw-condition-node
     (let ((c (emit (throw-condition-node-condition node))))
       (stmt "sk_throw_condition(~A);" c)
       "SK_NIL"))
    (values-node (emit-values node))
    (let-values-node (emit-let-values node))))

(defun emit-values (node)
  "values: the first value, or nil; the values themselves if they matter."
  (let* ((args (emit-args (values-node-args node)))
         (n (length args)))
    (cond (*tail-mv*
           (if args
               (let ((array (fresh "mv")))
                 (stmt "const sk_value ~A[] = {~{~A~^, ~}};" array args)
                 (temp (format nil "sk_mv_set(~D, ~A)" n array)))
               (temp "sk_mv_set(0, NULL)")))
          (args (first args))
          (t "SK_NIL"))))

(defun emit-let-values (node)
  "let-values*: each init's values, read from the registers right after it runs."
  (loop for (locals . init) in (let-values-node-bindings node)
        do (let* ((v (let ((*mv* t)) (emit init)))
                  (count (fresh "mvc")))
             (when (eq v :recur) (setf v "SK_NIL"))
             (stmt "int32_t ~A = sk_mv_count;" count)
             (loop for l in locals
                   for i from 0
                   do (stmt "~A ~A = sk_mv_get(~A, ~A, ~D);" (value-type) (bind-local l)
                            count v i))))
  (emit-tail (let-values-node-body node)))

(defparameter *native-core-functions*
  '("+" "-" "*" "/" "<" ">" "<=" ">=" "==" "=" "not=" "inc" "dec" "max" "min" "abs" "mod"
    "rem" "quot" "compare" "zero?" "pos?" "neg?" "not" "identical?" "identity" "constantly"
    "println" "print" "prn" "pr" "list" "vector" "hash-map" "%map-literal" "hash-set"
    "%set-literal" "vec" "count" "conj" "assoc" "dissoc" "disj" "get" "nth" "contains?"
    "empty?" "first" "rest" "next" "cons" "peek" "pop" "keys" "vals" "reduce" "apply"
    "str" "pr-str" "hash-of" "odd?" "even?" "subs" "keyword" "symbol" "name" "namespace" "atom" "deref" "reset!" "swap!"
    "compare-and-set!" "transient" "persistent!" "conj!" "assoc!" "dissoc!" "disj!" "pop!"
    "nil?" "some?" "true?" "false?" "vector?" "map?" "set?" "list?" "seq?" "coll?" "string?"
    "keyword?" "symbol?" "number?" "integer?" "float?" "char?" "boolean?" "fn?" "atom?"
    "%no-matching-case" "int" "char"
    ;; Seqs (M1.8)
    "seq" "%lazy-seq" "realized?" "sequential?" "reduced" "reduced?" "unreduced"
    "ensure-reduced" "%eduction"
    ;; Step 3 of M1.8
    "f64" "f32" "sqrt" "rand" "rand-int" "gensym" "parse-long" "boolean" "associative?"
    "counted?" "ifn?"
    ;; The object system (step 4)
    "equiv" "initialize" "update-instance-for-redefined-class" "make" "with" "slot"
    "set-slot!" "%set-slot!" "update-slot!" "cell" "instance?" "class-of" "class-name"
    "class-slots" "class-precedence-list" "generic-methods" "%define-class" "%class"
    "%eql-specializer" "%define-generic"
    ;; Structs and typed arrays (step 5)
    "%make-array" "aget" "aset!" "array?" "struct?" "view" "as-bytes" "update!"
    ;; Concurrency (step 6; runtime/src/tasks.zig)
    "%with-nursery" "%spawn" "%future" "%with-timeout" "%on-main-thread" "%spawn-pinned"
    "drain-main-thread!" "check-cancelled" "sleep" "cancel!" "cancelled?" "done?" "task?"
    "cpu-count" "chan" "chan?" ">!" "<!" "close!" "alts!" "timeout-chan"
    ;; skein.io's primitives (M1.9; runtime/src/io.zig)
    "%read-file" "%write-file" "%file-exists?" "%run-process"
    ;; For the compiler written in Skein (M1.9; runtime/src/compiler.zig)
    "%copy-symbol" "%identity-table" "%identity-get" "%identity-put!" "%f64-bits" "%f32-bits"
    "%decimal-to-float" "%generic?" "%arity-error-details" "%function-name" "%skein-error?"
    "%error-has-location?" "%core-function-names" "%core-function" "%registered-core-vars"
    ;; Conditions and restarts (M1.5)
    "error" "signal" "warn" "make-condition" "condition?" "error?" "condition-message"
    "condition-type" "condition-type-name" "invoke-restart" "find-restart" "compute-restarts"
    "restart-name" "restart-report" "%condition-type" "%define-condition" "%condition-slot")
  "The skein.core functions the native runtime has (runtime/src/core.zig). Calls to the
arithmetic, comparison and printing ones are compiled inline.")

(defparameter *library-namespaces* '("skein.core.native" "skein.compiler.env")
  "The namespaces that define skein.core functions in Skein: the library (D-051) and the
native compiler's compile-time environment (D-060).")

(defun library-var (name)
  "The var of skein.core function NAME in a namespace written in Skein, or NIL."
  (loop for ns-name in *library-namespaces*
        for ns = (skein.runtime:find-namespace ns-name)
        for var = (and ns (skein.runtime:find-own-var ns name))
        when var return var))

(defun native-core-function (node var)
  "A C expression for skein.core function VAR: the runtime's function object (a startup
constant), the library's var, or a compile error."
  (let ((name (var-name var)))
    (cond ((member name *native-core-functions* :test #'string=)
           (startup-constant (list :core name) (format nil "sk_core(~A)" (c-string-literal name))))
          ((library-var name) (emit-global-ref node (library-var name)))
          (t (unsupported node "the native backend can't use skein.core/~A yet" name)))))

(defparameter *builtin-condition-types*
  '("arithmetic-error" "type-error" "index-error" "arity-error" "unbound-var-error"
    "not-callable-error" "unsupported-operation-error" "transient-error" "namespace-error"
    "cancelled" "timeout" "task-cancelled-error")
  "The skein.core vars that hold built-in condition types.")

(defun emit-var-ref (node)
  (let ((var (var-ref-node-var node)))
    (if (core-var-p var)
        (if (member (var-name var) *builtin-condition-types* :test #'string=)
            (startup-constant (list :condition-type (var-name var))
                              (format nil "sk_builtin_condition_type(~A)"
                                      (c-string-literal (var-name var))))
            (if (gethash (var-name var) (unit-core-defined *unit*))
                ;; Defined by lib/skein/core.skn, compiled into this program.
                (emit-global-ref node var)
                (native-core-function node var)))
        (emit-global-ref node var))))

(defun emit-global-ref (node var)
  "Read VAR's value, checking that it is bound."
  (temp (format nil "sk_var_get(~A, ~A, ~A)" (var-c-name var)
                (c-string-literal (skein.runtime:var-qualified-name var))
                (c-string-literal (location-string node)))))

(defun emit-if (node &optional type)
  "if; with TYPE, its value is computed as that static type (typed.lisp)."
  (let ((test (emit-as (if-node-test node) :bool))
        (result (fresh "t")))
    (stmt "~A ~A~:[ = SK_NIL~;~];" (decl-type type) result type)
    (flet ((branch (n) (if type (emit-as n type) (emit-tail n))))
      (let ((then-recur nil) (else-recur nil))
        (with-block ("if (~A) {" test)
          (let ((v (branch (if-node-then node))))
            (if (eq v :recur) (setf then-recur t) (stmt "~A = ~A;" result v))))
        (with-block ("else {")
          (let ((v (branch (if-node-else node))))
            (if (eq v :recur) (setf else-recur t) (stmt "~A = ~A;" result v))))
        (if (and then-recur else-recur) :recur result)))))

(defun bind-local (local)
  "Declare a C variable for LOCAL and return its name."
  (let ((name (format nil "l_~A_~D" (c-identifier (local-name local)) (local-id local))))
    (setf (gethash local (ctx-locals *ctx*)) name)
    name))

(defun c-identifier (string)
  (with-output-to-string (out)
    (loop for ch across string
          do (write-char (if (or (char<= #\a ch #\z) (char<= #\A ch #\Z) (char<= #\0 ch #\9))
                             ch #\_)
                         out))))

(defun emit-let (bindings)
  (loop for (local . init) in bindings
        do (let ((value (local-store local init)))
             (when (eq value :recur) (setf value "0"))
             (stmt "~A ~A = ~A;" (decl-type (local-static-type local)) (bind-local local)
                   value)
             (note-array-count local (gethash local (ctx-locals *ctx*))))))

;;; loop* and recur. A recur target is a label plus the C names of its locals.

(defvar *frames* '()
  "C names of the frames (blocks, handler and restart clusters, unwind-protects) the code
being emitted is inside, in the current function, innermost first.")

(defstruct (target (:constructor make-target (label names locals &optional (frames *frames*))))
  label names locals frames)

(defvar *targets* '()
  "Alist of loop-node or arity -> target, innermost first.")

(defun emit-loop (node &optional type)
  "loop*; with TYPE, its value is computed as that static type (typed.lisp)."
  (emit-let (loop-node-bindings node))
  (let ((label (fresh "loop"))
        (result (fresh "t"))
        (locals (mapcar #'car (loop-node-bindings node))))
    (stmt "~A ~A~:[ = SK_NIL~;~];" (decl-type type) result type)
    (stmt "~A: ;" label)
    (stmt "SK_POLL();")
    (let* ((*targets* (acons node (make-target label
                                               (mapcar (lambda (l) (gethash l (ctx-locals *ctx*)))
                                                       locals)
                                               locals)
                             *targets*))
           (v (if type (emit-as (loop-node-body node) type) (emit-tail (loop-node-body node)))))
      (unless (eq v :recur) (stmt "~A = ~A;" result v)))
    result))

(defun emit-recur (node)
  (let* ((target (or (cdr (assoc (recur-node-target node) *targets*))
                     (unsupported node "recur outside its loop or function")))
         ;; Each value is computed first, as the local it goes to stores it.
         (values (loop for a in (recur-node-args node)
                       for l in (target-locals target)
                       collect (let ((v (local-store l a))
                                     (type (local-static-type l)))
                                 (if (eq v :recur)
                                     (if type "0" "SK_NIL")
                                     (typed-temp v type)))))
         ;; recur can leave blocks (block* passes tail position through): pop them.
         (left (ldiff *frames* (target-frames target))))
    (when left
      (stmt "sk_frame_pop(&~A);" (car (last left))))
    (loop for name in (target-names target)
          for v in values
          do (stmt "~A = ~A;" name v))
    (stmt "goto ~A;" (target-label target))
    :recur))

;;; Functions and closures

(defun free-locals (fn-node)
  "The locals FN-NODE refers to but does not bind (its captured values), in order of
first use. Locals are unique objects (CORE-IR.md), so binding is a set, not a scope. The
block tags of enclosing blocks it returns from count as locals: it captures their
tokens."
  (let ((bound (make-hash-table :test 'eq))
        (refs '()))
    (labels ((bind (l) (setf (gethash l bound) t))
             (use (l) (pushnew l refs))
             (walk (n)
               (etypecase n
                 ((or const-node var-ref-node))
                 (local-ref-node (use (local-ref-node-local n)))
                 (if-node (walk (if-node-test n)) (walk (if-node-then n)) (walk (if-node-else n)))
                 (do-node (mapc #'walk (do-node-forms n)))
                 (def-node (when (def-node-init n) (walk (def-node-init n))))
                 (fn-node
                  (when (fn-node-self n) (bind (fn-node-self n)))
                  (dolist (a (fn-node-arities n))
                    (mapc #'bind (arity-params a))
                    (when (arity-rest a) (bind (arity-rest a)))
                    (walk (arity-body a))))
                 (let-node (loop for (l . i) in (let-node-bindings n) do (bind l) (walk i))
                  (walk (let-node-body n)))
                 (loop-node (loop for (l . i) in (loop-node-bindings n) do (bind l) (walk i))
                  (walk (loop-node-body n)))
                 (letfn-node (loop for (l) in (letfn-node-bindings n) do (bind l))
                  (loop for (nil . f) in (letfn-node-bindings n) do (walk f))
                  (walk (letfn-node-body n)))
                 (recur-node (mapc #'walk (recur-node-args n)))
                 (set-node (use (set-node-local n)) (walk (set-node-value n)))
                 (call-node (walk (call-node-fn n)) (mapc #'walk (call-node-args n)))
                 (the-node (walk (the-node-expr n)))
                 (locally-node (walk (locally-node-body n)))
                 (unwind-protect-node (walk (unwind-protect-node-body n))
                  (walk (unwind-protect-node-cleanup n)))
                 (block-node (bind (block-node-tag n)) (walk (block-node-body n)))
                 (return-from-node (use (return-from-node-tag n))
                  (walk (return-from-node-value n)))
                 (values-node (mapc #'walk (values-node-args n)))
                 (let-values-node
                  (loop for (ls . i) in (let-values-node-bindings n) do (mapc #'bind ls) (walk i))
                  (walk (let-values-node-body n)))
                 (throw-condition-node (walk (throw-condition-node-condition n)))
                 (handler-bind-node
                  (loop for (ty . h) in (handler-bind-node-bindings n) do (walk ty) (walk h))
                  (walk (handler-bind-node-body n)))
                 (restart-bind-node
                  (loop for (nil f r) in (restart-bind-node-bindings n) do (walk f) (walk r))
                  (walk (restart-bind-node-body n))))))
      (walk fn-node)
      (remove-if (lambda (l) (gethash l bound)) (reverse refs)))))

(defun emit-fn (node)
  "Emit FN-NODE's C function. Returns a C expression for the function value and the
locals it captured. A function that captures nothing is made once, at startup."
  (let* ((code (fresh "fn"))
         (display (or (fn-node-name node) "fn"))
         (captured (free-locals node))
         (out (make-string-output-stream)))
    (let ((*ctx* (make-ctx :out out))
          (*targets* '())
          (*frames* '()))
      (setf (ctx-volatile *ctx*)
            (some (lambda (a) (uses-setjmp-p (arity-body a))) (fn-node-arities node)))
      (note-parameter-types (fn-node-arities node))
      (dolist (a (fn-node-arities node)) (infer-locals (arity-body a)))
      (when (fn-node-self node)
        (setf (gethash (fn-node-self node) (ctx-locals *ctx*)) "self"))
      (loop for l in captured
            for i from 0
            do (setf (gethash l (ctx-locals *ctx*)) (format nil "SK_CAPTURED(self, ~D)" i)
                     (gethash l (ctx-captured *ctx*)) t))
      (format out "static sk_value ~A(sk_value self, uint32_t argc, const sk_value *argv) {~%"
              code)
      (stmt "(void)self; (void)argv;")
      (dolist (arity (fn-node-arities node))
        (emit-arity arity))
      (stmt "return sk_arity_error(self, argc, ~A);" (c-string-literal (location-string node)))
      (format out "}~%"))
    (push (format nil "static sk_value ~A(sk_value self, uint32_t argc, const sk_value *argv);"
                  code)
          (unit-prototypes *unit*))
    (push (get-output-stream-string out) (unit-functions *unit*))
    (if (null captured)
        (let ((fobj (fresh "fobj")))
          (setf (unit-fn-objects *unit*)
                (append (unit-fn-objects *unit*) (list (list fobj code display))))
          (values fobj '()))
        (values (temp (format nil "sk_closure(~A, ~A, ~D, (const sk_value[]){~{~A~^, ~}})"
                              code (c-string-literal display) (length captured)
                              (mapcar (lambda (l)
                                        (box (or (gethash l (ctx-locals *ctx*))
                                                 (unsupported node "internal error: ~A is not in ~
                                                                    scope"
                                                              (if (local-p l)
                                                                  (local-name l)
                                                                  (block-tag-name l))))
                                             (and (local-p l) (local-static-type l))))
                                      captured)))
                captured))))

(defun emit-letfn (node)
  "letfn: make each closure with nil for the letfn locals it uses, then fill those in,
so the functions can call each other."
  (let ((bindings (letfn-node-bindings node)))
    (loop for (local) in bindings
          do (stmt "~A ~A = SK_NIL;" (value-type) (bind-local local)))
    (let ((made (loop for (local . fn) in bindings
                      collect (multiple-value-bind (expr captured) (emit-fn fn)
                                (stmt "~A = ~A;" (gethash local (ctx-locals *ctx*)) expr)
                                (cons local captured)))))
      (loop for (local . captured) in made
            do (loop for c in captured
                     for i from 0
                     when (assoc c bindings)
                       do (stmt "sk_closure_set(~A, ~D, ~A);"
                                (gethash local (ctx-locals *ctx*)) i
                                (gethash c (ctx-locals *ctx*))))))
    (emit-tail (letfn-node-body node))))

(defun emit-arity (arity)
  (let ((n (length (arity-params arity)))
        (rest (arity-rest arity)))
    (with-block ((if rest "if (argc >= ~D) {" "if (argc == ~D) {") n)
      ;; A parameter with a declared type is checked and unboxed on entry.
      (loop for p in (arity-params arity)
            for i from 0
            do (let ((type (local-static-type p)))
                 (stmt "~A ~A = ~A;" (decl-type type) (bind-local p)
                       (unbox (format nil "argv[~D]" i) type arity))
                 (note-array-count p (gethash p (ctx-locals *ctx*)))))
      (when rest
        (stmt "~A ~A = sk_rest_list(argc, argv, ~D);" (value-type) (bind-local rest) n))
      (let* ((label (fresh "top"))
             (locals (append (arity-params arity) (and rest (list rest))))
             (names (mapcar (lambda (p) (gethash p (ctx-locals *ctx*))) locals)))
        (stmt "~A: ;" label)
        (stmt "SK_POLL();")
        (let* ((*targets* (acons arity (make-target label names locals) *targets*))
               ;; A function's values are those of its body.
               (v (let ((*mv* t)) (emit (arity-body arity)))))
          (unless (eq v :recur) (stmt "return ~A;" v)))))))

;;; Non-local exits and conditions (M1.5, D-047). Frames live in the C function's own
;;; stack frame; runtime/src/cond.zig keeps them on a per-thread chain.

(defun node-children (node)
  "The nodes directly inside NODE, not counting the bodies of nested functions."
  (etypecase node
    ((or const-node var-ref-node local-ref-node fn-node) '())
    (if-node (list (if-node-test node) (if-node-then node) (if-node-else node)))
    (do-node (do-node-forms node))
    (def-node (and (def-node-init node) (list (def-node-init node))))
    (let-node (append (mapcar #'cdr (let-node-bindings node)) (list (let-node-body node))))
    (loop-node (append (mapcar #'cdr (loop-node-bindings node)) (list (loop-node-body node))))
    (letfn-node (list (letfn-node-body node)))
    (recur-node (recur-node-args node))
    (set-node (list (set-node-value node)))
    (call-node (cons (call-node-fn node) (call-node-args node)))
    (the-node (list (the-node-expr node)))
    (locally-node (list (locally-node-body node)))
    (unwind-protect-node (list (unwind-protect-node-body node)
                               (unwind-protect-node-cleanup node)))
    (block-node (list (block-node-body node)))
    (return-from-node (list (return-from-node-value node)))
    (values-node (values-node-args node))
    (let-values-node (append (mapcar #'cdr (let-values-node-bindings node))
                             (list (let-values-node-body node))))
    (throw-condition-node (list (throw-condition-node-condition node)))
    (handler-bind-node (append (loop for (ty . h) in (handler-bind-node-bindings node)
                                     collect ty collect h)
                               (list (handler-bind-node-body node))))
    (restart-bind-node (append (loop for (nil f r) in (restart-bind-node-bindings node)
                                     collect f collect r)
                               (list (restart-bind-node-body node))))))

(defun uses-setjmp-p (node)
  "True if NODE, outside nested functions, has a block* or unwind-protect."
  (or (block-node-p node) (unwind-protect-node-p node)
      (some #'uses-setjmp-p (node-children node))))

(defun emit-block (node)
  "block*: a frame that return-from* unwinds to. Its token (the frame's serial) is what
closures capture to return from it."
  (let ((frame (fresh "fr"))
        (result (fresh "t"))
        (tag (block-node-tag node)))
    (stmt "sk_frame ~A;" frame)
    (stmt "sk_frame_push(&~A, SK_FRAME_BLOCK);" frame)
    (stmt "~A ~A = SK_NIL;" (value-type) result)
    (setf (gethash tag (ctx-blocks *ctx*)) frame
          (gethash tag (ctx-locals *ctx*)) (format nil "SK_BLOCK_TOKEN(~A)" frame)
          (gethash tag (unit-block-mv *unit*)) *tail-mv*)
    (with-block ("if (SK_SETJMP(~A.jb) == 0) {" frame)
      (let* ((*frames* (cons frame *frames*))
             (v (emit-tail (block-node-body node))))
        (unless (eq v :recur)
          (stmt "~A = ~A;" result v)
          (stmt "sk_frame_pop(&~A);" frame))))
    (with-block ("else {")
      (stmt "~A = ~A.value;" result frame)
      (stmt "sk_frame_pop(&~A);" frame))
    result))

(defun emit-return-from (node)
  (let* ((tag (return-from-node-tag node))
        (v (let ((*mv* (gethash tag (unit-block-mv *unit*))))
             (emit (return-from-node-value node)))))
    (when (eq v :recur) (setf v "SK_NIL"))
    (let ((frame (gethash tag (ctx-blocks *ctx*))))
      (if frame
          (stmt "sk_unwind_to(&~A, ~A);" frame v)
          (stmt "sk_return_from(~A, ~A);"
                (or (gethash tag (ctx-locals *ctx*))
                    (unsupported node "internal error: no token for the block ~A"
                                 (block-tag-name tag)))
                v)))
    "SK_NIL"))

(defun emit-unwind-protect (node)
  "The body runs under an unwind-protect frame. Whether it finishes or an unwind passes
through, the frame is popped and the cleanup runs; an unwind then continues."
  (let ((frame (fresh "fr"))
        (unwinding (fresh "uw"))
        (result (fresh "t")))
    (stmt "sk_frame ~A;" frame)
    (stmt "sk_frame_push(&~A, SK_FRAME_UNWIND);" frame)
    (stmt "volatile int ~A = 0;" unwinding)
    (stmt "~A ~A = SK_NIL;" (value-type) result)
    (with-block ("if (SK_SETJMP(~A.jb) == 0) {" frame)
      (let* ((*frames* (cons frame *frames*))
             (v (emit-tail (unwind-protect-node-body node))))
        (unless (eq v :recur) (stmt "~A = ~A;" result v))
        (stmt "sk_frame_pop(&~A);" frame)))
    (with-block ("else {")
      (stmt "~A = 1;" unwinding))
    ;; The cleanup keeps the values of the body, or of the unwind it interrupted.
    (let ((saved (fresh "mvs")) (saved-count (fresh "mvn")))
      (stmt "sk_value ~A[SK_MV_MAX]; int32_t ~A = sk_mv_count;" saved saved-count)
      (stmt "if (~A > 0) memcpy(~A, sk_mv_values, sizeof(sk_value) * (size_t)~A);"
            saved-count saved saved-count)
      (emit (unwind-protect-node-cleanup node))
      (stmt "sk_mv_count = ~A;" saved-count)
      (stmt "if (~A > 0) memcpy(sk_mv_values, ~A, sizeof(sk_value) * (size_t)~A);"
            saved-count saved saved-count))
    (stmt "if (~A) sk_continue_unwind(&~A);" unwinding frame)
    result))

(defun emit-cluster-body (frame body)
  "Emit BODY inside the cluster FRAME (already pushed), pop it and return the value."
  (let* ((result (fresh "t"))
         (v (progn (stmt "~A ~A = SK_NIL;" (value-type) result)
                   (let ((*frames* (cons frame *frames*))) (emit-tail body)))))
    (unless (eq v :recur) (stmt "~A = ~A;" result v))
    (stmt "sk_frame_pop(&~A);" frame)
    result))

(defun emit-handler-bind (node)
  "handler-bind*: the types and handlers are evaluated in order, then pushed as a cluster."
  (let ((bindings (handler-bind-node-bindings node)))
    (if (null bindings)
        (emit-tail (handler-bind-node-body node))
        (let* ((pairs (emit-args (loop for (ty . h) in bindings collect ty collect h)))
               (types (fresh "ty")) (fns (fresh "hf")) (frame (fresh "fr")))
          (stmt "sk_value ~A[] = {~{~A~^, ~}};" types
                (loop for (ty) on pairs by #'cddr collect ty))
          (stmt "const sk_value ~A[] = {~{~A~^, ~}};" fns
                (loop for (nil h) on pairs by #'cddr collect h))
          (stmt "sk_frame ~A;" frame)
          (stmt "sk_frame_push_handlers(&~A, ~D, ~A, ~A);" frame (length bindings) types fns)
          (emit-cluster-body frame (handler-bind-node-body node))))))

(defun emit-restart-bind (node)
  "restart-bind*: names are symbols; functions and reports are evaluated in order."
  (let ((bindings (restart-bind-node-bindings node)))
    (if (null bindings)
        (emit-tail (restart-bind-node-body node))
        (let* ((names (mapcar (lambda (b) (constant-expr (first b) node)) bindings))
               (values (emit-args (loop for (nil f r) in bindings collect f collect r)))
               (rn (fresh "rn")) (rf (fresh "rf")) (rr (fresh "rr")) (frame (fresh "fr")))
          (stmt "sk_value ~A[] = {~{~A~^, ~}};" rn names)
          (stmt "const sk_value ~A[] = {~{~A~^, ~}};" rf
                (loop for (f) on values by #'cddr collect f))
          (stmt "const sk_value ~A[] = {~{~A~^, ~}};" rr
                (loop for (nil r) on values by #'cddr collect r))
          (stmt "sk_frame ~A;" frame)
          (stmt "sk_frame_push_restarts(&~A, ~D, ~A, ~A, ~A);" frame (length bindings) rn rf rr)
          (emit-cluster-body frame (restart-bind-node-body node))))))

(defparameter *builtin-class-names*
  '("any" "object" "nil-class" "integer" "float" "f32" "f64" "number" "char" "string"
    "keyword" "symbol" "vector" "hash-map" "hash-set" "list" "seq" "fn" "atom")
  "The built-in class names of DESIGN §8.3 (besides condition, error and warning), which
%class finds unqualified.")

(defun qualify-condition-type-call (fn args)
  "ARGS, with the symbol in a call (skein.core/%condition-type 'name \"ns\") or
(skein.core/%class 'name \"ns\") qualified by the namespace its var is in, which the
compiler knows from the program's ns form and requires, so the runtime can find the type
or class by its full name (D-047, D-054)."
  (if (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
           (member (var-name (var-ref-node-var fn)) '("%condition-type" "%class")
                   :test #'string=)
           (= (length args) 2) (const-node-p (first args)) (const-node-p (second args))
           (sym-p (const-node-value (first args))) (stringp (const-node-value (second args))))
      (let* ((sym (const-node-value (first args)))
             (ns (skein.runtime:find-namespace (const-node-value (second args))))
             (qualified
               (cond ((null ns) sym)
                     ((sym-namespace sym)
                      (let ((target (skein.runtime:find-alias ns (sym-namespace sym))))
                        (if target
                            (skein.runtime:intern-sym (sym-name sym) (namespace-name target))
                            sym)))
                     ((member (sym-name sym) '("condition" "error" "warning") :test #'string=)
                      sym)
                     ((and (string= (var-name (var-ref-node-var fn)) "%class")
                           (member (sym-name sym) *builtin-class-names* :test #'string=))
                      sym)
                     (t (let ((var (skein.runtime:resolve-var ns (sym-name sym))))
                          (if var
                              (skein.runtime:intern-sym (sym-name sym)
                                                        (namespace-name (var-namespace var)))
                              sym))))))
        (cons (make-const-node :location (node-location (first args)) :value qualified)
              (rest args)))
      args))

;;; Calls

(defun emit-args (args)
  "Emit ARGS left to right into temporaries; return their names."
  (mapcar (lambda (a)
            (let ((v (emit a)))
              (when (eq v :recur) (unsupported a "recur used as an argument"))
              ;; Constants (SK_... macros) are safe to use as they are.
              (if (and (>= (length v) 3) (string= "SK_" v :end2 3))
                  v
                  (temp v))))
          args))

(defun define-method-target (node args)
  "For (skein.core/%define-method 'name \"ns\" ...), a C expression for the generic
function's var, or for a skein.core generic function itself. Phase 0 looks the name up
when the method is defined; natively it is resolved here, from the image the compiler
runs in (D-054): a var that holds a generic function, else the namespace's own var."
  (let* ((sym (const-node-value (first args)))
         (ns (skein.runtime:ensure-namespace (const-node-value (second args))))
         (found (if (sym-namespace sym)
                    (let ((target (or (skein.runtime:find-alias ns (sym-namespace sym))
                                      (skein.runtime:find-namespace (sym-namespace sym)))))
                      (and target (skein.runtime:find-own-var target (sym-name sym))))
                    (skein.runtime:resolve-var ns (sym-name sym))))
         (var (if (and found (typep (skein.runtime::var-value found)
                                    'skein.runtime::skein-generic))
                  found
                  (skein.runtime:intern-var ns (sym-name sym)))))
    (if (core-var-p var)
        (native-core-function node var)
        (var-c-name var))))

(defun define-method-call-p (fn args)
  (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
       (string= (var-name (var-ref-node-var fn)) "%define-method")
       (= (length args) 6) (const-node-p (first args)) (const-node-p (second args))
       (sym-p (const-node-value (first args))) (stringp (const-node-value (second args)))))

(defun core-call-p (fn name args count)
  "True if FN is skein.core/NAME called with COUNT arguments, the first a quoted symbol."
  (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
       (string= (var-name (var-ref-node-var fn)) name)
       (= (length args) count) (const-node-p (first args))
       (sym-p (const-node-value (first args)))))

(defun qualified-type-symbol (sym)
  "SYM, a type in a make-array or a struct field, qualified if it names a struct (by its
definition on the host) so the runtime finds it by its full name (D-055)."
  (let ((def (and (null (sym-namespace sym)) (skein.runtime::find-struct-def sym))))
    (if def
        (let* ((name (skein.runtime::struct-def-name def))
               (slash (position #\/ name)))
          (skein.runtime:intern-sym (subseq name (1+ slash)) (subseq name 0 slash)))
        sym)))

(defun qualified-fields (fields)
  "A struct's fields constant ([[name type]...]) with struct types qualified."
  (skein.runtime:vector-from-list
   (mapcar (lambda (f)
             (let ((items (skein.runtime:vector-to-list f)))
               (skein.runtime:vector-from-list
                (if (and (second items) (sym-p (second items)))
                    (list (first items) (qualified-type-symbol (second items)))
                    items))))
           (skein.runtime:seq-to-cl fields))))

(defun emit-define-struct (node args)
  "(%define-struct 'name value? '[[field type]...]): define the struct natively, then set
the vars Phase 0 defines for it, which the host made when the form ran at compile time:
the constructor, name? and name-field (D-055)."
  (let* ((name (const-node-value (first args)))
         (short (sym-name name))
         (fields (skein.runtime:seq-to-cl (const-node-value (third args))))
         (def (temp (format nil "sk_define_struct(~A, ~A, ~A)"
                            (constant-expr name node)
                            (emit (second args))
                            (constant-expr (qualified-fields (const-node-value (third args)))
                                           node))))
         (ns *current-namespace*))
    (flet ((set-var (var-name expr)
             (let ((var (skein.runtime:find-own-var ns var-name)))
               (when var (stmt "sk_var_set(~A, ~A);" (var-c-name var) expr)))))
      (set-var short (format nil "sk_struct_constructor(~A)" def))
      (set-var (format nil "~A?" short) (format nil "sk_struct_predicate(~A)" def))
      (loop for f in fields
            for i from 0
            do (set-var (format nil "~A-~A" short (sym-name (skein.runtime:vector-nth f 0)))
                        (format nil "sk_struct_accessor(~A, ~D)" def i))))
    (single-value "SK_NIL")))

(defun emit-define-soa (node args)
  "(%define-soa 'name '[[field type]...]): as emit-define-struct, for defsoa's vars: the
type, make-name and a function per field."
  (let* ((name (const-node-value (first args)))
         (short (sym-name name))
         (fields (skein.runtime:seq-to-cl (const-node-value (second args))))
         (def (temp (format nil "sk_define_soa(~A, ~A)" (constant-expr name node)
                            (constant-expr (qualified-fields (const-node-value (second args)))
                                           node))))
         (ns *current-namespace*))
    (flet ((set-var (var-name expr)
             (let ((var (skein.runtime:find-own-var ns var-name)))
               (when var (stmt "sk_var_set(~A, ~A);" (var-c-name var) expr)))))
      (set-var short def)
      (set-var (format nil "make-~A" short) (format nil "sk_soa_maker(~A)" def))
      (loop for f in fields
            for i from 0
            do (set-var (sym-name (skein.runtime:vector-nth f 0))
                        (format nil "sk_soa_field(~A, ~D)" def i))))
    (single-value "SK_NIL")))

(defun emit-call (node)
  (let ((fn (call-node-fn node))
        (args (qualify-condition-type-call (call-node-fn node) (call-node-args node))))
    (when (core-call-p fn "%define-struct" args 3)
      (return-from emit-call (emit-define-struct node args)))
    (when (core-call-p fn "%define-soa" args 2)
      (return-from emit-call (emit-define-soa node args)))
    (when (core-call-p fn "%make-array" args 2)
      (setf args (cons (make-const-node :location (node-location (first args))
                                        :value (qualified-type-symbol
                                                (const-node-value (first args))))
                       (rest args))))
    (when (define-method-call-p fn args)
      (return-from emit-call
        (let ((target (define-method-target node args))
              (rest (emit-args (cddr args))))
          (single-value (temp (format nil "sk_define_method(~A~{, ~A~})" target rest))))))
    (if (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
             (member (var-name (var-ref-node-var fn)) *inline-primitives* :test #'string=))
        (single-value (emit-primitive node (var-name (var-ref-node-var fn)) args))
        (let ((f (emit fn))
              (values (emit-args args)))
          ;; A compiled callee sets the values it returns; the runtime's functions don't,
          ;; so start from one value.
          (when *tail-mv* (stmt "sk_mv_reset();"))
          (temp (if values
                    (let ((array (fresh "args")))
                      (stmt "const sk_value ~A[] = {~{~A~^, ~}};" array values)
                      (format nil "sk_call(~A, ~D, ~A)" f (length values) array))
                    (format nil "sk_call(~A, 0, NULL)" f)))))))

(defun fold (fn values)
  (reduce (lambda (acc v) (format nil "~A(~A, ~A)" fn acc v)) values))

(defun chain (fn values)
  "(op a b c) as (op a b) and (op b c), all true."
  (if (null (cddr values))
      (format nil "~A(~A, ~A)" fn (first values) (second values))
      (format nil "SK_BOOL(~{SK_TRUTHY(~A)~^ && ~})"
              (loop for (a b) on values while b collect (format nil "~A(~A, ~A)" fn a b)))))

(defparameter *inline-primitives*
  '("+" "*" "-" "/" "<" ">" "<=" ">=" "==" "=" "not=" "inc" "dec" "zero?" "pos?" "neg?"
    "not" "nil?" "identical?" "println" "print" "prn" "pr")
  "skein.core functions whose calls compile to inline C (other core functions are called
through their function objects).")

(defun check-arity (node name n min max)
  (unless (and (<= min n) (or (null max) (<= n max)))
    (unsupported node "wrong number of arguments (~D) passed to skein.core/~A" n name)))

(defun emit-primitive (node name args)
  (let* ((n (length args))
         (values (emit-args args)))
    (flet ((one () (check-arity node name n 1 1) (first values))
           (print-call (readably newline)
             (if values
                 (let ((array (fresh "args")))
                   (stmt "const sk_value ~A[] = {~{~A~^, ~}};" array values)
                   (format nil "sk_print(~D, ~A, ~:[0~;1~], ~:[0~;1~])" n array readably newline))
                 (format nil "sk_print(0, NULL, ~:[0~;1~], ~:[0~;1~])" readably newline))))
      (temp
       (cond
         ((string= name "+") (case n (0 "SK_FIXNUM(0)")
                                    (1 (format nil "sk_check_number(\"+\", ~A)" (first values)))
                                    (t (fold "sk_add" values))))
         ((string= name "*") (case n (0 "SK_FIXNUM(1)")
                                    (1 (format nil "sk_check_number(\"*\", ~A)" (first values)))
                                    (t (fold "sk_mul" values))))
         ((string= name "-") (check-arity node name n 1 nil)
          (if (= n 1) (format nil "sk_mul(SK_FIXNUM(-1), ~A)" (first values)) (fold "sk_sub" values)))
         ;; Phase 0 inlines / with exactly two arguments, so that is all it accepts.
         ((string= name "/") (check-arity node name n 2 2) (fold "sk_div" values))
         ((member name '("<" ">" "<=" ">=" "==" "=") :test #'string=)
          (check-arity node name n 1 nil)
          (if (= n 1)
              "SK_TRUE"
              (chain (cdr (assoc name '(("<" . "sk_lt") (">" . "sk_gt") ("<=" . "sk_le")
                                        (">=" . "sk_ge") ("==" . "sk_num_eq") ("=" . "sk_equal"))
                                 :test #'string=))
                     values)))
         ((string= name "not=") (check-arity node name n 1 nil)
          (if (= n 1) "SK_FALSE" (format nil "SK_BOOL(!SK_TRUTHY(~A))" (chain "sk_equal" values))))
         ((string= name "inc") (format nil "sk_add(~A, SK_FIXNUM(1))" (one)))
         ((string= name "dec") (format nil "sk_sub(~A, SK_FIXNUM(1))" (one)))
         ((string= name "zero?") (format nil "sk_num_eq(~A, SK_FIXNUM(0))" (one)))
         ((string= name "pos?") (format nil "sk_gt(~A, SK_FIXNUM(0))" (one)))
         ((string= name "neg?") (format nil "sk_lt(~A, SK_FIXNUM(0))" (one)))
         ((string= name "not") (format nil "SK_BOOL(!SK_TRUTHY(~A))" (one)))
         ((string= name "nil?") (format nil "SK_BOOL(~A == SK_NIL)" (one)))
         ((string= name "identical?") (check-arity node name n 2 2)
          (format nil "SK_BOOL(~A == ~A)" (first values) (second values)))
         ((string= name "println") (print-call nil t))
         ((string= name "print") (print-call nil nil))
         ((string= name "prn") (print-call t t))
         ((string= name "pr") (print-call t nil))
         (t (unsupported node "the native backend can't call skein.core/~A yet" name)))))))

;;; ------------------------------------------------------------------------------------
;;; Top-level forms and the whole program

(defun emit-core-macro (var fn-node)
  "Compile a macro of lib/skein/core.skn into the program: set VAR to FN-NODE's function
and register it with the runtime as a macro, for skein.compiler.env (D-060)."
  (emit-toplevel (make-def-node :location (node-location fn-node) :var var :init fn-node))
  (setf (unit-core-macros *unit*) (append (unit-core-macros *unit*) (list (var-c-name var)))))

(defun core-registrations (unit)
  "The C statements that register, for skein.compiler.env, the core macros the program
compiled and the public vars of skein.core.native."
  (when (unit-env-p unit)
    (append (mapcar (lambda (c) (format nil "sk_register_core_var(~A, 1);" c))
                    (unit-core-macros unit))
            (let ((ns (skein.runtime:find-namespace "skein.core.native")))
              (loop for (name ns-name var-name) in (unit-var-decls unit)
                    for var = (and ns (string= ns-name "skein.core.native")
                                   (skein.runtime:find-own-var ns var-name))
                    when (and var (not (skein.runtime:var-private-p var)))
                      collect (format nil "sk_register_core_var(~A, 0);" name))))))

(defun emit-toplevel (node)
  "Emit a top-level form into the program body."
  (let ((*ctx* (make-ctx :out (unit-body *unit*)))
        (*targets* '())
        (*frames* '()))
    (setf (ctx-volatile *ctx*) (uses-setjmp-p node))
    (infer-locals node)
    (with-block ("{")
      (let ((v (emit node)))
        (unless (eq v :recur) (stmt "(void)~A;" v))))))

(defun program-text (unit source-name main-var)
  (with-output-to-string (out)
    (format out "/* Generated by skein build from ~A. Do not edit. */~%~%" (c-comment source-name))
    (format out "#include \"skein.h\"~%#include <string.h>~%~%")
    (format out "static double sk_bits_f64(uint64_t bits) {~%  double d;~%  ~
                 memcpy(&d, &bits, sizeof d);~%  return d;~%}~%~%")
    (format out "static float sk_bits_f32(uint32_t bits) {~%  float f;~%  ~
                 memcpy(&f, &bits, sizeof f);~%  return f;~%}~%~%")
    ;; Every global value lives in one array, registered with the garbage collector as
    ;; roots, so it keeps its objects alive and is updated when they move.
    (let ((globals (append (mapcar #'car (unit-var-decls unit))
                           (mapcar #'car (unit-constants unit))
                           (mapcar #'first (unit-fn-objects unit)))))
      (format out "static sk_value sk_globals[~D];~%" (max 1 (length globals)))
      (loop for name in globals
            for i from 0
            for decl = (assoc name (unit-var-decls unit) :test #'string=)
            do (format out "#define ~A sk_globals[~D]~@[ /* ~A */~]~%" name i
                       (and decl (c-comment (format nil "~A/~A" (second decl) (third decl)))))))
    (terpri out)
    (dolist (p (reverse (unit-prototypes unit))) (format out "~A~%" p))
    (terpri out)
    (dolist (f (reverse (unit-functions unit))) (format out "~A~%" f))
    (format out "static void sk_program_init(void) {~%")
    (format out "  for (size_t i = 0; i < sizeof sk_globals / sizeof sk_globals[0]; i++) ~
                 sk_globals[i] = SK_UNBOUND;~%")
    (format out "  sk_register_roots(sk_globals, sizeof sk_globals / sizeof sk_globals[0]);~%")
    (loop for (name ns var-name) in (unit-var-decls unit)
          do (format out "  ~A = sk_var(~A, ~A);~%" name (c-string-literal ns)
                     (c-string-literal var-name)))
    (loop for (name . init) in (unit-constants unit)
          do (format out "  ~A = ~A;~%" name init))
    (loop for (fobj code display) in (unit-fn-objects unit)
          do (format out "  ~A = sk_fn(~A, ~A);~%" fobj code (c-string-literal display)))
    (dolist (r (core-registrations unit)) (format out "  ~A~%" r))
    (format out "}~%~%static void sk_program_body(void) {~%~A}~%~%"
            (get-output-stream-string (unit-body unit)))
    (format out "int main(int argc, char **argv) {~%  (void)argc;~%  (void)argv;~%  ~
                 sk_init();~%  sk_program_init();~%  sk_program_body();~%")
    ;; -main gets the command-line arguments, as `skein run` passes them.
    (when main-var
      (format out "  if (sk_var_value(~A) != SK_UNBOUND) {~%    ~
                   sk_value main_args[64];~%    uint32_t n = 0;~%    ~
                   for (int i = 1; i < argc && n < 64; i++) main_args[n++] = ~
                   sk_string(argv[i], strlen(argv[i]));~%    ~
                   sk_call(sk_var_value(~A), n, main_args);~%  }~%" main-var main-var))
    (format out "  sk_finish();~%  return 0;~%}~%")))
