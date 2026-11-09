;;;; The `skein` command-line interface.

(in-package #:skein.cli)

(defconstant +exit-ok+ 0
  "Exit code for success.")

(defconstant +exit-failure+ 1
  "Exit code when a command runs but fails.")

(defconstant +exit-usage+ 2
  "Exit code for bad command-line usage.")

(define-condition cli-error (error)
  ((message :initarg :message :reader cli-error-message)
   (exit-code :initarg :exit-code :initform +exit-failure+ :reader cli-error-exit-code))
  (:report (lambda (condition stream)
             (write-string (cli-error-message condition) stream)))
  (:documentation "A user-facing error from the `skein` command line.
MAIN prints its message to the error stream and returns its exit code."))

(setf (documentation 'cli-error-exit-code 'function)
      "Return the process exit code that a CLI-ERROR should produce.")

(defun cli-error (exit-code control &rest args)
  "Signal a CLI-ERROR with EXIT-CODE and a message built from CONTROL and ARGS."
  (error 'cli-error :exit-code exit-code
                    :message (apply #'format nil control args)))

(defun version ()
  "Return the Skein version string."
  (asdf:component-version (asdf:find-system "skein")))

(defun print-usage (stream)
  (format stream "~
Usage: skein <command> [arguments]

Commands:
  run [--release] <file.skn>
                   run a Skein program (--release: optimize with the release profile)
  help             show this message
  version          show the Skein version
"))

(defun command-run (args)
  (let ((skein.backend.cl:*profile* :dev))
    (when (equal (first args) "--release")
      (setf skein.backend.cl:*profile* :release
            args (rest args)))
    (command-run-file args)))

(defun command-run-file (args)
  (unless (= (length args) 1)
    (cli-error +exit-usage+ "skein run: expected one file, e.g. `skein run hello.skn`"))
  (let ((file (first args)))
    (unless (probe-file file)
      (cli-error +exit-failure+ "skein run: file not found: ~A" file))
    (multiple-value-bind (condition restarts) (run-reporting-unhandled file)
      (when condition
        (finish-output *standard-output*)
        (let ((*print-pretty* nil))
          (cli-error +exit-failure+ "error: ~A~:[~;~%available restarts:~{~%  ~A~}~]"
                     condition restarts restarts))))))

(defun skein-restart-descriptions ()
  "Describe the restarts that Skein code established, innermost first."
  (loop for r in (skein.runtime:skein-compute-restarts)
        when (eq (symbol-package (restart-name (skein.runtime::skein-restart-restart r)))
                 (find-package '#:skein-restarts))
          collect (format nil "~A: ~A"
                          (skein.runtime:readable-string (skein.runtime:skein-restart-name r))
                          (skein.runtime:skein-restart-report r))))

(defun run-reporting-unhandled (file)
  "Run FILE. If an error goes unhandled, return it and descriptions of the restarts that
were active when it was signaled; otherwise return NIL. Only unhandled errors stop the
program: a signal that no one handles still returns nil, as it should."
  (let ((result
          (catch 'unhandled
            (let ((sb-ext:*invoke-debugger-hook*
                    (lambda (condition hook)
                      (declare (ignore hook))
                      (throw 'unhandled (list condition (skein-restart-descriptions))))))
              (skein.backend.cl:run-file file)
              nil))))
    (values (first result) (second result))))

(defun main (args &key (out *standard-output*) (err *error-output*))
  "Run the `skein` command line with ARGS, a list of strings, and return an exit code.
Normal output goes to OUT and error messages to ERR. MAIN never exits the process;
see TOPLEVEL."
  (handler-case
      (let ((command (first args))
            (rest (rest args)))
        (cond ((null command)
               (print-usage err)
               +exit-usage+)
              ((member command '("help" "--help" "-h") :test #'string=)
               (print-usage out)
               +exit-ok+)
              ((member command '("version" "--version") :test #'string=)
               (format out "skein ~A~%" (version))
               +exit-ok+)
              ((string= command "run")
               (command-run rest)
               +exit-ok+)
              (t
               (cli-error +exit-usage+
                          "skein: unknown command `~A`. Run `skein help` for usage."
                          command))))
    (cli-error (e)
      (format err "~A~%" e)
      (cli-error-exit-code e))))

(defun toplevel ()
  "Entry point for the `skein` launcher scripts: run MAIN on the process's command-line
arguments, then exit with its exit code."
  (let ((code (catch 'internal-error
                ;; Only errors that nothing handles reach the debugger hook, so a Skein
                ;; program's own signals and handlers behave normally.
                (let ((sb-ext:*invoke-debugger-hook*
                        (lambda (condition hook)
                          (declare (ignore hook))
                          (let ((*print-pretty* nil))
                            (format *error-output* "skein: internal error: ~A~%" condition))
                          (throw 'internal-error +exit-failure+))))
                  (main (uiop:command-line-arguments))))))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    (uiop:quit code)))
