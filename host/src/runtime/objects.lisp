;;;; The object system (DESIGN §8), built on CLOS through closer-mop.
;;;; Skein classes are instances of the metaclass SKEIN-CLASS, whose class precedence list
;;;; is computed with C3. Slots are immutable unless declared with :cell; an :atom cell
;;;; holds an atom, an :unsynchronized cell holds its value directly and may only be set by
;;;; the thread that made the instance. Generic functions are CLOS generic functions;
;;;; methods are Skein functions that receive call-next-method and next-method? first.

(in-package #:skein.runtime)

(defpackage #:skein-classes (:use)
  (:documentation "Holds the CL names of classes defined by defclass."))
(defpackage #:skein-slots (:use)
  (:documentation "Holds the CL names of slots of Skein classes."))
(defpackage #:skein-generics (:use)
  (:documentation "Holds the CL names of generic functions defined in Skein."))

(define-condition no-method-error (skein-error) ()
  (:documentation "Signaled when no method of a generic function applies to the arguments."))

(define-condition slot-error (skein-error) ()
  (:documentation "Signaled for a missing slot, or for setting a slot that cannot be set."))

(defun slot-symbol (name)
  "Return the CL symbol for the Skein slot NAME (a string)."
  (intern name '#:skein-slots))

;;; ------------------------------------------------------------------------------------
;;; The metaclass and slot definitions

(defclass skein-class (standard-class)
  ((skein-name :initarg :skein-name :initform nil :accessor class-skein-name)
   ;; Slot name -> cell kind before the latest redefinition, for migrating instances.
   (previous-cells :initform (make-hash-table :test 'equal) :accessor class-previous-cells))
  (:documentation "The metaclass of classes defined with defclass."))

(defmethod c2mop:validate-superclass ((class skein-class) (super standard-class)) t)

(defclass skein-direct-slot (c2mop:standard-direct-slot-definition)
  ((cell :initarg :cell :initform nil :reader slot-cell)
   (skein-type :initarg :skein-type :initform nil :reader slot-skein-type)
   (init :initarg :init :initform nil :reader slot-init))
  (:documentation "A slot as written in defclass: its cell kind, :type and :init function."))

(defclass skein-effective-slot (c2mop:standard-effective-slot-definition)
  ((cell :initform nil :accessor slot-cell)
   (skein-type :initform nil :accessor slot-skein-type)
   (init :initform nil :accessor slot-init))
  (:documentation "A slot of a finalized Skein class."))

(defmethod c2mop:direct-slot-definition-class ((class skein-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'skein-direct-slot))

(defmethod c2mop:effective-slot-definition-class ((class skein-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'skein-effective-slot))

(defmethod c2mop:compute-effective-slot-definition ((class skein-class) name direct-slots)
  (let ((slot (call-next-method))
        (direct (find-if (lambda (d) (typep d 'skein-direct-slot)) direct-slots)))
    (when (and direct (typep slot 'skein-effective-slot))
      (setf (slot-cell slot) (slot-cell direct)
            (slot-skein-type slot) (slot-skein-type direct)
            (slot-init slot) (slot-init direct)))
    slot))

;;; C3 linearization (DESIGN §8.1)

(defun c3-merge (sequences class)
  (let ((result '()))
    (loop
      (setf sequences (remove nil sequences))
      (when (null sequences) (return (nreverse result)))
      (let ((candidate
              (loop for seq in sequences
                    for head = (first seq)
                    unless (some (lambda (s) (member head (rest s))) sequences)
                      return head)))
        (unless candidate
          (skein-error 'skein-error nil "the superclasses of ~A have no consistent order (C3)"
                       (or (class-skein-name class) (class-name class))))
        (push candidate result)
        (setf sequences (mapcar (lambda (s) (if (eq (first s) candidate) (rest s) s))
                                sequences))))))

(defmethod c2mop:compute-class-precedence-list ((class skein-class))
  (let ((supers (c2mop:class-direct-superclasses class)))
    (cons class
          (c3-merge (append (mapcar (lambda (s)
                                      (c2mop:ensure-finalized s)
                                      (c2mop:class-precedence-list s))
                                    supers)
                            (list supers))
                    class))))

;;; The root of every Skein class. OWNER is the thread allowed to set :unsynchronized
;;; cells; it is a CL slot, not a Skein one, so Skein code never sees it.

(defclass skein-object ()
  ((owner :initform nil :accessor object-owner))
  (:metaclass skein-class)
  (:documentation "The superclass of every class defined with defclass."))

(defun instance-p (x)
  "Return true if X is an instance of a class defined with defclass."
  (typep x 'skein-object))

(defun skein-slots (class)
  "Return the effective slots of CLASS that Skein code can see."
  (c2mop:ensure-finalized class)
  (remove-if-not (lambda (s) (eq (symbol-package (c2mop:slot-definition-name s))
                                 (find-package '#:skein-slots)))
                 (c2mop:class-slots class)))

(defun find-skein-slot (class name)
  (find (slot-symbol name) (skein-slots class) :key #'c2mop:slot-definition-name))

(defun slot-name-string (slot) (symbol-name (c2mop:slot-definition-name slot)))

(defun skein-class-name (class)
  "Return the qualified name of CLASS as a string."
  (if (typep class 'skein-class)
      (or (class-skein-name class) (string-downcase (symbol-name (class-name class))))
      (string-downcase (symbol-name (class-name class)))))

;;; ------------------------------------------------------------------------------------
;;; Defining classes

(defun stored-value (cell value)
  "The representation of VALUE in a slot whose cell kind is CELL."
  (if (eq cell :atom) (make-skein-atom value) value))

(defun cell-keyword (x)
  (cond ((null x) nil)
        ((and (kw-p x) (string= (kw-name x) "atom")) :atom)
        ((and (kw-p x) (string= (kw-name x) "unsynchronized")) :unsynchronized)
        ((and (kw-p x) (string= (kw-name x) "ref"))
         (skein-error 'skein-error nil ":cell :ref is reserved and not supported yet"))
        (t (skein-error 'skein-error nil ":cell must be :atom or :unsynchronized, not ~A"
                        (readable-string x)))))

(defun define-skein-class (name supers slots)
  "Create or redefine the class NAME (a qualified symbol) with superclasses SUPERS (class
objects) and SLOTS, a list of (name-symbol cell init-fn type)."
  (let* ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name)))
         (cl-name (intern qualified '#:skein-classes))
         (old (find-class cl-name nil)))
    (dolist (s supers)
      (unless (or (typep s 'skein-class) (eq s (find-class 'standard-object)))
        (skein-error 'skein-error nil "~A cannot be a superclass of ~A; only classes ~
                                       defined with defclass can"
                     (skein-class-name s) qualified)))
    (when (and old (typep old 'skein-class))
      (let ((previous (make-hash-table :test 'equal)))
        (dolist (s (skein-slots old))
          (setf (gethash (slot-name-string s) previous) (slot-cell s)))
        (setf (class-previous-cells old) previous)))
    (c2mop:ensure-class
     cl-name
     :metaclass 'skein-class
     :skein-name qualified
     :direct-superclasses (or supers (list (find-class 'skein-object)))
     :direct-slots
     (loop for (slot-name cell init type) in slots
           collect (let ((cell (cell-keyword cell))
                         (init init))
                     (list :name (slot-symbol (sym-name slot-name))
                           :initform nil
                           :initfunction (lambda ()
                                           (stored-value cell (and init (scall init))))
                           :cell cell :init init :skein-type type))))
    (let ((class (find-class cl-name)))
      (c2mop:finalize-inheritance class)
      ;; CLOS only updates instances when the slot layout changes. A slot that switched
      ;; between immutable and :atom also needs its value wrapped or unwrapped.
      (when (and old (typep old 'skein-class)
                 (loop for s in (skein-slots class)
                       for (before present) = (multiple-value-list
                                               (gethash (slot-name-string s)
                                                        (class-previous-cells class)))
                       thereis (and present (not (eq before (slot-cell s))))))
        (make-instances-obsolete class))
      class)))

;;; ------------------------------------------------------------------------------------
;;; Instances: make, with, slot access

(defun resolve-instance-class (x)
  (let ((class (if (sym-p x) (find-skein-class x) x)))
    (unless (typep class 'skein-class)
      (skein-error 'skein-error nil "~A is not a class defined with defclass" (readable-string x)))
    class))

(defun slot-not-found (class key)
  (error 'slot-error :location nil
                     :message (format nil "~A has no slot ~A" (skein-class-name class)
                                      (readable-string key))))

(defun check-initargs (class kvs)
  (when (oddp (length kvs))
    (skein-error 'skein-error nil "make and with need keys and values in pairs"))
  (loop for (k) on kvs by #'cddr
        unless (and (kw-p k) (find-skein-slot class (kw-name k)))
          do (slot-not-found class k)))

(defun make-object (class-designator kvs)
  "Make an instance of a Skein class from the keyword/value list KVS, then call the
generic function initialize on it."
  (let ((class (resolve-instance-class class-designator)))
    (c2mop:ensure-finalized class)
    (check-initargs class kvs)
    (let ((obj (allocate-instance class)))
      (dolist (slot (skein-slots class))
        (let* ((key (intern-kw (slot-name-string slot)))
               (given (loop for (k v) on kvs by #'cddr when (eq k key) return (list v))))
          (setf (slot-value obj (c2mop:slot-definition-name slot))
                (if given
                    (stored-value (slot-cell slot) (first given))
                    (funcall (c2mop:slot-definition-initfunction slot))))))
      (setf (object-owner obj) sb-thread:*current-thread*)
      (funcall (core-fn "initialize") obj)
      obj)))

(defun with-object (obj kvs)
  "Return a copy of OBJ with the slots in KVS changed. Cells are shared with OBJ unless
KVS contains :fresh-cells true; a changed cell slot gets a fresh cell."
  (unless (instance-p obj)
    (skein-error 'skein-error nil "with needs an instance, not ~A" (readable-string obj)))
  (let* ((fresh-key (intern-kw "fresh-cells"))
         (fresh (loop for (k v) on kvs by #'cddr thereis (and (eq k fresh-key) (truthy-p v))))
         (kvs (loop for (k v) on kvs by #'cddr unless (eq k fresh-key) append (list k v)))
         (class (class-of obj))
         (copy (allocate-instance class)))
    (check-initargs class kvs)
    (dolist (slot (skein-slots class))
      (let* ((name (c2mop:slot-definition-name slot))
             (key (intern-kw (slot-name-string slot)))
             (value (slot-value obj name))
             (given (loop for (k v) on kvs by #'cddr when (eq k key) return (list v))))
        (setf (slot-value copy name)
              (cond (given (stored-value (slot-cell slot) (first given)))
                    ((and fresh (eq (slot-cell slot) :atom))
                     (make-skein-atom (skein-atom-value value)))
                    (t value)))))
    (setf (object-owner copy) sb-thread:*current-thread*)
    copy))

(defun object-get (obj key not-found)
  "Read the slot named by the keyword KEY, or return NOT-FOUND. A cell slot gives its cell."
  (let ((slot (and (kw-p key) (find-skein-slot (class-of obj) (kw-name key)))))
    (if slot (slot-value obj (c2mop:slot-definition-name slot)) not-found)))

(defun set-object-slot (obj key value)
  "Set an :unsynchronized cell slot of OBJ (set! on (:slot obj))."
  (unless (instance-p obj)
    (skein-error 'skein-error nil "set! of ~A needs an instance, not ~A"
                 (readable-string key) (readable-string obj)))
  (let* ((class (class-of obj))
         (slot (or (and (kw-p key) (find-skein-slot class (kw-name key)))
                   (slot-not-found class key))))
    (case (slot-cell slot)
      ((nil) (error 'slot-error :location nil
                                :message (format nil "slot ~A of ~A is immutable; use with to ~
                                                      make a changed copy"
                                                 (readable-string key) (skein-class-name class))))
      (:atom (error 'slot-error :location nil
                                :message (format nil "slot ~A of ~A is an atom; use reset! or ~
                                                      swap! on it"
                                                 (readable-string key) (skein-class-name class))))
      (:unsynchronized
       (unless (eq (object-owner obj) sb-thread:*current-thread*)
         (error 'slot-error :location nil
                            :message (format nil "slot ~A of ~A is :unsynchronized and owned by ~
                                                  another thread"
                                             (readable-string key) (skein-class-name class))))
       (setf (slot-value obj (c2mop:slot-definition-name slot)) value)))))

(defun object-keys (obj)
  (list-from-cl (mapcar (lambda (s) (intern-kw (slot-name-string s)))
                        (skein-slots (class-of obj)))))

;;; ------------------------------------------------------------------------------------
;;; Redefinition (DESIGN §8.4)

(defmethod update-instance-for-redefined-class :after
    ((obj skein-object) added discarded plist &rest initargs)
  (declare (ignore initargs))
  (let* ((class (class-of obj))
         (previous (class-previous-cells class)))
    ;; Wrap or unwrap values whose slot changed between immutable and :atom.
    (dolist (slot (skein-slots class))
      (let ((name (c2mop:slot-definition-name slot)))
        (unless (member name added)
          (let ((old (gethash (symbol-name name) previous))
                (new (slot-cell slot))
                (value (slot-value obj name)))
            (cond ((and (eq new :atom) (not (eq old :atom)))
                   (setf (slot-value obj name) (make-skein-atom value)))
                  ((and (eq old :atom) (not (eq new :atom)) (skein-atom-p value))
                   (setf (slot-value obj name) (skein-atom-value value))))))))
    (flet ((keys (names)
             (vector-from-list (loop for n in names
                                     when (eq (symbol-package n) (find-package '#:skein-slots))
                                       collect (intern-kw (symbol-name n))))))
      (funcall (core-fn "update-instance-for-redefined-class")
               obj (keys added) (keys discarded)
               (map-from-pairs (loop for (n v) on plist by #'cddr
                                     when (eq (symbol-package n) (find-package '#:skein-slots))
                                       append (list (intern-kw (symbol-name n)) v)))))))

;;; ------------------------------------------------------------------------------------
;;; Classes by name, for defmethod specializers and make

(defparameter *builtin-classes*
  '(("any" . t) ("object" . skein-object) ("nil-class" . null) ("integer" . integer)
    ("float" . float) ("f32" . single-float) ("f64" . double-float) ("number" . real)
    ("char" . character) ("string" . string) ("keyword" . kw) ("symbol" . sym)
    ("vector" . pvector) ("hash-map" . skein-map) ("hash-set" . hash-set)
    ("list" . skein-list) ("seq" . skein-seq) ("fn" . function) ("atom" . skein-atom)
    ("condition" . condition) ("error" . error) ("warning" . warning))
  "Skein names for host classes that methods can specialize on (DESIGN §8.3).")

(defun find-skein-class (x &optional (namespace-name (namespace-name *current-namespace*)))
  "Return the class that X names. X may be a class or a symbol: one of the built-in class
names, or a var (in NAMESPACE-NAME) holding a class or a condition type."
  (flet ((fail () (skein-error 'skein-error nil "~A is not a class" (readable-string x))))
    (cond ((typep x 'class) x)
          ((condition-type-p x) (find-class (condition-type-class x)))
          ((not (sym-p x)) (fail))
          (t (let ((builtin (and (null (sym-namespace x))
                                 (assoc (sym-name x) *builtin-classes* :test #'string=))))
               (if builtin
                   (find-class (cdr builtin))
                   (let* ((ns (find-namespace namespace-name))
                          (var (and ns (if (sym-namespace x)
                                           (let ((target (or (find-alias ns (sym-namespace x))
                                                             (find-namespace (sym-namespace x)))))
                                             (and target (find-own-var target (sym-name x))))
                                           (resolve-var ns (sym-name x)))))
                          (value (and var (var-value var))))
                     (cond ((typep value 'class) value)
                           ((condition-type-p value) (find-class (condition-type-class value)))
                           (t (fail))))))))))

;;; ------------------------------------------------------------------------------------
;;; Generic functions

(defclass skein-generic (standard-generic-function)
  ((skein-name :initarg :skein-name :initform nil :accessor generic-skein-name)
   (required :initarg :required :initform 0 :accessor generic-required)
   (rest-p :initarg :rest-p :initform nil :accessor generic-rest-p))
  (:metaclass c2mop:funcallable-standard-class)
  (:documentation "A generic function defined in Skein."))

(defmethod no-applicable-method ((gf skein-generic) &rest args)
  (error 'no-method-error
         :location nil
         :message (format nil "no method of ~A applies to ~A" (generic-skein-name gf)
                          (readable-string (list-from-cl args)))))

(defun generic-lambda-list (required rest-p)
  (append (loop for i below required collect (intern (format nil "ARG~D" i) '#:skein-generics))
          (and rest-p (list '&rest (intern "MORE" '#:skein-generics)))))

(defun make-skein-generic (qualified required rest-p)
  "Create (or return the existing) generic function named QUALIFIED with REQUIRED
required parameters and optionally a rest parameter."
  (let* ((cl-name (intern qualified '#:skein-generics))
         (existing (and (fboundp cl-name) (fdefinition cl-name))))
    (if (and (typep existing 'skein-generic)
             (= (generic-required existing) required)
             (eq (generic-rest-p existing) rest-p))
        existing
        (progn
          (when (fboundp cl-name) (fmakunbound cl-name))
          (ensure-generic-function cl-name
                                   :generic-function-class 'skein-generic
                                   :lambda-list (generic-lambda-list required rest-p)
                                   :skein-name qualified :required required :rest-p rest-p)))))

(defun generic-var (name namespace-name)
  "Return the var that the symbol NAME refers to in NAMESPACE-NAME, for defmethod: an
existing var holding a generic function, or else this namespace's own var."
  (let* ((ns (or (find-namespace namespace-name) (ensure-namespace namespace-name)))
         (found (if (sym-namespace name)
                    (let ((target (or (find-alias ns (sym-namespace name))
                                      (find-namespace (sym-namespace name)))))
                      (and target (find-own-var target (sym-name name))))
                    (resolve-var ns (sym-name name)))))
    (if (and found (typep (var-value found) 'skein-generic))
        found
        (intern-var ns (sym-name name)))))

(defun define-generic (name namespace-name params)
  "defgeneric: make NAME in NAMESPACE-NAME a generic function with PARAMS (a vector of
symbols, possibly with & rest)."
  (let* ((names (vector-to-list params))
         (rest-p (find "&" names :key #'sym-name :test #'string=))
         (required (or (position "&" names :key #'sym-name :test #'string=) (length names)))
         (var (intern-var (find-namespace namespace-name) (sym-name name)))
         (gf (make-skein-generic (format nil "~A/~A" namespace-name (sym-name name))
                                 required (and rest-p t))))
    (def-var var gf)
    gf))

(sb-ext:define-load-time-global **specialized-cache**
    (make-hash-table :test 'equal :synchronized t))

(defun add-skein-method (name namespace-name qualifier specializers rest-p fn)
  "defmethod: add FN as a method of the generic function NAME (resolved in
NAMESPACE-NAME), creating the generic function if needed. SPECIALIZERS has one entry per
required parameter: a class, an eql specializer, or NIL for any value. FN takes
call-next-method and next-method? before the method's own parameters."
  (let* ((var (generic-var name namespace-name))
         (required (length specializers))
         (gf (let ((value (var-value var)))
               (if (typep value 'skein-generic)
                   value
                   (let ((new (make-skein-generic (var-qualified-name var) required rest-p)))
                     (def-var var new)
                     new))))
         (args (loop for i below required collect (make-symbol (format nil "A~D" i))))
         (rest (make-symbol "REST")))
    (unless (and (= required (generic-required gf)) (eq rest-p (generic-rest-p gf)))
      (skein-error 'skein-error nil "the parameters of this method do not match the generic ~
                                     function ~A (~D required~:[~;, with a rest parameter~])"
                   (generic-skein-name gf) (generic-required gf) (generic-rest-p gf)))
    (c2mop:ensure-method
     gf
     `(lambda (,@args ,@(and rest-p `(&rest ,rest)))
        (apply ',fn
               (lambda (&rest new-args)
                 (if new-args (apply #'call-next-method new-args) (call-next-method)))
               (lambda () (if (next-method-p) t ',+false+))
               ,@args
               ,(if rest-p rest nil)))
     :qualifiers (and qualifier (list (intern (string-upcase (kw-name qualifier)) :keyword)))
     :lambda-list `(,@args ,@(and rest-p `(&rest ,rest)))
     :specializers (mapcar (lambda (s) (or s (find-class t))) specializers))
    (clrhash **specialized-cache**)
    gf))

;;; ------------------------------------------------------------------------------------
;;; equiv and hash-of for instances (DESIGN §7): identity unless specialized

(defun specialized-p (gf-name args)
  "Return true if a method of the skein.core generic GF-NAME more specific than the
default one applies to ARGS (whose first element is an instance)."
  (let ((key (cons gf-name (class-of (first args)))))
    (multiple-value-bind (value found) (gethash key **specialized-cache**)
      (if found
          value
          (setf (gethash key **specialized-cache**)
                (some (lambda (m) (not (eq (first (c2mop:method-specializers m)) (find-class t))))
                      (compute-applicable-methods (core-fn gf-name) args)))))))

(defun instance-equiv (a b)
  (and (specialized-p "equiv" (list a b))
       (truthy-p (funcall (core-fn "equiv") a b))))

(defun instance-hash (x)
  (if (specialized-p "hash-of" (list x))
      (u32 (funcall (core-fn "hash-of") x))
      (identity-hash x)))

(define-condition equiv-hash-warning (warning)
  ((message :initarg :message :reader equiv-hash-warning-message))
  (:report (lambda (c stream) (write-string (equiv-hash-warning-message c) stream)))
  (:documentation "Warns that a class specializes only one of equiv and hash-of."))

(sb-ext:define-load-time-global **equiv-hash-warned** (make-hash-table :test 'eq :synchronized t))

(defun check-equiv-hash-methods ()
  "Warn about classes that specialize equiv but not hash-of, or the reverse (DESIGN §7)."
  (flet ((classes (gf-name)
           (loop for m in (c2mop:generic-function-methods (core-fn gf-name))
                 for c = (first (c2mop:method-specializers m))
                 when (typep c 'skein-class) collect c)))
    (let ((equiv (classes "equiv")) (hash (classes "hash-of")))
      (dolist (c (set-exclusive-or equiv hash))
        (unless (gethash c **equiv-hash-warned**)
          (setf (gethash c **equiv-hash-warned**) t)
          (warn 'equiv-hash-warning
                :message (format nil "class ~A specializes ~:[hash-of~;equiv~] but not ~
                                      ~:[equiv~;hash-of~]; equal instances must hash alike"
                                 (skein-class-name c) (member c equiv) (member c equiv))))))))

;;; The built-in generic functions of skein.core.

(defun define-core-generic (name required default)
  (let ((gf (make-skein-generic (format nil "skein.core/~A" name) required nil)))
    (def-var (intern-var +core+ name) gf)
    (c2mop:ensure-method gf default :specializers (loop repeat required collect (find-class t)))
    gf))

(define-core-generic "equiv" 2 '(lambda (a b) (bool (if (instance-p a) (eq a b) (equiv a b)))))
(define-core-generic "hash-of" 1 '(lambda (x) (if (instance-p x) (identity-hash x) (hash-of x))))
(define-core-generic "initialize" 1 '(lambda (x) (declare (ignore x)) nil))
(let ((gf (make-skein-generic "skein.core/update-instance-for-redefined-class" 4 nil)))
  (def-var (intern-var +core+ "update-instance-for-redefined-class") gf)
  (c2mop:ensure-method gf '(lambda (obj added discarded old)
                            (declare (ignore obj added discarded old))
                            nil)
                       :specializers (loop repeat 4 collect (find-class t))))

;;; ------------------------------------------------------------------------------------
;;; skein.core functions

(defcore "make" (class &rest kvs) (make-object class kvs))
(defcore "with" (obj &rest kvs) (with-object obj kvs))
(defcore "slot" (obj key &optional (not-found nil not-found-p))
  (let ((v (object-get obj key +not-found+)))
    (cond ((not (eq v +not-found+)) v)
          (not-found-p not-found)
          (t (slot-not-found (class-of obj) key)))))
(defcore "%set-slot!" (obj key value) (set-object-slot obj key value))
(defcore "instance?" (class x) (bool (typep x (find-skein-class class))))
(defcore "class-of" (x) (class-of x))
(defcore "class-name" (class)
  (let* ((name (skein-class-name (find-skein-class class)))
         (slash (position #\/ name)))
    (if slash (intern-sym (subseq name (1+ slash)) (subseq name 0 slash)) (intern-sym name))))
(defcore "class-slots" (class)
  (vector-from-list (mapcar (lambda (s) (intern-kw (slot-name-string s)))
                            (skein-slots (find-skein-class class)))))
(defcore "class-precedence-list" (class)
  (let ((class (find-skein-class class)))
    (c2mop:ensure-finalized class)
    (list-from-cl (c2mop:class-precedence-list class))))
(defcore "generic-methods" (gf)
  (list-from-cl
   (mapcar (lambda (m)
             (vector-from-list
              (list (vector-from-list (mapcar (lambda (q)
                                                (intern-kw (string-downcase (symbol-name q))))
                                              (method-qualifiers m)))
                    (vector-from-list (mapcar (lambda (s)
                                                (if (typep s 'c2mop:eql-specializer)
                                                    (list-from-cl
                                                     (list (intern-sym "=")
                                                           (c2mop:eql-specializer-object s)))
                                                    s))
                                              (c2mop:method-specializers m))))))
           (c2mop:generic-function-methods gf))))

(defcore "%define-class" (name supers slots)
  (define-skein-class name (seq-to-cl supers)
    (mapcar (lambda (v) (vector-to-list v)) (seq-to-cl slots))))
(defcore "%class" (name namespace-name) (find-skein-class name namespace-name))
(defcore "%eql-specializer" (value) (c2mop:intern-eql-specializer value))
(defcore "%define-generic" (name namespace-name params) (define-generic name namespace-name params))
(defcore "%define-method" (name namespace-name qualifier specializers rest-p fn)
  (add-skein-method name namespace-name qualifier (seq-to-cl specializers) (truthy-p rest-p) fn))
