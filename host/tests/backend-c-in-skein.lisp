;;;; The C backend written in Skein (lib/skein/compiler/c.skn, M1.9 step 2, D-059):
;;;; checked against the Lisp backend by translating programs with both and comparing the
;;;; C text. Both see the same top-level forms at the same moment: the Lisp backend's
;;;; translate-file calls a hook just before it emits each form, and the hook runs the
;;;; Skein expander and the Skein backend on that form.

(in-package #:skein.tests)

(def-suite skein.backend-c-in-skein :in all
  :description "The C backend written in Skein, checked against the Lisp backend.")

(in-suite skein.backend-c-in-skein)

(defun skein-c-function (name)
  "The function skein.compiler.c/NAME, loading the namespace the first time."
  (let ((ns (skein.runtime:find-namespace "skein.compiler.c")))
    (unless (and ns (skein.runtime:find-own-var ns name))
      (ev "(ns c-backend-bridge (:require [skein.compiler.c]))")
      (setf ns (skein.runtime:find-namespace "skein.compiler.c")))
    (skein.runtime:var-get (skein.runtime:find-own-var ns name) nil)))

(defun call-skein-c (name &rest args)
  (apply (skein-c-function name) args))

(defun canonical-c (text)
  "TEXT with each local's C name (l_name_id) renamed by order of first appearance: the
two expanders number locals with their own counters. The name is kept, without the
digits that follow an underscore."
  (let ((names (make-hash-table :test 'equal))
        (out (make-string-output-stream))
        (n (length text))
        (i 0))
    (flet ((ident-char-p (c) (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)
                                 (char= c #\_))))
      (loop while (< i n)
            do (if (and (char= (char text i) #\l) (< (1+ i) n) (char= (char text (1+ i)) #\_)
                        (or (zerop i) (not (ident-char-p (char text (1- i))))))
                   (let* ((end (or (position-if-not #'ident-char-p text :start i) n))
                          (id (subseq text i end)))
                     (write-string
                      (or (gethash id names)
                          (setf (gethash id names)
                                (format nil "~A#~D"
                                        (with-output-to-string (s)
                                          (loop for j from 0 below (length id)
                                                for c = (char id j)
                                                unless (and (digit-char-p c) (> j 0)
                                                            (let ((k (position-if-not
                                                                      #'digit-char-p id
                                                                      :end j :from-end t)))
                                                              (and k (char= (char id k) #\_))))
                                                  do (write-char c s)))
                                        (hash-table-count names))))
                      out)
                     (setf i end))
                   (progn (write-char (char text i) out) (incf i)))))
    (get-output-stream-string out)))

(defun canonical-gensyms (text)
  "TEXT with the numbers of gensyms (name__123) dropped: macros called by both expanders
draw on one gensym counter."
  (with-output-to-string (out)
    (let ((i 0) (n (length text)))
      (loop while (< i n)
            do (write-char (char text i) out)
               (when (and (char= (char text i) #\_) (< (1+ i) n) (char= (char text (1+ i)) #\_)
                          (< (+ i 2) n) (digit-char-p (char text (+ i 2))))
                 (write-char #\_ out)
                 (setf i (or (position-if-not #'digit-char-p text :start (+ i 2)) n))
                 (write-char #\# out)
                 (decf i))
               (incf i)))))

(defun skein-c-outcome (c)
  "A Skein backend failure as (:error message location), or (:bug text) if it is not a
c-backend-error."
  (let ((type (ignore-errors (skein.runtime::defined-type-of c))))
    (if (and type (string= (skein.runtime:condition-type-name type)
                           "skein.compiler.c/c-backend-error"))
        (list :error (skein.runtime::condition-slot c "message")
              (skein.syntax:format-location
               (from-skein-location (skein.runtime::condition-slot c "location"))))
        (list :bug (princ-to-string c)))))

(defun compare-c-backends (path)
  "Translate the program at PATH with both backends. Returns the Lisp backend's outcome
and the Skein backend's: canonical C text, (:error message location) for a
c-backend-error, or (:other text) for another failure of the Lisp side."
  (let* ((unit (call-skein-c "make-unit"))
         (skein nil)
         (skein.backend.c::*translate-hook*
           (lambda (event a b)
             (unless skein
               (handler-case
                   (ecase event
                     (:form (call-skein-c "emit-toplevel" unit
                                          (call-skein-expander "analyze-toplevel"
                                                               (to-skein-syntax a) b)
                                          b))
                     (:core-names (call-skein-c "note-core-names!" unit
                                                (skein.runtime:vector-from-list a)))
                     (:core-macro (let ((ns (skein.runtime:var-namespace b)))
                                    (call-skein-c "emit-core-macro" unit b
                                                  (call-skein-expander "analyze-toplevel"
                                                                       (to-skein-syntax a) ns)
                                                  ns)))
                     (:program (setf skein (canonical-gensyms
                                            (canonical-c
                                             (call-skein-c "program-text" unit b a))))))
                 (error (c) (setf skein (skein-c-outcome c)))))))
         (lisp (handler-case (canonical-gensyms
                       (canonical-c (skein.backend.c:translate-file path)))
                 (skein.backend.c:c-backend-error (e)
                   (list :error (skein.runtime:skein-error-message e)
                         (skein.syntax:format-location (skein.runtime:skein-error-location e))))
                 (error (e) (list :other (princ-to-string e))))))
    (values lisp skein)))

(defun backends-match-p (path)
  "Check that both backends translate PATH the same way."
  (multiple-value-bind (lisp skein) (compare-c-backends path)
    (is (equal lisp skein) "~A: the backends differ~%~A" (file-namestring path)
        (if (and (stringp lisp) (stringp skein))
            (first-difference lisp skein)
            (format nil "Lisp: ~S~%Skein: ~S"
                    (if (stringp lisp) "C text" lisp) (if (stringp skein) "C text" skein))))))

(defun native-programs ()
  "The programs the native tests build: examples with expected output, fixtures, n-body."
  (append (mapcar (lambda (name)
                    (asdf:system-relative-pathname "skein" (format nil "../examples/~A.skn" name)))
                  '("hello" "fib" "conditions" "collections" "macros" "objects" "particles"
                    "jobs"))
          (directory (asdf:system-relative-pathname "skein" "tests/fixtures/native-*.skn"))
          (list (asdf:system-relative-pathname "skein" "../bench/nbody/main.skn"))))

(test c-backend-in-skein-matches-on-native-programs
  (dolist (path (native-programs))
    (backends-match-p path)))

(test c-backend-in-skein-matches-on-every-file
  ;; Files that can't be built natively yet must fail with the same message and location.
  ;; The C backend tests (backend-c.lisp) also compare every program they build.
  (dolist (path (repository-skn-files))
    (backends-match-p path)))

(test c-backend-in-skein-has-the-same-tables
  ;; The lists of native skein.core functions and condition types are written twice
  ;; until the Lisp backend retires.
  (flet ((skein-set (name)
           (sort (skein.runtime:seq-to-cl
                  (skein.runtime:var-get
                   (skein.runtime:find-own-var
                    (skein.runtime:find-namespace "skein.compiler.c") name)
                   nil))
                 #'string<)))
    (skein-c-function "make-unit")
    (is (equal (sort (copy-list skein.backend.c::*native-core-functions*) #'string<)
               (skein-set "native-core-functions")))
    (is (equal (sort (copy-list skein.backend.c::*builtin-condition-types*) #'string<)
               (skein-set "builtin-condition-types")))
    (is (equal (sort (copy-list skein.backend.c::*builtin-class-names*) #'string<)
               (skein-set "builtin-class-names")))
    (is (equal (sort (copy-list skein.backend.c::*inline-primitives*) #'string<)
               (skein-set "inline-primitives")))))
