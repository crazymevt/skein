;;;; Core IR to Common Lisp forms.

(in-package #:skein.backend.cl)

(defvar *symbols*)
(defvar *targets*)
(defvar *form-locations* nil
  "While compiling, an EQ table from emitted CL forms to the Skein locations they came
from, used to place efficiency notes.")

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

;;; ------------------------------------------------------------------------------------
;;; Types and declarations (DESIGN §12)

(defun cl-type (type location)
  "Translate the Skein type TYPE to a CL type, reporting LOCATION if it is unknown."
  (handler-case (skein.runtime:skein-type-to-cl type)
    (skein.runtime:skein-error (e)
      (error 'skein.runtime:skein-error :location location
                                        :message (skein.runtime:skein-error-message e)))))

(defun binding-declarations (locals location)
  "A DECLARE form for LOCALS: all ignorable, with their declared types."
  `(declare (ignorable ,@(mapcar #'cl-symbol locals))
            ,@(loop for l in locals
                    when (local-type l)
                      collect `(type ,(cl-type (local-type l) location) ,(cl-symbol l)))))

(defun typed-temp-declarations (locals temps location)
  `(declare ,@(loop for l in locals
                    for temp in temps
                    when (local-type l)
                      collect `(type ,(cl-type (local-type l) location) ,temp))))

