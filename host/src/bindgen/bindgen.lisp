;;;; skein bindgen: C headers → Skein FFI declarations (DESIGN §14.4, D-038).
;;;;
;;;; clang does the C parsing. `clang -Xclang -ast-dump=json` gives the declarations and
;;;; `clang -E -dD` gives the #define lines with the files they come from. This file maps
;;;; C types to foreign types, evaluates simple constant macros and prints Skein source.

(in-package #:skein.bindgen)

;;; ------------------------------------------------------------------------------------
;;; Options and collected declarations

(defstruct (options (:conc-name opt-))
  (headers '())              ; the headers whose declarations are emitted
  (prefix "")                ; C name prefix, e.g. "SDL_"
  (namespace "bindings")
  (library-name nil)         ; var name for deflibrary, or NIL for no deflibrary
  (library-files '())        ; list of (os . file)
  (include-dirs '())
  (blocking '())             ; C function names to mark ^:blocking
  (clang "clang"))

(defvar *options*)
(defvar *records*)    ; C tag or typedef name → record
(defvar *enums*)      ; C name → enum
(defvar *typedefs*)   ; C name → JSON type object
(defvar *functions*)  ; list of FunctionDecl objects, in order
(defvar *macros*)     ; name → macro
(defvar *enumerators*) ; C enumerator name → integer
(defvar *names*)      ; Skein names already used
(defvar *selected-files*)

(defstruct record name kind fields file complete (emitted nil) (skein-name nil))
(defstruct enum name constants file)
(defstruct cmacro name params body file)

(defun selected-file-p (file)
  (and file (member (file-namestring file) *selected-files* :test #'string=)))

;;; ------------------------------------------------------------------------------------
;;; Names

(defun kebab (name)
  "Turn a C name into kebab case: CreateWindow → create-window, GPUDevice → gpu-device,
FRect → frect, INIT_VIDEO → init-video, windowID → window-id."
  (let ((out (make-string-output-stream))
        (run 0))                        ; uppercase letters since the last boundary
    (loop for i from 0 below (length name)
          for c = (char name i)
          for prev = (and (> i 0) (char name (1- i)))
          for next = (and (< (1+ i) (length name)) (char name (1+ i)))
          do (cond ((char= c #\_)
                    (setf run 0)
                    (unless (or (zerop i) (eql prev #\_)) (write-char #\- out)))
                   ((upper-case-p c)
                    (when (and prev (not (eql prev #\_))
                               (or (lower-case-p prev) (digit-char-p prev)
                                   (and (upper-case-p prev) next (lower-case-p next)
                                        (>= run 2))))
                      (write-char #\- out)
                      (setf run 0))
                    (incf run)
                    (write-char (char-downcase c) out))
                   (t (setf run 0) (write-char c out))))
    (string-right-trim "-" (get-output-stream-string out))))

(defun c-name-to-skein (c-name prefix &key keep-prefix)
  "The Skein name for C-NAME: kebab case, without PREFIX unless KEEP-PREFIX."
  (kebab (if (and (not keep-prefix) (plusp (length prefix))
                  (> (length c-name) (length prefix))
                  (string= prefix c-name :end2 (length prefix)))
             (subseq c-name (length prefix))
             c-name)))

(defun claim-name (c-name &key keep-prefix)
  "Reserve a Skein name for C-NAME. If the short name is taken, use the name with its
prefix; return NIL if that is taken too."
  (let ((short (c-name-to-skein c-name (opt-prefix *options*) :keep-prefix keep-prefix))
        (long (kebab c-name)))
    (loop for candidate in (list short long)
          unless (or (gethash candidate *names*)
                     (skein.expander:special-form-p candidate)
                     (zerop (length candidate))
                     (digit-char-p (char candidate 0)))
            do (setf (gethash candidate *names*) c-name)
               (return candidate))))

;;; ------------------------------------------------------------------------------------
;;; Collecting declarations from the AST dump

(defun collect-decl (decl)
  (let ((kind (jget decl "kind"))
        (name (jget decl "name"))
        (file (jget decl "_file")))
    (cond ((null name))
          ((string= kind "RecordDecl")
           (let ((old (gethash name *records*)))
             (when (or (null old) (and (jget decl "completeDefinition")
                                       (not (record-complete old))))
               (setf (gethash name *records*)
                     (make-record :name name
                                  :kind (if (equal (jget decl "tagUsed") "union") :union :struct)
                                  :fields (jget decl "inner") :file file
                                  :complete (eq (jget decl "completeDefinition") t))))))
          ((string= kind "EnumDecl")
           (when (jget decl "inner")
             (let ((next 0) (constants '()))
               (dolist (c (jget decl "inner"))
                 (when (equal (jget c "kind") "EnumConstantDecl")
                   (let* ((init (first (jget c "inner")))
                          (value (if (and init (jget init "value"))
                                     (parse-integer (jget init "value"))
                                     next)))
                     (push (cons (jget c "name") value) constants)
                     (setf (gethash (jget c "name") *enumerators*) value
                           next (1+ value)))))
               (setf (gethash name *enums*)
                     (make-enum :name name :constants (nreverse constants) :file file)))))
          ((string= kind "TypedefDecl")
           (setf (gethash name *typedefs*) decl))
          ((string= kind "FunctionDecl")
           (unless (find name *functions* :key (lambda (f) (jget f "name")) :test #'equal)
             (push decl *functions*))))))

;;; ------------------------------------------------------------------------------------
;;; C types → foreign types

(defparameter *c-primitives*
  '(("void" . "void") ("_Bool" . "bool") ("bool" . "bool")
    ("char" . "i8") ("signed char" . "i8") ("unsigned char" . "u8")
    ("short" . "i16") ("short int" . "i16") ("signed short" . "i16")
    ("unsigned short" . "u16") ("unsigned short int" . "u16")
    ("int" . "i32") ("signed" . "i32") ("signed int" . "i32")
    ("unsigned" . "u32") ("unsigned int" . "u32")
    ;; long is assumed to be 64 bits (LP64); see the ROADMAP note about Windows.
    ("long" . "i64") ("long int" . "i64") ("unsigned long" . "u64")
    ("unsigned long int" . "u64")
    ("long long" . "i64") ("long long int" . "i64") ("unsigned long long" . "u64")
    ("unsigned long long int" . "u64")
    ("float" . "f32") ("double" . "f64")
    ("int8_t" . "i8") ("int16_t" . "i16") ("int32_t" . "i32") ("int64_t" . "i64")
    ("uint8_t" . "u8") ("uint16_t" . "u16") ("uint32_t" . "u32") ("uint64_t" . "u64")
    ("size_t" . "u64") ("ssize_t" . "i64") ("intptr_t" . "i64") ("uintptr_t" . "u64")
    ("ptrdiff_t" . "i64"))
  "C type names and the foreign types they map to.")

(defparameter *ignored-qualifiers*
  '("const" "volatile" "restrict" "__restrict" "_Nonnull" "_Nullable" "_Null_unspecified"
    "__unaligned"))

(define-condition unsupported-type (error)
  ((reason :initarg :reason :reader unsupported-reason))
  (:report (lambda (c s) (write-string (unsupported-reason c) s)))
  (:documentation "Internal: a C type that bindgen cannot express."))

(defun unsupported-type (control &rest args)
  (error 'unsupported-type :reason (apply #'format nil control args)))

(defun words (string)
  (remove "" (uiop:split-string string :separator '(#\Space #\Tab)) :test #'string=))

(defun strip-qualifiers (string)
  (format nil "~{~A~^ ~}"
          (remove-if (lambda (w) (member w *ignored-qualifiers* :test #'string=))
                     (words string))))

(defun split-array-suffix (string)
  "Split \"float[4][4]\" into \"float\" and (4 4)."
  (let ((dims '()) (s (string-right-trim " " string)))
    (loop while (and (plusp (length s)) (char= (char s (1- (length s))) #\]))
          do (let ((open (position #\[ s :from-end t)))
               (push (or (parse-integer s :start (1+ open) :end (1- (length s))
                                          :junk-allowed t)
                         (unsupported-type "has a flexible array member"))
                     dims)
               (setf s (string-right-trim " " (subseq s 0 open)))))
    (values s dims)))

(defun record-for (c-name)
  (let ((r (gethash c-name *records*)))
    (and r (record-complete r) r)))

(defun record-skein (record)
  "The Skein name of RECORD's defcstruct or defcunion."
  (or (record-skein-name record)
      (setf (record-skein-name record) (kebab (record-name record)))))

(defun enum-type-name (enum)
  "The Skein name of ENUM's defcenum, or its base type when ENUM is not emitted."
  (if (selected-file-p (enum-file enum))
      (kebab (enum-name enum))
      (enum-base enum)))

(defun enum-base (enum)
  (let ((values (mapcar #'cdr (enum-constants enum))))
    (cond ((null values) "i32")
          ((every (lambda (v) (<= (- (expt 2 31)) v (1- (expt 2 31)))) values) "i32")
          ((every (lambda (v) (<= 0 v (1- (expt 2 32)))) values) "u32")
          ((every (lambda (v) (<= 0 v)) values) "u64")
          (t "i64"))))

(defun resolve-base (base)
  "Map a C type name without pointers or arrays to (values foreign-type kind), where kind
is :primitive, :record, :opaque, :enum or :function-pointer. Return NIL when the name is
unknown."
  (let ((prim (cdr (assoc base *c-primitives* :test #'string=))))
    (when prim (return-from resolve-base (values prim :primitive))))
  (let* ((w (words base))
         (tag (and (rest w) (member (first w) '("struct" "union" "enum") :test #'string=)
                   (second w))))
    (cond ((and tag (string= (first w) "enum"))
           (let ((e (gethash tag *enums*)))
             (if e (values (enum-type-name e) :enum) (values "i32" :primitive))))
          (tag
           (let ((r (record-for tag)))
             (if r (values (record-skein r) :record) (values (kebab tag) :opaque))))
          ((gethash base *typedefs*)
           (let ((target (jget (gethash base *typedefs*) "type" "qualType")))
             (cond ((search "(*)" target) (values "ptr" :function-pointer))
                   ((or (search "(unnamed" target) (search "(anonymous" target)) nil)
                   ((find #\* target)
                    (let ((type (map-type-string target :field)))
                      (and type (values type :pointer))))
                   (t (resolve-base (strip-qualifiers target))))))
          (t nil))))

(defun map-type-string (string context)
  "Map the C type STRING to a foreign type (a string of Skein source). CONTEXT is :param,
:return or :field. Return NIL if a name in it is unknown; signal UNSUPPORTED-TYPE if the
type cannot be expressed."
  (when (or (search "(*" string) (search "(^" string))
    (return-from map-type-string
      (if (search "(*)" string) "ptr" (unsupported-type "uses an array of function pointers"))))
  (let ((const-char (let ((w (words string)))
                      (and (member "const" w :test #'string=)
                           (equal (remove "const" w :test #'string=) '("char" "*"))))))
    (multiple-value-bind (s dims) (split-array-suffix (strip-qualifiers string))
      (let* ((stars (count #\* s))
             (base (string-trim " " (remove #\* s))))
        (when (and dims (not (eq context :field)))
          (setf stars (1+ stars) dims nil))
        (cond
          ((plusp stars)
           (cond ((and const-char (member context '(:param :return))) "c-string")
                 ((> stars 1) "(ptr ptr)")
                 ((string= base "void") "ptr")
                 (t (multiple-value-bind (type kind) (resolve-base base)
                      (cond ((null type) nil)
                            ((member kind '(:function-pointer :pointer)) "(ptr ptr)")
                            (t (format nil "(ptr ~A)" type)))))))
          (t
           (multiple-value-bind (type kind) (resolve-base base)
             (cond ((null type) nil)
                   ((member kind '(:opaque))
                    (unsupported-type "uses the incomplete type ~A by value" base))
                   ((and (eq kind :record) (not (eq context :field)))
                    (unsupported-type "passes the struct ~A by value" base))
                   ((and (string= type "void") (not (eq context :return)))
                    (unsupported-type "has a void value"))
                   (dims (format nil "(array ~A ~D)" type (reduce #'* dims)))
                   (t type)))))))))

(defun map-type (type-json context)
  "Map a clang type object to a foreign type string, trying the sugared type first and
the desugared one if the sugared one names something unknown."
  (or (map-type-string (jget type-json "qualType") context)
      (and (jget type-json "desugaredQualType")
           (map-type-string (jget type-json "desugaredQualType") context))
      (unsupported-type "uses the unknown type ~A" (jget type-json "qualType"))))

(defun return-type-json (function)
  "The return type of FUNCTION as a type object: the text before its parameter list."
  (flet ((before-params (s)
           (and s (let ((depth 0))
                    (loop for i from (1- (length s)) downto 0
                          for c = (char s i)
                          do (case c
                               (#\) (incf depth))
                               (#\( (decf depth)
                                (when (zerop depth)
                                  (return (string-trim " " (subseq s 0 i)))))))))))
    (let ((type (jget function "type")))
      (list (cons "qualType" (before-params (jget type "qualType")))
            (cons "desugaredQualType" (before-params (jget type "desugaredQualType")))))))

;;; ------------------------------------------------------------------------------------
;;; Records

(defun anonymous-type-p (type-json)
  (let ((q (jget type-json "qualType")))
    (or (search "(unnamed" q) (search "(anonymous" q))))

(defun record-field-specs (record)
  "Return the fields of RECORD as a list of (skein-field-name type-string), defining
records for nested anonymous structs and unions as needed. Signal UNSUPPORTED-TYPE when a
field cannot be expressed."
  (let ((pending nil) (specs '()))
    (dolist (item (record-fields record) (nreverse specs))
      (let ((kind (jget item "kind")))
        (cond ((equal kind "RecordDecl")
               (setf pending item))
              ((equal kind "FieldDecl")
               (let ((name (jget item "name")) (type (jget item "type")))
                 (when (or (null name) (string= name "") (jget item "isImplicit"))
                   (unsupported-type "has an anonymous struct or union member"))
                 (when (jget item "isBitfield")
                   (unsupported-type "has bit fields"))
                 (push (list (kebab name)
                             (if (anonymous-type-p type)
                                 (let* ((nested (make-record
                                                 :name (format nil "~A_~A" (record-name record)
                                                               name)
                                                 :kind (if (equal (jget pending "tagUsed")
                                                                  "union")
                                                           :union :struct)
                                                 :fields (jget pending "inner")
                                                 :file (record-file record) :complete t))
                                        (nested-name (format nil "~A-~A" (record-skein record)
                                                             (kebab name))))
                                   (setf (record-skein-name nested) nested-name
                                         (gethash (record-name nested) *records*) nested)
                                   (multiple-value-bind (s dims)
                                       (split-array-suffix (jget type "qualType"))
                                     (declare (ignore s))
                                     (if dims
                                         (format nil "(array ~A ~D)" nested-name
                                                 (reduce #'* dims))
                                         nested-name)))
                                 (map-type type :field)))
                       specs))))))))

(defun field-record-deps (specs)
  "The records that SPECS hold by value."
  (loop for (nil type) in specs
        for name = (if (and (> (length type) 7) (string= "(array " type :end2 7))
                       (subseq type 7 (position #\Space type :start 7))
                       type)
        for r = (loop for rec being the hash-values of *records*
                      when (and (record-complete rec) (equal (record-skein rec) name))
                        return rec)
        when r collect r))

;;; ------------------------------------------------------------------------------------
;;; Macros: reading `clang -E -dD` output and evaluating constant expressions

(defun parse-defines (text)
  "Collect the #define lines of TEXT (preprocessor output with line markers)."
  (let ((file nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (let ((line (string-right-trim '(#\Return) line)))
        (cond ((and (> (length line) 2) (string= "# " line :end2 2)
                    (digit-char-p (char line 2)))
               (let ((q1 (position #\" line)))
                 (when q1 (setf file (subseq line (1+ q1) (position #\" line :start (1+ q1)))))))
              ((and (> (length line) 8) (string= "#define " line :end2 8))
               (let* ((rest (subseq line 8))
                      (name-end (or (position-if-not
                                     (lambda (c) (or (alphanumericp c) (char= c #\_))) rest)
                                    (length rest)))
                      (name (subseq rest 0 name-end))
                      (params (and (< name-end (length rest))
                                   (char= (char rest name-end) #\()
                                   (let ((close (position #\) rest :start name-end)))
                                     (mapcar (lambda (p) (string-trim " " p))
                                             (uiop:split-string
                                              (subseq rest (1+ name-end) close)
                                              :separator '(#\,))))))
                      (body (string-trim " " (if params
                                                 (subseq rest (1+ (position #\) rest)))
                                                 (subseq rest name-end)))))
                 (setf (gethash name *macros*)
                       (make-cmacro :name name :params (if params params :object)
                                    :body body :file file)))))))))

(defun tokenize (text)
  "Split a C macro body into token strings."
  (let ((tokens '()) (i 0) (n (length text)))
    (loop
      (loop while (and (< i n) (member (char text i) '(#\Space #\Tab))) do (incf i))
      (when (>= i n) (return (nreverse tokens)))
      (let ((c (char text i)) (start i))
        (cond ((or (char= c #\") (char= c #\'))
               (incf i)
               (loop while (and (< i n) (char/= (char text i) c))
                     do (when (char= (char text i) #\\) (incf i)) (incf i))
               (incf i))
              ((or (digit-char-p c)
                   (and (char= c #\.) (< (1+ i) n) (digit-char-p (char text (1+ i)))))
               (let ((hex (and (< (1+ i) n) (char= c #\0) (char-equal (char text (1+ i)) #\x))))
                 (incf i)
                 (loop while (and (< i n)
                                  (let ((d (char text i)))
                                    (or (alphanumericp d) (char= d #\_) (char= d #\.)
                                        (and (member d '(#\+ #\-))
                                             (char-equal (char text (1- i))
                                                         (if hex #\p #\e))))))
                       do (incf i))))
              ((or (alpha-char-p c) (char= c #\_))
               (loop while (and (< i n) (or (alphanumericp (char text i))
                                            (char= (char text i) #\_)))
                     do (incf i)))
              ((and (< (1+ i) n)
                    (member (subseq text i (+ i 2)) '("<<" ">>" "##" "&&" "||" "==" "!=" "<=" ">=")
                            :test #'string=))
               (incf i 2))
              (t (incf i)))
        (push (subseq text start i) tokens)))))

(defun identifier-p (token)
  (and (plusp (length token))
       (or (alpha-char-p (char token 0)) (char= (char token 0) #\_))))

(define-condition not-constant (error) ()
  (:documentation "Internal: a macro body that is not a constant expression."))

(defun not-constant () (error 'not-constant))

(defun expand-tokens (tokens hidden)
  "Macro-expand TOKENS, never expanding the names in HIDDEN."
  (let ((out '()))
    (loop while tokens
          do (let* ((tok (pop tokens))
                    (m (and (identifier-p tok) (not (member tok hidden :test #'string=))
                            (gethash tok *macros*))))
               (cond ((null m) (push tok out))
                     ((eq (cmacro-params m) :object)
                      (dolist (x (expand-tokens (tokenize (cmacro-body m)) (cons tok hidden)))
                        (push x out)))
                     ((equal (first tokens) "(")
                      (pop tokens)
                      (let ((args '()) (current '()) (depth 0))
                        (loop
                          (let ((x (or (pop tokens) (not-constant))))
                            (cond ((and (string= x ")") (zerop depth))
                                   (push (nreverse current) args) (return))
                                  ((and (string= x ",") (zerop depth))
                                   (push (nreverse current) args) (setf current '()))
                                  (t (cond ((string= x "(") (incf depth))
                                           ((string= x ")") (decf depth)))
                                     (push x current)))))
                        (setf args (nreverse args))
                        (unless (= (length args) (length (cmacro-params m))) (not-constant))
                        (let ((body '()))
                          (dolist (x (tokenize (cmacro-body m)))
                            (when (string= x "#") (not-constant))
                            (let ((p (position x (cmacro-params m) :test #'string=)))
                              (if p
                                  (dolist (y (nth p args)) (push y body))
                                  (push x body))))
                          (setf body (nreverse body))
                          ;; token pasting
                          (loop for pos = (position "##" body :test #'string=)
                                while pos
                                do (when (or (zerop pos) (= pos (1- (length body))))
                                     (not-constant))
                                   (setf body (append (subseq body 0 (1- pos))
                                                      (tokenize (concatenate
                                                                 'string (nth (1- pos) body)
                                                                 (nth (1+ pos) body)))
                                                      (nthcdr (+ pos 2) body))))
                          (dolist (x (expand-tokens body (cons tok hidden)))
                            (push x out)))))
                     (t (not-constant)))))
    (nreverse out)))

;;; Values are (kind . value): kind is :int, :uint, :long, :ulong (value an integer),
;;; :f32 or :f64 (value the literal's text) or :string.

(defun wrap-int (kind value)
  (let* ((bits (if (member kind '(:int :uint)) 32 64))
         (v (ldb (byte bits 0) value)))
    (cons kind (if (and (member kind '(:int :long)) (logbitp (1- bits) v))
                   (- v (expt 2 bits))
                   v))))

(defun parse-number (text)
  (let* ((lower (string-downcase text))
         (hex (and (> (length lower) 1) (string= "0x" lower :end2 2))))
    (if (if hex
            (find-if (lambda (c) (find c ".p")) lower)
            (find-if (lambda (c) (find c ".e")) lower))
        (let* ((f32 (and (not hex) (char= (char lower (1- (length lower))) #\f)))
               (digits (string-right-trim "fl" lower)))
          (when hex (not-constant))
          (cons (if f32 :f32 :f64)
                (if (find #\. digits)
                    (if (char= (char digits 0) #\.) (concatenate 'string "0" digits) digits)
                    (let ((e (position #\e digits)))
                      (concatenate 'string (subseq digits 0 e) ".0" (subseq digits e))))))
        (let* ((end (position-if-not (lambda (c) (or (digit-char-p c 16) (char= c #\x)
                                                     (char= c #\b)))
                                     lower))
               (suffix (if end (subseq lower end) ""))
               (digits (if end (subseq lower 0 end) lower))
               (value (cond (hex (parse-integer digits :start 2 :radix 16))
                            ((and (> (length digits) 1) (string= "0b" digits :end2 2))
                             (parse-integer digits :start 2 :radix 2))
                            ((and (> (length digits) 1) (char= (char digits 0) #\0))
                             (parse-integer digits :radix 8))
                            (t (parse-integer digits))))
               (unsigned (find #\u suffix))
               (long (find #\l suffix)))
          (unless (every (lambda (c) (find c "ul")) suffix) (not-constant))
          (cons (cond ((and unsigned long) :ulong)
                      (unsigned (if (< value (expt 2 32)) :uint :ulong))
                      (long (if (< value (expt 2 63)) :long :ulong))
                      ((< value (expt 2 31)) :int)
                      ((and (or hex (char= (char digits 0) #\0)) (< value (expt 2 32))) :uint)
                      ((< value (expt 2 63)) :long)
                      (t :ulong))
                value)))))

(defun int-value-p (v) (member (car v) '(:int :uint :long :ulong)))

(defun arith-kind (a b)
  (let* ((wide (or (member (car a) '(:long :ulong)) (member (car b) '(:long :ulong))))
         (unsigned (or (and (member (car a) '(:uint :ulong))
                            (or (eq (car a) :ulong) (not (member (car b) '(:long :ulong)))))
                       (and (member (car b) '(:uint :ulong))
                            (or (eq (car b) :ulong) (not (member (car a) '(:long :ulong))))))))
    (if wide (if unsigned :ulong :long) (if unsigned :uint :int))))

(defun c-string-value (token)
  (let ((out (make-string-output-stream)) (i 1) (end (1- (length token))))
    (loop while (< i end)
          do (let ((c (char token i)))
               (incf i)
               (if (char= c #\\)
                   (let ((e (char token i)))
                     (incf i)
                     (write-char (case e
                                   (#\n #\Newline) (#\t #\Tab) (#\r #\Return)
                                   (#\0 (code-char 0)) (t e))
                                 out))
                   (write-char c out))))
    (get-output-stream-string out)))

(defun type-tokens-p (tokens)
  "True if TOKENS (inside parentheses) name a type, so the parentheses are a cast."
  (and tokens
       (every (lambda (tok)
                (or (string= tok "*")
                    (and (identifier-p tok)
                         (not (gethash tok *enumerators*))
                         (or (member tok '("const" "unsigned" "signed" "int" "long" "short"
                                           "char" "float" "double" "void" "struct")
                                     :test #'string=)
                             (assoc tok *c-primitives* :test #'string=)
                             (gethash tok *typedefs*)
                             (and (> (length tok) 2) (string= "_t" tok
                                                              :start2 (- (length tok) 2)))))))
              tokens)))

(defun apply-cast (type-tokens value)
  (when (member "*" type-tokens :test #'string=) (not-constant))
  (let* ((name (format nil "~{~A~^ ~}" (remove "const" type-tokens :test #'string=)))
         (prim (or (cdr (assoc name *c-primitives* :test #'string=))
                   (ignore-errors (resolve-base name)))))
    (cond ((and (int-value-p value) prim (member prim '("i8" "i16" "i32") :test #'string=))
           (wrap-int :int (cdr value)))
          ((and (int-value-p value) prim (member prim '("u8" "u16" "u32") :test #'string=))
           (wrap-int :uint (cdr value)))
          ((and (int-value-p value) prim (string= prim "i64")) (wrap-int :long (cdr value)))
          ((and (int-value-p value) prim (string= prim "u64")) (wrap-int :ulong (cdr value)))
          ((and (int-value-p value) prim (member prim '("f32" "f64") :test #'string=))
           (cons (if (string= prim "f32") :f32 :f64) (format nil "~D.0" (cdr value))))
          (t value))))

(defparameter *binary-precedence*
  '(("||" . 1) ("&&" . 2) ("|" . 3) ("^" . 4) ("&" . 5) ("==" . 6) ("!=" . 6)
    ("<" . 7) (">" . 7) ("<=" . 7) (">=" . 7) ("<<" . 8) (">>" . 8)
    ("+" . 9) ("-" . 9) ("*" . 10) ("/" . 10) ("%" . 10)))

(defun evaluate-tokens (tokens)
  "Evaluate a constant C expression given as tokens; signal NOT-CONSTANT if it isn't one."
  (let ((toks tokens))
    (labels ((peek () (first toks))
             (next () (or (pop toks) (not-constant)))
             (primary ()
               (let ((tok (next)))
                 (cond ((string= tok "(")
                        (let ((close (let ((depth 0))
                                       (position-if (lambda (x)
                                                      (cond ((string= x "(") (incf depth) nil)
                                                            ((string= x ")")
                                                             (if (zerop depth) t
                                                                 (progn (decf depth) nil)))))
                                                    toks))))
                          (unless close (not-constant))
                          (if (and (type-tokens-p (subseq toks 0 close))
                                   (nth (1+ close) toks)
                                   (or (member (nth (1+ close) toks) '("-" "+" "~" "!" "(")
                                               :test #'string=)
                                       (not (assoc (nth (1+ close) toks) *binary-precedence*
                                                   :test #'string=)))
                                   (not (string= (nth (1+ close) toks) ")")))
                              (let ((type (subseq toks 0 close)))
                                (setf toks (nthcdr (1+ close) toks))
                                (apply-cast type (unary)))
                              (let ((v (expr 0)))
                                (unless (equal (next) ")") (not-constant))
                                v))))
                       ((char= (char tok 0) #\")
                        (let ((s (c-string-value tok)))
                          (loop while (and (peek) (char= (char (peek) 0) #\"))
                                do (setf s (concatenate 'string s (c-string-value (next)))))
                          (cons :string s)))
                       ((char= (char tok 0) #\')
                        (let ((s (c-string-value tok)))
                          (unless (= (length s) 1) (not-constant))
                          (cons :int (char-code (char s 0)))))
                       ((or (digit-char-p (char tok 0)) (char= (char tok 0) #\.))
                        (parse-number tok))
                       ((gethash tok *enumerators*)
                        (cons :int (gethash tok *enumerators*)))
                       (t (not-constant)))))
             (unary ()
               (let ((tok (peek)))
                 (cond ((equal tok "-") (next)
                        (let ((v (unary)))
                          (if (int-value-p v)
                              (wrap-int (car v) (- (cdr v)))
                              (if (member (car v) '(:f32 :f64))
                                  (cons (car v) (if (char= (char (cdr v) 0) #\-)
                                                    (subseq (cdr v) 1)
                                                    (concatenate 'string "-" (cdr v))))
                                  (not-constant)))))
                       ((equal tok "+") (next) (unary))
                       ((equal tok "~") (next)
                        (let ((v (unary)))
                          (unless (int-value-p v) (not-constant))
                          (wrap-int (car v) (lognot (cdr v)))))
                       ((equal tok "!") (next)
                        (let ((v (unary)))
                          (unless (int-value-p v) (not-constant))
                          (cons :int (if (zerop (cdr v)) 1 0))))
                       (t (primary)))))
             (expr (min-prec)
               (let ((left (unary)))
                 (loop
                   (let* ((op (peek))
                          (prec (cdr (assoc op *binary-precedence* :test #'equal))))
                     (unless (and prec (> prec min-prec)) (return left))
                     (next)
                     (let ((right (expr prec)))
                       (unless (and (int-value-p left) (int-value-p right)) (not-constant))
                       (let ((a (cdr left)) (b (cdr right)) (kind (arith-kind left right)))
                         (setf left
                               (cond
                                 ((member op '("<<" ">>") :test #'string=)
                                  (let ((k (car (wrap-int (arith-kind left '(:int . 0)) 0))))
                                    (wrap-int k (if (string= op "<<") (ash a b) (ash a (- b))))))
                                 ((member op '("==" "!=" "<" ">" "<=" ">=" "&&" "||")
                                          :test #'string=)
                                  (cons :int
                                        (if (funcall (cond ((string= op "==") #'=)
                                                           ((string= op "!=") #'/=)
                                                           ((string= op "<") #'<)
                                                           ((string= op ">") #'>)
                                                           ((string= op "<=") #'<=)
                                                           ((string= op ">=") #'>=)
                                                           ((string= op "&&")
                                                            (lambda (x y) (and (/= x 0) (/= y 0))))
                                                           (t (lambda (x y)
                                                                (or (/= x 0) (/= y 0)))))
                                                     a b)
                                            1 0)))
                                 ((and (member op '("/" "%") :test #'string=) (zerop b))
                                  (not-constant))
                                 (t (wrap-int kind
                                              (cond ((string= op "|") (logior a b))
                                                    ((string= op "&") (logand a b))
                                                    ((string= op "^") (logxor a b))
                                                    ((string= op "+") (+ a b))
                                                    ((string= op "-") (- a b))
                                                    ((string= op "*") (* a b))
                                                    ((string= op "/") (truncate a b))
                                                    (t (rem a b))))))))))))))
      (let ((v (expr 0)))
        (when toks (not-constant))
        v))))

(defun macro-value (macro)
  "Evaluate an object-like MACRO; return (values value hex-p), or NIL if its body is not
a constant expression."
  (handler-case
      (let ((tokens (expand-tokens (tokenize (cmacro-body macro))
                                   (list (cmacro-name macro)))))
        (and tokens
             (values (evaluate-tokens tokens)
                     (some (lambda (tok) (and (> (length tok) 1) (string-equal "0x" tok :end2 2)))
                           tokens))))
    (not-constant () nil)
    (error () nil)))

;;; ------------------------------------------------------------------------------------
;;; Printing Skein source

(defun skein-string (string)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across string
          do (case c
               (#\" (write-string "\\\"" out))
               (#\\ (write-string "\\\\" out))
               (#\Newline (write-string "\\n" out))
               (#\Tab (write-string "\\t" out))
               (#\Return (write-string "\\r" out))
               (t (if (< (char-code c) 32)
                      (format out "\\u~4,'0X" (char-code c))
                      (write-char c out)))))
    (write-char #\" out)))

(defun value-source (value hex)
  (case (car value)
    (:string (skein-string (cdr value)))
    (:f32 (concatenate 'string (cdr value) "f"))
    (:f64 (cdr value))
    (t (if (and hex (> (cdr value) 9))
           (format nil "0x~X" (cdr value))
           (format nil "~D" (cdr value))))))

(defun fill-lines (out first-line items indent &key (separator " ") (close ""))
  "Write FIRST-LINE then ITEMS separated by SEPARATOR, wrapping before column 100 with
INDENT spaces, then CLOSE."
  (let ((column (length first-line)))
    (write-string first-line out)
    (loop for (item . more) on items
          for text = (if more (concatenate 'string item (string-right-trim " " separator)) item)
          for extra = (if more 0 (length close))
          do (when (> (+ column 1 (length text) extra) 100)
               (format out "~%~vA" indent "")
               (setf column indent))
             (when (> column indent)
               (write-char #\Space out)
               (incf column))
             (write-string text out)
             (incf column (length text)))
    (write-string close out)
    (terpri out)))

(defun write-comment (out text)
  "Write TEXT as ;; comment lines no longer than 100 characters."
  (let ((column 0))
    (dolist (word (words text))
      (cond ((zerop column) (write-string ";;" out) (setf column 2))
            ((> (+ column 1 (length word)) 100) (format out "~%;;") (setf column 2)))
      (write-char #\Space out)
      (write-string word out)
      (incf column (1+ (length word))))
    (terpri out)))

(defun emit-def (out name value-text)
  (if (<= (+ (length name) (length value-text) 7) 100)
      (format out "(def ~A ~A)~%" name value-text)
      (format out "(def ~A~%  ~A)~%" name value-text)))

(defun emit-skipped (out c-name reason)
  (format out ";; skipped ~A: ~A~%" c-name reason))

(defun emit-record (out record)
  (unless (record-emitted record)
    (setf (record-emitted record) :in-progress)
    (handler-case
        (let ((specs (record-field-specs record)))
          (dolist (dep (field-record-deps specs))
            (when (eq (record-emitted dep) :in-progress)
              (unsupported-type "contains itself"))
            (emit-record out dep)
            (unless (eq (record-emitted dep) t)
              (unsupported-type "contains ~A, which was skipped" (record-name dep))))
          (claim-name (record-name record) :keep-prefix t)
          (fill-lines out (format nil "(ffi/~A ~A"
                                  (if (eq (record-kind record) :union) "defcunion" "defcstruct")
                                  (record-skein record))
                      (loop for (f type) in specs collect (format nil "(~A ~A)" f type))
                      2 :close ")")
          (setf (record-emitted record) t))
      (unsupported-type (e)
        (emit-skipped out (record-name record) (unsupported-reason e))
        (setf (record-emitted record) :skipped)))))

(defun emit-enum (out enum)
  (let* ((names (mapcar #'car (enum-constants enum)))
         (segments (mapcar (lambda (n) (uiop:split-string n :separator '(#\_))) names))
         (common (if (rest segments)
                     (loop for i from 0
                           while (every (lambda (s)
                                          (and (< (1+ i) (length s))
                                               (equal (nth i s) (nth i (first segments)))))
                                        segments)
                           finally (return i))
                     (max 0 (1- (length (first segments))))))
         (type-name (kebab (enum-name enum))))
    (claim-name (enum-name enum) :keep-prefix t)
    (fill-lines out (format nil "(ffi/defcenum ~A ~A" type-name (enum-base enum))
                (loop for (name . value) in (enum-constants enum)
                      for segs in segments
                      collect (let ((key (loop for start downfrom common to 0
                                               for k = (kebab (format nil "~{~A~^_~}"
                                                                      (nthcdr start segs)))
                                               unless (digit-char-p (char k 0)) return k)))
                                (format nil "(:~A ~D)" key value)))
                2 :close ")")
    (dolist (c (enum-constants enum))
      (let ((name (claim-name (car c))))
        (if name
            (emit-def out name (format nil "~D" (cdr c)))
            (emit-skipped out (car c) "its name is taken"))))))

(defun emit-function (out function)
  (let ((c-name (jget function "name")))
    (cond ((eq (jget function "variadic") t) (emit-skipped out c-name "variadic"))
          ((or (eq (jget function "inline") t) (equal (jget function "storageClass") "static"))
           (emit-skipped out c-name "inline"))
          (t
           (handler-case
               (let* ((ret (map-type (return-type-json function) :return))
                      (params (loop for p in (jget function "inner")
                                    for i from 0
                                    when (equal (jget p "kind") "ParmVarDecl")
                                      collect (list (if (jget p "name")
                                                        (kebab (jget p "name"))
                                                        (format nil "arg~D" i))
                                                    (map-type (jget p "type") :param))))
                      (name (or (claim-name c-name)
                                (unsupported-type "its name is taken")))
                      (blocking (member c-name (opt-blocking *options*) :test #'string=)))
                 (let ((head (format nil "(ffi/defcfun ~:[~;^:blocking ~]~A ~S ~A"
                                     blocking name c-name ret))
                       (items (loop for (pname ptype) in params
                                    collect (format nil "~A ~A" pname ptype))))
                   (if (<= (+ (length head) (length (format nil " [~{~A~^, ~}])" items))) 100)
                       (format out "~A [~{~A~^, ~}])~%" head items)
                       (progn (if (<= (length head) 100)
                                  (write-line head out)
                                  (format out "(ffi/defcfun ~:[~;^:blocking ~]~A ~S~%  ~A~%"
                                          blocking name c-name ret))
                              (fill-lines out "  [" items 3 :separator ", " :close "])")))))
             (unsupported-type (e) (emit-skipped out c-name (unsupported-reason e))))))))

(defun emit-bindings (out)
  (let ((ns (opt-namespace *options*)))
    (write-comment out (format nil "Generated by skein bindgen from ~{~A~^, ~}. Do not edit; ~
                                    regenerate it, or wrap it in a hand-written namespace."
                               (mapcar #'file-namestring (opt-headers *options*))))
    (terpri out)
    (format out "(ns ~A~%  (:require [skein.ffi :as ffi]))~%" ns)
    (when (opt-library-name *options*)
      (claim-name (opt-library-name *options*) :keep-prefix t)
      (format out "~%(ffi/deflibrary ~A~%  {~{~A~^ ~}})~%" (opt-library-name *options*)
              (loop for (os . file) in (opt-library-files *options*)
                    collect (format nil ":~A ~A" os (skein-string file)))))
    ;; Constants from #define
    (let ((macros (sort (loop for m being the hash-values of *macros*
                              when (and (eq (cmacro-params m) :object)
                                        (selected-file-p (cmacro-file m))
                                        (prefixed-p (cmacro-name m)))
                                collect m)
                        #'string< :key #'cmacro-name))
          (header nil))
      (dolist (m macros)
        (multiple-value-bind (value hex) (macro-value m)
          (when value
            (unless header (format out "~%;;; Constants~%~%") (setf header t))
            (let ((name (claim-name (cmacro-name m))))
              (if name
                  (emit-def out name (value-source value hex))
                  (emit-skipped out (cmacro-name m) "its name is taken")))))))
    ;; Enums
    (let ((enums (sort (loop for e being the hash-values of *enums*
                             when (and (selected-file-p (enum-file e)) (enum-constants e))
                               collect e)
                       #'string< :key #'enum-name)))
      (when enums
        (format out "~%;;; Enums~%")
        (dolist (e enums) (terpri out) (emit-enum out e))))
    ;; Structs and unions
    (let ((records (sort (loop for r being the hash-values of *records*
                               when (and (record-complete r) (selected-file-p (record-file r))
                                         (prefixed-p (record-name r)))
                                 collect r)
                         #'string< :key #'record-name)))
      (when records
        (format out "~%;;; Structs and unions~%~%")
        (dolist (r records) (emit-record out r))))
    ;; Functions
    (let ((functions (sort (remove-if-not (lambda (f) (and (selected-file-p (jget f "_file"))
                                                           (prefixed-p (jget f "name"))))
                                          *functions*)
                           #'string< :key (lambda (f) (jget f "name")))))
      (when functions
        (format out "~%;;; Functions~%~%")
        (dolist (f functions) (emit-function out f))))))

(defun prefixed-p (name)
  (let ((prefix (opt-prefix *options*)))
    (and (> (length name) (length prefix)) (string= prefix name :end2 (length prefix)))))

;;; ------------------------------------------------------------------------------------
;;; Running clang

(defparameter *type-words*
  '("const" "volatile" "restrict" "struct" "union" "enum" "unsigned" "signed" "int" "long"
    "short" "char" "float" "double" "void" "_Bool" "bool" "__restrict" "_Nonnull"
    "_Nullable" "_Null_unspecified" "__unaligned")
  "Words in C type names that are not typedef names.")

(defun unknown-type-names ()
  "The typedef names used in collected declarations that bindgen cannot resolve yet.
They come from headers outside the prefix filter, such as <stdint.h> or SDL's Uint32."
  (let ((names (make-hash-table :test 'equal)))
    (labels ((scan-string (q)
               (unless (or (search "(unnamed" q) (search "(anonymous" q))
                 (dolist (tok (tokenize q))
                   (when (and (identifier-p tok)
                              (not (member tok *type-words* :test #'string=))
                              (not (assoc tok *c-primitives* :test #'string=))
                              (not (gethash tok *typedefs*))
                              (not (gethash tok *records*))
                              (not (gethash tok *enums*)))
                     (setf (gethash tok names) t)))))
             (walk (x)
               (cond ((and (consp x) (stringp (car x)) (equal (car x) "qualType")
                           (stringp (cdr x)))
                      (scan-string (cdr x)))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (dolist (f *functions*) (walk f))
      (loop for r being the hash-values of *records* do (walk (record-fields r)))
      (loop for d being the hash-values of *typedefs* do (walk (jget d "type"))))
    (sort (loop for k being the hash-keys of names collect k) #'string<)))

(defun resolve-unknown-typedefs (headers includes)
  "Ask clang what the unknown typedef names stand for, by declaring an alias of each, and
record the answers as typedefs."
  (let ((names (unknown-type-names)))
    (when names
      (uiop:with-temporary-file (:pathname source :type "c" :stream s :direction :output)
        (dolist (h headers)
          (format s "#include \"~A\"~%" (uiop:native-namestring (truename h))))
        (dolist (n names)
          (format s "typedef ~A skein_bindgen_alias_~A;~%" n n))
        (finish-output s)
        (dolist (decl (parse-json
                       (run-clang (append includes
                                          (list "-ferror-limit=0"
                                                "-Xclang" "-ast-dump=json"
                                                "-Xclang" "-ast-dump-filter=skein_bindgen_alias_"
                                                "-fsyntax-only" (uiop:native-namestring source)))
                                  :ignore-errors t)))
          (let ((name (jget decl "name")) (type (jget decl "type")))
            (when (and (equal (jget decl "kind") "TypedefDecl") name
                       (> (length name) 20))
              (setf (gethash (subseq name 20) *typedefs*)
                    (list (cons "kind" "TypedefDecl")
                          (cons "type" (list (cons "qualType"
                                                   (or (jget type "desugaredQualType")
                                                       (jget type "qualType"))))))))))))))

(defun run-clang (args &key ignore-errors)
  (multiple-value-bind (output error-output status)
      (handler-case (uiop:run-program (cons (opt-clang *options*) args)
                                      :output :string :error-output :string
                                      :ignore-error-status t)
        (error (e)
          (bindgen-error "could not run ~A (~A); install clang or set SKEIN_CLANG"
                         (opt-clang *options*) e)))
    (unless (or ignore-errors (zerop status))
      (bindgen-error "clang failed:~%~A" (string-trim '(#\Newline) error-output)))
    output))

(defun generate-bindings (headers &key (prefix "") (namespace "bindings") library-name
                                       library-files include-dirs blocking
                                       (clang (or (uiop:getenv "SKEIN_CLANG") "clang")))
  "Read the C HEADERS with clang and return Skein source that binds their functions,
structs, unions, enums and #define constants whose names start with PREFIX.
LIBRARY-FILES is a list of (os . file) for deflibrary, named LIBRARY-NAME. BLOCKING lists
the C functions to mark ^:blocking."
  (let* ((*options* (make-options :headers headers :prefix prefix :namespace namespace
                                  :library-name library-name :library-files library-files
                                  :include-dirs include-dirs :blocking blocking :clang clang))
         (*records* (make-hash-table :test 'equal))
         (*enums* (make-hash-table :test 'equal))
         (*typedefs* (make-hash-table :test 'equal))
         (*functions* '())
         (*macros* (make-hash-table :test 'equal))
         (*enumerators* (make-hash-table :test 'equal))
         (*names* (make-hash-table :test 'equal))
         (*selected-files* (mapcar #'file-namestring headers)))
    (dolist (h headers)
      (unless (probe-file h) (bindgen-error "header not found: ~A" h)))
    (uiop:with-temporary-file (:pathname source :type "c" :stream s :direction :output)
      (dolist (h headers)
        (format s "#include \"~A\"~%" (uiop:native-namestring (truename h))))
      (finish-output s)
      (let ((includes (loop for d in include-dirs collect (format nil "-I~A" d)))
            (file (uiop:native-namestring source)))
        (dolist (decl (parse-json
                       (run-clang (append includes
                                          (list "-Xclang" "-ast-dump=json"
                                                "-Xclang" (format nil "-ast-dump-filter=~A" prefix)
                                                "-fsyntax-only" file)))))
          (collect-decl decl))
        (setf *functions* (nreverse *functions*))
        (resolve-unknown-typedefs headers includes)
        (parse-defines (run-clang (append includes (list "-E" "-dD" file))))))
    (with-output-to-string (out) (emit-bindings out))))
