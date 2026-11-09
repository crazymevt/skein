;;;; Printing any value, for print/println (display) and pr/prn (readable).

(in-package #:skein.runtime)

(defun function-display-name (f)
  (let ((name (sb-kernel:%fun-name f)))
    (if (stringp name) name "fn")))

(defun print-value (x stream &key readably)
  "Write X to STREAM. When READABLY is false, strings and chars are written raw, as
print does; otherwise as pr does. Values with no readable syntax print as #<...>."
  (cond ((and (not readably) (stringp x)) (write-string x stream))
        ((and (not readably) (characterp x)) (write-char x stream))
        ((and (floatp x) (sb-ext:float-infinity-p x))
         (write-string (if (plusp x) "##Inf" "##-Inf") stream))
        ((and (floatp x) (sb-ext:float-nan-p x)) (write-string "##NaN" stream))
        ((or (null x) (eq x t) (false-p x) (numberp x) (characterp x) (stringp x)
             (sym-p x) (kw-p x))
         (print-atom x stream))
        ((functionp x) (format stream "#<fn ~A>" (function-display-name x)))
        ((var-p x) (format stream "#'~A" (var-qualified-name x)))
        ((namespace-p x) (format stream "#<namespace ~A>" (namespace-name x)))
        ;; Rest arguments are CL lists until persistent lists arrive in M0.4.
        ((consp x)
         (write-char #\( stream)
         (loop for (item . more) on x
               do (print-value item stream :readably readably)
                  (when more (write-char #\Space stream)))
         (write-char #\) stream))
        (t (format stream "#<~(~A~)>" (type-of x))))
  x)

(defun display-string (x)
  "Return X as print would write it."
  (with-output-to-string (s) (print-value x s)))

(defun readable-string (x)
  "Return X as pr would write it."
  (with-output-to-string (s) (print-value x s :readably t)))
