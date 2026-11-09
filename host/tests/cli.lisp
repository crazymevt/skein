;;;; Tests for skein.cli.

(in-package #:skein.tests)

(def-suite skein.cli :in all
  :description "The `skein` command line.")

(in-suite skein.cli)

(defun run-cli (&rest args)
  "Run skein.cli:main on ARGS. Return the exit code, stdout and stderr."
  (let* ((out (make-string-output-stream))
         (err (make-string-output-stream))
         (code (skein.cli:main args :out out :err err)))
    (values code (get-output-stream-string out) (get-output-stream-string err))))

(test no-arguments-prints-usage
  (multiple-value-bind (code out err) (run-cli)
    (is (= skein.cli:+exit-usage+ code))
    (is (string= "" out))
    (is (search "Usage: skein" err))))

(test help
  (dolist (flag '("help" "--help" "-h"))
    (multiple-value-bind (code out) (run-cli flag)
      (is (= skein.cli:+exit-ok+ code))
      (is (search "Usage: skein" out)))))

(test version
  (multiple-value-bind (code out) (run-cli "--version")
    (is (= skein.cli:+exit-ok+ code))
    (is (eql 0 (search "skein 0." out)))))

(test unknown-command
  (multiple-value-bind (code out err) (run-cli "frobnicate")
    (is (= skein.cli:+exit-usage+ code))
    (is (string= "" out))
    (is (search "unknown command `frobnicate`" err))))

(test run-needs-a-file
  (is (= skein.cli:+exit-usage+ (run-cli "run")))
  ;; Arguments after the file go to its -main (D-039); the file must still exist.
  (multiple-value-bind (code out err) (run-cli "run" "a.skn" "b.skn")
    (declare (ignore out))
    (is (= skein.cli:+exit-failure+ code))
    (is (search "file not found: a.skn" err))))

(test run-missing-file
  (multiple-value-bind (code out err) (run-cli "run" "no/such/file.skn")
    (is (= skein.cli:+exit-failure+ code))
    (is (string= "" out))
    (is (search "file not found: no/such/file.skn" err))))
