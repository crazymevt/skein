;;;; The C backend (Phase 1, D-044): Core IR to C11, compiled with zig cc against the
;;;; native runtime in runtime/.

(defpackage #:skein.backend.c
  (:use #:cl #:skein.ir)
  (:import-from #:skein.runtime
                #:var-namespace #:var-name #:namespace-name #:*current-namespace*
                #:ensure-namespace #:skein-error #:sym-p #:sym-name #:sym-namespace
                #:readable-string)
  (:export #:translate-file #:build-program #:c-backend-error #:native-target-name)
  (:documentation "Phase 1's C backend. TRANSLATE-FILE runs the Phase 0 front end over a
Skein file and turns its Core IR into a C11 program for the runtime's C interface
(runtime/include/skein.h); BUILD-PROGRAM compiles that with zig cc into an executable.
In M1.2 it covers numbers, strings, if, let, loop/recur, functions, vars and calls."))
