;;;; Tests for the object system (DESIGN §8, M0.7).

(in-package #:skein.tests)

(def-suite skein.objects :in all
  :description "Classes, instances, cells, generic functions and redefinition.")

(in-suite skein.objects)

(defparameter *ship-classes*
  "(defclass entity [] (id :init 1 :reader entity-id))
   (defclass ship [entity]
     \"A ship.\"
     (pos :init [0 0] :type vec2 :doc \"Position.\")
     (angle :init 0.0f)
     (hp :cell :atom :init 100)
     (scratch :cell :unsynchronized))")

(defun with-ships (source)
  (concatenate 'string *ship-classes* " " source))

;;; Classes and instances

(test make-and-slot-access
  (evp-is (with-ships "(def s (make ship :pos [1 2]))
                       [(:pos s) (:angle s) (entity-id s) (slot s :pos) (get s :angle)
                        (get s :nope :nf) (instance? ship s) (instance? entity s)]")
          "[[1 2] 0.0f 1 [1 2] 0.0f :nf true true]")
  (evp-is (with-ships "(keys (make ship))") "(:id :pos :angle :hp :scratch)")
  (evp-is (with-ships "(let [{:keys [pos angle]} (make ship :angle 2.0f)] [pos angle])")
          "[[0 0] 2.0f]")
  (evp-is (with-ships "(class-slots ship)") "[:id :pos :angle :hp :scratch]")
  (evp-is (with-ships "(class-name ship)")
          (format nil "test.ns~D/ship" (1+ *test-ns-counter*)))
  (evp-is "(defclass counter [] (n :init (+ 1 2))) [(:n (make counter)) (:n (make counter :n 9))]"
          "[3 9]")
  (fails (with-ships "(make ship :speed 1)") "/ship has no slot :speed")
  (fails (with-ships "(slot (make ship) :speed)") "has no slot :speed")
  (fails "(make 5)" "5 is not a class"))

(test init-expressions-run-per-instance
  (evp-is "(def n (atom 0))
           (defclass numbered [] (id :init (swap! n inc)))
           [(:id (make numbered)) (:id (make numbered)) (:id (make numbered :id 99)) @n]"
          "[1 2 99 2]"))

(test initialize-is-called
  (evp-is "(defclass sized [] (w :init 1) (area :cell :atom))
           (defmethod initialize [(s sized)] (reset! (:area s) (* (:w s) (:w s))))
           @(:area (make sized :w 3))"
          "9"))

(test printing-instances
  (evp-is "(defclass pt [] (x :init 1) (h :cell :atom :init 2)) (pr-str (make pt))"
          (format nil "\"#<test.ns~D/pt {:x 1, :h #<atom 2>}>\"" (1+ *test-ns-counter*))))

;;; Immutability and cells

(test immutable-slots
  (fails (with-ships "(set! (:pos (make ship)) [9 9])")
         "is immutable; use with to make a changed copy")
  (fails (with-ships "(set! (:hp (make ship)) 5)") "is an atom; use reset! or swap! on it")
  (fails (with-ships "(set! (:nope (make ship)) 5)") "has no slot :nope")
  (fails "(set! (:x 5) 1)" "needs an instance"))

(test atom-cells
  (evp-is (with-ships "(let [s (make ship)] (swap! (:hp s) - 30) (reset! (:hp s) (* 2 @(:hp s)))
                                            @(:hp s))")
          "140")
  (evp-is (with-ships "(let [s (make ship :hp 5)] @(:hp s))") "5"))

(test unsynchronized-cells
  (evp-is (with-ships "(let [s (make ship)] (set! (:scratch s) [1]) (:scratch s))") "[1]")
  (let ((obj (ev (with-ships "(make ship)")))
        (result nil))
    (sb-thread:join-thread
     (sb-thread:make-thread
      (lambda ()
        (setf result (handler-case (progn (skein.runtime::set-object-slot
                                           obj (kw "scratch") 1)
                                          :set)
                       (skein.runtime:slot-error (e)
                         (skein.runtime:skein-error-message e)))))))
    (is (stringp result))
    (is (search "is :unsynchronized and owned by another thread" result))))

(test with-copies-instances
  (evp-is (with-ships "(let [s (make ship :pos [1 1]) t (with s :pos [2 2] :angle 1.0f)]
                         [(:pos s) (:pos t) (:angle t) (identical? s t)])")
          "[[1 1] [2 2] 1.0f false]")
  ;; Cells are shared by reference unless :fresh-cells true.
  (evp-is (with-ships "(let [s (make ship) t (with s :angle 1.0f)]
                         (swap! (:hp t) dec)
                         [@(:hp s) @(:hp t) (identical? (:hp s) (:hp t))])")
          "[99 99 true]")
  (evp-is (with-ships "(let [s (make ship) t (with s :fresh-cells true)]
                         (swap! (:hp t) dec)
                         [@(:hp s) @(:hp t)])")
          "[100 99]")
  (evp-is (with-ships "(let [s (make ship) t (with s :hp 7)] [@(:hp s) @(:hp t)])") "[100 7]")
  (fails (with-ships "(with (make ship) :speed 1)") "has no slot :speed")
  (fails "(with {:a 1} :a 2)" "with needs an instance"))

(test cell-options
  (fails "(defclass r [] (x :cell :ref))" ":cell :ref is reserved and not supported yet")
  (fails "(defclass r2 [] (x :cell :weird))" ":cell must be :atom or :unsynchronized")
  (compile-fails "(defclass r3 [] (x :init))" "slot options must come in pairs")
  (compile-fails "(defclass r4 [] x)" "defclass slots look like (name :option value ...)")
  (compile-fails "(defclass r5 x)" "defclass needs a vector of superclasses"))

;;; Generic functions and dispatch

(test single-dispatch
  (evp-is "(defgeneric area [shape])
           (defclass circle [] (r))
           (defclass square [] (side))
           (defmethod area [(c circle)] (* 3 (:r c) (:r c)))
           (defmethod area [(s square)] (* (:side s) (:side s)))
           [(area (make circle :r 2)) (area (make square :side 3))]"
          "[12 9]")
  (fails "(defgeneric nothing-here [x]) (nothing-here 1)" "no method of ")
  (fails "(defgeneric nothing-here [x]) (nothing-here 1)" "/nothing-here applies to (1)"))

(test multiple-dispatch-and-eql-specializers
  (evp-is "(defgeneric collide [a b])
           (defclass rock [])
           (defclass craft [])
           (defmethod collide [a b] :default)
           (defmethod collide [(a craft) b] :craft-any)
           (defmethod collide [(a craft) (b rock)] :craft-rock)
           (defmethod collide [(a craft) (b (= :wall))] :craft-wall)
           [(collide (make craft) (make rock)) (collide (make craft) :wall)
            (collide (make craft) 1) (collide (make rock) (make craft))]"
          "[:craft-rock :craft-wall :craft-any :default]"))

(test dispatch-on-built-in-classes
  (evp-is "(defgeneric kind [x])
           (defmethod kind [x] :other)
           (defmethod kind [(x integer)] :integer)
           (defmethod kind [(x f32)] :f32)
           (defmethod kind [(x f64)] :f64)
           (defmethod kind [(x string)] :string)
           (defmethod kind [(x keyword)] :keyword)
           (defmethod kind [(x symbol)] :symbol)
           (defmethod kind [(x vector)] :vector)
           (defmethod kind [(x hash-map)] :map)
           (defmethod kind [(x hash-set)] :set)
           (defmethod kind [(x list)] :list)
           (defmethod kind [(x seq)] :seq)
           (defmethod kind [(x nil-class)] :nil)
           (defmethod kind [(x fn)] :fn)
           (defmethod kind [(x (= true))] :true)
           (map kind [1 1.0f 1.0 \"s\" :k 's [1] {:a 1}
                      {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18}
                      #{1} '(1) () (map inc [1]) nil inc true false])"
          (concatenate 'string "(:integer :f32 :f64 :string :keyword :symbol :vector :map :map "
                       ":set :list :list :seq :nil :fn :true :other)")))

(test standard-method-combination
  (logs "(defgeneric g [x])
         (defmethod g [x] (conj! log :primary-any) :result)
         (defmethod g [(x integer)] (conj! log :primary-int) (call-next-method))
         (defmethod g :before [(x integer)] (conj! log :before-int))
         (defmethod g :before [x] (conj! log :before-any))
         (defmethod g :after [x] (conj! log :after-any))
         (defmethod g :after [(x integer)] (conj! log :after-int))
         (defmethod g :around [(x integer)] (conj! log :around-in)
           (let [r (call-next-method)] (conj! log :around-out) r))
         (conj! log (g 5))"
        (concatenate 'string "[:around-in :before-int :before-any :primary-int :primary-any "
                     ":after-any :after-int :around-out :result]")))

(test call-next-method-and-next-method?
  (evp-is "(defgeneric step [x])
           (defmethod step [x] [:base x])
           (defmethod step [(x integer)] (call-next-method (* x 10)))
           (step 2)"
          "[:base 20]")
  (evp-is "(defgeneric nm [x])
           (defmethod nm [x] (next-method?))
           (defmethod nm [(x integer)] [(next-method?) (call-next-method)])
           (nm 1)"
          "[true false]")
  (evp-is "(defgeneric with-rest [x & more])
           (defmethod with-rest [x & more] [x more])
           (with-rest 1 2 3)"
          "[1 (2 3)]"))

(test generic-functions-are-values-and-redefinable
  (evp-is "(defgeneric twice [x]) (defmethod twice [x] (* 2 x)) (map twice [1 2])" "(2 4)")
  ;; A method without defgeneric creates the generic function.
  (evp-is "(defmethod implicit [(x integer)] :int) (implicit 1)" ":int")
  ;; defgeneric over a plain function turns it into a generic one; callers see it.
  (evp-is "(defn shout [x] :plain)
           (defn caller [] (shout 1))
           (defgeneric shout [x])
           (defmethod shout [(x integer)] :generic)
           (caller)"
          ":generic")
  ;; Redefining a method replaces it.
  (evp-is "(defgeneric r [x]) (defmethod r [x] 1) (defmethod r [x] 2) (r 0)" "2")
  (fails "(defgeneric two [a b]) (defmethod two [a] 1)" "do not match the generic function")
  (compile-fails "(defmethod q :sideways [x] 1)"
                 "a method qualifier must be :before, :after or :around")
  (evp-is "(defgeneric gm [x]) (defmethod gm [(x integer)] 1) (defmethod gm :after [x] 2)
           (count (generic-methods gm))"
          "2"))

(test methods-on-condition-types
  (evp-is "(defcondition oops [error])
           (defgeneric describe-it [c])
           (defmethod describe-it [c] :other)
           (defmethod describe-it [(c oops)] :oops)
           [(handler-case (error oops) (error [c] (describe-it c)))
            (handler-case (/ 1 0) (error [c] (describe-it c)))]"
          "[:oops :other]"))

;;; Inheritance

(test c3-linearization
  (evp-is "(defclass a [] (x)) (defclass b [a] (y)) (defclass c [a] (z)) (defclass d [b c])
           (map (comp name class-name) (take 4 (class-precedence-list d)))"
          "(\"d\" \"b\" \"c\" \"a\")")
  (evp-is "(defclass a [] (x :init 1)) (defclass b [a] (y :init 2)) (keys (make b))"
          "(:x :y)")
  (fails "(defclass a []) (defclass b [a]) (defclass bad [a b])" "have no consistent order (C3)")
  (fails "(defclass sub [integer])" "cannot be a superclass"))

;;; equiv and hash-of

(test instances-compare-by-identity-by-default
  (evp-is "(defclass p [] (x)) (let [a (make p :x 1)] [(= a a) (= a (make p :x 1))])"
          "[true false]"))

(test equiv-and-hash-of-can-be-specialized
  (evp-is "(defclass point [] (x) (y))
           (defmethod equiv [(a point) b]
             (and (instance? point b) (= (:x a) (:x b)) (= (:y a) (:y b))))
           (defmethod hash-of [(p point)] (hash-of [(:x p) (:y p)]))
           (let [a (make point :x 1 :y 2) b (make point :x 1 :y 2)]
             [(= a b) (= (hash-of a) (hash-of b)) (count (set [a b])) (get {a :found} b)
              (= a (make point :x 9 :y 2))])"
          "[true true 1 :found false]"))

(test specializing-only-equiv-warns
  (let ((warnings '()))
    (handler-bind ((skein.runtime:equiv-hash-warning
                     (lambda (w) (push (princ-to-string w) warnings) (muffle-warning w))))
      (ev "(defclass lonely [] (x)) (defmethod equiv [(a lonely) b] true)"))
    (is (= 1 (length warnings)))
    (is (search "specializes equiv but not hash-of" (first warnings)))))

;;; Redefinition (DESIGN §8.4)

(test redefining-a-class-updates-instances
  (evp-is "(defclass thing [] (a :init 1) (b :init 2))
           (def old (make thing :a 10))
           (defclass thing [] (a :init 1) (c :init (+ 3 4)))
           [(:a old) (:c old) (keys old) (get old :b :gone)]"
          "[10 7 (:a :c) :gone]")
  (evp-is "(defclass wrap [] (a :init 1))
           (def old (make wrap :a 5))
           (defclass wrap [] (a :cell :atom))
           @(:a old)"
          "5")
  (evp-is "(defclass unwrap [] (a :cell :atom :init 5))
           (def old (make unwrap))
           (defclass unwrap [] (a))
           (:a old)"
          "5")
  (evp-is "(defclass migrating [] (first-name :init \"Ada\"))
           (def old (make migrating))
           (defmethod update-instance-for-redefined-class [(o migrating) added discarded old-values]
             (reset! (:name o) (str (:first-name old-values) \"!\")))
           (defclass migrating [] (name :cell :atom))
           [@(:name old) (keys old)]"
          "[\"Ada!\" (:name)]")
  (evp-is "(defgeneric speak [x])
           (defclass dog [])
           (defmethod speak [(d dog)] :woof)
           (def rex (make dog))
           (defmethod speak [(d dog)] :bark)
           (speak rex)"
          ":bark"))
