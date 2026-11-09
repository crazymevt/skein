;;;; Tests for skein bindgen (DESIGN §14.4, M0.10). The golden test runs clang and is
;;;; skipped when clang is not installed.

(in-package #:skein.tests)

(def-suite skein.bindgen :in all
  :description "Generating FFI bindings from C headers.")

(in-suite skein.bindgen)

(defun fixture (name)
  (namestring (asdf:system-relative-pathname "skein" (format nil "tests/fixtures/bindgen/~A"
                                                              name))))

(defun clang-available-p ()
  (ignore-errors
   (zerop (nth-value 2 (uiop:run-program (list (or (uiop:getenv "SKEIN_CLANG") "clang")
                                               "--version")
                                         :ignore-error-status t)))))

(defun demo-bindings (&key (library t))
  (skein.bindgen:generate-bindings
   (list (fixture "demo.h"))
   :prefix "DEMO_" :namespace "demo.raw"
   :library-name (and library "demo")
   :library-files (and library '(("macos" . "libdemo.dylib") ("linux" . "libdemo.so")
                                 ("windows" . "demo.dll")))
   :blocking '("DEMO_PollEvent")))

(test kebab-names
  (loop for (c skein) in '(("CreateWindow" "create-window") ("GPUDevice" "gpu-device")
                           ("FRect" "frect") ("INIT_VIDEO" "init-video")
                           ("windowID" "window-id") ("GL_SetAttribute" "gl-set-attribute")
                           ("GetRGBA" "get-rgba") ("RenderTexture9Grid" "render-texture9-grid")
                           ("IOStream" "io-stream") ("x" "x") ("BUTTON_X1MASK" "button-x1-mask"))
        do (is (string= skein (skein.bindgen::kebab c)) "~A → ~A, expected ~A"
               c (skein.bindgen::kebab c) skein))
  (is (string= "create-window" (skein.bindgen:c-name-to-skein "SDL_CreateWindow" "SDL_")))
  (is (string= "sdl-frect" (skein.bindgen:c-name-to-skein "SDL_FRect" "SDL_" :keep-prefix t))))

(test json-reader
  (let ((objects (skein.bindgen:parse-json
                  "Dumping x: {\"a\": [1, -2, 3.5e1, true, false, null, \"q\\\"\\u00e9\"],
                               \"loc\": {\"file\": \"x.h\", \"includedFrom\": {\"file\": \"y.c\"}},
                               \"b\": {}} trailing {\"c\": []}")))
    (is (= 2 (length objects)))
    (is (equal '(1 -2 "3.5e1" t :false :null "q\"é")
               (skein.bindgen::jget (first objects) "a")))
    ;; The file of a location is its own, not the includer's.
    (is (equal "x.h" (skein.bindgen::jget (first objects) "_file")))
    (is (equal '(("c")) (second objects))))
  (signals skein.bindgen:bindgen-error (skein.bindgen:parse-json "{\"a\" 1}")))

(test constant-macros
  (let ((skein.bindgen::*macros* (make-hash-table :test 'equal))
        (skein.bindgen::*enumerators* (make-hash-table :test 'equal))
        (skein.bindgen::*typedefs* (make-hash-table :test 'equal))
        (skein.bindgen::*records* (make-hash-table :test 'equal))
        (skein.bindgen::*enums* (make-hash-table :test 'equal)))
    (skein.bindgen::parse-defines
     "# 1 \"m.h\"
#define A 0x10u
#define B (A | 1)
#define C(x) ((x) << 2)
#define D C(B)
#define E -1
#define F ~0u
#define G \"a\" \"b\"
#define H 2.5e3
#define I ((Uint32)-1)
#define J UINT64(0xFF)
#define UINT64(c) c##ULL
#define K SOME_FUNCTION(1)
#define L
#define M (3 / 0)
#define N 'x'
#define O RED
")
    (setf (gethash "RED" skein.bindgen::*enumerators*) 7
          (gethash "Uint32" skein.bindgen::*typedefs*)
          '(("kind" . "TypedefDecl") ("type" ("qualType" . "unsigned int"))))
    (flet ((value (name)
             (let ((v (skein.bindgen::macro-value
                       (gethash name skein.bindgen::*macros*))))
               (and v (skein.bindgen::value-source v nil)))))
      (loop for (name expected) in '(("A" "16") ("B" "17") ("D" "68") ("E" "-1")
                                     ("F" "4294967295") ("G" "\"ab\"") ("H" "2.5e3")
                                     ("I" "4294967295") ("J" "255") ("K" nil) ("L" nil) ("M" nil)
                                     ("N" "120") ("O" "7"))
            do (is (equal expected (value name)) "~A gave ~S, expected ~S"
                   name (value name) expected)))))

(test golden-demo-bindings
  (if (not (clang-available-p))
      (skip "clang is not installed")
      (let ((expected (uiop:read-file-string (fixture "demo.skn")))
            (got (demo-bindings)))
        (is (string= expected got)
            "bindgen output differs from tests/fixtures/bindgen/demo.skn:~%~A" got))))

(test generated-bindings-load
  (if (not (clang-available-p))
      (skip "clang is not installed")
      (let ((source (demo-bindings :library nil)))
        (skein.backend.cl:load-string source :file "demo.skn" :namespace "user")
        ;; The sizes C gives for these structs on 64-bit targets.
        (is (string= "[8 16 40 64 12 8]"
                     (pr (ev "(ns t.demo-sizes (:require [skein.ffi :as ffi]
                                                         [demo.raw :as d]))
                              [(ffi/sizeof d/demo-fpoint) (ffi/sizeof d/demo-rect)
                               (ffi/sizeof d/demo-key-event) (ffi/sizeof d/demo-event)
                               (ffi/sizeof d/demo-binding) (ffi/sizeof d/demo-binding-input)]"
                             :namespace "user"))))
        (is (string= "[3 \"demo\" 6 true]"
                     (pr (ev "(ns t.demo-values (:require [demo.raw :as d]))
                              [d/version d/name d/color-blue (fn? d/create-window)]"
                             :namespace "user")))))))

(test bindgen-command
  (multiple-value-bind (code out err) (run-cli "bindgen")
    (declare (ignore out))
    (is (= skein.cli:+exit-usage+ code))
    (is (search "expected headers" err)))
  (multiple-value-bind (code out err) (run-cli "bindgen" "x.h" "--prefix")
    (declare (ignore out))
    (is (= skein.cli:+exit-usage+ code))
    (is (search "--prefix needs a value" err)))
  (multiple-value-bind (code out err) (run-cli "bindgen" "x.h" "--prefix" "X_" "--ns" "x"
                                               "--lib" "beos=x.so")
    (declare (ignore out))
    (is (= skein.cli:+exit-usage+ code))
    (is (search "OS is macos, linux or windows" err)))
  (multiple-value-bind (code out err) (run-cli "bindgen" "no-such-header.h"
                                               "--prefix" "X_" "--ns" "x")
    (declare (ignore out))
    (is (= skein.cli:+exit-failure+ code))
    (is (search "header not found: no-such-header.h" err)))
  (if (not (clang-available-p))
      (skip "clang is not installed")
      (multiple-value-bind (code out) (run-cli "bindgen" (fixture "demo.h") "--prefix" "DEMO_"
                                               "--ns" "demo.raw" "--library" "demo"
                                               "--lib" "macos=libdemo.dylib"
                                               "--lib" "linux=libdemo.so"
                                               "--lib" "windows=demo.dll"
                                               "--blocking" "DEMO_PollEvent")
        (is (= skein.cli:+exit-ok+ code))
        (is (string= (uiop:read-file-string (fixture "demo.skn")) out)))))
