;;;; Skein type specifiers (DESIGN §12.1) and their CL equivalents.

(in-package #:skein.runtime)

(defparameter *scalar-types*
  '(("any" . t) ("bool" . (or (eql t) false-value)) ("char" . character) ("string" . string)
    ("keyword" . kw) ("symbol" . sym) ("vector" . pvector) ("hash-map" . skein-map)
    ("hash-set" . hash-set) ("list" . skein-list) ("seq" . (or null skein-seq))
    ("fixnum" . fixnum) ("integer" . integer) ("number" . real) ("float" . float)
    ("fn" . function) ("atom" . skein-atom) ("nil-class" . null) ("object" . skein-object))
  "Skein scalar and collection type names and their CL types.")

(defun type-error-for (type)
  (skein-error 'skein-error nil "unknown type ~A" (readable-string type)))

(defun named-type (sym namespace-name)
  "The CL type for a type name SYM: a primitive, a built-in name, a class, a condition
type or a struct type."
  (let ((name (and (null (sym-namespace sym)) (sym-name sym))))
    (or (and name (primitive-element-type sym))
        (and name (cdr (assoc name *scalar-types* :test #'string=)))
        (let ((def (find-struct-def sym namespace-name)))
          (and def (if (struct-def-soa-p def sym namespace-name) 'struct-array
                       (struct-def-cl-type def))))
        (let ((class (handler-case (find-skein-class sym namespace-name)
                       (skein-error () nil))))
          (and class (class-name class)))
        (type-error-for sym))))

(defun skein-type-to-cl (type &optional (namespace-name (namespace-name *current-namespace*)))
  "Return the CL type for the Skein type specifier TYPE (data: a symbol or a list)."
  (cond ((sym-p type) (named-type type namespace-name))
        ((and (plist-p type) (sym-p (first* type)))
         (let ((head (sym-name (first* type)))
               (args (seq-to-cl (rest* type))))
           (flet ((sub (x) (skein-type-to-cl x namespace-name)))
             (cond ((string= head "array")
                    (destructuring-bind (element &optional length) args
                      (let ((et (primitive-element-type element))
                            (def (find-struct-def element namespace-name)))
                        (cond ((and def (struct-def-value-p def)) 'struct-array)
                              (t `(simple-array ,(or et t) (,(if (integerp length) length '*))))))))
                   ((string= head "or") `(or ,@(mapcar #'sub args)))
                   ((string= head "and") `(and ,@(mapcar #'sub args)))
                   ((string= head "member") `(member ,@args))
                   ((string= head "maybe") `(or null ,(sub (first args))))
                   ((string= head "fn") 'function)
                   ((string= head "ptr") t)
                   (t (type-error-for type))))))
        (t (type-error-for type))))
