;;;; Tests for M0.12: numeric conversions, rand, skein.math, skein.time, the fixed-timestep
;;;; game loop, namespace roots and the Driftrock demo's rules (headless).

(in-package #:skein.tests)

(def-suite skein.math :in all
  :description "skein.math, conversions, clocks, the game loop and the demo game's rules.")

(in-suite skein.math)

(defun mev (source)
  "Evaluate SOURCE with skein.math required as m (vectors referred) and print the result."
  (pr (ev (format nil "(ns ~A (:require [skein.math :as m :refer [vec2 vec3 vec4 quat
                                                                  v+ v- v* dot]]))~%~A"
                  (fresh-ns) source)
          :namespace "user")))

(defmacro math-is (source expected)
  `(let ((got (mev ,source)))
     (is (string= ,expected got) "~S gave ~A, expected ~A" ,source got ,expected)))

(test conversions-and-rand
  (is (string= "[1.0f 1.5 3 -3 7 2.5f 2]" (pr (ev "[(f32 1) (f64 1.5f) (int 3.9) (int -3.9) (int 7)
                                                  (f32 2.5) (int 2.5f)]"))))
  (is (string= "[true true true true]"
               (pr (ev "[(every? #(and (<= 0 %) (< % 1)) (repeatedly 200 rand))
                         (every? #(< -1 % 5) (repeatedly 200 #(rand-int 5)))
                         (= #{0 1 2} (set (repeatedly 300 #(rand-int 3))))
                         (every? #(and (<= 0 %) (< % 2.5)) (repeatedly 100 #(rand 2.5)))]"))))
  (fails "(rand-int 0)" "rand-int needs a positive integer")
  (fails "(rand -1)" "rand needs a positive number"))

(test scalar-math
  ;; Floats keep their type; integers become f64.
  (math-is "[(m/sin 0) (m/sin 0.0f) (m/cos 0.0) (m/floor 2.7) (m/floor -2.5f) (m/ceil 2.1)
             (m/floor 3) (m/trunc -2.7)]"
           "[0.0 0.0f 1.0 2.0 -3.0f 3.0 3 -2.0]")
  ;; round: halves away from zero.
  (math-is "[(m/round 2.5) (m/round -2.5) (m/round 1.4f) (m/round 7)]" "[3.0 -3.0 1.0f 7]")
  (math-is "[(m/pow 2 10) (m/pow 2.0 0.5) (m/pow -8 0.5)]" "[1024 1.4142135623730951 ##NaN]")
  (math-is "[(m/asin 2.0) (m/log -1.0) (m/log 1.0) (m/exp 0.0)]" "[##NaN ##NaN 0.0 1.0]")
  (math-is "[(m/approx= (m/atan2 1 1) (/ m/pi 4)) (m/approx= (m/deg->rad 180) m/pi)
             (m/approx= (m/rad->deg m/tau) 360.0)]"
           "[true true true]")
  (math-is "[(m/clamp 5 0 3) (m/clamp -1 0 3) (m/lerp 0.0 10.0 0.25) (m/inverse-lerp 0.0 10.0 2.5)
             (m/remap 5.0 0.0 10.0 100.0 200.0) (m/smoothstep 0.0 1.0 0.5) (m/sign -3.5)
             (m/sign 0) (m/sign 4) (m/wrap -1.0 10.0) (m/wrap 12.5 10.0)]"
           "[3 0 2.5 0.25 150.0 0.5 -1.0 0 1 9.0 2.5]")
  (math-is "(every? (fn [_] (let [r (m/rand-range 2.0 3.0)] (and (<= 2.0 r) (< r 3.0))))
                    (range 50))"
           "true"))

(test noise
  ;; Deterministic, smooth, zero on the lattice, and within about [-1, 1].
  (math-is "[(= (m/noise 1.3 2.7) (m/noise 1.3 2.7)) (m/noise 1 2) (m/noise 1.0 2.0 3.0)
             (every? #(<= -1.1 % 1.1)
                     (for [i (range 200)] (m/noise (* i 0.37) (* i 0.19) (* i 0.11))))
             (< (abs (- (m/noise 0.5 0.5) (m/noise 0.501 0.5))) 0.01)
             (not= (m/noise 0.3 0.7) (m/noise 0.3 0.7 0.4))]"
           "[true 0.0 0.0 true true true]"))

(test vectors
  (math-is "[(v+ (vec2 1.0f 2.0f) (vec2 3.0f 4.0f)) (v- (vec3 1.0f 1.0f 1.0f) (vec3 1.0f 2.0f 3.0f))
             (v* (vec4 1.0f 2.0f 3.0f 4.0f) 2) (dot (vec3 1.0f 2.0f 3.0f) (vec3 4.0f 5.0f 6.0f))
             (m/length (vec2 3.0f 4.0f)) (m/length-sq (vec2 3.0f 4.0f))
             (m/distance (vec2 1.0f 1.0f) (vec2 4.0f 5.0f)) (m/negate (vec2 1.0f -2.0f))
             (m/vdiv (vec2 2.0f 4.0f) 2)]"
           (concatenate 'string
                        "[#<skein.math/vec2 {:x 4.0f, :y 6.0f}> "
                        "#<skein.math/vec3 {:x 0.0f, :y -1.0f, :z -2.0f}> "
                        "#<skein.math/vec4 {:x 2.0f, :y 4.0f, :z 6.0f, :w 8.0f}> "
                        "32.0f 5.0f 25.0f 5.0f #<skein.math/vec2 {:x -1.0f, :y 2.0f}> "
                        "#<skein.math/vec2 {:x 1.0f, :y 2.0f}>]"))
  (math-is "[(m/normalize (vec3 0.0f 0.0f 2.0f)) (m/normalize m/vec2-zero)
             (m/cross (vec3 1.0f 0.0f 0.0f) (vec3 0.0f 1.0f 0.0f))
             (m/perp (vec2 1.0f 0.0f)) (m/lerp (vec2 0.0f 0.0f) (vec2 10.0f 20.0f) 0.5)]"
           (concatenate 'string
                        "[#<skein.math/vec3 {:x 0.0f, :y 0.0f, :z 1.0f}> "
                        "#<skein.math/vec2 {:x 0.0f, :y 0.0f}> "
                        "#<skein.math/vec3 {:x 0.0f, :y 0.0f, :z 1.0f}> "
                        "#<skein.math/vec2 {:x -0.0f, :y 1.0f}> "
                        "#<skein.math/vec2 {:x 5.0f, :y 10.0f}>]"))
  (math-is "(let [v (m/rotate (vec2 1.0f 0.0f) (/ m/pi 2)) w (m/from-angle (/ m/pi 3) 2.0)]
              [(m/approx= (m/vec2-x v) 0.0) (m/approx= (m/vec2-y v) 1.0)
               (m/approx= (m/length w) 2.0) (m/approx= (m/angle w) (/ m/pi 3))])"
           "[true true true true]")
  (math-is "[(instance? vec2 (vec2 1.0f 1.0f)) (instance? vec3 (vec2 1.0f 1.0f))]"
           "[true false]"))

(test quaternions
  (math-is "(let [q (m/quat-from-axis-angle (vec3 0.0f 0.0f 1.0f) (/ m/pi 2))
                  v (m/quat-rotate q (vec3 1.0f 0.0f 0.0f))
                  qq (m/m* q q)
                  w (m/quat-rotate qq (vec3 1.0f 0.0f 0.0f))
                  back (m/quat-rotate (m/inverse q) v)
                  half (m/quat-rotate (m/slerp m/quat-identity q 0.5) (vec3 1.0f 0.0f 0.0f))]
              (mapv #(m/approx= % %2 1e-5)
                    [(m/vec3-x v) (m/vec3-y v) (m/vec3-x w) (m/vec3-x back) (m/vec3-y half)]
                    [0.0 1.0 -1.0 1.0 (m/sin (/ m/pi 4))]))"
           "[true true true true true]"))

(test matrices
  ;; 2D: translate after rotating, invert, and the determinant.
  (math-is "(let [t (m/m* (m/mat3-translation 10 0) (m/mat3-rotation (/ m/pi 2)))
                  p (m/transform-point t (vec2 1.0f 0.0f))
                  q (m/transform-point (m/inverse t) p)
                  d (m/transform-vector t (vec2 1.0f 0.0f))]
              [(m/approx= (m/vec2-x p) 10.0) (m/approx= (m/vec2-y p) 1.0)
               (m/approx= (m/vec2-x q) 1.0) (m/approx= (m/vec2-y q) 0.0)
               (m/approx= (m/vec2-x d) 0.0) (m/approx= (m/determinant t) 1.0)
               (= (m/transpose (m/transpose t)) t)
               (m/inverse (m/mat3-scale 0.0))])"
           "[true true true true true true true nil]")
  ;; 3D: a rotation and translation, inverted, gives back the point.
  (math-is "(let [q (m/quat-from-axis-angle (vec3 1.0f 1.0f 0.0f) 0.7)
                  t (m/m* (m/mat4-translation 1 2 3)
                          (m/m* (m/mat4-rotation q) (m/mat4-scale 2 2 2)))
                  p (vec3 0.5f -1.0f 2.0f)
                  r (m/transform-point (m/inverse t) (m/transform-point t p))]
              [(m/approx= (m/vec3-x r) 0.5 1e-4) (m/approx= (m/vec3-y r) -1.0 1e-4)
               (m/approx= (m/vec3-z r) 2.0 1e-4) (m/approx= (m/determinant t) 8.0 1e-3)
               (= (m/m* m/mat4-identity t) t)])"
           "[true true true true true]")
  ;; Projections map the near plane to depth 0 and the far plane to depth 1.
  (math-is "(let [p (m/perspective (/ m/pi 2) 1.0 1.0 10.0)
                  near (m/transform p (vec4 0.0f 0.0f -1.0f 1.0f))
                  far (m/transform p (vec4 0.0f 0.0f -10.0f 1.0f))
                  o (m/ortho -1 1 -1 1 1 10)
                  view (m/look-at (vec3 0.0f 0.0f 5.0f) m/vec3-zero (vec3 0.0f 1.0f 0.0f))
                  origin (m/transform-point view m/vec3-zero)]
              [(m/approx= (/ (m/vec4-z near) (m/vec4-w near)) 0.0)
               (m/approx= (/ (m/vec4-z far) (m/vec4-w far)) 1.0 1e-5)
               (m/approx= (m/vec4-z (m/transform o (vec4 0.0f 0.0f -1.0f 1.0f))) 0.0)
               (m/approx= (m/vec3-z origin) -5.0)])"
           "[true true true true]"))

(test clocks
  (is (string= "[true true true]"
               (pr (ev "(ns t.clock (:require [skein.time :as t]))
                        (let [a (t/now) n (t/now-ns)] (sleep 0.02)
                          [(float? a) (integer? n) (<= 0.015 (- (t/now) a) 1.0)])"
                       :namespace "user")))))

;;; The fixed-timestep loop

(test fixed-timestep-run-loop
  (is (string= "[true true true true]"
               (pr (ev "(ns t.loop (:require [skein.game :as game] [skein.time :as t]))
                        (let [updates (atom 0) renders (atom 0) alphas (atom []) frames (atom 0)
                              start (t/now)]
                          (game/run-loop {:step 0.01
                                          :frame (fn [] (swap! frames inc) (sleep 0.004))
                                          :update (fn [dt] (swap! updates inc))
                                          :render (fn [a] (swap! renders inc) (swap! alphas conj a))
                                          :running? (fn [] (< (- (t/now) start) 0.3))})
                          [(<= 15 @updates 35) (= @renders @frames)
                           (every? #(and (<= 0 %) (< % 1)) @alphas) (> @frames 10)])"
                       :namespace "user"))))
  ;; A long pause (here a slow frame) runs at most :max-steps updates per frame.
  (is (string= "true"
               (pr (ev "(ns t.loop2 (:require [skein.game :as game]))
                        (let [updates (atom 0) frames (atom 0)]
                          (game/run-loop {:step 0.01 :max-steps 3
                                          :frame (fn [] (swap! frames inc) (sleep 0.2))
                                          :update (fn [dt] (swap! updates inc))
                                          :running? (fn [] (< @frames 2))})
                          (<= 4 @updates 6))"
                       :namespace "user"))))
  ;; retry-frame runs a failed update again.
  (is (string= "[3 1]"
               (pr (ev "(ns t.loop3 (:require [skein.game :as game]))
                        (let [updates (atom 0) failed (atom 0)]
                          (handler-bind [error (fn [c] (swap! failed inc)
                                                 (invoke-restart 'retry-frame))]
                            ;; One update per frame, so the count is exact however
                            ;; slow the machine is.
                            (game/run-loop {:step 0.001 :max-steps 1
                                            :update (fn [dt]
                                                      (when (and (= @updates 1) (zero? @failed))
                                                        (error \"once\"))
                                                      (swap! updates inc))
                                            :running? (fn [] (< @updates 3))}))
                          [@updates @failed])"
                       :namespace "user"))))
  (fails "(ns t.loop4 (:require [skein.game :as game])) (game/run-loop {:update inc :step 0})"
         ":step must be a positive number"))

;;; Namespace roots

(test namespace-root-from-ns-name
  (with-source-tree (dir ("src/game/main.skn" "(ns game.main (:require [game.util :as u]))
                                                (defn -main [] (u/f))")
                         ("src/game/util.skn" "(ns game.util) (defn f [] :found)")
                         ("other/odd.skn" "(ns not.matching) (defn -main [] :odd)"))
    (is (equal (uiop:native-namestring (truename (merge-pathnames "src/" dir)))
               (uiop:native-namestring (skein.backend.cl::namespace-root
                                        (merge-pathnames "src/game/main.skn" dir)))))
    (is (null (skein.backend.cl::namespace-root (merge-pathnames "other/odd.skn" dir))))
    (is (string= ":found" (pr (skein.backend.cl:run-file
                               (merge-pathnames "src/game/main.skn" dir)))))))

;;; Driftrock's rules, headless

(test driftrock-rules
  (let ((skein.runtime:*source-paths*
          (list (asdf:system-relative-pathname "skein" "../examples/"))))
    (is (string= "[true true true true]"
                 (pr (ev "(ns t.driftrock (:require [driftrock.game :as g]
                                                    [driftrock.entities :as e]
                                                    [skein.math :as m]))
                          (g/restart!)
                          (dotimes [i 900] (g/update! (g/autopilot (/ i 60.0)) (/ 1.0 60.0)))
                          (let [wd @g/world]
                            [(pos? (:score wd))
                             (contains? #{:playing :respawning :game-over} (:mode wd))
                             (every? e/alive? (:rocks wd))
                             (every? #(<= 0 (m/vec2-x (:pos %)) 960) (:rocks wd))])"
                         :namespace "user"))))))
