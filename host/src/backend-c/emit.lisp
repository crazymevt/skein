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
  (body (make-string-output-stream)))

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
  (volatile nil))

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

(defun emit (node)
  "Emit NODE's statements; return a C expression for its value, or :RECUR if it jumped."
  (etypecase node
    (const-node (constant-expr (const-node-value node) node))
    (local-ref-node
     (or (gethash (local-ref-node-local node) (ctx-locals *ctx*))
         (unsupported node "internal error: no C variable for the local ~A"
                      (local-name (local-ref-node-local node)))))
    (var-ref-node (emit-var-ref node))
    (if-node (emit-if node))
    (do-node (let ((value "SK_NIL"))
               (dolist (f (do-node-forms node) value)
                 (setf value (emit f))
                 (when (eq value :recur) (return :recur)))))
    (def-node
     ;; def returns the var, as in Phase 0.
     (let ((name (var-c-name (def-node-var node))))
       (when (def-node-init node)
         (let ((init (emit (def-node-init node))))
           (stmt "sk_var_set(~A, ~A);" name init)))
       name))
    (fn-node (values (emit-fn node)))
    (let-node (emit-let (let-node-bindings node))
     (emit (let-node-body node)))
    (loop-node (emit-loop node))
    (recur-node (emit-recur node))
    (call-node (emit-call node))
    (the-node (emit (the-node-expr node)))
    (locally-node (emit (locally-node-body node)))
    (letfn-node (emit-letfn node))
    (set-node
     (let ((local (set-node-local node)))
       (when (gethash local (ctx-captured *ctx*))
         (unsupported node "a closure can't set! the ^:mutable local ~A of an enclosing ~
                            function yet" (local-name local)))
       (let ((v (emit (set-node-value node))))
         (stmt "~A = ~A;" (gethash local (ctx-locals *ctx*)) v)
         v)))
    (block-node (emit-block node))
    (return-from-node (emit-return-from node))
    (unwind-protect-node (emit-unwind-protect node))
    (handler-bind-node (emit-handler-bind node))
    (restart-bind-node (emit-restart-bind node))
    (throw-condition-node
     (let ((c (emit (throw-condition-node-condition node))))
       (stmt "sk_throw_condition(~A);" c)
       "SK_NIL"))
    ((or values-node let-values-node)
     (unsupported node "the native backend can't compile multiple values yet (M1.9)"))))

(defparameter *native-core-functions*
  '("+" "-" "*" "/" "<" ">" "<=" ">=" "==" "=" "not=" "inc" "dec" "max" "min" "abs" "mod"
    "rem" "quot" "compare" "zero?" "pos?" "neg?" "not" "identical?" "identity" "constantly"
    "println" "print" "prn" "pr" "list" "vector" "hash-map" "%map-literal" "hash-set"
    "%set-literal" "vec" "count" "conj" "assoc" "dissoc" "disj" "get" "nth" "contains?"
    "empty?" "first" "rest" "next" "cons" "peek" "pop" "into" "keys" "vals" "reduce" "apply"
    "str" "subs" "keyword" "symbol" "name" "namespace" "atom" "deref" "reset!" "swap!"
    "compare-and-set!" "transient" "persistent!" "conj!" "assoc!" "dissoc!" "disj!" "pop!"
    "nil?" "some?" "true?" "false?" "vector?" "map?" "set?" "list?" "seq?" "coll?" "string?"
    "keyword?" "symbol?" "number?" "integer?" "float?" "char?" "boolean?" "fn?" "atom?"
    "mapv" "%no-matching-case" "int" "char"
    ;; Conditions and restarts (M1.5)
    "error" "signal" "warn" "make-condition" "condition?" "error?" "condition-message"
    "condition-type" "condition-type-name" "invoke-restart" "find-restart" "compute-restarts"
    "restart-name" "restart-report" "%condition-type" "%define-condition" "%condition-slot")
  "The skein.core functions the native runtime has (runtime/src/core.zig). Calls to the
arithmetic, comparison and printing ones are compiled inline.")

(defun native-core-function (node var)
  "The startup constant holding skein.core function VAR, or a compile error."
  (let ((name (var-name var)))
    (unless (member name *native-core-functions* :test #'string=)
      (unsupported node "the native backend can't use skein.core/~A yet; most of skein.core ~
                         arrives in M1.9" name))
    (startup-constant (list :core name) (format nil "sk_core(~A)" (c-string-literal name)))))

(defparameter *builtin-condition-types*
  '("arithmetic-error" "type-error" "index-error" "arity-error" "unbound-var-error"
    "not-callable-error" "unsupported-operation-error" "transient-error" "namespace-error")
  "The skein.core vars that hold built-in condition types.")

(defun emit-var-ref (node)
  (let ((var (var-ref-node-var node)))
    (if (core-var-p var)
        (if (member (var-name var) *builtin-condition-types* :test #'string=)
            (startup-constant (list :condition-type (var-name var))
                              (format nil "sk_builtin_condition_type(~A)"
                                      (c-string-literal (var-name var))))
            (native-core-function node var))
        (temp (format nil "sk_var_get(~A, ~A, ~A)" (var-c-name var)
                      (c-string-literal (skein.runtime:var-qualified-name var))
                      (c-string-literal (location-string node)))))))

(defun emit-if (node)
  (let ((test (emit (if-node-test node)))
        (result (fresh "t")))
    (stmt "~A ~A = SK_NIL;" (value-type) result)
    (let ((then-recur nil) (else-recur nil))
      (with-block ("if (SK_TRUTHY(~A)) {" test)
        (let ((v (emit (if-node-then node))))
          (if (eq v :recur) (setf then-recur t) (stmt "~A = ~A;" result v))))
      (with-block ("else {")
        (let ((v (emit (if-node-else node))))
          (if (eq v :recur) (setf else-recur t) (stmt "~A = ~A;" result v))))
      (if (and then-recur else-recur) :recur result))))

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
        do (let ((value (emit init)))
             (stmt "~A ~A = ~A;" (value-type) (bind-local local) value))))

;;; loop* and recur. A recur target is a label plus the C names of its locals.

(defvar *frames* '()
  "C names of the frames (blocks, handler and restart clusters, unwind-protects) the code
being emitted is inside, in the current function, innermost first.")

(defstruct (target (:constructor make-target (label names &optional (frames *frames*))))
  label names frames)

(defvar *targets* '()
  "Alist of loop-node or arity -> target, innermost first.")

(defun emit-loop (node)
  (emit-let (loop-node-bindings node))
  (let ((label (fresh "loop"))
        (result (fresh "t")))
    (stmt "~A ~A = SK_NIL;" (value-type) result)
    (stmt "~A: ;" label)
    (stmt "SK_POLL();")
    (let* ((*targets* (acons node (make-target label (mapcar (lambda (b) (gethash (car b) (ctx-locals *ctx*)))
                                                             (loop-node-bindings node)))
                             *targets*))
           (v (emit (loop-node-body node))))
      (unless (eq v :recur) (stmt "~A = ~A;" result v)))
    result))

(defun emit-recur (node)
  (let* ((target (or (cdr (assoc (recur-node-target node) *targets*))
                     (unsupported node "recur outside its loop or function")))
         (values (mapcar (lambda (a) (let ((v (emit a))) (if (eq v :recur) "SK_NIL" (temp v))))
                         (recur-node-args node)))
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
                                        (or (gethash l (ctx-locals *ctx*))
                                            (unsupported node "internal error: ~A is not in ~
                                                               scope"
                                                         (if (local-p l)
                                                             (local-name l)
                                                             (block-tag-name l)))))
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
    (emit (letfn-node-body node))))

(defun emit-arity (arity)
  (let ((n (length (arity-params arity)))
        (rest (arity-rest arity)))
    (with-block ((if rest "if (argc >= ~D) {" "if (argc == ~D) {") n)
      (loop for p in (arity-params arity)
            for i from 0
            do (stmt "~A ~A = argv[~D];" (value-type) (bind-local p) i))
      (when rest
        (stmt "~A ~A = sk_rest_list(argc, argv, ~D);" (value-type) (bind-local rest) n))
      (let* ((label (fresh "top"))
             (names (mapcar (lambda (p) (gethash p (ctx-locals *ctx*)))
                            (append (arity-params arity) (and rest (list rest))))))
        (stmt "~A: ;" label)
        (stmt "SK_POLL();")
        (let* ((*targets* (acons arity (make-target label names) *targets*))
               (v (emit (arity-body arity))))
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
          (gethash tag (ctx-locals *ctx*)) (format nil "SK_BLOCK_TOKEN(~A)" frame))
    (with-block ("if (SK_SETJMP(~A.jb) == 0) {" frame)
      (let* ((*frames* (cons frame *frames*))
             (v (emit (block-node-body node))))
        (unless (eq v :recur)
          (stmt "~A = ~A;" result v)
          (stmt "sk_frame_pop(&~A);" frame))))
    (with-block ("else {")
      (stmt "~A = ~A.value;" result frame)
      (stmt "sk_frame_pop(&~A);" frame))
    result))

(defun emit-return-from (node)
  (let ((tag (return-from-node-tag node))
        (v (emit (return-from-node-value node))))
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
             (v (emit (unwind-protect-node-body node))))
        (unless (eq v :recur) (stmt "~A = ~A;" result v))
        (stmt "sk_frame_pop(&~A);" frame)))
    (with-block ("else {")
      (stmt "~A = 1;" unwinding))
    (emit (unwind-protect-node-cleanup node))
    (stmt "if (~A) sk_continue_unwind(&~A);" unwinding frame)
    result))

(defun emit-cluster-body (frame body)
  "Emit BODY inside the cluster FRAME (already pushed), pop it and return the value."
  (let* ((result (fresh "t"))
         (v (progn (stmt "~A ~A = SK_NIL;" (value-type) result)
                   (let ((*frames* (cons frame *frames*))) (emit body)))))
    (unless (eq v :recur) (stmt "~A = ~A;" result v))
    (stmt "sk_frame_pop(&~A);" frame)
    result))

(defun emit-handler-bind (node)
  "handler-bind*: the types and handlers are evaluated in order, then pushed as a cluster."
  (let ((bindings (handler-bind-node-bindings node)))
    (if (null bindings)
        (emit (handler-bind-node-body node))
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
        (emit (restart-bind-node-body node))
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

(defun qualify-condition-type-call (fn args)
  "ARGS, with the symbol in a call (skein.core/%condition-type 'name \"ns\") qualified by
the namespace its var is in, which the compiler knows from the program's ns form and
requires, so the runtime can find the type by its full name (D-047)."
  (if (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
           (string= (var-name (var-ref-node-var fn)) "%condition-type")
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

(defun emit-call (node)
  (let ((fn (call-node-fn node))
        (args (qualify-condition-type-call (call-node-fn node) (call-node-args node))))
    (if (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn))
             (member (var-name (var-ref-node-var fn)) *inline-primitives* :test #'string=))
        (emit-primitive node (var-name (var-ref-node-var fn)) args)
        (let ((f (emit fn))
              (values (emit-args args)))
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
         (t (unsupported node "the native backend can't call skein.core/~A yet; most of ~
                               skein.core arrives in M1.9"
                         name)))))))

;;; ------------------------------------------------------------------------------------
;;; Top-level forms and the whole program

(defun emit-toplevel (node)
  "Emit a top-level form into the program body."
  (let ((*ctx* (make-ctx :out (unit-body *unit*)))
        (*targets* '())
        (*frames* '()))
    (setf (ctx-volatile *ctx*) (uses-setjmp-p node))
    (with-block ("{")
      (let ((v (emit node)))
        (unless (eq v :recur) (stmt "(void)~A;" v))))))

(defun program-text (unit source-name main-var)
  (with-output-to-string (out)
    (format out "/* Generated by skein build from ~A. Do not edit. */~%~%" (c-comment source-name))
    (format out "#include \"skein.h\"~%#include <string.h>~%~%")
    (format out "static double sk_bits_f64(uint64_t bits) {~%  double d;~%  ~
                 memcpy(&d, &bits, sizeof d);~%  return d;~%}~%~%")
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
