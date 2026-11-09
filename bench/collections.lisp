;;;; Collection benchmarks (M0.4). Run with `make bench`; prints a Markdown table.
;;;; Each case runs a few times and reports the best time. CL baselines show what the
;;;; host's own mutable structures cost for the same work.

(load (merge-pathnames "../host/tools/bootstrap.lisp" *load-truename*))
(skein-quickload "skein")

(in-package #:skein.runtime)

(defparameter *runs* 5)

(defmacro bench (name &body body)
  `(let ((best nil))
     (dotimes (i *runs*)
       (sb-ext:gc :full t)
       (let ((start (get-internal-real-time)))
         ,@body
         (let ((ms (/ (- (get-internal-real-time) start)
                      (/ internal-time-units-per-second 1000.0))))
           (setf best (if best (min best ms) ms)))))
     (format t "| ~A | ~,1F |~%" ,name best)))

(defun core (name) (var-value (find-own-var +core+ name)))

(defvar *sink* nil)
(defparameter *n* 1000000)
(defparameter *m* 100000)

(defun persistent-vector (n)
  (let ((v +empty-vector+)) (dotimes (i n v) (setf v (vector-conj v i)))))
(defun transient-vector (n)
  (let ((tv (vector-transient +empty-vector+)))
    (dotimes (i n) (tvector-conj tv i))
    (tvector-persistent tv)))
(defun persistent-map (n)
  (let ((m +empty-map+)) (dotimes (i n m) (setf m (map-assoc m i i)))))
(defun transient-map (n)
  (let ((tm (map-transient +empty-map+)))
    (dotimes (i n) (tmap-assoc tm i i))
    (tmap-persistent tm)))

(format t "| Benchmark | Best of ~D (ms) |~%|---|---|~%" *runs*)

(bench "vector: conj 1M (persistent)" (setf *sink* (persistent-vector *n*)))
(bench "vector: conj! 1M (transient)" (setf *sink* (transient-vector *n*)))
(bench "CL baseline: vector-push-extend 1M"
  (let ((v (make-array 0 :adjustable t :fill-pointer t)))
    (dotimes (i *n*) (vector-push-extend i v))
    (setf *sink* v)))
(let ((v (transient-vector *n*)))
  (bench "vector: nth 1M" (let ((s 0)) (dotimes (i *n*) (incf s (vector-nth v i))) (setf *sink* s)))
  (bench "vector: assoc 100k" (let ((w v)) (dotimes (i *m*) (setf w (vector-assoc w i 0)))
                                (setf *sink* w)))
  (bench "vector: reduce + over 1M" (setf *sink* (funcall (core "reduce") (core "+") v))))
(bench "map: assoc 100k integer keys (persistent)" (setf *sink* (persistent-map *m*)))
(bench "map: assoc! 100k integer keys (transient)" (setf *sink* (transient-map *m*)))
(bench "CL baseline: hash table puthash 100k"
  (let ((h (make-hash-table))) (dotimes (i *m*) (setf (gethash i h) i)) (setf *sink* h)))
(let ((m (transient-map *m*)))
  (bench "map: get 1M (100k-entry map)"
    (let ((s 0)) (dotimes (i *n*) (incf s (map-get m (mod i *m*) 0))) (setf *sink* s)))
  (bench "map: dissoc 100k" (let ((w m)) (dotimes (i *m*) (setf w (map-dissoc w i)))
                              (setf *sink* w))))
(let ((keys (loop for i below *m* collect (intern-kw (format nil "k~D" i)))))
  (bench "map: assoc 100k keyword keys"
    (let ((m +empty-map+)) (dolist (k keys) (setf m (map-assoc m k 1))) (setf *sink* m))))
(bench "set: into #{} 100k" (setf *sink* (funcall (core "into") +empty-set+
                                                   (funcall (core "range") *m*))))
(let ((inc (core "inc")) (odd (core "odd?")) (plus (core "+")))
  (bench "seq: (reduce + (filter odd? (map inc (range 1M))))"
    (setf *sink* (funcall (core "reduce") plus
                          (funcall (core "filter") odd
                                   (funcall (core "map") inc (funcall (core "range") *n*))))))
  (bench "transducer: (transduce (comp (map inc) (filter odd?)) + (range 1M))"
    (setf *sink* (funcall (core "transduce")
                          (funcall (core "comp") (funcall (core "map") inc)
                                   (funcall (core "filter") odd))
                          plus (funcall (core "range") *n*))))
  (let ((v (transient-vector *n*)))
    (bench "transducer over a 1M vector: (into [] (map inc) v)"
      (setf *sink* (funcall (core "into") +empty-vector+ (funcall (core "map") inc) v)))))
(let ((a (transient-vector *m*)) (b (transient-vector *m*)))
  (bench "equality: = on two 100k vectors" (setf *sink* (equiv a b)))
  (bench "hashing: hash-of a 100k vector (uncached)"
    (setf (pvector-hash a) nil)
    (setf *sink* (hash-of a))))
