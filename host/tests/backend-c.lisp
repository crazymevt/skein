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
      (dolist (name '("hello" "fib" "conditions"))
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

;;; Core data (M1.4): collections, names, closures, atoms and transients

(test native-core-functions
  ;; About ninety skein.core functions over every collection type, printed with prn.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein" "tests/fixtures/native-core.skn"))))

(test native-closures
  (native-matches "(ns closures)
(defn adder [n] (fn [x] (+ x n)))
(defn compose [f g] (fn [& args] (f (apply g args))))
(defn counter []
  (let [count (atom 0)]
    {:inc (fn [] (swap! count inc)) :get (fn [] @count)}))
(defn nested [a] (fn [b] (fn [c] [a b c])))
(def add5 (adder 5))
(println (add5 10) ((adder 1) 2) ((compose inc +) 1 2 3) (((nested 1) 2) 3))
(let [c (counter)] ((:inc c)) ((:inc c)) (println ((:get c))))
(println (letfn [(ev? [n] (if (zero? n) true (od? (dec n))))
                 (od? [n] (if (zero? n) false (ev? (dec n))))]
           [(ev? 10) (od? 7) (ev? 3)]))
(defn rest-args [a & more] [a more])
(println (rest-args 1) (rest-args 1 2 3) (apply rest-args [4 5]))
(defn for-each-n [n f] (loop [i 0 acc []] (if (< i n) (recur (inc i) (conj acc (f i))) acc)))
(defn make-fns [] (vec (for-each-n 3 (fn [i] (fn [] (* i 100))))))
(defn map-vec [f v] (reduce (fn [acc x] (conj acc (f x))) [] v))
(println (map-vec (fn [g] (g)) (make-fns)))
(def ^:private counter-atom (atom []))
(swap! counter-atom conj :a)
(swap! counter-atom (fn [v x] (conj v x)) :b)
(prn @counter-atom (def zz 1) zz)
(defn -main [& args] (prn :main args))"))

(test native-collections-under-gc
  ;; Big collections built and changed in compiled code, with many collections along
  ;; the way.
  (native-matches "(ns bigcoll)
(defn map-range [a b] (loop [i a acc []] (if (< i b) (recur (inc i) (conj acc i)) acc)))
(defn take-n [n m] (reduce (fn [acc e] (if (< (count acc) n) (conj acc e) acc)) [] m))
(defn build-map [n]
  (loop [i 0 m {}] (if (< i n) (recur (inc i) (assoc m (str \"k\" i) [i (* i i)])) m)))
(defn build-vec [n]
  (loop [i 0 t (transient [])] (if (< i n) (recur (inc i) (conj! t {:i i})) (persistent! t))))
(defn drain [m n] (loop [i 0 m m] (if (< i n) (recur (inc i) (dissoc m (str \"k\" i))) m)))
(let [m (build-map 50000)
      v (build-vec 100000)
      s (into #{} (map-range 0 3000))
      d (drain m 49990)]
  (println (count m) (get m \"k49999\") (get m \"nope\" :missing))
  (println (count v) (nth v 77777) (:i (peek v)))
  (println (count s) (contains? s 2999) (contains? s 3000))
  (prn d)
  (prn (= m (build-map 50000)) (= v (build-vec 100000)) (into {} (take-n 12 m))))"))

;;; Conditions and unwinding (M1.5)

(test native-conditions
  ;; The Phase 0 condition tests (conditions.lisp) as one program.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein"
                                                  "tests/fixtures/native-conditions.skn"))))

(test native-conditions-under-load
  ;; Many unwinds with allocation in between: frames are popped, conditions collected.
  (native-matches "(ns cload)
(defcondition bad [error] (v :reader bad-v))
(defn junk [i]
  (loop [j 0 acc []] (if (< j (mod i 20)) (recur (inc j) (conj acc (str \"s\" j))) acc)))
(defn step [i]
  (try
    (let [js (junk i)] (if (zero? (mod i 3)) (error bad :v [i js]) (count js)))
    (catch bad e (count (nth (bad-v e) 1)))
    (finally nil)))
(defn run [n]
  (loop [i 0 total 0]
    (if (< i n)
      (recur (inc i) (+ total (step i)
                        (handler-case (restart-case (error bad :v i) (again [x] x))
                          (bad [c] (bad-v c)))
                        (restart-case (handler-bind [bad (fn [c]
                                                           (invoke-restart 'again (bad-v c)))]
                                        (error bad :v 1))
                          (again [x] x))))
      total)))
(prn (run 30000) (find-restart 'again))"))

(test native-unhandled-errors
  ;; As skein run does: the message and the active restarts on stderr, exit status 1.
  (native-fails "(ns unhandled)
(println \"signal:\" (signal \"ignored\"))
(warn \"careful\" 1)
(restart-case (error \"it broke\")
  (use-default [] :report \"Use the default\" 1)
  (try-again [] 2))"
                "WARNING: careful 1"
                (format nil "error: it broke~%available restarts:~%  ~
                             use-default: Use the default~%  try-again: try-again~%"))
  (native-fails "(ns unhandled2) (defcondition oops [error] (n)) (error oops :n 1)"
                (format nil "error: unhandled2/oops {:n 1}~%")))

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
  (build-fails "(ns u3) (println (map inc [1 2]))" "can't use skein.core/map yet")
  (build-fails "(ns u4) (def f range)" "can't use skein.core/range yet")
  (build-fails "(ns u5) (prn (values 1 2))" "multiple values yet (M1.8)")
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
  (with-program (file "(ns bc) (println (map inc [1]))")
    (multiple-value-bind (code out err) (run-cli "build" (namestring file))
      (declare (ignore out))
      (is (= skein.cli:+exit-failure+ code))
      (is (search "error: " err))
      (is (search "prog.skn:1:19" err)))))

(test every-native-core-function-exists
  ;; Each name the emitter allows refers to a function the runtime has (sk_core stops the
  ;; program at startup otherwise).
  (if (not (zig-available-p))
      (skip "zig is not installed")
      (with-program (file (format nil "(ns allcore) (def fns [~{~A~^ ~}]) (println (count fns))"
                                  skein.backend.c::*native-core-functions*))
        (multiple-value-bind (out err code) (native-run file)
          (is (eql 0 code) "stderr: ~A" err)
          (is (string= (format nil "~D~%" (length skein.backend.c::*native-core-functions*))
                       out))))))
