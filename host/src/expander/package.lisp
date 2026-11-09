;;;; The Skein expander: namespaces, scoping, macros, special forms to Core IR.

(defpackage #:skein.expander
  (:use #:cl #:skein.ir)
  (:shadow #:macroexpand-1 #:macroexpand)
  (:import-from #:skein.syntax
                #:make-syntax #:syntax-kind #:syntax-datum #:syntax-location #:syntax-meta
                #:syntax-to-string)
  (:import-from #:skein.runtime
                #:sym-p #:sym-name #:sym-namespace #:intern-sym #:kw-p #:kw-name
                #:intern-kw #:truthy-p
                #:namespace-name #:find-namespace #:find-alias #:resolve-var #:find-own-var
                #:intern-var #:var-macro-p #:var-private-p #:var-dynamic-p #:var-value
                #:var-namespace #:var-name #:var-qualified-name #:def-var #:+core+
                #:*current-namespace*)
  (:export
   #:compile-error
   #:env #:make-env #:env-namespace
   #:analyze #:analyze-toplevel #:macroexpand-1 #:macroexpand #:toplevel-do-p
   #:special-form-p)
  (:documentation "The Skein expander: resolves names, expands macros and builds Core IR.

ANALYZE turns a syntax object into a Core IR node (docs/CORE-IR.md). Built-in macros
are CL functions stored in skein.core vars until M0.5 moves them to Skein source."))
