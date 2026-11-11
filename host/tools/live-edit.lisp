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

(load (merge-pathnames "live-common.lisp" *load-truename*))
(in-package #:skein-live)

(setf *name* "live-edit")

(defvar *limit* (let ((v (sb-posix:getenv "SKEIN_LIVE_EDIT_LIMIT")))
                  (if v (let ((*read-default-float-format* 'double-float))
                          (coerce (read-from-string v) 'double-float))
                      1d0)))

(defun main ()
  (let ((game (start-driftrock "--frames" "1200" "--autopilot" "--check-60fps"
                               "--slow-frames")))
    ;; Building Driftrock with --eval takes a while the first time.
    (multiple-value-bind (started i) (wait-for "; skein dev" :timeout 900)
      (declare (ignore started))
      (sleep 3)
      ;; Three edits, a second apart: a shared CI runner has slow moments, so the median is
      ;; judged against the limit, and each edit against twice it (D-101).
      (let ((edits '()) (after i))
        (loop for (old new) in '(("(def turn-speed 4.2)" "(def turn-speed 4.3)")
                                 ("(def turn-speed 4.3)" "(def turn-speed 4.4)")
                                 ("(def turn-speed 4.4)" "(def turn-speed 4.5)"))
              do (let ((saved (now)))
                   (replace-in-file game old new)
                   (multiple-value-bind (compiled j)
                       (wait-for "; compiled game.skn" :after after :timeout 30)
                     (note "saved at ~,3F s, compiled code running ~,3F s later"
                           saved (- compiled saved))
                     (push (list saved compiled) edits)
                     (setf after j)
                     (sleep 1))))
        (setf edits (reverse edits))
        (let* ((tooks (mapcar (lambda (e) (- (second e) (first e))) edits))
               (median (second (sort (copy-list tooks) #'<))))
          (note "the median edit ran compiled ~,3F s after saving" median)
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
        (let ((lines (lines)))
          ;; Every slow frame, inside the edits' windows or not, with where it fell: on a
          ;; shared runner, to tell the reloads' stalls from the runner's.
          (loop for (time . line) across lines
                for at = (search "slow frame" line)
                when at
                  do (let ((e (first (sort (copy-list edits) #'<
                                           :key (lambda (e) (abs (- time (first e))))))))
                       (note "~A at ~,3F s: ~,3F s from a save, ~,3F s from its swap"
                             (subseq line at) time (- time (first e)) (- time (second e)))))
          (loop for (time . line) across lines
                when (and (search "slow frame" line)
                          (some (lambda (e) (<= (- (first e) 0.1) time (+ (second e) 0.5)))
                                edits))
                  do (fail "a frame went over the budget around a reload: ~A" line)
                when (search "error in thread" line)
                  do (fail "the program failed: ~A" line)))
        (quit-and-pass)))))

(main)
