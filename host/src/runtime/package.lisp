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
   ;; Calling
   #:invoke-other #:kw-lookup
   ;; Printing
   #:print-atom #:atom-to-string #:unprintable-value #:*char-names*
   #:print-value #:display-string #:readable-string)
  (:documentation "Runtime support for Phase 0 Skein programs: vars, data types, core functions.

Phase 0 value representation (D-028): Skein nil is CL NIL, true is CL T, false is the
singleton +FALSE+, integers are CL integers, f64 and f32 are double- and single-floats,
chars are CL characters and strings are CL strings. Functions are CL functions."))
