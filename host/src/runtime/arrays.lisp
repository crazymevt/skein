;;;; Typed arrays (DESIGN §9.2, §9.3). An array of a primitive type is a CL specialized
;;;; vector, so declared code compiles to plain AREF. Arrays of value structs are
;;;; STRUCT-ARRAYs (structs.lisp).

(in-package #:skein.runtime)

(defparameter *array-element-types*
  '(("i8" . (signed-byte 8)) ("i16" . (signed-byte 16)) ("i32" . (signed-byte 32))
    ("i64" . (signed-byte 64)) ("u8" . (unsigned-byte 8)) ("u16" . (unsigned-byte 16))
    ("u32" . (unsigned-byte 32)) ("u64" . (unsigned-byte 64)) ("f32" . single-float)
    ("f64" . double-float) ("fixnum" . fixnum) ("char" . character))
  "Skein element types stored unboxed, and their CL element types.")

(defun primitive-element-type (type)
  "Return the CL element type for the Skein element type TYPE (a symbol), or NIL if it is
not a primitive type."
  (and (sym-p type) (null (sym-namespace type))
       (cdr (assoc (sym-name type) *array-element-types* :test #'string=))))

(defun zero-of (cl-type)
  (cond ((subtypep cl-type 'double-float) 0d0)
        ((subtypep cl-type 'single-float) 0f0)
        ((subtypep cl-type 'integer) 0)
        ((subtypep cl-type 'character) (code-char 0))
        (t nil)))

(defun skein-element-name (cl-type)
  (or (car (rassoc cl-type *array-element-types* :test #'equal)) "any"))

(defun make-typed-array (type n)
  "Make a zero-initialized array of N elements of the Skein type TYPE: a primitive type,
a value-struct type, or any."
  (unless (typep n '(integer 0))
    (skein-error 'skein-error nil "make-array needs a non-negative length, not ~A"
                 (readable-string n)))
  (let ((et (primitive-element-type type)))
    (cond (et (make-array n :element-type et :initial-element (zero-of et)))
          ((and (sym-p type) (null (sym-namespace type))
                (member (sym-name type) '("any" "bool" "keyword" "symbol" "string")
                        :test #'string=))
           (make-array n :initial-element nil))
          (t (let ((def (find-struct-def type)))
               (cond ((and def (struct-def-value-p def)) (make-struct-array def n))
                     ;; Any other known type (a record, class or other named type) is
                     ;; stored boxed.
                     ((handler-case (skein-type-to-cl type) (skein-error () nil))
                      (make-array n :initial-element nil))
                     (t (skein-error 'skein-error nil "unknown array element type ~A"
                                     (readable-string type)))))))))

(defun array-like-p (x)
  "Return true if X is a Skein array: a CL vector (not a string) or a struct array."
  (or (and (vectorp x) (not (stringp x))) (struct-array-p x)))

(defun aget-slow (a i)
  (cond ((arrayp a) (aref a i))
        ((struct-array-p a) (struct-array-get a i))
        (t (unsupported "aget needs an array, not ~A" (readable-string a)))))

(defun aset-slow (a i v)
  (cond ((arrayp a) (setf (aref a i) v))
        ((struct-array-p a) (struct-array-set a i v) v)
        (t (unsupported "aset! needs an array, not ~A" (readable-string a)))))

(defun array-view (a start end)
  "A zero-copy slice of the primitive array A from START (inclusive) to END (exclusive)."
  (unless (and (vectorp a) (not (stringp a)))
    (unsupported "view needs an array of a primitive type, not ~A" (readable-string a)))
  (unless (and (integerp start) (integerp end) (<= 0 start end (length a)))
    (error 'index-error :location nil
                        :message (format nil "view ~A to ~A is out of bounds for an array of ~D"
                                         start end (length a))))
  (make-array (- end start) :element-type (array-element-type a)
                            :displaced-to a :displaced-index-offset start))

(defun array-element-bytes (a)
  "The size in bytes of one element of the specialized array A, or NIL if its elements
are not stored as plain numbers."
  (let ((et (array-element-type a)))
    (cond ((subtypep et 'double-float) 8)
          ((subtypep et 'single-float) 4)
          ((subtypep et '(unsigned-byte 8)) 1)
          ((subtypep et '(signed-byte 8)) 1)
          ((subtypep et '(unsigned-byte 16)) 2)
          ((subtypep et '(signed-byte 16)) 2)
          ((subtypep et '(unsigned-byte 32)) 4)
          ((subtypep et '(signed-byte 32)) 4)
          ((subtypep et '(unsigned-byte 64)) 8)
          ((subtypep et '(signed-byte 64)) 8)
          (t nil))))

(defun as-bytes (a)
  "A byte view of the primitive array A for passing to C or GPU APIs (DESIGN §9.3)."
  (unless (and (vectorp a) (not (stringp a)) (array-element-bytes a))
    (unsupported "as-bytes needs an array of a numeric type, not ~A" (readable-string a)))
  (make-byte-view a))

(defcore "%make-array" (type n) (make-typed-array type n))
(defcore "as-bytes" (a) (as-bytes a))
(defcore "aget" (a i) (skein-aget a i))
(defcore "aset!" (a i v) (skein-aset a i v))
(defcore "array?" (x) (bool (array-like-p x)))
(defcore "view" (a start &optional end) (array-view a start (or end (length a))))
(defcore "sqrt" (x) (skein-sqrt x))

(register-core-inlines)
