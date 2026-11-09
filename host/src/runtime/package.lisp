;;;; Runtime support for Skein programs hosted on SBCL.

(defpackage #:skein.runtime
  (:use #:cl)
  (:export
   ;; Symbols and keywords
   #:sym #:sym-p #:sym-name #:sym-namespace #:intern-sym
   #:kw #:kw-p #:kw-name #:kw-namespace #:intern-kw
   ;; Booleans
   #:+false+ #:false-p
   ;; Numbers
   #:decimal-to-float #:float-out-of-range
   ;; Printing
   #:print-atom #:atom-to-string #:unprintable-value #:*char-names*)
  (:documentation "Runtime support for Phase 0 Skein programs: vars, data types, core functions.

Phase 0 value representation (D-028): Skein nil is CL NIL, true is CL T, false is the
singleton +FALSE+, integers are CL integers, f64 and f32 are double- and single-floats,
chars are CL characters and strings are CL strings."))
