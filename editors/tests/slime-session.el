;;; slime-session.el --- A scripted SLIME session with skein dev -*- lexical-binding: t -*-

;; M2.7's exit (D-082): SLIME, with skein-slime.el and slime-fancy, drives `skein dev' on
;; demo.skn as a user would, and checks what each step shows. Run it from the checkout,
;; with SLIME's directory:
;;
;;   emacs --batch -Q -L <slime> -L editors -l editors/tests/slime-session.el
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

(defun session-wait (what pred &optional seconds)
  "Wait until PRED is true, handling SLIME's input meanwhile; fail after SECONDS (60)."
  (let ((end (+ (float-time) (or seconds 60))))
    (while (not (funcall pred))
      (when (> (float-time) end)
        (error "Timed out waiting for %s" what))
      (accept-process-output nil 0.05))))

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

(defun session-run ()
  "The session."
  (let* ((dir (file-name-as-directory (make-temp-file "skein-slime-" t)))
         (file (expand-file-name "demo.skn" dir)))
    (copy-file (expand-file-name "editors/tests/demo.skn" session-root) file)
    (setq skein-slime-program
          (expand-file-name (if (eq system-type 'windows-nt) "skein.cmd" "skein") session-root))

    ;; A .skn buffer: SLIME on, with its namespace as SLIME's package.
    (find-file file)
    (session-check "a .skn buffer has slime-mode" slime-mode)
    (session-check "its package is its namespace" (equal (slime-current-package) "demo")
                   (slime-current-package))

    ;; M-x skein-slime: skein dev runs the program, and SLIME connects to its Swank.
    (skein-slime file)
    ;; Connected, and SLIME has taken in the connection's info (the socket connects first).
    (session-wait "SLIME to connect"
                  (lambda () (and (slime-connected-p) (slime-lisp-implementation-type)))
                  600)
    (session-check "connected to Skein, without the version question"
                   (equal (slime-lisp-implementation-type) "Skein"))
    (session-wait "the REPL's prompt" (lambda () (session-has (slime-output-buffer) "demo>")))

    ;; The REPL.
    (with-current-buffer (slime-output-buffer)
      (goto-char (point-max))
      (insert "(+ 20 22)")
      (slime-repl-return))
    (session-wait "the REPL's value" (lambda () (session-has (slime-output-buffer) "42")))
    (session-check "the REPL evaluates" t)

    (with-current-buffer (find-buffer-visiting file)
      ;; Evaluating in the buffer's namespace.
      (session-check "C-x C-e" (equal (session-eval "(greet 1)") "=> \"hi 1\"")
                     (session-eval "(greet 1)"))

      ;; C-c C-c on an edited defn.
      (goto-char (point-min))
      (search-forward "\"hi \"")
      (replace-match "\"hello \"")
      (search-backward "(defn greet")
      (forward-char 1)
      (let ((compiled nil))
        (add-hook 'slime-compilation-finished-hook (lambda (&rest _) (setq compiled t)))
        (slime-compile-defun)
        (session-wait "C-c C-c" (lambda () compiled)))
      (session-check "C-c C-c compiles the edited function"
                     (equal (session-eval "(greet 2)") "=> \"hello 2\"")
                     (session-eval "(greet 2)"))

      ;; Completion and the argument list at the cursor.
      (session-check "completion" (equal (car (slime-simple-completions "gre")) '("greet"))
                     (slime-simple-completions "gre"))
      (goto-char (point-max))
      (insert "\n(greet ")
      (let ((doc (slime-eval `(swank:autodoc ',(slime-autodoc--parse-context)
                                             :print-right-margin 80))))
        (session-check "autodoc" (equal (car doc) "(greet ===> n <===)") doc))

      ;; Documentation and M-.
      (slime-describe-symbol "greet")
      (session-wait "the description"
                    (lambda () (session-has "*slime-description*" "Say hi to n.")))
      (session-check "describe shows the docstring" t))
    (with-current-buffer (find-buffer-visiting file)
      (slime-edit-definition "greet")
      (session-check "M-. goes to the definition"
                     (and (equal (file-truename (buffer-file-name)) (file-truename file))
                          (looking-at "(defn greet")
                          (= (line-number-at-pos) 5))
                     (list (buffer-file-name) (line-number-at-pos))))

    ;; SLDB for an error in what Emacs evaluates; a abort leaves it.
    (with-current-buffer (find-buffer-visiting file)
      (slime-eval-async '(swank:interactive-eval "(inner 2)")))
    (session-wait "SLDB" #'sldb-get-default-buffer)
    (with-current-buffer (sldb-get-default-buffer)
      (session-check "SLDB shows the error" (session-has (current-buffer) "division by zero")
                     (buffer-string))
      (session-check "and the backtrace" (session-has (current-buffer) "inner"))
      (sldb-abort))
    (session-wait "SLDB to close" (lambda () (null (sldb-get-default-buffer))))
    (session-check "abort leaves SLDB" t)

    ;; SLDB for an error in the program; its restart resumes it.
    (with-current-buffer (find-buffer-visiting file)
      (session-eval "(reset! go? true)"))
    (session-wait "SLDB for the program" #'sldb-get-default-buffer)
    (with-current-buffer (sldb-get-default-buffer)
      (session-check "with the program's restart" (session-has (current-buffer) "Use ten")
                     (buffer-string))
      (sldb-invoke-restart 0))
    (with-current-buffer (find-buffer-visiting file)
      (session-wait "the program to resume"
                    (lambda () (equal (session-eval "@result") "=> 10")))
      (session-check "a restart resumes the program" t)

      ;; The inspector.
      (slime-inspect "{:a [1 2]}")
      (session-wait "the inspector" (lambda () (session-has (slime-inspector-buffer) ":a")))
      (session-check "the inspector shows a map" t))
    (message "The SLIME session passed: %d checks." session-checks)))

(let ((status 0))
  (condition-case err
      (session-run)
    (error (message "%s" (error-message-string err))
           (when (get-buffer "*skein-dev*")
             (message "skein dev's output:\n%s"
                      (with-current-buffer "*skein-dev*" (buffer-string))))
           (setq status 1)))
  (let ((process (get-buffer-process "*skein-dev*")))
    (when process (delete-process process)))
  (kill-emacs status))

;;; slime-session.el ends here
