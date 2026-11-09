;;;; The binding generator (DESIGN §14.4).

(defpackage #:skein.bindgen
  (:use #:cl)
  (:export #:generate-bindings #:parse-json #:bindgen-error #:c-name-to-skein)
  (:documentation "skein bindgen: reads C headers through clang's JSON AST dump and writes
Skein FFI declarations (deflibrary, defcstruct, defcunion, defcfun and constants)."))
