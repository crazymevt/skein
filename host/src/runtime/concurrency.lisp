;;;; Concurrency on OS threads (DESIGN §13, D-037). A Phase 0 "fiber" is a task run by a
;;;; cached pool of worker threads: a new thread starts whenever no worker is idle, so a
;;;; task that blocks never stops another task from running. Cancellation is cooperative:
;;;; every blocking operation is a cancellation point, and so is check-cancelled.

(in-package #:skein.runtime)

;;; ------------------------------------------------------------------------------------
;;; Conditions

(define-condition cancelled (condition)
  ((message :initarg :message :initform "the task was cancelled" :reader cancelled-message))
  (:report (lambda (c stream) (write-string (cancelled-message c) stream)))
  (:documentation "Signaled at a cancellation point when the running code has been
cancelled. It is not an error, so handlers for error do not catch it; it unwinds to the
task or nursery that was cancelled."))

(define-condition task-timeout (skein-error) ()
  (:documentation "Signaled at a cancellation point when a with-timeout deadline passes."))

(define-condition task-cancelled-error (skein-error) ()
  (:documentation "Signaled by deref of a task that was cancelled."))

;;; ------------------------------------------------------------------------------------
;;; Cancellation scopes. *CANCEL-SCOPES* lists what the running code belongs to: its task,
;;; enclosing nurseries and with-timeout deadlines. Any of them being cancelled or expired
;;; makes the next cancellation point signal.

(defstruct (deadline (:constructor make-deadline (time seconds)) (:copier nil))
  (time 0 :read-only t)
  (seconds 0 :read-only t))

(defvar *cancel-scopes* '()
  "The cancellation scopes of the running code, innermost first.")

(defvar *current-task* nil
  "The task the current thread is running, or NIL.")

(defun now () (get-internal-real-time))

(defun seconds-from-now (seconds)
  (+ (now) (round (* seconds internal-time-units-per-second))))

(defun scope-cancelled-p (scope)
  (etypecase scope
    (deadline nil)
    (task (task-cancel-requested scope))
    (nursery (nursery-cancelled scope))))

(defun check-cancellation ()
  "A cancellation point: signal CANCELLED if any enclosing scope was cancelled, or
TASK-TIMEOUT if a with-timeout deadline has passed."
  (dolist (scope *cancel-scopes*)
    (cond ((deadline-p scope)
           (when (>= (now) (deadline-time scope))
             (error 'task-timeout :location nil
                                  :message (format nil "timed out after ~A seconds"
                                                   (display-string (deadline-seconds scope))))))
          ((scope-cancelled-p scope) (error 'cancelled)))))

;;; ------------------------------------------------------------------------------------
;;; The main thread. on-main-thread queues work here; the main thread runs it whenever it
;;; waits, or when the program calls drain-main-thread!.

(sb-ext:define-load-time-global **main-queue-lock** (sb-thread:make-mutex :name "main queue"))
(sb-ext:define-load-time-global **main-queue** '())

(defun main-thread-p () (eq sb-thread:*current-thread* (sb-thread:main-thread)))

(defun drain-main-thread ()
  "Run the work queued for the main thread. Does nothing on other threads."
  (when (main-thread-p)
    (loop (let ((task (sb-thread:with-mutex (**main-queue-lock**) (pop **main-queue**))))
            (unless task (return))
            (run-task task)))))

;;; ------------------------------------------------------------------------------------
;;; Waiting

(defun timed-wait (queue mutex seconds)
  "Wait on QUEUE for at most SECONDS, with MUTEX held before and after. SBCL's
CONDITION-WAIT may time out without re-acquiring the mutex, so take it back then."
  (or (sb-thread:condition-wait queue mutex :timeout seconds)
      (progn (unless (sb-thread:holding-mutex-p mutex)
               (sb-thread:grab-mutex mutex))
             nil)))

;;; Every blocking operation waits through WAIT-FOR, which wakes at least every
;;; 20 ms to run main-thread work and check for cancellation.

(defun wait-for (mutex queue ready on-ready &key deadline)
  "Wait until (READY) is true while holding MUTEX, then return (ON-READY), still holding
it. Returns :TIMEOUT instead if DEADLINE (internal time) passes first."
  (loop
    (sb-thread:with-mutex (mutex)
      (when (funcall ready) (return (funcall on-ready)))
      (when (and deadline (>= (now) deadline)) (return :timeout))
      (timed-wait queue mutex 0.02))
    (drain-main-thread)
    (check-cancellation)))

;;; ------------------------------------------------------------------------------------
;;; Tasks

(setf (documentation 'task-p 'function) "Return true if the argument is a task.")

(defparameter *inherited-specials*
  '(*current-namespace* *source-paths* *namespace-loader* *standard-output* *error-output*)
  "Special variables whose values a task takes from the code that spawned it.")

(defun capture-context ()
  ;; A task gets a copy of the dynamic bindings, so its set! changes only its own (D-076).
  (list* (cons '*dynamic-bindings* (copy-dynamic-bindings))
         (mapcar (lambda (s) (cons s (symbol-value s))) *inherited-specials*)))

(defun make-task (fn &key nursery (scopes '()))
  (%make-task fn scopes nursery (capture-context)))

(defun task-finished-p (task) (member (task-state task) '(:done :failed :cancelled)))

(defun finish-task (task state value)
  ;; A failure is recorded in the nursery before the task is marked finished: a nursery
  ;; joining its tasks must not see them all finished before it sees the failure.
  (let ((first-failure (and (eq state :failed) (task-nursery task)
                            (record-nursery-failure (task-nursery task) value))))
    (sb-thread:with-mutex ((task-lock task))
      (setf (task-state task) state)
      (case state
        (:done (setf (task-result task) value))
        (:failed (setf (task-condition task) value)))
      (sb-thread:condition-broadcast (task-done task)))
    ;; The first failure cancels the other tasks.
    (when first-failure (cancel-nursery (task-nursery task)))))

(defun run-task (task)
  "Run TASK in the current thread, recording its result, error or cancellation."
  (sb-thread:with-mutex ((task-lock task))
    (unless (eq (task-state task) :pending) (return-from run-task))
    (setf (task-state task) :running))
  (progv (mapcar #'car (task-context task)) (mapcar #'cdr (task-context task))
    (let ((*current-task* task)
          (*cancel-scopes* (cons task (task-scopes task))))
      (ensure-float-modes)
      (handler-case
          (progn (check-cancellation)
                 (finish-task task :done (funcall (task-fn task))))
        (cancelled () (finish-task task :cancelled nil))
        (error (e) (finish-task task :failed e))))))

(defun cancel-task (task)
  "Ask TASK to stop at its next cancellation point. Returns true if it had not finished."
  (setf (task-cancel-requested task) t)
  (not (task-finished-p task)))

(defun await-task (task &key deadline)
  "Wait for TASK to finish. Returns its value, re-signals its error, or signals
TASK-CANCELLED-ERROR. Returns :TIMEOUT if DEADLINE passes first."
  (when (eq (wait-for (task-lock task) (task-done task)
                      (lambda () (task-finished-p task)) (lambda () t)
                      :deadline deadline)
            :timeout)
    (return-from await-task :timeout))
  (ecase (task-state task)
    (:done (task-result task))
    (:failed (error (task-condition task)))
    (:cancelled (error 'task-cancelled-error :location nil :message "the task was cancelled"))))

;;; ------------------------------------------------------------------------------------
;;; The worker pool

(sb-ext:define-load-time-global **pool-lock** (sb-thread:make-mutex :name "pool"))
(sb-ext:define-load-time-global **pool-wake** (sb-thread:make-waitqueue))
(sb-ext:define-load-time-global **pool-queue** '())
(sb-ext:define-load-time-global **idle-workers** 0)
(sb-ext:define-load-time-global **worker-count** 0)

(defparameter *worker-idle-seconds* 30
  "How long an idle worker thread waits for work before it exits.")

(defun worker-loop ()
  (ensure-float-modes)
  (loop
    (let ((task nil))
      (sb-thread:with-mutex (**pool-lock**)
        (incf **idle-workers**)
        (let ((deadline (seconds-from-now *worker-idle-seconds*)))
          (loop until (or **pool-queue** (>= (now) deadline))
                do (timed-wait **pool-wake** **pool-lock** 1)))
        (decf **idle-workers**)
        (if **pool-queue**
            (setf task (pop **pool-queue**))
            (progn (decf **worker-count**) (return))))
      (run-task task))))

(defun submit-task (task)
  "Queue TASK to run on a worker thread, starting a new worker if none is idle."
  (sb-thread:with-mutex (**pool-lock**)
    (setf **pool-queue** (nconc **pool-queue** (list task)))
    (if (> **idle-workers** (length **pool-queue**))
        (sb-thread:condition-notify **pool-wake**)
        (progn (incf **worker-count**)
               (sb-thread:make-thread #'worker-loop :name "skein worker"))))
  task)

;;; ------------------------------------------------------------------------------------
;;; Nurseries (structured concurrency)

(defun cancel-nursery (n)
  (setf (nursery-cancelled n) t)
  (dolist (child (sb-thread:with-mutex ((nursery-lock n)) (copy-list (nursery-children n))))
    (cancel-task child)))

(defun record-nursery-failure (n condition)
  "Make CONDITION N's failure unless it has one; return true if it is the first."
  (sb-thread:with-mutex ((nursery-lock n))
    (unless (nursery-failure n) (setf (nursery-failure n) condition) t)))

(defun spawn-in (n fn)
  "Start FN as a task owned by the nursery N."
  (unless (nursery-p n)
    (skein-error 'skein-error nil "spawn needs a nursery, not ~A" (readable-string n)))
  (let ((task (make-task fn :nursery n :scopes *cancel-scopes*)))
    (sb-thread:with-mutex ((nursery-lock n)) (push task (nursery-children n)))
    (when (nursery-cancelled n) (cancel-task task))
    (submit-task task)))

(defun join-nursery (n)
  "Wait until every task of N has finished. If the waiting code is cancelled or times out
meanwhile, cancel the children and keep waiting for them, without further cancellation
checks; then return that interruption (a condition), or NIL."
  (let ((scopes *cancel-scopes*)
        (interruption nil))
    (loop
      (let ((pending (remove-if #'task-finished-p
                                (sb-thread:with-mutex ((nursery-lock n))
                                  (copy-list (nursery-children n))))))
        (when (null pending) (return interruption))
        (let ((child (first pending)))
          (handler-case (let ((*cancel-scopes* scopes))
                          (wait-for (task-lock child) (task-done child)
                                    (lambda () (task-finished-p child)) (lambda () t)))
            ((or cancelled task-timeout) (c)
              (cancel-nursery n)
              (setf scopes '() interruption c))))))))

(defun call-with-nursery (fn)
  "Run (FN nursery). Wait for all its tasks; if one fails, cancel the others and the
body, then re-signal that failure. If the body fails, cancel the tasks and re-signal."
  (let* ((n (make-nursery))
         (result nil)
         (problem nil))
    (let ((*cancel-scopes* (cons n *cancel-scopes*)))
      (handler-case (setf result (funcall fn n))
        (cancelled (c) (setf problem c))
        (error (e) (setf problem e) (cancel-nursery n)))
      (let* ((*cancel-scopes* (rest *cancel-scopes*))
             (interruption (join-nursery n)))
        (unless problem (setf problem interruption))))
    (cond ((nursery-failure n) (error (nursery-failure n)))
          (problem (error problem))
          (t result))))

;;; ------------------------------------------------------------------------------------
;;; Futures, sleep, timeouts and the main thread

(defun start-future (fn)
  "Start FN as a detached task (a future); deref waits for it."
  (submit-task (make-task fn)))

(defun skein-sleep (seconds)
  "Sleep for SECONDS, a cancellation point."
  (unless (and (realp seconds) (not (minusp seconds)))
    (skein-error 'skein-error nil "sleep needs a non-negative number of seconds, not ~A"
                 (readable-string seconds)))
  (let ((lock (sb-thread:make-mutex)) (queue (sb-thread:make-waitqueue)))
    (wait-for lock queue (constantly nil) (constantly nil)
              :deadline (seconds-from-now seconds))
    nil))

(defun call-with-timeout (seconds fn)
  "Run FN; if it is still running after SECONDS, its next cancellation point signals
TASK-TIMEOUT (and so do those of tasks it spawned meanwhile)."
  (let ((*cancel-scopes* (cons (make-deadline (seconds-from-now seconds) seconds)
                               *cancel-scopes*)))
    (funcall fn)))

(defun run-on-main-thread (fn)
  "Run FN on the main thread and return its value, waiting for it if called elsewhere."
  (if (main-thread-p)
      (funcall fn)
      (let ((task (make-task fn)))
        (sb-thread:with-mutex (**main-queue-lock**)
          (setf **main-queue** (nconc **main-queue** (list task))))
        (await-task task))))

(defun spawn-on-main-thread (fn)
  "Queue FN as a task for the main thread and return the task."
  (let ((task (make-task fn)))
    (sb-thread:with-mutex (**main-queue-lock**)
      (setf **main-queue** (nconc **main-queue** (list task))))
    task))

;;; ------------------------------------------------------------------------------------
;;; Data parallelism

(defun chunk-ranges (n)
  "Split 0..N into at most one range per CPU, as a list of (start . end)."
  (when (zerop n) (return-from chunk-ranges '()))
  (let* ((parts (max 1 (min n (skein.platform:cpu-count))))
         (size (ceiling n parts)))
    (loop for start from 0 below n by size
          collect (cons start (min n (+ start size))))))

(defun parallel-ranges (n fn)
  "Call (FN start end) for ranges covering 0..N in parallel; return the results in order."
  (let ((ranges (chunk-ranges n)))
    (if (<= (length ranges) 1)
        (mapcar (lambda (r) (funcall fn (car r) (cdr r))) ranges)
        (call-with-nursery
         (lambda (nursery)
           (mapcar #'await-task
                   (mapcar (lambda (r)
                             (spawn-in nursery (lambda () (funcall fn (car r) (cdr r)))))
                           ranges)))))))

(defun parallel-map (f coll)
  (let* ((items (coerce (seq-to-cl coll) 'simple-vector))
         (results (make-array (length items))))
    (parallel-ranges (length items)
                     (lambda (start end)
                       (loop for i from start below end
                             do (setf (svref results i) (scall f (svref items i))))))
    (list-from-cl (coerce results 'list))))

(defun parallel-reduce (f init coll)
  (let ((items (coerce (seq-to-cl coll) 'simple-vector)))
    (reduce (lambda (acc x) (scall f acc x))
            (parallel-ranges (length items)
                             (lambda (start end)
                               (let ((acc init))
                                 (loop for i from start below end
                                       do (setf acc (scall f acc (svref items i))))
                                 acc)))
            :initial-value init)))

(defun parallel-dotimes (n fn)
  (unless (typep n '(integer 0))
    (skein-error 'skein-error nil "pdotimes needs a non-negative count, not ~A"
                 (readable-string n)))
  (parallel-ranges n (lambda (start end)
                       (loop for i from start below end do (scall fn i))))
  nil)

;;; ------------------------------------------------------------------------------------
;;; skein.core functions

(dolist (entry '(("cancelled" cancelled) ("timeout" task-timeout)
                 ("task-cancelled-error" task-cancelled-error)))
  (destructuring-bind (name class) entry
    (let ((type (%make-condition-type (format nil "skein.core/~A" name) class)))
      (register-condition-type type)
      (def-var (intern-var +core+ name) type))))

(defcore "%with-nursery" (options-or-fn &optional (fn nil fn-p))
  ;; Natively a nursery takes a policy (D-088); Phase 0 has only :cancel-siblings.
  (when fn-p
    (let ((policy (and (map-p options-or-fn)
                       (map-get options-or-fn (intern-kw "on-error") nil))))
      (unless (or (null policy) (and (kw-p policy) (string= (kw-name policy) "cancel-siblings")))
        (skein-error 'skein-error nil "with-nursery's policy ~A is native only"
                     (readable-string policy)))))
  (let ((fn (if fn-p fn options-or-fn)))
    (call-with-nursery (lambda (n) (scall fn n)))))
(defcore "%spawn" (nursery fn) (spawn-in nursery (lambda () (scall fn))))
(defcore "%future" (fn) (start-future (lambda () (scall fn))))
(defcore "%with-timeout" (seconds fn) (call-with-timeout seconds (lambda () (scall fn))))
(defcore "%on-main-thread" (fn) (run-on-main-thread (lambda () (scall fn))))
(defcore "%spawn-pinned" (where fn)
  (unless (and (kw-p where) (string= (kw-name where) "main"))
    (skein-error 'skein-error nil "spawn-pinned supports only :main, not ~A"
                 (readable-string where)))
  (spawn-on-main-thread (lambda () (scall fn))))
(defcore "%pdotimes" (n fn) (parallel-dotimes n fn))
(defcore "drain-main-thread!" () (drain-main-thread) nil)
(defcore "check-cancelled" () (check-cancellation) nil)
(defcore "sleep" (seconds) (skein-sleep seconds))
(defcore "cancel!" (task) (bool (cancel-task task)))
(defcore "cancelled?" (task) (bool (eq (task-state task) :cancelled)))
(defcore "done?" (task) (bool (task-finished-p task)))
(defcore "task?" (x) (bool (task-p x)))
(defcore "pmap" (f coll) (parallel-map f coll))
(defcore "preduce" (f init coll) (parallel-reduce f init coll))
(defcore "cpu-count" () (skein.platform:cpu-count))

;;; ------------------------------------------------------------------------------------
;;; Promises, delays and volatiles (M2.11, D-093). Native programs are the reference;
;;; Phase 0 has them so that the names exist on both hosts.

(defstruct (skein-promise (:copier nil))
  "A promise (BODY nil) or a delay. STATE is :pending, :running, :done or :failed."
  (state :pending)
  (value nil)
  (condition nil)
  (body nil)
  (delay-p nil)
  (owner nil)
  (lock (sb-thread:make-mutex :name "promise") :read-only t)
  (done (sb-thread:make-waitqueue) :read-only t))

(defstruct (skein-volatile (:constructor make-skein-volatile (value)) (:copier nil))
  "A volatile: a box with no synchronization."
  (value nil))

(defun promise-realized-p (p)
  (member (skein-promise-state p) '(:done :failed)))

(defun run-delay (p)
  (let ((state :pending) value condition)
    (unwind-protect
         (handler-case (setf value (skein-apply (skein-promise-body p) '()) state :done)
           (skein-error (c) (setf condition c state :failed)))
      (sb-thread:with-mutex ((skein-promise-lock p))
        (setf (skein-promise-state p) state
              (skein-promise-value p) value
              (skein-promise-condition p) condition
              (skein-promise-owner p) nil)
        (unless (eq state :pending) (setf (skein-promise-body p) nil))
        (sb-thread:condition-broadcast (skein-promise-done p))))))

(defun deref-promise (p deadline timeout-value)
  (when (skein-promise-delay-p p)
    (let ((run nil))
      (sb-thread:with-mutex ((skein-promise-lock p))
        (case (skein-promise-state p)
          (:pending (setf (skein-promise-state p) :running
                          (skein-promise-owner p) sb-thread:*current-thread*
                          run t))
          (:running (when (eq (skein-promise-owner p) sb-thread:*current-thread*)
                      (skein-error 'skein-error nil "a delay's body dereferenced the delay")))))
      (when run (run-delay p))))
  (let ((r (wait-for (skein-promise-lock p) (skein-promise-done p)
                     (lambda () (promise-realized-p p))
                     (lambda () (list (skein-promise-state p) (skein-promise-value p)
                                      (skein-promise-condition p)))
                     :deadline deadline)))
    (cond ((eq r :timeout) timeout-value)
          ((eq (first r) :failed) (error (third r)))
          (t (second r)))))

(defcore "promise" () (make-skein-promise))
(defcore "deliver" (p x)
  (unless (and (skein-promise-p p) (not (skein-promise-delay-p p)))
    (skein-error 'skein-error nil "deliver needs a promise, not ~A" (readable-string p)))
  (sb-thread:with-mutex ((skein-promise-lock p))
    (if (eq (skein-promise-state p) :pending)
        (progn (setf (skein-promise-value p) x (skein-promise-state p) :done)
               (sb-thread:condition-broadcast (skein-promise-done p))
               p)
        nil)))
(defcore "%delay" (f) (make-skein-promise :body f :delay-p t))
(defcore "delay?" (x) (bool (and (skein-promise-p x) (skein-promise-delay-p x))))
(defcore "volatile!" (x) (make-skein-volatile x))
(defcore "volatile?" (x) (bool (skein-volatile-p x)))
(defcore "vreset!" (v x)
  (unless (skein-volatile-p v)
    (skein-error 'skein-error nil "vreset! needs a volatile, not ~A" (readable-string v)))
  (setf (skein-volatile-value v) x))
(defcore "vswap!" (v f &rest args)
  (unless (skein-volatile-p v)
    (skein-error 'skein-error nil "vswap! needs a volatile, not ~A" (readable-string v)))
  (setf (skein-volatile-value v) (skein-apply f (cons (skein-volatile-value v) args))))
