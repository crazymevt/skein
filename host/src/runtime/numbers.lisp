;;;; Number support for the reader.

(in-package #:skein.runtime)

(define-condition float-out-of-range (error)
  ((type :initarg :type :reader float-out-of-range-type))
  (:report (lambda (c stream)
             (format stream "float literal is too large for ~(~A~)"
                     (float-out-of-range-type c))))
  (:documentation "Signaled by DECIMAL-TO-FLOAT when a value is too large for its float type."))

(sb-ext:define-load-time-global +f64-infinity+ sb-ext:double-float-positive-infinity
  "Positive f64 infinity, read as ##Inf.")
(sb-ext:define-load-time-global +f64-negative-infinity+ sb-ext:double-float-negative-infinity
  "Negative f64 infinity, read as ##-Inf.")
(sb-ext:define-load-time-global +f64-nan+
    ;; The quiet NaN 0x7FF8000000000000, built from its bits.
    (sb-kernel:make-double-float #x7FF80000 0)
  "An f64 NaN, read as ##NaN.")

(defmacro without-nan-traps (&body body)
  "Run BODY with the floating-point invalid-operation trap masked, so that comparing a
NaN gives false instead of signaling (x86-64 traps on NaN comparisons; arm64 does not)."
  `(sb-int:with-float-traps-masked (:invalid) ,@body))

;;; Skein follows IEEE for floats: an invalid operation (such as comparing a NaN, or
;;; 0.0/0.0) gives NaN or false instead of trapping. Inlined comparisons rely on this.
;;; The modes belong to each thread, and SBCL on Windows does not keep them across
;;; loading, so the compiler driver calls this before running each top-level form.

(defun ensure-float-modes ()
  "Mask the floating-point invalid-operation trap in the current thread."
  (let ((traps (getf (sb-int:get-floating-point-modes) :traps)))
    (when (member :invalid traps)
      (sb-int:set-floating-point-modes :traps (remove :invalid traps)))))

(ensure-float-modes)

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
