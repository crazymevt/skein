;;;; A small JSON reader for clang's AST dump. Objects become alists (in document order),
;;;; arrays become lists. While reading, every "loc" object records the source file in
;;;; effect after it as a "_file" entry of its parent, because clang omits "file" when it
;;;; is the same as in the previous location.

(in-package #:skein.bindgen)

(define-condition bindgen-error (skein.runtime:skein-error) ()
  (:documentation "Signaled when bindgen cannot read its input or run clang."))

(defun bindgen-error (control &rest args)
  "Signal a BINDGEN-ERROR with a message built from CONTROL and ARGS."
  (error 'bindgen-error :location nil :message (apply #'format nil control args)))

(defvar *json* "")
(defvar *pos* 0)
(defvar *last-file* nil)

(declaim (inline peek-char*))
(defun peek-char* () (if (< *pos* (length *json*)) (char *json* *pos*) nil))

(defun skip-ws ()
  (loop while (and (< *pos* (length *json*))
                   (member (char *json* *pos*) '(#\Space #\Tab #\Newline #\Return)))
        do (incf *pos*)))

(defun expect (c)
  (skip-ws)
  (unless (eql (peek-char*) c)
    (bindgen-error "malformed JSON at offset ~D: expected ~A" *pos* c))
  (incf *pos*))

(defun parse-string ()
  (expect #\")
  (with-output-to-string (out)
    (loop
      (let ((c (char *json* *pos*)))
        (incf *pos*)
        (case c
          (#\" (return))
          (#\\ (let ((e (char *json* *pos*)))
                 (incf *pos*)
                 (case e
                   (#\n (write-char #\Newline out))
                   (#\t (write-char #\Tab out))
                   (#\r (write-char #\Return out))
                   (#\b (write-char #\Backspace out))
                   (#\f (write-char #\Page out))
                   (#\u (write-char (code-char (parse-integer *json* :start *pos*
                                                                     :end (+ *pos* 4)
                                                                     :radix 16))
                                    out)
                    (incf *pos* 4))
                   (t (write-char e out)))))
          (t (write-char c out)))))))

(defun parse-value ()
  (skip-ws)
  (let ((c (peek-char*)))
    (case c
      (#\{ (parse-object))
      (#\[ (parse-array))
      (#\" (parse-string))
      (t (cond ((string= "true" *json* :start2 *pos* :end2 (min (length *json*) (+ *pos* 4)))
                (incf *pos* 4) t)
               ((string= "false" *json* :start2 *pos* :end2 (min (length *json*) (+ *pos* 5)))
                (incf *pos* 5) :false)
               ((string= "null" *json* :start2 *pos* :end2 (min (length *json*) (+ *pos* 4)))
                (incf *pos* 4) :null)
               (t (let ((end (or (position-if-not (lambda (ch) (find ch "+-0123456789.eE"))
                                                  *json* :start *pos*)
                                 (length *json*))))
                    (prog1 (let ((text (subseq *json* *pos* end)))
                             (if (find-if (lambda (ch) (find ch ".eE")) text)
                                 text
                                 (parse-integer text)))
                      (setf *pos* end)))))))))

(defun parse-object ()
  (expect #\{)
  (let ((entries '()))
    (skip-ws)
    (if (eql (peek-char*) #\})
        (incf *pos*)
        (loop
          (let* ((key (parse-string))
                 (saved-file *last-file*)
                 (value (progn (expect #\:) (parse-value))))
            ;; "includedFrom" names the including file, not the location's own file.
            (when (string= key "includedFrom")
              (setf *last-file* saved-file))
            (when (and (string= key "file") (stringp value))
              (setf *last-file* value))
            (push (cons key value) entries)
            (when (string= key "loc")
              (push (cons "_file" *last-file*) entries)))
          (skip-ws)
          (case (peek-char*)
            (#\, (incf *pos*))
            (#\} (incf *pos*) (return))
            (t (bindgen-error "malformed JSON object at offset ~D" *pos*)))))
    (nreverse entries)))

(defun parse-array ()
  (expect #\[)
  (let ((items '()))
    (skip-ws)
    (if (eql (peek-char*) #\])
        (incf *pos*)
        (loop
          (push (parse-value) items)
          (skip-ws)
          (case (peek-char*)
            (#\, (incf *pos*))
            (#\] (incf *pos*) (return))
            (t (bindgen-error "malformed JSON array at offset ~D" *pos*)))))
    (nreverse items)))

(defun parse-json (string)
  "Parse every top-level JSON object in STRING (text between objects is skipped) and
return them as a list."
  (let ((*json* string) (*pos* 0) (*last-file* nil) (objects '()))
    (loop
      (let ((start (position #\{ *json* :start *pos*)))
        (unless start (return (nreverse objects)))
        (setf *pos* start)
        (push (parse-object) objects)))))

(defun jget (object &rest keys)
  "Follow KEYS through nested JSON objects."
  (dolist (k keys object)
    (setf object (and (listp object) (cdr (assoc k object :test #'equal))))))
