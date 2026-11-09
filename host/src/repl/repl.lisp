;;;; The REPL, debugger, file watcher and REPL server (DESIGN §15, D-039).

(in-package #:skein.repl)

;;; ------------------------------------------------------------------------------------
;;; Mailboxes: thread-safe FIFO queues

(defstruct (mailbox (:constructor make-mailbox ()) (:copier nil))
  (lock (sb-thread:make-mutex :name "mailbox"))
  (ready (sb-thread:make-waitqueue))
  (items '()))

(defun send (box item)
  (sb-thread:with-mutex ((mailbox-lock box))
    (setf (mailbox-items box) (append (mailbox-items box) (list item)))
    (sb-thread:condition-broadcast (mailbox-ready box)))
  item)

(defun receive (box &key timeout)
  "Return the next item of BOX, waiting for one. With TIMEOUT (seconds), return NIL if
none arrives in time."
  (let ((deadline (and timeout (+ (get-internal-real-time)
                                  (* timeout internal-time-units-per-second)))))
    (sb-thread:with-mutex ((mailbox-lock box))
      (loop
        (when (mailbox-items box)
          (return (pop (mailbox-items box))))
        (when (and deadline (>= (get-internal-real-time) deadline))
          (return nil))
        (skein.runtime::timed-wait (mailbox-ready box) (mailbox-lock box) 0.05)))))

;;; ------------------------------------------------------------------------------------
;;; Shared output: SBCL's file streams are not thread-safe, and in `skein dev` the program
;;; and the REPL write to the same terminal. Both go through one of these.

(defclass locked-output (sb-gray:fundamental-character-output-stream)
  ((target :initarg :target :reader locked-target)
   (lock :initform (sb-thread:make-mutex :name "output") :reader locked-lock))
  (:documentation "A character output stream that serializes writes to TARGET."))

(defmacro with-target ((var stream) &body body)
  `(sb-thread:with-recursive-lock ((locked-lock ,stream))
     (let ((,var (locked-target ,stream)))
       ,@body)))

(defmethod sb-gray:stream-write-char ((s locked-output) char)
  (with-target (out s) (write-char char out)))
(defmethod sb-gray:stream-write-string ((s locked-output) string &optional (start 0) end)
  (with-target (out s) (write-string string out :start start :end end)))
(defmethod sb-gray:stream-line-column ((s locked-output))
  (with-target (out s) (sb-kernel:charpos out)))
(defmethod sb-gray:stream-fresh-line ((s locked-output))
  (with-target (out s) (fresh-line out)))
(defmethod sb-gray:stream-terpri ((s locked-output))
  (with-target (out s) (terpri out)))
(defmethod sb-gray:stream-finish-output ((s locked-output))
  (with-target (out s) (finish-output out)))
(defmethod sb-gray:stream-force-output ((s locked-output))
  (with-target (out s) (force-output out)))
(defmethod sb-gray:stream-clear-output ((s locked-output))
  (with-target (out s) (clear-output out)))

(defun locked (stream)
  (if (typep stream 'locked-output)
      stream
      (make-instance 'locked-output :target stream)))

(defvar *initial-namespace* "user"
  "The namespace new consoles start in: the program's in `skein dev`.")

;;; ------------------------------------------------------------------------------------
;;; Consoles

(defstruct (console (:copier nil))
  "A REPL connection: the terminal or a socket client."
  (name "console")
  (in nil)
  (out nil)
  (mailbox (make-mailbox))
  ;; Messages put aside while debugging, handled before new ones.
  (deferred '())
  (reader nil)
  (closed nil)
  ;; True when the console ended with :quit rather than at the end of its input.
  (quit nil)
  (on-close nil))

(sb-ext:define-load-time-global **consoles-lock** (sb-thread:make-mutex :name "consoles"))
(sb-ext:define-load-time-global **consoles** '())

(defun live-consoles ()
  (sb-thread:with-mutex (**consoles-lock**) (copy-list **consoles**)))

(defvar *console* nil
  "The console whose control loop runs in this thread, or NIL.")

(defvar *debug-level* 0
  "How many debugger loops are active in this thread.")

(defun announce (control &rest args)
  "Print a message on every console (or the error stream if there are none)."
  (let ((text (apply #'format nil control args))
        (consoles (live-consoles)))
    (if consoles
        (dolist (c consoles)
          (ignore-errors
           (format (console-out c) "~&~A~%" text)
           (finish-output (console-out c))))
        (progn (format *error-output* "~&~A~%" text)
               (finish-output *error-output*)))))

(defun start-reader (console)
  "Start the thread that reads forms from CONSOLE's input and sends them to its mailbox
as (:form syntax), (:read-error message) or (:eof)."
  (sb-thread:make-thread
     (lambda ()
       ;; Making a reader peeks at the input, which blocks until some arrives.
       (let ((reader (skein.reader:make-reader (console-in console) :file "repl"
                                                                     :namespace "user"))
             (eof '#:eof))
         (setf (console-reader console) reader)
         (loop
           (handler-case
               (let ((form (skein.reader:read-form reader :eof-value eof)))
                 (when (eq form eof)
                   (send (console-mailbox console) '(:eof))
                   (return))
                 (send (console-mailbox console) (list :form form)))
             (skein.reader:read-error (e)
               (send (console-mailbox console)
                     (list :read-error (let ((*print-pretty* nil)) (princ-to-string e))))
               ;; Skip the rest of the bad line.
               (ignore-errors (read-line (console-in console) nil nil)))
             (error ()
               ;; The stream went away (e.g. a socket closed).
               (send (console-mailbox console) '(:eof))
               (return))))))
     :name (format nil "~A reader" (console-name console))))

(defun next-message (console)
  (or (pop (console-deferred console))
      (receive (console-mailbox console))))

(defun prompt (console &optional (prefix ""))
  (let ((out (console-out console)))
    (fresh-line out)
    (write-string (format nil "~A~A=> " prefix (namespace-name *current-namespace*)) out)
    (finish-output out)
    (when (console-reader console)
      (setf (skein.reader:reader-namespace (console-reader console))
            (namespace-name *current-namespace*)))))

(defun keyword-form (syntax)
  "If SYNTAX is a keyword like :quit, return its name, else NIL."
  (let ((d (skein.syntax:syntax-datum syntax)))
    (and (kw-p d) (null (skein.runtime::kw-namespace d)) (kw-name d))))

(defun integer-form (syntax)
  (let ((d (skein.syntax:syntax-datum syntax)))
    (and (integerp d) d)))

;;; History: *1, *2, *3 and *e live in skein.core, so every namespace sees them.

(defun set-core-var (name value)
  (def-var (intern-var +core+ name) value))

(defun record-value (value)
  (let ((v1 (skein.runtime:var-value (intern-var +core+ "*1")))
        (v2 (skein.runtime:var-value (intern-var +core+ "*2"))))
    (set-core-var "*3" v2)
    (set-core-var "*2" v1)
    (set-core-var "*1" value)))

(dolist (name '("*1" "*2" "*3" "*e"))
  (set-core-var name nil))

(defun print-result (out value)
  (format out "~A~%" (readable-string value))
  (finish-output out))

(defun eval-print (console form &key (abort-report "Return to the REPL"))
  "Evaluate FORM and print its value, with an abort restart around it."
  (let ((out (console-out console)))
    (restart-case
        (let ((value (skein.backend.cl:eval-toplevel form)))
          (finish-output *standard-output*)
          (record-value value)
          (print-result out value))
      (skein-restarts::|abort| ()
        :report (lambda (s) (write-string abort-report s))
        (format out "~&; aborted~%")
        (finish-output out)))))

(defun console-loop (console)
  "Run CONSOLE's read-eval-print loop in this thread until its input ends or :quit."
  (let ((*console* console)
        (*debug-level* 0)
        (*current-namespace* (ensure-namespace *initial-namespace*))
        (*standard-output* (console-out console))
        (*error-output* (console-out console)))
    (sb-thread:with-mutex (**consoles-lock**) (push console **consoles**))
    (start-reader console)
    (unwind-protect
         (loop
           (prompt console)
           (let ((msg (next-message console)))
             (ecase (first msg)
               (:eof (return))
               (:read-error (format (console-out console) "~&error: ~A~%" (second msg)))
               (:session (when (claim-session (second msg) console)
                           (remote-debug console (second msg))))
               (:form (let ((name (keyword-form (second msg))))
                        (if (equal name "quit")
                            (progn (setf (console-quit console) t) (return))
                            (eval-print console (second msg))))))))
      (sb-thread:with-mutex (**consoles-lock**)
        (setf **consoles** (remove console **consoles**)))
      (setf (console-closed console) t)
      ;; Any session this console was offered goes to another console.
      (dolist (msg (console-deferred console))
        (when (eq (first msg) :session) (offer-session (second msg))))
      (when (console-on-close console)
        (funcall (console-on-close console))))))

;;; ------------------------------------------------------------------------------------
;;; The debugger

(defun skein-restart-p (restart)
  (let ((name (restart-name restart)))
    (and name (eq (symbol-package name) (find-package '#:skein-restarts)))))

(defun debugger-restarts (condition)
  "The Skein restarts active for CONDITION, innermost first."
  (remove-if-not #'skein-restart-p (compute-restarts condition)))

(defun restart-label (restart)
  (readable-string (skein.runtime::restart-skein-name restart)))

(defun describe-error (condition restarts out &key (where ""))
  (let ((*print-pretty* nil))
    (format out "~&error~A: ~A~%" where condition)
    (when restarts
      (format out "restarts (type a number to choose one):~%")
      (loop for r in restarts
            for i from 0
            do (format out "  ~D: ~A~@[  ~A~]~%" i (car r) (cdr r))))
    (format out "Also: :bt for a backtrace, or any form to evaluate it here.~%")
    (finish-output out)))

(defun restart-descriptions (restarts)
  (mapcar (lambda (r)
            (cons (restart-label r)
                  (let ((*print-pretty* nil)) (princ-to-string r))))
          restarts))

(defun backtrace-lines (&key (count 40))
  "Return the Skein function frames on this thread's stack, innermost first."
  (let ((lines '()))
    (sb-debug:map-backtrace
     (lambda (frame)
       (let ((name (ignore-errors (sb-di:debug-fun-name (sb-di:frame-debug-fun frame)))))
         (when (and (stringp name) (< (length lines) count))
           (push name lines)))))
    (nreverse lines)))

(defun print-backtrace (out)
  (let ((lines (backtrace-lines)))
    (if lines
        (loop for line in lines for i from 0 do (format out "  ~D: ~A~%" i line))
        (format out "  (no Skein frames)~%"))
    (finish-output out)))

(defun outermost-abort (restarts)
  (find-if (lambda (r) (string= (symbol-name (restart-name r)) "abort")) restarts
           :from-end t))

(defun local-debug (console condition)
  "The debugger loop for an error in CONSOLE's own thread."
  (let* ((*debug-level* (1+ *debug-level*))
         (out (console-out console))
         (restarts (debugger-restarts condition))
         (prefix (format nil "debug[~D] " *debug-level*)))
    (describe-error condition (restart-descriptions restarts) out)
    (loop
      (prompt console prefix)
      (let ((msg (next-message console)))
        (case (first msg)
          (:eof
           ;; Input ended: unwind to the top and let the console loop see the end.
           (push '(:eof) (console-deferred console))
           (let ((abort (outermost-abort restarts)))
             (if abort (invoke-restart abort) (return))))
          (:read-error (format out "~&error: ~A~%" (second msg)))
          (:session (setf (console-deferred console)
                          (append (console-deferred console) (list msg))))
          (:form
           (let* ((form (second msg))
                  (n (integer-form form))
                  (name (keyword-form form)))
             (cond ((and n (< -1 n (length restarts)))
                    (invoke-restart (nth n restarts)))
                   (n (format out "~&no restart ~D~%" n))
                   ((equal name "bt") (print-backtrace out))
                   ((equal name "quit")
                    (push '(:eof) (console-deferred console))
                    (let ((abort (outermost-abort restarts)))
                      (if abort (invoke-restart abort) (return))))
                   (t (eval-print console form
                                  :abort-report (format nil "Return to debug level ~D"
                                                        *debug-level*)))))))))))

;;; Sessions: an error in a program thread, waiting for a console to tell it what to do.

(defstruct (session (:copier nil))
  thread
  condition
  restarts                              ; (label . report) pairs
  (mailbox (make-mailbox))
  (console nil)
  (finished nil))

(sb-ext:define-load-time-global **sessions-lock** (sb-thread:make-mutex :name "sessions"))

(defun claim-session (session console)
  "Make CONSOLE the one debugging SESSION, unless another console already is."
  (sb-thread:with-mutex (**sessions-lock**)
    (when (and (null (session-console session)) (not (session-finished session)))
      (setf (session-console session) console))))

(defun offer-session (session)
  "Offer SESSION to every live console; if there are none, tell it to give up."
  (let ((consoles (live-consoles)))
    (if consoles
        (dolist (c consoles) (send (console-mailbox c) (list :session session)))
        (send (session-mailbox session) '(:no-console)))))

(defun remote-debug (console session)
  "Debug SESSION from CONSOLE: send it the forms typed here until it resumes."
  (let ((out (console-out console))
        (prefix (format nil "debug[~A] " (sb-thread:thread-name (session-thread session)))))
    (describe-error (session-condition session) (session-restarts session) out
                    :where (format nil " in thread ~A"
                                   (sb-thread:thread-name (session-thread session))))
    (loop
      (prompt console prefix)
      (let ((msg (next-message console)))
        (case (first msg)
          (:eof
           (push '(:eof) (console-deferred console))
           (sb-thread:with-mutex (**sessions-lock**) (setf (session-console session) nil))
           (send (session-mailbox session) '(:detach))
           (return))
          (:read-error (format out "~&error: ~A~%" (second msg)))
          (:session (setf (console-deferred console)
                          (append (console-deferred console) (list msg))))
          (:form
           (let ((reply (make-mailbox)))
             (send (session-mailbox session)
                   (list :form (second msg) reply *current-namespace* out))
             (let ((answer (receive reply)))
               (ecase (first answer)
                 (:value (format out "~A~%" (second answer)))
                 (:error (format out "~&error: ~A~%" (second answer)))
                 (:message (format out "~A~%" (second answer)))
                 (:resumed (format out "~&; resumed~%")
                  (finish-output out)
                  (return)))
               (finish-output out)))))))))

(defun program-debug (condition)
  "The debugger for an error in a thread that is not a console: wait for a console to
attach, and evaluate what it sends in this thread, where the restarts are."
  (let* ((restarts (debugger-restarts condition))
         (session (make-session :thread sb-thread:*current-thread* :condition condition
                                :restarts (restart-descriptions restarts))))
    (flet ((give-up ()
             (let ((*print-pretty* nil))
               (format *error-output* "~&error in thread ~A: ~A~%"
                       (sb-thread:thread-name sb-thread:*current-thread*) condition)
               (finish-output *error-output*))
             (let ((abort (outermost-abort restarts)))
               (if abort
                   (invoke-restart abort)
                   (end-thread)))))
      (unless (live-consoles) (give-up))
      (offer-session session)
      (unwind-protect
           (loop
             (let ((msg (receive (session-mailbox session) :timeout 0.1)))
               (case (first msg)
                 ((nil) (when (and (null (session-console session)) (null (live-consoles)))
                          (give-up)))
                 (:no-console (give-up))
                 (:detach (offer-session session))
                 (:form (destructuring-bind (form reply namespace out) (rest msg)
                          (session-eval form reply namespace out restarts))))))
        (sb-thread:with-mutex (**sessions-lock**)
          (setf (session-finished session) t))))))

(defun session-eval (form reply namespace out restarts)
  "Handle one form a console sent to this thread's debug session."
  (let ((replied nil)
        (n (integer-form form))
        (name (keyword-form form)))
    (flet ((answer (&rest x) (setf replied t) (send reply x)))
      (unwind-protect
           (cond ((and n (< -1 n (length restarts)))
                  (answer :resumed)
                  (invoke-restart (nth n restarts)))
                 (n (answer :message (format nil "no restart ~D" n)))
                 ((equal name "bt")
                  (answer :message (with-output-to-string (s) (print-backtrace s))))
                 ((equal name "quit")
                  (answer :resumed)
                  (let ((abort (outermost-abort restarts)))
                    (when abort (invoke-restart abort))))
                 (t (handler-case
                        (let* ((*current-namespace* namespace)
                               (*standard-output* out)
                               (value (skein.backend.cl:eval-toplevel form)))
                          (finish-output out)
                          (record-value value)
                          (answer :value (readable-string value)))
                      (error (e)
                        (answer :error (let ((*print-pretty* nil)) (princ-to-string e)))))))
        ;; The form invoked a restart (or otherwise left): the thread resumes.
        (unless replied (send reply '(:resumed)))))))

(defun debug-condition (condition)
  "Handle an unhandled error: open the debugger in this console's thread, or a debug
session that a console can attach to."
  (set-core-var "*e" condition)
  ;; SBCL turns the hook off while it runs; errors made in the debugger need it too.
  (let ((sb-ext:*invoke-debugger-hook* #'debugger-hook))
    (if *console*
        (local-debug *console* condition)
        (program-debug condition)))
  ;; Reached only if no restart was invoked.
  (let ((abort (outermost-abort (debugger-restarts condition))))
    (if abort
        (invoke-restart abort)
        (end-thread))))

(defun end-thread ()
  "With nothing to resume, end the failing thread; only the main thread ends the process."
  (if (eq sb-thread:*current-thread* (sb-thread:main-thread))
      (sb-ext:exit :code 1 :abort t)
      (sb-thread:abort-thread)))

(defun install-debugger ()
  "Make unhandled errors in every thread open the Skein debugger."
  ;; Both this thread's binding (the launcher binds one) and the global value, which
  ;; other threads see.
  (setf sb-ext:*invoke-debugger-hook* #'debugger-hook
        (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) #'debugger-hook))

(defun debugger-hook (condition hook)
  (declare (ignore hook))
  (debug-condition condition))

;;; ------------------------------------------------------------------------------------
;;; Reloading

(defun namespace-source (ns)
  "The file NS was loaded from, or the file that would be loaded for it."
  (or (namespace-file ns)
      (let ((path (skein.backend.cl:find-namespace-file (namespace-name ns))))
        (and path (uiop:native-namestring path)))))

(defun reload-namespace (name)
  "Load the source file of the namespace called NAME again. Vars keep their identity, so
code that calls them sees the new definitions. Returns the file's path."
  (let* ((ns (find-namespace name))
         (path (if ns
                   (namespace-source ns)
                   (let ((p (skein.backend.cl:find-namespace-file name)))
                     (and p (uiop:native-namestring p))))))
    (unless path
      (skein-error 'namespace-error nil "cannot reload ~A: no source file found" name))
    (let ((*current-namespace* (ensure-namespace "user")))
      (skein.backend.cl:load-file path))
    path))

(skein.runtime:defcore "reload" (name)
  (unless (and (sym-p name) (null (sym-namespace name)))
    (skein-error 'namespace-error nil "reload needs a namespace name, like (reload 'game.core)"))
  (reload-namespace (sym-name name))
  nil)

;;; ------------------------------------------------------------------------------------
;;; The file watcher

(defvar *watch-interval* 0.25
  "Seconds between checks for changed source files in `skein dev`.")

(defun watched-files ()
  "The source files of the loaded namespaces."
  (remove-duplicates
   (loop for ns in (all-namespaces)
         for file = (and (namespace-loaded-p ns) (namespace-file ns))
         when file collect file)
   :test #'string=))

(defun file-date (path) (ignore-errors (file-write-date path)))

(defun start-watcher (source-paths)
  "Start a thread that reloads loaded source files when they change. Returns a function
that stops it."
  (let ((stop nil)
        (dates (make-hash-table :test 'equal)))
    (dolist (f (watched-files)) (setf (gethash f dates) (file-date f)))
    (sb-thread:make-thread
     (lambda ()
       (skein.runtime:ensure-float-modes)
       (let ((*source-paths* source-paths))
         (loop until stop
               do (dolist (f (watched-files))
                    (let ((date (file-date f)))
                      (multiple-value-bind (old seen) (gethash f dates)
                        (setf (gethash f dates) date)
                        (when (and seen date old (/= date old))
                          (reload-changed f)))))
                  (sleep *watch-interval*))))
     :name "file watcher")
    (lambda () (setf stop t))))

(defun reload-changed (file)
  (handler-case
      (let ((*current-namespace* (ensure-namespace "user")))
        (skein.backend.cl:load-file file)
        (announce "; reloaded ~A" (file-namestring file)))
    (error (e)
      (announce "; error reloading ~A: ~A" (file-namestring file)
                (let ((*print-pretty* nil)) (princ-to-string e))))))

;;; ------------------------------------------------------------------------------------
;;; The REPL server

(defstruct (server (:copier nil)) socket port thread)

(setf (documentation 'server-port 'function)
      "Return the port a REPL server listens on.")

(defun start-server (port)
  "Serve the REPL on localhost:PORT (0 picks a free port) and return the server."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) port)
    (sb-bsd-sockets:socket-listen socket 5)
    (let ((server (make-server :socket socket
                               :port (nth-value 1 (sb-bsd-sockets:socket-name socket)))))
      (setf (server-thread server)
            (sb-thread:make-thread (lambda () (serve server)) :name "REPL server"))
      server)))

(defun serve (server)
  (let ((source-paths *source-paths*)
        (count 0))
    (loop
      (let ((client (handler-case (sb-bsd-sockets:socket-accept (server-socket server))
                      (error () (return)))))
        ;; socket-accept can return NIL without a connection (seen on Windows).
        (if (null client)
            (sleep 0.01)
            (serve-client client (incf count) source-paths))))))

(defun serve-client (client number source-paths)
  (let* ((stream (sb-bsd-sockets:socket-make-stream
                  client :input t :output t :element-type 'character
                         :external-format :utf-8 :buffering :full))
         (console (make-console :name (format nil "client ~D" number)
                                :in stream :out stream)))
    (setf (console-on-close console)
          (lambda ()
            (ignore-errors (close stream))
            (ignore-errors (sb-bsd-sockets:socket-close client))))
    (sb-thread:make-thread
     (lambda ()
       (skein.runtime:ensure-float-modes)
       (let ((*source-paths* source-paths))
         (format stream "; Skein ~A REPL~%" (skein-version))
         (console-loop console)))
     :name (format nil "REPL ~A" (console-name console)))))

(defun stop-server (server)
  "Stop accepting REPL connections."
  (ignore-errors (sb-bsd-sockets:socket-close (server-socket server))))

(defun skein-version () (asdf:component-version (asdf:find-system "skein")))

;;; ------------------------------------------------------------------------------------
;;; skein repl and skein dev

(defun run-repl (&key (in *standard-input*) (out *standard-output*))
  "Run a REPL on IN and OUT in this thread until input ends or :quit. Namespaces are
found in the current directory and lib/."
  (install-debugger)
  (let ((*source-paths* (list (uiop:getcwd) (skein.backend.cl:library-directory))))
    (skein.runtime:ensure-float-modes)
    (format out "Skein ~A REPL. Type :quit or end the input to leave.~%" (skein-version))
    (console-loop (make-console :name "terminal" :in in :out out))
    (fresh-line out)
    (finish-output out)
    0))

(defun run-dev (file args &key (port 5555) (in *standard-input*) (out *standard-output*))
  "Run the program in FILE (calling its -main with ARGS) as `skein dev` does: reload
source files when they change, and serve a REPL on IN/OUT and, unless PORT is NIL, on
localhost:PORT. Returns once the program has finished and the terminal REPL has ended:
0, or 1 if the program was stopped by an error."
  (install-debugger)
  (let* ((out (locked out))
         (*standard-output* out)
         (*error-output* (locked *error-output*))
         (source-paths (skein.backend.cl:program-source-paths file))
         (old-output (sb-ext:symbol-global-value '*standard-output*))
         (terminal-started nil)
         (terminal-done nil)
         (status 0)
         (server (and port
                      (handler-case (start-server port)
                        (error (e)
                          (format out "; no REPL server: cannot listen on port ~D (~A)~%"
                                  port e)
                          nil))))
         (main sb-thread:*current-thread*)
         (program-running t)
         (terminal (make-console :name "terminal" :in in :out out)))
    (setf (console-on-close terminal)
          (lambda ()
            (setf terminal-done t)
            ;; :quit stops a program that is still running, through its abort restart.
            (when (and (console-quit terminal) program-running)
              (ignore-errors
               (sb-thread:interrupt-thread
                main (lambda ()
                       (let ((r (find-restart 'skein-restarts::|abort|)))
                         (when r (invoke-restart r)))))))))
    ;; Threads that bind nothing (the watcher, the server's clients) see these.
    (setf *source-paths* source-paths
          (sb-ext:symbol-global-value '*standard-output*) out)
    (format out "; skein dev: reloading changed files~:[~*~;; REPL on localhost:~D~]~%"
            server (and server (server-port server)))
    (finish-output out)
    (let ((stop-watcher nil))
      (flet ((after-load (namespace)
               ;; The REPL starts in the program's namespace once it has loaded.
               (setf *initial-namespace* (namespace-name namespace)
                     stop-watcher (start-watcher source-paths)
                     terminal-started t)
               (sb-thread:make-thread (lambda ()
                                        (skein.runtime:ensure-float-modes)
                                        (let ((*source-paths* source-paths))
                                          (console-loop terminal)))
                                      :name "REPL terminal")))
      (unwind-protect
           (progn
             (restart-case
                 (skein.backend.cl:run-file file :args args :after-load #'after-load)
               (skein-restarts::|abort| ()
                 :report "Stop the program"
                 (unless (console-quit terminal) (setf status 1))))
             (setf program-running nil)
             (finish-output *standard-output*)
             (when (and terminal-started (not terminal-done))
               (format out "~&; the program has finished; the REPL is still running ~
                            (type :quit to leave)~%")
               (finish-output out))
             (loop while (and terminal-started (not terminal-done))
                   do (skein.runtime::drain-main-thread)
                      (sleep 0.02)))
        (when stop-watcher (funcall stop-watcher))
        (when server (stop-server server))
        (finish-output out)
        (setf (sb-ext:symbol-global-value '*standard-output*) old-output))))
    status))
