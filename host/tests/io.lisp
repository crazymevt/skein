;;;; Tests for skein.io (M1.9 step 1, D-058): files and processes in Phase 0. The C
;;;; backend tests run the same fixture natively and compare (backend-c.lisp).

(in-package #:skein.tests)

(def-suite skein.io :in all :description "skein.io: reading and writing files, running programs.")

(in-suite skein.io)

(defun sbcl-command ()
  "A Skein vector that starts this SBCL: [runtime \"--core\" core]. SBCL is the one
program the tests can count on finding on every OS."
  (format nil "[~S \"--core\" ~S]"
          (uiop:native-namestring sb-ext:*runtime-pathname*)
          (uiop:native-namestring sb-ext:*core-pathname*)))

(defun io-fixture-program (dir)
  "The skein.io fixture, calling its checks with the directory DIR (a pathname)."
  (format nil "~A~%(check ~S ~A)~%"
          (uiop:read-file-string
           (asdf:system-relative-pathname "skein" "tests/fixtures/native-io.skn"))
          (string-right-trim "/\\" (uiop:native-namestring dir))
          (sbcl-command)))

(defparameter *io-fixture-expected*
  (format nil "~{~A~%~}"
          (list "nil true \"héllo ☃\\nline 2\\r\\n\""
                "\"short\" \"\" true false"
                "true true true"
                "true true"
                "{:exit 3, :out \"out\", :err \"err\"}"
                "\"short\""
                "\"cannot run no-such-program-for-skein\""
                (concatenate 'string
                             "\"run-process needs a vector of strings, not []\" "
                             "\"run-process needs a vector of strings, not [\\\"x\\\" 1]\" "
                             "\"a path must be a string, not 5\" "
                             "\"write-file needs a string, not 5\"")))
  "What the fixture prints: written text reads back unchanged (UTF-8, CR LF), messages
name the file, and run-process returns the exit code and both outputs.")

(test io-fixture
  (with-source-tree (dir ("prog.skn" ""))
    (let ((file (merge-pathnames "prog.skn" dir)))
      (with-open-file (s file :direction :output :if-exists :supersede :external-format :utf-8)
        (write-string (io-fixture-program dir) s))
      (is (string= *io-fixture-expected*
                   (with-output-to-string (*standard-output*)
                     (skein.backend.cl:run-file file)))))))

(test io-errors-are-io-errors
  (evp-is "(ns io1 (:require [skein.io :as io]))
           (try (io/read-file \"no/such/file.txt\") (catch io/io-error e (io/io-error-path e)))"
          "\"no/such/file.txt\"")
  (evp-is "(ns io2 (:require [skein.io :as io]))
           (try (io/run-process [\"no-such-program-for-skein\"])
             (catch io/io-error e (condition-message e)))"
          "\"cannot run no-such-program-for-skein\"")
  (evp-is "(ns io3 (:require [skein.io :as io]))
           (try (io/read-file \"no/such/file.txt\") (catch error e (condition-message e)))"
          "\"file not found: no/such/file.txt\""))
