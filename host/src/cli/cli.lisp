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
  run <file.skn>   run a Skein program
  help             show this message
  version          show the Skein version
"))

(defun command-run (args)
  (unless (= (length args) 1)
    (cli-error +exit-usage+ "skein run: expected one file, e.g. `skein run hello.skn`"))
  (let ((file (first args)))
    (unless (probe-file file)
      (cli-error +exit-failure+ "skein run: file not found: ~A" file))
    (cli-error +exit-failure+
               "skein run: running programs is not implemented yet (milestone M0.3)")))

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
  (let ((code (handler-case (main (uiop:command-line-arguments))
                (error (e)
                  (format *error-output* "skein: internal error: ~A~%" e)
                  +exit-failure+))))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    (uiop:quit code)))
