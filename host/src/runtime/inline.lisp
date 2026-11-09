;;;; Inlined primitives (D-036). Calls to these skein.core functions are compiled to CL
;;;; code directly, so that SBCL can optimize them with the declared types, as long as the
;;;; var still holds the original function. Value-struct accessors register here too.

(in-package #:skein.runtime)

(defstruct (inline-entry (:constructor make-inline-entry (fn emitter min max test-p))
                         (:copier nil))
  "How to inline calls to a var: FN is the function it held when registered; EMITTER
maps the CL argument forms to a CL form; MIN and MAX bound the argument count (MAX NIL:
no limit); TEST-P means the form is a CL boolean, to be wrapped with BOOL in value
position."
  fn emitter min max test-p)

(setf (documentation 'inline-entry-fn 'function) "The function an inline entry was made for."
      (documentation 'inline-entry-emitter 'function) "The code generator of an inline entry."
      (documentation 'inline-entry-min 'function) "The fewest arguments an inline entry takes."
      (documentation 'inline-entry-max 'function) "The most arguments an inline entry takes."
      (documentation 'inline-entry-test-p 'function)
      "True if an inline entry produces a CL boolean.")

(sb-ext:define-load-time-global **inline-entries** (make-hash-table :test 'eq :synchronized t))

(defun register-inline (var emitter min max &key test-p)
  "Inline calls to VAR (while it holds its current value) with EMITTER."
  (setf (gethash var **inline-entries**)
        (make-inline-entry (var-value var) emitter min max test-p)))

(defun inline-arity-mismatch (var argument-count)
  "If VAR is an inlined primitive (still holding its original function) and
ARGUMENT-COUNT is outside the counts it accepts, return a description of the accepted
counts; else NIL."
  (let ((entry (gethash var **inline-entries**)))
    (and entry
         ;; Only skein.core's primitives: a struct constructor also accepts a keyword form
         ;; that is not inlined.
         (eq (var-namespace var) +core+)
         (eq (var-value var) (inline-entry-fn entry))
         (not (and (<= (inline-entry-min entry) argument-count)
                   (or (null (inline-entry-max entry))
                       (<= argument-count (inline-entry-max entry)))))
         (let ((min (inline-entry-min entry)) (max (inline-entry-max entry)))
           (cond ((null max) (format nil "at least ~D" min))
                 ((= min max) (format nil "~D" min))
                 (t (format nil "~D to ~D" min max)))))))

(defun inline-entry-for (var argument-count)
  "Return the inline entry for a call to VAR with ARGUMENT-COUNT arguments, or NIL."
  (let ((entry (gethash var **inline-entries**)))
    (and entry
         (eq (var-value var) (inline-entry-fn entry))
         (<= (inline-entry-min entry) argument-count)
         (or (null (inline-entry-max entry)) (<= argument-count (inline-entry-max entry)))
         entry)))

;;; Helpers that inlined code calls. They are inline functions, so with declared types
;;; SBCL removes the branches that cannot happen.

(declaim (inline skein-divide skein-quot skein-sqrt skein-aget skein-aset skein-count))

(defun skein-divide (a b)
  "Skein's / on two numbers: integers divide as f64 (DESIGN §6.1)."
  (if (and (integerp a) (integerp b))
      (/ (coerce a 'double-float) b)
      (/ a b)))

(defun skein-quot (a b)
  (if (and (integerp a) (integerp b)) (values (truncate a b)) (values (ftruncate a b))))

(defun skein-sqrt (x)
  "Square root that stays real: a negative number gives NaN (not a complex number)."
  (cond ((minusp x) +f64-nan+)
        ((floatp x) (sqrt x))
        (t (sqrt (coerce x 'double-float)))))

(defun skein-count (x)
  "count, with a fast path for arrays so that SBCL knows the result is an index."
  (if (typep x '(simple-array * (*))) (length x) (count-of x)))

(defun skein-aget (a i)
  (if (typep a '(simple-array * (*))) (aref a i) (aget-slow a i)))

(defun skein-aset (a i v)
  (if (typep a '(simple-array * (*))) (setf (aref a i) v) (aset-slow a i v)))

(defmacro define-inline (name (&rest params) (min max &key test-p) &body body)
  "Register an inline expansion for the skein.core function NAME. PARAMS receives the
argument forms; with &rest, a list of them."
  `(register-inline (find-own-var +core+ ,name)
                    (lambda (,@params) ,@body)
                    ,min ,max :test-p ,test-p))

(defun register-core-inlines ()
  "Register the inline expansions of skein.core's numeric and array primitives."
  (define-inline "+" (&rest args) (0 nil) `(+ ,@args))
  (define-inline "-" (&rest args) (1 nil) `(- ,@args))
  (define-inline "*" (&rest args) (0 nil) `(* ,@args))
  (define-inline "/" (a b) (2 2) `(skein-divide ,a ,b))
  (define-inline "inc" (x) (1 1) `(1+ ,x))
  (define-inline "dec" (x) (1 1) `(1- ,x))
  (define-inline "quot" (a b) (2 2) `(skein-quot ,a ,b))
  (define-inline "rem" (a b) (2 2) `(rem ,a ,b))
  (define-inline "mod" (a b) (2 2) `(mod ,a ,b))
  (define-inline "max" (&rest args) (1 nil) `(max ,@args))
  (define-inline "min" (&rest args) (1 nil) `(min ,@args))
  (define-inline "abs" (x) (1 1) `(abs ,x))
  (define-inline "sqrt" (x) (1 1) `(skein-sqrt ,x))
  (define-inline "<" (&rest args) (1 nil :test-p t) `(< ,@args))
  (define-inline ">" (&rest args) (1 nil :test-p t) `(> ,@args))
  (define-inline "<=" (&rest args) (1 nil :test-p t) `(<= ,@args))
  (define-inline ">=" (&rest args) (1 nil :test-p t) `(>= ,@args))
  (define-inline "==" (&rest args) (1 nil :test-p t) `(= ,@args))
  (define-inline "zero?" (x) (1 1 :test-p t) `(zerop ,x))
  (define-inline "pos?" (x) (1 1 :test-p t) `(plusp ,x))
  (define-inline "neg?" (x) (1 1 :test-p t) `(minusp ,x))
  (define-inline "even?" (x) (1 1 :test-p t) `(evenp ,x))
  (define-inline "odd?" (x) (1 1 :test-p t) `(oddp ,x))
  (define-inline "not" (x) (1 1 :test-p t) `(not (truthy-p ,x)))
  (define-inline "nil?" (x) (1 1 :test-p t) `(null ,x))
  (define-inline "count" (x) (1 1) `(skein-count ,x))
  (define-inline "aget" (a i) (2 2) `(skein-aget ,a ,i))
  (define-inline "aset!" (a i v) (3 3) `(skein-aset ,a ,i ,v)))
