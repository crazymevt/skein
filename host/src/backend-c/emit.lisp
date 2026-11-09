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
  (locals (make-hash-table :test 'eq)))

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

(defun temp (expr)
  "Store EXPR in a fresh temporary and return its name."
  (let ((name (fresh "t")))
    (stmt "sk_value ~A = ~A;" name expr)
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
  (substitute #\_ #\* (substitute #\_ #\/ string)))

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
        (t (unsupported node "the native backend can't compile the constant ~A yet; ~
                              keywords, symbols and collections arrive in M1.4"
                        (readable-string value)))))

(defun var-c-name (var)
  (or (gethash var (unit-vars *unit*))
      (let ((name (fresh "var")))
        (setf (gethash var (unit-vars *unit*)) name
              (unit-var-decls *unit*)
              (append (unit-var-decls *unit*)
                      (list (cons name (skein.runtime:var-qualified-name var)))))
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
         (unsupported node "~A is a local of an enclosing function; closures that capture ~
                            locals arrive in M1.4"
                      (local-name (local-ref-node-local node)))))
    (var-ref-node (emit-var-ref node))
    (if-node (emit-if node))
    (do-node (let ((value "SK_NIL"))
               (dolist (f (do-node-forms node) value)
                 (setf value (emit f))
                 (when (eq value :recur) (return :recur)))))
    (def-node
     (let ((name (var-c-name (def-node-var node))))
       (when (def-node-init node)
         (let ((init (emit (def-node-init node))))
           (stmt "~A = ~A;" name init)))
       "SK_NIL"))
    (fn-node (emit-fn node))
    (let-node (emit-let (let-node-bindings node))
     (emit (let-node-body node)))
    (loop-node (emit-loop node))
    (recur-node (emit-recur node))
    (call-node (emit-call node))
    (the-node (emit (the-node-expr node)))
    (locally-node (emit (locally-node-body node)))
    (letfn-node (unsupported node "the native backend can't compile letfn yet (M1.4)"))
    (set-node (unsupported node "the native backend can't compile set! yet (M1.4)"))
    ((or unwind-protect-node block-node return-from-node throw-condition-node
         handler-bind-node restart-bind-node)
     (unsupported node "the native backend can't compile non-local exits or conditions ~
                        yet (M1.5)"))
    ((or values-node let-values-node)
     (unsupported node "the native backend can't compile multiple values yet (M1.9)"))))

(defun emit-var-ref (node)
  (let ((var (var-ref-node-var node)))
    (when (core-var-p var)
      (unsupported node "the native backend can't use ~A as a value yet (only in calls); ~
                         skein.core arrives in M1.9"
                   (skein.runtime:var-qualified-name var)))
    (temp (format nil "(~A != SK_UNBOUND ? ~A : sk_unbound(~A, ~A))"
                  (var-c-name var) (var-c-name var)
                  (c-string-literal (skein.runtime:var-qualified-name var))
                  (c-string-literal (location-string node))))))

(defun emit-if (node)
  (let ((test (emit (if-node-test node)))
        (result (fresh "t")))
    (stmt "sk_value ~A = SK_NIL;" result)
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
             (stmt "sk_value ~A = ~A;" (bind-local local) value))))

;;; loop* and recur. A recur target is a label plus the C names of its locals.

(defstruct (target (:constructor make-target (label names))) label names)

(defvar *targets* '()
  "Alist of loop-node or arity -> target, innermost first.")

(defun emit-loop (node)
  (emit-let (loop-node-bindings node))
  (let ((label (fresh "loop"))
        (result (fresh "t")))
    (stmt "sk_value ~A = SK_NIL;" result)
    (stmt "~A: ;" label)
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
                         (recur-node-args node))))
    (loop for name in (target-names target)
          for v in values
          do (stmt "~A = ~A;" name v))
    (stmt "goto ~A;" (target-label target))
    :recur))

;;; Functions

(defun emit-fn (node)
  (let* ((code (fresh "fn"))
         (fobj (fresh "fobj"))
         (display (or (fn-node-name node) "fn"))
         (out (make-string-output-stream)))
    (let ((*ctx* (make-ctx :out out))
          (*targets* '()))
      (when (fn-node-self node)
        (setf (gethash (fn-node-self node) (ctx-locals *ctx*)) "self"))
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
    (setf (unit-fn-objects *unit*)
          (append (unit-fn-objects *unit*) (list (list fobj code display))))
    fobj))

(defun emit-arity (arity)
  (let ((n (length (arity-params arity)))
        (rest (arity-rest arity)))
    (with-block ((if rest "if (argc >= ~D) {" "if (argc == ~D) {") n)
      (loop for p in (arity-params arity)
            for i from 0
            do (stmt "sk_value ~A = argv[~D];" (bind-local p) i))
      (when rest
        ;; Rest arguments need lists (M1.4); with none given, the rest local is nil.
        (stmt "if (argc > ~D) sk_unbound(\"rest arguments (not yet supported natively)\", ~A);"
              n (c-string-literal (location-string arity)))
        (stmt "sk_value ~A = SK_NIL;" (bind-local rest)))
      (let* ((label (fresh "top"))
             (names (mapcar (lambda (p) (gethash p (ctx-locals *ctx*)))
                            (append (arity-params arity) (and rest (list rest))))))
        (stmt "~A: ;" label)
        (let* ((*targets* (acons arity (make-target label names) *targets*))
               (v (emit (arity-body arity))))
          (unless (eq v :recur) (stmt "return ~A;" v)))))))

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
        (args (call-node-args node)))
    (if (and (var-ref-node-p fn) (core-var-p (var-ref-node-var fn)))
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
        (*targets* '()))
    (with-block ("{")
      (let ((v (emit node)))
        (unless (eq v :recur) (stmt "(void)~A;" v))))))

(defun program-text (unit source-name main-var)
  (with-output-to-string (out)
    (format out "/* Generated by skein build from ~A. Do not edit. */~%~%" (c-comment source-name))
    (format out "#include \"skein.h\"~%#include <string.h>~%~%")
    (format out "static double sk_bits_f64(uint64_t bits) {~%  double d;~%  ~
                 memcpy(&d, &bits, sizeof d);~%  return d;~%}~%~%")
    (loop for (name . comment) in (unit-var-decls unit)
          do (format out "static sk_value ~A = SK_UNBOUND; /* ~A */~%" name (c-comment comment)))
    (loop for (name) in (unit-constants unit)
          do (format out "static sk_value ~A;~%" name))
    (loop for (fobj) in (unit-fn-objects unit)
          do (format out "static sk_value ~A;~%" fobj))
    (terpri out)
    (dolist (p (reverse (unit-prototypes unit))) (format out "~A~%" p))
    (terpri out)
    (dolist (f (reverse (unit-functions unit))) (format out "~A~%" f))
    (format out "static void sk_program_init(void) {~%")
    (loop for (name . init) in (unit-constants unit)
          do (format out "  ~A = ~A;~%" name init))
    (loop for (fobj code display) in (unit-fn-objects unit)
          do (format out "  ~A = sk_fn(~A, ~A);~%" fobj code (c-string-literal display)))
    (format out "}~%~%static void sk_program_body(void) {~%~A}~%~%"
            (get-output-stream-string (unit-body unit)))
    (format out "int main(int argc, char **argv) {~%  (void)argc;~%  (void)argv;~%  ~
                 sk_init();~%  sk_program_init();~%  sk_program_body();~%")
    (when main-var
      (format out "  if (~A != SK_UNBOUND) sk_call(~A, 0, NULL);~%" main-var main-var))
    (format out "  return 0;~%}~%")))
