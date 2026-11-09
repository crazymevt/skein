;;;; The Skein reader (DESIGN §3). Must not use the CL reader or readtables.

(defpackage #:skein.reader
  (:use #:cl)
  (:import-from #:skein.syntax
                #:make-syntax #:syntax-kind #:syntax-datum #:syntax-location #:syntax-meta
                #:make-source-location #:format-location #:syntax-to-string)
  (:import-from #:skein.runtime
                #:intern-sym #:intern-kw #:sym-p #:sym-name #:sym-namespace #:kw-p
                #:+false+ #:decimal-to-float #:float-out-of-range #:*char-names*)
  (:export
   #:reader #:make-reader #:reader-namespace
   #:read-form #:read-all
   #:read-forms-from-string #:read-form-from-string #:read-file
   #:read-error #:read-error-message #:read-error-location)
  (:documentation "The Skein reader: turns a character stream into syntax objects.

The reader reads one form at a time so that the expander can change the current
namespace (used by ::keywords) between forms. It never uses the CL reader."))
