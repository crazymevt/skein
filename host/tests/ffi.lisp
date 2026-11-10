;;;; Tests for the FFI (DESIGN §14, M0.10). They call functions from the C library that
;;;; every SBCL process already has loaded (strlen, memset, qsort, ...).

(in-package #:skein.tests)

(def-suite skein.ffi :in all
  :description "Calling C: libraries, structs, unions, enums, memory and callbacks.")

(in-suite skein.ffi)

(defun ffi-ev (source)
  "Evaluate SOURCE in a fresh namespace that requires skein.ffi as ffi; print the result."
  (pr (ev (format nil "(ns ~A (:require [skein.ffi :as ffi]))~%~A" (fresh-ns) source)
          :namespace "user")))

(defmacro ffi-is (source expected)
  `(let ((got (ffi-ev ,source)))
     (is (string= ,expected got) "~S gave ~A, expected ~A" ,source got ,expected)))

(defmacro ffi-fails (source message)
  `(let ((e (handler-case (progn (ffi-ev ,source) nil) (error (e) e))))
     (is (typep e 'skein.runtime:skein-error) "~S should signal a Skein error, got ~A"
         ,source e)
     (when (typep e 'skein.runtime:skein-error)
       (is (search ,message (skein.runtime:skein-error-message e))
           "~S: message ~S does not contain ~S" ,source
           (skein.runtime:skein-error-message e) ,message))))

;;; Calls

(test call-c-functions
  (ffi-is "(ffi/defcfun strlen \"strlen\" u64 [s c-string])
           (ffi/defcfun c-abs \"abs\" i32 [x i32])
           [(strlen \"héllo\") (strlen \"\") (c-abs -7)]"
          "[6 0 7]")
  ;; A NULL c-string comes back as nil.
  (ffi-is "(ffi/defcfun ^:blocking getenv \"getenv\" c-string [name c-string])
           [(string? (getenv \"PATH\")) (getenv \"SKEIN_NO_SUCH_VARIABLE_42\")]"
          "[true nil]")
  ;; nil passed as a c-string is NULL.
  (is (cffi:null-pointer-p (skein.ffi::to-c (sym "c-string") nil))))

(test c-float-math-runs-without-traps
  ;; exp(1000) overflows inside C. C code runs with float traps masked, so it returns
  ;; infinity instead of signaling (regression: SDL3 tripped the overflow trap).
  (ffi-is "(ffi/defcfun c-exp \"exp\" f64 [x f64])
           (ffi/defcfun c-sqrtf \"sqrtf\" f32 [x f32])
           [(> (c-exp 1000.0) 1e300) (c-sqrtf 2.25) (c-exp 0)]"
          "[true 1.5f 1.0]")
  ;; Skein's own overflow behavior is unchanged afterwards.
  (is (eq :error (handler-case (progn (ev "(* 1e300 1e300)") :no-error)
                   (error () :error)))))

(test slow-calls-warn-unless-blocking
  ;; Sleep 20 ms: usleep(20000), or Sleep(20) from kernel32 on Windows.
  (let ((warned '())
        (sleep #+win32 "(ffi/defcfun pause \"Sleep\" void [ms u32])
                        (ffi/defcfun ^:blocking pause-blocking \"Sleep\" void [ms u32])
                        (def delay 20)"
               #-win32 "(ffi/defcfun pause \"usleep\" i32 [us u32])
                        (ffi/defcfun ^:blocking pause-blocking \"usleep\" i32 [us u32])
                        (def delay 20000)"))
    (handler-bind ((skein.ffi::slow-foreign-call
                     (lambda (w) (push (princ-to-string w) warned) (muffle-warning w))))
      (ffi-ev (format nil "~A (pause-blocking delay) (pause delay) (pause delay)" sleep)))
    (is (= 1 (length warned)) "warns once per function, not per call: ~S" warned)
    (is (search #+win32 "Sleep took more than 10 ms" #-win32 "usleep took more than 10 ms"
                (first warned)))))

;;; Structs, unions and memory

(test structs-and-unions
  (ffi-is "(ffi/defcstruct point (x i32) (y i32))
           (ffi/defcstruct rect (origin point) (size (array f32 2)) (tag u8))
           (ffi/defcunion number (i i64) (f f32) (bytes (array u8 3)))
           [(ffi/sizeof point) (ffi/sizeof rect) (ffi/sizeof number) (ffi/sizeof f64)
            (ffi/sizeof ptr)]"
          "[8 20 8 8 8]")
  (ffi-is "(ffi/defcstruct point (x i32) (y i32))
           (ffi/with-foreign [p (ffi/alloc point)]
             (ffi/put-field! p point :x 3)
             (ffi/put-field! p point :y -4)
             [(ffi/field p point :x) (ffi/field p point :y) (ffi/get p i32 1)])"
          "[3 -4 -4]")
  (ffi-is "(ffi/defcunion number (i i32) (f f32))
           (ffi/with-foreign [p (ffi/alloc number)]
             (ffi/put-field! p number :f 1.0f)
             (ffi/field p number :i))"
          "1065353216")
  (ffi-is "(ffi/defcstruct flag (on bool) (n u8))
           (ffi/with-foreign [p (ffi/alloc flag)]
             (ffi/put-field! p flag :on true)
             [(ffi/sizeof flag) (ffi/field p flag :on) (ffi/get p u8 0)])"
          "[2 true 1]")
  ;; Reading a nested struct or array field gives its address.
  (ffi-is "(ffi/defcstruct point (x i32) (y i32))
           (ffi/defcstruct line (from point) (to point) (tags (array u8 2)))
           (ffi/with-foreign [p (ffi/alloc line)]
             (let [to (ffi/field p line :to)
                   tags (ffi/field p line :tags)]
               (ffi/put-field! to point :y 7)
               (ffi/put! tags u8 3 1)
               [(ffi/get p i32 3) (ffi/get p u8 17) (- (ffi/address to) (ffi/address p))]))"
          "[7 3 8]")
  (ffi-fails "(ffi/defcstruct point (x i32) (y i32))
              (ffi/defcstruct line (from point) (to point))
              (ffi/with-foreign [p (ffi/alloc line)] (ffi/put-field! p line :to 0))"
             "holds a struct, union or array"))

(test memory
  (ffi-is "(ffi/with-foreign [p (ffi/alloc f32 4)]
             (ffi/put! p f32 2.5 1)
             (ffi/put! p f32 -1 3)
             [(ffi/get p f32 0) (ffi/get p f32 1) (ffi/get p f32 3) (ffi/null? p) (ffi/ptr? p)])"
          "[0.0f 2.5f -1.0f false true]")
  (ffi-is "(ffi/with-foreign [p (ffi/alloc u8 8)]
             (let [q (ffi/ptr+ p 3)]
               (ffi/put! q u8 9)
               [(- (ffi/address q) (ffi/address p)) (ffi/get p u8 3)]))"
          "[3 9]")
  (ffi-is "[(ffi/null? (ffi/null)) (ffi/null? nil) (ffi/ptr? 5)]" "[true true false]")
  (ffi-is "(ffi/defcfun memset \"memset\" ptr [p ptr, c i32, n u64])
           (let [p (ffi/own (ffi/alloc u8 4))]
             (memset p 7 4)
             [(ffi/get p u8 0) (ffi/get p u8 3)])"
          "[7 7]"))

(test owned-results
  ;; ^:owned on the return type: Skein frees the memory when the pointer is unreachable.
  (ffi-is "(ffi/defcfun c-malloc \"malloc\" ^:owned (ptr u8) [n u64])
           (ffi/defcfun c-malloc2 \"malloc\" ^:owned ptr [n u64])
           (ffi/defcfun ^:blocking c-malloc3 \"malloc\" ^:borrowed ptr [n u64])
           (let [p (c-malloc 4) q (c-malloc2 4) r (c-malloc3 4)]
             (ffi/put! p u8 42 3)
             (ffi/free r)
             [(ffi/get p u8 3) (ffi/ptr? p) (ffi/null? q) (= (class-of p) (class-of q))
              (= (class-of p) (class-of r))])"
          "[42 true false true false]"))

(test arrays-are-pinned-for-calls
  (ffi-is "(ffi/defcfun memset \"memset\" ptr [p ptr, c i32, n u64])
           (let [a (make-array u8 6)]
             (memset (view a 2 4) 9 2)
             (vec a))"
          "[0 0 9 9 0 0]")
  (ffi-is "(ffi/defcfun memset \"memset\" ptr [p ptr, c i32, n u64])
           (let [a (make-array f32 2)
                 bytes (as-bytes a)]
             (aset! a 0 1.5f)
             (aset! a 1 2.5f)
             (memset bytes 0 (count bytes))
             [(count bytes) (vec a)])"
          "[8 [0.0f 0.0f]]")
  (ffi-is "(ffi/defcfun memset \"memset\" ptr [p ptr, c i32, n u64])
           (let [a (make-array u8 4)]
             (ffi/pin [p a] (memset p 5 4))
             (vec a))"
          "[5 5 5 5]"))

;;; Enums, callbacks and handles

(test enums
  (ffi-is "(ffi/defcenum flags u32 (:a 1) (:b 2) (:c 4))
           [(ffi/enum-value flags :b) (ffi/enum-value flags [:a :c]) (ffi/enum-value flags 9)
            (ffi/enum-value flags nil)]"
          "[2 5 9 0]")
  (ffi-is "(ffi/defcenum color (:red 0) (:green 5))
           (ffi/defcfun c-abs \"abs\" i32 [x color])
           [(c-abs :green) (c-abs -3)]"
          "[5 3]")
  (ffi-fails "(ffi/defcenum color (:red 0)) (ffi/enum-value color :blue)" "has no value :blue"))

(test callbacks
  (ffi-is "(ffi/defcallback compare-ints i32 [a ptr, b ptr]
             (compare (ffi/get a i32) (ffi/get b i32)))
           (ffi/defcfun qsort \"qsort\" void [base ptr, n u64, size u64, cmp ptr])
           (let [a (make-array i32 5)]
             (doseq [[i v] (map-indexed vector [5 3 9 1 4])] (aset! a i v))
             (qsort a 5 4 compare-ints)
             (vec a))"
          "[1 3 4 5 9]")
  ;; An error in a callback cannot unwind through C: it warns and returns zero.
  (let ((warnings '()))
    (handler-bind ((skein.ffi::callback-error-warning
                     (lambda (w) (push (princ-to-string w) warnings) (muffle-warning w))))
      (ffi-is "(ffi/defcallback bad-compare i32 [a ptr, b ptr] (error \"no\"))
               (ffi/defcfun qsort \"qsort\" void [base ptr, n u64, size u64, cmp ptr])
               (let [a (make-array i32 2)] (qsort a 2 4 bad-compare) :survived)"
              ":survived"))
    (is (plusp (length warnings)))
    (is (search "signaled" (first warnings))))
  ;; Nor can another non-local exit (D-068): it's stopped where C called the callback.
  (let ((warnings '()))
    (handler-bind ((skein.ffi::callback-error-warning
                     (lambda (w) (push (princ-to-string w) warnings) (muffle-warning w))))
      (ffi-is "(ffi/defcallback leaving i32 [a ptr, b ptr] (invoke-restart 'skip) 1)
               (ffi/defcfun qsort \"qsort\" void [base ptr, n u64, size u64, cmp ptr])
               (restart-case (let [a (make-array i32 2)] (qsort a 2 4 leaving) :survived)
                 (skip [] :skipped))"
              ":survived"))
    (is (plusp (length warnings)))
    (is (search "tried to exit through C; returning 0" (first warnings)))))

(test handles
  (ffi-is "(let [v [1 2]
                 h (ffi/handle v)]
             [(integer? h) (identical? v (ffi/handle-value h)) (ffi/free-handle h)])"
          "[true true nil]")
  (ffi-is "(not= (ffi/handle :a) (ffi/handle :a))" "true"))

;;; Errors

(test ffi-errors
  (ffi-fails "(ffi/defcfun nope \"skein_no_such_function_xyz\" void []) (nope)"
             "the C function skein_no_such_function_xyz was not found")
  (ffi-fails "(ffi/deflibrary nolib {:macos \"libnope42.dylib\" :linux \"libnope42.so\"
                                     :windows \"nope42.dll\"})"
             "nope42")
  (ffi-fails "(ffi/defcfun f \"abs\" i32 [x no-such-type])" "unknown foreign type no-such-type")
  (ffi-fails "(ffi/defcfun f \"abs\" i32 [x])" "C parameters look like")
  (ffi-fails "(ffi/defcstruct point (x i32) (y i32))
              (ffi/defcfun f \"abs\" i32 [p point])"
             "pass it by pointer")
  (ffi-fails "(ffi/defcstruct point (x i32))
              (ffi/with-foreign [p (ffi/alloc point)] (ffi/field p point :z))"
             "has no field :z"))
