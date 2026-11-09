;;;; Symbols, keywords and false: atoms the reader produces (DESIGN §6.1).

(in-package #:skein.runtime)

;;; 32-bit hash mixing, shared by symbols, keywords and hash-of (hash.lisp).

(declaim (inline u32))
(defun u32 (x) (logand x #xFFFFFFFF))

(defun mix32 (h)
  "Murmur3's 32-bit finalizer: spread the bits of the 32-bit integer H."
  (declare (type (unsigned-byte 32) h))
  (setf h (u32 (* (logxor h (ash h -16)) #x85EBCA6B)))
  (setf h (u32 (* (logxor h (ash h -13)) #xC2B2AE35)))
  (logxor h (ash h -16)))

(defun fold32 (n)
  "Fold the integer N to 32 bits by XORing its 32-bit chunks."
  (let ((h 0))
    (loop for x = (abs n) then (ash x -32)
          do (setf h (logxor h (logand x #xFFFFFFFF)))
          until (< x #x100000000))
    (if (minusp n) (u32 (lognot h)) h)))

(defun string-hash32 (string)
  "A 32-bit hash of STRING's characters."
  (mix32 (fold32 (sxhash string))))

;;; Symbols and keywords are interned: reading the same name twice gives the same (EQ)
;;; object. The namespace is NIL for unqualified names.

(defstruct (sym (:constructor %make-sym (namespace name hash))
                (:copier nil))
  "A Skein symbol: an interned name with an optional namespace."
  (namespace nil :type (or null string) :read-only t)
  (name "" :type string :read-only t)
  (hash 0 :type (unsigned-byte 32) :read-only t))

(defstruct (kw (:constructor %make-kw (namespace name hash))
               (:copier nil))
  "A Skein keyword: an interned name with an optional namespace."
  (namespace nil :type (or null string) :read-only t)
  (name "" :type string :read-only t)
  (hash 0 :type (unsigned-byte 32) :read-only t))

(setf (documentation 'sym-name 'function) "Return the name of a Skein symbol."
      (documentation 'sym-namespace 'function)
      "Return the namespace of a Skein symbol, or NIL if it is unqualified."
      (documentation 'sym-p 'function) "Return true if the argument is a Skein symbol."
      (documentation 'kw-name 'function) "Return the name of a Skein keyword."
      (documentation 'kw-namespace 'function)
      "Return the namespace of a Skein keyword, or NIL if it is unqualified."
      (documentation 'kw-p 'function) "Return true if the argument is a Skein keyword.")

(sb-ext:define-load-time-global **syms** (make-hash-table :test 'equal :synchronized t))
(sb-ext:define-load-time-global **kws** (make-hash-table :test 'equal :synchronized t))

(defun intern-in (table constructor name namespace salt)
  (let ((key (cons namespace name)))
    (sb-ext:with-locked-hash-table (table)
      (or (gethash key table)
          (setf (gethash key table)
                (funcall constructor
                         (and namespace (coerce namespace 'simple-string))
                         (coerce name 'simple-string)
                         (u32 (+ salt (string-hash32 (if namespace
                                                         (format nil "~A/~A" namespace name)
                                                         name))))))))))

(defun intern-sym (name &optional namespace)
  "Return the Skein symbol NAME in NAMESPACE (a string, or NIL for an unqualified symbol)."
  (intern-in **syms** #'%make-sym name namespace 0))

(defun intern-kw (name &optional namespace)
  "Return the Skein keyword NAME in NAMESPACE (a string, or NIL for an unqualified keyword)."
  (intern-in **kws** #'%make-kw name namespace #x9E3779B9))

(defmethod print-object ((s sym) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (s stream :type t)
        (write-string (atom-to-string s) stream))))

(defmethod print-object ((k kw) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (k stream :type t)
        (write-string (atom-to-string k) stream))))

;;; false

(defstruct (false-value (:constructor %make-false-value) (:copier nil) (:predicate nil)))

(defmethod print-object ((f false-value) stream)
  (print-unreadable-object (f stream)
    (write-string "skein false" stream)))

(sb-ext:define-load-time-global +false+ (%make-false-value)
  "The Skein value false. Skein nil is CL NIL and true is CL T.")

(declaim (inline false-p))
(defun false-p (x)
  "Return true if X is the Skein value false."
  (eq x +false+))
