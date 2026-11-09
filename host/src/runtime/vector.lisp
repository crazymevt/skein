;;;; Persistent and transient vectors (Clojure's PersistentVector).
;;;; EDIT is NIL for persistent operations, or a transient's token: nodes carrying that
;;;; token belong to the transient and are changed in place.

(in-package #:skein.runtime)

(declaim (inline tailoff))
(defun tailoff (count)
  (if (< count +branch+) 0 (ash (ash (1- count) -5) 5)))

(defun editable-node (node edit)
  "Return NODE if EDIT owns it, else a copy owned by EDIT."
  (if (and edit (eq (vnode-edit node) edit))
      node
      (let ((copy (copy-seq node)))
        (setf (svref copy 32) edit)
        copy)))

(defun leaf-array (count shift root tail i)
  "Return the array holding element I: the tail or a leaf node."
  (if (>= i (tailoff count))
      tail
      (let ((node root))
        (loop for level from shift above 0 by 5
              do (setf node (svref node (logand (ash i (- level)) 31))))
        node)))

(defun new-path (edit level node)
  (if (zerop level)
      node
      (let ((ret (make-vnode edit)))
        (setf (svref ret 0) (new-path edit (- level 5) node))
        ret)))

(defun push-tail (edit count level parent tail-node)
  (let ((ret (editable-node parent edit))
        (subidx (logand (ash (1- count) (- level)) 31)))
    (setf (svref ret subidx)
          (if (= level 5)
              tail-node
              (let ((child (svref parent subidx)))
                (if child
                    (push-tail edit count (- level 5) child tail-node)
                    (new-path edit (- level 5) tail-node)))))
    ret))

(defun do-assoc (edit level node i value)
  (let ((ret (editable-node node edit)))
    (if (zerop level)
        (setf (svref ret (logand i 31)) value)
        (let ((subidx (logand (ash i (- level)) 31)))
          (setf (svref ret subidx) (do-assoc edit (- level 5) (svref node subidx) i value))))
    ret))

(defun pop-tail (edit count level node)
  (let ((subidx (logand (ash (- count 2) (- level)) 31)))
    (cond ((> level 5)
           (let ((child (pop-tail edit count (- level 5) (svref node subidx))))
             (if (and (null child) (zerop subidx))
                 nil
                 (let ((ret (editable-node node edit)))
                   (setf (svref ret subidx) child)
                   ret))))
          ((zerop subidx) nil)
          (t (let ((ret (editable-node node edit)))
               (setf (svref ret subidx) nil)
               ret)))))

(defun index-out-of-bounds (i count)
  (error 'index-error :location nil
                      :message (format nil "index ~A is out of bounds for a vector of ~D"
                                       i count)))

;;; Persistent operations

(defun vector-nth (v i &optional (not-found nil not-found-p))
  "Return element I of the persistent vector V."
  (let ((count (pvector-count v)))
    (if (and (integerp i) (< -1 i count))
        (svref (leaf-array count (pvector-shift v) (pvector-root v) (pvector-tail v) i)
               (logand i 31))
        (if not-found-p not-found (index-out-of-bounds i count)))))

(defun vector-conj (v value)
  "Return V with VALUE added at the end."
  (let* ((count (pvector-count v))
         (tail (pvector-tail v))
         (shift (pvector-shift v))
         (root (pvector-root v)))
    (if (< (- count (tailoff count)) +branch+)
        (let ((new-tail (make-array (1+ (length tail)))))
          (replace new-tail tail)
          (setf (svref new-tail (length tail)) value)
          (make-pvector (1+ count) shift root new-tail))
        (let ((tail-node (make-vnode nil)))
          (replace tail-node tail)
          (if (> (ash count -5) (ash 1 shift))
              (let ((new-root (make-vnode nil)))
                (setf (svref new-root 0) root
                      (svref new-root 1) (new-path nil shift tail-node))
                (make-pvector (1+ count) (+ shift 5) new-root (vector value)))
              (make-pvector (1+ count) shift (push-tail nil count shift root tail-node)
                            (vector value)))))))

(defun vector-assoc (v i value)
  "Return V with element I set to VALUE. I may equal the count, to append."
  (let ((count (pvector-count v)))
    (cond ((not (and (integerp i) (<= 0 i count))) (index-out-of-bounds i count))
          ((= i count) (vector-conj v value))
          ((>= i (tailoff count))
           (let ((new-tail (copy-seq (pvector-tail v))))
             (setf (svref new-tail (logand i 31)) value)
             (make-pvector count (pvector-shift v) (pvector-root v) new-tail)))
          (t (make-pvector count (pvector-shift v)
                           (do-assoc nil (pvector-shift v) (pvector-root v) i value)
                           (pvector-tail v))))))

(defun pvector-pop (v)
  "Return V without its last element."
  (let ((count (pvector-count v))
        (shift (pvector-shift v))
        (root (pvector-root v)))
    (cond ((zerop count) (unsupported "cannot pop an empty vector"))
          ((= count 1) +empty-vector+)
          ((> (- count (tailoff count)) 1)
           (make-pvector (1- count) shift root (subseq (pvector-tail v) 0
                                                       (1- (length (pvector-tail v))))))
          (t (let* ((new-tail (subseq (leaf-array count shift root (pvector-tail v)
                                                  (- count 2))
                                      0 32))
                    (new-root (or (pop-tail nil count shift root) +empty-vnode+))
                    (new-shift shift))
               (when (and (> shift 5) (null (svref new-root 1)))
                 (setf new-root (svref new-root 0)
                       new-shift (- new-shift 5)))
               (make-pvector (1- count) new-shift new-root new-tail))))))

(defun vector-from-list (list)
  "Return a persistent vector of the elements of the CL list LIST."
  (let ((tv (vector-transient +empty-vector+)))
    (dolist (x list) (tvector-conj tv x))
    (tvector-persistent tv)))

(defun vector-to-list (v)
  "Return the elements of the persistent vector V as a fresh CL list."
  (loop for i below (pvector-count v) collect (vector-nth v i)))

;;; Transient operations

(defun vector-transient (v)
  "Return a transient copy of the persistent vector V."
  (let* ((edit (make-edit-token))
         (tail (make-array +branch+ :initial-element nil)))
    (replace tail (pvector-tail v))
    (make-tvector (pvector-count v) (pvector-shift v)
                  (editable-node (pvector-root v) edit) tail edit)))

(defun tvector-conj (tv value)
  "Add VALUE to the end of the transient vector TV, in place. Returns TV."
  (let ((edit (tvector-edit tv)))
    (check-edit edit "transient vector")
    (let ((count (tvector-count tv)))
      (if (< (- count (tailoff count)) +branch+)
          (setf (svref (tvector-tail tv) (logand count 31)) value)
          (let ((tail-node (make-vnode edit))
                (shift (tvector-shift tv)))
            (replace tail-node (tvector-tail tv))
            (setf (tvector-tail tv) (make-array +branch+ :initial-element nil)
                  (svref (tvector-tail tv) 0) value)
            (if (> (ash count -5) (ash 1 shift))
                (let ((new-root (make-vnode edit)))
                  (setf (svref new-root 0) (tvector-root tv)
                        (svref new-root 1) (new-path edit shift tail-node)
                        (tvector-root tv) new-root
                        (tvector-shift tv) (+ shift 5)))
                (setf (tvector-root tv)
                      (push-tail edit count shift (tvector-root tv) tail-node)))))
      (setf (tvector-count tv) (1+ count))
      tv)))

(defun tvector-nth (tv i &optional (not-found nil not-found-p))
  "Return element I of the transient vector TV."
  (check-edit (tvector-edit tv) "transient vector")
  (let ((count (tvector-count tv)))
    (if (and (integerp i) (< -1 i count))
        (svref (leaf-array count (tvector-shift tv) (tvector-root tv) (tvector-tail tv) i)
               (logand i 31))
        (if not-found-p not-found (index-out-of-bounds i count)))))

(defun tvector-assoc (tv i value)
  "Set element I of the transient vector TV to VALUE, in place. Returns TV."
  (let ((edit (tvector-edit tv))
        (count (tvector-count tv)))
    (check-edit edit "transient vector")
    (cond ((not (and (integerp i) (<= 0 i count))) (index-out-of-bounds i count))
          ((= i count) (tvector-conj tv value))
          ((>= i (tailoff count)) (setf (svref (tvector-tail tv) (logand i 31)) value) tv)
          (t (setf (tvector-root tv) (do-assoc edit (tvector-shift tv) (tvector-root tv)
                                               i value))
             tv))))

(defun tvector-pop (tv)
  "Remove the last element of the transient vector TV, in place. Returns TV."
  (let ((edit (tvector-edit tv))
        (count (tvector-count tv))
        (shift (tvector-shift tv)))
    (check-edit edit "transient vector")
    (cond ((zerop count) (unsupported "cannot pop an empty vector"))
          ((or (= count 1) (> (- count (tailoff count)) 1))
           (setf (svref (tvector-tail tv) (logand (1- count) 31)) nil))
          (t (let* ((new-tail (editable-node (leaf-array count shift (tvector-root tv)
                                                         (tvector-tail tv) (- count 2))
                                             edit))
                    (new-root (or (pop-tail edit count shift (tvector-root tv))
                                  (make-vnode edit)))
                    (new-shift shift))
               (when (and (> shift 5) (null (svref new-root 1)))
                 (setf new-root (editable-node (svref new-root 0) edit)
                       new-shift (- new-shift 5)))
               (setf (tvector-root tv) new-root
                     (tvector-shift tv) new-shift
                     (tvector-tail tv) (subseq new-tail 0 32)))))
    (setf (tvector-count tv) (1- count))
    tv))

(defun tvector-persistent (tv)
  "Return a persistent vector with TV's contents; TV can no longer be used."
  (let ((edit (tvector-edit tv)))
    (check-edit edit "transient vector")
    (setf (tvector-edit tv) nil)
    (let ((count (tvector-count tv)))
      (if (zerop count)
          +empty-vector+
          (make-pvector count (tvector-shift tv) (tvector-root tv)
                        (subseq (tvector-tail tv) 0 (- count (tailoff count))))))))
