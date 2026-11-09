;;;; Tests for the expander and CL backend together: every special form of DESIGN §5.1
;;;; that M0.3 implements, calls, name resolution, macros, namespaces and redefinition.

(in-package #:skein.tests)

(def-suite skein.expander :in all
  :description "Expanding and evaluating Skein code (skein.expander + skein.backend.cl).")

(in-suite skein.expander)

;;; Helpers

(defvar *test-ns-counter* 0)

(defun fresh-ns ()
  (format nil "test.ns~D" (incf *test-ns-counter*)))

(defun ev (source &key (namespace (fresh-ns)))
  "Evaluate SOURCE in a fresh namespace (or NAMESPACE) and return the last value."
  (skein.backend.cl:load-string source :file "t.skn" :namespace namespace))

(defun ev-output (source)
  "Evaluate SOURCE in a fresh namespace and return what it printed."
  (with-output-to-string (*standard-output*)
    (ev source)))

(defun skein-false-p (x) (eq x skein.runtime:+false+))

(defmacro evals-to (source expected &key (test 'eql))
  `(is (,test ,expected (ev ,source)) "~S should evaluate to ~S" ,source ,expected))

(defun error-of (source &optional (type 'skein.runtime:skein-error))
  (handler-case (progn (ev source) nil)
    (error (e) (if (typep e type) e (error e)))))

(defmacro fails (source message &key line column (type ''skein.runtime:skein-error))
  "Check that evaluating SOURCE signals TYPE with MESSAGE in it, at LINE:COLUMN of t.skn
when they are given."
  `(let ((e (error-of ,source ,type)))
     (is (not (null e)) "~S should signal ~S" ,source ,type)
     (when e
       (is (search ,message (skein.runtime:skein-error-message e))
           "~S: message ~S does not contain ~S" ,source
           (skein.runtime:skein-error-message e) ,message)
       ,@(when line
           `((let ((loc (skein.runtime:skein-error-location e)))
               (is (and loc (equal (list ,line ,column)
                                   (list (skein.syntax:source-location-line loc)
                                         (skein.syntax:source-location-column loc))))
                   "~S: error at ~A, expected ~A:~A" ,source
                   (skein.syntax:format-location loc) ,line ,column)))))))

(defmacro type-fails (source)
  "Check that evaluating SOURCE signals a CL type error (a declared type was violated)."
  `(is (eq :type-error (handler-case (progn (ev ,source) :no-error) (type-error () :type-error)))
       "~S should signal a type error" ,source))

(defmacro compile-fails (source message &rest keys)
  `(fails ,source ,message :type 'skein.expander:compile-error ,@keys))

;;; quote

(test quote-form
  (is (eq (sym "x") (ev "(quote x)")))
  (is (eq (sym "x" "a.b") (ev "'a.b/x")))
  (is (eq (kw "k") (ev "':k")))
  (evals-to "'5" 5)
  (is (string= "s" (ev "'\"s\"")))
  (is (null (ev "'nil")))
  (is (skein.runtime:equiv (skein.runtime:vector-from-list '(1 2)) (ev "(quote [1 2])")))
  (is (string= "(1 [:a] {b #{c}})" (skein.runtime:readable-string (ev "'(1 [:a] {b #{c}})"))))
  (is (skein.runtime:plist-p (ev "'(1 2)")))
  (compile-fails "(quote)" "quote expects 1 argument, got 0" :line 1 :column 1)
  (compile-fails "(quote a b)" "quote expects 1 argument, got 2"))

;;; Literals

(test literals-evaluate-to-themselves
  (evals-to "42" 42)
  (evals-to "1.5" 1.5d0)
  (evals-to "1.5f" 1.5f0)
  (evals-to "\\a" #\a)
  (is (string= "text" (ev "\"text\"")))
  (is (eq (kw "k") (ev ":k")))
  (is (eq t (ev "true")))
  (is (skein-false-p (ev "false")))
  (is (null (ev "nil")))
  (is (string= "[1 2 3]" (skein.runtime:readable-string (ev "[1 2 (+ 1 2)]"))))
  (is (string= "{:a 2}" (skein.runtime:readable-string (ev "{:a (inc 1)}"))))
  (is (string= "#{1}" (skein.runtime:readable-string (ev "#{1}"))))
  (is (eq skein.runtime:+empty-list+ (ev "()")))
  (let ((v (ev "(def k (fn [] [1 2])) (identical? (k) (k))")))
    (is (eq t v) "a constant vector literal is built once, at compile time"))
  (fails "(let* [a 1 b 1] {a 1 b 2})" "duplicate key 1 in a map literal")
  (fails "(let* [a 1] #{a 1})" "duplicate element 1 in a set literal"))

;;; if

(test if-form
  (evals-to "(if true 1 2)" 1)
  (evals-to "(if nil 1 2)" 2)
  (evals-to "(if false 1 2)" 2)
  (evals-to "(if 0 1 2)" 1 )
  (evals-to "(if \"\" 1 2)" 1)
  (evals-to "(if :k 1 2)" 1)
  (is (null (ev "(if false 1)")))
  (compile-fails "(if)" "if expects 2 to 3 arguments, got 0")
  (compile-fails "(if 1 2 3 4)" "if expects 2 to 3 arguments, got 4"))

;;; do

(test do-form
  (is (null (ev "(do)")))
  (evals-to "(do 1 2 3)" 3)
  (is (string= (format nil "a~%b~%") (ev-output "(do (println \"a\") (println \"b\"))"))))

;;; def

(test def-form
  (let ((ns (fresh-ns)))
    (let ((var (ev "(def x 1)" :namespace ns)))
      (is (skein.runtime:var-p var))
      (is (string= (format nil "~A/x" ns) (skein.runtime:var-qualified-name var))))
    (evals-to "(do (def x 1) (def x 2) x)" 2)
    (is (= 1 (ev "x" :namespace ns)))
    (is (= 1 (ev "(do (def x) x)" :namespace ns)) "(def x) keeps an existing value"))
  (let ((ns (fresh-ns)))
    (ev "(def ^:private ^:dynamic *y* 1) (def z \"the doc\" 2)" :namespace ns)
    (let ((y (skein.runtime:find-own-var (skein.runtime:find-namespace ns) "*y*"))
          (z (skein.runtime:find-own-var (skein.runtime:find-namespace ns) "z")))
      (is (skein.runtime:var-private-p y))
      (is (skein.runtime:var-dynamic-p y))
      (is (string= "the doc" (skein.runtime:var-doc z)))
      (is (= 2 (skein.runtime:var-value z)))))
  (fails "(def x) x" "is unbound" :type 'skein.runtime:unbound-var-error :line 1 :column 9)
  (compile-fails "(def 5 1)" "def needs a symbol")
  (compile-fails "(def other.ns/x 1)" "cannot def other.ns/x outside its namespace")
  (compile-fails "(def x 1 2)" "needs a docstring second"))

;;; fn

(test fn-form
  (evals-to "((fn [x y] (+ x y)) 1 2)" 3)
  (evals-to "((fn [] 7))" 7)
  (is (null (ev "((fn []))")))
  (evals-to "((fn ([x] x) ([x y] (* x y))) 3 4)" 12)
  (evals-to "((fn ([x] x) ([x y] (* x y))) 3)" 3)
  (is (skein.runtime:equiv (skein.runtime:list-from-cl '(2 3))
                           (ev "((fn [x & more] more) 1 2 3)")))
  (is (skein.runtime:plist-p (ev "((fn [& more] more) 1)")))
  (is (null (ev "((fn [x & more] more) 1)")))
  (evals-to "((fn ([] 0) ([x & more] x)) 5 6)" 5)
  (evals-to "((fn fact [n] (if (< n 2) 1 (* n (fact (dec n))))) 10)" 3628800)
  (evals-to "(((fn [x] (fn [y] (+ x y))) 10) 5)" 15)
  (is (functionp (ev "(fn [x] x)")))
  (fails "((fn [x] x))" "wrong number of arguments (0) passed to fn (defined at t.skn:1:2)"
         :type 'skein.runtime:arity-error)
  (fails "((fn ([x] x) ([x y z] x)) 1 2)" "wrong number of arguments (2)")
  (compile-fails "(fn)" "fn needs a parameter vector")
  (compile-fails "(fn x)" "fn needs a parameter vector")
  (compile-fails "(fn [1] 1)" "a parameter must be an unqualified symbol, not 1")
  (compile-fails "(fn [x &] x)" "& must be followed by exactly one parameter")
  (compile-fails "(fn [& a b] a)" "& must be followed by exactly one parameter")
  (compile-fails "(fn ([x] 1) ([y] 2))" "two arities with the same number of parameters")
  (compile-fails "(fn ([& x] 1) ([& y] 2))" "only one variadic arity")
  (compile-fails "(fn ([a b c] 1) ([& y] 2))" "more parameters than the variadic one")
  (compile-fails "(fn (x) 1)" "fn parameters must be a vector"))

;;; let*

(test let*-form
  (evals-to "(let* [x 1 y (+ x 1)] (* x y))" 2)
  (evals-to "(let* [x 1 x (+ x 10)] x)" 11)
  (evals-to "(let* [x 1] (let* [x 2] x))" 2)
  (evals-to "(let* [x 1] (let* [y 2] x))" 1)
  (is (null (ev "(let* [])")))
  (evals-to "(let* [] 1 2)" 2)
  (compile-fails "(let* [x] x)" "let* binding vector needs an even number of forms")
  (compile-fails "(let* (x 1) x)" "let* needs a binding vector")
  (compile-fails "(let* [1 2] 3)" "a binding name must be an unqualified symbol")
  (compile-fails "(let* [x 1] y)" "unable to resolve symbol `y`" :line 1 :column 13))

;;; letfn*

(test letfn*-form
  (evals-to "(letfn* [(ev? [n] (if (= n 0) true (od? (dec n))))
                      (od? [n] (if (= n 0) false (ev? (dec n))))]
               (if (ev? 10) 1 0))"
            1)
  (evals-to "(letfn* [(f ([] (f 1)) ([x] (* x 2)))] (f))" 2)
  (compile-fails "(letfn* [f] 1)" "letfn* expects (name [params] body...)"))

;;; loop* and recur

(test loop*-and-recur
  (evals-to "(loop* [i 0 acc 0] (if (> i 100) acc (recur (inc i) (+ acc i))))" 5050)
  (evals-to "(loop* [i 1000000] (if (zero? i) :done (recur (dec i))))" (kw "done"))
  (evals-to "(loop* [x 1 y (+ x 1)] (+ x y))" 3)
  (evals-to "((fn [n acc] (if (zero? n) acc (recur (dec n) (* acc n)))) 5 1)" 120)
  (is (skein.runtime:equiv (skein.runtime:list-from-cl '(1 2))
                           (ev "((fn [n & xs] (if (zero? n) xs (recur (dec n) xs))) 3 1 2)")))
  ;; Each iteration gets fresh bindings: a closure keeps the value it saw.
  (evals-to "(loop* [i 0 f nil]
               (if (= i 3) (f) (recur (inc i) (if (= i 1) (fn [] i) f))))"
            1)
  (evals-to "(loop* [i 0] (if (< i 3) (do (recur (inc i))) i))" 3)
  (evals-to "(loop* [i 0] (let* [j (inc i)] (if (< j 5) (recur j) j)))" 5)
  ;; Regression: an inner loop* without bindings must not take over the outer recur.
  (evals-to "(loop* [i 0 n 0]
               (if (< i 3)
                 (do (loop* [] (if (= n 99) (recur) n))
                     (recur (inc i) (+ n 2)))
                 n))"
            6)
  (compile-fails "(loop* [i 0] (+ 1 (recur i)))" "recur must be in tail position"
                 :line 1 :column 19)
  (compile-fails "(loop* [i 0] (recur))" "recur expects 1 argument, got 0")
  (compile-fails "(recur 1)" "recur is only allowed inside loop* or fn")
  (compile-fails "(loop* [i 0] (fn [] (recur 1)))" "recur expects 0 arguments, got 1")
  (compile-fails "(loop* [i (recur 1)] i)" "recur is only allowed inside loop* or fn")
  (compile-fails "(loop* [i 0] (unwind-protect (recur 1)))" "recur must be in tail position"))

;;; set!

(test set!-form
  (evals-to "(let* [^:mutable x 1] (set! x (+ x 1)) x)" 2)
  (evals-to "(let* [^:mutable n 0 inc! (fn [] (set! n (inc n)))] (inc!) (inc!) n)" 2)
  (evals-to "((fn [^:mutable x] (set! x 5) x) 1)" 5)
  (compile-fails "(let* [x 1] (set! x 2))"
                 "cannot set! the immutable local x; declare it ^:mutable")
  (compile-fails "(do (def v 1) (set! v 2))" "set! of a var needs a dynamic binding")
  (compile-fails "(set! (f x) 1)" "set! needs a ^:mutable local or a slot like (:name obj)"))

;;; unwind-protect, block*, return-from*

(test unwind-protect-form
  (is (string= (format nil "body~%cleanup~%")
               (ev-output "(unwind-protect (println \"body\") (println \"cleanup\"))")))
  (evals-to "(unwind-protect 1 2 3)" 1)
  (is (string= (format nil "cleanup~%")
               (ev-output "(block* b (unwind-protect (return-from* b 1) (println \"cleanup\")))")))
  (is (string= (format nil "cleanup~%")
               (with-output-to-string (*standard-output*)
                 (ignore-errors (ev "(unwind-protect (undefined-thing) (println \"cleanup\"))"))
                 (ignore-errors (ev "(unwind-protect (5) (println \"cleanup\"))"))))))

(test block*-and-return-from*
  (evals-to "(block* done 1 (return-from* done 2) 3)" 2)
  (is (null (ev "(block* done (return-from* done) 3)")))
  (evals-to "(block* outer (block* inner (return-from* outer 1)) 2)" 1)
  (evals-to "(block* b (let* [f (fn [] (return-from* b 7))] (f) 8))" 7)
  (evals-to "(block* b 5)" 5)
  (compile-fails "(return-from* nowhere 1)" "no enclosing block* named nowhere")
  (compile-fails "(block* 5 1)" "a block name must be an unqualified symbol"))

;;; values, let-values*, the

(test values-and-let-values*
  (evals-to "(let-values* [[a b] (values 1 2)] (+ a b))" 3)
  (evals-to "(let-values* [[a b c] (values 1 2)] (if (nil? c) a 0))" 1)
  (evals-to "(let-values* [[a] (values 1 2)] a)" 1)
  (evals-to "(let-values* [[a b] (values 1 2) [c] (values (+ a b))] c)" 3)
  (evals-to "(let-values* [[q r] ((fn [] (values 7 8)))] (* q r))" 56)
  (evals-to "(let* [x (values 1 2)] x)" 1)
  (compile-fails "(let-values* [a (values 1)] a)" "binds a vector of names"))

(test the-form
  (evals-to "(the i32 5)" 5)
  (evals-to "(the f64 1.5)" 1.5d0)
  (is (eq :type-error (handler-case (ev "(the (array f32) 5)") (type-error () :type-error)))
      "the checks its type under the default (dev) policy")
  (compile-fails "(the i32)" "the expects 2 arguments, got 1"))

;;; declare and reserved forms

(test declare-and-reserved-forms
  (evals-to "((fn [x] (declare (type i32 x)) (+ x 1)) 1)" 2)
  (evals-to "(let* [x 1] (declare (type i32 x)) x)" 1)
  (compile-fails "(do (declare x) 1)" "declare is only allowed at the start of a body")
  (compile-fails "(%ffi-call 1)" "not supported until the FFI arrives (M0.10)"))

;;; Calls

(test calls
  (evals-to "(inc 1)" 2)
  (evals-to "(let* [f inc] (f 1))" 2)
  (evals-to "((if true inc dec) 1)" 2)
  (is (null (ev "(:k nil)")))
  (evals-to "(:k nil 5)" 5)
  (is (null (ev "(:k 1)")) "looking a keyword up in a non-collection gives nil, as get does")
  (fails "(:k)" ":k called with 0 arguments; expected 1 or 2" :type 'skein.runtime:arity-error)
  (fails "(5 1)" "cannot call 5" :type 'skein.runtime:not-callable-error :line 1 :column 1)
  (fails "(\"s\")" "cannot call \"s\"" :type 'skein.runtime:not-callable-error)
  (fails "(nil)" "cannot call nil" :type 'skein.runtime:not-callable-error)
  (is (string= (format nil "f~%a~%b~%")
               (ev-output "(def list* (fn [& xs] xs))
                           ((do (println \"f\") list*) (println \"a\") (println \"b\"))")))
  (is (string= (format nil "1~%2~%")
               (ev-output "((fn [a b] nil) (println 1) (println 2))"))))

;;; Name resolution

(test name-resolution
  (evals-to "(skein.core/inc 1)" 2)
  (evals-to "(let* [inc dec] (inc 1))" 0)
  (evals-to "(do (def inc (fn [x] (+ x 100))) (inc 1))" 101)
  (evals-to "(let* [if 1] (if true 2 3))" 2)
  (compile-fails "(undefined-fn 1)" "unable to resolve symbol `undefined-fn`" :line 1 :column 2)
  (compile-fails "no.such.ns/x" "no namespace `no.such.ns`")
  (compile-fails "skein.core/no-such-var" "no var `no-such-var` in namespace `skein.core`")
  (compile-fails "if" "unable to resolve symbol `if`"))

;;; Built-in macros

(test builtin-macros
  (evals-to "(when true 1 2)" 2)
  (is (null (ev "(when false 1)")))
  (evals-to "(when-not false 1 2)" 2)
  (is (null (ev "(when-not true 1)")))
  (evals-to "(cond false 1 nil 2 :else 3)" 3)
  (evals-to "(cond (= 1 1) :a :else :b)" (kw "a"))
  (is (null (ev "(cond false 1)")))
  (evals-to "(and)" t)
  (evals-to "(and 1 2 3)" 3)
  (is (null (ev "(and 1 nil 3)")))
  (is (skein-false-p (ev "(and 1 false 3)")))
  (is (null (ev "(or)")))
  (evals-to "(or nil false 3)" 3)
  (is (skein-false-p (ev "(or nil false)")))
  (evals-to "(let [x 1 y 2] (+ x y))" 3)
  (evals-to "(loop [i 0] (if (< i 5) (recur (inc i)) i))" 5)
  (evals-to "(do (defn add [a b] (+ a b)) (add 2 3))" 5)
  (evals-to "(do (defn f ([x] (f x 10)) ([x y] (+ x y))) (f 1))" 11)
  (let ((ns (fresh-ns)))
    (ev "(defn documented \"Docs.\" {:added 1} [x] x) (defn- hidden [] 1)" :namespace ns)
    (let ((d (skein.runtime:find-own-var (skein.runtime:find-namespace ns) "documented"))
          (h (skein.runtime:find-own-var (skein.runtime:find-namespace ns) "hidden")))
      (is (string= "Docs." (skein.runtime:var-doc d)))
      (is (skein.runtime:var-private-p h))
      (is (string= "hidden" (skein.runtime::function-display-name
                             (skein.runtime:var-value h))))))
  (compile-fails "(cond 1)" "cond needs an even number of forms")
  (compile-fails "(when)" "wrong number of arguments (0) passed to macro skein.core/when"
                 :line 1 :column 1))

(test macroexpand
  (let ((env (skein.expander:make-env :namespace (skein.runtime:ensure-namespace "user"))))
    (multiple-value-bind (form expanded)
        (skein.expander:macroexpand-1 (rd "(when a b c)") env)
      (is (eq t expanded))
      (is (string= "(if a (do b c))" (skein.syntax:syntax-to-string form))))
    (multiple-value-bind (form expanded) (skein.expander:macroexpand-1 (rd "(f a)") env)
      (is (null expanded))
      (is (string= "(f a)" (skein.syntax:syntax-to-string form))))
    (is (string= "(let* [x 1] x)"
                 (skein.syntax:syntax-to-string
                  (skein.expander:macroexpand (rd "(let [x 1] x)") env))))))

;;; Namespaces

(test ns-and-top-level-do
  (let ((name (fresh-ns)))
    (ev (format nil "(ns ~A) (def answer 42)" name))
    (is (= 42 (skein.runtime:var-value
               (skein.runtime:find-own-var (skein.runtime:find-namespace name) "answer"))))
    (is (skein.runtime:namespace-loaded-p (skein.runtime:find-namespace name))))
  (let ((name (fresh-ns)))
    (ev (format nil "(do (ns ~A) (def answer 43))" name))
    (is (skein.runtime:find-own-var (skein.runtime:find-namespace name) "answer")
        "the forms after ns in a top-level do are in the new namespace"))
  (let ((name (fresh-ns)))
    (is (eq (kw "k" name) (ev (format nil "(ns ~A) ::k" name)))
        "::kw after ns uses the new namespace"))
  (compile-fails "(ns)" "ns needs a namespace name")
  (compile-fails "(ns a.b (:use c))" "unknown ns clause")
  (compile-fails "(ns a.b (:require [c :bogus d]))" "unknown require option :bogus"))

(defmacro with-source-tree ((dir &rest files) &body body)
  "Write FILES, a list of (relative-path contents), under a fresh temporary DIR, and run
BODY with *SOURCE-PATHS* set to it."
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "skein-test-~D/"
                                         (random 1000000000 (make-random-state t)))
                                 (uiop:temporary-directory)))))
     (unwind-protect
          (progn
            (loop for (path contents) in (list ,@(mapcar (lambda (f) `(list ,@f)) files))
                  do (let ((full (merge-pathnames path ,dir)))
                       (ensure-directories-exist full)
                       (with-open-file (s full :direction :output :if-exists :supersede
                                               :external-format :utf-8)
                         (write-string contents s))))
            (let ((skein.runtime:*source-paths* (list ,dir)))
              ,@body))
       (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))

(test require
  (let ((lib (fresh-ns)))
    (with-source-tree (dir ((format nil "~A.skn" (substitute #\/ #\. lib))
                            (format nil "(ns ~A) (defn twice [x] (* 2 x)) (defn- secret [] 1)
                                         (def loads (fn [] :loaded))" lib)))
      (evals-to (format nil "(ns ~A (:require [~A :as u :refer [twice]]))
                             (+ (u/twice 1) (twice 10))"
                        (fresh-ns) lib)
                22)
      (evals-to (format nil "(ns ~A (:require ~A)) (~A/twice 4)" (fresh-ns) lib lib) 8)
      (is (eq (kw "k" lib) (ev (format nil "(ns ~A (:require [~A :as u])) ::u/k" (fresh-ns) lib)))
          "::alias/kw resolves the alias")
      (compile-fails (format nil "(ns ~A (:require [~A :as u])) (u/secret)" (fresh-ns) lib)
                     "is private")
      (fails (format nil "(ns ~A (:require [~A :refer [secret]]))" (fresh-ns) lib)
             "is private" :type 'skein.runtime:namespace-error)
      (fails (format nil "(ns ~A (:require [~A :refer [nope]]))" (fresh-ns) lib)
             "does not exist" :type 'skein.runtime:namespace-error)
      (fails (format nil "(ns ~A (:require [no.such.lib]))" (fresh-ns))
             "cannot find namespace no.such.lib: no no/such/lib.skn in"
             :type 'skein.runtime:namespace-error))))

(test require-loads-once-and-retries-after-failure
  (let ((good (fresh-ns)) (bad (fresh-ns)))
    (with-source-tree (dir ((format nil "~A.skn" (substitute #\/ #\. good))
                            (format nil "(ns ~A) (println \"loading\")" good))
                           ((format nil "~A.skn" (substitute #\/ #\. bad))
                            (format nil "(ns ~A) (undefined-thing)" bad)))
      (is (string= (format nil "loading~%")
                   (ev-output (format nil "(ns ~A (:require ~A)) (ns ~A (:require ~A))"
                                      (fresh-ns) good (fresh-ns) good))))
      (fails (format nil "(ns ~A (:require ~A))" (fresh-ns) bad) "unable to resolve symbol")
      (is (not (skein.runtime:namespace-loaded-p (skein.runtime:find-namespace bad))))
      (fails (format nil "(ns ~A (:require ~A))" (fresh-ns) bad) "unable to resolve symbol"))))

;;; Redefinition (the M0.3 exit criterion)

(test redefining-a-defn-changes-existing-callers
  (let ((ns (fresh-ns)))
    (ev "(defn greeting [] \"hello\")
         (defn greet [] (greeting))" :namespace ns)
    (is (string= "hello" (ev "(greet)" :namespace ns)))
    (ev "(defn greeting [] \"goodbye\")" :namespace ns)
    (is (string= "goodbye" (ev "(greet)" :namespace ns))
        "greet was compiled before the redefinition but calls through the var")
    ;; A function value captured before redefinition also sees the new definition.
    (let ((greet (ev "greet" :namespace ns)))
      (ev "(defn greeting [] \"again\")" :namespace ns)
      (is (string= "again" (funcall greet))))))

;;; Primitives in skein.core

(test arithmetic-follows-numeric-contagion
  (evals-to "(+ 1 2)" 3)
  (evals-to "(+)" 0)
  (evals-to "(- 5)" -5)
  (evals-to "(* 2 3 4)" 24)
  (evals-to "(/ 1 2)" 0.5d0)
  (evals-to "(/ 6 3)" 2.0d0)
  (evals-to "(/ 1.0f 2)" 0.5f0)
  (evals-to "(+ 1 2.5f)" 3.5f0)
  (evals-to "(+ 1.5f 2.5)" 4.0d0)
  (evals-to "(quot 7 2)" 3)
  (evals-to "(quot -7 2)" -3)
  (evals-to "(rem -7 2)" -1)
  (evals-to "(mod -7 2)" 1)
  (evals-to "(* 99999999999 99999999999)" 9999999999800000000001)
  (evals-to "(max 1 5 3)" 5)
  (evals-to "(abs -2)" 2))

(test comparisons-return-skein-booleans
  (evals-to "(< 1 2 3)" t)
  (is (skein-false-p (ev "(< 1 3 2)")))
  (evals-to "(= 1 1)" t)
  (is (skein-false-p (ev "(= 1 1.0)")) "= separates integers and floats")
  (evals-to "(== 1 1.0)" t)
  (evals-to "(= \"a\" \"a\")" t)
  (evals-to "(= :k :k)" t)
  (evals-to "(not= 1 2)" t)
  (evals-to "(not nil)" t)
  (is (skein-false-p (ev "(not 0)")))
  (evals-to "(zero? 0)" t)
  (evals-to "(nil? nil)" t)
  (is (skein-false-p (ev "(nil? false)")))
  (evals-to "(false? false)" t)
  (evals-to "(identical? :a :a)" t)
  ;; Regression: comparing NaN trapped on x86-64 instead of returning false.
  (is (skein-false-p (ev "(= ##NaN ##NaN)")))
  (is (skein-false-p (ev "(== ##NaN ##NaN)")))
  (is (skein-false-p (ev "(< ##NaN 1.0)")))
  (is (skein-false-p (ev "(>= 1.0 ##NaN)")))
  (is (skein-false-p (ev "(zero? ##NaN)")))
  (is (skein-false-p (ev "(= [##NaN] [##NaN])"))))

(test printing
  (is (string= (format nil "1 a :k nil true false \\b~%")
               (ev-output "(println 1 \"a\" :k nil true false \"\\\\b\")")))
  (is (string= (format nil "\"a\" \\c nil~%") (ev-output "(prn \"a\" \\c nil)")))
  (is (string= "ab1:knil" (ev "(str \"a\" \\b 1 :k nil \"nil\")")))
  (is (string= "\"a\" 1" (ev "(pr-str \"a\" 1)")))
  (is (string= "#<fn inc-ish>" (ev "(str (fn inc-ish [x] x))")))
  (is (search "#'test.ns" (ev "(str (def v 1))"))))

;;; Example programs (examples/*.skn with a matching .expected file)

(defun example-files ()
  (directory (merge-pathnames "examples/*.skn"
                              (uiop:pathname-parent-directory-pathname
                               (asdf:system-source-directory "skein")))))

(test examples
  (let ((files (example-files)))
    (is (>= (length files) 2) "examples/ should hold at least hello.skn and fib.skn")
    (dolist (file files)
      (let ((expected (make-pathname :type "expected" :defaults file)))
        (when (probe-file expected)
          (is (string= (uiop:read-file-string expected :external-format :utf-8)
                       (with-output-to-string (*standard-output*)
                         (skein.backend.cl:run-file file)))
              "~A printed the wrong output" (file-namestring file)))))))
