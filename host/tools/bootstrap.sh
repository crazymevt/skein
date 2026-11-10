#!/usr/bin/env bash
# Bootstrap the native compiler, skeinc (M1.9, D-063). Run from the repository root:
#   bash host/tools/bootstrap.sh compiler   build build/skeinc if a source changed
#   bash host/tools/bootstrap.sh test       also check that skeinc rebuilds itself to the
#                                           same C, and builds every example correctly
# The Makefile runs it with bash, so it behaves the same on Windows, where make would run
# recipes with cmd.exe.
set -euo pipefail

exe=""
if [ "${OS:-}" = "Windows_NT" ]; then exe=".exe"; fi
skeinc="build/skeinc$exe"

build_compiler() {
  mkdir -p build
  # Rebuild when skeinc is missing or any library or runtime source is newer.
  if [ -f "$skeinc" ] && [ -z "$(find lib runtime/src runtime/include -newer "$skeinc" \
                                    \( -name '*.skn' -o -name '*.zig' -o -name '*.c' \
                                       -o -name '*.h' \) -print -quit)" ]; then
    return
  fi
  # Phase 0 builds a first compiler, which builds skeinc. The first compiler's output
  # differs from skeinc's only in the numbers of gensyms baked into skein.core's macros
  # (D-062), so it isn't compared.
  ./skein build lib/skein/compiler/main.skn -o "build/skeinc-stage1$exe"
  "build/skeinc-stage1$exe" build lib/skein/compiler/main.skn -o "$skeinc"
}

test_compiler() {
  # skeinc rebuilds itself twice; the two builds' C must be identical.
  "$skeinc" build lib/skein/compiler/main.skn -o "build/skeinc-a$exe" --keep-c
  "build/skeinc-a$exe" build lib/skein/compiler/main.skn -o "build/skeinc-b$exe" --keep-c
  cmp build/skeinc-a.c build/skeinc-b.c
  echo "skeinc: rebuilding itself gives the same C"
  # Every example with an .expected file, built by skeinc, prints exactly that.
  mkdir -p build/examples
  for expected in examples/*.expected; do
    name=$(basename "$expected" .expected)
    "$skeinc" build "examples/$name.skn" -o "build/examples/$name$exe" > /dev/null
    "build/examples/$name$exe" > "build/examples/$name.out"
    if ! diff --strip-trailing-cr "$expected" "build/examples/$name.out" > /dev/null; then
      echo "skeinc: $name differs from $expected"
      exit 1
    fi
    echo "skeinc: $name ok"
  done
  # Cross builds (M1.11): hello for each P0 target, in the release profile, is an
  # executable of that target's format, and the one for this machine runs.
  local host=""
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) host=aarch64-macos ;;
    Linux-x86_64) host=x86_64-linux-gnu ;;
    MINGW*-x86_64 | MSYS*-x86_64) host=x86_64-windows-gnu ;;
  esac
  for target in aarch64-macos x86_64-windows-gnu x86_64-linux-gnu; do
    out="build/examples/hello-$target"
    case "$target" in *windows*) out="$out.exe" ;; esac
    "$skeinc" build examples/hello.skn --target "$target" --profile release -o "$out" > /dev/null
    magic=$(od -An -tx1 -N4 "$out" | tr -d ' \r\n')
    case "$target:$magic" in
      *macos:cffaedfe | *windows-gnu:4d5a* | *linux-gnu:7f454c46) ;;
      *) echo "skeinc: hello for $target isn't a $target executable ($magic)"; exit 1 ;;
    esac
    if [ "$target" = "$host" ] && ! "$out" | diff --strip-trailing-cr examples/hello.expected - \
         > /dev/null; then
      echo "skeinc: hello for $target differs from examples/hello.expected"
      exit 1
    fi
    echo "skeinc: hello for $target ok"
  done
  # Programs that only skeinc compiles (the FFI, D-064), built by skeinc, print what
  # `skein run` prints, and every line a ";; stderr: " comment gives on standard error.
  for program in host/tests/fixtures/native-ffi*.skn; do
    name=$(basename "$program" .skn)
    ./skein run "$program" > "build/examples/$name.expected"
    "$skeinc" build "$program" -o "build/examples/$name$exe" > /dev/null
    "build/examples/$name$exe" > "build/examples/$name.out" 2> "build/examples/$name.err"
    while IFS= read -r line; do
      if ! grep -qF -- "$line" "build/examples/$name.err"; then
        echo "skeinc: $name didn't print to stderr: $line"
        exit 1
      fi
    done < <(sed -n 's/^;; stderr: //p' "$program" | tr -d '\r')
    if ! diff --strip-trailing-cr "build/examples/$name.expected" "build/examples/$name.out" \
         > /dev/null; then
      echo "skeinc: $name differs from skein run"
      diff --strip-trailing-cr "build/examples/$name.expected" "build/examples/$name.out" \
        | head -20
      exit 1
    fi
    echo "skeinc: $name ok"
  done
}

case "${1:-}" in
  compiler) build_compiler ;;
  test) build_compiler; test_compiler ;;
  *) echo "usage: bash host/tools/bootstrap.sh compiler|test" >&2; exit 2 ;;
esac
