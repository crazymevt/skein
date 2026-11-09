;;;; Persistent collection, transient and seq types (DESIGN §6.2, §7).
;;;; The algorithms follow Clojure's PersistentVector and PersistentHashMap.

(in-package #:skein.runtime)

;;; ------------------------------------------------------------------------------------
;;; Errors

(define-condition index-error (skein-error) ()
  (:documentation "Signaled when an index is outside a collection's bounds."))

(define-condition unsupported-operation-error (skein-error) ()
  (:documentation "Signaled when a collection function is given a value it cannot work on,
such as (conj \"abc\" 1) or (assoc '(1) 0 2)."))

(define-condition transient-error (skein-error) ()
  (:documentation "Signaled when a transient is used after persistent!, or from a thread
other than the one that created it."))

(defun unsupported (control &rest args)
  (error 'unsupported-operation-error :location nil
                                      :message (apply #'format nil control args)))

;;; ------------------------------------------------------------------------------------
;;; Abstract bases, so that generic functions can dispatch on "any map", "any list" and
;;; "any seq" (DESIGN §8.3). They have no slots.

(defstruct (skein-seq (:constructor nil) (:copier nil) (:predicate nil))
  "The base of every seq type.")
(defstruct (skein-list (:include skein-seq) (:constructor nil) (:copier nil) (:predicate nil))
  "The base of the list types: () and non-empty lists.")
(defstruct (skein-map (:constructor nil) (:copier nil) (:predicate nil))
  "The base of the persistent map types.")

;;; ------------------------------------------------------------------------------------
;;; Lists

(defstruct (empty-list (:include skein-list) (:constructor %make-empty-list ()) (:copier nil))
  "The empty list ()."
  (hash nil))

(sb-ext:define-load-time-global +empty-list+ (%make-empty-list)
  "The empty list (). It is distinct from nil.")

(defstruct (plist (:include skein-list) (:constructor make-plist (first rest count)) (:copier nil))
  "A non-empty persistent list: a counted cons cell whose REST is a PLIST or +EMPTY-LIST+."
  (first nil :read-only t)
  (rest nil :read-only t)
  (count 1 :type fixnum :read-only t)
  (hash nil))

;;; ------------------------------------------------------------------------------------
;;; Vectors: a 32-way trie of nodes plus a tail (Clojure's PersistentVector).
;;; A node is a simple-vector of 33 elements: 32 slots, then the edit token that owns
;;; it (NIL for nodes that belong to persistent vectors).

(defconstant +branch+ 32)

(declaim (inline make-vnode vnode-edit))
(defun make-vnode (edit)
  (let ((node (make-array 33 :initial-element nil)))
    (setf (svref node 32) edit)
    node))
(defun vnode-edit (node) (svref node 32))

(sb-ext:define-load-time-global +empty-vnode+ (make-vnode nil))

(defstruct (pvector (:constructor make-pvector (count shift root tail)) (:copier nil))
  "A persistent vector."
  (count 0 :type fixnum :read-only t)
  (shift 5 :type fixnum :read-only t)
  (root nil :type simple-vector :read-only t)
  (tail nil :type simple-vector :read-only t)
  (hash nil))

(sb-ext:define-load-time-global +empty-vector+
    (make-pvector 0 5 +empty-vnode+ (vector))
  "The empty vector [].")

(defstruct (tvector (:constructor make-tvector (count shift root tail edit)) (:copier nil))
  "A transient vector. TAIL always has 32 slots."
  (count 0 :type fixnum)
  (shift 5 :type fixnum)
  (root nil :type simple-vector)
  (tail nil :type simple-vector)
  (edit nil))

;;; ------------------------------------------------------------------------------------
;;; Maps. Up to 8 entries live in an array map; larger maps are hash array mapped tries.

(defconstant +array-map-limit+ 8
  "The largest number of entries kept in an array map (DESIGN §6.2).")

(defstruct (array-map (:include skein-map) (:constructor make-array-map (array)) (:copier nil))
  "A small persistent map: ARRAY holds keys and values alternately."
  (array #() :type simple-vector :read-only t)
  (hash nil))

(sb-ext:define-load-time-global +empty-map+ (make-array-map (vector))
  "The empty map {}.")

(defstruct (hash-map (:include skein-map) (:constructor make-hash-map (count root)) (:copier nil))
  "A persistent hash map: a HAMT whose ROOT is a BNODE, CNODE or NIL."
  (count 0 :type fixnum :read-only t)
  (root nil :read-only t)
  (hash nil))

(sb-ext:define-load-time-global +subnode+ (make-symbol "SUBNODE")
  "Marks a key slot in a BNODE whose value slot holds a child node.")

(defstruct (bnode (:constructor make-bnode (edit bitmap array)) (:copier nil))
  "A HAMT bitmap-indexed node. ARRAY holds key/value pairs; a key of +SUBNODE+ means
the value is a child node."
  (edit nil)
  (bitmap 0 :type (unsigned-byte 32))
  (array #() :type simple-vector))

(defstruct (cnode (:constructor make-cnode (edit hash array)) (:copier nil))
  "A HAMT node for keys whose 32-bit hashes collide."
  (edit nil)
  (hash 0 :type (unsigned-byte 32))
  (array #() :type simple-vector))

(defstruct (tmap (:constructor make-tmap (count root edit &optional array)) (:copier nil))
  "A transient map. While it has at most +ARRAY-MAP-LIMIT+ entries it keeps them in
ARRAY (key/value pairs, in insertion order); after that ARRAY is NIL and ROOT is a HAMT."
  (count 0 :type fixnum)
  (root nil)
  (edit nil)
  (array nil))

;;; ------------------------------------------------------------------------------------
;;; Sets wrap a map from each element to itself.

(defstruct (hash-set (:constructor make-hash-set (map)) (:copier nil))
  "A persistent hash set."
  (map nil :read-only t)
  (hash nil))

(sb-ext:define-load-time-global +empty-set+ (make-hash-set +empty-map+)
  "The empty set #{}.")

(defstruct (tset (:constructor make-tset (tmap)) (:copier nil))
  "A transient set."
  (tmap nil :read-only t))

;;; ------------------------------------------------------------------------------------
;;; Seqs. SEQ returns NIL or one of these (or a PLIST, which is its own seq).

(defstruct (vseq (:include skein-seq) (:constructor make-vseq (vec index)) (:copier nil))
  "A seq over a vector from INDEX."
  (vec nil :read-only t)
  (index 0 :type fixnum :read-only t)
  (hash nil))

(defstruct (aseq (:include skein-seq) (:constructor make-aseq (array index)) (:copier nil))
  "A seq of the entries of an array map, from INDEX (a key position)."
  (array #() :type simple-vector :read-only t)
  (index 0 :type fixnum :read-only t)
  (hash nil))

(defstruct (nseq (:include skein-seq) (:constructor make-nseq (array index inner)) (:copier nil))
  "A seq of the entries under a HAMT node. INNER is the seq of a child node being
walked, or NIL when INDEX is at a key/value pair."
  (array #() :type simple-vector :read-only t)
  (index 0 :type fixnum :read-only t)
  (inner nil :read-only t)
  (hash nil))

(defstruct (kseq (:include skein-seq) (:constructor make-kseq (inner)) (:copier nil))
  "A seq of the keys of a seq of map entries (used for sets and keys)."
  (inner nil :read-only t)
  (hash nil))

(defstruct (valseq (:include skein-seq) (:constructor make-valseq (inner)) (:copier nil))
  "A seq of the values of a seq of map entries."
  (inner nil :read-only t)
  (hash nil))

(defstruct (sseq (:include skein-seq) (:constructor make-sseq (string index)) (:copier nil))
  "A seq of the characters of a string from INDEX."
  (string "" :type string :read-only t)
  (index 0 :type fixnum :read-only t)
  (hash nil))

(defstruct (arrseq (:include skein-seq) (:constructor make-arrseq (array index)) (:copier nil))
  "A seq of the elements of an array (a CL vector or a struct array) from INDEX."
  (array nil :read-only t)
  (index 0 :type fixnum :read-only t)
  (hash nil))

(defstruct (cseq (:include skein-seq) (:constructor make-cseq (first more)) (:copier nil))
  "A cons cell whose MORE is any seqable value (often a lazy seq); not counted."
  (first nil :read-only t)
  (more nil :read-only t)
  (hash nil))

(defstruct (lazy-seq (:include skein-seq) (:constructor make-lazy-seq (fn)) (:copier nil))
  "A lazy seq. FN is called once, the first time the seq is needed."
  (fn nil)
  (value nil)
  (seq nil)
  (hash nil))

;;; ------------------------------------------------------------------------------------
;;; Atoms (DESIGN §6.3; functions in atoms.lisp)

(defstruct (skein-atom (:constructor make-skein-atom (value)) (:copier nil))
  "A Skein atom: a box whose value changes only by compare-and-swap."
  (value nil))

(setf (documentation 'skein-atom-p 'function) "Return true if the argument is an atom."
      (documentation 'skein-atom-value 'function) "Return the current value of an atom.")

;;; ------------------------------------------------------------------------------------
;;; Value structs and arrays of them (DESIGN §9; functions in structs.lisp)

(defstruct (struct-def (:constructor make-struct-def (name cl-type value-p fields))
                       (:copier nil))
  "A type defined by defstruct. NAME is its qualified name, CL-TYPE the CL struct type,
VALUE-P true for value structs, FIELDS a list of FIELD-DEFs. LEAVES lists, for arrays of
value structs, the path to each primitive field as (field-def ...), with its CL type."
  (name "" :type string :read-only t)
  (cl-type nil :read-only t)
  (value-p nil :read-only t)
  (fields '() :read-only t)
  (constructor nil)
  (leaves '()))

(defstruct (field-def (:constructor make-field-def (name type cl-type slot accessor))
                      (:copier nil))
  "A field of a defstruct: its NAME (a string), Skein TYPE (data), CL-TYPE, the CL SLOT
name and the CL ACCESSOR function name."
  (name "" :type string :read-only t)
  (type nil :read-only t)
  (cl-type t :read-only t)
  (slot nil :read-only t)
  (accessor nil :read-only t))

(defstruct (struct-array (:constructor make-struct-array* (def count columns))
                         (:copier nil))
  "A fixed-length mutable array of value structs, stored inline as one specialized CL
array per primitive field (COLUMNS, in the order of the DEF's leaves)."
  (def nil :read-only t)
  (count 0 :type fixnum :read-only t)
  (columns #() :type simple-vector :read-only t))

(setf (documentation 'struct-def-p 'function) "Return true if the argument is a struct type."
      (documentation 'struct-array-p 'function)
      "Return true if the argument is an array of value structs.")

(defstruct (byte-view (:constructor make-byte-view (array)) (:copier nil))
  "The bytes of a primitive array, for passing to C (as-bytes, DESIGN §9.3)."
  (array nil :read-only t))

(setf (documentation 'byte-view-p 'function) "Return true if the argument is a byte view."
      (documentation 'byte-view-array 'function) "Return the array a byte view shows.")

;;; ------------------------------------------------------------------------------------
;;; Concurrency (DESIGN §13; functions in concurrency.lisp and channels.lisp)

(defstruct (task (:constructor %make-task (fn scopes nursery context)) (:copier nil))
  "A unit of work: a fiber in Phase 0. STATE is :pending, :running, :done, :failed or
:cancelled."
  (fn nil)
  (scopes '())
  (nursery nil)
  (context '())
  (state :pending)
  (result nil)
  (condition nil)
  (cancel-requested nil)
  (lock (sb-thread:make-mutex :name "task") :read-only t)
  (done (sb-thread:make-waitqueue) :read-only t))

(defstruct (nursery (:constructor make-nursery ()) (:copier nil))
  "A scope that owns the tasks spawned into it and waits for all of them."
  (children '())
  (failure nil)
  (cancelled nil)
  (lock (sb-thread:make-mutex :name "nursery") :read-only t))

(defstruct (chan (:constructor %make-chan (capacity)) (:copier nil))
  "A channel. CAPACITY 0 means unbuffered: a put completes when a taker takes the value."
  (capacity 0 :type (integer 0) :read-only t)
  (items '())
  (closed nil)
  (puts 0 :type integer)
  (takes 0 :type integer)
  (takers-waiting 0 :type integer))

;;; ------------------------------------------------------------------------------------
;;; Reductions

(defstruct (reduced (:constructor make-reduced (value)) (:copier nil))
  "Wraps a value to stop a reduction early."
  (value nil :read-only t))

(defstruct (eduction (:constructor make-eduction (xform coll)) (:copier nil))
  "A collection with a transducer applied each time it is reduced or seq'd."
  (xform nil :read-only t)
  (coll nil :read-only t))

;;; Documentation for the exported predicates.
(setf (documentation 'pvector-p 'function) "Return true if the argument is a persistent vector."
      (documentation 'plist-p 'function) "Return true if the argument is a non-empty list."
      (documentation 'empty-list-p 'function) "Return true if the argument is the empty list."
      (documentation 'array-map-p 'function) "Return true if the argument is an array map."
      (documentation 'hash-map-p 'function) "Return true if the argument is a HAMT map."
      (documentation 'hash-set-p 'function) "Return true if the argument is a persistent set."
      (documentation 'lazy-seq-p 'function) "Return true if the argument is a lazy seq.")

;;; ------------------------------------------------------------------------------------
;;; Edit tokens for transients. A token is a cons whose car is the owning thread; nodes
;;; created by a transient carry its token, so the transient may change them in place.

(defun make-edit-token ()
  (list sb-thread:*current-thread*))

(defun check-edit (edit what)
  "Check that a transient whose token is EDIT may be used here and now."
  (cond ((null edit)
         (error 'transient-error :location nil
                                 :message (format nil "~A used after persistent!" what)))
        ((not (eq (car edit) sb-thread:*current-thread*))
         (error 'transient-error :location nil
                                 :message (format nil "~A used by a thread that does not ~
                                                       own it" what)))))
