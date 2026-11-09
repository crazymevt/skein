;;;; defstruct (value structs and plain records), arrays of value structs, update! and
;;;; defsoa (DESIGN §9). Both kinds of struct are CL structs with typed, read-only slots;
;;;; both compare by their fields (D-036). An array of value structs keeps one specialized
;;;; CL array per primitive field, so its elements are stored inline.

(in-package #:skein.runtime)

(defpackage #:skein-structs (:use)
  (:documentation "Holds the CL names of struct types, constructors and accessors."))

(sb-ext:define-load-time-global **struct-defs** (make-hash-table :test 'equal :synchronized t))
(sb-ext:define-load-time-global **struct-defs-by-type** (make-hash-table :test 'eq :synchronized t))
(sb-ext:define-load-time-global **struct-defs-by-value**
    (make-hash-table :test 'eq :synchronized t :weakness :key))
(sb-ext:define-load-time-global **soa-defs** (make-hash-table :test 'eq :synchronized t))

(define-condition struct-redefinition-warning (warning)
  ((message :initarg :message :reader struct-redefinition-warning-message))
  (:report (lambda (c stream) (write-string (struct-redefinition-warning-message c) stream)))
  (:documentation "Warns that a struct's fields changed, so values and compiled code made
with the old layout keep using it."))

(defun struct-instance-def (x)
  "Return the struct-def of X if it is a value struct or record, else NIL."
  (and (typep x 'structure-object) (gethash (type-of x) **struct-defs-by-type**)))

(defun find-struct-def (x &optional (namespace-name (namespace-name *current-namespace*)))
  "Return the struct-def that X names: a struct-def, or a symbol whose var holds a
struct's constructor or a defsoa type. Returns NIL if there is none."
  (cond ((struct-def-p x) x)
        ((sym-p x)
         (let* ((ns (find-namespace namespace-name))
                (var (and ns (if (sym-namespace x)
                                 (let ((target (or (find-alias ns (sym-namespace x))
                                                   (find-namespace (sym-namespace x)))))
                                   (and target (find-own-var target (sym-name x))))
                                 (resolve-var ns (sym-name x)))))
                (value (and var (var-value var))))
           (cond ((struct-def-p value) value)
                 (value (gethash value **struct-defs-by-value**)))))))

(defun soa-type-p (def)
  "Return true if DEF is the element type of a defsoa collection."
  (gethash def **soa-defs**))

(defun struct-def-soa-p (def sym namespace-name)
  "Return true if SYM names the defsoa collection type of DEF (rather than the struct)."
  (declare (ignore sym namespace-name))
  (gethash def **soa-defs**))

;;; Defining structs

(defun field-cl-type (type value-p struct-name)
  (cond ((null type)
         (when value-p
           (skein-error 'skein-error nil "the fields of value struct ~A need types" struct-name))
         t)
        ((primitive-element-type type))
        (value-p
         (let ((def (find-struct-def type)))
           (unless (and def (struct-def-value-p def))
             (skein-error 'skein-error nil "a field of value struct ~A must have a primitive ~
                                            type or another value struct, not ~A"
                          struct-name (readable-string type)))
           (struct-def-cl-type def)))
        (t (skein-type-to-cl type))))

(defun compute-leaves (fields)
  "For arrays: the path to each primitive field, flattening nested value structs."
  (loop for f in fields
        append (let ((nested (find-struct-def-by-type (field-def-cl-type f))))
                 (if nested
                     (mapcar (lambda (leaf) (cons (cons f (car leaf)) (cdr leaf)))
                             (struct-def-leaves nested))
                     (list (cons (list f) (field-def-cl-type f)))))))

(defun find-struct-def-by-type (cl-type)
  (and (symbolp cl-type) (gethash cl-type **struct-defs-by-type**)))

(defun define-struct (name value-p fields &key (define-vars t))
  "Define or redefine the struct NAME (a qualified symbol). FIELDS is a list of
(field-symbol type-or-nil). Creates the var NAME holding the constructor and a var
NAME-FIELD for each accessor in the current namespace, unless DEFINE-VARS is false."
  (let* ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name)))
         (specs (loop for (fsym ftype) in fields
                      collect (list (sym-name fsym) ftype
                                    (field-cl-type ftype value-p qualified))))
         (layout (list value-p (mapcar (lambda (s) (list (first s) (third s))) specs)))
         (old (gethash qualified **struct-defs**))
         (old-layout (and old (list (struct-def-value-p old)
                                    (mapcar (lambda (f) (list (field-def-name f)
                                                              (field-def-cl-type f)))
                                            (struct-def-fields old)))))
         (def (if (and old (equal layout old-layout))
                  old
                  (build-struct-def qualified value-p specs old))))
    (when (and old (not (eq def old)))
      (warn 'struct-redefinition-warning
            :message (format nil "the fields of ~A changed; existing values and code compiled ~
                                  against the old fields keep using them until reloaded"
                             qualified)))
    (when define-vars (define-struct-vars def (sym-name name)))
    def))

(defun build-struct-def (qualified value-p specs old)
  (let* ((version (if old (1+ (or (get (struct-def-cl-type old) 'version) 0)) 0))
         (type-name (if (zerop version) qualified (format nil "~A#~D" qualified version)))
         (package (find-package '#:skein-structs))
         (cl-type (intern type-name package))
         (constructor (intern (format nil "make ~A" type-name) package))
         (fields (loop for (fname ftype ct) in specs
                       collect (make-field-def fname ftype ct (intern fname package)
                                               (intern (format nil "~A.~A" type-name fname)
                                                       package))))
         (def (make-struct-def qualified cl-type value-p fields)))
    (setf (get cl-type 'version) version)
    ;; The struct type must exist at run time, so it is created with EVAL (runtime code;
    ;; CLAUDE.md §4).
    (let ((*package* package))
      (eval `(defstruct (,cl-type (:constructor ,constructor
                                     ,(mapcar #'field-def-slot fields))
                                  (:copier nil) (:predicate nil)
                                  (:conc-name ,(format nil "~A." type-name)))
               ,@(loop for f in fields
                       collect `(,(field-def-slot f) ,(zero-of (field-def-cl-type f))
                                 :type ,(field-def-cl-type f) :read-only t)))))
    (setf (struct-def-constructor def) constructor
          (struct-def-leaves def) (and value-p (compute-leaves fields))
          (gethash qualified **struct-defs**) def
          (gethash cl-type **struct-defs-by-type**) def)
    def))

(defun missing-field (def f)
  (skein-error 'skein-error nil "~A needs a value for :~A"
               (struct-def-name def) (field-def-name f)))

(defun define-struct-vars (def short-name)
  (let* ((ns *current-namespace*)
         (fields (struct-def-fields def))
         (n (length fields))
         (constructor (struct-def-constructor def))
         (fn (sb-int:named-lambda short-name (&rest args)
               (cond ((= (length args) n) (apply constructor args))
                     ((and (= (length args) (* 2 n)) (plusp n) (kw-p (first args)))
                      (apply constructor
                             (loop for f in fields
                                   collect (loop for (k v) on args by #'cddr
                                                 when (and (kw-p k)
                                                           (string= (kw-name k) (field-def-name f)))
                                                   return v
                                                 finally (missing-field def f)))))
                     (t (skein-error 'arity-error nil "~A takes ~D field value~:P, or each field ~
                                                       as :name value"
                                     (struct-def-name def) n)))))
         (var (intern-var ns short-name)))
    (def-var var fn)
    (setf (gethash fn **struct-defs-by-value**) def)
    (register-inline var (lambda (&rest args) `(,constructor ,@args)) n n)
    (dolist (f fields)
      (let* ((accessor (field-def-accessor f))
             (cl-type (struct-def-cl-type def))
             (avar (intern-var ns (format nil "~A-~A" short-name (field-def-name f)))))
        (def-var avar (let ((accessor accessor))
                        (sb-int:named-lambda (format nil "~A-~A" short-name (field-def-name f))
                            (x)
                          (funcall accessor x))))
        (register-inline avar (let ((accessor accessor))
                                (lambda (x) `(,accessor (the ,cl-type ,x))))
                         1 1)))))

;;; Struct values: fields, equality, hashing, with

(defun struct-field (x def name)
  (let ((f (find name (struct-def-fields def) :key #'field-def-name :test #'string=)))
    (and f (values (funcall (field-def-accessor f) x) t))))

(defun struct-get (x key not-found)
  (let ((def (struct-instance-def x)))
    (if (and def (kw-p key))
        (multiple-value-bind (value found) (struct-field x def (kw-name key))
          (if found value not-found))
        not-found)))

(defun struct-keys (x)
  (list-from-cl (mapcar (lambda (f) (intern-kw (field-def-name f)))
                        (struct-def-fields (struct-instance-def x)))))

(defun struct-equiv (a b)
  (let ((def (struct-instance-def a)))
    (and (eq (type-of a) (type-of b))
         (every (lambda (f) (equiv (funcall (field-def-accessor f) a)
                                   (funcall (field-def-accessor f) b)))
                (struct-def-fields def)))))

(defun struct-hash (x)
  (let ((h (string-hash32 (struct-def-name (struct-instance-def x)))))
    (dolist (f (struct-def-fields (struct-instance-def x)) (mix32 h))
      (setf h (u32 (+ (* 31 h) (hash-of (funcall (field-def-accessor f) x))))))))

(defun struct-with (x kvs)
  (let ((def (struct-instance-def x)))
    (loop for (k) on kvs by #'cddr
          unless (and (kw-p k) (struct-field x def (kw-name k)))
            do (error 'slot-error :location nil
                                  :message (format nil "~A has no field ~A" (struct-def-name def)
                                                   (readable-string k))))
    (apply (struct-def-constructor def)
           (loop for f in (struct-def-fields def)
                 collect (loop for (k v) on kvs by #'cddr
                               when (string= (kw-name k) (field-def-name f)) return v
                               finally (return (funcall (field-def-accessor f) x)))))))

;;; Arrays of value structs

(defun make-struct-array (def n)
  (make-struct-array* def n
                      (coerce (loop for (nil . ct) in (struct-def-leaves def)
                                    collect (make-array n :element-type ct
                                                          :initial-element (zero-of ct)))
                              'simple-vector)))

(defun check-index (a i)
  (unless (and (integerp i) (< -1 i (struct-array-count a)))
    (error 'index-error :location nil
                        :message (format nil "index ~A is out of bounds for an array of ~D"
                                         i (struct-array-count a)))))

(defun build-struct (def columns start i)
  "Rebuild a value of DEF from COLUMNS at index I, starting at column START. Returns the
value and the next column."
  (let ((column start))
    (values (apply (struct-def-constructor def)
                   (loop for f in (struct-def-fields def)
                         collect (let ((nested (find-struct-def-by-type (field-def-cl-type f))))
                                   (if nested
                                       (multiple-value-bind (v next)
                                           (build-struct nested columns column i)
                                         (setf column next)
                                         v)
                                       (prog1 (aref (svref columns column) i)
                                         (incf column))))))
            column)))

(defun store-struct (def columns start i value)
  (unless (typep value (struct-def-cl-type def))
    (unsupported "expected a ~A, not ~A" (struct-def-name def) (readable-string value)))
  (let ((column start))
    (dolist (f (struct-def-fields def) column)
      (let ((v (funcall (field-def-accessor f) value))
            (nested (find-struct-def-by-type (field-def-cl-type f))))
        (if nested
            (setf column (store-struct nested columns column i v))
            (progn (setf (aref (svref columns column) i) v)
                   (incf column)))))))

(defun struct-array-get (a i)
  (check-index a i)
  (values (build-struct (struct-array-def a) (struct-array-columns a) 0 i)))

(defun struct-array-set (a i value)
  (check-index a i)
  (store-struct (struct-array-def a) (struct-array-columns a) 0 i value)
  value)

(defun field-column (def name)
  "Return the field NAME of DEF and the index of its first column."
  (let ((column 0))
    (dolist (f (struct-def-fields def)
               (unsupported "~A has no field ~A" (struct-def-name def) name))
      (when (string= (field-def-name f) name) (return (values f column)))
      (let ((nested (find-struct-def-by-type (field-def-cl-type f))))
        (incf column (if nested (length (struct-def-leaves nested)) 1))))))

(defun struct-array-field (a i name)
  (check-index a i)
  (multiple-value-bind (f column) (field-column (struct-array-def a) name)
    (let ((nested (find-struct-def-by-type (field-def-cl-type f))))
      (if nested
          (values (build-struct nested (struct-array-columns a) column i))
          (aref (svref (struct-array-columns a) column) i)))))

(defun set-struct-array-field (a i name value)
  (check-index a i)
  (multiple-value-bind (f column) (field-column (struct-array-def a) name)
    (let ((nested (find-struct-def-by-type (field-def-cl-type f))))
      (if nested
          (store-struct nested (struct-array-columns a) column i value)
          (setf (aref (svref (struct-array-columns a) column) i) value))
      value)))

(defun update-in-place (coll i args)
  "update!: (update! array i f args...) or, for arrays of value structs and defsoa
collections, (update! coll i :field f args...). Returns the new value."
  (cond ((struct-array-p coll)
         (destructuring-bind (key f &rest more) args
           (unless (kw-p key)
             (unsupported "update! on an array of structs needs a field keyword, not ~A"
                          (readable-string key)))
           (set-struct-array-field coll i (kw-name key)
                                   (skein-apply f (cons (struct-array-field coll i (kw-name key))
                                                        more)))))
        ((and (arrayp coll) (not (stringp coll)))
         (destructuring-bind (f &rest more) args
           (setf (aref coll i) (skein-apply f (cons (aref coll i) more)))))
        (t (unsupported "update! needs an array, not ~A" (readable-string coll)))))

;;; defsoa: a struct-of-arrays collection type (DESIGN §9.2)

(defun define-soa (name fields)
  "Define the defsoa type NAME: an element value struct NAME.element with FIELDS, the var
NAME holding the type, make-NAME, and a function per field taking (collection index)."
  (let* ((element (define-struct (intern-sym (format nil "~A.element" (sym-name name))
                                             (sym-namespace name))
                                 t fields :define-vars nil))
         (ns *current-namespace*)
         (short (sym-name name)))
    (setf (gethash element **soa-defs**) t)
    (def-var (intern-var ns short) element)
    (def-var (intern-var ns (format nil "make-~A" short))
             (sb-int:named-lambda (format nil "make-~A" short) (n) (make-struct-array element n)))
    (dolist (f (struct-def-fields element))
      (let ((fname (field-def-name f)))
        (def-var (intern-var ns fname)
                 (sb-int:named-lambda fname (coll i)
                   (unless (and (struct-array-p coll) (eq (struct-array-def coll) element))
                     (unsupported "~A needs a ~A collection, not ~A" fname short
                                  (readable-string coll)))
                   (struct-array-field coll i fname)))))
    element))

;;; skein.core functions

(defcore "%define-struct" (name value-p fields)
  (define-struct name (truthy-p value-p)
    (mapcar (lambda (v) (let ((items (vector-to-list v)))
                          (list (first items) (second items))))
            (seq-to-cl fields)))
  nil)
(defcore "%define-soa" (name fields)
  (define-soa name (mapcar (lambda (v) (let ((items (vector-to-list v)))
                                         (list (first items) (second items))))
                           (seq-to-cl fields)))
  nil)
(defcore "update!" (coll i &rest args) (update-in-place coll i args))
(defcore "struct?" (x) (bool (struct-instance-def x)))
