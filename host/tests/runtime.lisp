;;;; Tests for skein.runtime: atoms the reader produces, float conversion and printing.

(in-package #:skein.tests)

(def-suite skein.runtime :in all
  :description "Runtime atoms, float conversion and atom printing.")

(in-suite skein.runtime)

(test symbols-and-keywords-are-interned
  (is (eq (skein.runtime:intern-sym "foo") (skein.runtime:intern-sym "foo")))
  (is (eq (skein.runtime:intern-sym "foo" "a.b") (skein.runtime:intern-sym "foo" "a.b")))
  (is (not (eq (skein.runtime:intern-sym "foo") (skein.runtime:intern-sym "Foo"))))
  (is (not (eq (skein.runtime:intern-sym "foo") (skein.runtime:intern-sym "foo" "a"))))
  (is (eq (skein.runtime:intern-kw "k") (skein.runtime:intern-kw "k")))
  (is (not (eq (skein.runtime:intern-kw "k") (skein.runtime:intern-sym "k")))))

(test false-is-distinct
  (is (skein.runtime:false-p skein.runtime:+false+))
  (is (not (skein.runtime:false-p nil)))
  (is (not (null skein.runtime:+false+))))

(test decimal-to-float
  (is (eql 0.1d0 (skein.runtime:decimal-to-float nil 1 -1 :f64)))
  (is (eql 0.1f0 (skein.runtime:decimal-to-float nil 1 -1 :f32)))
  (is (eql -0.0d0 (skein.runtime:decimal-to-float t 0 0 :f64)))
  (is (eql 0.0d0 (skein.runtime:decimal-to-float nil 1 -400 :f64)))
  (is (eql 0.0d0 (skein.runtime:decimal-to-float nil 1 -1000000000 :f64)))
  (is (eql most-positive-double-float
           (skein.runtime:decimal-to-float nil 17976931348623157 292 :f64)))
  (signals skein.runtime:float-out-of-range
    (skein.runtime:decimal-to-float nil 18 307 :f64))
  (signals skein.runtime:float-out-of-range
    (skein.runtime:decimal-to-float nil 1 1000000000 :f64))
  (signals skein.runtime:float-out-of-range
    (skein.runtime:decimal-to-float nil 1 39 :f32)))

(test print-atoms
  (flet ((p (x) (skein.runtime:atom-to-string x)))
    (is (string= "nil" (p nil)))
    (is (string= "true" (p t)))
    (is (string= "false" (p skein.runtime:+false+)))
    (is (string= "-42" (p -42)))
    (is (string= "123456789012345678901234567890" (p 123456789012345678901234567890)))
    (is (string= "3.14" (p 3.14d0)))
    (is (string= "1.0e-9" (p 1d-9)))
    (is (string= "3.14f" (p 3.14f0)))
    (is (string= "-0.0" (p -0.0d0)))
    (is (string= "\\a" (p #\a)))
    (is (string= "\\newline" (p #\Newline)))
    (is (string= "\\u0000" (p (code-char 0))))
    (is (string= "\\λ" (p #\λ)))
    (is (string= "\"a\\\"b\\\\c\\nd\\u0001é\"" (p (format nil "a\"b\\c~%d~Cé" (code-char 1)))))
    (is (string= "foo" (p (skein.runtime:intern-sym "foo"))))
    (is (string= "a.b/foo" (p (skein.runtime:intern-sym "foo" "a.b"))))
    (is (string= ":k" (p (skein.runtime:intern-kw "k"))))
    (is (string= ":a.b/k" (p (skein.runtime:intern-kw "k" "a.b"))))
    (signals skein.runtime:unprintable-value
      (p sb-ext:double-float-positive-infinity))
    (signals skein.runtime:unprintable-value (p (list 1 2)))))
