;;;; Core IR to Common Lisp forms.

(in-package #:skein.backend.cl)

(defvar *symbols*)
(defvar *targets*)

(defun cl-symbol (x)
  "Return the CL symbol standing for a local or block tag in the generated code."
  (or (gethash x *symbols*)
      (setf (gethash x *symbols*)
            (etypecase x
              (local (make-symbol (format nil "~A_~D" (local-name x) (local-id x))))
              (block-tag (make-symbol (format nil "BLOCK_~A_~D"
                                              (block-tag-name x) (block-tag-id x))))))))

(defun node-to-cl (node)
  "Return a CL form that evaluates the Core IR NODE."
  (let ((*symbols* (make-hash-table :test 'eq))
        (*targets* (make-hash-table :test 'eq)))
    (emit node)))

(defun emit-all (nodes) (mapcar #'emit nodes))

(defun declare-ignorable (symbols)
  `(declare (ignorable ,@symbols)))

(defun emit-recur-target (target locals inits body-thunk)
  "Emit code that binds LOCALS to INITS (already-evaluated CL forms bound in order) and
runs the body produced by BODY-THUNK so that a recur to TARGET restarts it."
  (let* ((syms (mapcar #'cl-symbol locals))
         (temps (mapcar (lambda (s) (make-symbol (format nil "~A_NEXT" s))) syms))
         (block (make-symbol "RECUR_BLOCK"))
         (tag (make-symbol "RECUR_TOP")))
    (setf (gethash target *targets*) (cons tag temps))
    `(let* ,(mapcar #'list syms inits)
       ,(declare-ignorable syms)
       (let ,(mapcar #'list temps syms)
         (block ,block
           (tagbody
              ,tag
              (return-from ,block
                (let ,(mapcar #'list syms temps)
                  ,(declare-ignorable syms)
                  ,(funcall body-thunk)))))))))

(defun emit-arity (arity args)
  "Emit the body of ARITY, taking its parameters from the CL list ARGS."
  (let* ((params (arity-params arity))
         (rest (arity-rest arity))
         (locals (append params (and rest (list rest))))
         (inits (append (loop for i from 0 below (length params) collect `(nth ,i ,args))
                        (and rest `((skein.runtime:rest-args (nthcdr ,(length params) ,args)))))))
    (if (arity-recur-p arity)
        (emit-recur-target arity locals inits (lambda () (emit (arity-body arity))))
        (let ((syms (mapcar #'cl-symbol locals)))
          `(let ,(mapcar #'list syms inits)
             ,(declare-ignorable syms)
             ,(emit (arity-body arity)))))))

(defun emit-fn (node)
  (let* ((args (make-symbol "ARGS"))
         (count (make-symbol "COUNT"))
         (name (fn-node-name node))
         (arities (sort (copy-list (fn-node-arities node))
                        (lambda (a b) (and (not (arity-rest a)) (arity-rest b)))))
         (lambda-form
           `(sb-int:named-lambda ,name (&rest ,args)
              (let ((,count (length ,args)))
                (cond ,@(loop for a in arities
                              for n = (length (arity-params a))
                              collect `((,(if (arity-rest a) '>= '=) ,count ,n)
                                        ,(emit-arity a args)))
                      (t (arity-error ,name ,count ',(node-location node))))))))
    (if (fn-node-self node)
        (let ((self (cl-symbol (fn-node-self node))))
          `(let ((,self nil))
             (setq ,self ,lambda-form)))
        lambda-form)))

(defun emit-call (node)
  (let* ((f (make-symbol "F"))
         (args (fn-node-args-symbols (call-node-args node))))
    `(let ((,f ,(emit (call-node-fn node)))
           ,@(mapcar (lambda (s a) (list s (emit a))) args (call-node-args node)))
       (if (functionp ,f)
           (funcall ,f ,@args)
           (invoke-other ,f ',(node-location node) ,@args)))))

(defun fn-node-args-symbols (args)
  (loop for i from 1 to (length args) collect (make-symbol (format nil "A~D" i))))

(defun emit (node)
  (etypecase node
    (const-node `',(const-node-value node))
    (local-ref-node (cl-symbol (local-ref-node-local node)))
    (var-ref-node `(var-get ',(var-ref-node-var node) ',(node-location node)))
    (if-node `(if (truthy-p ,(emit (if-node-test node)))
                  ,(emit (if-node-then node))
                  ,(emit (if-node-else node))))
    (do-node `(progn ,@(emit-all (do-node-forms node))))
    (def-node (if (def-node-init node)
                  `(def-var ',(def-node-var node) ,(emit (def-node-init node)))
                  `',(def-node-var node)))
    (fn-node (emit-fn node))
    (let-node
     (let ((syms (mapcar (lambda (b) (cl-symbol (car b))) (let-node-bindings node))))
       `(let* ,(mapcar (lambda (s b) (list s (emit (cdr b)))) syms (let-node-bindings node))
          ,(declare-ignorable syms)
          ,(emit (let-node-body node)))))
    (letfn-node
     (let ((syms (mapcar (lambda (b) (cl-symbol (car b))) (letfn-node-bindings node))))
       `(let ,(mapcar (lambda (s) (list s nil)) syms)
          ,(declare-ignorable syms)
          (setq ,@(loop for s in syms
                        for b in (letfn-node-bindings node)
                        append (list s (emit (cdr b)))))
          ,(emit (letfn-node-body node)))))
    (loop-node
     (let ((locals (mapcar #'car (loop-node-bindings node)))
           (inits (mapcar (lambda (b) (emit (cdr b))) (loop-node-bindings node))))
       (if (loop-node-recur-p node)
           (emit-recur-target node locals inits (lambda () (emit (loop-node-body node))))
           (let ((syms (mapcar #'cl-symbol locals)))
             `(let* ,(mapcar #'list syms inits)
                ,(declare-ignorable syms)
                ,(emit (loop-node-body node)))))))
    (recur-node
     (destructuring-bind (tag . temps) (gethash (recur-node-target node) *targets*)
       `(progn
          (psetq ,@(loop for temp in temps
                         for arg in (recur-node-args node)
                         append (list temp (emit arg))))
          (go ,tag))))
    (set-node `(setq ,(cl-symbol (set-node-local node)) ,(emit (set-node-value node))))
    (call-node (emit-call node))
    (unwind-protect-node `(unwind-protect ,(emit (unwind-protect-node-body node))
                            ,(emit (unwind-protect-node-cleanup node))))
    (block-node `(block ,(cl-symbol (block-node-tag node)) ,(emit (block-node-body node))))
    (return-from-node `(return-from ,(cl-symbol (return-from-node-tag node))
                         ,(emit (return-from-node-value node))))
    (values-node `(values ,@(emit-all (values-node-args node))))
    (let-values-node
     (let ((body (emit (let-values-node-body node))))
       (dolist (b (reverse (let-values-node-bindings node)) body)
         (let ((syms (mapcar #'cl-symbol (car b))))
           (setf body `(multiple-value-bind ,syms ,(emit (cdr b))
                         ,(declare-ignorable syms)
                         ,body))))))
    (the-node (emit (the-node-expr node)))))

(defun compile-node (node)
  "Compile the Core IR NODE into a CL function of no arguments that evaluates it."
  (let ((form `(lambda ()
                 (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
                 ,(node-to-cl node))))
    ;; Warnings about the generated code (e.g. a constant of the wrong type) describe
    ;; errors that will happen at run time, where they are reported properly.
    (handler-bind ((warning #'muffle-warning))
      (compile nil form))))

(defun eval-node (node)
  "Compile and run the Core IR NODE, returning its value."
  (funcall (compile-node node)))
