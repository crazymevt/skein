;;;; Tests for M0.8: declarations, type specifiers, inlining, the calling convention,
;;;; typed arrays, value structs, records, defsoa and efficiency notes.

(in-package #:skein.tests)

(def-suite skein.types :in all
  :description "Declarations, value structs, typed arrays and efficiency notes.")

(in-suite skein.types)

;;; Type specifiers (DESIGN §12.1)

(test type-specifiers
  (flet ((cl (source) (skein.runtime:skein-type-to-cl (read-quoted source))))
    (is (equal '(signed-byte 8) (cl "i8")))
    (is (equal '(unsigned-byte 64) (cl "u64")))
    (is (eq 'single-float (cl "f32")))
    (is (eq 'double-float (cl "f64")))
    (is (eq 'fixnum (cl "fixnum")))
    (is (eq 'integer (cl "integer")))
    (is (eq 'real (cl "number")))
    (is (eq t (cl "any")))
    (is (eq 'string (cl "string")))
    (is (eq 'skein.runtime::pvector (cl "vector")))
    (is (eq 'skein.runtime::skein-map (cl "hash-map")))
    (is (equal '(simple-array single-float (*)) (cl "(array f32)")))
    (is (equal '(simple-array double-float (4)) (cl "(array f64 4)")))
    (is (equal '(simple-array t (*)) (cl "(array any)")))
    (is (equal '(or null double-float) (cl "(maybe f64)")))
    (is (equal '(or fixnum string) (cl "(or fixnum string)")))
    (is (eq 'function (cl "(fn [f32] f32)")))
    (signals skein.runtime:skein-error (cl "no-such-type"))))

;;; Declarations (DESIGN §12.2)

(test hints-and-declarations-are-checked
  (evals-to "((fn [^f64 x] (* x 2.0)) 1.5)" 3.0d0)
  (type-fails "((fn [^f64 x] x) 1)")
  (type-fails "(let [^i32 n 1.5] n)")
  (type-fails "(let [^i8 n 1000] n)")
  (type-fails "(defn f [x] (declare (type f32 x)) x) (f 1.0)")
  (evals-to "(defn f [x] (declare (type f32 x)) x) (f 1.0f)" 1.0f0)
  (type-fails "(defn r ^f32 [] 1) (r)")
  (evals-to "(loop [^fixnum i 0] (if (< i 3) (recur (inc i)) i))" 3)
  (type-fails "(loop [^fixnum i 0] (if (< i 3) (recur 1.5) i))")
  (evals-to "(let-values* [[^f64 a b] (values 1.0 2)] (+ a b))" 3.0d0)
  (type-fails "(the string 5)"))

(test optimize-declarations
  (evals-to "(defn f [x] (declare (type f64 x) (optimize (speed 3) (safety 1))) (* x x)) (f 3.0)"
            9.0d0)
  (evals-to "(defn f [x] (declare (optimize speed)) x) (f 1)" 1)
  (compile-fails "(fn [x] (declare (optimize (speed 9))) x)" "optimize takes qualities")
  (compile-fails "(fn [x] (declare (optimize (fast 1))) x)" "optimize takes qualities")
  (compile-fails "(fn [x] (declare (inline x)) x)" "unknown declaration")
  (compile-fails "(fn [x] (declare (type f64 y)) x)" "no local named y to declare")
  (fails "(fn [^no-such-type x] x)" "unknown type no-such-type" :line 1 :column 1))

(test declaim-ftype
  (evals-to "(declaim (ftype (fn [f64] f64) sq)) (defn sq [x] (* x x)) (sq 3.0)" 9.0d0)
  (type-fails "(declaim (ftype (fn [f64] f64) sq)) (defn sq [x] 1) (+ 1.0 (sq 3.0))")
  (fails "(declaim (inline x))" "declaim supports (ftype"))

(test release-profile
  (let ((skein.backend.cl:*profile* :release))
    (evals-to "(defn f [x] (+ x 1)) (f 1)" 2)))

;;; Inlined primitives keep their semantics (D-036)

(test inlined-primitives
  (evals-to "(let [a 1 b 2] (/ a b))" 0.5d0)
  (evals-to "(let [a 7 b 2] [(quot a b) (rem a b) (mod -7 b)])"
            (skein.runtime:vector-from-list '(3 1 1)) :test skein.runtime:equiv)
  (evals-to "(let [x ##NaN] [(< x 1.0) (> x 1.0) (== x x)])"
            (skein.runtime:vector-from-list (list skein.runtime:+false+ skein.runtime:+false+
                                                  skein.runtime:+false+))
            :test skein.runtime:equiv)
  (evals-to "(if (< 1 2 3) :yes :no)" (kw "yes"))
  (evals-to "(let [f <] (f 1 2))" t)
  (evals-to "(sqrt 16)" 4.0d0)
  (is (sb-ext:float-nan-p (ev "(sqrt -1.0)")))
  (evals-to "(count (make-array f64 3))" 3)
  (evals-to "(count \"héllo\")" 5)
  (fails "(inc)" "wrong number of arguments (0) passed to skein.core/inc, which takes 1"
         :line 1 :column 1))

(test calls-allocate-nothing
  (let* ((ns (fresh-ns))
         (add3 (ev "(defn add3 [a b c] (+ a b c)) add3" :namespace ns))
         (many (ev "(defn many ([] 0) ([a] a) ([a b & more] (+ a b))) many" :namespace ns)))
    (funcall add3 1 2 3)
    (funcall many 1 2)
    (let ((before (sb-ext:get-bytes-consed)))
      (dotimes (i 100000)
        (funcall add3 i 1 2)
        (funcall many i 2))
      (is (< (- (sb-ext:get-bytes-consed) before) 10000)
          "fixed-arity calls should not allocate argument lists"))))

;;; Typed arrays (DESIGN §9.2, §9.3)

(test typed-arrays
  (evp-is "(let [a (make-array f32 3)] (aset! a 1 2.5f) [(aget a 0) (aget a 1) (count a)])"
          "[0.0f 2.5f 3]")
  (evp-is "(let [a (make-array i32 2)] (aset! a 0 -5) (vec a))" "[-5 0]")
  (evp-is "(let [a (make-array u8 2)] (aset! a 1 255) (seq a))" "(0 255)")
  (evp-is "(let [a (make-array any 2)] (aset! a 0 :x) (vec a))" "[:x nil]")
  (evp-is "(let [a (make-array char 2)] (aset! a 0 \\z) (aget a 0))" "\\z")
  (evp-is "(make-array f64 2)" "#<array f64 [0.0 0.0]>")
  (evp-is "(let [a (make-array f64 3)] (update! a 2 + 1.5) (update! a 2 * 2.0) (aget a 2))" "3.0")
  (evp-is "(array? (make-array f32 1))" "true")
  (type-fails "(aset! (make-array f32 1) 0 1)")
  (type-fails "(aset! (make-array u8 1) 0 256)")
  (is (eq :error (handler-case (progn (ev "(aget (make-array f32 2) 5)") :ok) (error () :error))))
  (fails "(make-array bogus 3)" "unknown array element type bogus")
  (fails "(make-array f32 -1)" "make-array needs a non-negative length")
  (fails "(aget [1 2] 0)" "aget needs an array"))

(test array-views
  (evp-is "(let [a (make-array f64 4) v (view a 1 3)]
             (aset! v 0 7.0)
             [(aget a 1) (count v) (vec v)])"
          "[7.0 2 [7.0 0.0]]")
  (evp-is "(count (view (make-array f32 5) 2))" "3")
  (fails "(view (make-array f32 2) 1 5)" "out of bounds")
  (fails "(view [1 2] 0 1)" "view needs an array"))

;;; Value structs and records (DESIGN §9.1)

(defparameter *vec2* "(defstruct vec2 :value (x f32) (y f32))")

(defun with-vec2 (source) (concatenate 'string *vec2* " " source))

(test value-structs
  (evp-is (with-vec2 "(let [v (vec2 1.0f 2.0f)] [(:x v) (vec2-y v) (get v :z :nf) (keys v)])")
          "[1.0f 2.0f :nf (:x :y)]")
  (evp-is (with-vec2 "(vec2 :y 2.0f :x 1.0f)") (format nil "#<test.ns~D/vec2 {:x 1.0f, :y 2.0f}>"
                                                       (1+ *test-ns-counter*)))
  (evp-is (with-vec2 "[(= (vec2 1.0f 2.0f) (vec2 1.0f 2.0f)) (= (vec2 1.0f 2.0f) (vec2 2.0f 1.0f))
                      (= (hash-of (vec2 1.0f 2.0f)) (hash-of (vec2 1.0f 2.0f)))
                      (count (set [(vec2 1.0f 2.0f) (vec2 1.0f 2.0f)]))]")
          "[true false true 1]")
  (evp-is (with-vec2 "(:x (with (vec2 1.0f 2.0f) :x 5.0f))") "5.0f")
  (evp-is (with-vec2 "(struct? (vec2 1.0f 2.0f))") "true")
  (evp-is (with-vec2 "(defn dot ^f32 [^vec2 a ^vec2 b]
                        (+ (* (vec2-x a) (vec2-x b)) (* (vec2-y a) (vec2-y b))))
                      (dot (vec2 1.0f 2.0f) (vec2 3.0f 4.0f))")
          "11.0f")
  (evp-is (with-vec2 "(defmethod describe-v [(v vec2)] :vec2) (defmethod describe-v [v] :other)
                      [(describe-v (vec2 0.0f 0.0f)) (describe-v 1)]")
          "[:vec2 :other]")
  (type-fails (with-vec2 "(vec2 1 2)"))
  (type-fails (with-vec2 "(vec2-x 5)"))
  (fails (with-vec2 "(vec2 1.0f)") "takes 2 field values")
  (fails (with-vec2 "(vec2 :x 1.0f :z 2.0f)") "needs a value for :y")
  (fails (with-vec2 "(with (vec2 1.0f 2.0f) :z 1)") "has no field :z")
  (fails "(defstruct bad :value (s string))" "must have a primitive type or another value struct")
  (fails "(defstruct bad2 :value (x))" "need types")
  (compile-fails "(defstruct bad3 (x f32 extra))" "defstruct fields look like (name type)"))

(test plain-records
  (evp-is "(defstruct person (name) (tags))
           [(person \"Ada\" [1]) (= (person \"Ada\" [1]) (person \"Ada\" '(1)))
            (:name (person \"Bo\" []))]"
          (format nil "[#<test.ns~D/person {:name \"Ada\", :tags [1]}> true \"Bo\"]"
                  (1+ *test-ns-counter*)))
  (type-fails "(defstruct typed (n integer)) (typed \"x\")"))

(test redefining-a-struct
  (let ((warnings '()))
    (handler-bind ((skein.runtime:struct-redefinition-warning
                     (lambda (w) (push w warnings) (muffle-warning w))))
      (evp-is "(defstruct p2 :value (x f32))
               (def old (p2 1.0f))
               (defstruct p2 :value (x f32) (y f32))
               [(:x old) (:y (p2 1.0f 2.0f))]"
              "[1.0f 2.0f]"))
    (is (= 1 (length warnings))))
  (let ((warnings '()))
    (handler-bind ((skein.runtime:struct-redefinition-warning
                     (lambda (w) (push w warnings) (muffle-warning w))))
      (ev "(defstruct same :value (x f32)) (defstruct same :value (x f32))"))
    (is (null warnings) "an unchanged definition does not warn")))

;;; Arrays of value structs and defsoa

(test struct-arrays
  (evp-is (with-vec2 "(defstruct particle :value (pos vec2) (vel vec2) (life f32))
                      (let [ps (make-array particle 3)]
                        (aset! ps 1 (particle (vec2 1.0f 2.0f) (vec2 0.5f 0.0f) 10.0f))
                        (update! ps 1 :life - 2.5f)
                        (update! ps 1 :pos (fn [p] (with p :y 9.0f)))
                        [(:life (aget ps 1)) (:pos (aget ps 1)) (:life (aget ps 0)) (count ps)])")
          (format nil "[7.5f #<test.ns~D/vec2 {:x 1.0f, :y 9.0f}> 0.0f 3]"
                  (1+ *test-ns-counter*)))
  (fails (with-vec2 "(aset! (make-array vec2 1) 0 5)") "expected a ")
  (fails (with-vec2 "(aget (make-array vec2 1) 3)") "index 3 is out of bounds")
  (fails (with-vec2 "(update! (make-array vec2 1) 0 :z inc)") "has no field z"))

(test defsoa
  (evp-is (with-vec2 "(defsoa particles (pos vec2) (life f32))
                      (def ps (make-particles 4))
                      (update! ps 2 :life + 3.0f)
                      (update! ps 2 :pos (fn [p] (vec2 (+ (:x p) 1.0f) 5.0f)))
                      [(life ps 2) (pos ps 2) (count ps) (life ps 0)]")
          (format nil "[3.0f #<test.ns~D/vec2 {:x 1.0f, :y 5.0f}> 4 0.0f]"
                  (1+ *test-ns-counter*)))
  (evp-is (with-vec2 "(defsoa ps2 (pos vec2)) (defn f [p] (declare (type ps2 p)) (count p))
                      (f (make-ps2 3))")
          "3")
  (fails (with-vec2 "(defsoa ps3 (life f32)) (life [1] 0)") "life needs a ps3 collection")
  (compile-fails "(defsoa ps4 (life))" "defsoa fields look like (name type)"))

;;; Efficiency notes (DESIGN §12.4)

(defun notes-of (source)
  (let ((notes '()))
    (handler-bind ((skein.backend.cl:efficiency-note
                     (lambda (n) (push (princ-to-string n) notes) (muffle-warning n))))
      (ev source))
    (nreverse notes)))

(test efficiency-notes
  (let ((notes (notes-of "(defn slow [a b]
  (declare (optimize (speed 3)))
  (* a b 2.0))")))
    (is (plusp (length notes)))
    (is (every (lambda (n) (search "efficiency note at t.skn:3:" n)) notes))
    (is (some (lambda (n) (search "f64" n)) notes) "notes use Skein type names"))
  (is (null (notes-of "(defn fast [a b]
  (declare (type f64 a b) (optimize (speed 3)))
  (* a b 2.0))")))
  (is (null (notes-of "(defn plain [a b] (* a b 2.0))")) "no notes without (speed 2) or more"))

;;; The M0.8 benchmark program computes the right answer

(test nbody-benchmark-program
  (let ((path (merge-pathnames "bench/nbody/nbody.skn"
                               (uiop:pathname-parent-directory-pathname
                                (asdf:system-source-directory "skein")))))
    (skein.backend.cl:load-file path)
    (let ((result (funcall (skein.runtime:var-value
                            (skein.runtime:find-own-var (skein.runtime:find-namespace "nbody")
                                                        "run"))
                           1000)))
      (is (< (abs (- -0.169075164d0 (skein.runtime:vector-nth result 0))) 1d-9))
      (is (< (abs (- -0.169087605d0 (skein.runtime:vector-nth result 1))) 1d-9)))))
