;;; driftrock-session.el --- Debugging Driftrock live through SLIME -*- lexical-binding: t -*-

;; M2.15 step 5 (D-101): SLIME, with skein-slime.el, runs Driftrock under `skein dev' and
;; debugs it while it plays, as a user would. A bug compiled into its rules job with
;; C-c C-c opens SLDB in the job's thread, which offers the game's retry-frame; the fix,
;; compiled with C-c C-c, and retry-frame resume the game, which plays on to the end. Run
;; it from the checkout, with SLIME's directory, where a display is available (under
;; xvfb-run on Linux CI):
;;
;;   emacs --batch -Q -L <slime> -L editors -l editors/tests/driftrock-session.el
;;
;; It exits with 0 if every step passed.

;;; Code:

(require 'cl-lib)

(defvar session-root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name)))
  "The Skein checkout.")

(require 'skein-slime)
(slime-setup '(slime-fancy))

(defvar session-checks 0 "How many checks passed.")

(defvar session-rules "(reset! world (apply-rules wd input dt))"
  "The rules job's work in game.skn, where the bug goes.")

(defun session-wait (what pred &optional seconds)
  "Wait until PRED is true, handling SLIME's input meanwhile; fail after SECONDS (60)."
  (let ((end (+ (float-time) (or seconds 60))))
    (while (not (funcall pred))
      (when (> (float-time) end)
        (error "Timed out waiting for %s" what))
      (accept-process-output nil 0.05))))

(defun session-pause (seconds)
  "Handle SLIME's input for SECONDS."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end) (accept-process-output nil 0.05))))

(defun session-check (what ok &optional detail)
  "Fail unless OK, saying WHAT was checked (and DETAIL)."
  (unless ok
    (error "FAILED: %s%s" what (if detail (format "\n%S" detail) "")))
  (cl-incf session-checks)
  (message "ok: %s" what))

(defun session-has (buffer text)
  "True if BUFFER (or its name) exists and contains TEXT."
  (let ((b (get-buffer buffer)))
    (and b (with-current-buffer b
             (save-excursion (goto-char (point-min)) (search-forward text nil t))))))

(defun session-eval (code)
  "What C-x C-e shows for CODE, evaluated in the current buffer's namespace."
  (slime-eval `(swank:interactive-eval ,code)))

(defun session-compile-update (old new)
  "In game.skn's buffer, replace OLD with NEW in update! and C-c C-c it."
  (goto-char (point-min))
  (search-forward old)
  (replace-match new t t)
  (search-backward "(defn update!")
  (forward-char 1)
  (let ((compiled nil))
    (add-hook 'slime-compilation-finished-hook (lambda (&rest _) (setq compiled t)))
    (slime-compile-defun)
    (session-wait "C-c C-c" (lambda () compiled))))

(defun session-run ()
  "The session."
  (let* ((dir (file-name-as-directory (make-temp-file "skein-driftrock-" t)))
         (copy (expand-file-name "driftrock/" dir)))
    (copy-directory (expand-file-name "examples/driftrock/" session-root) copy nil t t)
    (when (file-directory-p (expand-file-name "dist" copy))
      (delete-directory (expand-file-name "dist" copy) t))
    (setq skein-slime-program
          (expand-file-name (if (eq system-type 'windows-nt) "skein.cmd" "skein") session-root))
    (setq skein-slime-program-args '("--autopilot" "--frames" "3600"))

    ;; M-x skein-slime on main.skn: Driftrock plays, and SLIME connects to its Swank.
    (find-file (expand-file-name "main.skn" copy))
    (skein-slime (buffer-file-name))
    (session-wait "SLIME to connect"
                  (lambda () (and (slime-connected-p) (slime-lisp-implementation-type)))
                  900)
    (session-check "connected to Driftrock" (equal (slime-lisp-implementation-type) "Skein"))

    ;; A bug in the rules job, compiled into the playing game with C-c C-c.
    (find-file (expand-file-name "game.skn" copy))
    (session-check "game.skn's package is its namespace"
                   (equal (slime-current-package) "driftrock.game") (slime-current-package))
    (session-compile-update session-rules
                            (concat "(do (error \"planted bug\") " session-rules ")"))
    (session-wait "SLDB for the job" #'sldb-get-default-buffer)
    (with-current-buffer (sldb-get-default-buffer)
      (session-check "SLDB shows the job's error" (session-has (current-buffer) "planted bug")
                     (buffer-string))
      (session-check "and offers the game's retry-frame"
                     (session-has (current-buffer) "Run this frame again (in main thread)")
                     (buffer-string)))

    ;; Paused: the game's window is kept alive.
    (session-pause 1)
    (with-current-buffer (find-buffer-visiting (expand-file-name "game.skn" copy))
      (session-check ":paused runs while the frame waits"
                     (equal (session-eval "(< 20 @driftrock.main/paused-calls)") "=> true")
                     (session-eval "@driftrock.main/paused-calls"))
      ;; The fix, with C-c C-c.
      (session-compile-update (concat "(do (error \"planted bug\") " session-rules ")")
                              session-rules))

    ;; retry-frame: the frame runs again in the main thread, and the game goes on.
    (with-current-buffer (sldb-get-default-buffer)
      (sldb-invoke-restart 0))
    (session-wait "SLDB to close" (lambda () (null (sldb-get-default-buffer))))
    (session-check "retry-frame leaves SLDB" t)
    (session-wait "the game to finish"
                  (lambda () (session-has "*skein-dev*" "the program has finished")) 300)
    (session-check "the game played on to the end" (session-has "*skein-dev*" "score ")
                   (with-current-buffer "*skein-dev*" (buffer-string)))
    (session-check "with no error in the main thread"
                   (not (session-has "*skein-dev*" "error in thread main thread"))
                   (with-current-buffer "*skein-dev*" (buffer-string)))
    (message "The Driftrock SLIME session passed: %d checks." session-checks)))

(let ((status 0))
  (condition-case err
      (session-run)
    (error (message "%s" (error-message-string err))
           (when (get-buffer "*skein-dev*")
             (message "skein dev's output:\n%s"
                      (with-current-buffer "*skein-dev*" (buffer-string))))
           (setq status 1)))
  ;; :quit, so that the program ends too, not only the launcher.
  (let ((process (get-buffer-process "*skein-dev*")))
    (when process
      (ignore-errors (process-send-string process ":quit\n"))
      (let ((end (+ (float-time) 10)))
        (while (and (process-live-p process) (< (float-time) end))
          (accept-process-output process 0.1)))
      (when (process-live-p process) (delete-process process))))
  (kill-emacs status))

;;; driftrock-session.el ends here
