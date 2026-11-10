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
  run [--release] <file.skn> [args...]
                   run a Skein program: load the file, then call its -main with the
                   args, if it defines one (--release: use the release profile)
  bindgen <header.h>... --prefix P --ns NS [--out FILE] [--library NAME]
          [--lib OS=FILE]... [-I DIR]... [--blocking C_NAME,...]
                   generate Skein FFI bindings from C headers (needs clang;
                   --lib takes macos, linux or windows, e.g. --lib linux=libfoo.so.1)
  build [file.skn] [-o FILE] [--target T] [--profile dev|release] [--keep-c]
                   compile a program to a native executable with skeinc and Zig 0.17.1;
                   with no file, the project that ./project.skn describes. --target
                   takes aarch64-macos, x86_64-windows-gnu, x86_64-linux-gnu, ...
  package [--target T] [--profile dev|release]
                   make a folder (a .app for macOS) in dist/ with the project's
                   executable, its C libraries and its assets
  bootstrap        build build/skeinc, the native compiler, if it's out of date
                   (build and package do this first)
  repl             start a REPL
  dev [--port N | --no-server] <file.skn> [args...]
                   run a program like `run`, reload source files when they change, and
                   serve a REPL on the terminal and on localhost:N (default 5555)
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
  (unless args
    (cli-error +exit-usage+ "skein run: expected a file, e.g. `skein run hello.skn`"))
  (let ((file (first args)))
    (unless (probe-file file)
      (cli-error +exit-failure+ "skein run: file not found: ~A" file))
    (multiple-value-bind (condition restarts) (run-reporting-unhandled file (rest args))
      (when condition
        (finish-output *standard-output*)
        (let ((*print-pretty* nil))
          (cli-error +exit-failure+ "error: ~A~:[~;~%available restarts:~{~%  ~A~}~]"
                     condition restarts restarts))))))

;;; ------------------------------------------------------------------------------------
;;; Native builds: skeinc, the native compiler, does `build` and `package` (M1.11, D-069)

(defun checkout-directory ()
  "The Skein checkout this command line runs from."
  (truename (asdf:system-relative-pathname "skein" "../")))

(defun native-file (root name)
  "build/NAME in the checkout ROOT, with .exe on Windows."
  (merge-pathnames (format nil "build/~A~:[~;.exe~]" name
                           (string= (skein.platform:os-name) "windows"))
                   root))

(defun compiler-sources (root)
  "The files skeinc is built from: lib/'s Skein and the runtime's Zig, C and headers."
  (loop for pattern in '("lib/**/*.skn" "runtime/src/**/*.zig" "runtime/src/**/*.c"
                         "runtime/include/**/*.h" "runtime/platform/**/*.zig")
        ;; merge-pathnames parses the wildcards in PATTERN.
        append (directory (merge-pathnames pattern root))))

(defun compiler-current-p (root)
  "True if build/skeinc exists and no source of it is newer."
  (let ((exe (probe-file (native-file root "skeinc"))))
    (and exe
         (let ((built (file-write-date exe)))
           (every (lambda (f) (<= (file-write-date f) built)) (compiler-sources root))))))