(defun emit-recur-target (target locals inits body-thunk location)
  "Emit code that binds LOCALS to INITS (CL forms evaluated in order) and runs the body
produced by BODY-THUNK so that a recur to TARGET restarts it. Each iteration gets fresh
bindings, so closures capture the values of their own iteration."
  (let* ((syms (mapcar #'cl-symbol locals))
         (temps (mapcar (lambda (s) (make-symbol (format nil "~A_NEXT" s))) syms))
         (block (make-symbol "RECUR_BLOCK"))
         (tag (make-symbol "RECUR_TOP")))
    (setf (gethash target *targets*) (cons tag temps))
    `(let* ,(mapcar #'list syms inits)
       ,(binding-declarations locals location)
       (let ,(mapcar #'list temps syms)
         ,(typed-temp-declarations locals temps location)
         (block ,block
           (tagbody
              ,tag
              (return-from ,block
                (let ,(mapcar #'list syms temps)
                  ,(binding-declarations locals location)
                  ,(funcall body-thunk)))))))))

;;; ------------------------------------------------------------------------------------
;;; Functions. Every Skein function is a CL lambda with &optional parameters (with
;;; supplied-p flags) for the most fixed parameters any arity has, plus &rest for the
;;; extras, so that a call with a valid argument count allocates nothing (D-036).

(defun emit-arity (arity params supplied more)
  "Emit ARITY's body, taking its parameters from the CL variables PARAMS (whose
supplied-p flags are SUPPLIED) and MORE (the &rest list)."
  (let* ((fixed (arity-params arity))
         (rest (arity-rest arity))
         (n (length fixed))
         (locals (append fixed (and rest (list rest))))
         (inits (append (subseq params 0 n)
                        (and rest
                             `((let ((r ,more))
                                 ,@(loop for p in (reverse (nthcdr n params))
                                         for s in (reverse (nthcdr n supplied))
                                         collect `(when ,s (push ,p r)))
                                 (skein.runtime:rest-args r))))))
         (location (node-location arity))
         (body (if (arity-recur-p arity)
                   (emit-recur-target arity locals inits (lambda () (emit (arity-body arity)))
                                      location)
                   `(let ,(mapcar (lambda (l i) (list (cl-symbol l) i)) locals inits)
                      ,(binding-declarations locals location)
                      ,(emit (arity-body arity))))))
    (if (arity-return-type arity)
        `(the ,(cl-type (arity-return-type arity) location) ,body)
        body)))

(defun emit-fn (node)
  (let* ((name (fn-node-name node))
         (arities (sort (copy-list (fn-node-arities node))
                        (lambda (a b) (and (not (arity-rest a)) (arity-rest b)))))
         (max (reduce #'max arities :key (lambda (a) (length (arity-params a)))))
         (params (loop for i below max collect (make-symbol (format nil "P~D" i))))
         (supplied (loop for i below max collect (make-symbol (format nil "S~D" i))))
         (more (make-symbol "MORE"))
         (count (make-symbol "COUNT"))
         (lambda-form
           `(sb-int:named-lambda ,name
                (&optional ,@(mapcar (lambda (p s) `(,p nil ,s)) params supplied) &rest ,more)
              (declare (ignorable ,@params ,@supplied ,more))
              (let ((,count (cond ,@(loop for s in supplied
                                          for i from 0
                                          collect `((not ,s) ,i))
                                  (t (+ ,max (length ,more))))))
                (cond ,@(loop for a in arities
                              for n = (length (arity-params a))
                              collect `((,(if (arity-rest a) '>= '=) ,count ,n)
                                        ,(emit-arity a params supplied more)))
                      (t (arity-error ,name ,count ',(node-location node))))))))
    (if (fn-node-self node)
        (let ((self (cl-symbol (fn-node-self node))))
          `(let ((,self nil))
             (setq ,self ,lambda-form)))
        lambda-form)))

;;; ------------------------------------------------------------------------------------
;;; Calls

(defun inline-entry (node)
  "If NODE calls a var whose calls are inlined (D-036), return the inline entry."
  (let ((fn (call-node-fn node)))
    (and (var-ref-node-p fn)
         (skein.runtime:inline-entry-for (var-ref-node-var fn)
                                         (length (call-node-args node))))))

(defun emit-inline (entry node)
  (apply (skein.runtime:inline-entry-emitter entry) (emit-all (call-node-args node))))

(defun check-primitive-arity (node)
  "Calls to inlined primitives with an impossible argument count fail when compiled."
  (let ((fn (call-node-fn node)))
    (when (var-ref-node-p fn)
      (let ((expected (skein.runtime:inline-arity-mismatch (var-ref-node-var fn)
                                                           (length (call-node-args node)))))
        (when expected
          (error 'skein.runtime:arity-error
                 :location (node-location node)
                 :function-name (skein.runtime:var-qualified-name (var-ref-node-var fn))
                 :argument-count (length (call-node-args node))
                 :message (format nil "wrong number of arguments (~D) passed to ~A, which ~
                                       takes ~A"
                                  (length (call-node-args node))
                                  (skein.runtime:var-qualified-name (var-ref-node-var fn))
                                  expected)))))))

(defun emit-call (node)
  (check-primitive-arity node)
  (let ((entry (inline-entry node)))
    (if entry
        (let ((form (emit-inline entry node)))
          (if (skein.runtime:inline-entry-test-p entry) `(skein.runtime:bool ,form) form))
        (let* ((f (make-symbol "F"))
               (args (loop for i from 1 to (length (call-node-args node))
                           collect (make-symbol (format nil "A~D" i))))
               (fn-node (call-node-fn node))
               (ftype (and (var-ref-node-p fn-node)
                           (skein.runtime:var-ftype (var-ref-node-var fn-node))))
               (call `(let ((,f ,(emit fn-node))
                            ,@(mapcar (lambda (s a) (list s (emit a))) args (call-node-args node)))
                        (if (functionp ,f)
                            (funcall ,f ,@args)
                            (invoke-other ,f ',(node-location node) ,@args)))))
          ;; A declaimed (fn [args] ret) tells SBCL the type of the result.
          (if (and ftype (skein.runtime:plist-p ftype))
              (let ((ret (skein.runtime:seq-first
                          (skein.runtime:seq-next (skein.runtime:seq-next ftype)))))
                `(the ,(cl-type ret (node-location node)) ,call))
              call)))))

(defun emit-test (node)
  "Emit NODE as a CL boolean: an inlined comparison directly, anything else through
TRUTHY-P (only nil and false are false)."
  (let ((entry (and (call-node-p node) (inline-entry node))))
    (if (and entry (skein.runtime:inline-entry-test-p entry))
        (emit-inline entry node)
        `(truthy-p ,(emit node)))))

;;; ------------------------------------------------------------------------------------

(defun emit (node)
  "Return the CL form for NODE, remembering which Skein location it came from."
  (let ((form (emit-1 node)))
    (when (and *form-locations* (consp form) (node-location node)
               (not (gethash form *form-locations*)))
      (setf (gethash form *form-locations*) (node-location node)))
    form))

(defun emit-1 (node)
  (etypecase node
    (const-node `',(const-node-value node))
    (local-ref-node (cl-symbol (local-ref-node-local node)))
    (var-ref-node `(var-get ',(var-ref-node-var node) ',(node-location node)))
    (if-node `(if ,(emit-test (if-node-test node))
                  ,(emit (if-node-then node))
                  ,(emit (if-node-else node))))
    (do-node `(progn ,@(emit-all (do-node-forms node))))
    (def-node (if (def-node-init node)
                  `(def-var ',(def-node-var node) ,(emit (def-node-init node)))
                  `',(def-node-var node)))
    (fn-node (emit-fn node))
    (let-node
     (let ((locals (mapcar #'car (let-node-bindings node))))
       `(let* ,(mapcar (lambda (b) (list (cl-symbol (car b)) (emit (cdr b))))
                       (let-node-bindings node))
          ,(binding-declarations locals (node-location node))
          ,(emit (let-node-body node)))))
    (letfn-node
     (let ((locals (mapcar #'car (letfn-node-bindings node))))
       `(let ,(mapcar (lambda (l) (list (cl-symbol l) nil)) locals)
          (declare (ignorable ,@(mapcar #'cl-symbol locals)))
          (setq ,@(loop for b in (letfn-node-bindings node)
                        append (list (cl-symbol (car b)) (emit (cdr b)))))
          ,(emit (letfn-node-body node)))))
    (loop-node
     (let ((locals (mapcar #'car (loop-node-bindings node)))
           (inits (mapcar (lambda (b) (emit (cdr b))) (loop-node-bindings node))))
       (if (loop-node-recur-p node)
           (emit-recur-target node locals inits (lambda () (emit (loop-node-body node)))
                              (node-location node))
           `(let* ,(mapcar (lambda (l i) (list (cl-symbol l) i)) locals inits)
              ,(binding-declarations locals (node-location node))
              ,(emit (loop-node-body node))))))
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
         (setf body `(multiple-value-bind ,(mapcar #'cl-symbol (car b)) ,(emit (cdr b))
                       ,(binding-declarations (car b) (node-location node))
                       ,body)))))
    (the-node `(the ,(cl-type (the-node-type node) (node-location node))
                    ,(emit (the-node-expr node))))
    (locally-node
     (let* ((policy (locally-node-policy node))
            (speed (cdr (assoc "speed" policy :test #'string=))))
       `(locally (declare (optimize ,@(loop for (quality . level) in policy
                                            collect (list (intern (string-upcase quality) :cl)
                                                          level)))
                          ;; Notes are shown only for code that asks for speed itself.
                          ,@(and speed (>= speed 2)
                                 '((sb-ext:unmuffle-conditions sb-ext:compiler-note))))
          ,(emit (locally-node-body node)))))
    (throw-condition-node `(skein.runtime:throw-condition
                            ,(emit (throw-condition-node-condition node))))
    (handler-bind-node (emit-handler-bind node))
    (restart-bind-node (emit-restart-bind node))))

(defun emit-handler-bind (node)
  "Handlers are tried in order. Each type is evaluated once, on entry, to a condition
type; the CL handler tests the condition against its class."
  (let ((entries (loop for (type . handler) in (handler-bind-node-bindings node)
                       collect (list (make-symbol "TYPE") (make-symbol "HANDLER")
                                     (emit type) (emit handler)))))
    `(let (,@(loop for (tsym hsym type handler) in entries
                   collect `(,tsym (skein.runtime:condition-type-class
                                    (skein.runtime:find-condition-type ,type)))
                   collect `(,hsym ,handler)))
       (handler-bind (,@(loop for (tsym hsym) in entries
                              collect `(condition (lambda (c)
                                                    (when (typep c ,tsym)
                                                      (if (functionp ,hsym)
                                                          (funcall ,hsym c)
                                                          (skein.runtime:invoke-other
                                                           ,hsym nil c)))))))
         ,(emit (handler-bind-node-body node))))))

(defun emit-restart-bind (node)
  (let ((entries (loop for (name fn report) in (restart-bind-node-bindings node)
                       collect (list (skein.runtime:restart-cl-name name)
                                     (make-symbol "RESTART") (make-symbol "REPORT")
                                     (emit fn) (emit report)))))
    `(let (,@(loop for (nil fsym rsym fn report) in entries
                   collect `(,fsym ,fn)
                   collect `(,rsym ,report)))
       (restart-bind (,@(loop for (cl-name fsym rsym) in entries
                              collect `(,cl-name
                                        (lambda (&rest args)
                                          (if (functionp ,fsym)
                                              (apply ,fsym args)
                                              (apply #'skein.runtime:invoke-other
                                                     ,fsym nil args)))
                                        :report-function
                                        (lambda (stream)
                                          (write-string (if ,rsym
                                                            (skein.runtime:display-string ,rsym)
                                                            ,(symbol-name cl-name))
                                                        stream)))))
         ,(emit (restart-bind-node-body node))))))

(defparameter *profiles*
  '(:dev ((speed 1) (safety 3) (debug 2))
    :release ((speed 3) (safety 1) (debug 0)))
  "The optimization profiles of DESIGN §12.3. (safety 0) is never set by a profile.")

(defvar *profile* :dev
  "The profile that code is compiled with: :dev (the default) or :release.")

(defun compile-node (node)
  "Compile the Core IR NODE into a CL function of no arguments that evaluates it.
SBCL's optimization notes about code that declares (optimize (speed 2)) or more are
re-signaled as Skein EFFICIENCY-NOTEs after compiling."
  (let* ((*form-locations* (make-hash-table :test 'eq))
         (form `(lambda ()
                  (declare (optimize ,@(getf *profiles* *profile*))
                           (sb-ext:muffle-conditions sb-ext:compiler-note))
                  ,(node-to-cl node)))
         (notes '())
         (fn (handler-bind ((sb-ext:compiler-note
                              (lambda (n)
                                (let ((note (translate-note n)))
                                  (when (and note (not (member note notes :test #'equal)))
                                    (push note notes)))
                                (muffle-warning n)))
                            ;; Warnings about the generated code (e.g. a constant of the
                            ;; wrong type) describe errors that will happen at run time,
                            ;; where they are reported properly.
                            (warning #'muffle-warning))
               (compile nil form))))
    (dolist (note (nreverse notes))
      (warn 'efficiency-note :location (car note) :message (cdr note)))
    fn))

;;; ------------------------------------------------------------------------------------
;;; Efficiency notes (DESIGN §12.4): SBCL's compiler notes, in Skein terms

(define-condition efficiency-note (style-warning)
  ((message :initarg :message :reader efficiency-note-message)
   (location :initarg :location :reader efficiency-note-location))
  (:report (lambda (c stream)
             (format stream "efficiency note at ~A: ~A"
                     (skein.syntax:format-location (efficiency-note-location c))
                     (efficiency-note-message c))))
  (:documentation "Explains why the compiler could not optimize something in code compiled
with speed 2 or more, such as generic arithmetic on values of unknown type."))

(defparameter *note-type-names*
  '(("(SIGNED-BYTE 8)" . "i8") ("(SIGNED-BYTE 16)" . "i16") ("(SIGNED-BYTE 32)" . "i32")
    ("(SIGNED-BYTE 64)" . "i64") ("(UNSIGNED-BYTE 8)" . "u8") ("(UNSIGNED-BYTE 16)" . "u16")
    ("(UNSIGNED-BYTE 32)" . "u32") ("(UNSIGNED-BYTE 64)" . "u64")
    ("DOUBLE-FLOAT" . "f64") ("SINGLE-FLOAT" . "f32") ("FIXNUM" . "fixnum")
    ("INTEGER" . "integer") ("RATIONAL" . "integer") ("REAL" . "number") ("NUMBER" . "number")
    ("FLOAT" . "float") ("FUNCTION" . "fn") ("UNSIGNED-BYTE" . "non-negative integer"))
  "SBCL type names in notes and the Skein names to show instead.")

(defun replace-all (string old new)
  (with-output-to-string (out)
    (loop with start = 0
          for pos = (search old string :start2 start)
          do (write-string string out :start start :end (or pos (length string)))
             (if pos (progn (write-string new out) (setf start (+ pos (length old))))
                 (return)))))

(defun note-location (context)
  "The Skein location of the CL form a note is about, or NIL."
  (ignore-errors
   (let ((path (sb-c::node-source-path context)))
     ;; Try the form itself, then its enclosing forms.
     (loop for p = path then (cons (first p) (cddr p))
           while (cddr p)
           do (let ((loc (gethash (sb-c::find-original-source p) *form-locations*)))
                (when loc (return loc)))))))

(defun translate-note (note)
  "Turn an SBCL compiler NOTE into (location . message), or NIL if it is noise or cannot
be traced to Skein code."
  (let* ((text (let ((*print-pretty* nil)) (princ-to-string note)))
         (location (note-location sb-c::*compiler-error-context*)))
    (unless (or (null location) (search "deleting unreachable code" text))
      (dolist (pair *note-type-names*)
        (setf text (replace-all text (car pair) (cdr pair))))
      (setf text (replace-all text "doing float to pointer coercion" "boxing a float"))
      (setf text (replace-all text "a T," "of unknown type,"))
      (setf text (replace-all text "a integer" "an integer"))
      (setf text (replace-all text ".The" ". The"))
      (cons location (collapse-whitespace text)))))

(defun collapse-whitespace (text)
  (with-output-to-string (out)
    (let ((space nil) (started nil))
      (loop for c across text
            do (if (member c '(#\Space #\Newline #\Tab))
                   (setf space t)
                   (progn (when (and space started) (write-char #\Space out))
                          (setf space nil started t)
                          (write-char c out)))))))

(defun eval-node (node)
  "Compile and run the Core IR NODE, returning its value."
  (funcall (compile-node node)))
