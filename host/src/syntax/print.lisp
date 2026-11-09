;;;; Printing syntax objects as Skein source text.

(in-package #:skein.syntax)

(defvar *print-meta* nil
  "True while PRINT-SYNTAX is writing metadata prefixes.")

(defun print-items (items stream)
  (loop for (item . more) on items
        do (%print-syntax item stream)
           (when more (write-char #\Space stream))))

(defun print-map-items (items stream)
  (loop for (key value . more) on items by #'cddr
        do (%print-syntax key stream)
           (write-char #\Space stream)
           (%print-syntax value stream)
           (when more (write-string ", " stream))))

(defun print-syntax (syntax stream &key (print-meta *print-meta*))
  "Write SYNTAX to STREAM as Skein source text that the reader reads back to an equal
form. Metadata is written as a ^{...} prefix only when PRINT-META is true."
  (let ((*print-meta* print-meta))
    (%print-syntax syntax stream))
  syntax)

(defun %print-syntax (syntax stream)
  (when (and *print-meta* (syntax-meta syntax))
    (write-char #\^ stream)
    (%print-syntax (syntax-meta syntax) stream)
    (write-char #\Space stream))
  (flet ((compound (open close printer)
           (write-string open stream)
           (funcall printer (syntax-datum syntax) stream)
           (write-string close stream)))
    (ecase (syntax-kind syntax)
      (:atom (skein.runtime:print-atom (syntax-datum syntax) stream))
      (:list (compound "(" ")" #'print-items))
      (:vector (compound "[" "]" #'print-items))
      (:map (compound "{" "}" #'print-map-items))
      (:set (compound "#{" "}" #'print-items)))))

(defun syntax-to-string (syntax &key print-meta)
  "Return SYNTAX printed as Skein source text. See PRINT-SYNTAX."
  (with-output-to-string (s)
    (print-syntax syntax s :print-meta print-meta)))
