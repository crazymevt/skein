;;;; The expander written in Skein (lib/skein/compiler/expander.skn, M1.7): checked
;;;; against the Phase 0 expander by expanding every .skn file in the repository with both
;;;; and comparing the Core IR, locations included.

(in-package #:skein.tests)

(def-suite skein.expander-in-skein :in all
  :description "The expander written in Skein, checked against the Phase 0 expander.")

(in-suite skein.expander-in-skein)

;;; ------------------------------------------------------------------------------------
;;; Calling the Skein expander

(defun skein-expander-function (name)
  "The function skein.compiler.expander/NAME, loading the namespace the first time."
  (let ((ns (skein.runtime:find-namespace "skein.compiler.expander")))
    (unless (and ns (skein.runtime:find-own-var ns name))
      (ev "(ns expander-bridge (:require [skein.compiler.expander]))")
      (setf ns (skein.runtime:find-namespace "skein.compiler.expander")))
    (skein.runtime:var-get (skein.runtime:find-own-var ns name) nil)))

(defun call-skein-expander (name &rest args)
  "Call skein.compiler.expander/NAME, turning its compile-error into Phase 0's."
  (handler-bind
      ((error (lambda (c)
                (let ((type (skein.runtime::defined-type-of c)))
                  (when (and type (string= (skein.runtime:condition-type-name type)
                                           "skein.compiler.expander/compile-error"))
                    (error 'skein.expander:compile-error
                           :message (skein.runtime::condition-slot c "message")
                           :location (from-skein-location
                                      (skein.runtime::condition-slot c "location"))))))))
    (apply (skein-expander-function name) args)))

(defun to-skein-location (loc)
  (and loc
       (skein.runtime::map-from-pairs
        (list (kw "file") (skein.syntax:source-location-file loc)
              (kw "line") (skein.syntax:source-location-line loc)
              (kw "column") (skein.syntax:source-location-column loc)
              (kw "end-line") (skein.syntax:source-location-end-line loc)
              (kw "end-column") (skein.syntax:source-location-end-column loc)))))

(defun to-skein-syntax (s)
  "The CL syntax object S as the Skein reader would make it (a map)."
  (let ((kind (skein.syntax:syntax-kind s)))
    (skein.runtime::map-from-pairs
     (append (list (kw "kind") (kw (string-downcase (symbol-name kind)))
                   (kw "datum") (if (eq kind :atom)
                                    (skein.syntax:syntax-datum s)
                                    (skein.runtime:vector-from-list
                                     (mapcar #'to-skein-syntax (skein.syntax:syntax-items s))))
                   (kw "loc") (to-skein-location (skein.syntax:syntax-location s)))
             (and (skein.syntax:syntax-meta s)
                  (list (kw "meta") (to-skein-syntax (skein.syntax:syntax-meta s))))))))

;;; ------------------------------------------------------------------------------------
;;; Core IR: the Skein expander's maps as Phase 0's structs, and both as canonical text

(defparameter *ir-shapes*
  '(("const" skein.ir:const-node (value :value))
    ("local-ref" skein.ir:local-ref-node (local :local))
    ("var-ref" skein.ir:var-ref-node (var :var))
    ("if" skein.ir:if-node (test :node) (then :node) (else :node))
    ("do" skein.ir:do-node (forms :nodes))
    ("def" skein.ir:def-node (var :var) (init :node))
    ("fn" skein.ir:fn-node (name :value) (self :local) (arities :nodes))
    ("arity" skein.ir:arity (params :locals) (rest :local) (recur-p :flag)
     (return-type :value) (body :node))
    ("let" skein.ir:let-node (bindings :bindings) (body :node))
    ("letfn" skein.ir:letfn-node (bindings :bindings) (body :node))
    ("loop" skein.ir:loop-node (recur-p :flag) (bindings :bindings) (body :node))
    ("recur" skein.ir:recur-node (target :target) (args :nodes))
    ("set" skein.ir:set-node (local :local) (value :node))
    ("call" skein.ir:call-node (fn :node) (args :nodes))
    ("unwind-protect" skein.ir:unwind-protect-node (body :node) (cleanup :node))
    ("block" skein.ir:block-node (tag :tag) (body :node))
    ("return-from" skein.ir:return-from-node (tag :tag) (value :node))
    ("values" skein.ir:values-node (args :nodes))
    ("let-values" skein.ir:let-values-node (bindings :multi-bindings) (body :node))
    ("the" skein.ir:the-node (type :value) (expr :node))
    ("locally" skein.ir:locally-node (policy :policy) (body :node))
    ("throw-condition" skein.ir:throw-condition-node (condition :node))
    ("handler-bind" skein.ir:handler-bind-node (bindings :node-pairs) (body :node))
    ("restart-bind" skein.ir:restart-bind-node (bindings :restarts) (body :node)))
  "Each Core IR node: its op in the Skein expander's maps, its Phase 0 struct, and its
fields with their kinds. The maps use the struct's field names as keys.")

(defun ir-accessor (struct field)
  (symbol-function (find-symbol (format nil "~A-~A" struct field) '#:skein.ir)))

(defun ir-get (map name)
  "MAP's value for the keyword NAME, which may be qualified, as in \"local/id\"."
  (let ((slash (position #\/ name)))
    (skein.runtime::map-get map (if slash
                                    (skein.runtime:intern-kw (subseq name (1+ slash))
                                                             (subseq name 0 slash))
                                    (skein.runtime:intern-kw name)))))

(defun ir-list (value) (skein.runtime:seq-to-cl value))

(defun from-skein-ir (node)
  "The Skein expander's Core IR NODE as Phase 0 Core IR structs. Locals and block tags
with the same id become the same object, and a recur's target id becomes its node."
  (let ((locals (make-hash-table)) (tags (make-hash-table)) (targets (make-hash-table)))
    (labels ((local (m)
               (and m
                    (let ((id (ir-get m "local/id")))
                      (or (gethash id locals)
                          (setf (gethash id locals)
                                (skein.ir:make-local
                                 (ir-get m "local/name")
                                 :mutable-p (skein.runtime:truthy-p (ir-get m "local/mutable?"))
                                 :type (skein.runtime::skein-atom-value
                                        (ir-get m "local/type"))))))))
             (tag (m)
               (let ((id (ir-get m "tag/id")))
                 (or (gethash id tags)
                     (setf (gethash id tags) (skein.ir:make-block-tag (ir-get m "tag/name"))))))
             (field (kind v)
               (ecase kind
                 ((:value :var) v)
                 (:node (conv v))
                 (:nodes (mapcar #'conv (ir-list v)))
                 (:local (local v))
                 (:locals (mapcar #'local (ir-list v)))
                 (:flag (skein.runtime:truthy-p v))
                 (:target (or (gethash v targets) (error "recur to an unknown target ~A" v)))
                 (:tag (tag v))
                 (:bindings (loop for b in (ir-list v)
                                  collect (destructuring-bind (l init) (ir-list b)
                                            (cons (local l) (conv init)))))
                 (:multi-bindings (loop for b in (ir-list v)
                                        collect (destructuring-bind (ls init) (ir-list b)
                                                  (cons (mapcar #'local (ir-list ls))
                                                        (conv init)))))
                 (:policy (loop for b in (ir-list v)
                                collect (destructuring-bind (q level) (ir-list b)
                                          (cons q level))))
                 (:node-pairs (loop for b in (ir-list v)
                                    collect (destructuring-bind (ty h) (ir-list b)
                                              (cons (conv ty) (conv h)))))
                 (:restarts (loop for b in (ir-list v)
                                  collect (destructuring-bind (name f r) (ir-list b)
                                            (list name (conv f) (conv r)))))))
             (conv (m)
               (and m
                    (let* ((op (skein.runtime:kw-name (ir-get m "op")))
                           (shape (or (assoc op *ir-shapes* :test #'string=)
                                      (error "unknown Core IR op ~A" op)))
                           (struct (second shape))
                           (target-p (member op '("arity" "loop") :test #'string=))
                           (n (apply (symbol-function
                                      (find-symbol (format nil "MAKE-~A" struct) '#:skein.ir))
                                     :location (from-skein-location (ir-get m "loc"))
                                     (loop for (name kind) in (cddr shape)
                                           for key = (string-downcase (symbol-name name))
                                           unless (and target-p (eq name 'body))
                                             append (list (intern (symbol-name name) :keyword)
                                                          (field kind (ir-get m key)))))))
                      ;; A loop's or arity's recurs refer to it, so it exists before its body.
                      (when target-p
                        (setf (gethash (ir-get m "id") targets) n
                              (slot-value n (find-symbol "BODY" '#:skein.ir))
                              (conv (ir-get m "body"))))
                      n))))
      (conv node))))

(defun canonical-location (l)
  (if l
      (format nil "~A:~D:~D-~D:~D" (skein.syntax:source-location-file l)
              (skein.syntax:source-location-line l) (skein.syntax:source-location-column l)
              (skein.syntax:source-location-end-line l) (skein.syntax:source-location-end-column l))
      "?"))

(defun renumber-gensyms (text)
  "TEXT with each __<digits> numbered by its order of appearance."
  (let ((seen (make-hash-table :test 'equal)))
    (with-output-to-string (out)
      (loop with i = 0
            while (< i (length text))
            do (if (and (< (+ i 2) (length text))
                        (string= "__" text :start2 i :end2 (+ i 2))
                        (digit-char-p (char text (+ i 2))))
                   (let* ((end (or (position-if-not #'digit-char-p text :start (+ i 2))
                                   (length text)))
                          (digits (subseq text (+ i 2) end)))
                     (format out "__#~D" (or (gethash digits seen)
                                             (setf (gethash digits seen)
                                                   (hash-table-count seen))))
                     (setf i end))
                   (progn (write-char (char text i) out) (incf i)))))))

(defun canonical-ir (node)
  "NODE (Phase 0 Core IR) as canonical text: ids and gensym numbers become their order of
appearance, so two expansions compare as text."
  (let ((ids (make-hash-table :test 'eq)))
    (labels ((id (x) (or (gethash x ids) (setf (gethash x ids) (hash-table-count ids))))
             (value (x) (handler-case (skein.runtime:readable-string x)
                          (error () (format nil "#<~A>" (type-of x)))))
             (local (l)
               (if l
                   (format nil "~A#~D~:[~;!~]~@[:~A~]" (skein.ir:local-name l) (id l)
                           (skein.ir:local-mutable-p l)
                           (and (skein.ir:local-type l) (value (skein.ir:local-type l))))
                   "-"))
             (field (kind v)
               (ecase kind
                 (:value (value v))
                 (:var (skein.runtime:var-qualified-name v))
                 (:node (p v))
                 (:nodes (format nil "[~{~A~^ ~}]" (mapcar #'p v)))
                 (:local (local v))
                 (:locals (format nil "[~{~A~^ ~}]" (mapcar #'local v)))
                 (:flag (if v "yes" "no"))
                 (:target (format nil "T~D" (id v)))
                 (:tag (format nil "~A%~D" (skein.ir:block-tag-name v) (id v)))
                 (:bindings (format nil "[~{~A~^ ~}]"
                                    (loop for (l . init) in v
                                          collect (format nil "~A ~A" (local l) (p init)))))
                 (:multi-bindings (format nil "[~{~A~^ ~}]"
                                          (loop for (ls . init) in v
                                                collect (format nil "[~{~A~^ ~}] ~A"
                                                                (mapcar #'local ls) (p init)))))
                 (:policy (format nil "[~{~A~^ ~}]"
                                  (loop for (q . level) in v collect (format nil "~A=~A" q level))))
                 (:node-pairs (format nil "[~{~A~^ ~}]"
                                      (loop for (ty . h) in v
                                            collect (format nil "~A ~A" (p ty) (p h)))))
                 (:restarts (format nil "[~{~A~^ ~}]"
                                    (loop for (name f r) in v
                                          collect (format nil "~A ~A ~A" (value name) (p f)
                                                          (p r)))))))
             (p (n)
               (if (null n)
                   "-"
                   (let ((shape (find-if (lambda (s) (typep n (second s))) *ir-shapes*)))
                     (format nil "(~A@~A~@[ T~D~]~{ ~A~})" (first shape)
                             (canonical-location (skein.ir:node-location n))
                             (and (member (first shape) '("arity" "loop") :test #'string=)
                                  (id n))
                             (loop for (name kind) in (cddr shape)
                                   collect (field kind (funcall (ir-accessor (second shape)
                                                                             name)
                                                                n))))))))
      (renumber-gensyms (p node)))))

(defun canonical-syntax (s)
  "The syntax object S as text with metadata and every location."
  (labels ((p (s)
             (format nil "~@[^~A ~]~A@~A"
                     (and (skein.syntax:syntax-meta s) (p (skein.syntax:syntax-meta s)))
                     (if (eq (skein.syntax:syntax-kind s) :atom)
                         (skein.runtime:readable-string (skein.syntax:syntax-datum s))
                         (format nil "~A~{~A~^ ~}~A"
                                 (ecase (skein.syntax:syntax-kind s)
                                   (:list "(") (:vector "[") (:map "{") (:set "#{"))
                                 (mapcar #'p (skein.syntax:syntax-items s))
                                 (ecase (skein.syntax:syntax-kind s)
                                   (:list ")") (:vector "]") (:map "}") (:set "}"))))
                     (canonical-location (skein.syntax:syntax-location s)))))
    (renumber-gensyms (p s))))

;;; ------------------------------------------------------------------------------------
;;; Comparing the two expanders on files

(defvar *errors-seen* '()
  "The error outcomes so far, most recent first.")

(defun outcome (thunk)
  "The text THUNK returns, or ERROR: and the message and location of a compile error."
  (handler-case (funcall thunk)
    (skein.runtime:skein-error (e)
      (let ((text (format nil "ERROR: ~A @~A" (skein.runtime:skein-error-message e)
                          (canonical-location (skein.runtime:skein-error-location e)))))
        (push text *errors-seen*)
        text))))

(defun first-difference (a b)
  (let ((i (or (mismatch a b) 0)))
    (format nil "Phase 0:  ...~A~%in Skein: ...~A"
            (subseq a (max 0 (- i 60)) (min (length a) (+ i 120)))
            (subseq b (max 0 (- i 60)) (min (length b) (+ i 120))))))

(defvar *mismatches*)

(defun defining-call-p (ir)
  "True if IR calls one of skein.core's %define- functions (defstruct, defclass, ...)."
  (and (skein.ir:call-node-p ir)
       (skein.ir:var-ref-node-p (skein.ir:call-node-fn ir))
       (let ((var (skein.ir:var-ref-node-var (skein.ir:call-node-fn ir))))
         (and (string= (skein.runtime:namespace-name (skein.runtime:var-namespace var))
                       "skein.core")
              (eql 0 (search "%define-" (skein.runtime:var-name var)))))))

(defun evaluate-p (p0-ir library-form-p)
  "Whether to run a top-level form after comparing it: ns and defmacro forms (as skein
build does), defs of functions, which macros later in the file may call, and the
definitions of structs, classes, generic functions and condition types, whose names
later forms use."
  (or library-form-p
      (defining-call-p p0-ir)
      (and (skein.ir:def-node-p p0-ir)
           (or (skein.ir:fn-node-p (skein.ir:def-node-init p0-ir))
               (defining-call-p (skein.ir:def-node-init p0-ir))))))

(defun compare-toplevel (form sk-form library-form-p)
  "Expand FORM with Phase 0 and SK-FORM (the same form as a map) with the Skein expander,
compare them, and treat a (do ...) expansion's subforms as top-level forms."
  (let* ((ns skein.runtime:*current-namespace*)
         (sk-expanded nil)
         (sk-text (outcome (lambda ()
                             (setf sk-expanded
                                   (call-skein-expander
                                    "macroexpand" sk-form
                                    (call-skein-expander "make-env" ns)))
                             (canonical-syntax (from-skein-syntax sk-expanded)))))
         (p0-expanded nil)
         (p0-text (outcome (lambda ()
                             (setf p0-expanded (skein.expander:macroexpand
                                                form (skein.expander:make-env :namespace ns)))
                             (canonical-syntax p0-expanded)))))
    (cond ((string/= p0-text sk-text)
           (push (format nil "~A: the expansions differ~%~A"
                         (canonical-location (skein.syntax:syntax-location form))
                         (first-difference p0-text sk-text))
                 *mismatches*))
          ((null p0-expanded))
          ((skein.expander:toplevel-do-p p0-expanded)
           (loop for sub in (rest (skein.syntax:syntax-items p0-expanded))
                 for sk-sub in (rest (skein.runtime:seq-to-cl (skein-get sk-expanded "datum")))
                 do (compare-toplevel sub sk-sub library-form-p)))
          (t
           (let* ((sk-ir-text (outcome (lambda ()
                                         (canonical-ir
                                          (from-skein-ir
                                           (call-skein-expander "analyze-toplevel"
                                                                sk-expanded ns))))))
                  (p0-ir nil)
                  (p0-ir-text (outcome (lambda ()
                                         (setf p0-ir (skein.expander:analyze-toplevel
                                                      p0-expanded ns))
                                         (canonical-ir p0-ir)))))
             (if (string/= p0-ir-text sk-ir-text)
                 (push (format nil "~A: the Core IR differs~%~A"
                               (canonical-location (skein.syntax:syntax-location form))
                               (first-difference p0-ir-text sk-ir-text))
                       *mismatches*)
                 (when (and p0-ir (evaluate-p p0-ir library-form-p))
                   (skein.backend.cl:eval-toplevel p0-expanded))))))))

(defun compare-expanders-on-file (path)
  "Expand every top-level form of the file at PATH with both expanders. Returns the
differences found, as messages, and how many top-level forms there were."
  (let ((skein.runtime:*source-paths* (skein.backend.cl:program-source-paths path)))
    (with-open-file (s path :external-format :utf-8)
      (compare-expanders-on-stream s (namestring path) "user"))))

(defun compare-expanders-on-stream (s file namespace)
  "Expand every top-level form on the stream S, starting in NAMESPACE, with both
expanders. Returns the differences found, as messages, and how many top-level forms there
were."
  (let* ((*mismatches* '())
         (count 0)
         (before (skein.runtime::all-namespaces))
         (entered '())
         (skein.runtime:*current-namespace* (skein.runtime:ensure-namespace namespace)))
    ;; Only part of the file runs, so forget the namespaces it declares; a later require
    ;; then loads them properly.
    (unwind-protect
      (let ((reader (skein.reader:make-reader
                     s :file file :namespace namespace
                     :resolve-alias (lambda (alias)
                                      (let ((ns (skein.runtime:find-alias
                                                 skein.runtime:*current-namespace* alias)))
                                        (and ns (skein.runtime:namespace-name ns)))))))
        (loop
          (setf (skein.reader:reader-namespace reader)
                (skein.runtime:namespace-name skein.runtime:*current-namespace*))
          (pushnew skein.runtime:*current-namespace* entered)
          (let ((form (skein.reader:read-form reader :eof-value :eof)))
            (when (eq form :eof) (return))
            (incf count)
            (compare-toplevel form (to-skein-syntax form)
                              (member (skein.backend.c::form-head form) '("ns" "defmacro")
                                      :test #'equal)))))
      (pushnew skein.runtime:*current-namespace* entered)
      (dolist (ns entered)
        (unless (member ns before)
          (skein.runtime::remove-namespace (skein.runtime:namespace-name ns)))))
    (values (reverse *mismatches*) count)))

(defun needs-a-dependency-p (path)
  "True for the files that require the SDL3 bindings, which are a git dependency (M2.12,
D-095) that Phase 0 can't fetch: the SDL examples and Driftrock's main and draw."
  (let ((s (namestring path)))
    (or (search "/examples/sdl/" s)
        (search "/examples/driftrock/main.skn" s)
        (search "/examples/driftrock/draw.skn" s))))

(defun native-only-p (path)
  "True for the programs that only run natively: the manual's generator, its tests and
its examples (doc/, D-111), which use regular expressions (D-105) and the evaluator."
  (search "/doc/" (namestring path)))

(test expander-in-skein-matches-phase-0-on-every-file
  ;; The exit criterion of M1.7: the same Core IR as Phase 0 for every .skn file.
  (let ((total 0))
    (dolist (path (remove-if (lambda (p) (or (needs-a-dependency-p p) (native-only-p p)))
                             (repository-skn-files)))
      ;; A file whose foreign library is missing (SDL3, say) can't load its requires.
      (handler-case
          (multiple-value-bind (mismatches count) (compare-expanders-on-file path)
            (incf total count)
            (is (null mismatches) "~A:~%~{~A~^~%~}" (namestring path)
                (subseq mismatches 0 (min 3 (length mismatches)))))
        (skein.ffi:ffi-error (e)
          (skip "~A: ~A" (file-namestring path) e))))
    (is (> total 1000) "only ~D top-level forms were compared" total)))

;;; Compile errors: the same message and location from both expanders

(defun compile-fails-sources ()
  "The source strings of every (compile-fails \"source\" ...) in the test files."
  (let ((sources '()))
    (dolist (name '("eval" "macros" "conditions" "objects" "types"))
      (with-open-file (in (asdf:system-relative-pathname "skein" (format nil "tests/~A.lisp" name)))
        (let ((*package* (find-package '#:skein.tests))
              (*read-eval* nil))
          (loop for form = (read in nil in)
                until (eq form in)
                do (labels ((walk (x)
                              (when (consp x)
                                (when (and (eq (car x) 'compile-fails) (stringp (second x)))
                                  (push (second x) sources))
                                (loop for y on x while (consp y) do (walk (car y))))))
                     (walk form))))))
    (nreverse sources)))

(test expander-in-skein-reports-the-same-compile-errors
  (let ((sources (compile-fails-sources))
        (errors 0))
    (is (> (length sources) 60) "found only ~D compile-fails cases" (length sources))
    (loop for source in sources
          for i from 0
          do (let ((before (length *errors-seen*)))
               (with-input-from-string (s source)
                 (let ((mismatches (compare-expanders-on-stream
                                    s "t.skn" (format nil "expander-errors-~D" i))))
                   (is (null mismatches) "~S:~%~{~A~^~%~}" source mismatches)))
               (when (> (length *errors-seen*) before) (incf errors))))
    ;; Most cases fail while expanding; a few fail later, when the code runs.
    (is (> errors 50) "only ~D of ~D cases gave a compile error" errors (length sources))))

;;; destructure: the same binding vector (up to gensym numbers) or the same error

(defun library-function (name)
  "The function skein.core.native/NAME (lib/skein/core/native.skn)."
  (skein.runtime:var-get (skein.runtime:find-own-var
                          (skein.runtime:require-namespace "skein.core.native") name)
                         nil))

(defun destructure-outcome (fn bindings)
  (handler-case (renumber-gensyms (skein.runtime:readable-string (funcall fn bindings)))
    (error (e) (format nil "ERROR: ~A" (if (typep e 'skein.runtime:skein-error)
                                           (skein.runtime:skein-error-message e)
                                           (skein.runtime::condition-report e))))))

(defun destructure-matches-p (pattern-text)
  "Check that both destructure functions agree on the binding vector PATTERN-TEXT."
  (let* ((bindings (ev (format nil "'~A" pattern-text)))
         (p0 (destructure-outcome
              (lambda (b) (skein.runtime:vector-from-list (skein.expander::destructure b)))
              bindings))
         (sk (destructure-outcome (library-function "destructure") bindings)))
    (is (string= p0 sk) "~A~%Phase 0:  ~A~%in Skein: ~A" pattern-text p0 sk)))

(defparameter *destructure-patterns*
  '("[a 1]" "[[a b] v]" "[[a & r] v]" "[[a b :as all] v]" "[[a [b [c]]] v]"
    "[[& [x y]] v]" "[{:keys [a b]} m]" "[{:keys [a/b c]} m]" "[{:strs [s]} m]"
    "[{:syms [x n/y]} m]" "[{a :a b :b} m]" "[{:keys [a] :or {a 1} :as all} m]"
    "[{[x y] :pos} m]" "[{:ns/keys [a b/c]} m]" "[{:keys [:k :q/z]} m]"
    "[[a {:keys [b]} & {:keys [c]}] v]" "[a 1 [b c] v {d :d} m]"
    ;; Errors
    "[a]" "a" "[[& ] v]" "[[a :as] v]" "[[a :as 1] v]" "[{:keys a} m]" "[1 2]"
    "[& v]" "[{:keys [1]} m]"))

(test destructure-in-skein-matches-phase-0
  (dolist (p *destructure-patterns*) (destructure-matches-p p)))

(defun random-pattern (rs depth)
  (let ((names '("a" "b" "c" "d" "x" "y")))
    (flet ((name () (nth (random (length names) rs) names)))
      (if (or (zerop depth) (< (random 10 rs) 4))
          (name)
          (case (random 2 rs)
            (0 (format nil "[~{~A~^ ~}~@[ & ~A~]~@[ :as ~A~]]"
                       (loop repeat (random 4 rs) collect (random-pattern rs (1- depth)))
                       (and (zerop (random 3 rs)) (random-pattern rs (1- depth)))
                       (and (zerop (random 3 rs)) (name))))
            (t (format nil "{~{~A~^ ~}}"
                       (remove-duplicates
                        (loop repeat (1+ (random 3 rs))
                              collect (case (random 5 rs)
                                        (0 (format nil ":keys [~A ~A]" (name) (name)))
                                        (1 (format nil ":strs [~A]" (name)))
                                        (2 (format nil ":or {~A 1}" (name)))
                                        (3 (format nil ":as ~A" (name)))
                                        (t (format nil "~A :~A" (random-pattern rs (1- depth))
                                                   (name)))))
                        :test #'string=
                        :key (lambda (s) (subseq s 0 (position #\Space s)))))))))))

(test destructure-in-skein-matches-phase-0-on-random-patterns
  (let ((rs (sb-ext:seed-random-state 20261110)))
    (dotimes (i 300)
      (destructure-matches-p (format nil "[~A v ~A w]" (random-pattern rs 3)
                                     (random-pattern rs 3))))))
