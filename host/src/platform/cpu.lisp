;;;; The number of CPUs available, used to size data-parallel work.

(in-package #:skein.platform)

#-win32
(defun sysconf (name)
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "sysconf" (function sb-alien:long sb-alien:int))
   name))

(defun cpu-count ()
  "Return the number of online CPUs, or 4 if it cannot be determined."
  (or (ignore-errors
       (let ((n #+win32 (parse-integer (uiop:getenv "NUMBER_OF_PROCESSORS") :junk-allowed t)
                #+darwin (sysconf 58)   ; _SC_NPROCESSORS_ONLN
                #+linux (sysconf 84)    ; _SC_NPROCESSORS_ONLN
                #-(or win32 darwin linux) nil))
         (and (integerp n) (plusp n) n)))
      4))
