;;;; Runtime support for Skein programs hosted on SBCL.

(defpackage #:skein.runtime
  (:use #:cl)
  (:export
   ;; Symbols and keywords
   #:sym #:sym-p #:sym-name #:sym-namespace #:intern-sym #:copy-sym
   #:kw #:kw-p #:kw-name #:kw-namespace #:intern-kw
   ;; Booleans and truthiness
   #:+false+ #:false-p #:truthy-p #:bool
   ;; Numbers
   #:decimal-to-float #:float-out-of-range #:ensure-float-modes
   #:+f64-infinity+ #:+f64-negative-infinity+ #:+f64-nan+
   ;; Errors
   #:skein-error #:skein-error-message #:skein-error-location
   #:unbound-var-error #:not-callable-error #:arity-error #:namespace-error
   #:arity-error-function-name #:arity-error-argument-count
   ;; Namespaces and vars
   #:namespace #:namespace-p #:namespace-name #:namespace-loaded-p #:namespace-file
   #:*loading-file* #:all-namespaces
   #:find-namespace #:ensure-namespace #:remove-namespace #:find-alias
   #:+core+ #:*current-namespace* #:*source-paths* #:*program-file* #:*namespace-loader*
   #:namespace-file-name #:require-namespace #:namespace-requires #:namespace-syntax-requires
   #:*expansion-context* #:phase-warning #:defcore #:gensym-name
   #:var #:var-p #:var-namespace #:var-name #:var-value #:var-macro-p #:var-dynamic-p
   #:var-private-p #:var-doc #:var-qualified-name
   #:+unbound+ #:intern-var #:find-own-var #:resolve-var #:var-bound-p #:var-get #:def-var
   ;; Collections (DESIGN §6.2)
   #:+empty-list+ #:+empty-vector+ #:+empty-map+ #:+empty-set+
   #:pvector-p #:plist-p #:empty-list-p #:array-map-p #:hash-map-p #:hash-set-p #:lazy-seq-p
   #:list-from-cl #:rest-args #:vector-from-list #:vector-to-list #:map-from-pairs #:set-from-cl
   #:vector-nth #:vector-conj #:vector-assoc #:pvector-pop
   #:vector-transient #:tvector-conj #:tvector-assoc #:tvector-pop #:tvector-nth
   #:tvector-persistent
   #:map-get #:map-assoc #:map-dissoc #:map-count #:map-contains-p
   #:map-transient #:tmap-assoc #:tmap-dissoc #:tmap-get #:tmap-persistent
   #:index-error #:unsupported-operation-error #:transient-error
   ;; Seqs, equality and hashing (DESIGN §7)
   #:seq #:seq-first #:seq-next #:seq-rest #:seq-to-cl #:count-of
   #:coll-get #:coll-conj #:coll-assoc
   #:equiv #:hash-of #:compare-values #:sequential-p #:map-p
   ;; Conditions and restarts (DESIGN §10)
   #:condition-type #:condition-type-p #:condition-type-name #:condition-type-class
   #:find-condition-type #:condition-type-of #:condition-report #:throw-condition
   #:restart-cl-name #:skein-warning #:skein-condition #:skein-restart-p #:skein-restart-name
   #:skein-restart-report #:skein-compute-restarts
   ;; Objects (DESIGN §8)
   #:instance-p #:make-object #:with-object #:find-skein-class #:skein-class #:skein-object
   #:skein-generic #:check-equiv-hash-methods #:equiv-hash-warning #:no-method-error
   #:slot-error #:skein-atom-p #:skein-atom-value
   ;; Types, arrays and structs (DESIGN §9, §12)
   #:skein-type-to-cl #:inline-entry-for #:inline-arity-mismatch #:inline-entry-emitter
   #:inline-entry-test-p
   #:var-ftype #:struct-redefinition-warning #:struct-array-p #:find-struct-def
   #:byte-view-p #:byte-view-array #:array-element-bytes
   ;; Concurrency (DESIGN §13)
   #:cancelled #:task-timeout #:task-cancelled-error #:task-p #:chan-p
   ;; Calling
   #:invoke-other #:kw-lookup
   ;; Printing
   #:print-atom #:atom-to-string #:unprintable-value #:*char-names*
   #:print-value #:display-string #:readable-string)
  (:documentation "Runtime support for Phase 0 Skein programs: vars, data types, core functions.

Phase 0 value representation (D-028): Skein nil is CL NIL, true is CL T, false is the
singleton +FALSE+, integers are CL integers, f64 and f32 are double- and single-floats,
chars are CL characters and strings are CL strings. Functions are CL functions."))
