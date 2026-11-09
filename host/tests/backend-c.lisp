;;;; Tests for the C backend (M1.2): programs built natively must print what `skein run`
;;;; prints. They need Zig 0.17.1 and are skipped without it.

(in-package #:skein.tests)

(def-suite skein.backend.c :in all
  :description "Compiling Skein to C and running it natively, checked against Phase 0.")

(in-suite skein.backend.c)

(defun zig-available-p ()
  (ignore-errors
   (zerop (nth-value 2 (uiop:run-program (list (or (uiop:getenv "SKEIN_ZIG") "zig") "version")
                                         :ignore-error-status t)))))

(defun phase0-output (file)
  "What `skein run` prints for FILE."
  (with-output-to-string (*standard-output*)
    (skein.backend.cl:run-file file)))

(defun native-run (file)
  "Build FILE natively and run it. Returns stdout, stderr and the exit code."
  (let ((exe (skein.backend.c:build-program
              file :output (uiop:native-namestring
                            (make-pathname :name (format nil "~A-native" (pathname-name file))
                                           :type (and (string= (skein.platform:os-name) "windows")
                                                      "exe")
                                           :defaults file)))))
    (uiop:run-program (list (uiop:native-namestring exe)) :output :string :error-output :string
                                                          :ignore-error-status t)))

(defmacro with-program ((file source) &body body)
  "Write SOURCE to FILE (a .skn in a fresh temporary directory) for BODY."
  (let ((dir (gensym)))
    `(with-source-tree (,dir ("prog.skn" ,source))
       (let ((,file (merge-pathnames "prog.skn" ,dir)))
         ,@body))))

(defmacro native-matches (source)
  "SOURCE, built natively, prints exactly what skein run prints."
  `(if (not (zig-available-p))
       (skip "zig is not installed")
       (with-program (file ,source)
         (let ((expected (phase0-output file)))
           (multiple-value-bind (out err code) (native-run file)
             (is (eql 0 code) "native exit code ~A, stderr: ~A" code err)
             (is (string= expected out) "native output differs:~%--- skein run:~%~A--- native:~%~A"
                 expected out))))))

(defmacro native-fails (source &rest messages)
  "SOURCE builds, but running it natively exits with status 1 and prints MESSAGES."
  `(if (not (zig-available-p))
       (skip "zig is not installed")
       (with-program (file ,source)
         (multiple-value-bind (out err code) (native-run file)
           (declare (ignore out))
           (is (eql 1 code) "expected exit code 1, got ~A" code)
           (dolist (m (list ,@messages))
             (is (search m err) "stderr ~S does not contain ~S" err m))))))

(defmacro build-fails (source message)
  "Building SOURCE natively signals a C-BACKEND-ERROR with MESSAGE."
  `(with-program (file ,source)
     (let ((e (handler-case (progn (skein.backend.c:translate-file file) nil)
                (skein.backend.c:c-backend-error (e) e))))
       (is (not (null e)) "building should fail with ~S" ,message)
       (when e
         (is (search ,message (skein.runtime:skein-error-message e))
             "message ~S does not contain ~S" (skein.runtime:skein-error-message e) ,message)
         (is (not (null (skein.runtime:skein-error-location e))) "the error has no location")))))

;;; The exit criterion: the examples

(test native-examples
  (if (not (zig-available-p))
      (skip "zig is not installed")
      (dolist (name '("hello" "fib"))
        (let ((file (asdf:system-relative-pathname "skein" (format nil "../examples/~A.skn" name))))
          (with-source-tree (dir ("unused.skn" ""))
            (let ((exe (skein.backend.c:build-program
                        file :output (uiop:native-namestring
                                      (merge-pathnames (format nil "~A-native~:[~;.exe~]" name
                                                               (string= (skein.platform:os-name)
                                                                        "windows"))
                                                       dir)))))
              (is (string= (uiop:read-file-string
                            (asdf:system-relative-pathname
                             "skein" (format nil "../examples/~A.expected" name)))
                           (uiop:run-program (list (uiop:native-namestring exe))
                                             :output :string))
                  "native ~A differs from ~A.expected" name name)))))))

;;; Numbers and printing

(test native-numbers
  (native-matches "(ns nums)
(prn (+) (+ 1) (+ 1 2 3) (- 5) (- 10 3 2) (*) (* 2 3 4) (/ 6 3) (/ 1 3))
(prn (+ 1 1.5f) (+ 1.5f 2.0) (* 2 2.5) (- 0.0) (- 1.5f) (/ 1.0 4) (+ 0.1 0.2))
(prn (+ 2305843009213693951 1) (- -2305843009213693952 1) (inc 2305843009213693951))
(prn (* 4611686018427387903 4611686018427387903) (- (* 99999999999 99999999999 99999999999)))
(prn (- (+ 2305843009213693951 10) 10) 12345678901234567890123 -98765432109876543210)
(prn (< 1 2) (< 2 1) (< 1 2 3) (< 1 3 2) (> 3 2 1) (<= 1 1 2) (>= 2 2 3) (< 1 2.5) (== 1 1.0))
(prn (= 1 1) (= 1 1.0) (= 1.0 1.0f) (= \"a\" \"a\") (= \"a\" \"b\") (= 2 2 2) (not= 1 2) (= nil nil))
(prn (inc 41) (dec 0) (zero? 0) (zero? 0.0) (pos? 3) (neg? -1.5) (not nil) (not 0) (nil? nil))
(prn 1.5 0.1 1e21 1e-7 100.0 1e7 1234567.0 2.0e-5 0.001 9.9e-4 1e100 0.5f 3.4e38 ##NaN ##-Inf)
(prn (< 1 ##NaN) (= ##NaN ##NaN) (identical? nil nil))
(println \"display:\" \"a\\\"b\" \\c nil true false 42)
(prn \"readable:\" \"a\\\"b\\n\" \\c \\newline \\space \"héllo ☃\")
(print \"no newline\") (pr 1 2) (println)
(println)"))

;;; Control flow and functions

(test native-control-flow
  (native-matches "(ns flow)
(defn classify [n] (if (neg? n) \"never\" (if (zero? n) \"zero\" \"positive\")))
(defn sum-to [n] (loop [i 0 acc 0] (if (> i n) acc (recur (inc i) (+ acc i)))))
(defn fact [n] (if (zero? n) 1 (* n (fact (dec n)))))
(defn countdown [n] (if (pos? n) (recur (dec n)) \"never\"))
(defn nested [n]
  (loop [i 0 total 0]
    (if (< i n)
      (recur (inc i) (+ total (loop [j 0 s 0] (if (< j i) (recur (inc j) (+ s j)) s))))
      total)))
(defn inner-empty-loop [n]
  (loop [i 0 hits 0]
    (if (< i n)
      (do (loop [] (if (= hits 99) (recur) nil))
          (recur (inc i) (+ hits 2)))
      hits)))
(defn str-free [a] (* a 10))
(defn arities ([] \"none\") ([a] (str-free a)) ([a b] (+ a b)))
(defn self-ref [n] (if (< n 1) 0 (+ n (self-ref (- n 1)))))
(println (classify 0) (classify 5) (sum-to 100) (fact 25) (nested 10) (inner-empty-loop 5))
(println (arities) (arities 4) (arities 1 2) (self-ref 100))
(println (let [a 1 b (+ a 1)] (let [a (* b 10)] (+ a b))))
(println (if nil 1) (if false 1 2) (do 1 2 3) (if 0 \"zero is true\" \"no\"))
(def x 10)
(def y (+ x 5))
(def later)
(defn uses-later [] (* later 2))
(def later 21)
(println x y (uses-later))
(def x 100)
(println x)
(println (fn [a] a) classify)
(defn -main [& args] (println \"main ran with\" args))"))

;;; Garbage collection (M1.3): programs that allocate far more than they keep

(defun native-run-with-stats (file)
  "Build FILE natively and run it with SKEIN_GC_STATS=1. Returns stdout and stderr."
  (let ((exe (skein.backend.c:build-program
              file :output (uiop:native-namestring
                            (make-pathname :name "gc-native"
                                           :type (and (string= (skein.platform:os-name) "windows")
                                                      "exe")
                                           :defaults file))))
        (out (make-string-output-stream))
        (err (make-string-output-stream)))
    (sb-ext:run-program (uiop:native-namestring exe) '()
                        :output out :error err
                        :environment (cons "SKEIN_GC_STATS=1" (sb-ext:posix-environ)))
    (values (get-output-stream-string out) (get-output-stream-string err))))

(test native-garbage-collection
  (if (not (zig-available-p))
      (skip "zig is not installed")
      (with-program (file "(ns gcheavy)
(def greeting \"kept across collections\")
(def big 123456789012345678901234567890)
(defn churn [n]
  ;; Each iteration makes a bignum and drops it: about 96 MB in all.
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (- (+ acc 100000000000000000000) 99999999999999999999))
      acc)))
(defn twice [x] (* 2 x))
(println (churn 3000000) greeting (twice big))
(println (churn 1000) greeting big)")
        (let ((expected (phase0-output file)))
          (multiple-value-bind (out err) (native-run-with-stats file)
            (is (string= expected out) "native output differs:~%~A~%vs~%~A" out expected)
            (let* ((at (search "gc: " err))
                   (minor (and at (parse-integer err :start (+ at 4) :junk-allowed t))))
              (is (and minor (>= minor 5)) "expected several minor collections: ~A" err)))))))

;;; Runtime errors: a message on stderr and exit status 1

(test native-runtime-errors
  (native-fails "(ns e1) (def g) (defn f [] (g)) (f)" "error: e1/g is unbound at "
                "prog.skn:1:29")
  (native-fails "(ns e2) (defn f [a] a) (println \"before\") (f 1 2)"
                "error: wrong number of arguments (2) passed to f (defined at ")
  (native-fails "(ns e3) (def notfn 5) (notfn 1)" "error: 5 is not a function")
  (native-fails "(ns e4) (println (+ 1 \"a\"))" "error: + needs numbers, not \"a\"")
  (native-fails "(ns e5) (println (/ 1 0))" "error: division by zero"))

;;; What the native backend can't compile yet: errors with locations

(test native-unsupported
  (build-fails "(ns u1) (defn adder [n] (fn [x] (+ x n)))" "closures that capture locals")
  (build-fails "(ns u2) (println :kw)" "keywords, symbols and collections arrive in M1.4")
  (build-fails "(ns u3) (println (count \"ab\"))" "can't call skein.core/count yet")
  (build-fails "(ns u4) (def f inc)" "can't use skein.core/inc as a value yet")
  (build-fails "(ns u5) (try 1 (catch error e 2))" "conditions yet (M1.5)")
  (build-fails "(ns u6) (println (inc 1 2))" "wrong number of arguments (2) passed to skein.core/inc"))

;;; The command

(test build-command
  (multiple-value-bind (code out err) (run-cli "build")
    (declare (ignore out))
    (is (= skein.cli:+exit-usage+ code))
    (is (search "expected a file" err)))
  (multiple-value-bind (code out err) (run-cli "build" "no/such.skn")
    (declare (ignore out))
    (is (= skein.cli:+exit-failure+ code))
    (is (search "file not found" err)))
  (with-program (file "(ns bc) (println :kw)")
    (multiple-value-bind (code out err) (run-cli "build" (namestring file))
      (declare (ignore out))
      (is (= skein.cli:+exit-failure+ code))
      (is (search "error: " err))
      (is (search "prog.skn:1:18" err)))))
