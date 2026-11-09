;;;; The Skein reader (DESIGN §3). Must not use the CL reader or readtables.

(defpackage #:skein.reader
  (:use #:cl)
  (:documentation "The Skein reader: turns a character stream into syntax objects."))
