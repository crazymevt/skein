;;;; The seq abstraction, lists, sets and generic collection operations (DESIGN §7).

(in-package #:skein.runtime)

(defmacro scall (f &rest args)
  "Call the Skein callable F (a function, keyword, map, set or vector) with ARGS."
  (let ((g (gensym "F")))
    `(let ((,g ,f))
       (if (functionp ,g) (funcall ,g ,@args) (invoke-other ,g nil ,@args)))))

;;; ------------------------------------------------------------------------------------
;;; Lists

(defun make-entry (key value)
  "Return a map entry: a vector of KEY and VALUE."
  (make-pvector 2 5 +empty-vnode+ (vector key value)))

(defun list-from-cl (items)
  "Return a persistent list of the elements of the CL list ITEMS, or () if it is empty."
  (let ((result +empty-list+) (count 0))
    (dolist (x (reverse items) result)
      (setf result (make-plist x result (incf count))))))

(defun rest-args (items)
  "Convert a CL &rest list into the value of a Skein rest parameter: nil if empty."
  (and items (list-from-cl items)))

(defun list-cons (x coll)
  (etypecase coll
    (empty-list (make-plist x coll 1))
    (plist (make-plist x coll (1+ (plist-count coll))))))

;;; ------------------------------------------------------------------------------------
;;; seq, first, rest, next

(defun node-seq (array index &optional inner)
  "Return a seq of the entries in the HAMT node array ARRAY from INDEX, or NIL."
  (if inner
      (make-nseq array index inner)
      (loop for j from index below (length array) by 2
            do (if (not (eq (svref array j) +subnode+))
                   (return (make-nseq array j nil))
                   (let ((child (node-seq (node-array (svref array (1+ j))) 0)))
                     (when child (return (make-nseq array (+ j 2) child))))))))

(defun node-array (node)
  (etypecase node (bnode (bnode-array node)) (cnode (cnode-array node))))

(defun lazy-seq-realize (ls)
  "Realize the lazy seq LS and return its seq (NIL if empty)."
  (when (lazy-seq-fn ls)
    (let ((value (funcall (lazy-seq-fn ls))))
      (setf (lazy-seq-value ls) value
            (lazy-seq-fn ls) nil)
      (loop while (lazy-seq-p value)
            do (setf value (lazy-seq-realize value)))
      (setf (lazy-seq-seq ls) (seq value)
            (lazy-seq-value ls) nil)))
  (lazy-seq-seq ls))

(defun seq (x)
  "Return NIL if X is empty, else a seq of its elements: X itself if it is a non-empty
list or seq. Signals UNSUPPORTED-OPERATION-ERROR if X is not seqable."
  (typecase x
    (null nil)
    ((or plist vseq aseq nseq kseq valseq sseq cseq arrseq) x)
    (empty-list nil)
    (pvector (if (zerop (pvector-count x)) nil (make-vseq x 0)))
    (array-map (if (zerop (length (array-map-array x))) nil (make-aseq (array-map-array x) 0)))
    (hash-map (and (hash-map-root x) (node-seq (node-array (hash-map-root x)) 0)))
    (hash-set (let ((s (seq (hash-set-map x)))) (and s (make-kseq s))))
    (string (if (zerop (length x)) nil (make-sseq x 0)))
    (lazy-seq (lazy-seq-realize x))
    (eduction (seq (eduction-seq x)))
    (vector (if (zerop (length x)) nil (make-arrseq x 0)))
    (struct-array (if (zerop (struct-array-count x)) nil (make-arrseq x 0)))
    (t (unsupported "~A is not seqable" (readable-string x)))))

(defun seq-first (s)
  "Return the first element of the seq S (as returned by SEQ)."
  (etypecase s
    (plist (plist-first s))
    (vseq (vector-nth (vseq-vec s) (vseq-index s)))
    (aseq (make-entry (svref (aseq-array s) (aseq-index s))
                      (svref (aseq-array s) (1+ (aseq-index s)))))
    (nseq (if (nseq-inner s)
              (seq-first (nseq-inner s))
              (make-entry (svref (nseq-array s) (nseq-index s))
                          (svref (nseq-array s) (1+ (nseq-index s))))))
    (kseq (vector-nth (seq-first (kseq-inner s)) 0))
    (valseq (vector-nth (seq-first (valseq-inner s)) 1))
    (sseq (char (sseq-string s) (sseq-index s)))
    (cseq (cseq-first s))
    (arrseq (aget-slow (arrseq-array s) (arrseq-index s)))))

(defun seq-next (s)
  "Return the seq after the first element of the seq S, or NIL."
  (etypecase s
    (plist (let ((r (plist-rest s))) (if (plist-p r) r nil)))
    (vseq (let ((i (1+ (vseq-index s))))
            (if (< i (pvector-count (vseq-vec s))) (make-vseq (vseq-vec s) i) nil)))
    (aseq (let ((i (+ 2 (aseq-index s))))
            (if (< i (length (aseq-array s))) (make-aseq (aseq-array s) i) nil)))
    (nseq (if (nseq-inner s)
              (node-seq (nseq-array s) (nseq-index s) (seq-next (nseq-inner s)))
              (node-seq (nseq-array s) (+ 2 (nseq-index s)))))
    (kseq (let ((n (seq-next (kseq-inner s)))) (and n (make-kseq n))))
    (valseq (let ((n (seq-next (valseq-inner s)))) (and n (make-valseq n))))
    (sseq (let ((i (1+ (sseq-index s))))
            (if (< i (length (sseq-string s))) (make-sseq (sseq-string s) i) nil)))
    (cseq (seq (cseq-more s)))
    (arrseq (let ((i (1+ (arrseq-index s))))
              (if (< i (count-of (arrseq-array s))) (make-arrseq (arrseq-array s) i) nil)))))

(defun seq-rest (s)
  "Return what follows the first element of the seq S, without realizing a lazy tail."
  (typecase s
    (plist (plist-rest s))
    (cseq (or (cseq-more s) +empty-list+))
    (t (or (seq-next s) +empty-list+))))

(defun first* (x) (let ((s (seq x))) (and s (seq-first s))))
(defun rest* (x) (let ((s (seq x))) (if s (seq-rest s) +empty-list+)))
(defun next* (x) (let ((s (seq x))) (and s (seq-next s))))

(defmacro do-seq ((var coll &optional result) &body body)
  "Run BODY with VAR bound to each element of the seqable COLL."
  (let ((s (gensym "S")))
    `(loop for ,s = (seq ,coll) then (seq-next ,s)
           while ,s
           do (let ((,var (seq-first ,s))) ,@body)
           finally (return ,result))))

(defun seq-to-cl (coll)
  "Return the elements of the seqable COLL as a fresh CL list."
  (let ((items '()))
    (do-seq (x coll) (push x items))
    (nreverse items)))

;;; ------------------------------------------------------------------------------------
;;; Sets

(defun set-conj (s x)
  (let ((m (hash-set-map s)))
    (if (map-contains-p m x) s (make-hash-set (map-assoc m x x)))))

(defun set-disj (s x)
  (let* ((m (hash-set-map s)) (new (map-dissoc m x)))
    (if (eq new m) s (make-hash-set new))))

(defun set-contains-p (s x) (map-contains-p (hash-set-map s) x))

(defun set-from-cl (items)
  "Return a persistent set of the elements of the CL list ITEMS."
  (let ((tm (map-transient +empty-map+)))
    (dolist (x items) (tmap-assoc tm x x))
    (make-hash-set (tmap-persistent tm))))

;;; ------------------------------------------------------------------------------------
;;; Generic collection operations

(defun counted-p (x)
  "Return true if (count X) takes constant time."
  (typep x '(or null plist empty-list pvector array-map hash-map hash-set string vseq
             tvector tmap tset)))

(defun count-of (x)
  "Return the number of elements in X."
  (typecase x
    (null 0)
    (plist (plist-count x))
    (empty-list 0)
    (pvector (pvector-count x))
    ((or array-map hash-map) (map-count x))
    (hash-set (map-count (hash-set-map x)))
    (string (length x))
    (vseq (- (pvector-count (vseq-vec x)) (vseq-index x)))
    (tvector (check-edit (tvector-edit x) "transient vector") (tvector-count x))
    (tmap (check-edit (tmap-edit x) "transient map") (tmap-count x))
    (tset (count-of (tset-tmap x)))
    (vector (length x))
    (struct-array (struct-array-count x))
    (t (let ((n 0)) (do-seq (e x) (declare (ignore e)) (incf n)) n))))

(defun coll-cons (x coll)
  "Return a seq of X followed by the elements of COLL (cons)."
  (typecase coll
    (null (make-plist x +empty-list+ 1))
    ((or plist empty-list) (list-cons x coll))
    (t (make-cseq x coll))))

(defun coll-conj (coll x)
  "Add X to COLL in the way natural for it (conj): lists and seqs at the front, vectors at
the end, maps take [key value] entries, sets add X."
  (typecase coll
    (null (make-plist x +empty-list+ 1))
    ((or plist empty-list) (list-cons x coll))
    (pvector (vector-conj coll x))
    ((or array-map hash-map)
     (cond ((and (pvector-p x) (= (pvector-count x) 2))
            (map-assoc coll (vector-nth x 0) (vector-nth x 1)))
           ((typep x '(or array-map hash-map))
            (let ((m coll)) (map-reduce-kv x (lambda (acc k v) (declare (ignore acc))
                                                (setf m (map-assoc m k v))) nil)
              m))
           ((null x) coll)
           (t (unsupported "conj on a map needs a [key value] vector or a map, not ~A"
                           (readable-string x)))))
    (hash-set (set-conj coll x))
    ((or vseq aseq nseq kseq valseq sseq cseq lazy-seq) (make-cseq x coll))
    (t (unsupported "cannot conj onto ~A" (readable-string coll)))))

(defun coll-assoc (coll key value)
  "Return COLL with KEY mapped to VALUE: maps by key, vectors by index; nil becomes a map."
  (typecase coll
    (null (make-array-map (vector key value)))
    ((or array-map hash-map) (map-assoc coll key value))
    (pvector (vector-assoc coll key value))
    (t (unsupported "cannot assoc on ~A" (readable-string coll)))))

(defun coll-dissoc (coll key)
  (typecase coll
    (null nil)
    ((or array-map hash-map) (map-dissoc coll key))
    (t (unsupported "cannot dissoc from ~A" (readable-string coll)))))

(defun coll-get (coll key &optional not-found)
  "Look KEY up in COLL (get): maps by key, vectors and strings by index, sets by
membership. Returns NOT-FOUND if it is absent or COLL is not associative."
  (typecase coll
    ((or array-map hash-map) (map-get coll key not-found))
    (pvector (if (and (integerp key) (< -1 key (pvector-count coll)))
                 (vector-nth coll key)
                 not-found))
    (hash-set (if (set-contains-p coll key) (map-get (hash-set-map coll) key) not-found))
    (string (if (and (integerp key) (< -1 key (length coll))) (char coll key) not-found))
    (tmap (tmap-get coll key not-found))
    (tvector (if (and (integerp key) (< -1 key (tvector-count coll)))
                 (tvector-nth coll key)
                 not-found))
    (tset (if (eq (tmap-get (tset-tmap coll) key +not-found+) +not-found+)
              not-found
              (tmap-get (tset-tmap coll) key)))
    (condition (if (kw-p key) (condition-slot coll (kw-name key) not-found) not-found))
    (t (cond ((instance-p coll) (object-get coll key not-found))
             ((struct-instance-def coll) (struct-get coll key not-found))
             (t not-found)))))

(defun coll-contains-p (coll key)
  (not (eq (coll-get coll key +not-found+) +not-found+)))

(defun coll-nth (coll i &optional (not-found nil not-found-p))
  "Return element I of COLL (nth). Signals INDEX-ERROR if it is out of range, unless
NOT-FOUND is given."
  (flet ((out ()
           (if not-found-p
               not-found
               (error 'index-error :location nil
                                   :message (format nil "index ~A is out of bounds" i)))))
    (unless (integerp i)
      (unsupported "nth needs an integer index, not ~A" (readable-string i)))
    (typecase coll
      (null (if not-found-p not-found nil))
      (pvector (if (< -1 i (pvector-count coll)) (vector-nth coll i) (out)))
      (string (if (< -1 i (length coll)) (char coll i) (out)))
      (tvector (if (< -1 i (tvector-count coll)) (tvector-nth coll i) (out)))
      ((or array-map hash-map hash-set) (unsupported "nth is not supported on ~A"
                                                     (readable-string coll)))
      (t (if (minusp i)
             (out)
             (loop for s = (seq coll) then (seq-next s)
                   for n from 0
                   while s
                   when (= n i) return (seq-first s)
                   finally (return (out))))))))

(defun coll-empty (coll)
  "Return an empty collection of the same kind as COLL, or nil."
  (typecase coll
    ((or plist empty-list) +empty-list+)
    (pvector +empty-vector+)
    ((or array-map hash-map) +empty-map+)
    (hash-set +empty-set+)
    ((or vseq aseq nseq kseq valseq sseq cseq lazy-seq) +empty-list+)
    (t nil)))
