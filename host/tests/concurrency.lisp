;;;; Tests for concurrency (DESIGN §13, M0.9), including stress tests that repeat each
;;;; scenario 100 times.

(in-package #:skein.tests)

(def-suite skein.concurrency :in all
  :description "Tasks, nurseries, futures, cancellation, channels and parallelism.")

(in-suite skein.concurrency)

(defparameter *stress-runs* 100
  "How many times each stress test repeats its scenario (ROADMAP M0.9).")

(defmacro stress (name source expected)
  "Evaluate SOURCE (in one namespace) *STRESS-RUNS* times; each run must print EXPECTED."
  `(test ,name
     (let ((ns (fresh-ns)) (failures 0) (first-bad nil))
       (dotimes (i *stress-runs*)
         (let ((got (handler-case (pr (ev ,source :namespace ns))
                      (error (e) (format nil "ERROR: ~A" e)))))
           (unless (string= got ,expected)
             (incf failures)
             (unless first-bad (setf first-bad got)))))
       (is (zerop failures) "~D of ~D runs failed; first got ~A, expected ~A"
           failures *stress-runs* first-bad ,expected))))

;;; Nurseries and spawn

(test nursery-waits-for-its-tasks
  (evp-is "(let [a (atom [])]
             (with-nursery [n]
               (spawn n (sleep 0.02) (swap! a conj :slow))
               (spawn n (swap! a conj :fast)))
             (sort @a))"
          "(:fast :slow)")
  (evp-is "(with-nursery [n] (let [t (spawn n (+ 1 2))] (* 10 @t)))" "30")
  (evp-is "(with-nursery [n] :body-value)" ":body-value")
  (fails "(spawn 5 1)" "spawn needs a nursery"))

(test failing-task-cancels-siblings-and-propagates
  (evp-is "(let [sleeper (atom nil)]
             [(try (with-nursery [n]
                     (reset! sleeper (spawn n (sleep 10) :never))
                     (spawn n (error \"boom\")))
                (catch error e (condition-message e)))
              (cancelled? @sleeper)])"
          "[\"boom\" true]")
  ;; The body is cancelled too, and the child's error wins.
  (evp-is "(try (with-nursery [n]
                  (spawn n (error \"child failed\"))
                  (sleep 10)
                  :body-finished)
             (catch error e (condition-message e)))"
          "\"child failed\"")
  ;; An error in the body cancels the children.
  (evp-is "(let [t (atom nil)]
             [(try (with-nursery [n] (reset! t (spawn n (sleep 10))) (error \"body failed\"))
                (catch error e (condition-message e)))
              (cancelled? @t)])"
          "[\"body failed\" true]")
  ;; Errors propagate through nested nurseries.
  (evp-is "(try (with-nursery [outer]
                  (spawn outer (with-nursery [inner] (spawn inner (error \"deep\")))))
             (catch error e (condition-message e)))"
          "\"deep\""))

(test cancellation-is-not-an-error
  ;; A handler for error inside the task does not swallow the cancellation.
  (evp-is "(let [t (atom nil)]
             (try (with-nursery [n]
                    (reset! t (spawn n (try (sleep 10) (catch error e :swallowed))))
                    (spawn n (error \"x\")))
               (catch error e nil))
             (cancelled? @t))"
          "true"))

;;; Futures

(test futures
  (evp-is "@(future (+ 1 2))" "3")
  (evp-is "(let [f (future (sleep 0.05) :done)] [(deref f 0.001 :not-yet) @f (done? f)])"
          "[:not-yet :done true]")
  (evp-is "(let [f (future (error \"in future\"))]
             (try @f (catch error e (condition-message e))))"
          "\"in future\"")
  (evp-is "(let [f (future (sleep 10))] [(cancel! f) (try @f (catch task-cancelled-error e :c))])"
          "[true :c]")
  (evp-is "(task? (future 1))" "true")
  (fails "@5" "deref (@) needs an atom or a task"))

;;; Cancellation points and timeouts

(test cooperative-cancellation
  (evp-is "(let [f (future (loop [i 0] (check-cancelled) (recur (inc i))))]
             (sleep 0.01)
             (cancel! f)
             (try @f (catch task-cancelled-error e :stopped)))"
          ":stopped"))

(test timeouts
  (evp-is "(try (with-timeout 0.02 (sleep 5) :finished) (catch timeout e (condition-message e)))"
          "\"timed out after 0.02 seconds\"")
  (evp-is "(with-timeout 1.0 :quick)" ":quick")
  ;; Tasks spawned inside with-timeout are cancelled with it.
  (evp-is "(try (with-timeout 0.02 (with-nursery [n] (spawn n (sleep 5))))
             (catch timeout e :timed-out))"
          ":timed-out")
  (evp-is "(try (with-timeout 0.02 (<! (chan))) (catch timeout e :timed-out))" ":timed-out")
  (fails "(sleep -1)" "sleep needs a non-negative number of seconds"))

;;; Channels

(test channels
  (evp-is "(let [ch (chan 2)] (>! ch 1) (>! ch 2) (close! ch) [(<! ch) (<! ch) (<! ch) (>! ch 3)])"
          "[1 2 nil false]")
  (evp-is "(let [ch (chan)] (future (>! ch :hi)) (<! ch))" ":hi")
  (evp-is "(let [ch (chan) taken (atom false)]
             (let [putter (future (>! ch :v) @taken)]
               (sleep 0.02)
               (reset! taken true)
               (<! ch)
               @putter))"
          "true")
  (evp-is "(let [a (chan) b (chan 1)] (>! b :from-b) (first (alts! [a b])))" ":from-b")
  (evp-is "(let [ch (chan 1)] (first (alts! [[ch :put-value]])))" "true")
  (evp-is "(let [ch (chan 1)] (alts! [[ch :x]]) (<! ch))" ":x")
  (evp-is "(let [t (timeout-chan 0.01)] (first (alts! [(chan) t])))" "nil")
  (evp-is "(chan? (chan 3))" "true")
  (fails "(>! (chan 1) nil)" "cannot put nil on a channel")
  (fails "(<! 5)" "<! needs a channel")
  (fails "(chan -1)" "chan needs a non-negative buffer size")
  (fails "(alts! [5])" "alts! needs channels or [channel value] puts"))

;;; Data parallelism

(test data-parallelism
  (evp-is "(pmap inc (range 10))" "(1 2 3 4 5 6 7 8 9 10)")
  (evp-is "(pmap inc [])" "()")
  (evp-is "(preduce + 0 (range 1001))" "500500")
  (evp-is "(preduce + 0 [])" "0")
  (evp-is "(let [a (make-array i64 50)] (pdotimes [i 50] (aset! a i (* 2 i))) (reduce + (seq a)))"
          "2450")
  (evp-is "(try (pmap (fn [x] (if (= x 7) (error \"seven\") x)) (range 20))
             (catch error e (condition-message e)))"
          "\"seven\"")
  (fails "(pdotimes [i -1] i)" "pdotimes needs a non-negative count"))

;;; Threads

(test main-thread-affinity
  (evp-is "(on-main-thread :here)" ":here")
  ;; The main thread runs queued work while it waits on the future.
  (evp-is "@(future (on-main-thread :marshalled))" ":marshalled")
  (evp-is "(let [t (spawn-pinned :main (+ 1 1))] (drain-main-thread!) @t)" "2")
  (fails "(spawn-pinned :gpu 1)" "spawn-pinned supports only :main"))

(test tasks-inherit-context
  (is (string= (format nil "from a task~%")
               (with-output-to-string (*standard-output*)
                 (ev "(with-nursery [n] (spawn n (println \"from a task\")))"))))
  (evp-is "(defcondition local-oops [error])
           (try @(future (error 'local-oops)) (catch local-oops e :found-in-namespace))"
          ":found-in-namespace"))

(test tasks-get-a-copy-of-the-bindings
  ;; D-076: a task sees the bindings in force where it was spawned; its set! changes only
  ;; what it, and the tasks it spawns afterwards, see.
  (evp-is "(def ^:dynamic *x* 1)
           (binding [*x* 2]
             [(with-nursery [n]
                @(spawn n (let [before *x*]
                            (set! *x* 3)
                            [before *x* @(future *x*)])))
              *x*])"
          "[[2 3 3] 2]")
  (evp-is "(def ^:dynamic *x* 1)
           (binding [*x* 2]
             (let [f (future (sleep 0.05) *x*)]
               (set! *x* 5)
               [@f *x*]))"
          "[2 5]")
  (evp-is "(def ^:dynamic *x* 1) [@(future *x*) (binding [*x* 2] @(future (binding [*x* 3] *x*)))]"
          "[1 3]"))

(test worker-threads-do-not-trap-on-nan
  ;; Regression: each worker thread must mask the invalid-operation trap (D-036).
  (evp-is "@(future [(< ##NaN 1.0) (== ##NaN ##NaN)])" "[false false]"))

(test transients-stay-with-their-thread
  (evp-is "(let [t (transient [])]
             (try @(future (conj! t 1)) (catch transient-error e :refused)))"
          ":refused"))

;;; Job graphs

(test job-graphs
  (evp-is "(ns jg1 (:require [skein.jobs :as jobs :refer [job]]))
           (jobs/graph {:a (job 1) :b (job {:after [:a]} 2) :c (job {:after [:a :b]} 3)})"
          "{:a 1, :b 2, :c 3}")
  (evp-is "(ns jg2 (:require [skein.jobs :as jobs :refer [job]]))
           (try (jobs/graph {:a (job {:after [:b]} 1) :b (job {:after [:a]} 2)})
             (catch error e (condition-message e)))"
          "\"the job graph has a cycle among [:a :b]\"")
  (evp-is "(ns jg3 (:require [skein.jobs :as jobs :refer [job]]))
           (try (jobs/graph {:a (job {:after [:nope]} 1)}) (catch error e (condition-message e)))"
          "\"job :a depends on :nope which is not in the graph\"")
  (evp-is "(ns jg4 (:require [skein.jobs :as jobs :refer [job]]))
           (try (jobs/graph {:a (job (error \"job failed\")) :b (job (sleep 10))})
             (catch error e (condition-message e)))"
          "\"job failed\""))

;;; Stress tests: each scenario 100 times

(stress stress-nursery-atom-increments
  "(let [a (atom 0)]
     (with-nursery [n] (dotimes [i 20] (spawn n (dotimes [j 100] (swap! a inc)))))
     @a)"
  "2000")

(stress stress-buffered-producers-and-consumers
  "(let [ch (chan 4) total (atom 0)]
     (with-nursery [n]
       (let [producers (vec (for [p (range 4)] (spawn n (doseq [i (range 50)] (>! ch 1)))))]
         (dotimes [c 3] (spawn n (loop [] (when-let [v (<! ch)] (swap! total + v) (recur)))))
         (doseq [p producers] @p)
         (close! ch)))
     @total)"
  "200")

(stress stress-unbuffered-rendezvous
  "(let [ch (chan)]
     (with-nursery [n]
       (spawn n (dotimes [i 30] (>! ch i)) (close! ch))
       (loop [acc 0] (if-let [v (<! ch)] (recur (+ acc v)) acc))))"
  "435")

(stress stress-alts-collects-everything
  "(let [a (chan) b (chan 2)]
     (with-nursery [n]
       (spawn n (dotimes [i 20] (>! a 1)) (close! a))
       (spawn n (dotimes [i 20] (>! b 2)) (close! b))
       (loop [open #{a b} sum 0]
         (if (empty? open)
           sum
           (let [[v ch] (alts! (vec open))]
             (if (nil? v) (recur (disj open ch) sum) (recur open (+ sum v))))))))"
  "60")

(stress stress-failure-cancels-siblings
  "(let [sleepers (atom [])]
     [(try (with-nursery [n]
             (dotimes [i 6] (swap! sleepers conj (spawn n (sleep 10))))
             (spawn n (error \"stop\")))
        (catch error e (condition-message e)))
      (every? cancelled? @sleepers)])"
  "[\"stop\" true]")

(stress stress-data-parallelism-matches-sequential
  "(let [xs (vec (range 300))]
     [(= (pmap #(* % %) xs) (map #(* % %) xs))
      (= (preduce + 0 xs) (reduce + 0 xs))
      (let [a (make-array i64 300)] (pdotimes [i 300] (aset! a i i)) (= (vec (seq a)) xs))])"
  "[true true true]")

(stress stress-job-graph-respects-dependencies
  "(ns stress.jobs (:require [skein.jobs :as jobs :refer [job]]))
   (let [log (atom [])
         step (fn [k] (swap! log conj k) k)]
     (jobs/graph {:a (job (step :a))
                  :b (job {:after [:a]} (step :b))
                  :c (job {:after [:a]} (step :c))
                  :d (job {:after [:b :c]} (step :d))})
     (let [order @log]
       [(first order) (last order) (count order)]))"
  "[:a :d 4]")

(stress stress-timeouts-cancel-work
  "(try (with-timeout 0.005 (with-nursery [n] (spawn n (sleep 5)) (spawn n (<! (chan)))))
     (catch timeout e :timed-out))"
  ":timed-out")

(test timed-waits-keep-their-mutex
  ;; Regression: SBCL's CONDITION-WAIT can time out without re-acquiring its mutex, which
  ;; broke the worker pool under load in CI. Thread B's wait times out while A holds the
  ;; mutex; afterwards B must still hold it.
  (let ((m (sb-thread:make-mutex)) (q (sb-thread:make-waitqueue)) (held nil))
    (let ((b (sb-thread:make-thread
              (lambda ()
                (sb-thread:with-mutex (m)
                  (skein.runtime::timed-wait q m 0.02)
                  (setf held (sb-thread:holding-mutex-p m)))))))
      (sleep 0.005)
      (sb-thread:with-mutex (m) (sleep 0.1))
      (sb-thread:join-thread b)
      (is (eq t held)))))
