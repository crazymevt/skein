;;;; Tests of native skein dev's Swank server (M2.7, D-082): a client that speaks the
;;;; protocol as SLIME does, to a program built with skeinc --eval.

(in-package #:skein.tests)

(def-suite skein.swank :in all
  :description "The Swank server of native skein dev, over its protocol.")

(in-suite skein.swank)

(defun swank-send (stream text)
  "Send TEXT as a Swank message: its length in UTF-8 bytes, six hex digits, then it."
  (let ((octets (sb-ext:string-to-octets text :external-format :utf-8)))
    (write-sequence (sb-ext:string-to-octets (format nil "~6,'0X" (length octets))) stream)
    (write-sequence octets stream)
    (finish-output stream)))

(defun swank-receive (stream)
  "The next Swank message from STREAM, as text, or NIL at its end."
  (let ((header (make-array 6 :element-type '(unsigned-byte 8))))
    (when (= 6 (read-sequence header stream))
      (let* ((n (parse-integer (sb-ext:octets-to-string header) :radix 16))
             (payload (make-array n :element-type '(unsigned-byte 8))))
        (when (= n (read-sequence payload stream))
          (sb-ext:octets-to-string payload :external-format :utf-8))))))

(defun swank-request (stream form package thread id)
  "Send (:emacs-rex FORM PACKAGE THREAD ID), FORM and the rest written as Emacs writes
them, and return the messages up to its (:return ...), in order."
  (swank-send stream (format nil "(:emacs-rex ~A ~A ~A ~D)" form package thread id))
  (loop for message = (swank-receive stream)
        while message
        collect message
        until (eql 0 (search "(:return" message))))

(defun swank-until (stream prefix)
  "The messages from STREAM up to the first that starts with PREFIX, in order."
  (loop for message = (swank-receive stream)
        while message
        collect message
        until (eql 0 (search prefix message))))

(defun swank-has (messages &rest texts)
  "True if each of TEXTS is in one of MESSAGES."
  (every (lambda (text) (some (lambda (m) (search text m)) messages)) texts))

(defmacro with-swank-program ((stream dir files) &body body)
  "Build the program in FILES (the first is the program) with skeinc --eval, run it with
SKEIN_DEV=none and Swank on a free port, and run BODY with STREAM connected to it."
  (let ((exe (gensym)) (process (gensym)) (line (gensym)) (port (gensym))
        (socket (gensym)))
    `(if (not (zig-available-p))
         (skip "zig is not installed")
         (with-source-tree (,dir ,@files)
           (let* ((,exe (native-dev-build ,dir ,(car (first files))))
                  (,process (sb-ext:run-program ,exe '() :wait nil :input :stream
                                                         :output :stream :error :output
                                                         :directory (uiop:native-namestring ,dir)
                                                         :environment
                                                         (list* "SKEIN_DEV=none" "SKEIN_SWANK=0"
                                                                (sb-ext:posix-environ)))))
             (unwind-protect
                  (let* ((,line (read-line (sb-ext:process-output ,process)))
                         (,port (parse-integer ,line
                                               :start (+ (search "Swank on localhost:" ,line) 19)
                                               :junk-allowed t))
                         (,socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream
                                                                             :protocol :tcp)))
                    (sb-bsd-sockets:socket-connect ,socket #(127 0 0 1) ,port)
                    (let ((,stream (sb-bsd-sockets:socket-make-stream
                                    ,socket :input t :output t
                                            :element-type '(unsigned-byte 8)
                                            :buffering :full :timeout 60)))
                      (unwind-protect (progn ,@body)
                        (close ,stream))))
               (when (sb-ext:process-alive-p ,process)
                 (sb-ext:process-kill ,process 9))
               ;; Windows keeps the executable locked until the process has gone.
               (sb-ext:process-wait ,process)))))))

(test swank-connection-and-listener
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defn greet [n] (str \"hi \" n))
(defn -main [& args] (sleep 60))
")))
    (let ((info (swank-request s "(swank:connection-info)" "nil" "t" 1)))
      (is (swank-has info "(:return (:ok (:pid " ":style :spawn"
                     ":lisp-implementation (:type \"Skein\" :name \"skein\""
                     ":package (:name \"serve\" :prompt \"serve\")" ") 1)")
          "~S" info))
    (is (swank-has (swank-request s "(swank:swank-require '(:swank-repl :swank-arglists))"
                                  "\"COMMON-LISP-USER\"" "t" 2)
                   "(:return (:ok (\"SWANK-REPL\" \"SWANK-ARGLISTS\")) 2)"))
    (is (swank-has (swank-request s "(swank-repl:create-repl nil :coding-system \"utf-8-unix\")"
                                  "nil" "t" 3)
                   "(:return (:ok (\"serve\" \"serve\")) 3)"))
    ;; The listener: a value, what the code prints (as UTF-8, counted in bytes), and the
    ;; namespace following in-ns.
    (let ((m (swank-request s "(swank-repl:listener-eval \"(+ 20 22)\")" "\"serve\""
                            ":repl-thread" 4)))
      (is (equal '("(:write-string \"42\\n\" :repl-result)" "(:return (:ok nil) 4)") m) "~S" m))
    (let ((m (swank-request s (concatenate 'string "(swank-repl:listener-eval "
                                           "\"(println \\\"café\\\") (greet \\\"you\\\")\")")
                            "\"serve\"" ":repl-thread" 5)))
      (is (equal '("(:write-string \"café\\n\")"
                   "(:write-string \"\\\"hi you\\\"\\n\" :repl-result)"
                   "(:return (:ok nil) 5)")
                 m)
          "~S" m))
    (let ((m (swank-request s "(swank-repl:listener-eval \"(in-ns 'other)\")" "\"serve\""
                            ":repl-thread" 6)))
      (is (swank-has m "(:new-package \"other\" \"other\")" "(:return (:ok nil) 6)") "~S" m))
    (is (swank-has (swank-request s "(swank:set-package \"serve\")" "nil" "t" 7)
                   "(:return (:ok (\"serve\" \"serve\")) 7)"))
    ;; *1 is the listener's last value.
    (is (swank-has (swank-request s "(swank-repl:listener-eval \"*1\")" "\"serve\""
                                  ":repl-thread" 8)
                   "(:write-string \"#<namespace other>\\n\" :repl-result)"))
    ;; An error opens the debugger; its abort aborts the request.
    (swank-send s "(:emacs-rex (swank-repl:listener-eval \"(/ 1 0)\") \"serve\" :repl-thread 9)")
    (is (swank-has (swank-until s "(:debug-activate") "(:debug 1 1 (\"division by zero\""))
    (swank-send s "(:emacs-rex (swank:sldb-abort) \"serve\" 1 90)")
    (is (swank-has (swank-until s "(:return (:abort \"division by zero\") 9)")
                   "(:debug-return 1 1 nil)"))
    (is (swank-has (swank-request s "(swank:no-such-request 1)" "nil" "t" 10)
                   "(:return (:abort \"Skein's Swank server has no swank:no-such-request\") 10)"))))

(test swank-evaluating-and-compiling
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defn -main [& args] (sleep 60))
")
                              ("lib.skn" "(ns lib)
(defn f [] (println \"in f\") :lib-f)
")))
    (let ((lib (uiop:native-namestring (merge-pathnames "lib.skn" dir))))
      ;; Strings with escapes both ways; the buffer's namespace.
      (is (swank-has (swank-request s "(swank:interactive-eval \"(str \\\"q\\\\\\\"b\\\" 1)\")"
                                    "\"serve\"" "t" 1)
                     "(:return (:ok \"=> \\\"q\\\\\\\"b1\\\"\") 1)"))
      (is (swank-has (swank-request s "(swank:interactive-eval-region \"(def x 2) (* x 21)\")"
                                    "\"serve\"" "t" 2)
                     "(:return (:ok \"=> 42\") 2)"))
      (is (swank-has (swank-request s "(swank:interactive-eval \"\")" "\"serve\"" "t" 3)
                     "(:return (:ok \"; No value\") 3)"))
      (is (swank-has (swank-request s "(swank:eval-and-grab-output \"(do (print \\\"out\\\") 5)\")"
                                    "\"serve\"" "t" 4)
                     "(:return (:ok (\"out\" \"5\")) 4)"))
      ;; C-c C-c: a region compiled where it is in its file; errors are notes there.
      (is (swank-has (swank-request
                      s (format nil "(swank:compile-string-for-emacs \"(defn twice [n] (* 2 n))\" ~
                                     \"serve.skn\" '((:position 30) (:line 3 1)) ~S 'nil)"
                                (uiop:native-namestring (merge-pathnames "serve.skn" dir)))
                      "\"serve\"" "t" 5)
                     "(:return (:ok (:compilation-result nil t "))
      (is (swank-has (swank-request s "(swank:interactive-eval \"(twice 21)\")" "\"serve\"" "t" 6)
                     "(:return (:ok \"=> 42\") 6)"))
      (let ((m (swank-request s "(swank:compile-string-for-emacs \"
(let [y] y)\" \"*scratch*\" '((:position 1) (:line 7 1)) nil 'nil)" "\"serve\"" "t" 7)))
        (is (swank-has m "(:return (:ok (:compilation-result ((:message \"a binding vector"
                       ":severity :error :location (:location (:buffer \"*scratch*\") (:line 8 0)"
                       ") nil 0.0 nil nil)) 7)")
            "~S" m))
      ;; C-c C-k: the file loaded, with what it prints going to Emacs.
      (let ((m (swank-request s (format nil "(swank:compile-file-for-emacs ~S t)" lib)
                              "\"serve\"" "t" 8)))
        (is (swank-has m "(:return (:ok (:compilation-result nil t ") "~S" m)
        (is (swank-has (swank-request s "(swank:interactive-eval \"(f)\")" "\"lib\"" "t" 9)
                       "(:write-string \"in f\\n\")" "(:return (:ok \"=> :lib-f\") 9)")))
      (is (swank-has (swank-request s (format nil "(swank:load-file ~S)" lib) "\"serve\"" "t" 10)
                     "(:return (:ok t) 10)"))
      (is (swank-has (swank-request s "(swank:list-all-package-names t)" "nil" "t" 11)
                     "\"lib\"" "\"serve\"" "\"user\"")))))

(test swank-requests-run-at-the-same-time
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defn -main [& args] (sleep 60))
")))
    ;; A buffer's in-ns while the listener is evaluating doesn't change the listener's
    ;; namespace (D-083), and the other request answers first.
    (swank-send s (concatenate 'string "(:emacs-rex (swank-repl:listener-eval "
                               "\"(sleep 0.5) (def here 1)\") \"serve\" :repl-thread 1)"))
    (swank-send s "(:emacs-rex (swank:interactive-eval \"(in-ns 'other)\") \"user\" t 2)")
    (let ((m (loop repeat 3 collect (swank-receive s))))
      (is (equal '("(:return (:ok \"=> #<namespace other>\") 2)"
                   "(:write-string \"#'serve/here\\n\" :repl-result)"
                   "(:return (:ok nil) 1)")
                 m)
          "~S" m))))

;;; The debugger (SLDB, M2.7 step 2)

(test swank-debugger-for-requests
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defn greet [n] (str \"hi \" n))
(defn inner [x] (/ x 0))
(defn outer [x] (inner x))
(defn safe [x] (restart-case (outer x) (use-ten [] :report \"Use ten\" 10)))
(defn -main [& args] (sleep 60))
")))
    ;; An error in the listener: SLDB in its thread (1), with Skein's restarts and the
    ;; functions between the error and the REPL.
    (swank-send s "(:emacs-rex (swank-repl:listener-eval \"(safe 1)\") \"serve\" :repl-thread 1)")
    (let ((m (swank-until s "(:debug-activate")))
      (is (equal (list (concatenate 'string "(:debug 1 1 (\"division by zero\" "
                                    "\"   [Condition of type arithmetic-error]\" nil) "
                                    "((\"use-ten\" \"Use ten\") "
                                    "(\"abort\" \"Return to SLIME's top level.\")) "
                                    "((0 \"inner\") (1 \"outer\") (2 \"safe\")) (1))")
                       "(:debug-activate 1 1 nil)")
                 m)
          "~S" m))
    (is (swank-has (swank-request s "(swank:backtrace 1 3)" "\"serve\"" "1" 2)
                   "(:return (:ok ((1 \"outer\") (2 \"safe\"))) 2)"))
    (is (swank-has (swank-request s "(swank:frame-source-location 0)" "\"serve\"" "1" 3)
                   ;; An absolute path, which Emacs needs.
                   "(:return (:ok (:location (:file \"" "serve.skn\") (:line 3 0) nil)) 3)"))
    ;; Evaluating in the debugger's thread; a compile error is only an answer; a runtime
    ;; error opens level 2, whose abort returns to level 1.
    (is (swank-has (swank-request s "(swank:eval-string-in-frame \"(greet 3)\" 0 \"serve\")"
                                  "\"serve\"" "1" 4)
                   "(:return (:ok \"=> \\\"hi 3\\\"\") 4)"))
    (is (swank-has (swank-request s "(swank:eval-string-in-frame \"(car 1)\" 0 \"serve\")"
                                  "\"serve\"" "1" 5)
                   "(:return (:abort \"unable to resolve symbol `car`"))
    (swank-send s (concatenate 'string "(:emacs-rex (swank:eval-string-in-frame \"(outer 2)\" 0 "
                               "\"serve\") \"serve\" 1 6)"))
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 1 2 (\"division by zero\""
                     "((\"abort\" \"Return to sldb level 1.\") (\"use-ten\" \"Use ten\")"
                     " (1 6))")
          "~S" m))
    (swank-send s "(:emacs-rex (swank:sldb-abort) \"serve\" 1 7)")
    (let ((m (swank-until s "(:return (:abort \"division by zero\") 6)")))
      (is (swank-has m "(:debug-return 1 2 nil)") "~S" m))
    ;; Restart 0 of level 1: safe returns 10, and the listener prints it.
    (swank-send s "(:emacs-rex (swank:invoke-nth-restart-for-emacs 1 0) \"serve\" 1 8)")
    (let ((m (swank-until s "(:return (:ok nil) 1)")))
      (is (swank-has m "(:debug-return 1 1 nil)" "(:write-string \"10\\n\" :repl-result)")
          "~S" m))
    ;; An error in another request: a thread of its own; q aborts the request.
    (swank-send s "(:emacs-rex (swank:interactive-eval \"(outer 3)\") \"serve\" t 9)")
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 2 1 (\"division by zero\"" "(9))") "~S" m))
    (swank-send s "(:emacs-rex (swank:throw-to-toplevel) \"serve\" 2 10)")
    (let ((m (swank-until s "(:return (:abort \"division by zero\") 9)")))
      (is (swank-has m "(:debug-return 2 1 nil)") "~S" m))))

(test swank-debugger-for-the-program
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defonce go? (atom false))
(defn inner [x] (/ x 0))
(defn -main [& args]
  (loop [] (when-not @go? (sleep 0.02) (recur)))
  (println \"got\" (restart-case (inner 1) (use-ten [] :report \"Use ten\" 10)))
  (reset! go? :done)
  (sleep 60))
")))
    ;; An error in the program that no handler handles opens SLDB in Emacs, in the
    ;; program's fiber, which a restart resumes.
    (is (swank-has (swank-request s "(swank:interactive-eval \"(reset! go? true)\")" "\"serve\""
                                  "t" 1)
                   "(:return (:ok \"=> true\") 1)"))
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 2 1 (\"division by zero\""
                     "((\"use-ten\" \"Use ten\") (\"abort\" \"Stop the program\"))"
                     "((0 \"inner\") (1 \"-main\")) nil)")
          "~S" m))
    (swank-send s "(:emacs-rex (swank:invoke-nth-restart-for-emacs 1 0) \"serve\" 2 2)")
    (is (swank-has (swank-until s "(:debug-return") "(:debug-return 2 1 nil)"))
    (loop repeat 100
          until (search ":done" (car (swank-request s "(swank:interactive-eval \"@go?\")"
                                                    "\"serve\"" "t" 3)))
          do (sleep 0.05))
    (is (swank-has (swank-request s "(swank:interactive-eval \"@go?\")" "\"serve\"" "t" 4)
                   "(:return (:ok \"=> :done\") 4)"))))

;;; Completion, argument lists, documentation and the inspector (M2.7 step 3)

(test swank-names
  (with-swank-program (s dir (("serve.skn" "(ns serve (:require [skein.io :as io]))
(defn greet
  \"Say hi to n.\"
  [n] (str \"hi \" n))
(defn sum ([a] a) ([a b & more] (apply + a b more)))
(defmacro twice [x] `(do ~x ~x))
(defn -main [& args] (sleep 60))
")))
    (flet ((ask (form id)
             (swank-request s form "\"serve\"" "t" id)))
      ;; Completion: the namespace's own names, skein.core's, and alias/name.
      (is (swank-has (ask "(swank:simple-completions \"gre\" \"serve\")" 1)
                     "(:return (:ok ((\"greet\") \"greet\")) 1)"))
      (is (swank-has (ask "(swank:completions \"io/read-f\" \"serve\")" 2)
                     "(:return (:ok ((\"io/read-file\") \"io/read-file\")) 2)"))
      (is (swank-has (ask "(swank:simple-completions \"mapc\" \"serve\")" 3)
                     "(:return (:ok ((\"mapcat\") \"mapcat\")) 3)"))
      ;; Argument lists, with the argument at the cursor marked, from compiled code: a
      ;; function, a rest parameter, a macro (without &form and &env) and skein.core.
      (is (swank-has (ask (concatenate 'string "(swank:autodoc '(\"greet\" \"\" "
                                       "swank::%cursor-marker%) :print-right-margin 80)")
                          4)
                     "(:return (:ok (\"(greet ===> n <===)\" t)) 4)"))
      (is (swank-has (ask "(swank:autodoc '(\"sum\" \"1\" \"2\" \"\" swank::%cursor-marker%))" 5)
                     "(:return (:ok (\"(sum a b & ===> more <===)\" t)) 5)"))
      (is (swank-has (ask "(swank:autodoc '(\"twice\" \"\" swank::%cursor-marker%))" 6)
                     "(:return (:ok (\"(twice ===> x <===)\" t)) 6)"))
      (is (swank-has (ask "(swank:autodoc '(\"map\" \"inc\" \"\" swank::%cursor-marker%))" 7)
                     "(:return (:ok (\"(map f & ===> colls <===)\" t)) 7)"))
      (is (swank-has (ask "(swank:autodoc '(\"no-such\" swank::%cursor-marker%))" 8)
                     "(:return (:ok (:not-available t)) 8)"))
      ;; Documentation, apropos and M-. (an absolute path, which Emacs needs).
      (is (swank-has (ask "(swank:describe-symbol \"greet\")" 9)
                     "serve/greet\\n([n])\\n\\nSay hi to n.\\n\\nDefined at "))
      (is (swank-has (ask "(swank:describe-symbol \"io/read-file\")" 10)
                     "skein.io/read-file\\n([path])\\n"))
      (is (swank-has (ask "(swank:apropos-list-for-emacs \"gree\" t nil nil)" 11)
                     "((:designator \"serve/greet\" :function \"Say hi to n.\"))"))
      (let* ((m (ask "(swank:find-definitions-for-emacs \"greet\")" 12))
             (reply (ignore-errors (read-from-string (car (last m)))))
             (location (second (first (second (second reply))))))
        (is (swank-has m "((\"(def serve/greet)\" (:location (:file \"" "(:line 2 0) nil)))")
            "~S" m)
        ;; The file's absolute path, which Emacs needs.
        (is (equal (truename (merge-pathnames "serve.skn" dir))
                   (ignore-errors (truename (second (second location)))))
            "~S" location)))))

(test swank-inspector
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defclass point [] (x :init 1) (y :init 2))
(defn -main [& args] (sleep 60))
")))
    (flet ((ask (form id)
             (swank-request s form "\"serve\"" "t" id)))
      (is (swank-has (ask "(swank:init-inspector \"{:a [1 2]}\")" 1)
                     (concatenate 'string "(:return (:ok (:title \"{:a [1 2]}\" :id 0 :content "
                                  "((\"Class: \" (:value \"#<class hash-map>\" 0) \"\\n\" "
                                  "\"Count: 1\\n\\n\" (:value \":a\" 1) \" = \" "
                                  "(:value \"[1 2]\" 2) \"\\n\") 8 0 8))) 1)")))
      ;; Into a part, back and forward again.
      (is (swank-has (ask "(swank:inspect-nth-part 2)" 2)
                     ":title \"[1 2]\" :id 1" "\"0: \" (:value \"1\" 1)"))
      (is (swank-has (ask "(swank:inspector-pop)" 3) ":title \"{:a [1 2]}\" :id 0"))
      (is (swank-has (ask "(swank:inspector-next)" 4) ":title \"[1 2]\" :id 1"))
      (is (swank-has (ask "(swank:inspect-nth-part 9)" 5) "(:return (:abort \"no part 9\") 5)"))
      (is (swank-has (ask "(swank:inspector-range 0 2)" 6)
                     "(:return (:ok ((\"Class: \" (:value \"#<class vector>\" 0)) 10 0 2)) 6)"))
      ;; An object's slots; a lazy seq shows its first items.
      (is (swank-has (ask "(swank:init-inspector \"(make point)\")" 7)
                     "\"x: \" (:value \"1\" 1)" "\"y: \" (:value \"2\" 2)"))
      (is (swank-has (ask "(swank:init-inspector \"(range)\")" 8)
                     ":title \"#<lazy seq>\"" "(only the first 1000 are shown)"))
      (is (swank-has (ask "(swank:quit-inspector)" 9) "(:return (:ok nil) 9)")))))

;;; Supervisors (M2.8 step 1, D-088): a task's unhandled error opens SLDB in its fiber.

(test swank-debugger-for-tasks
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defonce go? (atom false))
(defonce result (atom nil))
(defn inner [x] (/ x 0))
(defn -main [& args]
  (loop [] (when-not @go? (sleep 0.02) (recur)))
  (with-nursery [n]
    (reset! result @(spawn n (restart-case (inner 1) (use-ten [] :report \"Use ten\" 10)))))
  (sleep 60))
")))
    ;; A task of the program: SLDB in its thread, with its restarts and "Fail the task".
    (is (swank-has (swank-request s "(swank:interactive-eval \"(reset! go? true)\")" "\"serve\""
                                  "t" 1)
                   "(:return (:ok \"=> true\") 1)"))
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 2 1 (\"division by zero\""
                     "((\"use-ten\" \"Use ten\") (\"abort\" \"Fail the task\"))"
                     "((0 \"inner\") (1 \"fn\"))")
          "~S" m))
    (swank-send s "(:emacs-rex (swank:invoke-nth-restart-for-emacs 1 0) \"serve\" 2 2)")
    (is (swank-has (swank-until s "(:debug-return") "(:debug-return 2 1 nil)"))
    (loop repeat 100
          until (search "10" (car (last (swank-request s "(swank:interactive-eval \"@result\")"
                                                       "\"serve\"" "t" 3))))
          do (sleep 0.05))
    (is (swank-has (swank-request s "(swank:interactive-eval \"@result\")" "\"serve\"" "t" 4)
                   "(:return (:ok \"=> 10\") 4)"))
    ;; A future that a request waits for: failing it re-signals in the request, whose own
    ;; SLDB has no "Fail the task" (Swank's fibers aren't the program's tasks).
    (swank-send s "(:emacs-rex (swank:interactive-eval \"@(future (inner 2))\") \"serve\" t 5)")
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 3 1 (\"division by zero\"" "((\"abort\" \"Fail the task\"))")
          "~S" m))
    (swank-send s "(:emacs-rex (swank:invoke-nth-restart-for-emacs 1 0) \"serve\" 3 6)")
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug-return 3 1 nil)" "(:debug 4 1 (\"division by zero\""
                     "((\"abort\" \"Return to SLIME's top level.\")) ")
          "~S" m))
    (swank-send s "(:emacs-rex (swank:sldb-abort) \"serve\" 4 7)")
    (is (swank-has (swank-until s "(:return (:abort \"division by zero\") 5)")
                   "(:debug-return 4 1 nil)"))))

(test swank-policy-after-the-debugger
  ;; In skein dev the debugger comes first; failing the task applies its nursery's policy
  ;; (M2.8 step 2, D-088): under :ignore the program goes on.
  (with-swank-program (s dir (("serve.skn" "(ns serve)
(defonce go? (atom false))
(defonce result (atom nil))
(defn -main [& args]
  (loop [] (when-not @go? (sleep 0.02) (recur)))
  (with-nursery [n {:on-error :ignore}]
    (spawn n (error \"ignored\"))
    (reset! result @(spawn n :fine)))
  (sleep 60))
")))
    (is (swank-has (swank-request s "(swank:interactive-eval \"(reset! go? true)\")" "\"serve\""
                                  "t" 1)
                   "(:return (:ok \"=> true\") 1)"))
    (let ((m (swank-until s "(:debug-activate")))
      (is (swank-has m "(:debug 2 1 (\"ignored\"" "((\"abort\" \"Fail the task\"))") "~S" m))
    (swank-send s "(:emacs-rex (swank:invoke-nth-restart-for-emacs 1 0) \"serve\" 2 2)")
    (is (swank-has (swank-until s "(:debug-return") "(:debug-return 2 1 nil)"))
    (loop repeat 100
          until (search ":fine" (car (last (swank-request s "(swank:interactive-eval \"@result\")"
                                                          "\"serve\"" "t" 3))))
          do (sleep 0.05))
    (is (swank-has (swank-request s "(swank:interactive-eval \"@result\")" "\"serve\"" "t" 4)
                   "(:return (:ok \"=> :fine\") 4)"))))
