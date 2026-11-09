;;;; Persistent and transient maps: array maps and HAMTs (Clojure's PersistentHashMap).
;;;; Node operations take EDIT: NIL for persistent updates, or a transient's token, in
;;;; which case nodes owned by that token are changed in place.

(in-package #:skein.runtime)

(declaim (inline hamt-mask bitpos bnode-index))
(defun hamt-mask (hash shift) (logand (ash hash (- shift)) 31))
(defun bitpos (hash shift) (ash 1 (hamt-mask hash shift)))
(defun bnode-index (bitmap bit) (logcount (logand bitmap (1- bit))))

(defun clone-and-set (array i x &optional (j nil j-p) y)
  (let ((new (copy-seq array)))
    (setf (svref new i) x)
    (when j-p (setf (svref new j) y))
    new))

(defun remove-pair (array i)
  "Return ARRAY without the pair at pair index I."
  (let ((new (make-array (- (length array) 2))))
    (replace new array :end2 (* 2 i))
    (replace new array :start1 (* 2 i) :start2 (* 2 (1+ i)))
    new))

(defun insert-pair (array i key value)
  (let ((new (make-array (+ (length array) 2))))
    (replace new array :end2 (* 2 i))
    (setf (svref new (* 2 i)) key
          (svref new (1+ (* 2 i))) value)
    (replace new array :start1 (* 2 (1+ i)) :start2 (* 2 i))
    new))

(defun owned-p (node-edit edit)
  (and edit (eq node-edit edit)))

;;; Bitmap-indexed nodes. ADDED is a one-element vector set to T when a key is added.

(defun create-node (edit shift key1 value1 hash2 key2 value2)
  (let ((hash1 (hash-of key1)))
    (if (= hash1 hash2)
        (make-cnode edit hash1 (vector key1 value1 key2 value2))
        (let ((added (vector nil)))
          (node-assoc (node-assoc (make-bnode edit 0 #()) edit shift hash1 key1 value1 added)
                      edit shift hash2 key2 value2 added)))))

(defun bnode-set (node edit array &optional (bitmap (bnode-bitmap node)))
  "Return NODE with ARRAY and BITMAP: changed in place if EDIT owns it, else a new node."
  (if (owned-p (bnode-edit node) edit)
      (progn (setf (bnode-array node) array (bnode-bitmap node) bitmap) node)
      (make-bnode edit bitmap array)))

(defun node-assoc (node edit shift hash key value added)
  "Return NODE with KEY (whose hash is HASH) mapped to VALUE."
  (etypecase node
    (bnode
     (let* ((bit (bitpos hash shift))
            (bitmap (bnode-bitmap node))
            (idx (bnode-index bitmap bit))
            (array (bnode-array node)))
       (if (zerop (logand bitmap bit))
           (progn (setf (svref added 0) t)
                  (bnode-set node edit (insert-pair array idx key value) (logior bitmap bit)))
           (let ((k (svref array (* 2 idx)))
                 (v (svref array (1+ (* 2 idx)))))
             (cond ((eq k +subnode+)
                    (let ((n (node-assoc v edit (+ shift 5) hash key value added)))
                      (if (eq n v)
                          node
                          (bnode-set node edit (clone-and-set array (1+ (* 2 idx)) n)))))
                   ((equiv key k)
                    (if (eq value v)
                        node
                        (bnode-set node edit (clone-and-set array (1+ (* 2 idx)) value))))
                   (t (setf (svref added 0) t)
                      (bnode-set node edit
                                 (clone-and-set array (* 2 idx) +subnode+
                                                (1+ (* 2 idx))
                                                (create-node edit (+ shift 5) k v
                                                             hash key value)))))))))
    (cnode
     (if (= hash (cnode-hash node))
         (let* ((array (cnode-array node))
                (idx (loop for i from 0 below (length array) by 2
                           when (equiv key (svref array i)) return i)))
           (cond ((and idx (eq (svref array (1+ idx)) value)) node)
                 (idx (cnode-set node edit (clone-and-set array (1+ idx) value)))
                 (t (setf (svref added 0) t)
                    (cnode-set node edit (concatenate 'simple-vector array
                                                      (vector key value))))))
         ;; A different hash: nest this collision node under a bitmap node.
         (node-assoc (make-bnode edit (bitpos (cnode-hash node) shift)
                                 (vector +subnode+ node))
                     edit shift hash key value added)))))

(defun cnode-set (node edit array)
  (if (owned-p (cnode-edit node) edit)
      (progn (setf (cnode-array node) array) node)
      (make-cnode edit (cnode-hash node) array)))

(defun node-without (node edit shift hash key)
  "Return NODE without KEY, or NIL if it would be empty."
  (etypecase node
    (bnode
     (let* ((bit (bitpos hash shift))
            (bitmap (bnode-bitmap node)))
       (if (zerop (logand bitmap bit))
           node
           (let* ((idx (bnode-index bitmap bit))
                  (array (bnode-array node))
                  (k (svref array (* 2 idx)))
                  (v (svref array (1+ (* 2 idx)))))
             (cond ((eq k +subnode+)
                    (let ((n (node-without v edit (+ shift 5) hash key)))
                      (cond ((eq n v) node)
                            (n (bnode-set node edit (clone-and-set array (1+ (* 2 idx)) n)))
                            ((= bitmap bit) nil)
                            (t (bnode-set node edit (remove-pair array idx)
                                          (logxor bitmap bit))))))
                   ((equiv key k)
                    (if (= bitmap bit)
                        nil
                        (bnode-set node edit (remove-pair array idx) (logxor bitmap bit))))
                   (t node))))))
    (cnode
     (let* ((array (cnode-array node))
            (idx (loop for i from 0 below (length array) by 2
                       when (equiv key (svref array i)) return i)))
       (cond ((null idx) node)
             ((= (length array) 2) nil)
             (t (cnode-set node edit (remove-pair array (floor idx 2)))))))))

(defun node-find (node shift hash key not-found)
  (loop
    (etypecase node
      (bnode
       (let* ((bit (bitpos hash shift))
              (bitmap (bnode-bitmap node)))
         (when (zerop (logand bitmap bit)) (return not-found))
         (let* ((idx (bnode-index bitmap bit))
                (array (bnode-array node))
                (k (svref array (* 2 idx)))
                (v (svref array (1+ (* 2 idx)))))
           (cond ((eq k +subnode+) (setf node v shift (+ shift 5)))
                 ((equiv key k) (return v))
                 (t (return not-found))))))
      (cnode
       (let ((array (cnode-array node)))
         (return (loop for i from 0 below (length array) by 2
                       when (equiv key (svref array i)) return (svref array (1+ i))
                       finally (return not-found))))))))

;;; Persistent maps

(sb-ext:define-load-time-global +not-found+ (make-symbol "NOT-FOUND"))

(defun array-map-index (array key)
  (loop for i from 0 below (length array) by 2
        when (equiv key (svref array i)) return i))

(defun map-count (m)
  "Return the number of entries in the persistent map M."
  (etypecase m
    (array-map (floor (length (array-map-array m)) 2))
    (hash-map (hash-map-count m))))

(defun map-get (m key &optional not-found)
  "Return the value of KEY in the persistent map M, or NOT-FOUND."
  (etypecase m
    (array-map (let* ((array (array-map-array m))
                      (i (array-map-index array key)))
                 (if i (svref array (1+ i)) not-found)))
    (hash-map (let ((root (hash-map-root m)))
                (if root (node-find root 0 (hash-of key) key not-found) not-found)))))

(defun map-contains-p (m key)
  "Return true if the persistent map M has KEY."
  (not (eq (map-get m key +not-found+) +not-found+)))

(defun map-assoc (m key value)
  "Return the persistent map M with KEY mapped to VALUE."
  (etypecase m
    (array-map
     (let* ((array (array-map-array m))
            (i (array-map-index array key)))
       (cond ((and i (eq (svref array (1+ i)) value)) m)
             (i (make-array-map (clone-and-set array (1+ i) value)))
             ((< (length array) (* 2 +array-map-limit+))
              (make-array-map (concatenate 'simple-vector array (vector key value))))
             (t (let ((tm (map-transient m)))
                  (tmap-assoc tm key value)
                  (tmap-persistent tm))))))
    (hash-map
     (let* ((added (vector nil))
            (root (node-assoc (or (hash-map-root m) (make-bnode nil 0 #())) nil 0
                              (hash-of key) key value added)))
       (if (eq root (hash-map-root m))
           m
           (make-hash-map (if (svref added 0) (1+ (hash-map-count m)) (hash-map-count m))
                          root))))))

(defun map-dissoc (m key)
  "Return the persistent map M without KEY."
  (etypecase m
    (array-map
     (let* ((array (array-map-array m))
            (i (array-map-index array key)))
       (if i (make-array-map (remove-pair array (floor i 2))) m)))
    (hash-map
     (let ((root (hash-map-root m)))
       (if (null root)
           m
           (let ((new (node-without root nil 0 (hash-of key) key)))
             (cond ((eq new root) m)
                   ((null new) +empty-map+)
                   (t (make-hash-map (1- (hash-map-count m)) new)))))))))

(defun map-from-pairs (pairs)
  "Return a persistent map of the CL list PAIRS (k1 v1 k2 v2 ...); later keys win."
  (let ((tm (map-transient +empty-map+)))
    (loop for (k v) on pairs by #'cddr do (tmap-assoc tm k v))
    (tmap-persistent tm)))

;;; Iterating entries

(defun node-reduce-kv (node f acc)
  "Call (F ACC K V) for each entry under NODE, threading ACC; stops on a REDUCED."
  (let ((array (etypecase node (bnode (bnode-array node)) (cnode (cnode-array node)))))
    (loop for i from 0 below (length array) by 2
          for k = (svref array i)
          for v = (svref array (1+ i))
          do (setf acc (if (eq k +subnode+) (node-reduce-kv v f acc) (funcall f acc k v)))
             (when (reduced-p acc) (return acc)))
    acc))

(defun map-reduce-kv (m f acc)
  "Call (F ACC K V) for each entry of the persistent map M; stops on a REDUCED, which is
returned as is."
  (etypecase m
    (array-map
     (let ((array (array-map-array m)))
       (loop for i from 0 below (length array) by 2
             do (setf acc (funcall f acc (svref array i) (svref array (1+ i))))
                (when (reduced-p acc) (return acc)))
       acc))
    (hash-map (if (hash-map-root m) (node-reduce-kv (hash-map-root m) f acc) acc))))

;;; Transient maps

(defun map-transient (m)
  "Return a transient map with the entries of the persistent map M."
  (let ((edit (make-edit-token)))
    (etypecase m
      (array-map
       (let ((array (make-array (* 2 +array-map-limit+) :initial-element nil))
             (source (array-map-array m)))
         (replace array source)
         (make-tmap (floor (length source) 2) nil edit array)))
      (hash-map (make-tmap (hash-map-count m) (hash-map-root m) edit)))))

(defun tmap-array-index (tm key)
  (loop for i from 0 below (* 2 (tmap-count tm)) by 2
        when (equiv key (svref (tmap-array tm) i)) return i))

(defun tmap-assoc (tm key value)
  "Map KEY to VALUE in the transient map TM, in place. Returns TM."
  (let ((edit (tmap-edit tm))
        (array (tmap-array tm)))
    (check-edit edit "transient map")
    (when array
      (let ((i (tmap-array-index tm key)))
        (cond (i (setf (svref array (1+ i)) value)
                 (return-from tmap-assoc tm))
              ((< (tmap-count tm) +array-map-limit+)
               (let ((n (* 2 (tmap-count tm))))
                 (setf (svref array n) key
                       (svref array (1+ n)) value)
                 (incf (tmap-count tm))
                 (return-from tmap-assoc tm)))
              (t ;; Full: move the entries into a HAMT and continue below.
               (let ((count (tmap-count tm)))
                 (setf (tmap-array tm) nil
                       (tmap-count tm) 0)
                 (loop for i from 0 below (* 2 count) by 2
                       do (tmap-assoc tm (svref array i) (svref array (1+ i)))))))))
    (let* ((added (vector nil))
           (root (node-assoc (or (tmap-root tm) (make-bnode edit 0 #())) edit 0
                             (hash-of key) key value added)))
      (setf (tmap-root tm) root)
      (when (svref added 0) (incf (tmap-count tm)))
      tm)))

(defun tmap-dissoc (tm key)
  "Remove KEY from the transient map TM, in place. Returns TM."
  (let ((edit (tmap-edit tm)))
    (check-edit edit "transient map")
    (let ((array (tmap-array tm)))
      (when array
        (let ((i (tmap-array-index tm key))
              (end (* 2 (tmap-count tm))))
          (when i
            (replace array array :start1 i :start2 (+ i 2) :end2 end)
            (setf (svref array (- end 2)) nil
                  (svref array (- end 1)) nil)
            (decf (tmap-count tm))))
        (return-from tmap-dissoc tm)))
    (let ((root (tmap-root tm))
          (hash (hash-of key)))
      (when (and root (not (eq (node-find root 0 hash key +not-found+) +not-found+)))
        (setf (tmap-root tm) (node-without root edit 0 hash key))
        (decf (tmap-count tm))))
    tm))

(defun tmap-get (tm key &optional not-found)
  "Return the value of KEY in the transient map TM, or NOT-FOUND."
  (check-edit (tmap-edit tm) "transient map")
  (if (tmap-array tm)
      (let ((i (tmap-array-index tm key)))
        (if i (svref (tmap-array tm) (1+ i)) not-found))
      (let ((root (tmap-root tm)))
        (if root (node-find root 0 (hash-of key) key not-found) not-found))))

(defun tmap-persistent (tm)
  "Return a persistent map with TM's entries; TM can no longer be used. Maps of up to
+ARRAY-MAP-LIMIT+ entries become array maps."
  (check-edit (tmap-edit tm) "transient map")
  (setf (tmap-edit tm) nil)
  (let ((count (tmap-count tm))
        (root (tmap-root tm)))
    (cond ((zerop count) +empty-map+)
          ((tmap-array tm) (make-array-map (subseq (tmap-array tm) 0 (* 2 count))))
          ((<= count +array-map-limit+)
           (let ((pairs '()))
             (node-reduce-kv root (lambda (acc k v) (push v pairs) (push k pairs) acc) nil)
             (make-array-map (coerce pairs 'simple-vector))))
          (t (make-hash-map count root)))))
