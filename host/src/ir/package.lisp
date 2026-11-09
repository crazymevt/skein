;;;; Core IR node definitions (DESIGN §5.1, docs/CORE-IR.md).

(defpackage #:skein.ir
  (:use #:cl)
  (:export
   #:local #:make-local #:local-p #:local-name #:local-id #:local-mutable-p
   #:block-tag #:make-block-tag #:block-tag-p #:block-tag-name #:block-tag-id
   #:node #:node-p #:node-location
   #:const-node #:make-const-node #:const-node-p #:const-node-value
   #:local-ref-node #:make-local-ref-node #:local-ref-node-p #:local-ref-node-local
   #:var-ref-node #:make-var-ref-node #:var-ref-node-p #:var-ref-node-var
   #:if-node #:make-if-node #:if-node-p #:if-node-test #:if-node-then #:if-node-else
   #:do-node #:make-do-node #:do-node-p #:do-node-forms
   #:def-node #:make-def-node #:def-node-p #:def-node-var #:def-node-init
   #:fn-node #:make-fn-node #:fn-node-p #:fn-node-name #:fn-node-self #:fn-node-arities
   #:arity #:make-arity #:arity-p #:arity-params #:arity-rest #:arity-body #:arity-recur-p
   #:let-node #:make-let-node #:let-node-p #:let-node-bindings #:let-node-body
   #:letfn-node #:make-letfn-node #:letfn-node-p #:letfn-node-bindings #:letfn-node-body
   #:loop-node #:make-loop-node #:loop-node-p #:loop-node-bindings #:loop-node-body
   #:loop-node-recur-p
   #:recur-node #:make-recur-node #:recur-node-p #:recur-node-target #:recur-node-args
   #:set-node #:make-set-node #:set-node-p #:set-node-local #:set-node-value
   #:call-node #:make-call-node #:call-node-p #:call-node-fn #:call-node-args
   #:unwind-protect-node #:make-unwind-protect-node #:unwind-protect-node-p
   #:unwind-protect-node-body #:unwind-protect-node-cleanup
   #:block-node #:make-block-node #:block-node-p #:block-node-tag #:block-node-body
   #:return-from-node #:make-return-from-node #:return-from-node-p
   #:return-from-node-tag #:return-from-node-value
   #:values-node #:make-values-node #:values-node-p #:values-node-args
   #:let-values-node #:make-let-values-node #:let-values-node-p
   #:let-values-node-bindings #:let-values-node-body
   #:the-node #:make-the-node #:the-node-p #:the-node-type #:the-node-expr
   #:throw-condition-node #:make-throw-condition-node #:throw-condition-node-p
   #:throw-condition-node-condition
   #:handler-bind-node #:make-handler-bind-node #:handler-bind-node-p
   #:handler-bind-node-bindings #:handler-bind-node-body
   #:restart-bind-node #:make-restart-bind-node #:restart-bind-node-p
   #:restart-bind-node-bindings #:restart-bind-node-body)
  (:documentation "Core IR: the small language the expander produces and backends consume.
See docs/CORE-IR.md. Every node includes NODE-LOCATION; the accessors follow the
defstruct naming convention (e.g. IF-NODE-TEST)."))