(defun run-native (program args out err &key directory)
  "Run PROGRAM with ARGS, with SKEIN_HOME set to this checkout, copying its output to OUT
and ERR. Returns its exit code."
  (let* ((home (substitute #\/ #\\ (uiop:native-namestring (checkout-directory))))
         (environment (cons (format nil "SKEIN_HOME=~A" home)
                            (remove-if (lambda (e) (uiop:string-prefix-p "SKEIN_HOME=" e))
                                       (sb-ext:posix-environ))))
         (process (sb-ext:run-program (uiop:native-namestring program) args
                                      :search nil :wait t :input t :output out :error err
                                      :environment environment
                                      :directory (and directory
                                                      (uiop:native-namestring directory)))))
    (sb-ext:process-exit-code process)))

(defun bootstrap-compiler (out err)
  "Build build/skeinc unless it is current, and return its path. Phase 0's C backend
builds a first compiler from lib/skein/compiler/main.skn, which builds skeinc (D-063); this
is the only use of that backend from the command line."
  (let* ((root (checkout-directory))
         (skeinc (native-file root "skeinc"))
         (stage1 (native-file root "skeinc-stage1")))
    (unless (compiler-current-p root)
      (format err "skein: building the native compiler, build/skeinc (once; this takes a ~
                   minute or two)~%")
      (finish-output err)
      (ensure-directories-exist stage1)
      (handler-case
          (uiop:with-current-directory (root)
            (skein.backend.c:build-program (merge-pathnames "lib/skein/compiler/main.skn" root)
                                           :output stage1))
        (skein.runtime:skein-error (e)
          (let ((*print-pretty* nil))
            (cli-error +exit-failure+ "skein: building the first compiler failed: ~A" e))))
      (format out "built ~A~%" (uiop:native-namestring stage1))
      (let ((code (run-native stage1 (list "build" "lib/skein/compiler/main.skn"
                                           "-o" (uiop:native-namestring skeinc))
                              out err :directory root)))
        (unless (eql code 0)
          (cli-error +exit-failure+ "skein: building build/skeinc failed"))))
    skeinc))

(defun command-native (command args out err)
  "skein build or skein package: run skeinc with the same arguments, bootstrapping it
first if needed, and return its exit code."
  (run-native (bootstrap-compiler err err) (cons command args) out err))

(defun command-dev (args out)
  (let ((port 5555))
    (loop while (and args (char= (char (first args) 0) #\-))
          do (let ((arg (pop args)))
               (cond ((string= arg "--no-server") (setf port nil))
                     ((string= arg "--port")
                      (setf port (or (ignore-errors (parse-integer (pop args)))
                                     (cli-error +exit-usage+ "skein dev: --port needs a ~
                                                              number"))))
                     (t (cli-error +exit-usage+ "skein dev: unknown option ~A" arg)))))
    (unless args
      (cli-error +exit-usage+ "skein dev: expected a file, e.g. `skein dev game.skn`"))
    (unless (probe-file (first args))
      (cli-error +exit-failure+ "skein dev: file not found: ~A" (first args)))
    (skein.repl:run-dev (first args) (rest args) :port port :in *standard-input* :out out)))

(defun command-bindgen (args out)
  (let ((headers '()) (prefix nil) (namespace nil) (output nil) (library nil)
        (files '()) (includes '()) (blocking '()))
    (flet ((value (option)
             (or (pop args)
                 (cli-error +exit-usage+ "skein bindgen: ~A needs a value" option))))
      (loop while args
            do (let ((arg (pop args)))
                 (cond ((string= arg "--prefix") (setf prefix (value arg)))
                       ((string= arg "--ns") (setf namespace (value arg)))
                       ((string= arg "--out") (setf output (value arg)))
                       ((string= arg "--library") (setf library (value arg)))
                       ((string= arg "--lib")
                        (let* ((v (value arg)) (eq (position #\= v)))
                          (unless (and eq (member (subseq v 0 eq) '("macos" "linux" "windows")
                                                  :test #'string=))
                            (cli-error +exit-usage+ "skein bindgen: --lib takes OS=FILE, where ~
                                                     OS is macos, linux or windows"))
                          (push (cons (subseq v 0 eq) (subseq v (1+ eq))) files)))
                       ((string= arg "-I") (push (value arg) includes))
                       ((and (> (length arg) 2) (string= "-I" arg :end2 2))
                        (push (subseq arg 2) includes))
                       ((string= arg "--blocking")
                        (setf blocking (append blocking (uiop:split-string (value arg)
                                                                           :separator '(#\,)))))
                       ((and (plusp (length arg)) (char= (char arg 0) #\-))
                        (cli-error +exit-usage+ "skein bindgen: unknown option ~A" arg))
                       (t (push arg headers))))))
    (unless (and headers prefix namespace)
      (cli-error +exit-usage+ "skein bindgen: expected headers, --prefix and --ns, e.g. ~
                               `skein bindgen foo.h --prefix FOO_ --ns foo.raw`"))
    (when (and files (not library))
      (setf library "lib"))
    (let ((text (handler-case
                    (skein.bindgen:generate-bindings (reverse headers)
                                                     :prefix prefix :namespace namespace
                                                     :library-name library
                                                     :library-files (reverse files)
                                                     :include-dirs (reverse includes)
                                                     :blocking blocking)
                  (skein.bindgen:bindgen-error (e)
                    (cli-error +exit-failure+ "skein bindgen: ~A" e)))))
      (if output
          (with-open-file (s output :direction :output :if-exists :supersede
                                    :external-format :utf-8)
            (write-string text s))
          (write-string text out)))))

(defun skein-restart-descriptions ()
  "Describe the restarts that Skein code established, innermost first."
  (loop for r in (skein.runtime:skein-compute-restarts)
        when (eq (symbol-package (restart-name (skein.runtime::skein-restart-restart r)))
                 (find-package '#:skein-restarts))
          collect (format nil "~A: ~A"
                          (skein.runtime:readable-string (skein.runtime:skein-restart-name r))
                          (skein.runtime:skein-restart-report r))))

(defun run-reporting-unhandled (file args)
  "Run FILE. If an error goes unhandled, return it and descriptions of the restarts that
were active when it was signaled; otherwise return NIL. Only unhandled errors stop the
program: a signal that no one handles still returns nil, as it should."
  (let ((result
          (catch 'unhandled
            (let ((sb-ext:*invoke-debugger-hook*
                    (lambda (condition hook)
                      (declare (ignore hook))
                      (throw 'unhandled (list condition (skein-restart-descriptions))))))
              (skein.backend.cl:run-file file :args args)
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
              ((string= command "repl")
               (unless (null rest)
                 (cli-error +exit-usage+ "skein repl: takes no arguments"))
               (skein.repl:run-repl :in *standard-input* :out out))
              ((string= command "dev")
               (command-dev rest out))
              ((member command '("build" "package") :test #'string=)
               (command-native command rest out err))
              ((string= command "bootstrap")
               (unless (null rest)
                 (cli-error +exit-usage+ "skein bootstrap: takes no arguments"))
               (let ((skeinc (bootstrap-compiler out err)))
                 (format out "~A is up to date~%" (uiop:native-namestring skeinc)))
               +exit-ok+)
              ((string= command "bindgen")
               (command-bindgen rest out)
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
