;;;; Converting between syntax objects and the plain data that macros see (D-033).
;;;; Macros written in Skein receive and return ordinary lists, vectors and symbols, as in
;;;; Clojure. To keep source locations and metadata, each conversion gives symbols and
;;;; collections fresh identities and records where each came from in *ORIGINS*; when a
;;;; macro passes such an object through, the original syntax object is reused.

(in-package #:skein.expander)

(defvar *origins* nil
  "During one macro call, an EQ hash table from data objects to the syntax they came
from; NIL otherwise.")

(defun singleton-p (x)
  (or (eq x skein.runtime:+empty-list+) (eq x skein.runtime:+empty-vector+)
      (eq x skein.runtime:+empty-map+) (eq x skein.runtime:+empty-set+)))

(defun syntax-to-data (syntax)
  "Return the plain Skein data for SYNTAX, recording origins in *ORIGINS* if it is bound."
  (let* ((children (and (not (eq (syntax-kind syntax) :atom))
                        (mapcar #'syntax-to-data (items syntax))))
         (value (ecase (syntax-kind syntax)
                  (:atom (let ((d (syntax-datum syntax)))
                           (if (sym-p d) (skein.runtime:copy-sym d) d)))
                  (:list (skein.runtime:list-from-cl children))
                  (:vector (skein.runtime:vector-from-list children))
                  (:map (skein.runtime:map-from-pairs children))
                  (:set (skein.runtime:set-from-cl children)))))
    (when (and *origins*
               (or (sym-p value) (stringp value)
                   (and (not (eq (syntax-kind syntax) :atom)) (not (singleton-p value))))
               (not (gethash value *origins*)))
      (setf (gethash value *origins*) syntax))
    value))

(defun data-to-syntax (x location)
  "Return a syntax object for the data X. Objects recorded in *ORIGINS* become their
original syntax; anything new gets LOCATION."
  (or (and *origins* (gethash x *origins*))
      (flet ((children (xs) (mapcar (lambda (y) (data-to-syntax y location)) xs)))
        (cond ((skein.runtime:pvector-p x)
               (make-syntax :kind :vector :datum (children (skein.runtime:vector-to-list x))
                            :location location))
              ((skein.runtime:map-p x)
               (make-syntax :kind :map
                            :datum (children (loop for e in (skein.runtime:seq-to-cl x)
                                                   append (list (skein.runtime:vector-nth e 0)
                                                                (skein.runtime:vector-nth e 1))))
                            :location location))
              ((skein.runtime:hash-set-p x)
               (make-syntax :kind :set :datum (children (skein.runtime:seq-to-cl x))
                            :location location))
              ((skein.runtime:sequential-p x)
               (make-syntax :kind :list :datum (children (skein.runtime:seq-to-cl x))
                            :location location))
              (t (make-syntax :kind :atom :datum x :location location))))))

(defun env-to-data (env)
  "Return &env for a macro: a map from each local's name (a symbol) to true."
  (skein.runtime:map-from-pairs
   (loop for (name) in (env-locals env) append (list (intern-sym name) t))))

(defun expand-data-macro (var form env)
  "Call the Skein macro in VAR on FORM, converting to and from data."
  (let* ((*origins* (make-hash-table :test 'eq))
         (skein.runtime::*syntax-meta-lookup* nil)
         (data (syntax-to-data form))
         (args (skein.runtime:seq-to-cl (skein.runtime:seq-rest (skein.runtime:seq data))))
         (name (var-qualified-name var))
         (result
           (handler-case
               (let ((skein.runtime:*expansion-context* (cons var (loc form))))
                 (apply (var-value var) data (env-to-data env) args))
             (compile-error (e) (error e))
             (skein.runtime:arity-error (e)
               ;; The macro's own function: report the user's argument count, without
               ;; the implicit &form and &env.
               (if (equal (skein.runtime:arity-error-function-name e)
                          (skein.runtime::function-display-name (var-value var)))
                   (compile-error form "wrong number of arguments (~D) passed to macro ~A"
                                  (- (skein.runtime:arity-error-argument-count e) 2) name)
                   (compile-error form "~A (in macro ~A)"
                                  (skein.runtime:skein-error-message e) name)))
             (skein.runtime:skein-error (e)
               (if (skein.runtime:skein-error-location e)
                   (error e)
                   (compile-error form "~A (in macro ~A)"
                                  (skein.runtime:skein-error-message e) name)))
             (error (e)
               (let ((*print-pretty* nil))
                 (compile-error form "error while expanding macro ~A: ~A" name e))))))
    (data-to-syntax result (loc form))))

;;; macroexpand-1, macroexpand and macroexpand-all for Skein code (DESIGN §11.1)

(defun data-macroexpand (form expand)
  (let* ((*origins* nil)
         (syntax (data-to-syntax form nil))
         (env (make-env :namespace *current-namespace*)))
    (syntax-to-data (funcall expand syntax env))))

(defun expand-all (syntax env)
  (let ((expanded (macroexpand syntax env)))
    (cond ((eq (syntax-kind expanded) :atom) expanded)
          ((equal (head-name expanded) "quote") expanded)
          (t (make-syntax :kind (syntax-kind expanded)
                          :datum (mapcar (lambda (x) (expand-all x env)) (items expanded))
                          :location (loc expanded))))))

(skein.runtime:defcore "macroexpand-1" (form)
  (data-macroexpand form (lambda (s env) (values (macroexpand-1 s env)))))
(skein.runtime:defcore "macroexpand" (form)
  (data-macroexpand form (lambda (s env) (values (macroexpand s env)))))
(skein.runtime:defcore "macroexpand-all" (form)
  (data-macroexpand form #'expand-all))

(skein.runtime:defcore "%syntax-meta" (form)
  ;; For macros: the metadata (^:blocking, ^type, ...) of a form they received, or nil.
  ;; The expander written in Skein provides its own lookup (M1.7).
  (if skein.runtime::*syntax-meta-lookup*
      ;; The lookup is the compiler's code, not the macro's, so phase rules don't apply.
      (let ((skein.runtime:*expansion-context* nil))
        (skein.runtime::scall skein.runtime::*syntax-meta-lookup* form))
      (let ((syntax (and *origins* (gethash form *origins*))))
        (and syntax (syntax-meta syntax) (syntax-value (syntax-meta syntax))))))
