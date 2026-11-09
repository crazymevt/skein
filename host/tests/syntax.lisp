;;;; Tests for skein.syntax: locations, equality and printing.

(in-package #:skein.tests)

(def-suite skein.syntax :in all
  :description "Syntax objects, locations, equality and printing.")

(in-suite skein.syntax)

(defun atom-syn (x)
  (skein.syntax:make-syntax :kind :atom :datum x))

(defun syn (kind &rest items)
  (skein.syntax:make-syntax :kind kind :datum items))

(test format-location
  (is (string= "foo.skn:12:5"
               (skein.syntax:format-location
                (skein.syntax:make-source-location :file "foo.skn" :line 12 :column 5
                                                   :end-line 12 :end-column 6))))
  (is (string= "<input>:1:1"
               (skein.syntax:format-location (skein.syntax:make-source-location))))
  (is (string= "<unknown location>" (skein.syntax:format-location nil))))

(test syntax-equal
  (let ((a (syn :list (atom-syn 1) (atom-syn "x")))
        (b (syn :list (atom-syn 1) (atom-syn "x"))))
    (is (skein.syntax:syntax-equal a b))
    (is (not (skein.syntax:syntax-equal a (syn :vector (atom-syn 1) (atom-syn "x")))))
    (is (not (skein.syntax:syntax-equal a (syn :list (atom-syn 1)))))
    (is (not (skein.syntax:syntax-equal (atom-syn 1) (atom-syn 1d0))))
    (setf (skein.syntax:syntax-meta b) (syn :map (atom-syn 1) (atom-syn 2)))
    (is (skein.syntax:syntax-equal a b))
    (is (not (skein.syntax:syntax-equal a b :meta t)))))

(test print-syntax
  (let ((form (syn :list
                   (atom-syn (skein.runtime:intern-sym "f"))
                   (syn :vector (atom-syn 1) (atom-syn 2.5d0))
                   (syn :map (atom-syn (skein.runtime:intern-kw "a")) (atom-syn 1)
                        (atom-syn (skein.runtime:intern-kw "b")) (atom-syn nil))
                   (syn :set (atom-syn #\x))
                   (syn :list))))
    (is (string= "(f [1 2.5] {:a 1, :b nil} #{\\x} ())" (skein.syntax:syntax-to-string form)))
    (setf (skein.syntax:syntax-meta (second (skein.syntax:syntax-items form)))
          (syn :map (atom-syn (skein.runtime:intern-kw "k")) (atom-syn t)))
    (is (string= "(f ^{:k true} [1 2.5] {:a 1, :b nil} #{\\x} ())"
                 (skein.syntax:syntax-to-string form :print-meta t)))))
