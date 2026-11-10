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
    ;; An error aborts the request (the debugger comes in step 2).
    (is (swank-has (swank-request s "(swank-repl:listener-eval \"(/ 1 0)\")" "\"serve\""
                                  ":repl-thread" 9)
                   "(:return (:abort \"division by zero\") 9)"))
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
                       ":severity :error :location (:location (:buffer \"*scratch*\") (:line 8 1)"
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
