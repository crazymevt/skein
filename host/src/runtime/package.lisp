;;;; Runtime support for Skein programs hosted on SBCL.

(defpackage #:skein.runtime
  (:use #:cl)
  (:export
   ;; Symbols and keywords
   #:sym #:sym-p #:sym-name #:sym-namespace #:intern-sym
   #:kw #:kw-p #:kw-name #:kw-namespace #:intern-kw
   ;; Booleans and truthiness
   #:+false+ #:false-p #:truthy-p #:bool
   ;; Numbers
   #:decimal-to-float #:float-out-of-range
   #:+f64-infinity+ #:+f64-negative-infinity+ #:+f64-nan+
   ;; Errors
   #:skein-error #:skein-error-message #:skein-error-location
   #:unbound-var-error #:not-callable-error #:arity-error #:namespace-error
   ;; Namespaces and vars
   #:namespace #:namespace-p #:namespace-name #:namespace-loaded-p
   #:find-namespace #:ensure-namespace #:remove-namespace #:find-alias
   #:+core+ #:*current-namespace* #:*source-paths* #:*namespace-loader*
   #:namespace-file-name #:require-namespace
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
   #:equiv #:hash-of #:compare-values
   ;; Calling
   #:invoke-other #:kw-lookup
   ;; Printing
   #:print-atom #:atom-to-string #:unprintable-value #:*char-names*
   #:print-value #:display-string #:readable-string)
  (:documentation "Runtime support for Phase 0 Skein programs: vars, data types, core functions.

Phase 0 value representation (D-028): Skein nil is CL NIL, true is CL T, false is the
singleton +FALSE+, integers are CL integers, f64 and f32 are double- and single-floats,
chars are CL characters and strings are CL strings. Functions are CL functions."))
