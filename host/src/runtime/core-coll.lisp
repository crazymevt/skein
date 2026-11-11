;;;; skein.core collection, seq and transducer functions (DESIGN §6.2, §7).
;;;; Lazy seqs are realized one element at a time (D-032).

(in-package #:skein.runtime)

(defmacro lazy (&body body)
  "Return a lazy seq whose contents BODY computes when first needed."
  `(make-lazy-seq (lambda () ,@body)))

(defun skein-apply (f args)
  "Call the Skein callable F with the CL list ARGS."
  (if (functionp f) (apply f args) (apply #'invoke-other f nil args)))

(declaim (inline unreduce))
(defun unreduce (x)
  "Return the value inside X if it is a REDUCED, else X."
  (if (reduced-p x) (reduced-value x) x))

(defmacro rf-lambda ((acc x) &key (init nil) (complete acc) step)
  "A reducing function with arities 0 (INIT), 1 (COMPLETE) and 2 (STEP)."
  (let ((acc-p (gensym "ACC-P")) (x-p (gensym "X-P")))
    `(lambda (&optional (,acc nil ,acc-p) (,x nil ,x-p))
       (declare (ignorable ,acc ,x))
       (cond (,x-p ,step) (,acc-p ,complete) (t ,init)))))

(defmacro transducer ((rf) &key (init `(scall ,rf)) (complete `(scall ,rf acc)) step
                                (state nil))
  "Return a transducer: a function of a reducing function RF. STATE is a list of
bindings created once per application, for stateful transducers."
  `(lambda (,rf)
     (let* ,state
       (rf-lambda (acc x) :init ,init :complete ,complete :step ,step))))

;;; ------------------------------------------------------------------------------------
;;; Reduction

(defun reduce-coll (f acc coll)
  "Reduce COLL with the Skein callable F starting from ACC. Stops early when F returns a
REDUCED; returns the unwrapped result."
  (flet ((done (acc) (unreduce acc)))
    (typecase coll
      (null acc)
      (pvector
       (loop for i below (pvector-count coll)
             do (setf acc (scall f acc (vector-nth coll i)))
                (when (reduced-p acc) (return)))
       (done acc))
      ((or array-map hash-map)
       (done (map-reduce-kv coll (lambda (acc k v) (scall f acc (make-entry k v))) acc)))
      (eduction (transduce-coll (eduction-xform coll)
                                (rf-lambda (a x) :init (scall f) :step (scall f a x))
                                acc (eduction-coll coll)))
      (t (do-seq (x coll)
           (setf acc (scall f acc x))
           (when (reduced-p acc) (return)))
         (done acc)))))

(defun transduce-coll (xform f init coll)
  (let* ((xf (scall xform f))
         (result (reduce-coll xf init coll)))
    (scall xf result)))

;;; ------------------------------------------------------------------------------------
;;; Constructors

(defcore "list" (&rest xs) (list-from-cl xs))
(defcore "vector" (&rest xs) (vector-from-list xs))
(defcore "hash-map" (&rest kvs)
  (when (oddp (length kvs)) (unsupported "hash-map needs an even number of arguments"))
  (map-from-pairs kvs))
(defcore "hash-set" (&rest xs) (set-from-cl xs))
(defcore "vec" (coll)
  (if (pvector-p coll) coll (vector-from-list (seq-to-cl coll))))
(defcore "set" (coll)
  (if (hash-set-p coll) coll (set-from-cl (seq-to-cl coll))))
(defcore "list*" (&rest args)
  (let ((items (butlast args)) (tail (car (last args))))
    (reduce (lambda (x acc) (coll-cons x acc)) items :from-end t
                                                       :initial-value (or (seq tail) nil))))

(defun literal-error (what item)
  (error 'unsupported-operation-error
         :location nil :message (format nil "duplicate ~A ~A in a ~A literal" what
                                        (readable-string item)
                                        (if (string= what "key") "map" "set"))))

(defcore "%map-literal" (&rest kvs)
  (let ((m (map-from-pairs kvs)))
    (unless (= (* 2 (map-count m)) (length kvs))
      (loop for (k) on kvs by #'cddr
            for seen = (list k) then (cons k seen)
            when (find k (rest seen) :test #'equiv) do (literal-error "key" k)))
    m))

(defcore "%set-literal" (&rest xs)
  (let ((s (set-from-cl xs)))
    (unless (= (count-of s) (length xs))
      (loop for (x . more) on xs
            when (find x more :test #'equiv) do (literal-error "element" x)))
    s))

(defcore "%lazy-seq" (thunk) (make-lazy-seq (lambda () (scall thunk))))

;;; ------------------------------------------------------------------------------------
;;; Predicates

(defmacro defpredicate (name (x) test)
  `(defcore ,name (,x) (bool ,test)))

