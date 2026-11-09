;;;; Conditions and restarts (DESIGN §10), built on the CL condition system.
;;;; A Skein condition type is a CONDITION-TYPE object wrapping a CL condition class;
;;;; defcondition creates the class at run time. Restarts are CL restarts whose names are
;;;; symbols in the SKEIN-RESTARTS package.

(in-package #:skein.runtime)

(defpackage #:skein-condition-classes
  (:use)
  (:documentation "Holds the CL names of condition classes created by defcondition."))

(defpackage #:skein-restarts
  (:use)
  (:documentation "Holds the CL names of restarts established by Skein code."))

(defstruct (condition-type (:constructor %make-condition-type (name class))
                           (:copier nil))
  "A Skein condition type: its qualified NAME (a string), the CL condition CLASS (a
symbol), its own SLOTS (a list of (name-string cl-symbol initform-fn)), and an optional
REPORT function of a condition that returns a string."
  (name "" :type string)
  (class nil :type symbol)
  (slots '())
  (parents '())
  (report nil))

(setf (documentation 'condition-type-p 'function)
      "Return true if the argument is a Skein condition type."
      (documentation 'condition-type-name 'function)
      "Return the qualified name of a condition type."
      (documentation 'condition-type-class 'function)
      "Return the CL class name behind a condition type.")

(defmethod print-object ((x condition-type) stream)
  (print-unreadable-object (x stream)
    (format stream "condition-type ~A" (condition-type-name x))))

;;; The registry: qualified name -> type, and CL class name -> type.

(sb-ext:define-load-time-global **condition-types** (make-hash-table :test 'equal :synchronized t))
(sb-ext:define-load-time-global **types-by-class** (make-hash-table :test 'eq :synchronized t))

(defun register-condition-type (type)
  (setf (gethash (condition-type-name type) **condition-types**) type
        (gethash (condition-type-class type) **types-by-class**) type))

(define-condition skein-condition (condition)
  ((message :initarg :message :reader skein-condition-message))
  (:report (lambda (c stream) (write-string (skein-condition-message c) stream)))
  (:documentation "A condition made by (signal \"message\" ...); not an error."))

(define-condition skein-warning (warning)
  ((message :initarg :message :reader skein-warning-message))
  (:report (lambda (c stream) (write-string (skein-warning-message c) stream)))
  (:documentation "A warning made by (warn \"message\" ...)."))

(defparameter *builtin-condition-types*
  ;; Skein name, CL class, and whether a skein.core var names the type. condition, error
  ;; and warning have no vars because error and warn are functions.
  '(("condition" condition nil) ("error" error nil) ("warning" warning nil)
    ("arithmetic-error" arithmetic-error t) ("type-error" type-error t)
    ("index-error" index-error t) ("arity-error" arity-error t)
    ("unbound-var-error" unbound-var-error t) ("not-callable-error" not-callable-error t)
    ("unsupported-operation-error" unsupported-operation-error t)
    ("transient-error" transient-error t) ("namespace-error" namespace-error t)))

(dolist (entry *builtin-condition-types*)
  (destructuring-bind (name class var-p) entry
    (let ((type (%make-condition-type (format nil "skein.core/~A" name) class)))
      (register-condition-type type)
      (when var-p (def-var (intern-var +core+ name) type)))))

(defun builtin-type (name)
  (gethash (format nil "skein.core/~A" name) **condition-types**))

(defun unqualified-type-name (type)
  (let ((name (condition-type-name type)))
    (subseq name (1+ (position #\/ name)))))

(defun find-condition-type (x &optional (namespace-name (namespace-name *current-namespace*)))
  "Return the condition type that X names: a condition type, or a symbol. A symbol is
resolved in the namespace NAMESPACE-NAME (as a var holding a type), which defaults to the
current namespace; condition, error and warning are built in; failing that, an
unqualified name that only one namespace defines is accepted."
  (flet ((fail ()
           (skein-error 'skein-error nil "~A is not a condition type" (readable-string x))))
    (cond ((condition-type-p x) x)
          ((not (sym-p x)) (fail))
          ((and (null (sym-namespace x))
                (member (sym-name x) '("condition" "error" "warning") :test #'string=))
           (builtin-type (sym-name x)))
          (t (let* ((ns (and namespace-name (find-namespace namespace-name)))
                    (var (and ns (if (sym-namespace x)
                                     (let ((target (or (find-alias ns (sym-namespace x))
                                                       (find-namespace (sym-namespace x)))))
                                       (and target (find-own-var target (sym-name x))))
                                     (resolve-var ns (sym-name x)))))
                    (value (and var (var-value var))))
               (cond ((condition-type-p value) value)
                     ((sym-namespace x)
                      (or (gethash (format nil "~A/~A" (sym-namespace x) (sym-name x))
                                   **condition-types**)
                          (fail)))
                     (t (let ((matches (loop for type being the hash-values
                                               of **condition-types**
                                             when (string= (sym-name x)
                                                           (unqualified-type-name type))
                                               collect type)))
                          (case (length matches)
                            (0 (fail))
                            (1 (first matches))
                            (t (skein-error 'skein-error nil "condition type ~A is ambiguous; ~
                                                              qualify it with its namespace"
                                            (sym-name x))))))))))))

(defun condition-type-of (c)
  "Return the Skein condition type of the condition C (the nearest registered type)."
  (loop for class in (sb-mop:class-precedence-list (class-of c))
        for type = (gethash (class-name class) **types-by-class**)
        when type return type))

(defun defined-type-of (c)
  "Return the nearest condition type of C that defcondition created, or NIL."
  (loop with package = (find-package '#:skein-condition-classes)
        for class in (sb-mop:class-precedence-list (class-of c))
        for type = (gethash (class-name class) **types-by-class**)
        when (and type (eq (symbol-package (condition-type-class type)) package))
          return type))

;;; defcondition

(defun all-slots (type)
  (append (condition-type-slots type) (mapcan #'all-slots (condition-type-parents type))))

(defun define-condition-type (name parents slots report)
  "Create or redefine the condition type NAME (a qualified symbol) with PARENTS (types),
SLOTS (a list of (slot-symbol initform-fn)) and REPORT (a function or nil)."
  (let* ((qualified (format nil "~A/~A" (sym-namespace name) (sym-name name)))
         (class (intern qualified '#:skein-condition-classes))
         (type (or (gethash qualified **condition-types**)
                   (%make-condition-type qualified class)))
         (slot-specs (loop for (slot initform) in slots
                           collect (list (sym-name slot)
                                         (intern (sym-name slot) '#:skein-condition-classes)
                                         initform))))
    (setf (condition-type-slots type) slot-specs
          (condition-type-parents type) parents
          (condition-type-report type) report)
    ;; The class must exist at run time, so it is created with EVAL; this is the runtime,
    ;; not the front end, so CL tricks are allowed (CLAUDE.md §4).
    (eval `(define-condition ,class ,(or (mapcar #'condition-type-class parents) '(condition))
             ,(loop for (slot-name cl-symbol) in slot-specs
                    collect `(,cl-symbol :initarg ,(intern slot-name :keyword) :initform nil))
             (:report (lambda (c stream) (write-string (condition-report c) stream)))))
    (register-condition-type type)
    type))

(defun condition-slot (c slot-name &optional (not-found nil not-found-p))
  "Return the slot SLOT-NAME (a string) of the Skein condition C."
  (let* ((type (defined-type-of c))
         (spec (and type (find slot-name (all-slots type) :key #'first :test #'string=))))
    (cond (spec (slot-value c (second spec)))
          (not-found-p not-found)
          (t (skein-error 'skein-error nil "~A has no slot ~A" (readable-string c) slot-name)))))

(defun condition-report (c)
  "Return the message of the condition C."
  (let ((type (defined-type-of c)))
    (cond ((and type (condition-type-report type))
           (display-string (scall (condition-type-report type) c)))
          ((and type (condition-type-slots type))
           (format nil "~A ~A" (condition-type-name type)
                   (readable-string
                    (map-from-pairs (loop for (name) in (all-slots type)
                                          append (list (intern-kw name)
                                                       (condition-slot c name)))))))
          (type (condition-type-name type))
          (t (let ((*print-pretty* nil)) (princ-to-string c))))))

(defun make-skein-condition (type initargs)
  "Make a condition of TYPE from the Skein keyword/value list INITARGS."
  (let* ((type (find-condition-type type))
         (slot-names (mapcar #'first (all-slots type)))
         (cl-initargs (loop for (k v) on initargs by #'cddr
                            append (list (cond ((not (kw-p k))
                                                (skein-error 'skein-error nil
                                                             "condition initargs must be ~
                                                              keywords, not ~A"
                                                             (readable-string k)))
                                               ((not (member (kw-name k) slot-names
                                                             :test #'string=))
                                                (skein-error 'skein-error nil "~A has no slot ~A"
                                                             (condition-type-name type)
                                                             (kw-name k)))
                                               (t (intern (kw-name k) :keyword)))
                                         v)))
         (c (handler-case (apply #'make-condition (condition-type-class type) cl-initargs)
              (error ()
                (skein-error 'skein-error nil "cannot make a ~A from ~A"
                             (condition-type-name type)
                             (readable-string (list-from-cl initargs)))))))
    (loop for (name cl-symbol initform) in (all-slots type)
          unless (getf initargs (intern-kw name))
            do (when initform (setf (slot-value c cl-symbol) (scall initform))))
    c))

;;; Signaling

(defun message-of (args)
  (format nil "~{~A~^ ~}" (mapcar #'display-string args)))

(defun to-condition (x args kind)
  "Turn the arguments of error, signal or warn into a condition. KIND is :error, :signal
or :warning, which decides the class of a condition made from a message string."
  (cond ((typep x 'condition) x)
        ((stringp x) (let ((message (message-of (cons x args))))
                       (ecase kind
                         (:error (make-condition 'skein-error :message message))
                         (:signal (make-condition 'skein-condition :message message))
                         (:warning (make-condition 'skein-warning :message message)))))
        (t (make-skein-condition x args))))

(defun throw-condition (c)
  "Signal the condition C; if no handler unwinds, enter the debugger (CL's ERROR)."
  (unless (typep c 'condition)
    (skein-error 'skein-error nil "throw-condition needs a condition, not ~A"
                 (readable-string c)))
  (error c))

;;; Restarts

(defun restart-cl-name (name)
  "Return the CL symbol used as the name of the Skein restart NAME (a symbol)."
  (intern (if (sym-namespace name)
              (format nil "~A/~A" (sym-namespace name) (sym-name name))
              (sym-name name))
          '#:skein-restarts))

(defun restart-skein-name (restart)
  "Return the name of RESTART as a Skein symbol."
  (let ((name (restart-name restart)))
    (cond ((null name) nil)
          ((eq (symbol-package name) (find-package '#:skein-restarts))
           (let* ((s (symbol-name name)) (slash (position #\/ s)))
             (if slash
                 (intern-sym (subseq s (1+ slash)) (subseq s 0 slash))
                 (intern-sym s))))
          (t (intern-sym (string-downcase (symbol-name name)))))))

;;; SBCL allocates restarts on the stack, so Skein code never holds a CL restart directly
;;; (it could outlive its RESTART-CASE and crash the image). It gets a SKEIN-RESTART that
;;; copies the name and report; using one checks that its restart is still active.

(defstruct (skein-restart (:constructor make-skein-restart (restart name report))
                          (:copier nil))
  "A Skein view of a CL restart: its NAME (a Skein symbol) and REPORT (a string)."
  (restart nil :read-only t)
  (name nil :read-only t)
  (report "" :read-only t))

(setf (documentation 'skein-restart-p 'function) "Return true if the argument is a restart."
      (documentation 'skein-restart-name 'function) "Return the name of a restart."
      (documentation 'skein-restart-report 'function) "Return the description of a restart.")

(defun wrap-restart (r)
  (make-skein-restart r (restart-skein-name r) (let ((*print-pretty* nil)) (princ-to-string r))))

(defun active-restart (x condition)
  "Return the active CL restart that X (a SKEIN-RESTART or a name symbol) stands for, or
NIL if there is none."
  (cond ((skein-restart-p x)
         (find (skein-restart-restart x) (compute-restarts condition)))
        ((sym-p x)
         (or (find-restart (restart-cl-name x) condition)
             ;; CL's standard restarts: abort, continue, muffle-warning, store-value,
             ;; use-value.
             (and (null (sym-namespace x))
                  (member (sym-name x) '("abort" "continue" "muffle-warning" "store-value"
                                         "use-value")
                          :test #'string=)
                  (find-restart (find-symbol (string-upcase (sym-name x)) :cl) condition))))
        (t (skein-error 'skein-error nil "~A does not name a restart" (readable-string x)))))

(defun skein-compute-restarts (&optional condition)
  "Return the active restarts as SKEIN-RESTARTs, innermost first."
  (mapcar #'wrap-restart (compute-restarts condition)))
