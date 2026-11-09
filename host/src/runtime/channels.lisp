;;;; Channels (DESIGN §13.2). In Phase 0 a blocked channel operation blocks its thread.
;;;; All channels share one lock and one wake-up queue; that keeps alts! simple, and
;;;; contention does not matter yet. Every wait is a cancellation point.

(in-package #:skein.runtime)

(sb-ext:define-load-time-global **chan-lock** (sb-thread:make-mutex :name "channels"))
(sb-ext:define-load-time-global **chan-wake** (sb-thread:make-waitqueue))

(setf (documentation 'chan-p 'function) "Return true if the argument is a channel.")

(defun make-chan (&optional (capacity 0))
  (unless (typep capacity '(integer 0))
    (skein-error 'skein-error nil "chan needs a non-negative buffer size, not ~A"
                 (readable-string capacity)))
  (%make-chan capacity))

(defun check-chan (x what)
  (unless (chan-p x) (unsupported "~A needs a channel, not ~A" what (readable-string x))))

(defun chan-wake () (sb-thread:condition-broadcast **chan-wake**))

(defun chan-wait (ready on-ready &key deadline)
  (wait-for **chan-lock** **chan-wake** ready on-ready :deadline deadline))

;;; These run with **CHAN-LOCK** held.

(defun take-ready-p (ch) (or (chan-items ch) (chan-closed ch)))

(defun take-now (ch)
  "Take a value (NIL if the channel is closed and empty)."
  (if (chan-items ch)
      (prog1 (pop (chan-items ch))
        (incf (chan-takes ch))
        (chan-wake))
      nil))

(defun put-ready-p (ch)
  (or (chan-closed ch)
      (if (zerop (chan-capacity ch))
          (> (chan-takers-waiting ch) (length (chan-items ch)))
          (< (length (chan-items ch)) (chan-capacity ch)))))

(defun put-now (ch value)
  "Put VALUE; return its ticket, or NIL if the channel is closed."
  (unless (chan-closed ch)
    (setf (chan-items ch) (nconc (chan-items ch) (list value)))
    (chan-wake)
    (incf (chan-puts ch))))

;;; Operations

(defun chan-put (ch value)
  "Put VALUE on CH, waiting for buffer space (or, unbuffered, for a taker). Returns true,
or false if CH is closed."
  (check-chan ch ">!")
  (when (null value) (skein-error 'skein-error nil "cannot put nil on a channel"))
  (let ((ticket (chan-wait (lambda () (or (chan-closed ch)
                                          (zerop (chan-capacity ch))
                                          (< (length (chan-items ch)) (chan-capacity ch))))
                           (lambda () (put-now ch value)))))
    (cond ((null ticket) +false+)
          ((plusp (chan-capacity ch)) t)
          ;; Unbuffered: wait until the value has been taken.
          (t (bool (chan-wait (lambda () (or (>= (chan-takes ch) ticket) (chan-closed ch)))
                              (lambda () (>= (chan-takes ch) ticket))))))))

(defun chan-take (ch)
  "Take a value from CH, waiting for one. Returns nil once CH is closed and empty."
  (check-chan ch "<!")
  (sb-thread:with-mutex (**chan-lock**)
    (incf (chan-takers-waiting ch))
    (chan-wake))
  (unwind-protect
       (chan-wait (lambda () (take-ready-p ch)) (lambda () (take-now ch)))
    (sb-thread:with-mutex (**chan-lock**)
      (decf (chan-takers-waiting ch)))))

(defun chan-close (ch)
  "Close CH: puts fail from now on, and takes return nil once it is empty."
  (check-chan ch "close!")
  (sb-thread:with-mutex (**chan-lock**)
    (setf (chan-closed ch) t)
    (chan-wake))
  nil)

(defun chan-alts (ops)
  "Perform the first ready operation among OPS: a channel to take from, or [channel value]
to put. Returns [value channel] (for a put, the value is true, or false if closed)."
  (let ((ops (mapcar (lambda (op)
                       (cond ((chan-p op) (list :take op))
                             ((and (pvector-p op) (= (pvector-count op) 2)
                                   (chan-p (vector-nth op 0)))
                              (list :put (vector-nth op 0) (vector-nth op 1)))
                             (t (unsupported "alts! needs channels or [channel value] puts, ~
                                              not ~A" (readable-string op)))))
                     (seq-to-cl ops))))
    (when (null ops) (unsupported "alts! needs at least one operation"))
    (flet ((ready-op ()
             ;; Try the operations in a random order, so that no channel is favored.
             (find-if (lambda (op) (if (eq (first op) :take)
                                       (take-ready-p (second op))
                                       (put-ready-p (second op))))
                      (shuffle-list ops))))
      (chan-wait (lambda () (ready-op))
                 (lambda ()
                   (let ((op (ready-op)))
                     (vector-from-list
                      (if (eq (first op) :take)
                          (list (take-now (second op)) (second op))
                          (list (bool (put-now (second op) (third op))) (second op))))))))))

(defun shuffle-list (list)
  (let ((v (coerce list 'vector)))
    (loop for i from (1- (length v)) downto 1
          do (rotatef (aref v i) (aref v (random (1+ i)))))
    (coerce v 'list)))

(defun timeout-chan (seconds)
  "A channel that closes after SECONDS."
  (let ((ch (make-chan)))
    (start-future (lambda () (skein-sleep seconds) (chan-close ch)))
    ch))

(defcore "chan" (&optional (capacity 0)) (make-chan capacity))
(defcore "chan?" (x) (bool (chan-p x)))
(defcore ">!" (ch value) (chan-put ch value))
(defcore "<!" (ch) (chan-take ch))
(defcore "close!" (ch) (chan-close ch))
(defcore "alts!" (ops) (chan-alts ops))
(defcore "timeout-chan" (seconds) (timeout-chan seconds))
