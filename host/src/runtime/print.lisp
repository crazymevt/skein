;;;; Printing atoms in Skein syntax, so that the reader reads them back.

(in-package #:skein.runtime)

(define-condition unprintable-value (error)
  ((value :initarg :value :reader unprintable-value-value))
  (:report (lambda (c stream)
             (format stream "cannot print ~S as Skein data yet"
                     (unprintable-value-value c))))
  (:documentation "Signaled when a value has no readable Skein printed form yet."))

(defparameter *char-names*
  '((#\Newline . "newline") (#\Space . "space") (#\Tab . "tab")
    (#\Backspace . "backspace") (#\Page . "formfeed") (#\Return . "return"))
  "Named character literals, shared with the reader.")

(defun float-to-string (x)
  (when (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x))
    (error 'unprintable-value :value x))
  ;; With *READ-DEFAULT-FLOAT-FORMAT* matching the float's type, SBCL prints the
  ;; shortest digits that read back to the same float, with no exponent marker
  ;; other than "e".
  (etypecase x
    (double-float (let ((*read-default-float-format* 'double-float))
                    (prin1-to-string x)))
    (single-float (let ((*read-default-float-format* 'single-float))
                    (concatenate 'string (prin1-to-string x) "f")))))

(defun write-hex4 (code stream)
  (format stream "\\u~4,'0X" code))

(defun control-char-p (ch)
  (let ((code (char-code ch)))
    (or (< code 32) (= code 127))))

(defun print-string-literal (string stream)
  (write-char #\" stream)
  (loop for ch across string
        do (case ch
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Tab (write-string "\\t" stream))
             (#\Return (write-string "\\r" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (t (if (control-char-p ch)
                    (write-hex4 (char-code ch) stream)
                    (write-char ch stream)))))
  (write-char #\" stream))

(defun print-char-literal (ch stream)
  (write-char #\\ stream)
  (let ((name (cdr (assoc ch *char-names*))))
    (cond (name (write-string name stream))
          ((control-char-p ch) (format stream "u~4,'0X" (char-code ch)))
          (t (write-char ch stream)))))

(defun print-qualified (namespace name stream)
  (when namespace
    (write-string namespace stream)
    (write-char #\/ stream))
  (write-string name stream))

(defun print-atom (x stream)
  "Write the Skein printed form of the atom X to STREAM: nil, true, false, an integer,
f64, f32, char, string, symbol or keyword. Signals UNPRINTABLE-VALUE for other values."
  (cond ((null x) (write-string "nil" stream))
        ((eq x t) (write-string "true" stream))
        ((false-p x) (write-string "false" stream))
        ((integerp x) (format stream "~D" x))
        ((floatp x) (write-string (float-to-string x) stream))
        ((characterp x) (print-char-literal x stream))
        ((stringp x) (print-string-literal x stream))
        ((sym-p x) (print-qualified (sym-namespace x) (sym-name x) stream))
        ((kw-p x)
         (write-char #\: stream)
         (print-qualified (kw-namespace x) (kw-name x) stream))
        (t (error 'unprintable-value :value x)))
  x)

(defun atom-to-string (x)
  "Return the Skein printed form of the atom X as a string. See PRINT-ATOM."
  (with-output-to-string (s)
    (print-atom x s)))
