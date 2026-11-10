;;; skein-slime.el --- Use SLIME with Skein -*- lexical-binding: t -*-

;; Copyright (c) the Skein authors. MIT License.
;; Package-Requires: ((emacs "27.1") (slime "2.26"))
;; Keywords: languages, lisp

;;; Commentary:

;; Native `skein dev' serves Swank on localhost:4005, so SLIME connects to a running Skein
;; program (DESIGN §15, D-082). This file:
;;
;; - opens `.skn' files in `clojure-mode' (or `lisp-mode' if it isn't installed) with
;;   `slime-mode' on;
;; - tells SLIME each buffer's namespace, from its (ns ...) form, as it reads a Common Lisp
;;   buffer's package from (in-package ...);
;; - connects to Skein without SLIME's "Versions differ" question, since Skein's server
;;   isn't SLIME's own Swank;
;; - adds M-x skein-slime-connect, to connect to a running `skein dev', and M-x skein-slime,
;;   to run `skein dev' on the current file and connect to it.
;;
;; Setup, with SLIME installed (from MELPA, or a checkout on `load-path'):
;;
;;   (add-to-list 'load-path "/path/to/skein/editors")
;;   (require 'skein-slime)
;;   (slime-setup '(slime-fancy))
;;
;; See docs/EDITORS.md.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'slime)

(defgroup skein-slime nil
  "SLIME for Skein."
  :group 'slime
  :prefix "skein-slime-")

(defcustom skein-slime-port 4005
  "The port `skein dev' serves Swank on."
  :type 'integer)

(defcustom skein-slime-program nil
  "The `skein' launcher `skein-slime' runs.
nil finds `skein' (`skein.cmd' on Windows) in the file's directory or the
nearest one above it that has it, then on the PATH."
  :type '(choice (const :tag "Find it" nil) file))

;;; Namespaces

(defun skein-slime-buffer-namespace ()
  "The namespace of the current buffer: the name in its (ns ...) form, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward
             "^[ \t]*(ns[ \t\n]+\\(?:\\^[^ \t\n]+[ \t\n]+\\)*\\([^] \t\n()[{}\"]+\\)" nil t)
        (match-string-no-properties 1)))))

(defun skein-slime-setup-buffer ()
  "Use SLIME in this buffer, with its namespace as SLIME's package."
  (setq-local slime-find-buffer-package-function #'skein-slime-buffer-namespace)
  (slime-mode 1))

;;;###autoload
(defun skein-slime-source-mode ()
  "Edit Skein source with SLIME.
The mode is `clojure-mode' if it is installed, else `lisp-mode'."
  (interactive)
  (if (fboundp 'clojure-mode) (clojure-mode) (lisp-mode))
  (skein-slime-setup-buffer))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.skn\\'" . skein-slime-source-mode))

(defun skein-slime--maybe-setup-buffer ()
  "Set up SLIME in a `.skn' buffer that another setting opened in `clojure-mode'."
  (when (and buffer-file-name (string-match-p "\\.skn\\'" buffer-file-name))
    (skein-slime-setup-buffer)))

(add-hook 'clojure-mode-hook #'skein-slime--maybe-setup-buffer)

;;; Connecting

(defvar skein-slime--connecting-to-skein nil
  "True while SLIME takes in the connection info of a Skein program.")

(defun skein-slime--note-implementation (set-info connection info)
  "Around `slime-set-connection-info' (SET-INFO): note whether INFO is Skein's."
  (let ((skein-slime--connecting-to-skein
         (equal (plist-get (plist-get info :lisp-implementation) :type) "Skein")))
    (funcall set-info connection info)))

(defun skein-slime--check-version (check version connection)
  "Around `slime-check-version' (CHECK): Skein's server has its own VERSION."
  (or skein-slime--connecting-to-skein (funcall check version connection)))

(advice-add 'slime-set-connection-info :around #'skein-slime--note-implementation)
(advice-add 'slime-check-version :around #'skein-slime--check-version)

;;;###autoload
(defun skein-slime-connect (&optional port)
  "Connect SLIME to `skein dev' on localhost (PORT, default `skein-slime-port').
With a prefix argument, ask for the port."
  (interactive (list (if current-prefix-arg
                         (read-number "Swank port: " skein-slime-port)
                       skein-slime-port)))
  ;; 127.0.0.1, not localhost, which may mean IPv6's ::1: the server listens on IPv4.
  (slime-connect "127.0.0.1" (or port skein-slime-port)))

(defun skein-slime--launcher (directory)
  "The `skein' launcher to run for a file in DIRECTORY."
  (let ((name (if (eq system-type 'windows-nt) "skein.cmd" "skein")))
    (or skein-slime-program
        (let ((root (locate-dominating-file
                     directory
                     (lambda (dir) (file-regular-p (expand-file-name name dir))))))
          (and root (expand-file-name name root)))
        (executable-find name)
        (user-error "Cannot find the skein launcher: set `skein-slime-program'"))))

(defun skein-slime--watch-output (_output)
  "In the `skein dev' buffer: connect once the program says where Swank is."
  (let ((port (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "Swank on localhost:\\([0-9]+\\)" nil t)
                  (string-to-number (match-string 1))))))
    (when port
      (remove-hook 'comint-output-filter-functions #'skein-slime--watch-output t)
      (run-at-time 0 nil #'skein-slime-connect port))))

;;;###autoload
(defun skein-slime (file)
  "Run `skein dev' on FILE (the current buffer's) and connect SLIME to it.
The program runs in the buffer *skein-dev*, which is also its terminal REPL.
Swank listens on a free port, which SLIME connects to once the program is
built and running."
  (interactive (list (or buffer-file-name (read-file-name "Skein program: " nil nil t))))
  (let* ((file (expand-file-name file))
         (default-directory (file-name-directory file))
         (launcher (skein-slime--launcher default-directory))
         (buffer (get-buffer-create "*skein-dev*")))
    (let ((old (get-buffer-process buffer)))
      (when old (delete-process old)))
    (with-current-buffer buffer
      (erase-buffer)
      (setq default-directory (file-name-directory file))
      (make-comint-in-buffer "skein-dev" buffer launcher nil "dev" "--no-server"
                             "--swank-port" "0" (file-name-nondirectory file))
      (add-hook 'comint-output-filter-functions #'skein-slime--watch-output nil t))
    (display-buffer buffer)
    buffer))

(provide 'skein-slime)
;;; skein-slime.el ends here
