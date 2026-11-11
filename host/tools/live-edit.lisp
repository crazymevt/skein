;;;; M2.9's exit check (D-091): edit Driftrock while it plays under native `skein dev`, and
;;;; check that the change runs as compiled code within a second of saving, without a
;;;; frame over the 60 fps budget around the reload.
;;;;
;;;;   sbcl --script host/tools/live-edit.lisp
;;;;
;;;; Run it from the checkout, where a display is available (under xvfb-run on Linux CI). It
;;;; copies examples/driftrock to a temporary directory, runs
;;;; `skein dev --no-server --no-swank driftrock/main.skn --frames 1200 --autopilot
;;;; --check-60fps --slow-frames` there, changes a constant in driftrock/game.skn three
;;;; times from three seconds into the game, a second apart, and exits with 0 if every check
;;;; passed: the median edit runs compiled within the limit, and each within twice it
;;;; (D-101). SKEIN_LIVE_EDIT_LIMIT sets the limit in seconds (default 1).

(require :sb-posix)

(defpackage #:skein-live-edit (:use #:cl))
(in-package #:skein-live-edit)

(defvar *root* (truename "./"))
(defvar *limit* (let ((v (sb-posix:getenv "SKEIN_LIVE_EDIT_LIMIT")))
                  (if v (let ((*read-default-float-format* 'double-float))
                          (coerce (read-from-string v) 'double-float))
                      1d0)))
(defvar *lines* (make-array 0 :adjustable t :fill-pointer 0)
  "(seconds . line) for each line the program printed.")
(defvar *lock* (sb-thread:make-mutex))
(defvar *start* (get-internal-real-time))

(defun now ()
  (/ (- (get-internal-real-time) *start*) (float internal-time-units-per-second 1d0)))

(defun fail (control &rest args)
  (format t "~&live-edit: FAILED: ~?~%" control args)
  (sb-thread:with-mutex (*lock*)
    (loop for (time . line) across *lines* do (format t "~8,3F ~A~%" time line)))
  (finish-output)
  (sb-ext:exit :code 1 :abort t))

(defun wait-for (text &key (timeout 60) (after 0))
  "The time of the first line after the AFTERth that contains TEXT; fail after TIMEOUT."
  (loop with deadline = (+ (now) timeout)
        do (sb-thread:with-mutex (*lock*)
             (loop for i from after below (length *lines*)
                   for (time . line) = (aref *lines* i)
                   when (search text line) do (return-from wait-for (values time (1+ i)))))
           (when (> (now) deadline) (fail "timed out waiting for ~S" text))
           (sleep 0.01)))

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

(defun main ()
  (let* ((dir (merge-pathnames (format nil "skein-live-edit-~D/" (random 1000000000
                                                                           (make-random-state t)))
                               (uiop-temp)))
         (game (merge-pathnames "driftrock/game.skn" dir)))
    (copy-directory (merge-pathnames "examples/driftrock/" *root*) (merge-pathnames "driftrock/" dir))
    (let* ((args (list "dev" "--no-server" "--no-swank" "driftrock/main.skn"
                       "--frames" "1200" "--autopilot" "--check-60fps" "--slow-frames"))
           ;; On Windows, through skein.cmd: a search for bash there can find WSL's
           ;; bash.exe in System32 rather than Git's.
           (process (if (member :win32 *features*)
                        (sb-ext:run-program
                         "cmd" (list* "/c" (sb-ext:native-namestring
                                            (merge-pathnames "skein.cmd" *root*))
                                      args)
                         :search t :wait nil :input :stream :output :stream :error :output
                         :directory (namestring dir))
                        (sb-ext:run-program
                         "bash" (cons (namestring (merge-pathnames "skein" *root*)) args)
                         :search t :wait nil :input :stream :output :stream :error :output
                         :directory (namestring dir))))
           (input (sb-ext:process-input process)))
      (sb-thread:make-thread
       (lambda ()
         (loop for line = (ignore-errors (read-line (sb-ext:process-output process) nil nil))
               while line
               do (sb-thread:with-mutex (*lock*)
                    (vector-push-extend (cons (now) (string-right-trim '(#\Return) line))
                                        *lines*)))))
      (flet ((say (line) (format input "~A~%" line) (finish-output input)))
        ;; Building Driftrock with --eval takes a while the first time.
        (multiple-value-bind (started i) (wait-for "; skein dev" :timeout 900)
          (declare (ignore started))
          (sleep 3)
          ;; Three edits, a second apart: a shared CI runner has slow moments, so the
          ;; median is judged against the limit, and each edit against twice it (D-101).
          (let ((edits '()) (after i))
            (loop for (old new) in '(("(def turn-speed 4.2)" "(def turn-speed 4.3)")
                                     ("(def turn-speed 4.3)" "(def turn-speed 4.4)")
                                     ("(def turn-speed 4.4)" "(def turn-speed 4.5)"))
                  do (let* ((text (with-open-file (s game)
                                    (let ((str (make-string (file-length s))))
                                      (subseq str 0 (read-sequence str s)))))
                            (at (or (search old text) (fail "~A has no ~A" game old)))
                            (saved (now)))
                       (with-open-file (s game :direction :output :if-exists :supersede)
                         (write-string (concatenate 'string (subseq text 0 at) new
                                                    (subseq text (+ at (length old))))
                                       s))
                       (multiple-value-bind (compiled j)
                           (wait-for "; compiled game.skn" :after after :timeout 30)
                         (format t "live-edit: saved at ~,3F s, compiled code running ~,3F s ~
                                    later~%" saved (- compiled saved))
                         (push (list saved compiled) edits)
                         (setf after j)
                         (sleep 1))))
            (setf edits (reverse edits))
            (let* ((tooks (mapcar (lambda (e) (- (second e) (first e))) edits))
                   (median (second (sort (copy-list tooks) #'<))))
              (format t "live-edit: the median edit ran compiled ~,3F s after saving~%" median)
              (when (> median *limit*)
                (fail "the median edit took ~,3F s to run compiled, over ~,3F s" median *limit*))
              (dolist (took tooks)
                (when (> took (* 2 *limit*))
                  (fail "an edit took ~,3F s to run compiled, over ~,3F s" took (* 2 *limit*)))))
            ;; The last value is in force, in compiled code.
            (say "[driftrock.game/turn-speed (%evaluated? driftrock.game/update!)]")
            (setf after (nth-value 1 (wait-for "[4.5 false]" :after after :timeout 10)))
            ;; No frame over budget from each save until half a second after its swap.
            (wait-for "the REPL is still running" :after after :timeout 120)
            ;; Judged on a copy: fail takes the lock to print every line.
            (let ((lines (sb-thread:with-mutex (*lock*) (copy-seq *lines*))))
              ;; Every slow frame, inside the edits' windows or not, with where it fell: on
              ;; a shared runner, to tell the reloads' stalls from the runner's.
              (loop for (time . line) across lines
                    for at = (search "slow frame" line)
                    when at
                      do (let ((e (first (sort (copy-list edits) #'<
                                               :key (lambda (e) (abs (- time (first e))))))))
                           (format t "live-edit: ~A at ~,3F s: ~,3F s from a save, ~,3F s from ~
                                      its swap~%"
                                   (subseq line at) time (- time (first e)) (- time (second e)))))
              (loop for (time . line) across lines
                    when (and (search "slow frame" line)
                              (some (lambda (e) (<= (- (first e) 0.1) time (+ (second e) 0.5)))
                                    edits))
                      do (fail "a frame went over the budget around a reload: ~A" line)
                    when (search "error in thread" line)
                      do (fail "the program failed: ~A" line)))
              (say ":quit")
              (loop repeat 600 while (sb-ext:process-alive-p process) do (sleep 0.05))
              (when (sb-ext:process-alive-p process)
                (sb-ext:process-kill process 9)
                (fail "skein dev did not exit after :quit"))
              (format t "live-edit: passed~%")
              (sb-ext:exit :code 0)))))))

(defun uiop-temp ()
  (let ((tmp (or (sb-posix:getenv "TMPDIR") (sb-posix:getenv "TEMP") (sb-posix:getenv "TMP")
                 "/tmp/")))
    (pathname (if (member (char tmp (1- (length tmp))) '(#\/ #\\)) tmp
                  (concatenate 'string tmp "/")))))

(main)
