;;;; The compile-time environment as skein.core functions, for the expander written in
;;;; Skein (lib/skein/compiler/expander.skn, M1.7, D-049): namespaces, vars, macro calls,
;;;; fresh symbols and identity tables. The names start with % because they are the
;;;; compiler's interface to the image, not a public API.

(in-package #:skein.runtime)

;;; Namespaces

(defcore "%find-namespace" (name) (find-namespace name))
(defcore "%current-namespace" () *current-namespace*)
(defcore "%namespace-name" (ns) (namespace-name ns))
(defcore "%find-alias" (ns alias) (find-alias ns alias))

;;; Vars

(defcore "%resolve-var" (ns name) (resolve-var ns name))
(defcore "%find-own-var" (ns name) (find-own-var ns name))
(defcore "%intern-var" (ns name) (intern-var ns name))
(defcore "%var-name" (var) (var-name var))
(defcore "%var-namespace" (var) (var-namespace var))
(defcore "%var-qualified-name" (var) (var-qualified-name var))
(defcore "%var-value" (var) (var-value var))
(defcore "%var-private?" (var) (bool (var-private-p var)))
(defcore "%var-dynamic?" (var) (bool (var-dynamic-p var)))

(defcore "%var-macro" (var)
  ;; :syntax for the built-in macros written in CL, true for macros written in Skein,
  ;; else nil.
  (let ((m (var-macro-p var)))
    (cond ((eq m :syntax) (intern-kw "syntax"))
          (m t)
          (t nil))))

(defcore "%set-var-flags!" (var dynamic private doc)
  ;; What def does when it is expanded: the var is no longer a macro, and its dynamic and
  ;; private flags and docstring come from the def form.
  (setf (var-macro-p var) nil
        (var-dynamic-p var) (truthy-p dynamic)
        (var-private-p var) (truthy-p private)
        (var-doc var) doc)
  var)

;;; Symbols and identity

(defcore "%copy-symbol" (s)
  ;; A symbol = to S but not identical? to it, so the expander can track where it came
  ;; from.
  (copy-sym s))

(defcore "%identity-table" () (make-hash-table :test 'eq))
(defcore "%identity-get" (table key) (values (gethash key table)))
(defcore "%identity-put!" (table key value) (setf (gethash key table) value))

;;; Calling macros

(defvar *syntax-meta-lookup* nil
  "While the expander written in Skein runs a macro, a function from a form the macro
received to that form's metadata (as data), for %syntax-meta.")

(defun location-from-map (loc)
  (and loc
       (flet ((field (name) (map-get loc (intern-kw name))))
         (skein.syntax:make-source-location
          :file (field "file") :line (field "line") :column (field "column")
          :end-line (field "end-line") :end-column (field "end-column")))))

(defcore "%call-macro" (var form env args location meta-lookup)
  ;; Call the macro in VAR as the expander does: with the form, &env and the arguments,
  ;; checking phase rules (DESIGN §4.4) against LOCATION (a location map).
  (let ((*expansion-context* (cons var (location-from-map location)))
        (*syntax-meta-lookup* meta-lookup))
    (apply (var-value var) form env (seq-to-cl args))))

(defcore "%arity-error-details" (c)
  ;; [function-name argument-count] for an arity error, or nil.
  (and (typep c 'arity-error)
       (vector-from-list (list (arity-error-function-name c) (arity-error-argument-count c)))))

(defcore "%function-name" (f)
  ;; The display name of a function, as arity errors name it.
  (and (functionp f) (function-display-name f)))

(defcore "%error-has-location?" (c)
  (bool (and (typep c 'skein-error) (skein-error-location c))))

(defcore "%skein-error?" (c) (bool (typep c 'skein-error)))

;;; For the C backend in Skein (lib/skein/compiler/c.skn, M1.9 step 2)

(defcore "%ensure-namespace" (name) (ensure-namespace name))

(defcore "%generic?" (x)
  ;; True if X is a generic function.
  (bool (typep x 'skein-generic)))

(defcore "%struct-def-name" (sym ns)
  ;; The qualified name ("ns/name") of the struct type that the symbol SYM names in the
  ;; namespace NS, or nil.
  (let ((def (find-struct-def sym (namespace-name ns))))
    (and def (struct-def-name def))))

(defcore "%f64-bits" (x)
  ;; The IEEE 754 bits of the f64 X, as a non-negative integer.
  (ldb (byte 64 0) (sb-kernel:double-float-bits x)))

(defcore "%f32-bits" (x)
  ;; The IEEE 754 bits of the f32 X, as a non-negative integer.
  (ldb (byte 32 0) (sb-kernel:single-float-bits x)))

;;; For skein.compiler.env (lib/skein/compiler/env.skn, M1.9 step 3), the native
;;; compiler's model of these namespaces. On the host the compiler uses the image instead,
;;; so the first three are never called; they exist so the namespace loads.

(defcore "%core-function-names" () (vector-from-list '()))
(defcore "%core-function" (name) (declare (ignore name)) nil)
(defcore "%registered-core-vars" () (vector-from-list '()))

(defcore "%eval-registry" ()
  ;; Natively, a program built with --eval registers its namespaces and vars for
  ;; skein.compiler.env (D-078); Phase 0's are the image's own.
  nil)
(defcore "%runtime-var-value" (var not-found)
  (let ((v (var-value var))) (if (eq v +unbound+) not-found v)))
(defcore "%set-runtime-var-value!" (var value) (setf (var-value var) value))
(defcore "%install-evaluator!" (hooks)
  ;; Phase 0 evaluates code itself (backend-cl/driver.lisp).
  (declare (ignore hooks))
  nil)

(defcore "%namespace-syntax-requires" (ns)
  (vector-from-list (reverse (namespace-syntax-requires ns))))

(defcore "%namespace-requires" (ns)
  ;; The namespaces NS requires at run time, in the order its ns form requires them.
  (vector-from-list (reverse (namespace-requires ns))))

;;; For the interpreter of phase-1 code (lib/skein/compiler/interp.skn, M1.9 step 4,
;;; D-061). The native runtime has the same functions (runtime/src/compiler.zig), and
;;; skein.compiler.env the ones about vars.

(defun sapply (f args)
  (if (functionp f) (apply f args) (apply #'invoke-other f nil args)))

(defcore "%call-with-handlers" (types handlers thunk)
  ;; Call THUNK with handlers established as handler-bind* does: one cluster, tried in
  ;; order.
  (let ((entries (mapcar (lambda (type handler)
                           (cons (condition-type-class (find-condition-type type)) handler))
                         (seq-to-cl types) (seq-to-cl handlers))))
    (handler-bind ((condition (lambda (c)
                                (loop for (class . handler) in entries
                                      when (typep c class) do (scall handler c)))))
      (scall thunk))))

(defcore "%call-with-restarts" (names fns reports thunk)
  ;; Call THUNK with restarts established as restart-bind* does; NAMES are symbols.
  (let ((sb-kernel:*restart-clusters*
          (cons (mapcar (lambda (name f report)
                          (let ((cl-name (restart-cl-name name)))
                            (sb-kernel:make-restart
                             cl-name
                             (lambda (&rest args) (sapply f args))
                             (lambda (stream)
                               (write-string (if report
                                                 (display-string report)
                                                 (symbol-name cl-name))
                                             stream)))))
                        (seq-to-cl names) (seq-to-cl fns) (seq-to-cl reports))
                sb-kernel:*restart-clusters*)))
    (scall thunk)))

(defcore "%apply-values" (vs) (values-list (seq-to-cl vs)))

(defcore "%call-with-values" (f args)
  ;; Call F with the vector ARGS; return a vector of all its values.
  (vector-from-list (multiple-value-list (sapply f (seq-to-cl args)))))

(defcore "%named-fn" (name f)
  ;; F (a closure) under the name NAME, for %function-name, printing and arity errors.
  (if (sb-kernel:closurep f) (sb-int:set-closure-name f t name) f))

(defcore "%arity-error" (name argc message)
  (error 'arity-error :function-name name :argument-count argc :location nil
                      :message message))

(defcore "%set-var-value!" (var value) (def-var var value) value)

(defcore "%var-defined?" (var) (bool (var-bound-p var)))

(defcore "%check-phase" (var)
  ;; While a macro written in Skein runs, warn if it uses VAR against DESIGN §4.4.
  (when *expansion-context* (check-phase var))
  nil)

(defcore "%add-method" (gf qualifier specializers rest-p fn)
  ;; Natively, skein.compiler.env's %define-method adds methods through this. In Phase 0
  ;; %define-method does it itself.
  (declare (ignore gf qualifier specializers rest-p fn))
  (skein-error 'skein-error nil "%add-method is only used by the native compiler"))

(defcore "%getenv" (name)
  ;; The environment variable NAME's value, or nil. For the native compiler's driver.
  (uiop:getenv name))

(defcore "%host-target" ()
  ;; This machine's zig target triple (DESIGN §19.1): the native compiler's default target.
  (format nil "~A-~A"
          #+(or arm64 aarch64) "aarch64" #+x86-64 "x86_64"
          #+darwin "macos" #+linux "linux-gnu" #+win32 "windows-gnu"))

;;; skein.compiler.env's %define-struct and %define-soa use these natively; in Phase 0
;;; %define-struct and %define-soa do the work themselves.

(macrolet ((native-only (&rest names)
             `(progn
                ,@(loop for name in names
                        collect `(defcore ,name (&rest args)
                                   (declare (ignore args))
                                   (skein-error 'skein-error nil "~A is only used by the native ~
                                                                  compiler" ,name))))))
  (native-only "%make-struct-def" "%struct-constructor" "%struct-predicate" "%struct-accessor"
               "%make-soa-def" "%soa-maker" "%soa-field"))

