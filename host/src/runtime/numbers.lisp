;;;; Number support for the reader.

(in-package #:skein.runtime)

(define-condition float-out-of-range (error)
  ((type :initarg :type :reader float-out-of-range-type))
  (:report (lambda (c stream)
             (format stream "float literal is too large for ~(~A~)"
                     (float-out-of-range-type c))))
  (:documentation "Signaled by DECIMAL-TO-FLOAT when a value is too large for its float type."))

(defun decimal-to-float (negative mantissa exponent type)
  "Return the float nearest to MANTISSA * 10^EXPONENT, negated if NEGATIVE.
MANTISSA is a non-negative integer and TYPE is :F64 or :F32. The result is correctly
rounded. Values too small for TYPE become zero; values too large signal
FLOAT-OUT-OF-RANGE."
  (check-type mantissa (integer 0))
  (let* ((cl-type (ecase type (:f64 'double-float) (:f32 'single-float)))
         (zero (coerce 0 cl-type))
         ;; Decimal exponent of the leading digit, to reject absurd exponents cheaply
         ;; before building huge rationals.
         (magnitude (+ exponent (length (princ-to-string mantissa)) -1))
         (max-magnitude (ecase type (:f64 309) (:f32 39)))
         (min-magnitude (ecase type (:f64 -330) (:f32 -50)))
         (value
           (cond ((zerop mantissa) zero)
                 ((> magnitude max-magnitude)
                  (error 'float-out-of-range :type type))
                 ((< magnitude min-magnitude) zero)
                 (t (handler-case (coerce (* mantissa (expt 10 exponent)) cl-type)
                      (floating-point-overflow ()
                        (error 'float-out-of-range :type type)))))))
    (if negative (- value) value)))
