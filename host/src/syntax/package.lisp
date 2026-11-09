;;;; Syntax objects: a datum plus its source location (DESIGN §3).

(defpackage #:skein.syntax
  (:use #:cl)
  (:export
   ;; Source locations
   #:source-location #:make-source-location #:source-location-p
   #:source-location-file #:source-location-line #:source-location-column
   #:source-location-end-line #:source-location-end-column
   #:format-location
   ;; Syntax objects
   #:syntax #:make-syntax #:syntax-p
   #:syntax-kind #:syntax-datum #:syntax-location #:syntax-meta
   #:atom-syntax-p #:syntax-items
   #:syntax-equal
   ;; Printing
   #:print-syntax #:syntax-to-string)
  (:documentation "Syntax objects: Skein data annotated with source locations.

A syntax object has a KIND, a DATUM, a LOCATION and optional META. For kind :ATOM the
datum is the value itself (see skein.runtime for the representation). For :LIST,
:VECTOR, :MAP and :SET the datum is a CL list of child syntax objects in source order;
a map's children alternate key, value. META is NIL or a :MAP syntax object."))
