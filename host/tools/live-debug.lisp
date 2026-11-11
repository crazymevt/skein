;;;; M2.15's scripted session (D-101): debug Driftrock while it plays under native
;;;; `skein dev`. A bug saved into one of its jobs crashes it; the job's debugger offers the
;;;; game's retry-frame; the fix is saved and runs compiled; retry-frame resumes the game,
;;;; whose :paused has run meanwhile, and it plays on to the end.
;;;;
;;;;   sbcl --script host/tools/live-debug.lisp
;;;;
;;;; Run it from the checkout, where a display is available (under xvfb-run on Linux CI). It
;;;; copies examples/driftrock to a temporary directory, runs
;;;; `skein dev --no-server --no-swank driftrock/main.skn --frames 900 --autopilot
;;;; --check-60fps --slow-frames` there, and exits with 0 if every check passed.

(load (merge-pathnames "live-common.lisp" *load-truename*))
(in-package #:skein-live)

(setf *name* "live-debug")

(defparameter *rules* "(reset! world (apply-rules wd input dt))"
  "The rules job's work in driftrock/game.skn, where the bug goes.")

(defun main ()
  (let ((game (start-driftrock "--frames" "900" "--autopilot" "--check-60fps"
                               "--slow-frames")))
    ;; Building Driftrock with --eval takes a while the first time.
    (wait-for "; skein dev" :timeout 900)
    (sleep 3)
    ;; The bug: the rules job signals an error.
    (let* ((fixed (replace-in-file game *rules*
                                   (concatenate 'string "(do (error \"planted bug\") "
                                                *rules* ")")))
           (after (nth-value 1 (wait-for "error in thread task: planted bug" :timeout 30))))
      ;; The job's debugger offers the game's frame restarts, then its own abort.
      (wait-for "0: retry-frame  Run this frame again (in main thread)" :after after)
      (wait-for "1: skip-frame  Skip the rest of this frame (in main thread)" :after after)
      (setf after (nth-value 1 (wait-for "2: abort  Fail the task" :after after)))
      ;; Paused: the game's window is kept alive.
      (sleep 1)
      (say "[:paused (< 20 @driftrock.main/paused-calls)]")
      (setf after (nth-value 1 (wait-for "[:paused true]" :after after :timeout 10)))
      ;; The fix, saved: evaluated at once, then compiled.
      (let ((saved (now)))
        (write-file game fixed)
        (setf after (nth-value 1 (wait-for "; reloaded game.skn" :after after :timeout 30)))
        (multiple-value-bind (compiled j) (wait-for "; compiled game.skn" :after after
                                                                           :timeout 30)
          (note "the fix ran compiled ~,3F s after saving" (- compiled saved))
          (setf after j)))
      (say "[:compiled (%evaluated? driftrock.game/update!)]")
      (setf after (nth-value 1 (wait-for "[:compiled false]" :after after :timeout 10)))
      ;; retry-frame: the frame runs again in the main thread, and the game goes on.
      (say "0")
      (multiple-value-bind (resumed j) (wait-for "; resumed" :after after :timeout 10)
        (setf after j)
        (wait-for "the REPL is still running" :after after :timeout 120)
        (let ((lines (lines)))
          ;; Every slow frame: the one that waited in the debugger, and any other, with
          ;; when it came; none may in the two seconds after it resumed but that one.
          (let ((first-after t))
            (loop for (time . line) across lines
                  for at = (search "slow frame" line)
                  when at
                    do (note "~A at ~,3F s: ~,3F s from resuming" (subseq line at) time
                             (- time resumed))
                       (when (and (>= time resumed) (< time (+ resumed 2)))
                         (if first-after
                             (setf first-after nil)
                             (fail "a frame went over the budget after resuming: ~A" line)))))
          (let ((errors (count-if (lambda (l) (search "error in thread" (cdr l))) lines)))
            (when (/= errors 1)
              (fail "~D errors, not just the planted one" errors))))))
    (quit-and-pass)))

(main)
