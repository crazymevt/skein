;;;; Namespaces and vars (DESIGN §4.3).

(in-package #:skein.runtime)

(sb-ext:define-load-time-global +unbound+ (make-symbol "UNBOUND")
  "The value of a var that has been declared but not defined.")

(defstruct (namespace (:constructor %make-namespace (name)) (:copier nil))
  "A Skein namespace: its own vars, vars referred from other namespaces, and aliases."
  (name "" :type string :read-only t)
  (mappings (make-hash-table :test 'equal :synchronized t) :read-only t)
  (refers (make-hash-table :test 'equal :synchronized t) :read-only t)
  (aliases (make-hash-table :test 'equal :synchronized t) :read-only t)
  (loaded-p nil)
  ;; The source file its ns form was loaded from (a native namestring), or NIL.
  (file nil)
  ;; Namespaces this one requires at run time (phase 0) and for syntax (phase 1).
  (requires '())
  (syntax-requires '()))

(defstruct (var (:constructor %make-var (namespace name)) (:copier nil))
  "A Skein var: a named global cell. Calls to globals read the var each time, which
is what makes redefinition visible to existing callers."
  (namespace nil :read-only t)
  (name "" :type string :read-only t)
  (value +unbound+)
  (macro-p nil)
  (dynamic-p nil)
  (private-p nil)
  (doc nil)
  ;; A declared function type, (fn [arg-types] return-type) as data (DESIGN §12.2).
  (ftype nil))

(setf (documentation 'namespace-name 'function) "Return the name of a namespace."
      (documentation 'namespace-p 'function) "Return true if the argument is a namespace."
      (documentation 'namespace-loaded-p 'function)
      "Return true once a namespace's source has started loading."
      (documentation 'namespace-file 'function)
      "Return the source file a namespace was loaded from, or NIL."
      (documentation 'namespace-requires 'function)
      "Return the namespaces this namespace requires at run time."
      (documentation 'namespace-syntax-requires 'function)
      "Return the namespaces this namespace requires for syntax (:require-for-syntax)."
      (documentation 'var-p 'function) "Return true if the argument is a var."
      (documentation 'var-namespace 'function) "Return the namespace a var belongs to."
      (documentation 'var-name 'function) "Return the unqualified name of a var."
      (documentation 'var-value 'function)
      "Return the raw value of a var: its root value, or +UNBOUND+."
      (documentation 'var-macro-p 'function)
      "Return true if a var holds a macro. In Phase 0 a macro's value is a CL function
of a syntax object and an expander environment, returning a syntax object."
      (documentation 'var-dynamic-p 'function) "Return true if a var is ^:dynamic."
      (documentation 'var-private-p 'function) "Return true if a var is ^:private."
      (documentation 'var-doc 'function) "Return a var's docstring, or NIL."
      (documentation 'var-ftype 'function)
      "Return the function type declared for a var with declaim, or NIL.")

(defmethod print-object ((v var) stream)
  (print-unreadable-object (v stream :type t)
    (write-string (var-qualified-name v) stream)))

(defmethod print-object ((n namespace) stream)
  (print-unreadable-object (n stream :type t)
    (write-string (namespace-name n) stream)))

(defun var-qualified-name (var)
  "Return \"ns/name\" for VAR."
  (format nil "~A/~A" (namespace-name (var-namespace var)) (var-name var)))

;;; The namespace registry

(sb-ext:define-load-time-global **namespaces** (make-hash-table :test 'equal :synchronized t))

(defun find-namespace (name)
  "Return the namespace called NAME (a string), or NIL."
  (gethash name **namespaces**))

(defun ensure-namespace (name)
  "Return the namespace called NAME, creating it if needed."
  (sb-ext:with-locked-hash-table (**namespaces**)
    (or (gethash name **namespaces**)
        (setf (gethash name **namespaces**) (%make-namespace name)))))

(defun all-namespaces ()
  "Return a list of every namespace."
  (loop for ns being the hash-values of **namespaces** collect ns))

(defun remove-namespace (name)
  "Forget the namespace called NAME. Existing code that refers to its vars keeps them."
  (remhash name **namespaces**))

(sb-ext:define-load-time-global +core+
    (let ((core (ensure-namespace "skein.core")))
      (setf (namespace-loaded-p core) t)
      core)
  "The skein.core namespace. Its public vars are visible in every namespace.")

(defvar *current-namespace* (ensure-namespace "user")
  "The namespace that top-level forms are expanded in. `ns` forms change it.")

(defvar *source-paths* '()
  "Directories searched, in order, for a namespace's source file.")

(defvar *program-file* nil
  "The main file of the program that skein run or skein dev is running (a pathname), or
NIL. skein.io/resource-dir starts from it.")

(defvar *loading-file* nil
  "The file being loaded (a native namestring), or NIL. A namespace declared while it
loads records it as its file.")

(defvar *namespace-loader* nil
  "A function of a namespace name that loads its source, set by the compiler driver.")

;;; Vars

(defun intern-var (namespace name)
  "Return NAMESPACE's own var called NAME, creating an unbound one if needed."
  (let ((table (namespace-mappings namespace)))
    (sb-ext:with-locked-hash-table (table)
      (or (gethash name table)
          (setf (gethash name table) (%make-var namespace name))))))

(defun find-own-var (namespace name)
  "Return NAMESPACE's own var called NAME, or NIL."
  (gethash name (namespace-mappings namespace)))

(defun resolve-var (namespace name)
  "Return the var that the unqualified NAME means in NAMESPACE: its own var, then a
referred var, then a public var of skein.core. Returns NIL if there is none."
  (or (find-own-var namespace name)
      (gethash name (namespace-refers namespace))
      (let ((core (find-own-var +core+ name)))
        (and core (not (var-private-p core)) core))))

(defun find-alias (namespace alias)
  "Return the namespace that ALIAS names in NAMESPACE, or NIL."
  (gethash alias (namespace-aliases namespace)))

(defun var-bound-p (var)
  "Return true if VAR has a value."
  (not (eq (var-value var) +unbound+)))

(defvar *expansion-context* nil
  "While a macro defined in Skein runs, a cons of its var and the location of the form
being expanded; NIL otherwise. Used to check phase rules (DESIGN §4.4).")

(declaim (inline var-get))
(defun var-get (var location)
  "Return VAR's value. Signals UNBOUND-VAR-ERROR, reporting LOCATION, if it has none.
While a macro runs, also checks that VAR may be used at expansion time."
  (when *expansion-context* (check-phase var))
  (let ((value (var-value var)))
    (if (eq value +unbound+)
        (skein-error 'unbound-var-error location "var ~A is unbound" (var-qualified-name var))
        value)))

(defun def-var (var value)
  "Set VAR's root value to VALUE and return VAR."
  (setf (var-value var) value)
  var)

;;; Phases (DESIGN §4.4, D-033). A macro defined in namespace M may use, while it runs,
;;; vars of skein.core, of M itself, and of the namespaces M requires for syntax together
;;; with everything those require. Anything else is a phase violation; Phase 0 warns.

(define-condition phase-warning (warning)
  ((message :initarg :message :reader phase-warning-message)
   (location :initarg :location :initform nil :reader phase-warning-location))
  (:report (lambda (c stream)
             (format stream "~A~@[ at ~A~]" (phase-warning-message c)
                     (and (phase-warning-location c)
                          (skein.syntax:format-location (phase-warning-location c))))))
  (:documentation "Warns that a macro used a var at expansion time (phase 1) from a
namespace that is not available for syntax."))

(sb-ext:define-load-time-global **phase-warned** (make-hash-table :test 'equal :synchronized t))

(defun syntax-namespaces (ns)
  "Return the namespaces whose vars a macro defined in NS may use while it runs."
  (let ((seen (list +core+ ns)))
    (labels ((visit (n)
               (unless (member n seen)
                 (push n seen)
                 (mapc #'visit (namespace-requires n))
                 (mapc #'visit (namespace-syntax-requires n)))))
      (mapc #'visit (namespace-syntax-requires ns))
      seen)))

(defun compiler-namespace-p (ns)
  "True if NS is part of the compiler written in Skein (skein.compiler.*), whose code runs
while macros expand but is not theirs: the interpreter running a macro, say (D-061)."
  (let ((name (namespace-name ns)))
    (and (> (length name) 15) (string= "skein.compiler." name :end2 15))))

(defun check-phase (var)
  (destructuring-bind (macro . location) *expansion-context*
    (let ((macro-ns (var-namespace macro)))
      (unless (or (member (var-namespace var) (syntax-namespaces macro-ns))
                  (compiler-namespace-p (var-namespace var)))
        (let ((key (cons (var-qualified-name macro) (var-qualified-name var))))
          (unless (gethash key **phase-warned**)
            (setf (gethash key **phase-warned**) t)
            (warn 'phase-warning
                  :location location
                  :message (format nil "macro ~A uses ~A while expanding; require ~A with ~
                                        :require-for-syntax in ~A"
                                   (var-qualified-name macro) (var-qualified-name var)
                                   (namespace-name (var-namespace var))
                                   (namespace-name macro-ns)))))))))

;;; Loading namespaces

(defun namespace-file-name (name)
  "Return the relative source path for namespace NAME: a.b-c becomes a/b-c.skn."
  (concatenate 'string (substitute #\/ #\. name) ".skn"))

(defun require-namespace (name)
  "Make sure the namespace called NAME is loaded, loading its source file if needed,
and return it."
  (let ((ns (find-namespace name)))
    (if (and ns (namespace-loaded-p ns))
        ns
        (progn
          (unless *namespace-loader*
            (skein-error 'namespace-error nil "cannot load namespace ~A: no loader" name))
          (funcall *namespace-loader* name)
          (or (find-namespace name)
              (skein-error 'namespace-error nil
                           "loading ~A did not define namespace ~A"
                           (namespace-file-name name) name))))))
