;;;; The Skein expander: namespaces, scoping, macros, special forms to Core IR.

(defpackage #:skein.expander
  (:use #:cl)
  (:documentation "The Skein expander: resolves names, expands macros and builds Core IR."))
