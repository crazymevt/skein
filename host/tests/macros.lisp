;;;; Tests for M0.5: defmacro, syntax-quote, phase tracking, the core macros written in
;;;; lib/skein/core.skn, and destructuring.

(in-package #:skein.tests)

(def-suite skein.macros :in all
  :description "defmacro, syntax-quote, phases, core macros and destructuring.")

(in-suite skein.macros)

(defun evp (source)
  "Evaluate SOURCE in a fresh namespace and return the printed result."
  (pr (ev source)))

(defmacro evp-is (source expected)
  `(is (string= ,expected (evp ,source)) "~S gave ~A, expected ~A" ,source (evp ,source) ,expected))

;;; skein.core is loaded from Skein source

(test core-macros-come-from-core-skn
  (let ((when-var (skein.runtime:find-own-var skein.runtime:+core+ "when")))
    (is (eq t (skein.runtime:var-macro-p when-var)) "when is a macro written in Skein")
    (is (search "If test is true" (skein.runtime:var-doc when-var)))
    (is (eq :syntax (skein.runtime:var-macro-p
                     (skein.runtime:find-own-var skein.runtime:+core+ "defmacro")))
        "defmacro is one of the built-in bootstrap macros")))

;;; defmacro

(test defmacro-basics
  (evp-is "(defmacro unless [test & body] `(if ~test nil (do ~@body))) (unless false 1 2)" "2")
  (evp-is "(defmacro unless [test & body] `(if ~test nil (do ~@body))) (unless true 1)" "nil")
  (evp-is "(defmacro m \"Docs.\" [] 42) (m)" "42")
  (evp-is "(defmacro m ([] 0) ([x] x) ([x & more] (count more))) [(m) (m 5) (m 1 2 3)]"
          "[0 5 2]")
  (evp-is "(defmacro nothing [] nil) (nothing)" "nil")
  (evp-is "(defmacro form-of [& args] (list 'quote &form)) (form-of 1 2)" "(form-of 1 2)")
  (evp-is "(defmacro locals [] (list 'quote (vec (sort (map name (keys &env))))))
           (let [a 1 b 2] (locals))"
          "[\"a\" \"b\"]")
  (evp-is "(defmacro defconst [name v] `(def ~name ~v)) (defconst answer 42) answer" "42")
  (evp-is "(defmacro m [[a b]] `(+ ~a ~b)) (m [1 2])" "3")
  (is (skein.runtime:var-p (ev "(defmacro m [] 1)"))))

(test macro-helpers-in-the-same-namespace
  (evp-is "(defn helper [x] (list 'inc x)) (defmacro m [x] (helper x)) (m 1)" "2"))

(test macro-errors-point-at-the-call
  (compile-fails "(defmacro m [x] (%error \"bad input:\" x)) (do (m 7))"
                 "bad input: 7 (in macro test.ns" :line 1 :column 46)
  (compile-fails "(defmacro m [x] x) (m)" "wrong number of arguments (0) passed to macro"
                 :line 1 :column 20)
  (compile-fails "(defmacro m [] (inc nil)) (m)" "error while expanding macro" :line 1 :column 27)
  (compile-fails "(defmacro)" "defmacro needs a name")
  (compile-fails "(defmacro m)" "defmacro needs a parameter vector")
  (compile-fails "(defmacro m (x) 1)" "defmacro parameters must be a vector, not x")
  (compile-fails "(defmacro m 5)" "expected an arity"))

(test locations-survive-macro-expansion
  ;; The undefined symbol keeps its own location although the macro rebuilt the form.
  (compile-fails "(defmacro unless [t & body] `(if ~t nil (do ~@body)))
(unless false (+ 1 undefined-thing))"
                 "unable to resolve symbol `undefined-thing`" :line 2 :column 20)
  ;; Code the macro made up gets the location of the macro call.
  (compile-fails "(defmacro bad [] '(no-such-fn))
  (bad)"
                 "unable to resolve symbol `no-such-fn`" :line 2 :column 3))

(test metadata-survives-macro-expansion
  (let ((ns (fresh-ns)))
    (ev "(defmacro defp [name v] `(def ~name ~v)) (defp ^:private secret 1)" :namespace ns)
    (is (skein.runtime:var-private-p
         (skein.runtime:find-own-var (skein.runtime:find-namespace ns) "secret"))))
  (evp-is "(let [^:mutable n 1] (set! n 5) n)" "5"))

;;; syntax-quote

