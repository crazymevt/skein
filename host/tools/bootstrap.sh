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
  # ./skein bootstrap rebuilds skeinc when it's missing or any library or runtime source
  # is newer: Phase 0 builds a first compiler, which builds skeinc. The first compiler's
  # output differs from skeinc's only in the numbers of gensyms baked into skein.core's
  # macros (D-062), so it isn't compared.
  ./skein bootstrap
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
  # A project (M1.11): with no file, skeinc builds the project.skn in the current directory,
  # into it, beside the assets that skein.io/resource-dir finds (D-073). It runs from
  # another directory.
  (cd examples/hello-app && "$OLDPWD/$skeinc" build > /dev/null)
  greeted=$(cd build && ../examples/hello-app/hello$exe Ada Grace | tr -d '\r')
  rm -f "examples/hello-app/hello$exe" examples/hello-app/hello.pdb
  if [ "$greeted" != $'hello, Ada\nhello, Grace' ]; then
    echo "skeinc: the hello-app project doesn't greet its arguments"
    exit 1
  fi
  echo "skeinc: hello-app ok"
  # Packages (M1.11): the package-app fixture, with the C library it bundles built for
  # each P0 target, packaged for each. The one for this machine runs from another
  # directory, so it finds the library only beside itself.
  local app=host/tests/fixtures/package-app
  mkdir -p "$app/native/out"
  for target in aarch64-macos x86_64-windows-gnu x86_64-linux-gnu; do
    case "$target" in
      *macos) lib=libpkgdemo.dylib; dir="dist/$target/package-app.app/Contents/"
              files="MacOS/package-app Frameworks/libpkgdemo.dylib Info.plist"
              files="$files Resources/assets/data/note.txt"
              run="${dir}MacOS/package-app" ;;
      *windows-gnu) lib=pkgdemo.dll; dir="dist/$target/package-app/"
                    files="package-app.exe pkgdemo.dll assets/data/note.txt"
                    run="${dir}package-app.exe" ;;
      *) lib=libpkgdemo.so; dir="dist/$target/package-app/"
         files="package-app libpkgdemo.so assets/data/note.txt"
         run="${dir}package-app" ;;
    esac
    "${SKEIN_ZIG:-zig}" cc -target "$target" -shared -o "$app/native/out/$lib" \
      "$app/native/pkgdemo.c"
    (cd "$app" && "$OLDPWD/$skeinc" package --target "$target" > /dev/null)
    for f in $files; do
      if [ ! -f "$app/$dir$f" ]; then
        echo "skeinc: the package for $target has no $f"
        exit 1
      fi
    done
    if [ "$target" = "$host" ]; then
      answer=$(cd build && "../$app/$run" | tr -d '\r')
      if [ "$answer" != $'answer: 42\nAn asset that skein package copies.' ]; then
        echo "skeinc: the package for $target didn't find its library: $answer"
        exit 1
      fi
    fi
    echo "skeinc: package for $target ok"
  done
  # Every native fixture, built by skeinc, prints what
  # `skein run` prints, and every line a ";; stderr: " comment gives on standard error.
  for program in host/tests/fixtures/native-*.skn; do
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
  # Every example and fixture again with SKEIN_GC_VERIFY=1 (D-073): each collection is
  # major and is followed by a check that nothing points at an object that's gone.
  for expected in examples/*.expected build/examples/native-*.expected; do
    name=$(basename "$expected" .expected)
    if ! SKEIN_GC_VERIFY=1 "build/examples/$name$exe" 2> "build/examples/$name.verify-err" \
         | diff --strip-trailing-cr "$expected" - > /dev/null; then
      echo "skeinc: $name fails with SKEIN_GC_VERIFY=1"
      head -5 "build/examples/$name.verify-err"
      exit 1
    fi
  done
  echo "skeinc: everything passes with SKEIN_GC_VERIFY=1"
}

case "${1:-}" in
  compiler) build_compiler ;;
  test) build_compiler; test_compiler ;;
  *) echo "usage: bash host/tools/bootstrap.sh compiler|test" >&2; exit 2 ;;
esac
