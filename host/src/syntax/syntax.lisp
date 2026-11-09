;;;; Source locations and syntax objects.

(in-package #:skein.syntax)

(defstruct (source-location (:copier nil))
  "Where a form appears in source: FILE (a string, or NIL for input with no file), and
1-based LINE and COLUMN of its first character. END-LINE and END-COLUMN give the
position just after its last character. Columns count characters, not bytes."
  (file nil :type (or null string) :read-only t)
  (line 1 :type (integer 1) :read-only t)
  (column 1 :type (integer 1) :read-only t)
  (end-line 1 :type (integer 1) :read-only t)
  (end-column 1 :type (integer 1) :read-only t))

(setf (documentation 'source-location-file 'function)
      "Return the file of a source location, or NIL."
      (documentation 'source-location-line 'function)
      "Return the 1-based line where a form starts."
      (documentation 'source-location-column 'function)
      "Return the 1-based column where a form starts."
      (documentation 'source-location-end-line 'function)
      "Return the line just after a form ends."
      (documentation 'source-location-end-column 'function)
      "Return the column just after a form ends."
      (documentation 'source-location-p 'function)
      "Return true if the argument is a source location.")

(defun format-location (location)
  "Return LOCATION as \"file:line:column\", using \"<input>\" when there is no file.
Returns \"<unknown location>\" if LOCATION is NIL."
  (if location
      (format nil "~A:~D:~D"
              (or (source-location-file location) "<input>")
              (source-location-line location)
              (source-location-column location))
      "<unknown location>"))

(defstruct (syntax (:copier nil))
  "A Skein form plus where it came from. See the skein.syntax package documentation."
  (kind :atom :type (member :atom :list :vector :map :set) :read-only t)
  (datum nil :read-only t)
  (location nil :type (or null source-location) :read-only t)
  (meta nil :type (or null syntax)))

(setf (documentation 'syntax-kind 'function)
      "Return the kind of a syntax object: :ATOM, :LIST, :VECTOR, :MAP or :SET."
      (documentation 'syntax-datum 'function)
      "Return the datum of a syntax object: the atom, or a list of child syntax objects."
      (documentation 'syntax-location 'function)
      "Return the source location of a syntax object, or NIL."
      (documentation 'syntax-meta 'function)
      "Return the metadata of a syntax object (a :MAP syntax object), or NIL."
      (documentation 'syntax-p 'function)
      "Return true if the argument is a syntax object.")

(defun atom-syntax-p (syntax)
  "Return true if SYNTAX is a syntax object of kind :ATOM."
  (and (syntax-p syntax) (eq (syntax-kind syntax) :atom)))

(defun syntax-items (syntax)
  "Return the child syntax objects of a compound syntax object, in source order."
  (assert (not (atom-syntax-p syntax)) (syntax) "~S is an atom, not a compound form" syntax)
  (syntax-datum syntax))

(defun atom-equal (a b)
  (cond ((and (stringp a) (stringp b)) (string= a b))
        (t (eql a b))))

(defun syntax-equal (a b &key meta)
  "Return true if syntax objects A and B represent the same form, ignoring source
locations. Metadata is compared only when META is true."
  (and (eq (syntax-kind a) (syntax-kind b))
       (if (eq (syntax-kind a) :atom)
           (atom-equal (syntax-datum a) (syntax-datum b))
           (let ((xs (syntax-datum a))
                 (ys (syntax-datum b)))
             (and (= (length xs) (length ys))
                  (every (lambda (x y) (syntax-equal x y :meta meta)) xs ys))))
       (or (not meta)
           (let ((ma (syntax-meta a))
                 (mb (syntax-meta b)))
             (if (and ma mb)
                 (syntax-equal ma mb :meta t)
                 (and (null ma) (null mb)))))))
