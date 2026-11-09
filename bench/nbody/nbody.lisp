;;;; N-body reference (the Computer Language Benchmarks Game algorithm), hand-written and
;;;; declared SBCL code. bench/nbody/nbody.skn is the same program in Skein; M0.8's exit
;;;; criterion is that it runs within 2x of this one. Both store bodies in parallel f64
;;;; arrays and use the same declarations: (optimize (speed 3) (safety 1)).

(defpackage #:nbody-reference (:use #:cl))
(in-package #:nbody-reference)

(defconstant +pi+ 3.141592653589793d0)
(defconstant +solar-mass+ (* 4d0 +pi+ +pi+))
(defconstant +days-per-year+ 365.24d0)

(deftype f64-array () '(simple-array double-float (*)))

(defun make-bodies ()
  (let ((data (list (list 0d0 0d0 0d0 0d0 0d0 0d0 1d0)
                    (list 4.84143144246472090d+00 -1.16032004402742839d+00 -1.03622044471123109d-01
                          1.66007664274403694d-03 7.69901118419740425d-03 -6.90460016972063023d-05
                          9.54791938424326609d-04)
                    (list 8.34336671824457987d+00 4.12479856412430479d+00 -4.03523417114321381d-01
                          -2.76742510726862411d-03 4.99852801234917238d-03 2.30417297573763929d-05
                          2.85885980666130812d-04)
                    (list 1.28943695621391310d+01 -1.51111514016986312d+01 -2.23307578892655734d-01
                          2.96460137564761618d-03 2.37847173959480950d-03 -2.96589568540237556d-05
                          4.36624404335156298d-05)
                    (list 1.53796971148509165d+01 -2.59193146099879641d+01 1.79258772950371181d-01
                          2.68067772490389322d-03 1.62824170038242295d-03 -9.51592254519715870d-05
                          5.15138902046611451d-05)))
        (arrays (loop repeat 7 collect (make-array 5 :element-type 'double-float))))
    (loop for body in data
          for i from 0
          do (loop for value in body
                   for array in arrays
                   for k from 0
                   do (setf (aref array i)
                            (cond ((= k 6) (* value +solar-mass+))
                                  ((>= k 3) (* value +days-per-year+))
                                  (t value)))))
    arrays))

(defun offset-momentum (vx vy vz m)
  (declare (type f64-array vx vy vz m) (optimize (speed 3) (safety 1)))
  (let ((px 0d0) (py 0d0) (pz 0d0))
    (declare (type double-float px py pz))
    (dotimes (i (length m))
      (incf px (* (aref vx i) (aref m i)))
      (incf py (* (aref vy i) (aref m i)))
      (incf pz (* (aref vz i) (aref m i))))
    (setf (aref vx 0) (/ (- px) +solar-mass+)
          (aref vy 0) (/ (- py) +solar-mass+)
          (aref vz 0) (/ (- pz) +solar-mass+))))

(defun energy (x y z vx vy vz m)
  (declare (type f64-array x y z vx vy vz m) (optimize (speed 3) (safety 1)))
  (let ((e 0d0) (n (length m)))
    (declare (type double-float e))
    (dotimes (i n)
      (incf e (* 0.5d0 (aref m i) (+ (* (aref vx i) (aref vx i)) (* (aref vy i) (aref vy i))
                                     (* (aref vz i) (aref vz i)))))
      (loop for j from (1+ i) below n
            do (let ((dx (- (aref x i) (aref x j)))
                     (dy (- (aref y i) (aref y j)))
                     (dz (- (aref z i) (aref z j))))
                 (decf e (/ (* (aref m i) (aref m j))
                            (sqrt (+ (* dx dx) (* dy dy) (* dz dz))))))))
    e))

(defun advance (x y z vx vy vz m dt)
  (declare (type f64-array x y z vx vy vz m) (type double-float dt)
           (optimize (speed 3) (safety 1)))
  (let ((n (length m)))
    (dotimes (i n)
      (loop for j from (1+ i) below n
            do (let* ((dx (- (aref x i) (aref x j)))
                      (dy (- (aref y i) (aref y j)))
                      (dz (- (aref z i) (aref z j)))
                      (d2 (+ (* dx dx) (* dy dy) (* dz dz)))
                      (mag (/ dt (* d2 (sqrt d2)))))
                 (decf (aref vx i) (* dx (aref m j) mag))
                 (decf (aref vy i) (* dy (aref m j) mag))
                 (decf (aref vz i) (* dz (aref m j) mag))
                 (incf (aref vx j) (* dx (aref m i) mag))
                 (incf (aref vy j) (* dy (aref m i) mag))
                 (incf (aref vz j) (* dz (aref m i) mag)))))
    (dotimes (i n)
      (incf (aref x i) (* dt (aref vx i)))
      (incf (aref y i) (* dt (aref vy i)))
      (incf (aref z i) (* dt (aref vz i))))))

(defun run (steps)
  (destructuring-bind (x y z vx vy vz m) (make-bodies)
    (offset-momentum vx vy vz m)
    (let ((before (energy x y z vx vy vz m)))
      (dotimes (i steps) (advance x y z vx vy vz m 0.01d0))
      (values before (energy x y z vx vy vz m)))))
