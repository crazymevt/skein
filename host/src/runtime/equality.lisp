;;;; Value equality, hashing and ordering (DESIGN §7).

(in-package #:skein.runtime)

(defun sequential-p (x)
  "Return true if X is a sequential collection: a list, vector or seq. Sequential
collections are equal when their elements are equal, whatever their type."
  (typep x '(or plist empty-list pvector vseq aseq nseq kseq valseq sseq cseq lazy-seq)))

(defun map-p (x) (typep x '(or array-map hash-map)))

(defun float-equal (a b)
  (= a b))

(defun equiv (a b)
  "Skein's = on two values (DESIGN §7): value equality for numbers, strings, characters
and persistent collections; identity for everything else. Integers and floats are
never equal; f32 and f64 compare by value."
  (cond ((numberp a)
         (and (numberp b)
              (if (integerp a)
                  (and (integerp b) (= a b))
                  (and (floatp b) (float-equal a b)))))
        ((eq a b) t)
        ((stringp a) (and (stringp b) (string= a b)))
        ((sequential-p a) (and (sequential-p b) (sequential-equiv a b)))
        ((map-p a) (and (map-p b) (map-equiv a b)))
        ((hash-set-p a) (and (hash-set-p b) (set-equiv a b)))
        (t nil)))

(defun sequential-equiv (a b)
  (if (and (pvector-p a) (pvector-p b))
      (and (= (pvector-count a) (pvector-count b))
           (loop for i below (pvector-count a)
                 always (equiv (vector-nth a i) (vector-nth b i))))
      (and (or (not (counted-p a)) (not (counted-p b)) (= (count-of a) (count-of b)))
           (loop for sa = (seq a) then (seq-next sa)
                 for sb = (seq b) then (seq-next sb)
                 do (cond ((and (null sa) (null sb)) (return t))
                          ((or (null sa) (null sb)) (return nil))
                          ((not (equiv (seq-first sa) (seq-first sb))) (return nil)))))))

(defun map-equiv (a b)
  (and (= (map-count a) (map-count b))
       (not (reduced-p
             (map-reduce-kv a (lambda (acc k v)
                                (if (equiv v (map-get b k +not-found+))
                                    acc
                                    (make-reduced nil)))
                            t)))))

(defun set-equiv (a b)
  (and (= (count-of a) (count-of b))
       (do-seq (x a t)
         (unless (set-contains-p b x) (return nil)))))

;;; ------------------------------------------------------------------------------------
;;; Hashing. hash-of returns a 32-bit unsigned integer consistent with equiv.

(sb-ext:define-load-time-global **identity-hashes**
    (make-hash-table :test 'eq :weakness :key :synchronized t))
(sb-ext:define-load-time-global **identity-counter** 0)

(defun identity-hash (x)
  "A stable 32-bit hash for a value compared by identity."
  (let ((table **identity-hashes**))
    (sb-ext:with-locked-hash-table (table)
      (or (gethash x table)
          (setf (gethash x table)
                (mix32 (u32 (incf **identity-counter**))))))))

(defun mix-collection-hash (h count)
  (mix32 (u32 (logxor h (* count #x9E3779B9)))))

(defun ordered-hash (coll)
  (let ((h 1) (n 0))
    (do-seq (x coll)
      (setf h (u32 (+ (* 31 h) (hash-of x))))
      (incf n))
    (mix-collection-hash h n)))

(defmacro cached-hash (x accessor compute)
  `(or (,accessor ,x) (setf (,accessor ,x) ,compute)))

(defun hash-of (x)
  "Return a 32-bit hash of X consistent with equiv: equal values have equal hashes."
  (typecase x
    (null 0)
    ((eql t) 1231)
    (integer (if (typep x '(signed-byte 64))
                 (mix32 (fold32 x))
                 (mix32 (fold32 (sxhash x)))))
    (float (if (zerop x)
               0
               (mix32 (fold32 (sxhash (coerce x 'double-float))))))
    (character (mix32 (char-code x)))
    (string (string-hash32 x))
    (sym (sym-hash x))
    (kw (kw-hash x))
    (pvector (cached-hash x pvector-hash (ordered-hash x)))
    (plist (cached-hash x plist-hash (ordered-hash x)))
    (empty-list (mix-collection-hash 1 0))
    ((or vseq aseq nseq kseq valseq sseq cseq lazy-seq) (ordered-hash x))
    (array-map (cached-hash x array-map-hash (map-hash x)))
    (hash-map (cached-hash x hash-map-hash (map-hash x)))
    (hash-set (cached-hash x hash-set-hash
                           (let ((h 0))
                             (do-seq (e x) (setf h (u32 (+ h (hash-of e)))))
                             (mix-collection-hash h (count-of x)))))
    (t (if (false-p x) 1237 (identity-hash x)))))

(defun map-hash (m)
  (let ((h 0))
    (map-reduce-kv m (lambda (acc k v)
                       (setf h (u32 (+ h (logxor (hash-of k) (hash-of v)))))
                       acc)
                   nil)
    (mix-collection-hash h (map-count m))))

;;; ------------------------------------------------------------------------------------
;;; Ordering

(defun compare-values (a b)
  "Return a negative, zero or positive integer as A sorts before, with or after B.
Numbers compare by value; strings, chars, symbols and keywords in the usual order;
vectors by length, then element by element; nil sorts first and false before true."
  (flet ((cmp (lt eq) (cond (lt -1) (eq 0) (t 1)))
         (bad () (unsupported "cannot compare ~A with ~A"
                              (readable-string a) (readable-string b))))
    (cond ((and (null a) (null b)) 0)
          ((null a) -1)
          ((null b) 1)
          ((and (realp a) (realp b)) (cmp (< a b) (= a b)))
          ((and (stringp a) (stringp b))
           (cmp (string< a b) (string= a b)))
          ((and (characterp a) (characterp b)) (cmp (char< a b) (char= a b)))
          ((and (or (eq a t) (false-p a)) (or (eq b t) (false-p b)))
           (cmp (and (false-p a) (eq b t)) (eq a b)))
          ((or (and (sym-p a) (sym-p b)) (and (kw-p a) (kw-p b)))
           (let ((na (if (sym-p a) (sym-namespace a) (kw-namespace a)))
                 (nb (if (sym-p b) (sym-namespace b) (kw-namespace b))))
             (cond ((and na nb (string/= na nb)) (cmp (string< na nb) nil))
                   ((and (null na) nb) -1)
                   ((and na (null nb)) 1)
                   (t (let ((xa (if (sym-p a) (sym-name a) (kw-name a)))
                            (xb (if (sym-p b) (sym-name b) (kw-name b))))
                        (cmp (string< xa xb) (string= xa xb)))))))
          ((and (pvector-p a) (pvector-p b))
           (if (/= (pvector-count a) (pvector-count b))
               (cmp (< (pvector-count a) (pvector-count b)) nil)
               (loop for i below (pvector-count a)
                     for c = (compare-values (vector-nth a i) (vector-nth b i))
                     unless (zerop c) return c
                     finally (return 0))))
          (t (bad)))))
