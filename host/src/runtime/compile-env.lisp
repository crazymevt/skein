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

(defcore "%set-var-info!" (var arglists location)
  ;; Natively the model keeps these for documentation (D-086); Phase 0's REPL has its own.
  (declare (ignore arglists location))
  var)

(defcore "%var-info" (var)
  (declare (ignore var))
  nil)

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
(defcore "%make-runtime-var" (ns-name name)
  ;; Natively a new var of the program; Phase 0's vars are the image's.
  (intern-var (ensure-namespace ns-name) name))
(defcore "%set-runtime-var-dynamic!" (var) (setf (var-dynamic-p var) t) nil)
(defcore "%runtime-var" (var) var)
(defcore "%runtime-var-of" (var) var)
(defcore "%namespace-file" (ns) (namespace-file ns))
(defcore "%set-namespace-file!" (ns file) (setf (namespace-file ns) file) nil)
(defcore "%eval-run" (code)
  ;; Natively the closure compiler runs lowered code (D-079); Phase 0 compiles to CL.
  (declare (ignore code))
  (skein-error 'skein-error nil "%eval-run is native only"))
(defcore "%install-debugger!" (f)
  ;; Phase 0's REPL has its own debugger (repl/repl.lisp).
  (declare (ignore f))
  nil)
(defcore "%backtrace" () (vector-from-list '()))

;;; The REPL and skein dev natively (M2.6, D-081) use these; Phase 0's REPL is in CL
;;; (repl/repl.lisp), so here they only say so.
(macrolet ((native-only (&rest names)
             `(progn ,@(loop for name in names
                             collect `(defcore ,name (&rest args)
                                        (declare (ignore args))
                                        (skein-error 'skein-error nil "~A is native only"
                                                     ,name))))))
  (native-only "%file-mtime" "%stdin" "%read-text" "%write-text" "%tcp-listen"
               "%tcp-accept" "%tcp-port" "%tcp-close" "%exit" "%main-thread?"
               "%run-attached" "%utf8-length" "%utf8-split" "%absolute-path" "%load-module"
               ;; STM (M2.10, D-092)
               "ref" "ref?" "%dosync" "%in-transaction?" "ref-set" "alter" "commute"
               "ensure"
               ;; skein.io's directories, bytes and streams, and skein.log's clock (M2.11,
               ;; D-093)
               "%stat" "%delete-path" "%rename-path" "%read-bytes" "%write-bytes"
               "%open-stream" "%stream-read-line" "%stream-read-rest" "%stream-read-bytes"
               "%stream-write" "%stream-flush" "%stream-close"
               ;; By-value structs (M2.13, D-096): the C backend's, which runs natively
               "%ctype-layout"))

(defcore "%epoch-millis" ()
  ;; Wall-clock time in milliseconds since 1970 (skein.log, M2.11).
  (multiple-value-bind (seconds microseconds) (sb-ext:get-time-of-day)
    (+ (* seconds 1000) (floor microseconds 1000))))

(defcore "%utc-offset" (millis)
  ;; The local time zone's offset from UTC, in seconds east, at MILLIS since 1970
  ;; (skein.time/local-time, M2.14). CL's zone is hours west, not counting daylight time.
  (multiple-value-bind (s m h d mo y dow dst zone)
      (decode-universal-time (+ (floor millis 1000) 2208988800))
    (declare (ignore s m h d mo y dow))
    (round (- (* (if dst 3600 0) 1) (* zone 3600)))))

(defcore "%write-stderr" (text)
  ;; skein.log's default handler (M2.11).
  (write-string text *error-output*)
  (force-output *error-output*)
  nil)

(defcore "%evaluated?" (f)
  ;; Phase 0 compiles everything it evaluates (D-091).
  (declare (ignore f))
  nil)

(defcore "%install-task-runner!" (f)
  ;; Phase 0's REPL doesn't debug tasks (D-088).
  (declare (ignore f))
  nil)

;; Regular expressions (M3.3, D-105) are native only.
(defcore "%regex-literal" (s)
  (declare (ignore s))
  (error "regular expressions are native only (D-105)"))

(defcore "re-pattern" (s)
  (declare (ignore s))
  (error "regular expressions are native only (D-105)"))

(defcore "%re-exec" (p s start full)
  (declare (ignore p s start full))
  (error "regular expressions are native only (D-105)"))

(defcore "%re-names" (p)
  (declare (ignore p))
  (error "regular expressions are native only (D-105)"))

(defcore "%re-source" (p)
  (declare (ignore p))
  (error "regular expressions are native only (D-105)"))

(defcore "%pattern?" (x)
  ;; Nothing is a pattern in Phase 0; skein.string asks before matching a string.
  (declare (ignore x))
  nil)

;; skein.json (M3.2, D-104) is native only.
(defcore "%json-read" (s key-fn value-fn)
  (declare (ignore s key-fn value-fn))
  (error "skein.json is native only (D-104)"))

(defcore "%json-write" (x pretty escape-unicode key-fn value-fn)
  (declare (ignore x pretty escape-unicode key-fn value-fn))
  (error "skein.json is native only (D-104)"))

(defcore "%json-reformat" (s indent)
  (declare (ignore s indent))
  (error "skein.json is native only (D-104)"))

;; skein.bytes (M3.2, D-104) is native only.
(defcore "%utf8" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%utf8-string" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%base64" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%unbase64" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%hex" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%unhex" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%sha1" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%sha256" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

(defcore "%md5" (x)
  (declare (ignore x))
  (error "skein.bytes is native only (D-104)"))

;; skein.process (M3.1, D-103) is native only.
(defcore "%process-start" (argv dir env in out err)
  (declare (ignore argv dir env in out err))
  (error "skein.process is native only (D-103)"))

(defcore "%process-stream" (h i)
  (declare (ignore h i))
  (error "skein.process is native only (D-103)"))

(defcore "%process-signal" (h kind tree)
  (declare (ignore h kind tree))
  (error "skein.process is native only (D-103)"))

(defcore "%process-pid" (h)
  (declare (ignore h))
  (error "skein.process is native only (D-103)"))

(defcore "%process-exit" (h)
  (declare (ignore h))
  (error "skein.process is native only (D-103)"))

(defcore "%process-wait" (h seconds)
  (declare (ignore h seconds))
  (error "skein.process is native only (D-103)"))

(defcore "%interrupt-ignored?" ()
  (error "skein.process is native only (D-103)"))

(defcore "%environment" ()
  (error "skein.process is native only (D-103)"))

(defcore "%executable-path" ()
  (error "skein.process is native only (D-103)"))

(defcore "%task-spawner-restarts" (task)
  ;; Phase 0's tasks don't record their spawner's restarts (D-101).
  (declare (ignore task))
  nil)

(defcore "%choose-spawner-restart!" (task restart)
  (declare (ignore task restart))
  nil)

(defcore "%set-output-var!" (var)
  ;; Phase 0's REPL binds *standard-output* instead.
  (declare (ignore var))
  nil)

(defcore "%all-namespaces" () (vector-from-list (all-namespaces)))

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

