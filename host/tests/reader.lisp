;;;; Tests for skein.reader: every row of DESIGN §3, locations, errors and round-tripping.

(in-package #:skein.tests)

(def-suite skein.reader :in all
  :description "The Skein reader.")

(in-suite skein.reader)

;;; Which reader the tests use. The suite runs once with the CL reader, and again with
;;; the reader written in Skein (lib/skein/compiler/reader.skn, M1.6), whose syntax
;;; objects and errors are converted to the CL reader's.

(defvar *use-skein-reader* nil
  "True while the reader tests run against the reader written in Skein.")

(defun skein-reader-function (name)
  "The function skein.compiler.reader/NAME, loading the namespace the first time."
  (let ((ns (skein.runtime:find-namespace "skein.compiler.reader")))
    (unless (and ns (skein.runtime:find-own-var ns name))
      (ev "(ns reader-bridge (:require [skein.compiler.reader]))")
      (setf ns (skein.runtime:find-namespace "skein.compiler.reader")))
    (skein.runtime:var-get (skein.runtime:find-own-var ns name) nil)))

(defun skein-get (map key-name)
  (skein.runtime::map-get map (skein.runtime:intern-kw key-name)))

(defun from-skein-location (loc)
  (and loc
       (skein.syntax:make-source-location
        :file (skein-get loc "file") :line (skein-get loc "line")
        :column (skein-get loc "column") :end-line (skein-get loc "end-line")
        :end-column (skein-get loc "end-column"))))

(defun from-skein-syntax (form)
  "The Skein reader's syntax object FORM (a map) as a CL syntax object."
  (let ((kind (intern (string-upcase (skein.runtime:kw-name (skein-get form "kind")))
                      :keyword))
        (datum (skein-get form "datum"))
        (meta (skein-get form "meta")))
    (skein.syntax:make-syntax
     :kind kind
     :datum (if (eq kind :atom)
                datum
                (mapcar #'from-skein-syntax (skein.runtime:vector-to-list datum)))
     :location (from-skein-location (skein-get form "loc"))
     :meta (and meta (from-skein-syntax meta)))))

(defun call-skein-reader (name &rest args)
  "Call skein.compiler.reader/NAME, turning its read-error into a SKEIN.READER:READ-ERROR."
  (handler-bind
      ((error (lambda (c)
                (let ((type (skein.runtime::defined-type-of c)))
                  (when (and type (string= (skein.runtime:condition-type-name type)
                                           "skein.compiler.reader/read-error"))
                    (error 'skein.reader:read-error
                           :message (skein.runtime::condition-slot c "message")
                           :location (from-skein-location
                                      (skein.runtime::condition-slot c "location"))))))))
    (apply (skein-reader-function name) args)))

(defun skein-reader-options (&key file namespace resolve-alias)
  (skein.runtime::map-from-pairs
   (list (kw "file") file (kw "namespace") namespace (kw "resolve-alias") resolve-alias)))

(defun reader-read-forms-from-string (string &key file namespace)
  (if *use-skein-reader*
      (mapcar #'from-skein-syntax
              (skein.runtime:vector-to-list
               (call-skein-reader "read-string-forms" string
                                  (skein-reader-options :file file :namespace namespace))))
      (skein.reader:read-forms-from-string string :file file :namespace namespace)))

(defun reader-read-form-from-string (string &key file namespace)
  (if *use-skein-reader*
      (from-skein-syntax
       (call-skein-reader "read-string-form" string
                          (skein-reader-options :file file :namespace namespace)))
      (skein.reader:read-form-from-string string :file file :namespace namespace)))

(defun reader-make (stream &key namespace resolve-alias)
  (if *use-skein-reader*
      (call-skein-reader "make-reader" (uiop:slurp-stream-string stream)
                         (skein-reader-options :namespace namespace
                                               :resolve-alias resolve-alias))
      (skein.reader:make-reader stream :namespace namespace :resolve-alias resolve-alias)))

(defun reader-read-form (r &key eof-value)
  (if *use-skein-reader*
      (let ((form (call-skein-reader "read-form" r skein.runtime:+false+ eof-value)))
        (if (eq form eof-value) form (from-skein-syntax form)))
      (skein.reader:read-form r :eof-value eof-value)))

(defun set-reader-namespace (r namespace)
  (if *use-skein-reader*
      (call-skein-reader "set-reader-namespace!" r namespace)
      (setf (skein.reader:reader-namespace r) namespace)))

(defun reader-read-file (path)
  (if *use-skein-reader*
      (reader-read-forms-from-string
       (uiop:read-file-string path :external-format :utf-8) :file path)
      (skein.reader:read-file path)))

;;; Helpers

(defun rd (string)
  "Read exactly one form from STRING in namespace `user`."
  (reader-read-form-from-string string :file "t.skn" :namespace "user"))

(defun rd-all (string)
  (reader-read-forms-from-string string :file "t.skn" :namespace "user"))

(defun rd-str (string)
  "Read STRING and print every form back, with metadata, separated by \" | \"."
  (format nil "~{~A~^ | ~}"
          (mapcar (lambda (f) (skein.syntax:syntax-to-string f :print-meta t))
                  (rd-all string))))

(defun datum (string)
  (skein.syntax:syntax-datum (rd string)))

(defun sym (name &optional ns) (skein.runtime:intern-sym name ns))
(defun kw (name &optional ns) (skein.runtime:intern-kw name ns))

(defmacro reads-as (input expected)
  `(is (string= ,expected (rd-str ,input)) "~S read as ~S" ,input (rd-str ,input)))

(defun read-error-of (input)
  (handler-case (progn (rd-all input) nil)
    (skein.reader:read-error (e) e)))

(defmacro read-fails (input message line column)
  "Check that reading INPUT signals a READ-ERROR whose message contains MESSAGE, at
LINE:COLUMN of t.skn."
  `(let ((e (read-error-of ,input)))
     (is (not (null e)) "~S should not read" ,input)
     (when e
       (is (search ,message (skein.reader:read-error-message e))
           "~S: message ~S does not contain ~S"
           ,input (skein.reader:read-error-message e) ,message)
       (let ((loc (skein.reader:read-error-location e)))
         (is (equal (list "t.skn" ,line ,column)
                    (list (skein.syntax:source-location-file loc)
                          (skein.syntax:source-location-line loc)
                          (skein.syntax:source-location-column loc)))
             "~S: error at ~A, expected ~A:~A" ,input
             (skein.syntax:format-location loc) ,line ,column)))))

;;; DESIGN §3, row by row

(test lists
  (reads-as "(a b c)" "(a b c)")
  (reads-as "()" "()")
  (reads-as "(f (g (h x)))" "(f (g (h x)))")
  (is (eq :list (skein.syntax:syntax-kind (rd "(a)"))))
  (is (null (datum "()"))))

(test vectors
  (reads-as "[a b c]" "[a b c]")
  (reads-as "[]" "[]")
  (reads-as "[[1] [2 [3]]]" "[[1] [2 [3]]]")
  (is (eq :vector (skein.syntax:syntax-kind (rd "[1]")))))

(test maps
  (reads-as "{:a 1 :b 2}" "{:a 1, :b 2}")
  (reads-as "{}" "{}")
  (reads-as "{[1 2] {:x #{3}}}" "{[1 2] {:x #{3}}}")
  (reads-as "{1 :a 1.0 :b}" "{1 :a, 1.0 :b}")
  (is (eq :map (skein.syntax:syntax-kind (rd "{}")))))

(test sets
  (reads-as "#{1 2 3}" "#{1 2 3}")
  (reads-as "#{}" "#{}")
  (reads-as "#{[1] #{2}}" "#{[1] #{2}}")
  (is (eq :set (skein.syntax:syntax-kind (rd "#{}")))))

(test keywords
  (is (eq (kw "kw") (datum ":kw")))
  (is (eq (kw "kw" "ns") (datum ":ns/kw")))
  (is (eq (kw "kw" "a.b.c") (datum ":a.b.c/kw")))
  (is (eq (kw "kw" "user") (datum "::kw")))
  (is (eq (kw "kw" "game.player")
          (skein.syntax:syntax-datum
           (reader-read-form-from-string "::kw" :namespace "game.player"))))
  (is (eq (kw "1") (datum ":1")))
  (is (eq (kw "a?") (datum ":a?"))))

(test symbols
  (is (eq (sym "sym") (datum "sym")))
  (is (eq (sym "sym" "ns") (datum "ns/sym")))
  (is (eq (sym "/") (datum "/")))
  (is (eq (sym "/" "skein.core") (datum "skein.core//")))
  (is (not (eq (datum "Foo") (datum "foo"))) "symbols are case-sensitive")
  (dolist (name '("update!" "alive?" "*log-level*" "->" "->>" "a.b" "x#" "&" "+" "-"
                  "a'" "λ" "→" "<=" "%" "%1" "%&" "..."))
    (is (eq (sym name) (datum name)) "~S should read as a symbol" name)))

(test strings
  (is (string= "text" (datum "\"text\"")))
  (is (string= "" (datum "\"\"")))
  (is (string= (format nil "a~%b~Cc\"d\\e~Cf~Cg" #\Tab #\Return #\Backspace)
               (datum "\"a\\nb\\tc\\\"d\\\\e\\rf\\bg\"")))
  (is (string= (string #\Page) (datum "\"\\f\"")))
  (is (string= "é" (datum "\"\\u00e9\"")))
  (is (string= "é" (datum "\"\\u00E9\"")))
  (is (string= (string (code-char #x1F600)) (datum "\"\\uD83D\\uDE00\"")))
  (is (string= "λ😀" (datum "\"λ😀\"")))
  (is (string= (format nil "line1~%line2") (datum (format nil "\"line1~%line2\"")))))

(test string-literals-normalize-crlf
  (is (string= (format nil "a~%b") (datum (format nil "\"a~C~Cb\"" #\Return #\Newline))))
  (is (string= (format nil "a~Cb" #\Return) (datum (format nil "\"a~Cb\"" #\Return))))
  (is (string= (format nil "a~C~%b" #\Return) (datum "\"a\\r\\nb\""))
      "escaped \\r\\n is kept"))

(test characters
  (is (eql #\a (datum "\\a")))
  (is (eql #\Newline (datum "\\newline")))
  (is (eql #\Space (datum "\\space")))
  (is (eql #\Tab (datum "\\tab")))
  (is (eql #\Backspace (datum "\\backspace")))
  (is (eql #\Page (datum "\\formfeed")))
  (is (eql #\Return (datum "\\return")))
  (is (eql #\λ (datum "\\λ")))
  (is (eql (code-char #x1F600) (datum "\\😀")))
  (is (eql #\é (datum "\\u00e9")))
  (is (eql #\u (datum "\\u")))
  (is (eql #\( (datum "\\(")))
  (is (eql #\\ (datum "\\\\")))
  (is (equal (list #\a #\b) (mapcar #'skein.syntax:syntax-datum
                                    (skein.syntax:syntax-items (rd "(\\a \\b)"))))))

(test integers
  (is (eql 42 (datum "42")))
  (is (eql -7 (datum "-7")))
  (is (eql 5 (datum "+5")))
  (is (eql 0 (datum "0")))
  (is (eql 0 (datum "-0")))
  (is (eql 255 (datum "0xFF")))
  (is (eql 255 (datum "0xff")))
  (is (eql -255 (datum "-0xFF")))
  (is (eql 10 (datum "0b1010")))
  (is (eql 1000000 (datum "1_000_000")))
  (is (eql #xFFFF (datum "0xFF_FF")))
  (is (eql 123456789012345678901234567890 (datum "123456789012345678901234567890"))))

(test symbolic-floats
  (is (eql skein.runtime:+f64-infinity+ (datum "##Inf")))
  (is (eql skein.runtime:+f64-negative-infinity+ (datum "##-Inf")))
  (is (sb-ext:float-nan-p (datum "##NaN")))
  (reads-as "[##Inf ##-Inf ##NaN]" "[##Inf ##-Inf ##NaN]")
  (reads-as "(f ##Inf)" "(f ##Inf)"))

(test f64-floats
  (is (eql 3.14d0 (datum "3.14")))
  (is (eql 1d-9 (datum "1e-9")))
  (is (eql 1d9 (datum "1E9")))
  (is (eql 1.5d3 (datum "1.5e+3")))
  (is (eql -2.5d0 (datum "-2.5")))
  (is (eql -0.0d0 (datum "-0.0")))
  (is (eql 0.5d0 (datum "0.5")))
  (is (eql 1000.5d0 (datum "1_000.5")))
  (is (eql 0.0d0 (datum "1e-400")) "too-small floats round to zero")
  (is (eql most-positive-double-float (datum "1.7976931348623157e308"))))

(test f32-floats
  (is (eql 3.14f0 (datum "3.14f")))
  (is (eql 1.0f0 (datum "1.0f")))
  (is (eql 1f5 (datum "1e5f")))
  (is (eql -2.5f-3 (datum "-2.5e-3f")))
  (is (typep (datum "0.1f") 'single-float)))

(test nil-true-false
  (is (eq nil (datum "nil")))
  (is (eq t (datum "true")))
  (is (eq skein.runtime:+false+ (datum "false")))
  (is (eq :atom (skein.syntax:syntax-kind (rd "nil"))))
  (is (eq (sym "nil?") (datum "nil?")))
  (is (eq (sym "falsey") (datum "falsey"))))

(test quote-and-friends
  (reads-as "'x" "(quote x)")
  (reads-as "'(1 2)" "(quote (1 2))")
  (reads-as "`x" "(skein.core/syntax-quote x)")
  (reads-as "~x" "(skein.core/unquote x)")
  (reads-as "~@xs" "(skein.core/unquote-splicing xs)")
  (reads-as "@a" "(skein.core/deref a)")
  (reads-as "`(when ~x (log ~@ys))"
            (concatenate 'string
                         "(skein.core/syntax-quote (when (skein.core/unquote x) "
                         "(log (skein.core/unquote-splicing ys))))"))
  (reads-as "''x" "(quote (quote x))")
  (reads-as "' x" "(quote x)"))

(test metadata
  (reads-as "^i32 n" "^{:tag i32} n")
  (reads-as "^:private x" "^{:private true} x")
  (reads-as "^{:k v} x" "^{:k v} x")
  (reads-as "^\"Str\" x" "^{:tag \"Str\"} x")
  (reads-as "^(array f32) xs" "^{:tag (array f32)} xs")
  (reads-as "^f32 [^vec2 a ^vec2 b]" "^{:tag f32} [^{:tag vec2} a ^{:tag vec2} b]")
  (reads-as "^:private ^:dynamic *x*" "^{:private true, :dynamic true} *x*")
  (reads-as "^{:a 1} ^{:a 2 :b 3} x" "^{:a 1, :b 3} x")
  (reads-as "^:m (f x)" "^{:m true} (f x)")
  (reads-as "^:m {}" "^{:m true} {}")
  (reads-as "^:m #{}" "^{:m true} #{}")
  (is (eq (sym "x") (datum "^:private x")) "metadata does not change the datum"))

(test fn-shorthand
  (reads-as "#(+ % 1)" "(fn [%1] (+ %1 1))")
  (reads-as "#(+ %1 %2)" "(fn [%1 %2] (+ %1 %2))")
  (reads-as "#(list %3)" "(fn [%1 %2 %3] (list %3))")
  (reads-as "#(apply f %&)" "(fn [& %&] (apply f %&))")
  (reads-as "#(apply f % %&)" "(fn [%1 & %&] (apply f %1 %&))")
  (reads-as "#(foo)" "(fn [] (foo))")
  (reads-as "#(vector % [%2])" "(fn [%1 %2] (vector %1 [%2]))")
  (reads-as "[#(a %) #(b %)]" "[(fn [%1] (a %1)) (fn [%1] (b %1))]")
  (reads-as "(%1 %)" "(%1 %)"))

(test discard
  (reads-as "#_x y" "y")
  (reads-as "(a #_b c)" "(a c)")
  (reads-as "(a #_(b c))" "(a)")
  (reads-as "#_ #_ a b c" "c")
  (reads-as "[1 #_2]" "[1]")
  (reads-as "{:a #_:b 1}" "{:a 1}")
  (is (null (rd-all "#_x"))))

(test comments-and-whitespace
  (reads-as "; comment
x ; trailing
; last" "x")
  (reads-as "#| block |# x" "x")
  (reads-as "#| outer #| nested |# still comment |# x" "x")
  (reads-as (format nil "#| multi~%line |# x") "x")
  (reads-as "a,b,,c" "a | b | c")
  (reads-as "[1, 2, 3]" "[1 2 3]")
  (reads-as (format nil "~Ca~Cb~Cc" #\Tab #\Page (code-char 11)) "a | b | c")
  (is (null (rd-all "")))
  (is (null (rd-all "  ; nothing here")))
  (reads-as (format nil "~Cx" (code-char #xFEFF)) "x"))

(test alias-keywords
  (with-input-from-string (s "::m/k")
    (let ((r (reader-make s :resolve-alias (lambda (a) (and (string= a "m") "skein.math")))))
      (is (eq (kw "k" "skein.math") (skein.syntax:syntax-datum (reader-read-form r)))))))

(test reader-namespace-can-change-between-forms
  (with-input-from-string (s "::a ::b")
    (let ((r (reader-make s :namespace "one")))
      (is (eq (kw "a" "one") (skein.syntax:syntax-datum (reader-read-form r))))
      (set-reader-namespace r "two")
      (is (eq (kw "b" "two") (skein.syntax:syntax-datum (reader-read-form r))))
      (is (eq :done (reader-read-form r :eof-value :done))))))

;;; Locations

(defun loc-list (syntax)
  (let ((l (skein.syntax:syntax-location syntax)))
    (list (skein.syntax:source-location-line l) (skein.syntax:source-location-column l)
          (skein.syntax:source-location-end-line l)
          (skein.syntax:source-location-end-column l))))

(test locations
  (let ((forms (rd-all (format nil "(a b)~%  [1~%   22]  :k"))))
    (is (equal '(1 1 1 6) (loc-list (first forms))))
    (is (equal '(2 3 3 7) (loc-list (second forms))))
    (is (equal '(3 9 3 11) (loc-list (third forms))))
    (destructuring-bind (one two) (skein.syntax:syntax-items (second forms))
      (is (equal '(2 4 2 5) (loc-list one)))
      (is (equal '(3 4 3 6) (loc-list two))))
    (is (equal "t.skn" (skein.syntax:source-location-file
                        (skein.syntax:syntax-location (first forms)))))))

(test locations-of-sugar
  (let ((form (rd "  'abc")))
    (is (equal '(1 3 1 7) (loc-list form)))
    (is (equal '(1 3 1 4) (loc-list (first (skein.syntax:syntax-items form))))))
  (is (equal '(1 1 1 9) (loc-list (rd "#(f % 1)"))))
  (is (equal '(1 1 1 7) (loc-list (rd "\"a\\nb\""))))
  (is (equal '(1 1 1 7) (loc-list (rd "\\space")))))

(test locations-with-crlf-and-tabs
  (let ((forms (rd-all (format nil "a~C~%~Cb" #\Return #\Tab))))
    (is (equal '(2 2 2 3) (loc-list (second forms))))))

(test location-after-multiline-string
  (let ((forms (rd-all (format nil "\"x~%yy\" z"))))
    (is (equal '(1 1 2 4) (loc-list (first forms))))
    (is (equal '(2 5 2 6) (loc-list (second forms))))))

;;; Errors

(test unterminated-forms
  (read-fails "(a b" "unterminated list" 1 1)
  (read-fails "  [1 (2)" "unterminated vector" 1 3)
  (read-fails "{:a 1" "unterminated map" 1 1)
  (read-fails "#{1" "unterminated set" 1 1)
  (read-fails (format nil "x~%  \"abc") "unterminated string" 2 3)
  (read-fails "\"abc\\" "unterminated string" 1 1)
  (read-fails "#| a #| b |# c" "unterminated block comment" 1 1)
  (read-fails "#(+ %" "unterminated list" 1 1))

(test mismatched-and-unexpected-delimiters
  (read-fails "(a]" "expected `)` to close the list at t.skn:1:1, found `]`" 1 3)
  (read-fails "[a)" "expected `]` to close the vector" 1 3)
  (read-fails "#{a]" "expected `}` to close the set" 1 4)
  (read-fails ")" "unexpected `)`" 1 1)
  (read-fails "a }" "unexpected `}`" 1 3))

(test missing-forms-after-prefixes
  (read-fails "'" "expected a form after `'`, reached end of input" 1 1)
  (read-fails "(a ')" "expected a form after `'`, found `)`" 1 5)
  (read-fails "`" "expected a form after ``" 1 1)
  (read-fails "~@" "expected a form after `~@`" 1 1)
  (read-fails "@" "expected a form after `@`" 1 1)
  (read-fails "^:k" "expected a form after `^ metadata`" 1 1)
  (read-fails "(#_)" "expected a form after `#_`, found `)`" 1 4)
  (read-fails "#" "unexpected end of input after `#`" 1 1)
  (read-fails "\\" "unexpected end of input after `\\`" 1 1))

(test bad-numbers
  (read-fails "007" "leading zeros are not allowed" 1 1)
  (read-fails "00.5" "leading zeros are not allowed" 1 1)
  (read-fails "5." "a digit must follow the decimal point" 1 1)
  (read-fails "5.e3" "a digit must follow the decimal point" 1 1)
  (read-fails "1f" "the f suffix needs a float literal" 1 1)
  (read-fails "0xFG" "invalid number" 1 1)
  (read-fails "1e400" "float literal `1e400` is too large for f64" 1 1)
  (read-fails "-1e400" "too large for f64" 1 1)
  (read-fails "1e39f" "too large for f32" 1 1)
  (read-fails "1__0" "misplaced underscore" 1 1)
  (read-fails "1_" "misplaced underscore" 1 1)
  (read-fails "1._5" "a digit must follow the decimal point" 1 1)
  (read-fails "0x_1" "misplaced underscore" 1 1)
  (read-fails "0x" "invalid number" 1 1)
  (read-fails "0b102" "invalid number" 1 1)
  (read-fails "1a" "invalid number" 1 1)
  (read-fails "-1-" "invalid number" 1 1)
  (read-fails "1e" "invalid number" 1 1)
  (read-fails "1.5F" "invalid number" 1 1))

(test bad-strings-and-chars
  (read-fails "\"a\\qb\"" "unknown escape `\\q`" 1 3)
  (read-fails "\"\\u12\"" "invalid unicode escape" 1 2)
  (read-fails "\"\\uD83D\"" "unpaired surrogate \\uD83D" 1 2)
  (read-fails "\"\\uDE00\"" "unpaired surrogate \\uDE00" 1 2)
  (read-fails "\"\\uD83D\\u0041\"" "unpaired surrogate" 1 2)
  (read-fails "\\abc" "unsupported character literal `\\abc`" 1 1)
  (read-fails "\\uD800" "surrogate code point" 1 1)
  (read-fails "\\u12" "unsupported character literal" 1 1))

(test bad-symbols-and-keywords
  (read-fails "a/b/c" "invalid symbol `a/b/c`" 1 1)
  (read-fails "a/" "invalid symbol" 1 1)
  (read-fails "/a" "invalid symbol" 1 1)
  (read-fails "a:" "invalid symbol" 1 1)
  (read-fails "a::b" "invalid symbol" 1 1)
  (read-fails ":" "invalid keyword `:`" 1 1)
  (read-fails ":/" "invalid keyword" 1 1)
  (read-fails ":a/" "invalid keyword" 1 1)
  (read-fails ":::a" "invalid keyword" 1 1)
  (read-fails "::a/b" "no namespace alias `a` for `::a/b`" 1 1)
  (read-fails "::a/" "invalid keyword" 1 1)
  (let ((e (handler-case (reader-read-form-from-string "::k")
             (skein.reader:read-error (e) e))))
    (is (search "needs a current namespace" (skein.reader:read-error-message e)))))

(test bad-collections
  (read-fails "{:a}" "map literal has an odd number of forms" 1 1)
  (read-fails "{:a 1 :b}" "odd number of forms" 1 1)
  (read-fails "{:a 1 :a 2}" "duplicate key :a in map literal" 1 7)
  (read-fails "{[1 2] 1 [1 2] 2}" "duplicate key [1 2]" 1 10)
  (read-fails "#{1 2 1}" "duplicate element 1 in set literal" 1 7)
  (read-fails "#{1 #_x 1}" "duplicate element" 1 9))

(test bad-dispatch-and-reserved-syntax
  (read-fails "#inst \"2020\"" "tagged literals such as `#inst` are reserved" 1 1)
  (read-fails "##Inf2" "unknown symbolic value `##Inf2`" 1 1)
  (read-fails "##" "unknown symbolic value `##`" 1 1)
  (read-fails "# x" "unknown dispatch" 1 1)
  (read-fails "x #\"a" "unterminated regex" 1 3)
  (read-fails "#\"a\\" "unterminated regex" 1 1))

;;; D-105: a regex literal keeps its text raw, each backslash with the character after it.
(test regex-literals
  (reads-as "#\"a+\"" "(skein.core/%regex-literal \"a+\")")
  (reads-as "#\"\\d\\.\"" "(skein.core/%regex-literal \"\\\\d\\\\.\")")
  (reads-as "#\"a\\\"b\"" "(skein.core/%regex-literal \"a\\\\\\\"b\")"))

(test bad-metadata
  (read-fails "^5 x" "metadata must be a symbol, keyword, string, map or type form" 1 2)
  (read-fails "^[a] x" "metadata must be" 1 2)
  (read-fails "^:k 5" "metadata can only be attached to symbols and collections" 1 5)
  (read-fails "^:k \"s\"" "metadata can only be attached" 1 5)
  (read-fails "^:k :x" "metadata can only be attached" 1 5))

(test bad-fn-shorthand
  (read-fails "#(a #(b))" "nested #() are not allowed" 1 5)
  (read-fails "#(%0)" "invalid argument `%0`" 1 3)
  (read-fails "#(%01)" "invalid argument `%01`" 1 3)
  (read-fails "#(%x)" "invalid argument `%x`" 1 3))

(test error-report-includes-location
  (let ((e (read-error-of (format nil "x~%  \"abc"))))
    (is (string= "unterminated string at t.skn:2:3" (princ-to-string e)))))

(test read-form-from-string-wants-one-form
  (signals skein.reader:read-error (reader-read-form-from-string ""))
  (signals skein.reader:read-error (reader-read-form-from-string "a b")))

(test read-file
  (uiop:with-temporary-file (:pathname path :type "skn")
    (with-open-file (s path :direction :output :if-exists :supersede
                            :external-format :utf-8)
      (format s "(ns demo)~%(def λ \"é\")~%"))
    (let ((forms (reader-read-file (namestring path))))
      (is (= 2 (length forms)))
      (is (string= "(def λ \"é\")" (skein.syntax:syntax-to-string (second forms))))
      (is (equal (namestring path)
                 (skein.syntax:source-location-file
                  (skein.syntax:syntax-location (second forms))))))))

;;; Round-tripping through the printer

(defparameter *round-trip-samples*
  '("(defn add [a b] (+ a b))"
    "{:a 1 :b [2 3.5 1.0e-9f] :c #{\\x \\newline}}"
    "[nil true false 0 -1 0xFF 1e100 -0.0 3.14f \"s\\\"q\\u0001\" :ns/k sym ns/sym]"
    "^:private ^{:doc \"d\"} (def ^:dynamic *x* 1)"
    "#(+ % %& %3)"
    "`(let [x# ~v] (f ~@args))"
    "(f '[a b] @c)"
    "\"multi\nline λ 😀 \\t tab\""))

(test round-trip-samples
  (dolist (src *round-trip-samples*)
    (dolist (print-meta '(nil t))
      (let* ((forms (rd-all src))
             (printed (format nil "~{~A~^ ~}"
                              (mapcar (lambda (f)
                                        (skein.syntax:syntax-to-string f :print-meta print-meta))
                                      forms)))
             (again (rd-all printed)))
        (is (= (length forms) (length again)))
        (is (every (lambda (a b) (skein.syntax:syntax-equal a b :meta print-meta))
                   forms again)
            "~S printed as ~S did not read back equal" src printed)))))

;;; Randomized tests

(defparameter *random-state-seed* 20261109)

(defun random-elt (seq rs) (elt seq (random (length seq) rs)))

(defun random-double (rs)
  (loop (let ((x (sb-kernel:make-double-float (- (random (expt 2 32) rs) (expt 2 31))
                                              (random (expt 2 32) rs))))
          (unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x))
            (return x)))))

(defun random-single (rs)
  (loop (let ((x (sb-kernel:make-single-float (- (random (expt 2 32) rs) (expt 2 31)))))
          (unless (or (sb-ext:float-infinity-p x) (sb-ext:float-nan-p x))
            (return x)))))

(defun random-char (rs)
  (loop (let ((code (case (random 4 rs)
                      (0 (random 128 rs))
                      (1 (+ 128 (random 1920 rs)))
                      (2 (random #x10000 rs))
                      (t (random char-code-limit rs)))))
          (unless (<= #xD800 code #xDFFF)
            (return (code-char code))))))

(defun random-string (rs)
  (coerce (loop repeat (random 8 rs) collect (random-char rs)) 'string))

(defparameter *random-names* '("a" "foo" "update!" "alive?" "*x*" "->" "λ" "x#" "a.b" "+"))
(defparameter *random-namespaces* '(nil nil "skein.core" "game.player"))

(defun random-atom (rs)
  (case (random 11 rs)
    (0 nil) (1 t) (2 skein.runtime:+false+)
    (3 (- (random 2000 rs) 1000))
    (4 (- (random (expt 2 100) rs) (expt 2 99)))
    (5 (random-double rs))
    (6 (random-single rs))
    (7 (random-char rs))
    (8 (random-string rs))
    (9 (sym (random-elt *random-names* rs) (random-elt *random-namespaces* rs)))
    (t (kw (random-elt *random-names* rs) (random-elt *random-namespaces* rs)))))

(defun distinct-by-printing (items)
  (let ((seen (make-hash-table :test 'equal)))
    (remove-if (lambda (x)
                 (let ((key (skein.syntax:syntax-to-string x)))
                   (prog1 (gethash key seen) (setf (gethash key seen) t))))
               items)))

(defun random-syntax (rs depth)
  (if (or (zerop depth) (< (random 10 rs) 4))
      (atom-syn (random-atom rs))
      (let* ((kind (random-elt '(:list :vector :map :set) rs))
             (items (loop repeat (random 5 rs) collect (random-syntax rs (1- depth))))
             (form
               (case kind
                 (:set (apply #'syn :set (distinct-by-printing items)))
                 (:map (let ((keys (distinct-by-printing items)))
                         (apply #'syn :map
                                (loop for k in keys
                                      append (list k (random-syntax rs (1- depth)))))))
                 (t (apply #'syn kind items)))))
        (when (< (random 10 rs) 2)
          (setf (skein.syntax:syntax-meta form)
                (syn :map (atom-syn (kw "tag")) (atom-syn (sym "i32")))))
        form)))

(test random-round-trip
  (let ((rs (sb-ext:seed-random-state *random-state-seed*)))
    (dotimes (i 2000)
      (let* ((form (random-syntax rs 4))
             (printed (skein.syntax:syntax-to-string form :print-meta t))
             (again (handler-case (rd printed)
                      (skein.reader:read-error (e)
                        (fail "~S failed to read: ~A" printed e)
                        nil))))
        (unless (and again (skein.syntax:syntax-equal form again :meta t))
          (fail "~S did not round-trip" printed)
          (return))))
    (pass)))

(test random-floats-round-trip-exactly
  (let ((rs (sb-ext:seed-random-state *random-state-seed*)))
    (dotimes (i 5000)
      (let ((d (random-double rs))
            (s (random-single rs)))
        (unless (and (eql d (datum (skein.runtime:atom-to-string d)))
                     (eql s (datum (skein.runtime:atom-to-string s))))
          (fail "~S or ~S did not round-trip" d s)
          (return))))
    (pass)))

(test random-decimals-match-reference-reader
  ;; Reference model: SBCL's own float reader, which rounds correctly.
  (let ((rs (sb-ext:seed-random-state *random-state-seed*)))
    (dotimes (i 5000)
      (let* ((digits (format nil "~D" (random (expt 10 (1+ (random 25 rs))) rs)))
             (point (random (1+ (length digits)) rs))
             (int-part (if (zerop point) "0" (string-left-trim "0" (subseq digits 0 point))))
             (int-part (if (string= int-part "") "0" int-part))
             (frac-part (if (= point (length digits)) "0" (subseq digits point)))
             (exponent (- (random 640 rs) 320))
             (text (format nil "~A.~Ae~D" int-part frac-part exponent))
             (expected (handler-case
                           (let ((*read-default-float-format* 'double-float))
                             (read-from-string text))
                         (error () :error)))
             (actual (handler-case (datum text)
                       (skein.reader:read-error () :error))))
        (unless (or (eql expected actual)
                    ;; SBCL's reader may signal for underflow where we return zero.
                    (and (eq expected :error) (eql actual 0.0d0)))
          (fail "~A: expected ~S, read ~S" text expected actual)
          (return))))
    (pass)))

;;; The reader in Skein (M1.6): the tests above, run against it

(def-suite skein.reader-in-skein :in all
  :description "The reader written in Skein, checked against the CL reader's tests.")

(in-suite skein.reader-in-skein)

(test reader-in-skein-passes-the-reader-tests
  (let* ((*use-skein-reader* t)
         (results (fiveam:run 'skein.reader)))
    (unless (fiveam:results-status results)
      (fiveam:explain! results))
    (is (fiveam:results-status results) "the reader in Skein fails some reader tests")))

(defun same-locations-p (a b)
  "True if syntax objects A and B, and everything inside them (metadata included), have
the same locations."
  (flet ((loc-list (s)
           (let ((l (skein.syntax:syntax-location s)))
             (and l (list (skein.syntax:source-location-file l)
                          (skein.syntax:source-location-line l)
                          (skein.syntax:source-location-column l)
                          (skein.syntax:source-location-end-line l)
                          (skein.syntax:source-location-end-column l))))))
    (and (equal (loc-list a) (loc-list b))
         (eq (null (skein.syntax:syntax-meta a)) (null (skein.syntax:syntax-meta b)))
         (or (null (skein.syntax:syntax-meta a))
             (same-locations-p (skein.syntax:syntax-meta a) (skein.syntax:syntax-meta b)))
         (or (eq (skein.syntax:syntax-kind a) :atom)
             (every #'same-locations-p (skein.syntax:syntax-items a)
                    (skein.syntax:syntax-items b))))))

(defun repository-program-files ()
  "The repository's .skn files that hold code: all but project files (project.skn, M1.11),
which are data."
  (remove "project" (repository-skn-files) :key #'pathname-name :test #'string=))

(defun repository-skn-files ()
  (let ((root (truename (asdf:system-relative-pathname "skein" "../"))))
    (sort (remove-if (lambda (p)
                       (let ((s (namestring p)))
                         ;; test-project and the deps fixtures are projects, whose
                         ;; namespaces are found through their project.skn files (skein
                         ;; test, M2.11; dependencies, M2.12). .claude/ holds other
                         ;; checkouts (agents' worktrees), not this one's files.
                         (or (search ".skein-cache" s) (search "/build/" s)
                             (search "/.claude/" s)
                             (search "/dist/" s) (search "/test-project/" s)
                             (search "/fixtures/deps/" s))))
                     (directory (merge-pathnames "**/*.skn" root)))
          #'string< :key #'namestring)))

(test reader-in-skein-reads-every-skn-file
  ;; The exit criterion of M1.6: the same syntax objects, data and locations, as the CL
  ;; reader for every .skn file in the repository.
  (let ((files (repository-skn-files)))
    (is (> (length files) 20) "found only ~D .skn files" (length files))
    (dolist (path files)
      (let* ((name (namestring path))
             (expected (skein.reader:read-file name :namespace "user"))
             (actual (let ((*use-skein-reader* t))
                       (reader-read-forms-from-string
                        (uiop:read-file-string path :external-format :utf-8)
                        :file name :namespace "user"))))
        (is (= (length expected) (length actual)) "~A: ~D forms, the Skein reader read ~D"
            name (length expected) (length actual))
        (loop for e in expected
              for a in actual
              unless (and (skein.syntax:syntax-equal e a :meta t) (same-locations-p e a))
                do (fail "~A: the Skein reader differs at ~A" name
                         (skein.syntax:format-location (skein.syntax:syntax-location e)))
                   (return))))))
