;;;; Skein errors that carry a source location.

(in-package #:skein.runtime)

(define-condition skein-error (error)
  ((message :initarg :message :reader skein-error-message)
   (location :initarg :location :initform nil :reader skein-error-location))
  (:report (lambda (c stream)
             (format stream "~A~@[ at ~A~]" (skein-error-message c)
                     (and (skein-error-location c)
                          (skein.syntax:format-location (skein-error-location c))))))
  (:documentation "The base of Skein's own errors. SKEIN-ERROR-LOCATION is the source
location of the problem, or NIL; the report appends it as \"at file:line:col\"."))

(setf (documentation 'skein-error-message 'function)
      "Return the description of a SKEIN-ERROR, without its location."
      (documentation 'skein-error-location 'function)
      "Return the source location of a SKEIN-ERROR, or NIL.")

(define-condition unbound-var-error (skein-error) ()
  (:documentation "Signaled when code reads a var that has no value."))

(define-condition not-callable-error (skein-error) ()
  (:documentation "Signaled when code calls a value that is not a function or keyword."))

(define-condition arity-error (skein-error) ()
  (:documentation "Signaled when a function is called with the wrong number of arguments."))

(define-condition namespace-error (skein-error) ()
  (:documentation "Signaled when a namespace or a var in it cannot be found or loaded."))

(defun skein-error (type location control &rest args)
  "Signal a Skein error of TYPE at LOCATION with a message from CONTROL and ARGS."
  (error type :location location :message (apply #'format nil control args)))
