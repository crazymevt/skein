;;;; The foreign function interface (DESIGN §14), on top of CFFI.

(defpackage #:skein.ffi
  (:use #:cl)
  (:import-from #:skein.runtime
                #:sym-p #:sym-name #:sym-namespace #:kw-p #:kw-name #:intern-kw #:intern-sym
                #:skein-error #:unsupported #:readable-string #:truthy-p #:bool #:+false+
                #:vector-to-list #:seq-to-cl #:map-from-pairs #:coll-get #:list-from-cl
                #:intern-var #:def-var #:find-namespace #:ensure-namespace #:resolve-var
                #:find-own-var #:var-value #:*current-namespace* #:namespace-name #:scall
                #:skein-apply #:ensure-float-modes #:display-string)
  (:export #:foreign-type #:ffi-error #:library-search-directories)
  (:documentation "The Skein FFI: loading C libraries, describing C structs, unions and
enums, calling C functions and receiving callbacks. Its Skein functions live in the
skein.ffi namespace; its macros are in lib/skein/ffi.skn."))
