;;;; Numeric conversions and random numbers (skein.core), the host part of skein.math
;;;; (trigonometry, rounding, noise) and of skein.time (clocks). D-040.

(in-package #:skein.runtime)

;;; ------------------------------------------------------------------------------------
;;; Conversions (skein.core): named after the types they produce. int also gives a
;;; char's code point, and char the character with a code point, as in Clojure.

(declaim (inline to-f32 to-f64 to-int float-arg))

(defun to-f32 (x)
  (if (typep x 'single-float) x (coerce x 'single-float)))

(defun to-f64 (x)
  (if (typep x 'double-float) x (coerce x 'double-float)))

(defun to-int (x)
  (cond ((integerp x) x)
        ((characterp x) (char-code x))
        ((realp x) (values (truncate x)))
        (t (skein-error 'skein-error nil "int needs a number or a char, not ~A"
                        (readable-string x)))))

(defun to-char (x)
  "The character with code point X, as Clojure's char; a character is returned as it is."
  (cond ((characterp x) x)
        ((and (integerp x) (<= 0 x #x10FFFF) (not (<= #xD800 x #xDFFF))) (code-char x))
        (t (skein-error 'skein-error nil "char needs a code point, not ~A"
                        (readable-string x)))))

(defun float-arg (x)
  "X as a float: floats stay as they are, other numbers become f64."
  (if (floatp x) x (coerce x 'double-float)))

(defcore "f32" (x) (to-f32 x))
(defcore "f64" (x) (to-f64 x))
(defcore "int" (x) (to-int x))
(defcore "char" (x) (to-char x))

(define-inline "f32" (x) (1 1) `(to-f32 ,x))
(define-inline "f64" (x) (1 1) `(to-f64 ,x))
(define-inline "int" (x) (1 1) `(to-int ,x))

;;; Random numbers (skein.core), as in Clojure: (rand) and (rand n) give an f64 in [0, n);
;;; (rand-int n) an integer in [0, n).

(sb-ext:define-load-time-global **random-state** (make-random-state t))
(sb-ext:define-load-time-global **random-lock** (sb-thread:make-mutex :name "random"))

(defun skein-random (limit)
  (sb-thread:with-mutex (**random-lock**)
    (random limit **random-state**)))

(defcore "rand" (&optional (n 1.0d0))
  (unless (and (realp n) (plusp n))
    (skein-error 'skein-error nil "rand needs a positive number, not ~A" (readable-string n)))
  (skein-random (to-f64 n)))

(defcore "rand-int" (n)
  (unless (and (integerp n) (plusp n))
    (skein-error 'skein-error nil "rand-int needs a positive integer, not ~A"
                 (readable-string n)))
  (skein-random n))

;;; ------------------------------------------------------------------------------------
;;; skein.math's host functions. lib/skein/math.skn adds the rest of the namespace.

(defmacro defmath (name (&rest params) template)
  "Define skein.math/NAME as a function whose body is TEMPLATE (a backquoted form over
PARAMS), and inline calls to it with the same template."
  (let ((body (eval `(let ,(mapcar (lambda (p) `(,p ',p)) params) ,template))))
    `(let ((var (intern-var (ensure-namespace "skein.math") ,name)))
       (def-var var (sb-int:named-lambda ,(format nil "skein.math/~A" name) ,params ,body))
       (register-inline var (lambda ,params ,template) ,(length params) ,(length params)))))

(sb-ext:define-load-time-global +f32-nan+ (sb-kernel:make-single-float #x7FC00000)
  "An f32 NaN.")

(defun math-domain-nan (x)
  (if (typep x 'single-float) +f32-nan+ +f64-nan+))

(declaim (inline real-or-nan))
(defun real-or-nan (fn x)
  "Call FN on X; a complex result (outside FN's real domain) becomes NaN."
  (let ((r (funcall fn (float-arg x))))
    (if (complexp r) (math-domain-nan (float-arg x)) r)))

(defmath "sin" (x) `(sin (float-arg ,x)))
(defmath "cos" (x) `(cos (float-arg ,x)))
(defmath "tan" (x) `(tan (float-arg ,x)))
(defmath "asin" (x) `(real-or-nan #'asin ,x))
(defmath "acos" (x) `(real-or-nan #'acos ,x))
(defmath "atan" (x) `(atan (float-arg ,x)))
(defmath "atan2" (y x) `(atan (float-arg ,y) (float-arg ,x)))
(defmath "exp" (x) `(exp (float-arg ,x)))
(defmath "log" (x) `(real-or-nan #'log ,x))
(defmath "pow" (x y) `(math-pow ,x ,y))
(defmath "floor" (x) `(if (integerp ,x) ,x (ffloor ,x)))
(defmath "ceil" (x) `(if (integerp ,x) ,x (fceiling ,x)))
(defmath "round" (x) `(if (integerp ,x) ,x (math-round ,x)))
(defmath "trunc" (x) `(if (integerp ,x) ,x (ftruncate ,x)))

(defun math-pow (x y)
  "X to the power Y: integers to non-negative integer powers stay exact; otherwise a
float, NaN where the result is not real."
  (if (and (integerp x) (integerp y) (>= y 0))
      (expt x y)
      (let ((r (expt (float-arg x) (if (integerp y) y (float-arg y)))))
        (if (complexp r) (math-domain-nan (float-arg x)) r))))

(defun math-round (x)
  "Round X to the nearest whole number, halves away from zero, keeping its float type."
  (if (minusp x)
      (- (ffloor (+ (- x) 0.5)))
      (ffloor (+ x 0.5))))

;;; Improved Perlin noise (Ken Perlin, 2002): (noise x y) and (noise x y z) give a smooth
;;; f64 in about [-1, 1].

(sb-ext:define-load-time-global **noise-permutation**
    (let* ((p #(151 160 137 91 90 15 131 13 201 95 96 53 194 233 7 225 140 36 103 30 69 142
                8 99 37 240 21 10 23 190 6 148 247 120 234 75 0 26 197 62 94 252 219 203 117
                35 11 32 57 177 33 88 237 149 56 87 174 20 125 136 171 168 68 175 74 165 71
                134 139 48 27 166 77 146 158 231 83 111 229 122 60 211 133 230 220 105 92 41
                55 46 245 40 244 102 143 54 65 25 63 161 1 216 80 73 209 76 132 187 208 89 18
                169 200 196 135 130 116 188 159 86 164 100 109 198 173 186 3 64 52 217 226 250
                124 123 5 202 38 147 118 126 255 82 85 212 207 206 59 227 47 16 58 17 182 189
                28 42 223 183 170 213 119 248 152 2 44 154 163 70 221 153 101 155 167 43 172 9
                129 22 39 253 19 98 108 110 79 113 224 232 178 185 112 104 218 246 97 228 251
                34 242 193 238 210 144 12 191 179 162 241 81 51 145 235 249 14 239 107 49 192
                214 31 181 199 106 157 184 84 204 176 115 121 50 45 127 4 150 254 138 236 205
                93 222 114 67 29 24 72 243 141 128 195 78 66 215 61 156 180))
           (table (make-array 512 :element-type 'fixnum)))
      (dotimes (i 512 table) (setf (aref table i) (aref p (mod i 256))))))

(declaim (inline noise-fade noise-lerp noise-grad))
(defun noise-fade (u) (* u u u (+ (* u (- (* u 6) 15)) 10)))
(defun noise-lerp (u a b) (+ a (* u (- b a))))
(defun noise-grad (hash x y z)
  (let* ((h (logand hash 15))
         (u (if (< h 8) x y))
         (v (cond ((< h 4) y) ((or (= h 12) (= h 14)) x) (t z))))
    (+ (if (evenp h) u (- u)) (if (zerop (logand h 2)) v (- v)))))

(defun perlin-noise (x y z)
  (declare (type double-float x y z) (optimize (speed 3) (safety 0)))
  (let* ((p **noise-permutation**)
         (fx (ffloor x)) (fy (ffloor y)) (fz (ffloor z))
         (xi (logand (the fixnum (truncate fx)) 255))
         (yi (logand (the fixnum (truncate fy)) 255))
         (zi (logand (the fixnum (truncate fz)) 255))
         (x (- x fx)) (y (- y fy)) (z (- z fz))
         (u (noise-fade x)) (v (noise-fade y)) (w (noise-fade z)))
    (declare (type (simple-array fixnum (512)) p))
    (macrolet ((p (i) `(aref p ,i)))
      (let* ((a (+ (p xi) yi)) (aa (+ (p a) zi)) (ab (+ (p (1+ a)) zi))
             (b (+ (p (1+ xi)) yi)) (ba (+ (p b) zi)) (bb (+ (p (1+ b)) zi)))
        (noise-lerp w
                    (noise-lerp v
                                (noise-lerp u (noise-grad (p aa) x y z)
                                            (noise-grad (p ba) (- x 1) y z))
                                (noise-lerp u (noise-grad (p ab) x (- y 1) z)
                                            (noise-grad (p bb) (- x 1) (- y 1) z)))
                    (noise-lerp v
                                (noise-lerp u (noise-grad (p (1+ aa)) x y (- z 1))
                                            (noise-grad (p (1+ ba)) (- x 1) y (- z 1)))
                                (noise-lerp u (noise-grad (p (1+ ab)) x (- y 1) (- z 1))
                                            (noise-grad (p (1+ bb)) (- x 1) (- y 1)
                                                        (- z 1)))))))))

(def-var (intern-var (ensure-namespace "skein.math") "noise")
         (sb-int:named-lambda "skein.math/noise" (x y &optional (z 0.0d0))
           (perlin-noise (to-f64 x) (to-f64 y) (to-f64 z))))

;;; ------------------------------------------------------------------------------------
;;; skein.time's host functions: a monotonic clock.

(sb-ext:define-load-time-global **clock-start** (get-internal-real-time))

(def-var (intern-var (ensure-namespace "skein.time") "now")
         (sb-int:named-lambda "skein.time/now" ()
           (/ (to-f64 (- (get-internal-real-time) **clock-start**))
              internal-time-units-per-second)))

(def-var (intern-var (ensure-namespace "skein.time") "now-ns")
         (sb-int:named-lambda "skein.time/now-ns" ()
           (* (- (get-internal-real-time) **clock-start**)
              (/ 1000000000 internal-time-units-per-second))))
