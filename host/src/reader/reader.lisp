;;;; The Skein reader (DESIGN §3).

(in-package #:skein.reader)

;;; ------------------------------------------------------------------------------------
;;; Errors

(define-condition read-error (error)
  ((message :initarg :message :reader read-error-message)
   (location :initarg :location :reader read-error-location))
  (:report (lambda (c stream)
             (format stream "~A at ~A" (read-error-message c)
                     (format-location (read-error-location c)))))
  (:documentation "Signaled when Skein source text is malformed. READ-ERROR-LOCATION
gives the source location of the problem and READ-ERROR-MESSAGE describes it."))

(setf (documentation 'read-error-message 'function)
      "Return the description of a READ-ERROR, without its location."
      (documentation 'read-error-location 'function)
      "Return the source location of a READ-ERROR.")

;;; ------------------------------------------------------------------------------------
;;; Reader state

(defstruct (fn-literal (:constructor make-fn-literal ()))
  (max-arg 0 :type (integer 0))
  (rest-p nil))

(defstruct (reader (:constructor %make-reader (stream file namespace)))
  "The state of a reader over one character stream. See MAKE-READER."
  (stream nil :read-only t)
  (file nil :type (or null string) :read-only t)
  (namespace nil :type (or null string))
  (line 1 :type (integer 1))
  (column 1 :type (integer 1))
  ;; Non-NIL while reading the body of #(...).
  (fn-literal nil :type (or null fn-literal)))

(setf (documentation 'reader-namespace 'function)
      "Return the current namespace name used to resolve ::keywords, or NIL.
SETF it when the expander enters a new namespace.")

(defun make-reader (stream &key file namespace)
  "Return a reader over the character STREAM. FILE (a string) names the source in
locations and errors. NAMESPACE is the current namespace name, used for ::keywords."
  (let ((r (%make-reader stream file namespace)))
    ;; Skip a UTF-8 byte order mark at the start of the input.
    (when (eql (peek-char nil stream nil nil) (code-char #xFEFF))
      (read-char stream))
    r))

(defun peek (r)
  (peek-char nil (reader-stream r) nil nil))

(defun next (r)
  (let ((c (read-char (reader-stream r) nil nil)))
    (cond ((null c))
          ((char= c #\Newline)
           (incf (reader-line r))
           (setf (reader-column r) 1))
          (t (incf (reader-column r))))
    c))

(defun span (r line column)
  "Return a location from LINE:COLUMN to the reader's current position."
  (make-source-location :file (reader-file r) :line line :column column
                        :end-line (reader-line r) :end-column (reader-column r)))

(defun point (r line column)
  (make-source-location :file (reader-file r) :line line :column column
                        :end-line line :end-column column))

(defun fail (r line column control &rest args)
  (error 'read-error :message (apply #'format nil control args)
                     :location (point r line column)))

(defun fail-at (location control &rest args)
  (error 'read-error :message (apply #'format nil control args) :location location))

;;; ------------------------------------------------------------------------------------
;;; Character classes

(defun whitespace-p (c)
  "Whitespace: space, tab, newline, carriage return, form feed, vertical tab and comma."
  (and c (or (member c '(#\Space #\Tab #\Newline #\Return #\Page #\,))
             (= (char-code c) 11))))

(defun terminating-p (c)
  "Characters that end a token: they always start a new form or delimit one."
  (find c "\";@^`~()[]{}\\"))

(defun token-end-p (c)
  (or (null c) (whitespace-p c) (terminating-p c)))

;;; ------------------------------------------------------------------------------------
;;; Syntax construction helpers

(defun atom-at (value location)
  (make-syntax :kind :atom :datum value :location location))

(defun compound (kind items location)
  (make-syntax :kind kind :datum items :location location))

(defun sym-syntax (name namespace location)
  (atom-at (intern-sym name namespace) location))

;;; ------------------------------------------------------------------------------------
;;; The main dispatch

(defun read-next (r)
  "Read the next item. Returns (values :FORM syntax), (values :CLOSE char line column)
for a closing delimiter, or (values :EOF). Skips whitespace, comments and #_ forms."
  (loop
    (loop while (whitespace-p (peek r)) do (next r))
    (let* ((line (reader-line r))
           (column (reader-column r))
           (c (next r)))
      (flet ((form (syntax) (return-from read-next (values :form syntax))))
        (case c
          ((nil) (return (values :eof)))
          (#\; (skip-line-comment r))
          (#\( (form (read-sequence-form r :list #\) line column)))
          (#\[ (form (read-sequence-form r :vector #\] line column)))
          (#\{ (form (read-sequence-form r :map #\} line column)))
          ((#\) #\] #\}) (return (values :close c line column)))
          (#\" (form (read-string-literal r line column)))
          (#\\ (form (read-char-literal r line column)))
          (#\' (form (read-wrapped r "quote" nil "'" line column)))
          (#\` (form (read-wrapped r "syntax-quote" "skein.core" "`" line column)))
          (#\~ (form (if (eql (peek r) #\@)
                         (progn (next r)
                                (read-wrapped r "unquote-splicing" "skein.core" "~@"
                                              line column))
                         (read-wrapped r "unquote" "skein.core" "~" line column))))
          (#\@ (form (read-wrapped r "deref" "skein.core" "@" line column)))
          (#\^ (form (read-with-meta r line column)))
          (#\# (let ((d (next r)))
                 (case d
                   (#\{ (form (read-sequence-form r :set #\} line column)))
                   (#\( (form (read-fn-literal r line column)))
                   (#\_ (read-required r "#_" line column))
                   (#\| (skip-block-comment r line column))
                   ((nil) (fail r line column "unexpected end of input after `#`"))
                   (#\# (fail r line column "`##` literals (such as ##Inf) are not ~
                                              supported yet"))
                   (t (if (token-end-p d)
                          (fail r line column "unknown dispatch `#~A`" d)
                          (fail r line column "tagged literals such as `#~A` are reserved ~
                                               and not supported yet"
                                (read-token-text r d)))))))
          (t (form (read-token-form r c line column))))))))

(defun read-required (r after line column)
  "Read one form that must follow the prefix AFTER, which started at LINE:COLUMN."
  (multiple-value-bind (kind x close-line close-column) (read-next r)
    (ecase kind
      (:form x)
      (:close (fail r close-line close-column "expected a form after `~A`, found `~A`"
                    after x))
      (:eof (fail r line column "expected a form after `~A`, reached end of input"
                  after)))))

(defun skip-line-comment (r)
  (loop for c = (next r)
        until (or (null c) (char= c #\Newline))))

(defun skip-block-comment (r line column)
  (let ((depth 1))
    (loop
      (let ((c (next r)))
        (cond ((null c) (fail r line column "unterminated block comment"))
              ((and (char= c #\|) (eql (peek r) #\#))
               (next r)
               (when (zerop (decf depth)) (return)))
              ((and (char= c #\#) (eql (peek r) #\|))
               (next r)
               (incf depth)))))))

;;; ------------------------------------------------------------------------------------
;;; Collections

(defun kind-name (kind)
  (ecase kind (:list "list") (:vector "vector") (:map "map") (:set "set")))

(defun read-sequence-form (r kind close line column)
  (let ((items '()))
    (loop
      (multiple-value-bind (what x close-line close-column) (read-next r)
        (ecase what
          (:form (push x items))
          (:close
           (unless (char= x close)
             (fail r close-line close-column
                   "expected `~A` to close the ~A at ~A, found `~A`"
                   close (kind-name kind) (format-location (point r line column)) x))
           (return))
          (:eof (fail r line column "unterminated ~A" (kind-name kind))))))
    (setf items (nreverse items))
    (case kind
      (:map (check-map-items r items line column))
      (:set (check-distinct items "element" "set")))
    (compound kind items (span r line column))))

(defun check-distinct (items what where)
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (item items)
      (let ((key (syntax-to-string item)))
        (when (gethash key seen)
          (fail-at (syntax-location item) "duplicate ~A ~A in ~A literal" what key where))
        (setf (gethash key seen) t)))))

(defun check-map-items (r items line column)
  (when (oddp (length items))
    (fail r line column "map literal has an odd number of forms (~D)" (length items)))
  (check-distinct (loop for key in items by #'cddr collect key) "key" "map"))

;;; ------------------------------------------------------------------------------------
;;; Prefix forms: 'x `x ~x ~@x @x

(defun read-wrapped (r name namespace prefix line column)
  (let* ((head (sym-syntax name namespace
                           (make-source-location :file (reader-file r) :line line
                                                 :column column :end-line line
                                                 :end-column (+ column (length prefix)))))
         (form (read-required r prefix line column)))
    (compound :list (list head form) (span r line column))))

;;; ------------------------------------------------------------------------------------
;;; Metadata: ^type x, ^:key x, ^{...} x

(defun keyword-syntax (name location)
  (atom-at (intern-kw name) location))

(defun meta-map (r m)
  "Convert the form after ^ into a map syntax object."
  (let ((loc (syntax-location m))
        (datum (syntax-datum m)))
    (case (syntax-kind m)
      (:map m)
      (:list (compound :map (list (keyword-syntax "tag" loc) m) loc))
      (:atom
       (cond ((or (sym-p datum) (stringp datum))
              (compound :map (list (keyword-syntax "tag" loc) m) loc))
             ((kw-p datum)
              (compound :map (list m (atom-at t loc)) loc))
             (t (bad-meta r m))))
      (t (bad-meta r m)))))

(defun bad-meta (r m)
  (declare (ignore r))
  (fail-at (syntax-location m)
           "metadata must be a symbol, keyword, string, map or type form, not ~A"
           (syntax-to-string m)))

(defun merge-meta (outer inner)
  "Merge two metadata maps. Keys in OUTER win."
  (if (null inner)
      outer
      (let* ((outer-items (syntax-datum outer))
             (outer-keys (loop for k in outer-items by #'cddr collect (syntax-to-string k)))
             (kept (loop for (k v) on (syntax-datum inner) by #'cddr
                         unless (member (syntax-to-string k) outer-keys :test #'string=)
                           append (list k v))))
        (compound :map (append outer-items kept) (syntax-location outer)))))

(defun read-with-meta (r line column)
  (let* ((m (meta-map r (read-required r "^" line column)))
         (target (read-required r "^ metadata" line column)))
    (unless (or (not (eq (syntax-kind target) :atom))
                (sym-p (syntax-datum target)))
      (fail-at (syntax-location target)
               "metadata can only be attached to symbols and collections, not ~A"
               (syntax-to-string target)))
    (setf (syntax-meta target) (merge-meta m (syntax-meta target)))
    target))

;;; ------------------------------------------------------------------------------------
;;; #(...) anonymous function shorthand

(defun read-fn-literal (r line column)
  (when (reader-fn-literal r)
    (fail r line column "nested #() are not allowed"))
  (let* ((state (make-fn-literal))
         (body (progn
                 (setf (reader-fn-literal r) state)
                 (unwind-protect (read-sequence-form r :list #\) line column)
                   (setf (reader-fn-literal r) nil))))
         (here (make-source-location :file (reader-file r) :line line :column column
                                     :end-line line :end-column (+ column 2)))
         (params (append (loop for i from 1 to (fn-literal-max-arg state)
                               collect (sym-syntax (format nil "%~D" i) nil here))
                         (when (fn-literal-rest-p state)
                           (list (sym-syntax "&" nil here) (sym-syntax "%&" nil here))))))
    (compound :list
              (list (sym-syntax "fn" nil here) (compound :vector params here) body)
              (span r line column))))

(defun fn-literal-arg (r name line column)
  "Handle a %-symbol NAME inside #(). Returns the symbol name to use."
  (let ((state (reader-fn-literal r)))
    (cond ((string= name "%")
           (setf (fn-literal-max-arg state) (max 1 (fn-literal-max-arg state)))
           "%1")
          ((string= name "%&")
           (setf (fn-literal-rest-p state) t)
           name)
          ((and (> (length name) 1)
                (char/= (char name 1) #\0)
                (every #'digit-char-p (subseq name 1)))
           (setf (fn-literal-max-arg state)
                 (max (parse-integer name :start 1) (fn-literal-max-arg state)))
           name)
          (t (fail r line column "invalid argument `~A` in #(): use %, %1, %2, ... or %&"
                   name)))))

;;; ------------------------------------------------------------------------------------
;;; Strings and characters

(defun read-hex4 (r line column)
  (let ((code 0))
    (dotimes (i 4 code)
      (let* ((c (next r))
             (digit (and c (digit-char-p c 16))))
        (unless digit
          (fail r line column "invalid unicode escape: `\\u` needs four hex digits"))
        (setf code (+ (* code 16) digit))))))

(defun high-surrogate-p (code) (<= #xD800 code #xDBFF))
(defun low-surrogate-p (code) (<= #xDC00 code #xDFFF))

(defun read-unicode-escape (r line column)
  "Read the XXXX of a \\uXXXX string escape, combining a surrogate pair."
  (let ((code (read-hex4 r line column)))
    (cond ((low-surrogate-p code)
           (fail r line column "unpaired surrogate \\u~4,'0X in string" code))
          ((high-surrogate-p code)
           (unless (and (eql (next r) #\\) (eql (next r) #\u))
             (fail r line column "unpaired surrogate \\u~4,'0X in string" code))
           (let ((low (read-hex4 r line column)))
             (unless (low-surrogate-p low)
               (fail r line column "unpaired surrogate \\u~4,'0X in string" code))
             (code-char (+ #x10000 (ash (- code #xD800) 10) (- low #xDC00)))))
          (t (code-char code)))))

(defun read-string-literal (r line column)
  (let ((out (make-string-output-stream)))
    (loop
      (let* ((c-line (reader-line r))
             (c-column (reader-column r))
             (c (next r)))
        (case c
          ((nil) (fail r line column "unterminated string"))
          (#\" (return))
          (#\\
           (let ((e (next r)))
             (write-char
              (case e
                ((nil) (fail r line column "unterminated string"))
                (#\n #\Newline) (#\t #\Tab) (#\r #\Return)
                (#\b #\Backspace) (#\f #\Page) (#\" #\") (#\\ #\\)
                (#\u (read-unicode-escape r c-line c-column))
                (t (fail r c-line c-column "unknown escape `\\~A` in string" e)))
              out)))
          ;; Normalize CRLF line endings in string literals to LF (D-029).
          (#\Return (unless (eql (peek r) #\Newline)
                      (write-char c out)))
          (t (write-char c out)))))
    (atom-at (get-output-stream-string out) (span r line column))))

(defun read-char-literal (r line column)
  (let ((first (next r)))
    (unless first
      (fail r line column "unexpected end of input after `\\`"))
    (let ((token (read-token-text r first)))
      (atom-at
       (cond ((= (length token) 1) first)
             ((car (rassoc token *char-names* :test #'string=)))
             ((and (= (length token) 5)
                   (char= (char token 0) #\u)
                   (every (lambda (c) (digit-char-p c 16)) (subseq token 1)))
              (let ((code (parse-integer token :start 1 :radix 16)))
                (when (or (high-surrogate-p code) (low-surrogate-p code))
                  (fail r line column "\\~A is a surrogate code point, not a character"
                        token))
                (code-char code)))
             (t (fail r line column "unsupported character literal `\\~A`" token)))
       (span r line column)))))

;;; ------------------------------------------------------------------------------------
;;; Tokens: numbers, symbols, keywords, nil, true, false

(defun read-token-text (r first)
  "Return FIRST plus the characters up to the next delimiter."
  (with-output-to-string (s)
    (write-char first s)
    (loop until (token-end-p (peek r))
          do (write-char (next r) s))))

(defun read-token-form (r first line column)
  (let ((token (read-token-text r first)))
    (atom-at (parse-token r token line column) (span r line column))))

(defun number-start-p (token)
  (or (digit-char-p (char token 0))
      (and (> (length token) 1)
           (find (char token 0) "+-")
           (digit-char-p (char token 1)))))

(defun parse-token (r token line column)
  (cond ((number-start-p token) (parse-number r token line column))
        ((char= (char token 0) #\:) (parse-keyword r token line column))
        ((string= token "nil") nil)
        ((string= token "true") t)
        ((string= token "false") +false+)
        (t (parse-symbol r token line column))))

(defun split-qualified (text)
  "Split TEXT into (values namespace name), or return NIL if it is not a valid name.
A valid name has at most one /, and its parts don't start or end with : or contain ::."
  (flet ((valid-part-p (s)
           (and (plusp (length s))
                (char/= (char s 0) #\:)
                (char/= (char s (1- (length s))) #\:)
                (not (search "::" s)))))
    (let ((slash (position #\/ text)))
      (cond ((string= text "/") (values nil "/"))
            ((null slash) (and (valid-part-p text) (values nil text)))
            (t (let ((ns (subseq text 0 slash))
                     (name (subseq text (1+ slash))))
                 (and (valid-part-p ns)
                      (or (string= name "/") (and (valid-part-p name) (not (find #\/ name))))
                      (values ns name))))))))

(defun parse-symbol (r token line column)
  (multiple-value-bind (ns name) (split-qualified token)
    (unless name
      (fail r line column "invalid symbol `~A`" token))
    (when (and (reader-fn-literal r) (null ns) (char= (char name 0) #\%))
      (setf name (fn-literal-arg r name line column)))
    (intern-sym name ns)))

(defun parse-keyword (r token line column)
  (if (and (> (length token) 1) (char= (char token 1) #\:))
      (let ((name (subseq token 2)))
        (when (find #\/ name)
          (fail r line column "`::alias/name` keywords are not supported yet: `~A`" token))
        (unless (nth-value 1 (split-qualified name))
          (fail r line column "invalid keyword `~A`" token))
        (unless (reader-namespace r)
          (fail r line column "`~A` needs a current namespace" token))
        (intern-kw name (reader-namespace r)))
      (multiple-value-bind (ns name) (split-qualified (subseq token 1))
        (when (or (null name) (string= name "/"))
          (fail r line column "invalid keyword `~A`" token))
        (intern-kw name ns))))

;;; Numbers (D-029): 42 -7 0xFF 0b1010 1_000_000 3.14 1e-9 3.14f 1.0e5f.
;;; Underscores may only appear between digits. Leading zeros are rejected (no octal),
;;; a decimal point needs digits on both sides, and the f suffix needs a float.

(defun parse-number (r token line column)
  (let ((pos 0)
        (end (length token))
        (negative nil))
    (labels ((bad (control &rest args)
               (apply #'fail r line column control args))
             (invalid () (bad "invalid number `~A`" token))
             (peek-is (chars) (and (< pos end) (find (char token pos) chars)))
             (digits (radix)
               ;; Read a run of digits and underscores; return the digits only.
               (let ((start pos))
                 (loop while (and (< pos end)
                                  (or (digit-char-p (char token pos) radix)
                                      (char= (char token pos) #\_)))
                       do (incf pos))
                 (let ((run (subseq token start pos)))
                   (when (or (zerop (length run))
                             (char= (char run 0) #\_)
                             (char= (char run (1- (length run))) #\_)
                             (search "__" run))
                     (if (find #\_ run)
                         (bad "misplaced underscore in number `~A`" token)
                         (invalid)))
                   (remove #\_ run)))))
      (when (peek-is "+-")
        (setf negative (char= (char token pos) #\-))
        (incf pos))
      (flet ((radix-integer (radix)
               (incf pos 2)
               (let ((value (parse-integer (digits radix) :radix radix)))
                 (unless (= pos end) (invalid))
                 (if negative (- value) value))))
        (when (and (< (1+ pos) end) (char= (char token pos) #\0))
          (case (char token (1+ pos))
            ((#\x #\X) (return-from parse-number (radix-integer 16)))
            ((#\b #\B) (return-from parse-number (radix-integer 2))))))
      (let* ((int-digits (digits 10))
             (frac-digits "")
             (exponent 0)
             (float-p nil))
        (when (and (> (length int-digits) 1) (char= (char int-digits 0) #\0))
          (bad "leading zeros are not allowed in `~A` (Skein has no octal literals)" token))
        (when (peek-is ".")
          (incf pos)
          (unless (and (< pos end) (digit-char-p (char token pos)))
            (bad "a digit must follow the decimal point in `~A`" token))
          (setf frac-digits (digits 10) float-p t))
        (when (peek-is "eE")
          (incf pos)
          (let ((exp-negative (and (peek-is "+-") (char= (char token pos) #\-))))
            (when (peek-is "+-") (incf pos))
            (unless (and (< pos end) (digit-char-p (char token pos))) (invalid))
            (let ((e (parse-integer (digits 10))))
              (setf exponent (if exp-negative (- e) e) float-p t))))
        (let ((type :f64))
          (when (peek-is "f")
            (unless float-p
              (bad "the f suffix needs a float literal such as 1.0f, not `~A`" token))
            (incf pos)
            (setf type :f32))
          (unless (= pos end) (invalid))
          (if float-p
              (handler-case
                  (decimal-to-float negative
                                    (parse-integer (concatenate 'string int-digits
                                                                frac-digits))
                                    (- exponent (length frac-digits))
                                    type)
                (float-out-of-range ()
                  (bad "float literal `~A` is too large for ~(~A~)" token type)))
              (let ((value (parse-integer int-digits)))
                (if negative (- value) value))))))))

;;; ------------------------------------------------------------------------------------
;;; Public entry points

(defun read-form (reader &key eof-error-p eof-value)
  "Read the next form from READER and return it as a syntax object.
At end of input, signal a READ-ERROR if EOF-ERROR-P is true, else return EOF-VALUE."
  (multiple-value-bind (kind x line column) (read-next reader)
    (ecase kind
      (:form x)
      (:close (fail reader line column "unexpected `~A`" x))
      (:eof (if eof-error-p
                (fail reader (reader-line reader) (reader-column reader)
                      "unexpected end of input")
                eof-value)))))

(defun read-all (reader)
  "Read every remaining form from READER and return them as a list of syntax objects."
  (loop with eof = '#:eof
        for form = (read-form reader :eof-value eof)
        until (eq form eof)
        collect form))

(defun read-forms-from-string (string &key file namespace)
  "Read every form in STRING and return a list of syntax objects."
  (with-input-from-string (s string)
    (read-all (make-reader s :file file :namespace namespace))))

(defun read-form-from-string (string &key file namespace)
  "Read exactly one form from STRING and return it. Signals a READ-ERROR if STRING
holds no forms or more than one."
  (with-input-from-string (s string)
    (let* ((r (make-reader s :file file :namespace namespace))
           (form (read-form r :eof-error-p t))
           (eof '#:eof)
           (extra (read-form r :eof-value eof)))
      (unless (eq extra eof)
        (fail-at (syntax-location extra) "expected one form, found more"))
      form)))

(defun read-file (path &key namespace)
  "Read every form in the UTF-8 file at PATH and return a list of syntax objects.
Locations name the file as PATH was given."
  (with-open-file (s path :external-format :utf-8)
    (read-all (make-reader s :file (if (stringp path) path (namestring path))
                             :namespace namespace))))