(test syntax-quote
  (let ((ns (fresh-ns)))
    (is (string= (format nil "(~A/a skein.core/inc if 3 4 5)" ns)
                 (pr (ev "`(a inc if ~(+ 1 2) ~@[4 5])" :namespace ns))))
    (is (string= (format nil "~A/defined" ns)
                 (pr (ev "(def defined 1) `defined" :namespace ns)))))
  (evp-is "`[1 ~(inc 1)]" "[1 2]")
  (evp-is "`{:a ~(inc 1)}" "{:a 2}")
  (evp-is "(= `#{~(inc 1)} #{2})" "true")
  (let ((ns (fresh-ns)))
    (is (string= (format nil "(fn [& ~A/xs] (let* [~A/y 1] (recur)))" ns ns)
                 (pr (ev "`(fn [& xs] (let* [y 1] (recur)))" :namespace ns)))
        "special forms and & stay unqualified; other symbols are qualified"))
  (evp-is "`(skein.core/x ~@nil)" "(skein.core/x)")
  (evp-is "`()" "()")
  (evp-is "`:k" ":k")
  (evp-is "`5" "5")
  (evp-is "(let [[a b] `[x# x#]] (= a b))" "true")
  (evp-is "(= `x# `x#)" "false"))

(test syntax-quote-resolves-aliases
  (let ((lib (fresh-ns)))
    (with-source-tree (dir ((format nil "~A.skn" (substitute #\/ #\. lib))
                            (format nil "(ns ~A) (defn f [] 1)" lib)))
      (is (string= (format nil "~A/f" lib)
                   (pr (ev (format nil "(ns ~A (:require [~A :as l])) `l/f" (fresh-ns) lib))))))))

(test unquote-outside-syntax-quote
  (compile-fails "~x" "~ (unquote) is only allowed inside syntax-quote")
  (compile-fails "(inc ~@xs)" "~@ (unquote-splicing) is only allowed inside syntax-quote")
  (compile-fails "`~@xs" "~@ is only allowed directly inside a list"))

(test nested-syntax-quote
  ;; The inner syntax-quote is expanded first; the outer one quotes the code it produces.
  (evp-is "(first ``a)" "quote"))

;;; Phase tracking (DESIGN §4.4, D-033)

(defun phase-warnings-of (source)
  (let ((warnings '()))
    (handler-bind ((skein.runtime:phase-warning
                     (lambda (w) (push (princ-to-string w) warnings) (muffle-warning w))))
      (ev source))
    warnings))

(test phase-tracking
  (let ((runtime-lib (fresh-ns)) (syntax-lib (fresh-ns)) (deep (fresh-ns)))
    (with-source-tree (dir ((format nil "~A.skn" (substitute #\/ #\. runtime-lib))
                            (format nil "(ns ~A) (defn helper [x] x)" runtime-lib))
                           ((format nil "~A.skn" (substitute #\/ #\. deep))
                            (format nil "(ns ~A) (defn deep-helper [x] x)" deep))
                           ((format nil "~A.skn" (substitute #\/ #\. syntax-lib))
                            (format nil "(ns ~A (:require [~A :as d]))
                                         (defn helper [x] (d/deep-helper x))"
                                    syntax-lib deep)))
      (let ((w (phase-warnings-of
                (format nil "(ns ~A (:require [~A :as r])) (defmacro m [x] (r/helper x)) (m 1)"
                        (fresh-ns) runtime-lib))))
        (is (= 1 (length w)))
        (is (search (format nil "uses ~A/helper while expanding; require ~A with ~
                                 :require-for-syntax"
                            runtime-lib runtime-lib)
                    (first w))))
      (is (null (phase-warnings-of
                 (format nil "(ns ~A (:require-for-syntax [~A :as s])) (defmacro m [x] (s/helper x))
                              (m 1)"
                         (fresh-ns) syntax-lib)))
          "a namespace required for syntax, and what it requires, may be used")
      (is (null (phase-warnings-of "(defn h [x] x) (defmacro m [x] (h (inc x))) (m 1)"))
          "skein.core and the macro's own namespace may be used"))))

;;; Core macros

(test conditionals
  (evp-is "(comment (undefined) 1 2)" "nil")
  (evp-is "(when true 1 2)" "2")
  (evp-is "(when-not false 3)" "3")
  (evp-is "(if-not false :a :b)" ":a")
  (evp-is "(if-not true :a)" "nil")
  (evp-is "(cond nil 1 false 2 :else 3)" "3")
  (evp-is "(cond)" "nil")
  (compile-fails "(cond 1)" "cond needs an even number of forms (in macro skein.core/cond)")
  (evp-is "[(and) (and 1 2) (and 1 nil 2) (or) (or nil 2) (or false nil)]"
          "[true 2 nil nil 2 nil]")
  (evp-is "(let [^:mutable n 0] (and (do (set! n 1) false) (set! n 2)) n)" "1")
  (evp-is "(if-let [x 5] (* x 2) :no)" "10")
  (evp-is "(if-let [x false] :yes :no)" ":no")
  (evp-is "(if-let [[a b] [1 2]] (+ a b))" "3")
  (evp-is "(when-let [x 4] (inc x))" "5")
  (evp-is "(if-some [x false] [x] :none)" "[false]")
  (evp-is "(when-some [x nil] :yes)" "nil")
  (compile-fails "(if-let [a 1 b 2] a)" "if-let needs a binding vector"))

(test case-macro
  (evp-is "(case 2 1 :one (2 3) :two-or-three :other)" ":two-or-three")
  (evp-is "(case :b :a 1 :b 2)" "2")
  (evp-is "(case 'x x :sym y :other)" ":sym")
  (evp-is "(case \"s\" \"s\" :str :no)" ":str")
  (evp-is "(case 7 1 :one :default)" ":default")
  (evp-is "(case [1 2] [1 2] :vec :no)" ":vec")
  (fails "(case 7 1 :one)" "no case clause matches 7"))

(test threading
  (evp-is "(-> 5 inc (* 2) (- 1))" "11")
  (evp-is "(-> {:a {:b 1}} :a :b)" "1")
  (evp-is "(->> (range 5) (map inc) (filter odd?) (reduce +))" "9")
  (evp-is "(-> 1)" "1")
  (evp-is "(as-> 2 x (* x x) (+ x 1))" "5")
  (evp-is "(as-> 2 x)" "2")
  (evp-is "(some-> {:a {:b 2}} :a :b inc)" "3")
  (evp-is "(some-> {:a nil} :a :b inc)" "nil")
  (evp-is "(some->> [1 2] (map inc) (reduce +))" "5")
  (evp-is "(some->> nil (map inc))" "nil")
  (evp-is "(persistent! (doto (transient []) (conj! 1) (conj! 2)))" "[1 2]"))

(test loops
  (evp-is "(let [^:mutable i 0] (while (< i 5) (set! i (inc i))) i)" "5")
  (evp-is "(let [^:mutable s 0] (dotimes [i 4] (set! s (+ s i))) s)" "6")
  (evp-is "(dotimes [i 3] i)" "nil")
  (evp-is "(loop [i 0] (if (< i 3) (recur (inc i)) i))" "3")
  (evp-is "(loop [[x & more] [1 2 3] total 0] (if x (recur more (+ total x)) total))" "6")
  (evp-is "(loop [[a b] [1 2] c (+ a b)] c)" "3")
  (evp-is "(letfn [(ev? [n] (if (zero? n) true (od? (dec n))))
                   (od? [n] (if (zero? n) false (ev? (dec n))))]
            (ev? 10))"
          "true"))

(defun collected (source)
  "Evaluate SOURCE with `out` bound to a transient vector; return the collected values."
  (evp (format nil "(let [out (transient [])] ~A (persistent! out))" source)))

(test doseq-macro
  (is (string= "[1 2 3]" (collected "(doseq [x [1 2 3]] (conj! out x))")))
  (is (string= "[[1 :a] [1 :b] [2 :a] [2 :b]]"
               (collected "(doseq [x [1 2] y [:a :b]] (conj! out [x y]))")))
  (is (string= "[1 3]" (collected "(doseq [x (range 5) :when (odd? x)] (conj! out x))")))
  (is (string= "[0 1 2]" (collected "(doseq [x (range) :while (< x 3)] (conj! out x))")))
  (is (string= "[[2 1] [3 1] [3 2]]"
               (collected "(doseq [x [1 2 3] y [1 2 3] :while (< y x)] (conj! out [x y]))")))
  (is (string= "[10 20]" (collected "(doseq [x [1 2] :let [y (* 10 x)]] (conj! out y))")))
  (is (string= "[3 7]" (collected "(doseq [[a b] [[1 2] [3 4]]] (conj! out (+ a b)))")))
  (is (string= "[[:a 1]]" (collected "(doseq [[k v] {:a 1}] (conj! out [k v]))")))
  (evp-is "(doseq [x []] x)" "nil")
  (compile-fails "(doseq [x] 1)" "doseq needs a vector with an even number of forms"))

(test for-macro
  (evp-is "(for [x [1 2 3]] (* x x))" "(1 4 9)")
  (evp-is "(for [x [1 2] y [:a :b]] [x y])" "([1 :a] [1 :b] [2 :a] [2 :b])")
  (evp-is "(for [x (range 6) :when (even? x)] x)" "(0 2 4)")
  (evp-is "(for [x (range) :while (< x 3)] x)" "(0 1 2)")
  (evp-is "(for [x [1 2 3] y [1 2 3] :while (< y x)] [x y])" "([2 1] [3 1] [3 2])")
  (evp-is "(for [x [1 2] :let [y (inc x)]] y)" "(2 3)")
  (evp-is "(for [[a b] [[1 2] [3 4]]] (+ a b))" "(3 7)")
  (evp-is "(take 3 (for [x (range) y (range x)] [x y]))" "([1 0] [2 0] [2 1])")
  (evp-is "(for [x []] x)" "()")
  (evp-is "(let [^:mutable n 0 s (for [x (range 10)] (do (set! n (inc n)) x))] (first s) n)"
          "1"))

(test lazy-seq-macro-in-core
  (evp-is "(do (defn nats [n] (lazy-seq (cons n (nats (inc n))))) (take 3 (nats 0)))" "(0 1 2)"))

;;; Destructuring (DESIGN §5.4)

(test vector-destructuring
  (evp-is "(let [[a b] [1 2]] [a b])" "[1 2]")
  (evp-is "(let [[a b] [1]] [a b])" "[1 nil]")
  (evp-is "(let [[a & more] [1 2 3]] [a more])" "[1 (2 3)]")
  (evp-is "(let [[a & more] [1]] more)" "nil")
  (evp-is "(let [[a :as all] [1 2]] all)" "[1 2]")
  (evp-is "(let [[a b & more :as all] '(1 2 3)] [a b more all])" "[1 2 (3) (1 2 3)]")
  (evp-is "(let [[a [b c]] [1 [2 3]]] [a b c])" "[1 2 3]")
  (evp-is "(let [[a b] \"xy\"] [a b])" "[\\x \\y]")
  (evp-is "(let [[a b] nil] [a b])" "[nil nil]")
  (evp-is "(let [[_ _ c] (range)] c)" "2"))

(test map-destructuring
  (evp-is "(let [{:keys [a b]} {:a 1 :b 2}] [a b])" "[1 2]")
  (evp-is "(let [{:keys [a b] :or {b 9}} {:a 1}] [a b])" "[1 9]")
  (evp-is "(let [{:keys [a] :or {a 9}} {:a false}] a)" "false")
  (evp-is "(let [{:keys [a] :as m} {:a 1}] m)" "{:a 1}")
  (evp-is "(let [{:strs [a]} {\"a\" 1}] a)" "1")
  (evp-is "(let [{:syms [a]} {'a 1}] a)" "1")
  (evp-is "(let [{x :x [y] :ys} {:x 1 :ys [2]}] [x y])" "[1 2]")
  (evp-is "(let [{:keys [g/a]} {:g/a 1}] a)" "1")
  (evp-is "(let [{:g/keys [a b]} {:g/a 1 :g/b 2}] [a b])" "[1 2]")
  (evp-is "(let [{:keys [:a]} {:a 3}] a)" "3")
  (evp-is "(let [{:keys [a]} nil] a)" "nil")
  (evp-is "(let [[{:keys [a]}] [{:a 5}]] a)" "5")
  (evp-is "(let [{[x] :v} {:v [7]}] x)" "7")
  (evp-is "((fn [& {:keys [a b]}] [a b]) :a 1 :b 2)" "[1 2]"))

(test destructuring-in-fn-loop-and-friends
  (evp-is "((fn [[a b] {:keys [c]}] [a b c]) [1 2] {:c 3})" "[1 2 3]")
  (evp-is "((fn [x & [y z]] [x y z]) 1 2 3)" "[1 2 3]")
  (evp-is "((fn self [[n & more] acc] (if n (recur more (+ acc n)) acc)) [1 2 3] 0)" "6")
  (evp-is "(do (defn f [{:keys [a]}] a) (f {:a 7}))" "7")
  (evp-is "(map (fn [[k v]] (+ k v)) {1 2})" "(3)")
  (evp-is "(#(let [[a b] %] (+ a b)) [1 2])" "3"))

(test destructuring-errors
  (compile-fails "(let [5 1] 1)" "unsupported binding form: 5")
  (compile-fails "(let [[a &] [1]] a)" "& must be followed by a binding")
  (compile-fails "(let [[a :as] [1]] a)" ":as must be followed by a symbol")
  (compile-fails "(let [a] a)" "a binding vector needs an even number of forms")
  (compile-fails "(let [{:keys a} {}] a)" ":keys needs a vector of names")
  (compile-fails "(let (a 1) a)" "bindings must be a vector"))

;;; macroexpand

(test macroexpand-functions
  (evp-is "(macroexpand-1 '(when a b))" "(if a (do b))")
  (evp-is "(macroexpand-1 '(f a))" "(f a)")
  (evp-is "(macroexpand '(when-not a b))" "(if a nil (do b))")
  (evp-is "(macroexpand '(-> a b c))" "(c (b a))")
  (evp-is "(macroexpand-all '(when a (when b c)))" "(if a (do (if b (do c))))")
  (evp-is "(macroexpand-all '(quote (when a b)))" "(quote (when a b))"))
