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
      (dolist (name '("hello" "fib" "conditions" "collections" "macros" "objects"
                      "particles"))
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

;;; Programs of several namespaces, and skein.core's library in Skein (M1.8, D-051)

(test native-program-of-several-namespaces
  ;; Requires with :as and :refer, a private function, a macro from a required namespace,
  ;; shared requires translated once and in order, and -main with arguments.
  (if (not (zig-available-p))
      (skip "zig is not installed")
      (with-source-tree (dir ("app/util.skn" "(ns app.util)
(def greeting \"hello\")
(defn- secret [] 41)
(defn answer [] (inc (secret)))
(defmacro twice [x] `(do ~x ~x))
(println \"loading app.util\")")
                             ("app/more.skn" "(ns app.more (:require [app.util :as u]))
(defn shout [s] (str s \"! \" (u/answer)))
(println \"loading app.more\")")
                             ("app/main.skn" "(ns app.main
  (:require [app.util :as u :refer [answer]]
                                    [app.more]))
(u/twice (println u/greeting (answer)))
(println (app.more/shout \"x\"))
(defn -main [& args] (println \"main\" args))"))
        (let* ((file (merge-pathnames "app/main.skn" dir))
               (expected (with-output-to-string (*standard-output*)
                           (skein.backend.cl:run-file file))))
          (multiple-value-bind (out err code) (native-run file)
            (is (eql 0 code) "native exit code ~A, stderr: ~A" code err)
            (is (string= expected out) "native output differs:~%--- skein run:~%~A--- native:~%~A"
                expected out))))))

(defun library-names ()
  "The public functions of skein.core.native."
  (skein.runtime:require-namespace "skein.core.native")
  (let ((ns (skein.runtime:find-namespace "skein.core.native")))
    (loop for name being the hash-keys of (skein.runtime::namespace-mappings ns)
            using (hash-value var)
          unless (skein.runtime:var-private-p var) collect name)))

(defun value-with (source library-p)
  "SOURCE evaluated, printed: with skein.core, or with every skein.core.native function
referred in place of skein.core's."
  (handler-case
      (pr (ev (format nil "(ns lib-test~:[~;~:* ~
                           (:require [skein.core.native :refer [~{~A~^ ~}]])~])~%~A"
                      (and library-p (library-names)) source)))
    (error (e) (format nil "error: ~A" (if (typep e 'skein.runtime:skein-error)
                                           (skein.runtime:skein-error-message e)
                                           (princ-to-string e))))))

(defun library-matches (&rest sources)
  "Each source gives the same printed value with skein.core as with skein.core.native."
  (dolist (source sources)
    (let ((core (value-with source nil)) (lib (value-with source t)))
      (is (string= core lib) "~A: Phase 0 gives ~A, skein.core.native ~A" source core lib))))

(test native-library-matches-phase-0
  (library-matches "(update {:a 1} :a inc)" "(update {:a 1} :b (fnil inc 0))"
                   "(update [1 2] 0 + 10 20)" "(update nil :k (constantly 1))"))

(test native-library-seqs-match-phase-0
  (library-matches
   ;; Lazy seq functions, with a collection and as transducers
   "(map inc [1 2 3])" "(map + [1 2] [10 20 30])" "(map vector \"ab\" (range))"
   "(map inc nil)" "(map identity {:a 1 :b 2})" "(map inc #{1 2 3})"
   "(into [] (map inc) [1 2])" "(mapv inc [1 2])" "(mapv + [1 2] [3 4] [5 6])"
   "(map-indexed vector [:a :b])" "(into [] (map-indexed vector) [:a :b])"
   "(filter odd? (range 10))" "(into [] (filter odd?) [1 2 3])" "(filterv even? [1 2 3 4])"
   "(remove odd? [1 2 3])" "(into [] (remove odd?) [1 2 3])"
   "(keep (fn [x] (when (odd? x) (* x x))) (range 6))" "(into [] (keep identity) [1 nil 2])"
   "(take 3 (range))" "(take 0 [1])" "(take 5 [1 2])" "(into [] (take 2) [1 2 3])"
   "(into [] (take 0) [1 2 3])" "(drop 2 [1 2 3])" "(drop 5 [1])" "(into [] (drop 1) [1 2])"
   "(take-while neg? [-1 -2 3 -4])" "(into [] (take-while odd?) [1 3 4 5])"
   "(drop-while neg? [-1 -2 3 -4])" "(into [] (drop-while odd?) [1 3 4 5])"
   "(concat [1] '(2) nil #{3})" "(concat)" "(into [] cat [[1 2] [3]])"
   "(mapcat reverse [[1 2] [3 4]])" "(into [] (mapcat (fn [x] [x x])) [1 2])"
   "(range 5)" "(range 2 8 3)" "(range 5 0 -2)" "(take 3 (range 0 1 0))" "(range 3 3)"
   "(repeat 3 :x)" "(take 2 (repeat :y))" "(repeatedly 2 (constantly 7))"
   "(take 4 (iterate (fn [x] (* 2 x)) 1))" "(take 5 (cycle [1 2]))" "(cycle [])"
   "(interleave [1 2 3] [:a :b])" "(interleave)" "(interpose :x [1 2 3])"
   "(into [] (interpose :x) [1 2])" "(interpose :x [])"
   "(partition 2 [1 2 3 4 5])" "(partition 2 1 [1 2 3])" "(partition 3 [1 2])"
   "(partition-all 2 [1 2 3])" "(partition-all 2 3 [1 2 3 4 5])"
   "(into [] (partition-all 2) [1 2 3])" "(distinct [1 2 1 3 2])"
   "(into [] (distinct) [1 1 2])" "(dedupe [1 1 2 2 1])" "(into [] (dedupe) [1 1 2])"
   ;; Eager ones
   "(reverse [1 2 3])" "(reverse nil)" "(sort [3 1 2])" "(sort > [3 1 2])"
   "(sort (fn [a b] (- b a)) [1 3 2])" "(sort-by count [\"ccc\" \"a\" \"bb\"])"
   "(sort-by first [[2 :a] [1 :b] [2 :c] [1 :d]])" "(sort [])"
   "(flatten [1 [2 [3 (4)]] 5])" "(flatten nil)" "(frequencies [:a :b :a])"
   "(group-by odd? (range 6))" "(some even? [1 3 4])" "(some even? [1])"
   "(every? odd? [1 3])" "(every? odd? [])" "(not-every? odd? [1 2])" "(not-any? odd? [2])"
   "(nthrest [1 2 3] 2)" "(nthnext [1 2 3] 2)" "(nthnext [1] 3)" "(split-at 2 [1 2 3])"
   "(split-with odd? [1 3 4 5])" "(doall (map inc [1]))" "(dorun (map inc [1]))"
   "(second [1 2])" "(ffirst [[1]])" "(nnext [1 2 3])" "(last [1 2])" "(last (range 4))"
   "(last [])" "(butlast [1 2 3])" "(butlast [1])" "(list* 1 2 [3 4])" "(list* nil)"
   "(set [1 2 2])"
   ;; Reduction and transducer entry points
   "(into [] [1 2])" "(into {} [[:a 1]])" "(into #{} [1 1])" "(into '(1) [2 3])"
   "(into nil [1])" "(into [] (comp (map inc) (filter even?)) (range 10))" "(into)"
   "(transduce (map inc) + [1 2 3])" "(transduce (map inc) + 10 [1 2 3])"
   "(transduce (take 2) conj [1 2 3])" "(sequence [1 2])" "(sequence nil)"
   "(sequence (comp (map inc) (take 2)) [5 6 7])" "(sequence (partition-all 2) [1 2 3])"
   "(reduce-kv (fn [acc k v] (conj acc [k v])) [] {:a 1})"
   "(reduce-kv (fn [acc i v] (+ acc i v)) 0 [10 20])" "(reduce-kv + 0 nil)"
   "((comp inc *) 2 3)" "((comp) 5)" "((partial + 1 2) 3)" "((complement odd?) 2)"
   "((juxt inc dec) 5)" "((fnil inc 0) nil)" "((completing +) 1 2)"
   "((completing + str) 3)"
   "(reduce + (eduction (map inc) (filter odd?) [1 2 3 4]))"
   "(seq (eduction (map inc) [1 2]))" "(into [] (eduction (map inc) [1]))"
   "(reduce (fn [acc x] (if (> x 2) (reduced acc) (+ acc x))) 0 (range 10))"
   ;; How much a lazy seq realizes
   "(let [log (atom [])] (doall (take 2 (map (fn [x] (swap! log conj x) x) (range 10)))) @log)"
   "(let [log (atom [])] (first (filter (fn [x] (swap! log conj x) (> x 2)) (range 10))) @log)"
   "(let [log (atom [])] (sequence (map (fn [x] (swap! log conj x) x)) [1 2 3]) @log)"
   "(let [s (map inc [1 2])] [(realized? s) (first s) (realized? s)])"
   ;; Errors
   "(take 2 5)" "(reduce-kv + 0 #{1})"))

(defun random-vector-text (rs)
  (format nil "[~{~D~^ ~}]" (loop repeat (random 8 rs) collect (- (random 10 rs) 3))))

(test native-library-seqs-match-phase-0-randomly
  ;; Random collections through random seq functions and transducer stacks.
  (let ((rs (sb-ext:seed-random-state 20261111))
        (seq-fns '("(map inc ~A)" "(filter odd? ~A)" "(remove even? ~A)" "(take 3 ~A)"
                   "(drop 2 ~A)" "(take-while pos? ~A)" "(drop-while neg? ~A)"
                   "(partition-all 2 ~A)" "(partition 2 1 ~A)" "(distinct ~A)" "(dedupe ~A)"
                   "(interpose 0 ~A)" "(reverse ~A)" "(sort ~A)" "(concat ~A [9])"
                   "(mapcat (fn [x] [x x]) ~A)" "(keep (fn [x] (when (pos? x) x)) ~A)"))
        (xforms '("(map inc)" "(filter odd?)" "(take 4)" "(drop 1)" "(distinct)" "(dedupe)"
                  "(partition-all 2)" "(take-while pos?)" "(interpose 0)" "cat")))
    (dotimes (i 150)
      (let* ((v (random-vector-text rs))
             (inner (nth (random (length seq-fns) rs) seq-fns))
             (outer (nth (random (length seq-fns) rs) seq-fns)))
        (library-matches (format nil "(vec ~A)" (format nil outer (format nil inner v))))))
    (dotimes (i 150)
      (let* ((v (random-vector-text rs))
             (stack (loop repeat (1+ (random 3 rs))
                          collect (nth (random (length xforms) rs) xforms)))
             (xform (format nil "(comp ~{~A~^ ~})" (remove "cat" stack :test #'string=))))
        (library-matches (format nil "(into [] ~A ~A)" xform v)
                         (format nil "(sequence ~A ~A)" xform v)
                         (format nil "(transduce ~A + 0 ~A)" xform v))))))

(test native-seqs
  ;; The runtime's seqs and the library's seq functions and transducers, compiled.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein" "tests/fixtures/native-seqs.skn"))))

(test native-more-of-skein-core
  ;; Step 3 of M1.8: the runtime's new functions, the library's map functions, calling
  ;; collections, and multiple values.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein" "tests/fixtures/native-more.skn"))))

(test native-library-maps-match-phase-0
  (library-matches
   "(get-in {:a {:b 1}} [:a :b])" "(get-in {:a 1} [:x] :nf)" "(get-in {:a 1} [])"
   "(get-in [[1 2]] [0 1])" "(get-in nil [:a])" "(get-in {:a nil} [:a] :nf)"
   "(assoc-in {} [:a :b] 1)" "(assoc-in {:a {:b 1}} [:a :c] 2)" "(assoc-in [1 [2]] [1 0] :x)"
   "(assoc-in nil [:k] 1)" "(update-in {:a {:b 1}} [:a :b] inc)"
   "(update-in {:a [1 2]} [:a 0] + 10 20)" "(update-in nil [:x :y] (fnil inc 0))"
   "(merge {:a 1} {:b 2})" "(merge {:a 1} nil {:a 2})" "(merge)" "(merge nil)"
   "(merge nil {:a 1})" "(merge {:a 1} [:b 2])" "(merge-with + {:a 1} {:a 2 :b 3})"
   "(merge-with concat {:a [1]} {:a [2]} nil {:a [3]})" "(merge-with + nil nil)"
   "(select-keys {:a 1 :b 2} [:a :x])" "(select-keys {} [])" "(select-keys [10 20] [1 5])"
   "(zipmap [:a :b] [1 2 3])" "(zipmap (range 3) (repeat :x))" "(zipmap nil [1])"
   "(find {:a 1} :a)" "(find {:a nil} :a)" "(find {} :a)" "(find nil :a)"
   "(key (first {:a 1}))" "(val (first {:a 1}))" "(empty [1 2])" "(empty {:a 1})"
   "(empty #{1})" "(empty '(1 2))" "(empty (range 3))" "(empty 5)" "(not-empty [])"
   "(not-empty [1])" "(not-empty \"\")"))

(test native-objects
  ;; Step 4 of M1.8: classes, instances and cells, generic functions with multiple
  ;; dispatch and method combination, equiv and hash-of, condition types as classes.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein"
                                                  "tests/fixtures/native-objects.skn"))))

(test native-structs-and-arrays
  ;; Step 5 of M1.8: value structs, records, typed arrays, views and defsoa.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein"
                                                  "tests/fixtures/native-structs.skn"))))

(test native-typed-code
  ;; Step 5 of M1.8: declared types compile to unboxed C with Phase 0's results and errors.
  (native-matches (uiop:read-file-string
                   (asdf:system-relative-pathname "skein" "tests/fixtures/native-typed.skn"))))

(test native-nbody
  ;; The n-body benchmark, built natively (release), computes Phase 0's energies exactly.
  (if (not (zig-available-p))
      (skip "zig is not installed")
      (let* ((main (asdf:system-relative-pathname "skein" "../bench/nbody/main.skn"))
             (expected (with-output-to-string (*standard-output*)
                         (skein.backend.cl:run-file main :args '("2000"))))
             (exe (skein.backend.c:build-program
                   main :profile :release
                        :output (uiop:native-namestring
                                 (merge-pathnames (format nil "nbody-native~:[~;.exe~]"
                                                          (string= (skein.platform:os-name)
                                                                   "windows"))
                                                  (uiop:temporary-directory))))))
        (is (string= expected (uiop:run-program (list (uiop:native-namestring exe) "2000")
                                                :output :string))))))

(test native-library-routing
  (native-matches "(ns libroute)
(prn (update {:n 1} :n inc) (update [1 2] 1 * 10) (update {} :k (fn [_] :new)))
(def f update)
(prn (f {:a [1]} :a conj 2))"))

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
  (build-fails "(ns u3) (println (chan))" "can't use skein.core/chan yet")
  (build-fails "(ns u4) (def f pmap)" "can't use skein.core/pmap yet")
  (build-fails "(ns u5) (let [^:mutable x 0] (fn [] (set! x 1)))"
               "can't set! the ^:mutable local x")
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
  (with-program (file "(ns bc) (println (chan))")
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
