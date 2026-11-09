;;;; The operating system, and where its C libraries live.

(in-package #:skein.platform)

(defun os-name ()
  "Return \"macos\", \"linux\" or \"windows\"."
  #+darwin "macos" #+linux "linux" #+win32 "windows"
  #-(or darwin linux win32) "unknown")

(defun library-directories ()
  "Directories to search for C libraries: those in the SKEIN_LIBRARY_PATH environment
variable, then the usual package-manager locations for this OS."
  (let* ((separator #+win32 #\; #-win32 #\:)
         (from-env (let ((v (uiop:getenv "SKEIN_LIBRARY_PATH")))
                     (and v (remove "" (uiop:split-string v :separator (list separator))
                                    :test #'string=)))))
    (mapcar #'uiop:ensure-directory-pathname
            (append from-env
                    #+darwin '("/opt/homebrew/lib/" "/usr/local/lib/")
                    #+linux '("/usr/local/lib/")
                    #+win32 '()))))
