;;;; What host/tools/live-edit.lisp and live-debug.lisp share (M2.9, M2.15; D-091, D-101):
;;;; Driftrock run under native `skein dev` in a copy of its directory, its output collected
;;;; line by line with the time each came, and the REPL on its standard input.

(require :sb-posix)

(defpackage #:skein-live (:use #:cl))
(in-package #:skein-live)

(defvar *name* "live" "The script's name, which its messages start with.")
(defvar *root* (truename "./"))
(defvar *lines* (make-array 0 :adjustable t :fill-pointer 0)
  "(seconds . line) for each line the program printed.")
(defvar *lock* (sb-thread:make-mutex))
(defvar *start* (get-internal-real-time))
(defvar *process* nil "skein dev's process, once started.")

(defun now ()
  (/ (- (get-internal-real-time) *start*) (float internal-time-units-per-second 1d0)))

(defun note (control &rest args)
  (format t "~&~A: ~?~%" *name* control args)
  (finish-output))

(defun fail (control &rest args)
  "Say what failed, print every line with its time, stop the program and exit with 1."
  (format t "~&~A: FAILED: ~?~%" *name* control args)
  (sb-thread:with-mutex (*lock*)
    (loop for (time . line) across *lines* do (format t "~8,3F ~A~%" time line)))
  (finish-output)
  (when (and *process* (sb-ext:process-alive-p *process*))
    (sb-ext:process-kill *process* 9))
  (sb-ext:exit :code 1 :abort t))

(defun wait-for (text &key (timeout 60) (after 0))
  "The time of the first line after the AFTERth that contains TEXT, and the index after it;
fail after TIMEOUT."
  (loop with deadline = (+ (now) timeout)
        do (sb-thread:with-mutex (*lock*)
             (loop for i from after below (length *lines*)
                   for (time . line) = (aref *lines* i)
                   when (search text line) do (return-from wait-for (values time (1+ i)))))
           (when (> (now) deadline) (fail "timed out waiting for ~S" text))
           (sleep 0.01)))

(defun line-count ()
  (sb-thread:with-mutex (*lock*) (length *lines*)))

(defun lines ()
  "A copy of the lines so far (fail takes the lock to print them)."
  (sb-thread:with-mutex (*lock*) (copy-seq *lines*)))

(defun uiop-temp ()
  (let ((tmp (or (sb-posix:getenv "TMPDIR") (sb-posix:getenv "TEMP") (sb-posix:getenv "TMP")
                 "/tmp/")))
    (pathname (if (member (char tmp (1- (length tmp))) '(#\/ #\\)) tmp
                  (concatenate 'string tmp "/")))))

(defun copy-directory (from to)
  (dolist (file (directory (merge-pathnames "**/*.*" from)))
    (let ((rel (enough-namestring file from)))
      (unless (or (search "dist/" rel) (search "dist\\" rel) (null (pathname-name file)))
        (let ((target (merge-pathnames rel to)))
          (ensure-directories-exist target)
          (with-open-file (in file :element-type '(unsigned-byte 8))
            (with-open-file (out target :element-type '(unsigned-byte 8) :direction :output
                                        :if-exists :supersede)
              (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
                (loop for n = (read-sequence buf in) while (plusp n)
                      do (write-sequence buf out :end n))))))))))

(defun read-file (path)
  (with-open-file (s path)
    (let ((str (make-string (file-length s))))
      (subseq str 0 (read-sequence str s)))))

(defun write-file (path text)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (write-string text s)))

(defun replace-in-file (path old new)
  "Save the file at PATH with its first OLD replaced by NEW; its text before."
  (let* ((text (read-file path))
         (at (or (search old text) (fail "~A has no ~A" path old))))
    (write-file path (concatenate 'string (subseq text 0 at) new
                                  (subseq text (+ at (length old)))))
    text))

(defun start-driftrock (&rest game-args)
  "Copy examples/driftrock to a temporary directory and run it there under
`skein dev --no-server --no-swank` with GAME-ARGS; the path of its copy of game.skn."
  (let ((dir (merge-pathnames (format nil "skein-~A-~D/" *name*
                                      (random 1000000000 (make-random-state t)))
                              (uiop-temp))))
    (copy-directory (merge-pathnames "examples/driftrock/" *root*)
                    (merge-pathnames "driftrock/" dir))
    (let ((args (list* "dev" "--no-server" "--no-swank" "driftrock/main.skn" game-args)))
      (setf *process*
            ;; On Windows, through skein.cmd: a search for bash there can find WSL's
            ;; bash.exe in System32 rather than Git's.
            (if (member :win32 *features*)
                (sb-ext:run-program
                 "cmd" (list* "/c" (sb-ext:native-namestring
                                    (merge-pathnames "skein.cmd" *root*))
                              args)
                 :search t :wait nil :input :stream :output :stream :error :output
                 :directory (namestring dir))
                (sb-ext:run-program
                 "bash" (cons (namestring (merge-pathnames "skein" *root*)) args)
                 :search t :wait nil :input :stream :output :stream :error :output
                 :directory (namestring dir)))))
    (sb-thread:make-thread
     (lambda ()
       (loop for line = (ignore-errors (read-line (sb-ext:process-output *process*) nil nil))
             while line
             do (sb-thread:with-mutex (*lock*)
                  (vector-push-extend (cons (now) (string-right-trim '(#\Return) line))
                                      *lines*)))))
    (merge-pathnames "driftrock/game.skn" dir)))

(defun say (line)
  "Type LINE at the REPL."
  (let ((input (sb-ext:process-input *process*)))
    (format input "~A~%" line)
    (finish-output input)))

(defun quit-and-pass ()
  "Leave skein dev with :quit, check that it exits, and exit with 0."
  (say ":quit")
  (loop repeat 600 while (sb-ext:process-alive-p *process*) do (sleep 0.05))
  (when (sb-ext:process-alive-p *process*)
    (fail "skein dev did not exit after :quit"))
  (note "passed")
  (sb-ext:exit :code 0))
