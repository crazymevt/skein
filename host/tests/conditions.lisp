;;;; Tests for conditions and restarts (DESIGN §10, M0.6).

(in-package #:skein.tests)

(def-suite skein.conditions :in all
  :description "Conditions, handlers and restarts.")

(in-suite skein.conditions)

(defun logged (source)
  "Evaluate SOURCE with `log` bound to a transient vector; return the logged values."
  (evp (format nil "(let [log (transient [])] ~A (persistent! log))" source)))

(defmacro logs (source expected)
  `(is (string= ,expected (logged ,source)) "~S logged ~A, expected ~A"
       ,source (logged ,source) ,expected))

;;; error, signal, warn

(test error-with-a-message
  (evp-is "(handler-case (error \"bad value:\" 42) (error [e] (condition-message e)))"
          "\"bad value: 42\"")
  (evp-is "(handler-case (error \"x\") (error [e] [(condition? e) (error? e)]))" "[true true]")
  (fails "(error \"plain\" :k)" "plain :k"))

(test signal-and-warn
  (evp-is "(signal \"nobody listens\")" "nil")
  (evp-is "(handler-case (signal \"heard\") (condition [c] (condition-message c)))" "\"heard\"")
  (evp-is "(handler-bind [warning (fn [w] (invoke-restart 'muffle-warning))]
             (warn \"quiet\")
             :done)"
          ":done")
  (evp-is "(handler-case (warn \"w\") (warning [w] (error? w)))" "false"))

(test throw-condition-special-form
  (evp-is "(handler-case (throw-condition (make-condition 'error)) (error [e] :thrown))" ":thrown")
  (fails "(throw-condition 5)" "throw-condition needs a condition, not 5")
  (compile-fails "(throw-condition)" "throw-condition expects 1 argument, got 0"))

(test host-errors-are-conditions
  (evp-is "(handler-case (/ 1 0) (arithmetic-error [e] :divide-by-zero))" ":divide-by-zero")
  (evp-is "(handler-case (+ 1 \"a\") (type-error [e] :type))" ":type")
  (evp-is "(handler-case (nth [1] 5) (index-error [e] :index))" ":index")
  (evp-is "(handler-case ((fn [x] x)) (arity-error [e] :arity))" ":arity")
  (evp-is "(handler-case (5 1) (not-callable-error [e] :not-callable))" ":not-callable"))

;;; defcondition

(test defcondition
  (evp-is "(defcondition asset-missing [error] (path :reader asset-path))
           (handler-case (error 'asset-missing :path \"a.png\")
             (asset-missing [c] [(asset-path c) (:path c) (error? c)]))"
          "[\"a.png\" \"a.png\" true]")
  (evp-is "(defcondition note [] (n :initform (+ 1 2)))
           (handler-case (signal 'note) (note [c] [(:n c) (error? c)]))"
          "[3 false]")
  (evp-is "(defcondition base [error] (a :reader base-a))
           (defcondition derived [base] (b :reader derived-b))
           (handler-case (error derived :a 1 :b 2)
             (base [c] [(base-a c) (derived-b c)]))"
          "[1 2]")
  (evp-is "(defcondition loud [error] (x :reader loud-x)
             (:report (fn [c] (str \"loud: \" (loud-x c)))))
           (handler-case (error 'loud :x 5) (error [c] (condition-message c)))"
          "\"loud: 5\"")
  (evp-is "(defcondition plain [error] (x))
           (handler-case (error 'plain :x 1) (error [c] (condition-message c)))"
          (format nil "\"~A/plain {:x 1}\"" (format nil "test.ns~D" (1+ *test-ns-counter*))))
  (evp-is "(defcondition c1 [error]) (= (condition-type-name c1) 'c1)" "false")
  (evp-is "(defcondition c2 [error]) (name (condition-type-name c2))" "\"c2\"")
  (evp-is "(defcondition c3 [error])
           (handler-case (error c3) (error [c] (= (condition-type c) c3)))"
          "true")
  (evp-is "(defcondition c4 [error]) (condition? (make-condition 'c4))" "true"))

(test defcondition-can-be-redefined
  (evp-is "(defcondition grows [error] (a :reader grows-a))
           (defcondition grows [error] (a :reader grows-a) (b :reader grows-b))
           (handler-case (error 'grows :a 1 :b 2) (grows [c] [(grows-a c) (grows-b c)]))"
          "[1 2]"))

(test defcondition-errors
  (fails "(error 'no-such-condition-type)" "no-such-condition-type is not a condition type")
  (fails "(defcondition k1 [error]) (error 'k1 :nope 1)" "/k1 has no slot nope")
  (fails "(defcondition k2 [error]) (error 'k2 \"x\" 1)" "condition initargs must be keywords")
  (compile-fails "(defcondition k3 error)" "defcondition needs a vector of parent condition types"))

;;; handler-bind: handlers run without unwinding

(test handlers-run-before-unwinding
  ;; The handler sees the condition while the signaling code's unwind-protect is still
  ;; in place: :handler is logged before :cleanup.
  (logs "(handler-case
           (handler-bind [error (fn [c] (conj! log :handler))]
             (unwind-protect (error \"boom\") (conj! log :cleanup)))
           (error [e] (conj! log :caught)))"
        "[:handler :cleanup :caught]"))

(test declining-handlers-pass-the-condition-on
  ;; A handler that returns declines; the next one (further out) runs. Inner first.
  (logs "(handler-case
           (handler-bind [error (fn [c] (conj! log :outer))]
             (handler-bind [error (fn [c] (conj! log :inner))
                            condition (fn [c] (conj! log :same-cluster))]
               (error \"x\")))
           (error [e] (conj! log :caught)))"
        "[:inner :same-cluster :outer :caught]")
  (logs "(handler-bind [warning (fn [w] (conj! log :not-for-errors))]
           (handler-case (error \"x\") (error [e] (conj! log :caught))))"
        "[:caught]"))

(test handlers-can-invoke-restarts
  ;; The example from DESIGN §10.
  (evp-is "(defcondition asset-missing [error] (path :reader asset-path))
           (defn load-texture [path]
             (restart-case
               (if (= path \"good.png\") [:texture path] (error 'asset-missing :path path))
               (use-placeholder [] :placeholder)
               (use-path [p] (load-texture p))))
           [(handler-bind [asset-missing (fn [c] (invoke-restart 'use-placeholder))]
              (load-texture \"missing.png\"))
            (handler-bind [asset-missing (fn [c] (invoke-restart 'use-path \"good.png\"))]
              (load-texture \"missing.png\"))]"
          "[:placeholder [:texture \"good.png\"]]"))

;;; Restarts

(test restart-selection
  (evp-is "(restart-case (invoke-restart 'second 1 2) (first [] :first) (second [a b] (+ a b)))"
          "3")
  (evp-is "(restart-case (invoke-restart 'opt) (opt [& xs] (count xs)))" "0")
  (evp-is "(restart-case :no-restart-used (r [] :r))" ":no-restart-used")
  (evp-is "(restart-case (map restart-name (take 2 (compute-restarts))) (a [] 1) (b [] 2))"
          "(a b)")
  (evp-is "(restart-case (restart-report (find-restart 'r)) (r [] :report \"Do the thing\" 1))"
          "\"Do the thing\"")
  (evp-is "(find-restart 'nowhere)" "nil")
  ;; The innermost restart with a name wins.
  (evp-is "(restart-case (restart-case (invoke-restart 'r) (r [] :inner)) (r [] :outer))"
          ":inner")
  (evp-is "(restart-case (invoke-restart (find-restart 'r) 5) (r [x] (* x 2)))" "10")
  (fails "(invoke-restart 'not-active)" "no restart not-active is active"))

(test restarts-are-safe-after-their-extent
  (evp-is "(let [r (restart-case (find-restart 'r) (r [] 1))] (restart-name r))" "r")
  (fails "(let [r (restart-case (find-restart 'r) (r [] 1))] (invoke-restart r))"
         "no restart r is active")
  (evp-is "(first (map restart-name (restart-case (compute-restarts) (late [] 1))))" "late"))

(test restart-case-errors
  (compile-fails "(restart-case 1 (r 2))" "restart-case clauses look like (name [params] body...)")
  (compile-fails "(restart-bind* [r] 1)"
                 "restart-bind* needs a vector of name, function and report triples"))

;;; handler-case and try

(test handler-case
  (evp-is "(handler-case (error \"x\") (arithmetic-error [e] :arith) (error [e] :error))" ":error")
  (evp-is "(handler-case (/ 1 0) (arithmetic-error [e] :arith) (error [e] :error))" ":arith")
  (evp-is "(handler-case (error \"x\") (error [] :no-var))" ":no-var")
  (evp-is "(handler-case 42 (error [e] :never))" "42")
  (evp-is "(handler-case (handler-case (/ 1 0) (index-error [e] :inner)) (error [e] :outer))"
          ":outer")
  (compile-fails "(handler-case 1 (error e 2))"
                 "handler-case clauses look like (type [c] body...)"))

(test try-catch-finally
  (evp-is "(try 1 2)" "2")
  (evp-is "(try (/ 1 0) (catch arithmetic-error e :caught))" ":caught")
  (logs "(conj! log (try (conj! log :body) :value (finally (conj! log :finally))))"
        "[:body :finally :value]")
  (logs "(try (error \"x\") (catch error e (conj! log :catch)) (finally (conj! log :finally)))"
        "[:catch :finally]")
  (logs "(try (try (error \"x\") (finally (conj! log :inner-finally)))
             (catch error e (conj! log :outer-catch)))"
        "[:inner-finally :outer-catch]"))

;;; unwind-protect ordering

(test unwind-protect-ordering
  (logs "(handler-case
           (unwind-protect
             (unwind-protect (error \"x\") (conj! log :inner) (conj! log :inner2))
             (conj! log :outer))
           (error [e] (conj! log :handler)))"
        "[:inner :inner2 :outer :handler]")
  (logs "(restart-case
           (unwind-protect (invoke-restart 'r) (conj! log :cleanup))
           (r [] (conj! log :restart)))"
        "[:cleanup :restart]")
  (logs "(block* b (unwind-protect (unwind-protect (return-from* b 1) (conj! log 1))
                                   (conj! log 2)))"
        "[1 2]"))

;;; skein run reports unhandled errors with their restarts

(defun run-skein-process (&rest args)
  "Run the skein command line in a new SBCL with ARGS. Returns stdout, stderr and the
exit code."
  (uiop:run-program (list* sb-ext:*runtime-pathname* "--noinform" "--no-userinit"
                           "--non-interactive"
                           "--load" (namestring (asdf:system-relative-pathname
                                                 "skein" "tools/launch.lisp"))
                           "--eval" "(skein.cli:toplevel)" "--end-toplevel-options" args)
                    :output :string :error-output :string :ignore-error-status t))

(test unhandled-errors-show-restarts
  (uiop:with-temporary-file (:pathname path :type "skn")
    (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string "(ns unhandled)
(println \"signal:\" (signal \"ignored\"))
(restart-case (error \"it broke\")
  (use-default [] :report \"Use the default\" 1)
  (try-again [] 2))" s))
    ;; Run in a separate SBCL: inside this process, the test framework's own error
    ;; handler would catch the error before it counts as unhandled.
    (multiple-value-bind (out err code) (run-skein-process "run" (namestring path))
      (is (search "signal: nil" out))
      (is (= skein.cli:+exit-failure+ code))
      (is (search "error: it broke" err))
      (is (search (format nil "available restarts:~%  use-default: Use the default~%  ~
                               try-again: try-again")
                  err)))))

(test restarts-match-by-plain-name
  ;; A restart established under a qualified name (as a syntax-quoted macro does) is
  ;; found by its plain name, and the reverse (D-041).
  (evp-is "(restart-case (invoke-restart 'retry-it) (some.ns/retry-it [] :found))" ":found")
  (evp-is "(restart-case (invoke-restart 'other.ns/retry-it) (retry-it [] :found))" ":found")
  (evp-is "(defmacro with-again [& body] `(restart-case (do ~@body) (again [] :again)))
           (with-again (invoke-restart 'again))"
          ":again")
  (evp-is "(restart-case (restart-name (find-restart 'x.y/plain)) (plain [] nil))" "plain"))
