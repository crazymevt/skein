;;;; The Common Lisp backend: Core IR to CL forms.

(defpackage #:skein.backend.cl
  (:use #:cl #:skein.ir)
  (:import-from #:skein.runtime
                #:var-get #:dynamic-var-get #:def-var #:truthy-p #:invoke-other #:arity-error
                #:*current-namespace* #:*source-paths* #:*program-file* #:*namespace-loader*
                #:namespace-name #:ensure-namespace #:find-namespace #:namespace-loaded-p
                #:namespace-file-name #:skein-error #:namespace-error)
  (:export
   #:node-to-cl #:compile-node #:eval-node #:*profile* #:efficiency-note
   #:eval-toplevel #:load-stream #:load-string #:load-file #:load-namespace #:run-file
   #:program-source-paths #:main-function #:find-namespace-file #:library-directory)
  (:documentation "The Phase 0 backend: translates Core IR into Common Lisp code, compiles
it with SBCL and runs it. Also the compiler driver: reading, expanding and evaluating
top-level forms, loading files, and finding namespaces on *SOURCE-PATHS*."))