(defpredicate "seq?" (x) (typep x '(or plist empty-list vseq aseq nseq kseq valseq sseq cseq
                                    lazy-seq)))
(defpredicate "list?" (x) (typep x '(or plist empty-list)))
(defpredicate "vector?" (x) (pvector-p x))
(defpredicate "map?" (x) (map-p x))
(defpredicate "set?" (x) (hash-set-p x))
(defpredicate "coll?" (x) (or (sequential-p x) (map-p x) (hash-set-p x)))
(defpredicate "sequential?" (x) (sequential-p x))
(defpredicate "associative?" (x) (or (map-p x) (pvector-p x)))
(defpredicate "counted?" (x) (and x (counted-p x)))
(defpredicate "empty?" (x) (null (seq x)))
(defpredicate "fn?" (x) (functionp x))
(defpredicate "ifn?" (x) (or (functionp x) (kw-p x) (map-p x) (hash-set-p x) (pvector-p x)))
(defpredicate "string?" (x) (stringp x))
(defpredicate "keyword?" (x) (kw-p x))
(defpredicate "symbol?" (x) (sym-p x))
(defpredicate "number?" (x) (realp x))
(defpredicate "integer?" (x) (integerp x))
(defpredicate "float?" (x) (floatp x))
(defpredicate "char?" (x) (characterp x))
(defpredicate "boolean?" (x) (or (eq x t) (false-p x)))
(defpredicate "reduced?" (x) (reduced-p x))
(defpredicate "realized?" (x) (and (lazy-seq-p x) (null (lazy-seq-fn x))))

;;; ------------------------------------------------------------------------------------
;;; Access

(defcore "count" (coll) (count-of coll))
(defcore "nth" (coll i &optional (not-found nil not-found-p))
  (if not-found-p (coll-nth coll i not-found) (coll-nth coll i)))
(defcore "get" (coll key &optional not-found) (coll-get coll key not-found))
(defcore "get-in" (coll keys &optional not-found)
  (let ((x coll))
    (do-seq (k keys x)
      (setf x (coll-get x k +not-found+))
      (when (eq x +not-found+) (return not-found)))))
(defcore "contains?" (coll key) (bool (coll-contains-p coll key)))
(defcore "find" (m key)
  (and m (map-contains-p m key) (make-entry key (map-get m key))))
(defcore "seq" (coll) (seq coll))
(defcore "first" (coll) (first* coll))
(defcore "rest" (coll) (rest* coll))
(defcore "next" (coll) (next* coll))
(defcore "second" (coll) (first* (next* coll)))
(defcore "ffirst" (coll) (first* (first* coll)))
(defcore "nnext" (coll) (next* (next* coll)))
(defcore "last" (coll)
  (if (pvector-p coll)
      (and (plusp (pvector-count coll)) (vector-nth coll (1- (pvector-count coll))))
      (let ((last nil)) (do-seq (x coll last) (setf last x)))))
(defcore "butlast" (coll)
  (let ((items (butlast (seq-to-cl coll)))) (and items (list-from-cl items))))
(defcore "peek" (coll)
  (typecase coll
    (null nil)
    (pvector (and (plusp (pvector-count coll)) (vector-nth coll (1- (pvector-count coll)))))
    ((or plist empty-list) (first* coll))
    (t (unsupported "cannot peek at ~A" (readable-string coll)))))
(defcore "pop" (coll)
  (typecase coll
    (null nil)
    (pvector (pvector-pop coll))
    (plist (plist-rest coll))
    (empty-list (unsupported "cannot pop an empty list"))
    (t (unsupported "cannot pop ~A" (readable-string coll)))))
(defcore "keys" (m)
  (cond ((instance-p m) (object-keys m))
        ((struct-instance-def m) (struct-keys m))
        (t (let ((s (seq m))) (and s (make-kseq s))))))
(defcore "vals" (m) (let ((s (seq m))) (and s (make-valseq s))))
(defcore "key" (entry) (vector-nth entry 0))
(defcore "val" (entry) (vector-nth entry 1))
(defcore "empty" (coll) (coll-empty coll))
(defcore "not-empty" (coll) (and (seq coll) coll))

;;; ------------------------------------------------------------------------------------
;;; Building new collections

(defcore "conj" (&optional (coll nil coll-p) &rest xs)
  (cond ((not coll-p) +empty-vector+)
        (t (dolist (x xs coll) (setf coll (coll-conj coll x))))))
(defcore "cons" (x coll) (coll-cons x coll))
(defcore "assoc" (coll key value &rest kvs)
  (setf coll (coll-assoc coll key value))
  (when (oddp (length kvs)) (unsupported "assoc needs an even number of keys and values"))
  (loop for (k v) on kvs by #'cddr do (setf coll (coll-assoc coll k v)))
  coll)
(defcore "dissoc" (coll &rest keys)
  (dolist (k keys coll) (setf coll (coll-dissoc coll k))))
(defcore "disj" (set &rest xs)
  (if (null set) nil (dolist (x xs set) (setf set (set-disj set x)))))
(defcore "update" (coll key f &rest args)
  (coll-assoc coll key (skein-apply f (list* (coll-get coll key) args))))
(defun assoc-in (coll keys value)
  (let ((k (first* keys)) (more (next* keys)))
    (coll-assoc coll k (if more (assoc-in (coll-get coll k) more value) value))))
(defcore "assoc-in" (coll keys value) (assoc-in coll keys value))
(defun update-in (coll keys f args)
  (let ((k (first* keys)) (more (next* keys)))
    (coll-assoc coll k (if more
                           (update-in (coll-get coll k) more f args)
                           (skein-apply f (list* (coll-get coll k) args))))))
(defcore "update-in" (coll keys f &rest args) (update-in coll keys f args))
(defcore "merge" (&rest maps)
  (when (some #'identity maps)
    (reduce (lambda (acc m) (if m (coll-conj (or acc +empty-map+) m) acc)) maps)))
(defcore "merge-with" (f &rest maps)
  (when (some #'identity maps)
    (reduce (lambda (acc m)
              (if (null m)
                  acc
                  (let ((result (or acc +empty-map+)))
                    (map-reduce-kv m (lambda (a k v)
                                       (declare (ignore a))
                                       (setf result
                                             (map-assoc result k
                                                        (if (map-contains-p result k)
                                                            (scall f (map-get result k) v)
                                                            v))))
                                   nil)
                    result)))
            maps)))
(defcore "select-keys" (m keys)
  (let ((result +empty-map+))
    (do-seq (k keys result)
      (when (coll-contains-p m k) (setf result (map-assoc result k (coll-get m k)))))))
(defcore "zipmap" (keys vals)
  (let ((tm (map-transient +empty-map+)))
    (loop for ks = (seq keys) then (seq-next ks)
          for vs = (seq vals) then (seq-next vs)
          while (and ks vs)
          do (tmap-assoc tm (seq-first ks) (seq-first vs)))
    (tmap-persistent tm)))

;;; ------------------------------------------------------------------------------------
;;; Transients

(defun transient-of (coll)
  (typecase coll
    (pvector (vector-transient coll))
    ((or array-map hash-map) (map-transient coll))
    (hash-set (make-tset (map-transient (hash-set-map coll))))
    (t (unsupported "cannot make a transient of ~A" (readable-string coll)))))

(defun conj! (tc x)
  (typecase tc
    (tvector (tvector-conj tc x))
    (tmap (unless (and (pvector-p x) (= (pvector-count x) 2))
            (unsupported "conj! on a map needs a [key value] vector"))
          (tmap-assoc tc (vector-nth x 0) (vector-nth x 1)))
    (tset (tmap-assoc (tset-tmap tc) x x) tc)
    (t (unsupported "conj! needs a transient, not ~A" (readable-string tc)))))

(defun persistent! (tc)
  (typecase tc
    (tvector (tvector-persistent tc))
    (tmap (tmap-persistent tc))
    (tset (make-hash-set (tmap-persistent (tset-tmap tc))))
    (t (unsupported "persistent! needs a transient, not ~A" (readable-string tc)))))

(defcore "transient" (coll) (transient-of coll))
(defcore "persistent!" (tc) (persistent! tc))
(defcore "conj!" (&optional (tc nil tc-p) (x nil x-p))
  (cond ((not tc-p) (vector-transient +empty-vector+))
        ((not x-p) tc)
        (t (conj! tc x))))
(defcore "assoc!" (tc key value &rest kvs)
  (flet ((one (k v)
           (typecase tc
             (tvector (tvector-assoc tc k v))
             (tmap (tmap-assoc tc k v))
             (t (unsupported "assoc! needs a transient vector or map")))))
    (one key value)
    (loop for (k v) on kvs by #'cddr do (one k v))
    tc))
(defcore "dissoc!" (tc &rest keys)
  (unless (tmap-p tc) (unsupported "dissoc! needs a transient map"))
  (dolist (k keys tc) (tmap-dissoc tc k)))
(defcore "disj!" (tc &rest xs)
  (unless (tset-p tc) (unsupported "disj! needs a transient set"))
  (dolist (x xs tc) (tmap-dissoc (tset-tmap tc) x)))
(defcore "pop!" (tc)
  (unless (tvector-p tc) (unsupported "pop! needs a transient vector"))
  (tvector-pop tc))

;;; ------------------------------------------------------------------------------------
;;; reduce, into and transducer entry points

(defcore "reduced" (x) (make-reduced x))
(defcore "unreduced" (x) (unreduce x))
(defcore "ensure-reduced" (x) (if (reduced-p x) x (make-reduced x)))

(defcore "reduce" (f init-or-coll &optional (coll nil coll-p))
  (if coll-p
      (reduce-coll f init-or-coll coll)
      (let ((s (seq init-or-coll)))
        (if s
            (reduce-coll f (seq-first s) (seq-rest s))
            (scall f)))))

(defcore "reduce-kv" (f init coll)
  (typecase coll
    (null init)
    ((or array-map hash-map)
     (unreduce (map-reduce-kv coll (lambda (acc k v) (scall f acc k v)) init)))
    (pvector (let ((acc init))
               (loop for i below (pvector-count coll)
                     do (setf acc (scall f acc i (vector-nth coll i)))
                        (when (reduced-p acc) (return)))
               (unreduce acc)))
    (t (unsupported "reduce-kv needs a map or vector, not ~A" (readable-string coll)))))

(defcore "completing" (f &optional (cf nil cf-p))
  (rf-lambda (acc x) :init (scall f) :complete (if cf-p (scall cf acc) acc)
                     :step (scall f acc x)))

(defcore "transduce" (xform f init-or-coll &optional (coll nil coll-p))
  (if coll-p
      (transduce-coll xform f init-or-coll coll)
      (transduce-coll xform f (scall f) init-or-coll)))

(defun into-coll (to from &optional xform)
  (if (typep to '(or pvector array-map hash-map hash-set))
      (let ((rf (rf-lambda (acc x) :init (transient-of to) :step (conj! acc x))))
        (persistent! (if xform
                         (transduce-coll xform rf (transient-of to) from)
                         (reduce-coll rf (transient-of to) from))))
      (let ((rf (rf-lambda (acc x) :init to :step (coll-conj acc x))))
        (if xform (transduce-coll xform rf to from) (reduce-coll rf to from)))))

(defcore "into" (&optional (to nil to-p) (xform-or-from nil from-p) (from nil xform-p))
  (cond ((not to-p) +empty-vector+)
        ((not from-p) to)
        (xform-p (into-coll to from xform-or-from))
        (t (into-coll to xform-or-from))))

(defun transformed-seq (xform coll)
  "A lazy seq of COLL's elements passed through the transducer XFORM."
  (let* ((buffer '())
         (rf (rf-lambda (acc x) :step (progn (push x buffer) acc)))
         (xf (scall xform rf))
         (source (seq coll))
         (done nil))
    (labels ((next-chunk ()
               (lazy
                 (loop
                   (when buffer
                     (let ((items (reverse buffer)))
                       (setf buffer '())
                       (return (reduce (lambda (x acc) (make-cseq x acc)) items
                                       :from-end t :initial-value (next-chunk)))))
                   (when done (return nil))
                   (if source
                       (let ((r (scall xf nil (seq-first source))))
                         (setf source (seq-next source))
                         (when (reduced-p r)
                           (setf source nil)))
                       (progn (setf done t)
                              (scall xf nil)))))))
      (next-chunk))))

(defcore "sequence" (xform-or-coll &optional (coll nil coll-p))
  (if coll-p
      (transformed-seq xform-or-coll coll)
      (or (seq xform-or-coll) +empty-list+)))

(defun compose (fns)
  (if (null fns)
      #'identity
      (let ((fns (reverse fns)))
        (lambda (&rest args)
          (let ((result (skein-apply (first fns) args)))
            (dolist (f (rest fns) result)
              (setf result (scall f result))))))))

(defcore "comp" (&rest fns) (compose fns))

(defcore "eduction" (&rest xforms-and-coll)
  (make-eduction (compose (butlast xforms-and-coll)) (car (last xforms-and-coll))))

(defcore "%eduction" (xform coll seq-fn reduce-fn)
  ;; The native library (lib/skein/core/native.skn) makes eductions with the functions
  ;; the native runtime calls to seq and reduce them; Phase 0 needs only XFORM and COLL.
  (declare (ignore seq-fn reduce-fn))
  (make-eduction xform coll))

(defun eduction-seq (e)
  (transformed-seq (eduction-xform e) (eduction-coll e)))

;;; ------------------------------------------------------------------------------------
;;; Seq functions. Called with a collection they return lazy seqs; called without one,
;;; most return transducers.

(defun lazy-map (f colls)
  (lazy
    (let ((seqs (mapcar #'seq colls)))
      (when (every #'identity seqs)
        (make-cseq (skein-apply f (mapcar #'seq-first seqs))
                   (lazy-map f (mapcar #'seq-rest seqs)))))))

(defcore "map" (f &rest colls)
  (if colls
      (lazy-map f colls)
      (transducer (rf) :step (scall rf acc (scall f x)))))

(defcore "mapv" (f &rest colls) (into-coll +empty-vector+ (lazy-map f colls)))

(defcore "map-indexed" (f &optional (coll nil coll-p))
  (if coll-p
      (labels ((walk (i coll)
                 (lazy (let ((s (seq coll)))
                         (and s (make-cseq (scall f i (seq-first s))
                                           (walk (1+ i) (seq-rest s))))))))
        (walk 0 coll))
      (transducer (rf) :state ((i -1)) :step (scall rf acc (scall f (incf i) x)))))

(defun lazy-filter (pred coll keep-p)
  (lazy
    (loop for s = (seq coll) then (seq-next s)
          while s
          do (let ((x (seq-first s)))
               (when (eq keep-p (truthy-p (scall pred x)))
                 (return (make-cseq x (lazy-filter pred (seq-rest s) keep-p))))))))

(defcore "filter" (pred &optional (coll nil coll-p))
  (if coll-p
      (lazy-filter pred coll t)
      (transducer (rf) :step (if (truthy-p (scall pred x)) (scall rf acc x) acc))))

(defcore "filterv" (pred coll) (into-coll +empty-vector+ (lazy-filter pred coll t)))

(defcore "remove" (pred &optional (coll nil coll-p))
  (if coll-p
      (lazy-filter pred coll nil)
      (transducer (rf) :step (if (truthy-p (scall pred x)) acc (scall rf acc x)))))

(defcore "keep" (f &optional (coll nil coll-p))
  (if coll-p
      (labels ((walk (coll)
                 (lazy (loop for s = (seq coll) then (seq-next s)
                             while s
                             do (let ((v (scall f (seq-first s))))
                                  (unless (null v)
                                    (return (make-cseq v (walk (seq-rest s))))))))))
        (walk coll))
      (transducer (rf) :step (let ((v (scall f x))) (if (null v) acc (scall rf acc v))))))

(defcore "take" (n &optional (coll nil coll-p))
  (if coll-p
      (labels ((walk (n coll)
                 (lazy (when (plusp n)
                         (let ((s (seq coll)))
                           (and s (make-cseq (seq-first s) (walk (1- n) (seq-rest s)))))))))
        (walk n coll))
      (transducer (rf) :state ((left n))
                       :step (let ((acc (if (plusp left) (scall rf acc x) acc)))
                               (decf left)
                               (if (plusp left) acc (if (reduced-p acc) acc
                                                        (make-reduced acc)))))))

(defcore "drop" (n &optional (coll nil coll-p))
  (if coll-p
      (lazy (loop for s = (seq coll) then (seq-next s)
                  for i from 0
                  while (and s (< i n))
                  finally (return s)))
      (transducer (rf) :state ((left n))
                       :step (if (plusp left) (progn (decf left) acc) (scall rf acc x)))))

(defcore "take-while" (pred &optional (coll nil coll-p))
  (if coll-p
      (labels ((walk (coll)
                 (lazy (let ((s (seq coll)))
                         (and s (truthy-p (scall pred (seq-first s)))
                              (make-cseq (seq-first s) (walk (seq-rest s))))))))
        (walk coll))
      (transducer (rf) :step (if (truthy-p (scall pred x))
                                 (scall rf acc x)
                                 (make-reduced acc)))))

(defcore "drop-while" (pred &optional (coll nil coll-p))
  (if coll-p
      (lazy (loop for s = (seq coll) then (seq-next s)
                  while (and s (truthy-p (scall pred (seq-first s))))
                  finally (return s)))
      (transducer (rf) :state ((dropping t))
                       :step (if (and dropping (truthy-p (scall pred x)))
                                 acc
                                 (progn (setf dropping nil) (scall rf acc x))))))

(defun lazy-concat (colls)
  (lazy
    (loop while colls
          do (let ((s (seq (first colls))))
               (if s
                   (return (make-cseq (seq-first s)
                                      (lazy-concat (cons (seq-rest s) (rest colls)))))
                   (pop colls))))))

(defcore "concat" (&rest colls) (lazy-concat colls))

(defun cat-rf (rf)
  (rf-lambda (acc x) :init (scall rf) :complete (scall rf acc)
                     :step (let ((r (reduce-coll (lambda (a y)
                                                   (let ((r (scall rf a y)))
                                                     (if (reduced-p r) (make-reduced r) r)))
                                                 acc x)))
                             r)))

(defcore "cat" (rf) (cat-rf rf))

(defcore "mapcat" (f &rest colls)
  (if colls
      (lazy-concat-seq (lazy-map f colls))
      (lambda (rf) (funcall (transducer (rf2) :step (scall rf2 acc (scall f x)))
                            (cat-rf rf)))))

(defun lazy-concat-seq (seqs)
  "Concatenate a (possibly lazy, possibly infinite) seq of collections."
  (labels ((walk (current more)
             (lazy (loop
                     (let ((s (seq current)))
                       (when s
                         (return (make-cseq (seq-first s) (walk (seq-rest s) more))))
                       (let ((m (seq more)))
                         (unless m (return nil))
                         (setf current (seq-first m) more (seq-rest m))))))))
    (walk nil seqs)))

(defcore "range" (&optional (a nil a-p) (b nil b-p) (step 1))
  (multiple-value-bind (start end)
      (cond ((not a-p) (values 0 nil))
            ((not b-p) (values 0 a))
            (t (values a b)))
    (labels ((walk (i)
               (lazy (when (or (null end)
                               (if (plusp step) (< i end) (if (minusp step) (> i end) t)))
                       (make-cseq i (walk (+ i step)))))))
      (walk start))))

(defcore "repeat" (n-or-x &optional (x nil x-p))
  (labels ((walk (n)
             (lazy (when (or (null n) (plusp n))
                     (make-cseq (if x-p x n-or-x) (walk (and n (1- n))))))))
    (walk (if x-p n-or-x nil))))

(defcore "repeatedly" (n-or-f &optional (f nil f-p))
  (labels ((walk (n)
             (lazy (when (or (null n) (plusp n))
                     (make-cseq (scall (if f-p f n-or-f)) (walk (and n (1- n))))))))
    (walk (if f-p n-or-f nil))))

(defcore "iterate" (f x)
  (labels ((walk (x) (lazy (make-cseq x (walk (scall f x)))))) (walk x)))

(defcore "cycle" (coll)
  (if (null (seq coll))
      +empty-list+
      (labels ((walk (s) (lazy (let ((s (or (seq s) (seq coll))))
                                 (make-cseq (seq-first s) (walk (seq-rest s)))))))
        (walk coll))))

(defcore "interleave" (&rest colls)
  (labels ((walk (colls)
             (lazy (let ((seqs (mapcar #'seq colls)))
                     (when (and seqs (every #'identity seqs))
                       (reduce (lambda (s acc) (make-cseq (seq-first s) acc)) seqs
                               :from-end t
                               :initial-value (walk (mapcar #'seq-rest seqs))))))))
    (walk colls)))

(defcore "interpose" (sep &optional (coll nil coll-p))
  (if coll-p
      (lazy (let ((s (seq coll)))
              (and s (make-cseq (seq-first s)
                                (lazy-concat-seq
                                 (lazy-map (lambda (x) (list-from-cl (list sep x)))
                                           (list (seq-rest s))))))))
      (transducer (rf) :state ((started nil))
                       :step (if started
                                 (let ((r (scall rf acc sep)))
                                   (if (reduced-p r) r (scall rf r x)))
                                 (progn (setf started t) (scall rf acc x))))))

(defun take-cl (n s)
  "Return up to N elements from the seq S as a CL list, and the seq after them."
  (let ((items '()))
    (loop repeat n while s do (push (seq-first s) items) (setf s (seq-next s)))
    (values (nreverse items) s)))

(defcore "partition" (n &optional (step-or-coll nil sc-p) (coll nil coll-p))
  (unless sc-p (unsupported "partition needs a collection"))
  (let ((step (if coll-p step-or-coll n))
        (coll (if coll-p coll step-or-coll)))
    (labels ((walk (coll)
               (lazy (let ((items (take-cl n (seq coll))))
                       (when (= (length items) n)
                         (make-cseq (list-from-cl items)
                                    (walk (funcall (core-fn "drop") step coll))))))))
      (walk coll))))

(defcore "partition-all" (n &optional (step-or-coll nil sc-p) (coll nil coll-p))
  (if (not sc-p)
      (transducer (rf) :state ((buffer '()))
                       :complete (let ((acc (if buffer
                                                (let ((v (vector-from-list (reverse buffer))))
                                                  (setf buffer '())
                                                  (unreduce (scall rf acc v)))
                                                acc)))
                                   (scall rf acc))
                       :step (progn (push x buffer)
                                    (if (= (length buffer) n)
                                        (let ((v (vector-from-list (reverse buffer))))
                                          (setf buffer '())
                                          (scall rf acc v))
                                        acc)))
      (let ((step (if coll-p step-or-coll n))
            (coll (if coll-p coll step-or-coll)))
        (labels ((walk (coll)
                   (lazy (let ((items (take-cl n (seq coll))))
                           (when items
                             (make-cseq (list-from-cl items)
                                        (walk (funcall (core-fn "drop") step coll))))))))
          (walk coll)))))

(defcore "distinct" (&optional (coll nil coll-p))
  (if coll-p
      (labels ((walk (coll seen)
                 (lazy (loop for s = (seq coll) then (seq-next s)
                             while s
                             do (let ((x (seq-first s)))
                                  (unless (set-contains-p seen x)
                                    (return (make-cseq x (walk (seq-rest s)
                                                               (set-conj seen x))))))))))
        (walk coll +empty-set+))
      (transducer (rf) :state ((seen +empty-set+))
                       :step (if (set-contains-p seen x)
                                 acc
                                 (progn (setf seen (set-conj seen x)) (scall rf acc x))))))

(defcore "dedupe" (&optional (coll nil coll-p))
  (let ((xf (transducer (rf) :state ((prev +not-found+))
                             :step (if (and (not (eq prev +not-found+)) (equiv prev x))
                                       acc
                                       (progn (setf prev x) (scall rf acc x))))))
    (if coll-p (transformed-seq xf coll) xf)))

(defcore "reverse" (coll)
  (let ((result +empty-list+)) (do-seq (x coll result) (setf result (coll-cons x result)))))

(defun comparator (f)
  "Turn a Skein comparator (returning a number or a boolean) into a CL predicate."
  (lambda (a b)
    (let ((r (scall f a b)))
      (if (realp r) (minusp r) (truthy-p r)))))

(defun sort-cl (items pred key)
  (stable-sort (coerce items 'simple-vector) pred :key key))

(defcore "sort" (cmp-or-coll &optional (coll nil coll-p))
  (let* ((items (seq-to-cl (if coll-p coll cmp-or-coll)))
         (pred (if coll-p (comparator cmp-or-coll)
                   (lambda (a b) (minusp (compare-values a b))))))
    (list-from-cl (coerce (sort-cl items pred #'identity) 'list))))

(defcore "sort-by" (keyfn cmp-or-coll &optional (coll nil coll-p))
  (let* ((items (seq-to-cl (if coll-p coll cmp-or-coll)))
         (pred (if coll-p (comparator cmp-or-coll)
                   (lambda (a b) (minusp (compare-values a b))))))
    (list-from-cl (coerce (sort-cl items pred (lambda (x) (scall keyfn x))) 'list))))

(defcore "flatten" (coll)
  (labels ((walk (x acc)
             (if (sequential-p x)
                 (progn (do-seq (y x) (setf acc (walk y acc))) acc)
                 (cons x acc))))
    (list-from-cl (nreverse (let ((acc '())) (do-seq (x coll acc) (setf acc (walk x acc))))))))

(defcore "frequencies" (coll)
  (let ((tm (map-transient +empty-map+)))
    (do-seq (x coll) (tmap-assoc tm x (1+ (tmap-get tm x 0))))
    (tmap-persistent tm)))

(defcore "group-by" (f coll)
  (let ((tm (map-transient +empty-map+)))
    (do-seq (x coll)
      (let ((k (scall f x)))
        (tmap-assoc tm k (vector-conj (tmap-get tm k +empty-vector+) x))))
    (tmap-persistent tm)))

(defcore "some" (pred coll)
  (do-seq (x coll nil)
    (let ((r (scall pred x))) (when (truthy-p r) (return r)))))
(defcore "every?" (pred coll)
  (bool (do-seq (x coll t) (unless (truthy-p (scall pred x)) (return nil)))))
(defcore "not-every?" (pred coll)
  (bool (do-seq (x coll nil) (unless (truthy-p (scall pred x)) (return t)))))
(defcore "not-any?" (pred coll)
  (bool (do-seq (x coll t) (when (truthy-p (scall pred x)) (return nil)))))

(defcore "nthrest" (coll n)
  (loop for s = coll then (rest* s) repeat n finally (return s)))
(defcore "nthnext" (coll n)
  (loop for s = (seq coll) then (seq-next s) repeat n while s finally (return s)))
(defcore "split-at" (n coll)
  (vector-from-list (list (funcall (core-fn "take") n coll) (funcall (core-fn "drop") n coll))))
(defcore "split-with" (pred coll)
  (vector-from-list (list (funcall (core-fn "take-while") pred coll)
                          (funcall (core-fn "drop-while") pred coll))))
(defcore "doall" (coll) (do-seq (x coll coll) (declare (ignore x))))
(defcore "dorun" (coll) (do-seq (x coll nil) (declare (ignore x))))

;;; ------------------------------------------------------------------------------------
;;; Functions

(defcore "apply" (f &rest args)
  (skein-apply f (append (butlast args) (seq-to-cl (car (last args))))))
(defcore "partial" (f &rest bound)
  (lambda (&rest args) (skein-apply f (append bound args))))
(defcore "complement" (f)
  (lambda (&rest args) (bool (not (truthy-p (skein-apply f args))))))
(defcore "constantly" (x) (lambda (&rest args) (declare (ignore args)) x))
(defcore "juxt" (&rest fns)
  (lambda (&rest args) (vector-from-list (mapcar (lambda (f) (skein-apply f args)) fns))))
(defcore "fnil" (f default)
  (lambda (x &rest args) (skein-apply f (cons (if (null x) default x) args))))

;;; ------------------------------------------------------------------------------------
;;; Equality, hashing, ordering, names

(defcore "=" (x &rest more) (bool (every (lambda (y) (equiv x y)) more)))
(defcore "not=" (x &rest more) (bool (notevery (lambda (y) (equiv x y)) more)))
(defcore "hash-of" (x) (hash-of x))
(defcore "compare" (a b) (compare-values a b))

(defcore "name" (x)
  (typecase x
    (string x)
    (sym (sym-name x))
    (kw (kw-name x))
    (t (unsupported "name needs a string, symbol or keyword, not ~A" (readable-string x)))))
(defcore "namespace" (x)
  (typecase x
    (sym (sym-namespace x))
    (kw (kw-namespace x))
    (t (unsupported "namespace needs a symbol or keyword, not ~A" (readable-string x)))))
(defcore "keyword" (a &optional (b nil b-p))
  (cond (b-p (intern-kw b a))
        ((kw-p a) a)
        ((sym-p a) (intern-kw (sym-name a) (sym-namespace a)))
        ((stringp a) (intern-kw a))
        (t nil)))
(defcore "symbol" (a &optional (b nil b-p))
  (cond (b-p (intern-sym b a))
        ((sym-p a) a)
        ((kw-p a) (intern-sym (kw-name a) (kw-namespace a)))
        ((stringp a) (intern-sym a))
        (t (unsupported "symbol needs a string, keyword or symbol"))))
(defcore "subs" (s start &optional (end (length s))) (subseq s start end))

(defun core-fn (name)
  "Return the CL function in the skein.core var NAME."
  (var-value (find-own-var +core+ name)))

;;; String cursors (D-019, M2.11): natively byte offsets; Phase 0's strings index
;;; characters in O(1), so here a cursor is a character index. skein.string treats cursors
;;; as opaque, so both give the same results.

(defcore "%string-end" (s) (length s))
(defcore "%string-char-at" (s c) (if (< c (length s)) (char s c) nil))
(defcore "%string-next" (s c) (min (1+ c) (length s)))
(defcore "%string-slice" (s from to) (subseq s from to))
(defcore "%string-find" (s part from &optional last)
  (if (truthy-p last)
      (search part s :from-end t)
      (search part s :start2 from)))
(defcore "%string-cursor->index" (s c) (declare (ignore s)) c)
(defcore "%string-index->cursor" (s i)
  (unless (<= 0 i (length s))
    (skein-error 'skein-error nil "%string-index->cursor: no index ~D in the string" i))
  i)
(defcore "%string-ascii-case" (s upper)
  ;; ASCII letters only, as natively.
  (map 'string (lambda (ch)
                 (cond ((and (truthy-p upper) (char<= #\a ch #\z)) (char-upcase ch))
                       ((and (not (truthy-p upper)) (char<= #\A ch #\Z)) (char-downcase ch))
                       (t ch)))
       s))
