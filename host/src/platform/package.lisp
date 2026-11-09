;;;; Platform-specific code. Everything outside host/src/platform/ must work unchanged on
;;;; macOS, Windows and Linux (CLAUDE.md §4).

(defpackage #:skein.platform
  (:use #:cl)
  (:export #:cpu-count)
  (:documentation "Operating-system specific helpers: the number of CPUs."))
