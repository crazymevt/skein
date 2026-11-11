;;;; The FFI (DESIGN §14) on CFFI. Pointers are CFFI foreign pointers (SBCL SAPs); NULL is
;;;; nil on the Skein side. Each defcfun compiles a small CL wrapper that converts
;;;; arguments and results.

(in-package #:skein.ffi)

(define-condition ffi-error (skein.runtime:skein-error) ()
  (:documentation "Signaled for FFI problems: a library that cannot be loaded, a missing C
function, an unsupported type, or a bad argument."))

(defun ffi-error (control &rest args)
  "Signal an FFI-ERROR with a message built from CONTROL and ARGS."
  (error 'ffi-error :location nil :message (apply #'format nil control args)))

(defpackage #:skein-cstructs (:use)
  (:documentation "Holds the CFFI names of structs, unions and callbacks defined in Skein."))

(setf cffi:*default-foreign-encoding* :utf-8)

(defmacro defffi (name lambda-list &body body)
  "Define the Skein function skein.ffi/NAME as a CL function."
  `(def-var (intern-var (ensure-namespace "skein.ffi") ,name)
            (sb-int:named-lambda ,(format nil "skein.ffi/~A" name) ,lambda-list ,@body)))

;;; ------------------------------------------------------------------------------------
;;; Types (DESIGN §14.1)

(defparameter *primitive-ffi-types*
  '(("i8" . :int8) ("i16" . :int16) ("i32" . :int32) ("i64" . :int64)
    ("u8" . :uint8) ("u16" . :uint16) ("u32" . :uint32) ("u64" . :uint64)
    ("f32" . :float) ("f64" . :double) ("bool" . :uint8) ("void" . :void)
    ("c-string" . :string) ("ptr" . :pointer))
  "Skein foreign types and their CFFI types. bool is C's one-byte _Bool.")

(defstruct (ctype (:constructor make-ctype (name kind cffi-name fields)) (:copier nil))
  "A C struct, union or enum defined in Skein. For an enum, FIELDS is a list of (keyword
. value) and CFFI-NAME is its integer type."
  name kind cffi-name fields)

(sb-ext:define-load-time-global **ctypes** (make-hash-table :test 'equal :synchronized t))

(defun find-ctype (sym &optional (namespace-name (namespace-name *current-namespace*)))
  "Return the ctype that SYM names: a var holding one, or a qualified name."
  (let* ((ns (find-namespace namespace-name))
         (var (and ns (resolve-var ns (sym-name sym))))
         (value (and var (var-value var))))
    (cond ((ctype-p value) value)
          ((sym-namespace sym)
           (gethash (format nil "~A/~A" (sym-namespace sym) (sym-name sym)) **ctypes**)))))

(defun primitive-type-p (type)
  (and (sym-p type) (null (sym-namespace type))
       (assoc (sym-name type) *primitive-ffi-types* :test #'string=)))

(defun resolve-type (type)
  "Resolve a foreign type given as data: a primitive symbol stays, a struct, union or enum
name becomes its ctype (looked up in the current namespace), and (ptr T), (fn ...) and
(array T n) stay as they are, with array element types resolved."
  (cond ((ctype-p type) type)
        ((primitive-type-p type) type)
        ((sym-p type) (or (find-ctype type)
                          (ffi-error "unknown foreign type ~A" (readable-string type))))
        ((equal (type-head type) "array")
         (destructuring-bind (element n) (type-args type)
           (list-from-cl (list (intern-sym "array") (resolve-type element) n))))
        (t type)))

(defun type-head (type)
  (and (skein.runtime:plist-p type) (sym-p (skein.runtime:seq-first type))
       (sym-name (skein.runtime:seq-first type))))

(defun type-args (type) (seq-to-cl (skein.runtime:seq-rest type)))

(defun foreign-type (type &key field)
  "Return the CFFI type for the resolved foreign TYPE. Structs and unions are allowed only
as FIELD types (by value inside another struct); arguments use pointers to them."
  (cond ((primitive-type-p type) (cdr (assoc (sym-name type) *primitive-ffi-types*
                                             :test #'string=)))
        ((or (ctype-p type) (sym-p type))
         (let ((c (resolve-type type)))
           (cond ((eq (ctype-kind c) :enum) (ctype-cffi-name c))
                 (field (list (if (eq (ctype-kind c) :union) :union :struct)
                              (ctype-cffi-name c)))
                 (t (ffi-error "~A is a ~(~A~); pass it by pointer, as (ptr ...)"
                               (ctype-name c) (ctype-kind c))))))
        ((equal (type-head type) "ptr") :pointer)
        ((equal (type-head type) "fn") :pointer)
        ((and field (equal (type-head type) "array"))
         (destructuring-bind (element n) (type-args type)
           (list (foreign-type element :field t) n)))
        (t (ffi-error "unsupported foreign type ~A" (readable-string type)))))

(defun enum-ctype (type)
  (and (ctype-p type) (eq (ctype-kind type) :enum) type))

;;; ------------------------------------------------------------------------------------
;;; Libraries

(defun library-search-directories ()
  "Directories searched for C libraries besides the system's default places."
  (skein.platform:library-directories))

(defun load-library (spec)
  "Load the C library described by SPEC: a map from :macos, :linux and :windows to a file
name or a vector of names to try. Returns the name that loaded."
  (let* ((key (intern-kw (skein.platform:os-name)))
         (names (let ((v (coll-get spec key)))
                  (cond ((stringp v) (list v))
                        (v (seq-to-cl v))
                        (t (ffi-error "no library given for ~A in ~A" (skein.platform:os-name)
                                      (readable-string spec))))))
         (cffi:*foreign-library-directories*
           (append (library-search-directories) cffi:*foreign-library-directories*))
         (errors '()))
    (dolist (name names)
      (handler-case (progn (cffi:load-foreign-library name) (return-from load-library name))
        (error (e) (push (let ((*print-pretty* nil)) (princ-to-string e)) errors))))
    (ffi-error "could not load ~{~A~^ or ~}: ~A" names (first errors))))

;;; ------------------------------------------------------------------------------------
;;; Structs, unions and enums

(defun define-ctype (name kind fields)
  "Define the struct or union NAME (a qualified symbol) with FIELDS, a list of
(field-symbol type)."
  (let* ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name)))
         (cffi-name (intern qualified '#:skein-cstructs))
         (slots (loop for (fsym ftype) in fields
                      collect (let ((ft (foreign-type ftype :field t)))
                                (if (and (consp ft) (integerp (second ft))
                                         (not (member (first ft) '(:struct :union))))
                                    `(,(intern (sym-name fsym) '#:skein-cstructs) ,(first ft)
                                      :count ,(second ft))
                                    `(,(intern (sym-name fsym) '#:skein-cstructs) ,ft))))))
    (eval (if (eq kind :union)
              `(cffi:defcunion ,cffi-name ,@slots)
              `(cffi:defcstruct ,cffi-name ,@slots)))
    (setf (gethash qualified **ctypes**)
          (make-ctype qualified kind cffi-name
                      (loop for (fsym ftype) in fields collect (list fsym (resolve-type ftype)))))))

(defun define-enum (name base values)
  (let ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name))))
    (setf (gethash qualified **ctypes**)
          (make-ctype qualified :enum (foreign-type base)
                      (loop for (k v) on values by #'cddr collect (cons k v))))))

(defun enum-value (ctype x)
  "Convert X to the integer value of the enum CTYPE: a keyword, a collection of keywords
(ORed together, for flags) or an integer."
  (cond ((integerp x) x)
        ((kw-p x) (or (cdr (assoc x (ctype-fields ctype)))
                      (ffi-error "~A has no value ~A" (ctype-name ctype) (readable-string x))))
        ((null x) 0)
        (t (reduce #'logior (mapcar (lambda (k) (enum-value ctype k)) (seq-to-cl x))
                   :initial-value 0))))

(defun struct-ctype (type)
  (let ((c (and (or (ctype-p type) (sym-p type)) (resolve-type type))))
    (unless (and c (member (ctype-kind c) '(:struct :union)))
      (ffi-error "~A is not a struct or union" (readable-string type)))
    c))

(defun field-name (ctype key)
  (unless (kw-p key)
    (ffi-error "struct fields are named by keywords, not ~A" (readable-string key)))
  (unless (find (kw-name key) (ctype-fields ctype) :key (lambda (f) (sym-name (first f)))
                                                   :test #'string=)
    (ffi-error "~A has no field ~A" (ctype-name ctype) (readable-string key)))
  (intern (kw-name key) '#:skein-cstructs))

;;; ------------------------------------------------------------------------------------
;;; Pointers and memory

(defstruct (owned-ptr (:constructor make-owned-ptr (pointer)) (:copier nil))
  "A pointer that Skein owns: C memory freed when it is garbage or by ffi/free."
  (pointer nil))

(defun to-pointer (x)
  "Convert a Skein value to a foreign pointer for a ptr argument."
  (cond ((null x) (cffi:null-pointer))
        ((cffi:pointerp x) x)
        ((owned-ptr-p x)
         (or (owned-ptr-pointer x) (ffi-error "the pointer was already freed")))
        ((skein.runtime:byte-view-p x) (array-pointer (skein.runtime:byte-view-array x)))
        ((and (vectorp x) (not (stringp x))) (array-pointer x))
        (t (ffi-error "expected a pointer, nil or an array of a primitive type, not ~A"
                      (readable-string x)))))

(defun array-pointer (a)
  "The address of the first element of the specialized array A (which must be pinned)."
  (multiple-value-bind (base offset) (array-displacement a)
    (if base
        (cffi:inc-pointer (array-pointer base)
                          (* offset (element-size base)))
        (sb-sys:vector-sap a))))

(defun element-size (a)
  (or (skein.runtime:array-element-bytes a)
      (ffi-error "an array of ~A cannot be passed to C" (array-element-type a))))

(defun pin-targets (x)
  "The Lisp objects to pin while C may use X's memory."
  (cond ((skein.runtime:byte-view-p x) (pin-targets (skein.runtime:byte-view-array x)))
        ((and (vectorp x) (not (stringp x)))
         (let ((base (array-displacement x))) (if base (pin-targets base) (list x))))
        (t '())))

(defun call-with-pinned (objects fn)
  "Call FN with every object in OBJECTS pinned, so the GC does not move them."
  (if (null objects)
      (funcall fn)
      (let ((o (first objects)))
        (sb-sys:with-pinned-objects (o)
          (call-with-pinned (rest objects) fn)))))

(defun from-pointer (p)
  (if (or (null p) (cffi:null-pointer-p p)) nil p))

(defun type-size (type)
  (let ((type (resolve-type type)))
    (cffi:foreign-type-size (if (and (ctype-p type) (not (enum-ctype type)))
                                (foreign-type type :field t)
                                (foreign-type type)))))

(defun alloc (type count)
  "Allocate zeroed C memory for COUNT values of TYPE (a primitive type or a struct)."
  (cffi:foreign-alloc :uint8 :count (* count (type-size type)) :initial-element 0))

(defun free-memory (p)
  (cond ((owned-ptr-p p)
         (let ((raw (owned-ptr-pointer p)))
           (when raw
             (sb-ext:cancel-finalization p)
             (setf (owned-ptr-pointer p) nil)
             (cffi:foreign-free raw))))
        ((null p))
        (t (cffi:foreign-free (to-pointer p))))
  nil)

(defun own (raw)
  "Wrap the foreign pointer RAW so that it is freed when garbage (DESIGN §14.2 ^:owned)."
  (if (or (null raw) (cffi:null-pointer-p raw))
      nil
      (let ((owned (make-owned-ptr raw))
            (address raw))
        (sb-ext:finalize owned (lambda () (cffi:foreign-free address)) :dont-save t)
        owned)))

(defun mem-type (type)
  (foreign-type (resolve-type type)))

(defun mem-get (p type index)
  (let ((type (resolve-type type)))
    (from-c type (cffi:mem-aref (to-pointer p) (mem-type type) index))))

(defun mem-put (p type value index)
  (let ((type (resolve-type type)))
    (setf (cffi:mem-aref (to-pointer p) (mem-type type) index) (to-c type value))
    value))

;;; Handles: stable integer tokens for Skein objects that C code holds (DESIGN §14.2).

(sb-ext:define-load-time-global **handles** (make-hash-table :synchronized t))
(sb-ext:define-load-time-global **handle-counter** (list 0))

(defun make-handle (obj)
  (let ((h (1+ (sb-ext:atomic-incf (car **handle-counter**)))))
    (setf (gethash h **handles**) obj)
    h))

;;; ------------------------------------------------------------------------------------
;;; Converting values between Skein and C

(defun to-c (type value)
  "Convert VALUE for passing to C as TYPE."
  (let ((enum (enum-ctype type)))
    (cond (enum (enum-value enum value))
          ((not (sym-p type)) (to-pointer value))
          (t (let ((name (sym-name type)))
               (cond ((string= name "bool") (if (truthy-p value) 1 0))
                     ((string= name "f32") (coerce value 'single-float))
                     ((string= name "f64") (coerce value 'double-float))
                     ((string= name "ptr") (to-pointer value))
                     ((string= name "c-string") (or value (cffi:null-pointer)))
                     (t value)))))))

(defun from-c (type value)
  "Convert VALUE received from C as TYPE."
  (cond ((enum-ctype type) value)
        ((not (sym-p type)) (from-pointer value))
        (t (let ((name (sym-name type)))
             (cond ((string= name "bool") (bool (/= value 0)))
                   ((string= name "ptr") (from-pointer value))
                   ((string= name "void") nil)
                   (t value))))))

;;; ------------------------------------------------------------------------------------
;;; defcfun

(define-condition slow-foreign-call (style-warning)
  ((message :initarg :message :reader slow-foreign-call-message))
  (:report (lambda (c s) (write-string (slow-foreign-call-message c) s)))
  (:documentation "Warns that a C function not marked ^:blocking took more than 10 ms."))

(defvar *warn-slow-calls* t
  "When true, C calls not marked ^:blocking that take longer than 10 ms warn once.")

(defun check-call-time (name start)
  (when (and *warn-slow-calls*
             (> (- (get-internal-real-time) start) (/ internal-time-units-per-second 100)))
    (let ((key (intern name '#:skein-cstructs)))
      (unless (get key 'warned)
        (setf (get key 'warned) t)
        (warn 'slow-foreign-call
              :message (format nil "the C function ~A took more than 10 ms; mark it ~
                                    ^:blocking if it waits" name))))))

(defun make-foreign-function (skein-name c-name return-type params &key blocking owned)
  "Return a Skein function that calls the C function C-NAME. PARAMS is a list of
(name-string type). The symbol is looked up on the first call."
  (when (member nil (mapcar #'second params))
    (ffi-error "every parameter of ~A needs a type" c-name))
  (setf return-type (resolve-type return-type))
  (let* ((args (loop for (n) in params collect (make-symbol (string-upcase n))))
         (pointer (make-symbol "POINTER"))
         (types (mapcar (lambda (p) (resolve-type (second p))) params))
         (cffi-return (if (and (sym-p return-type) (string= (sym-name return-type) "c-string"))
                          :string
                          (mem-type return-type)))
         ;; C code expects IEEE default behavior: no float traps while it runs.
         (call `(sb-int:with-float-traps-masked
                    (:overflow :invalid :divide-by-zero :inexact :underflow)
                  (cffi:foreign-funcall-pointer
                   ,pointer ()
                   ,@(loop for a in args
                           for type in types
                           append (list (mem-type type) `(to-c ',type ,a)))
                   ,cffi-return)))
         (start (make-symbol "START"))
         (form
           `(let ((,pointer nil))
              (sb-int:named-lambda ,skein-name ,args
                (unless ,pointer
                  (setf ,pointer (or (cffi:foreign-symbol-pointer ,c-name)
                                     (ffi-error "the C function ~A was not found; load its ~
                                                 library with ffi/deflibrary" ,c-name))))
                (let ((,start (get-internal-real-time)))
                  (declare (ignorable ,start))
                  (flet ((call ()
                           ,(if owned `(own ,call) `(from-c ',return-type ,call))))
                    (multiple-value-prog1
                        ,(let ((pointer-args (loop for a in args
                                                   for type in types
                                                   when (eq (mem-type type) :pointer)
                                                     collect a)))
                           (if pointer-args
                               `(call-with-pinned (mapcan #'pin-targets (list ,@pointer-args))
                                                  #'call)
                               '(call)))
                      ,@(unless blocking `((check-call-time ,c-name ,start))))))))))
    (compile nil `(lambda () ,form))))

(defun define-foreign-function (name c-name return-type params blocking owned)
  (let ((fn (funcall (make-foreign-function
                      (sym-name name) c-name return-type
                      (loop for p in params collect (list (sym-name (first p)) (second p)))
                      :blocking blocking :owned owned))))
    (def-var (intern-var *current-namespace* (sym-name name)) fn)))

;;; ------------------------------------------------------------------------------------
;;; Callbacks (DESIGN §14.3)

(define-condition callback-error-warning (warning)
  ((message :initarg :message :reader callback-error-warning-message))
  (:report (lambda (c s) (write-string (callback-error-warning-message c) s)))
  (:documentation "Warns that a Skein callback signaled an error, which cannot unwind
through C; the callback returned a zero value instead."))

(defun call-with-skein-float-modes (thunk)
  "Call THUNK with Skein's float traps (overflow and division by zero) enabled, as C code
calls back with all traps masked, and restore the caller's modes afterwards."
  (let ((saved (sb-int:get-floating-point-modes)))
    (unwind-protect
         (progn
           (sb-int:set-floating-point-modes :traps '(:overflow :divide-by-zero)
                                            :accrued-exceptions '() :current-exceptions '())
           (funcall thunk))
      (apply #'sb-int:set-floating-point-modes saved))))

(defun call-stopping-exits (thunk)
  "Call THUNK. A non-local exit that would leave it is stopped here, since it must not
unwind through C's frames (D-068). Returns true if THUNK returned."
  (let ((returned nil))
    (block barrier
      (unwind-protect (progn (funcall thunk) (setf returned t))
        (unless returned (return-from barrier))))
    returned))

(defun call-from-c (name zero zero-text thunk)
  "Run THUNK, a callback's body, for C: return its value, or ZERO if it signals an error
or tries to exit through C, which warns, naming the callback NAME and ZERO-TEXT. The
warning is signaled inside a barrier too, so a handler that tries to exit is stopped."
  (let* ((result zero)
         (message nil)
         (returned (call-stopping-exits
                    (lambda ()
                      (handler-case (setf result (funcall thunk))
                        (error (e)
                          (setf message (format nil "callback ~A signaled ~A~A" name
                                                (let ((*print-pretty* nil))
                                                  (princ-to-string e))
                                                zero-text))))))))
    (unless returned
      (setf result zero
            message (format nil "callback ~A tried to exit through C~A" name zero-text)))
    (when message
      (call-stopping-exits (lambda () (warn 'callback-error-warning :message message))))
    result))

(defun define-callback (name return-type params fn)
  "Make a C function pointer that calls the Skein function FN, and bind NAME to it."
  (let* ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name)))
         (cffi-name (intern qualified '#:skein-cstructs))
         (args (loop for (n) in params collect (make-symbol (string-upcase (sym-name n)))))
         (params (loop for (n type) in params collect (list n (resolve-type type))))
         (return-type (resolve-type return-type))
         (zero (if (member (mem-type return-type) '(:float :double))
                   (coerce 0 (if (eq (mem-type return-type) :float) 'single-float 'double-float))
                   (if (eq (mem-type return-type) :pointer) '(cffi:null-pointer) 0)))
         ;; How the warning shows the zero (as the C backend's does, D-068).
         (zero-text (case (mem-type return-type)
                      ((:float :double) "; returning 0.0")
                      ((:pointer :string) "; returning nil")
                      (:void "")
                      (t "; returning 0"))))
    (eval `(cffi:defcallback ,cffi-name ,(mem-type return-type)
               ,(loop for a in args for (nil type) in params collect (list a (mem-type type)))
             (call-with-skein-float-modes
              (lambda ()
                (call-from-c ,qualified ,zero ,zero-text
                             (lambda ()
                               (to-c ',return-type
                                     (funcall ',fn ,@(loop for a in args
                                                           for (nil type) in params
                                                           collect `(from-c ',type ,a))))))))))
    (def-var (intern-var *current-namespace* (sym-name name)) (cffi:get-callback cffi-name))))

;;; ------------------------------------------------------------------------------------
;;; The skein.ffi namespace

(defffi "%load-library" (spec) (load-library spec))
(defffi "%define-struct" (name kind fields)
  (let ((c (define-ctype name (if (string= (kw-name kind) "union") :union :struct)
             (mapcar (lambda (f) (vector-to-list f)) (seq-to-cl fields)))))
    (def-var (intern-var *current-namespace* (sym-name name)) c)
    nil))
(defffi "%define-enum" (name base values)
  (let ((c (define-enum name base (seq-to-cl values))))
    (def-var (intern-var *current-namespace* (sym-name name)) c)
    nil))
(defffi "%define-function" (name c-name return-type params blocking owned)
  (define-foreign-function name c-name return-type
    (mapcar (lambda (p) (vector-to-list p)) (seq-to-cl params))
    (truthy-p blocking) (truthy-p owned))
  nil)
(defffi "%define-function-ptr" (name return-type params blocking owned)
  ;; Calls through function pointers are native only (M2.13, D-096).
  (declare (ignore return-type params blocking owned))
  (def-var (intern-var *current-namespace* (sym-name name))
           (lambda (&rest args)
             (declare (ignore args))
             (ffi-error "~A: defcfun-ptr is native only (D-096)" (sym-name name))))
  nil)
(defffi "%define-callback" (name return-type params fn)
  (define-callback name return-type (mapcar (lambda (p) (vector-to-list p)) (seq-to-cl params)) fn)
  nil)
(defffi "%type" (type) type)
(defffi "%alloc" (type &optional (count 1)) (alloc type count))
(defffi "free" (p) (free-memory p))
(defffi "own" (p) (own (to-pointer p)))
(defffi "null" () nil)
(defffi "null?" (p) (bool (or (null p) (cffi:null-pointer-p (to-pointer p)))))
(defffi "ptr?" (x) (bool (or (cffi:pointerp x) (owned-ptr-p x))))
(defffi "address" (p) (cffi:pointer-address (to-pointer p)))
(defffi "ptr+" (p bytes) (cffi:inc-pointer (to-pointer p) bytes))
(defffi "%sizeof" (type) (type-size type))
(defffi "%get" (p type &optional (index 0)) (mem-get p type index))
(defffi "%put!" (p type value &optional (index 0)) (mem-put p type value index))
(defun field-access (type key)
  "Return the CFFI struct type, slot name and resolved foreign type of field KEY of TYPE."
  (let* ((c (struct-ctype type))
         (slot (field-name c key)))
    (values (list (if (eq (ctype-kind c) :union) :union :struct) (ctype-cffi-name c))
            slot
            (second (find (kw-name key) (ctype-fields c)
                          :key (lambda (f) (sym-name (first f))) :test #'string=)))))

(defun inline-field-p (ftype)
  "True for fields stored inline that have no single value: structs, unions, arrays."
  (or (and (ctype-p ftype) (member (ctype-kind ftype) '(:struct :union)))
      (equal (type-head ftype) "array")))

(defffi "%field" (p type key)
  (multiple-value-bind (ctype slot ftype) (field-access type key)
    (if (inline-field-p ftype)
        ;; A nested struct, union or array: its address, to read further.
        (from-pointer (cffi:foreign-slot-pointer (to-pointer p) ctype slot))
        (from-c ftype (cffi:foreign-slot-value (to-pointer p) ctype slot)))))
(defffi "%put-field!" (p type key value)
  (multiple-value-bind (ctype slot ftype) (field-access type key)
    (when (inline-field-p ftype)
      (ffi-error "the field ~A holds a struct, union or array; write to its parts through ~
                  the pointer that (field ...) returns" (readable-string key)))
    (setf (cffi:foreign-slot-value (to-pointer p) ctype slot) (to-c ftype value))
    value))
(defffi "c-string" (p) (and p (cffi:foreign-string-to-lisp (to-pointer p))))
(defffi "enum-value" (enum x)
  (enum-value (or (enum-ctype (resolve-type enum)) (ffi-error "~A is not an enum" enum)) x))
(defffi "handle" (obj) (make-handle obj))
(defffi "handle-value" (h)
  (multiple-value-bind (v found) (gethash h **handles**)
    (if found v (ffi-error "~A is not a live handle" (readable-string h)))))
(defffi "free-handle" (h) (remhash h **handles**) nil)
(defffi "%call-pinned" (x fn)
  (sb-sys:with-pinned-objects ((pin-targets x))
    (scall fn (to-pointer x))))
(defffi "load-library" (spec) (load-library spec))

;;; For the C backend written in Skein (M1.10): what a foreign type name stands for.

(skein.runtime:defcore "%ctype-info" (x)
  ;; [kind base name] for a C type: kind :struct, :union or :enum, base an enum's integer
  ;; type (a symbol), name the qualified name. nil for anything else.
  (if (ctype-p x)
      (skein.runtime:vector-from-list
       (list (skein.runtime:intern-kw (string-downcase (symbol-name (ctype-kind x))))
             (and (eq (ctype-kind x) :enum)
                  (skein.runtime:intern-sym (car (rassoc (ctype-cffi-name x) *primitive-ffi-types*))))
             (ctype-name x)))
      nil))
