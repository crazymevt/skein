;;;; Core IR nodes. See docs/CORE-IR.md for the meaning of each node.

(in-package #:skein.ir)

(defvar *next-id* 0
  "Counter for unique local and block-tag ids.")

(defun next-id () (incf *next-id*))

(defstruct (local (:constructor make-local (name &key mutable-p (id (next-id)))))
  "A local binding. Each binding gets its own object; references point at it."
  (name "" :type string :read-only t)
  (id 0 :type integer :read-only t)
  (mutable-p nil :read-only t))

(defmethod print-object ((l local) stream)
  (print-unreadable-object (l stream :type t)
    (format stream "~A#~D" (local-name l) (local-id l))))

(defstruct (block-tag (:constructor make-block-tag (name &key (id (next-id)))))
  "The target of return-from*, bound by block*."
  (name "" :type string :read-only t)
  (id 0 :type integer :read-only t))

(defstruct (node (:constructor nil) (:copier nil))
  "The base of every Core IR node. LOCATION is a skein.syntax:source-location or NIL."
  (location nil :read-only t))

(setf (documentation 'node-location 'function) "Return the source location of a node."
      (documentation 'node-p 'function) "Return true if the argument is a Core IR node."
      (documentation 'local-name 'function) "Return the source name of a local."
      (documentation 'local-id 'function) "Return the unique id of a local."
      (documentation 'local-mutable-p 'function)
      "Return true if a local was declared ^:mutable."
      (documentation 'local-p 'function) "Return true if the argument is a local."
      (documentation 'block-tag-name 'function) "Return the source name of a block tag."
      (documentation 'block-tag-id 'function) "Return the unique id of a block tag."
      (documentation 'block-tag-p 'function) "Return true if the argument is a block tag."
      (documentation 'make-local 'function)
      "Make a fresh local named NAME. MUTABLE-P marks a ^:mutable binding."
      (documentation 'make-block-tag 'function) "Make a fresh block tag named NAME.")

(defmacro define-node (name &rest slots)
  "Define a Core IR node struct NAME with SLOTS, documenting its generated functions."
  (flet ((sym (&rest parts)
           (intern (format nil "~{~A~}" parts) (symbol-package name))))
    `(progn
       (defstruct (,name (:include node) (:copier nil))
         ,(format nil "Core IR ~(~A~); see docs/CORE-IR.md." name)
         ,@slots)
       (setf (documentation ',(sym "MAKE-" name) 'function)
             ,(format nil "Make a ~(~A~)." name)
             (documentation ',(sym name "-P") 'function)
             ,(format nil "Return true if the argument is a ~(~A~)." name)
             ,@(loop for (slot) in slots
                     append `((documentation ',(sym name "-" slot) 'function)
                              ,(format nil "Return the ~(~A~) of a ~(~A~)." slot name)))))))

(define-node const-node (value nil :read-only t))
(define-node local-ref-node (local nil :read-only t))
(define-node var-ref-node (var nil :read-only t))
(define-node if-node (test nil :read-only t) (then nil :read-only t) (else nil :read-only t))
(define-node do-node (forms '() :read-only t))
(define-node def-node (var nil :read-only t) (init nil :read-only t))
(define-node fn-node (name nil :read-only t) (self nil :read-only t)
  (arities '() :read-only t))
(define-node arity (params '() :read-only t) (rest nil :read-only t) (body nil)
  (recur-p nil))
(define-node let-node (bindings '() :read-only t) (body nil :read-only t))
(define-node letfn-node (bindings '() :read-only t) (body nil :read-only t))
(define-node loop-node (bindings '() :read-only t) (body nil) (recur-p nil))
(define-node recur-node (target nil :read-only t) (args '() :read-only t))
(define-node set-node (local nil :read-only t) (value nil :read-only t))
(define-node call-node (fn nil :read-only t) (args '() :read-only t))
(define-node unwind-protect-node (body nil :read-only t) (cleanup nil :read-only t))
(define-node block-node (tag nil :read-only t) (body nil :read-only t))
(define-node return-from-node (tag nil :read-only t) (value nil :read-only t))
(define-node values-node (args '() :read-only t))
(define-node let-values-node (bindings '() :read-only t) (body nil :read-only t))
(define-node the-node (type nil :read-only t) (expr nil :read-only t))
