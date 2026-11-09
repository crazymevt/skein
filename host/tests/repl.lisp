;;;; Tests for live development (DESIGN §15, M0.11): the REPL and its debugger, reload,
;;;; defonce, -main, frame restarts, the REPL server and `skein dev`.

(in-package #:skein.tests)

(def-suite skein.repl :in all
  :description "The REPL, debugger, reload, file watcher and REPL server.")

(in-suite skein.repl)

(defmacro with-saved-debugger-hook (&body body)
  "Run BODY, then restore the debugger hook that the REPL replaces."
  (let ((global (gensym)) (local (gensym)))
    `(let ((,global (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*))
           (,local sb-ext:*invoke-debugger-hook*))
       (unwind-protect (progn ,@body)
         (setf (sb-ext:symbol-global-value 'sb-ext:*invoke-debugger-hook*) ,global
               sb-ext:*invoke-debugger-hook* ,local)))))

(defun repl-session (input)
  "Run a REPL on the string INPUT and return what it printed. It runs in its own thread,
as at the terminal: there, FiveAM's error handlers do not take its errors."
  (with-saved-debugger-hook
    (sb-thread:join-thread
     (sb-thread:make-thread
      (lambda ()
        (with-output-to-string (out)
          (with-input-from-string (in input)
            (skein.repl:run-repl :in in :out out))))
      :name "test REPL"))))

(defun repl-has (transcript &rest pieces)
  "True if PIECES appear in TRANSCRIPT in this order."
  (let ((pos 0))
    (dolist (p pieces t)
      (let ((found (search p transcript :start2 pos)))
        (unless found (return nil))
        (setf pos (+ found (length p)))))))

(defmacro transcript-is (input &rest pieces)
  `(let ((got (repl-session ,input)))
     (is (repl-has got ,@pieces) "REPL transcript for ~S:~%~A~%should contain, in order: ~S"
         ,input got (list ,@pieces))))

;;; The REPL

(test repl-evaluates-and-prints
  (transcript-is "(+ 1 2)
(defn f [x] (* x 10))
(f 4)
(+ *1 1)
\"s\"
(println \"out\")
"
                 "user=> 3" "user=> #'user/f" "user=> 40" "user=> 41" "user=> \"s\""
                 "user=> out" "nil")
  ;; ns and in-ns change the prompt and where definitions go.
  (transcript-is "(ns repl.test.a)
(def x 1)
(in-ns 'user)
repl.test.a/x
"
                 "repl.test.a=> #'repl.test.a/x" "user=> 1")
  ;; :quit ends the session; nothing after it runs.
  (let ((got (repl-session ":quit
(println \"not reached\")
")))
    (is (not (search "not reached" got)))))

(test repl-recovers-from-read-errors
  (transcript-is "(+ 1 2))
(+ 2 3)
" "error: unexpected `)`" "user=> 5"))

(test repl-debugger
  ;; An error lists the restarts; a form can be evaluated; a number picks a restart.
  (transcript-is "(defn g [x] (/ x 0))
(defn h [x] (inc (g x)))
(h 5)
:bt
(+ 40 2)
0
(+ 1 1)
"
                 "error: " "0: abort  Return to the REPL" "debug[1] user=>"
                 "0: g" "1: h" "debug[1] user=> 42" "; aborted" "user=> 2")
  ;; Skein restarts come first, and choosing one returns its value.
  (transcript-is "(restart-case (error \"oops\") (use-default [] :report \"Use 7\" 7))
0
"
                 "error: oops" "0: use-default  Use 7" "1: abort" "user=> 7")
  ;; A nested error opens a second level; its abort returns to the first.
  (transcript-is "(error \"one\")
(error \"two\")
0
:quit
"
                 "error: one" "debug[1] user=>" "error: two"
                 "0: abort  Return to debug level 1" "debug[2] user=>" "; aborted"
                 "debug[1] user=>")
  ;; *e holds the last error.
  (transcript-is "(error \"remember me\")
0
(condition-message *e)
"
                 "\"remember me\"")
  ;; The input ending inside the debugger ends the session.
  (transcript-is "(error \"last\")
" "error: last" "debug[1] user=>"))

;;; reload, defonce and -main

(test reload-and-defonce
  (let ((lib (fresh-ns)))
    (with-source-tree (dir ((format nil "~A.skn" (substitute #\/ #\. lib))
                            (format nil "(ns ~A) (defonce state (atom 0)) (swap! state inc)
                                         (defn version [] 1)" lib)))
      (let ((user (fresh-ns))
            (file (merge-pathnames (format nil "~A.skn" (substitute #\/ #\. lib)) dir)))
        (is (string= "[1 1]" (pr (ev (format nil "(ns ~A (:require [~A :as l]))
                                                   [(l/version) @l/state]" user lib)))))
        (is (string= (uiop:native-namestring (truename file))
                     (skein.runtime:namespace-file (skein.runtime:find-namespace lib))))
        (with-open-file (s file :direction :output :if-exists :supersede)
          (format s "(ns ~A) (defonce state (atom 0)) (swap! state inc) (defn version [] 2)"
                  lib))
        ;; The function changes; the defonce'd atom survives (and was bumped again).
        (is (string= "[2 2 nil]"
                     (pr (ev (format nil "(ns ~A (:require [~A :as l]))
                                          (let [r (reload '~A)] [(l/version) @l/state r])"
                                     user lib lib)))))
        (fails (format nil "(reload 'no.such.namespace~A)" (random 100000))
               "cannot reload")
        (fails "(reload \"x\")" "reload needs a namespace name")))))

(test defonce-defines-once
  (is (string= "[1 true]"
               (pr (ev "(defonce a 1) (defonce a 2) [a (%var-bound? 'repl.defonce.test/a)]"
                       :namespace "repl.defonce.test")))))

(test run-file-calls-main
  (with-source-tree (dir ("prog.skn" "(ns repl.prog) (def loaded (atom :yes))
                                       (defn -main [& args] [@loaded (vec args)])")
                         ("plain.skn" "(ns repl.plain) (+ 1 2)"))
    (is (string= "[:yes [\"a\" \"b\"]]"
                 (pr (skein.backend.cl:run-file (merge-pathnames "prog.skn" dir)
                                                :args '("a" "b")))))
    (is (eql 3 (skein.backend.cl:run-file (merge-pathnames "plain.skn" dir))))
    ;; Without calling -main, the value is the file's last form's: the -main var.
    (is (skein.runtime:var-p (skein.backend.cl:run-file (merge-pathnames "prog.skn" dir)
                                                        :call-main nil)))))

(test parse-long
  (is (string= "[42 -7 3 nil nil nil]"
               (pr (ev "[(parse-long \"42\") (parse-long \"-7\") (parse-long \"+3\")
                         (parse-long \"4x\") (parse-long \"\") (parse-long \"-\")]"))))
  (fails "(parse-long 5)" "parse-long needs a string"))

;;; Frame restarts

(test frame-restarts
  (is (string= "[[1 2 4 5 6] 1]"
               (pr (ev "(ns repl.frames (:require [skein.game :as game]))
                        (let [n (atom 0) fails (atom 2) seen (atom [])]
                          (game/run-loop
                            {:running? (fn [] (< @n 6))
                             :frame (fn []
                                      (swap! n inc)
                                      (handler-bind [error (fn [c]
                                                             (if (pos? @fails)
                                                               (do (swap! fails dec)
                                                                   (invoke-restart 'retry-frame))
                                                               (invoke-restart 'skip-frame)))]
                                        (when (= @n 3) (error \"boom\"))
                                        (swap! seen conj @n)))})
                          [@seen @fails])"
                       :namespace "user"))))
  ;; skip-frame gives up on the frame; with-frame-restarts returns nil then.
  (is (string= "[nil :ok]"
               (pr (ev "(ns repl.frames2 (:require [skein.game :as game]))
                        [(handler-bind [error (fn [c] (invoke-restart 'skip-frame))]
                           (game/with-frame-restarts (error \"x\") :never))
                         (game/with-frame-restarts :ok)]"
                       :namespace "user"))))
  (fails "(ns repl.frames3 (:require [skein.game :as game])) (game/run-loop {})"
         "run-loop needs a :frame, :update or :render function"))

;;; The REPL server

(test repl-server
  (with-saved-debugger-hook
    (skein.repl::install-debugger)
    (let ((server (skein.repl:start-server 0)))
      (unwind-protect
           (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream
                                                                     :protocol :tcp)))
             (sb-bsd-sockets:socket-connect socket #(127 0 0 1) (skein.repl:server-port server))
             (let ((stream (sb-bsd-sockets:socket-make-stream
                            socket :input t :output t :element-type 'character
                                   :external-format :utf-8 :buffering :full)))
               (unwind-protect
                    (progn
                      (format stream "(+ 20 22)~%(/ 1 0)~%0~%(str \"a\" \"b\")~%:quit~%")
                      (finish-output stream)
                      ;; Read until the server closes the connection, but give up after
                      ;; 30 s rather than hang.
                      (let* ((buffer (make-string-output-stream))
                             (reader (sb-thread:make-thread
                                      (lambda ()
                                        (loop for line = (ignore-errors
                                                          (read-line stream nil nil))
                                              while line do (write-line line buffer)))
                                      :name "test socket reader"))
                             (done (sb-thread:join-thread reader :timeout 30
                                                                 :default :timeout))
                             (got (get-output-stream-string buffer)))
                        (is (not (eq done :timeout))
                            "the server did not close the connection after :quit")
                        (is (repl-has got "Skein" "user=> 42" "error: " "0: abort"
                                      "; aborted" "user=> \"ab\"")
                            "server transcript:~%~A" got)))
                 (close stream))))
        (skein.repl:stop-server server)))))

;;; skein dev, end to end: an error in the running program, fixed by editing the file,
;;; then retry-frame.

(defun launch-skein (args directory)
  (uiop:launch-program
   (append (list (or (uiop:getenv "SBCL") "sbcl") "--noinform" "--no-userinit"
                 "--non-interactive"
                 "--load" (namestring (asdf:system-relative-pathname
                                       "skein" "tools/launch.lisp"))
                 "--eval" "(skein.cli:toplevel)" "--end-toplevel-options")
           args)
   :input :stream :output :stream :error-output :output :directory directory))

(defun collect-output (stream buffer lock)
  "Copy lines from STREAM into BUFFER (an adjustable string) until it ends."
  (sb-thread:make-thread
   (lambda ()
     (loop for line = (ignore-errors (read-line stream nil nil))
           while line
           do (sb-thread:with-mutex (lock)
                (format buffer "~A~%" line))))
   :name "test output collector"))

(defun wait-for-output (buffer lock text &key (start 0) (timeout 60))
  "Wait until TEXT appears in BUFFER after START; return the position after it, or NIL."
  (loop repeat (* timeout 20)
        do (let ((pos (sb-thread:with-mutex (lock) (search text buffer :start2 start))))
             (when pos (return (+ pos (length text))))
             (sleep 0.05))))

(test dev-fix-and-retry-frame
  (with-source-tree (dir ("loop.skn" "(ns devloop (:require [skein.game :as game]))
(defonce frames (atom 0))
(defn value-for [n] (if (= n 3) (error \"bad frame\" n) (* n 10)))
(defn frame [] (let [n (swap! frames inc)] (println \"frame\" n (value-for n)) (sleep 0.05)))
(defn -main [& args]
  (println \"args\" args)
  (game/run-loop {:frame frame :running? (fn [] (< @frames 5))})
  (println \"finished\"))
"))
    (let* ((process (launch-skein (list "dev" "--no-server" "loop.skn" "x") dir))
           (buffer (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
           (lock (sb-thread:make-mutex))
           (input (uiop:process-info-input process)))
      (collect-output (uiop:process-info-output process) buffer lock)
      (unwind-protect
           (block scenario
            (flet ((wait (text &optional (start 0))
                    (or (wait-for-output buffer lock text :start start)
                        (progn (fail "timed out waiting for ~S in:~%~A" text buffer)
                               (return-from scenario))))
                  (say (line)
                    (format input "~A~%" line)
                    (finish-output input)))
             (let ((pos (wait "error in thread")))
               (is (search "args (x)" buffer))
               (is (search "frame 2 20" buffer))
               (wait "0: retry-frame" pos)
               ;; Fix the bug; the watcher reloads the file while the program waits.
               (sleep 1.1)        ; file dates have one-second resolution on some systems
               (let ((text (uiop:read-file-string (merge-pathnames "loop.skn" dir))))
                 (with-open-file (s (merge-pathnames "loop.skn" dir) :direction :output
                                                                     :if-exists :supersede)
                   (write-string (let ((bad "(if (= n 3) (error \"bad frame\" n) (* n 10))"))
                                   (concatenate 'string
                                                (subseq text 0 (search bad text))
                                                "(* n 100)"
                                                (subseq text (+ (search bad text)
                                                                (length bad)))))
                                 s)))
               (setf pos (wait "; reloaded loop.skn" pos))
               ;; Forms typed now run in the failing thread, in the program's namespace.
               (say "(value-for 3)")
               (setf pos (wait "300" pos))
               (say "0")
               ;; The program and the REPL print concurrently, in either order.
               (wait "; resumed" pos)
               (setf pos (wait "frame 4 400" pos))
               (wait "finished" pos)
               (say ":quit")
               (loop repeat 600 while (uiop:process-alive-p process) do (sleep 0.05))
               (is (not (uiop:process-alive-p process)) "skein dev did not exit after :quit")
               (unless (uiop:process-alive-p process)
                 (is (eql 0 (uiop:wait-process process)))))))
        (when (uiop:process-alive-p process)
          (uiop:terminate-process process :urgent t))))))
