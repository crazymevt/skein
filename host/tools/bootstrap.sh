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
  # skein test (M2.11, D-093): a project's test/ passes, and failing/ fails with status 1.
  tested=$(cd host/tests/fixtures/test-project && "$OLDPWD/$skeinc" test | tr -d '\r')
  if [[ "$tested" != *"Ran 1 tests containing 2 assertions."*"0 failures, 0 errors."* ]]; then
    echo "skeinc: skein test printed: $tested"
    exit 1
  fi
  status=0
  tested=$(cd host/tests/fixtures/test-project && "$OLDPWD/$skeinc" test failing | tr -d '\r') \
    || status=$?
  if [ "$status" != 1 ] || [[ "$tested" != *"FAIL in (adds-wrongly)"* ]]; then
    echo "skeinc: skein test failing exited with $status and printed: $tested"
    exit 1
  fi
  echo "skeinc: skein test ok"
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
  # Every native fixture, built by skeinc (with the options of its ";; build: " comment, if
  # it has one), prints what `skein host run` (Phase 0) prints, and every line that a
  # ";; stderr: " comment gives on standard error.
  for program in host/tests/fixtures/native-*.skn; do
    name=$(basename "$program" .skn)
    ./skein host run "$program" > "build/examples/$name.expected"
    options=$(sed -n 's/^;; build: //p' "$program" | tr -d '\r')
    # shellcheck disable=SC2086 # the options are words
    "$skeinc" build "$program" $options -o "build/examples/$name$exe" > /dev/null
    "build/examples/$name$exe" > "build/examples/$name.out" 2> "build/examples/$name.err"
    while IFS= read -r line; do
      if ! grep -qF -- "$line" "build/examples/$name.err"; then
        echo "skeinc: $name didn't print to stderr: $line"
        exit 1
      fi
    done < <(sed -n 's/^;; stderr: //p' "$program" | tr -d '\r')
    if ! diff --strip-trailing-cr "build/examples/$name.expected" "build/examples/$name.out" \
         > /dev/null; then
      echo "skeinc: $name differs from skein host run"
      diff --strip-trailing-cr "build/examples/$name.expected" "build/examples/$name.out" \
        | head -20
      exit 1
    fi
    echo "skeinc: $name ok"
  done
  # Native-only fixtures: supervision policies (M2.8, D-088; Phase 0 has only
  # :cancel-siblings), STM (M2.10, D-092; Phase 0 has none) and the standard library's
  # additions (M2.11, D-093). Each prints its .expected
  # on standard output, every ";; stderr: " line on standard error, and exits with its
  # ";; status: " (0 if none).
  for program in host/tests/fixtures/supervise/*.skn host/tests/fixtures/stm/*.skn \
                 host/tests/fixtures/library/*.skn; do
    name=$(basename "$(dirname "$program")")-$(basename "$program" .skn)
    "$skeinc" build "$program" -o "build/examples/$name$exe" > /dev/null
    status=0
    "build/examples/$name$exe" > "build/examples/$name.out" 2> "build/examples/$name.err" \
      || status=$?
    expected_status=$(sed -n 's/^;; status: //p' "$program" | tr -d '\r')
    if [ "$status" != "${expected_status:-0}" ]; then
      echo "skeinc: $name exited with $status, not ${expected_status:-0}"
      cat "build/examples/$name.err"
      exit 1
    fi
    while IFS= read -r line; do
      if ! grep -qF -- "$line" "build/examples/$name.err"; then
        echo "skeinc: $name didn't print to stderr: $line"
        exit 1
      fi
    done < <(sed -n 's/^;; stderr: //p' "$program" | tr -d '\r')
    if ! diff --strip-trailing-cr "${program%.skn}.expected" "build/examples/$name.out" \
         > /dev/null; then
      echo "skeinc: $name differs from its .expected"
      diff --strip-trailing-cr "${program%.skn}.expected" "build/examples/$name.out" | head -20
      exit 1
    fi
    echo "skeinc: $name ok"
  done
  # A million channel messages between 10,000 fibers (M2.3; native only).
  "$skeinc" build host/tests/fixtures/ring-fibers.skn --profile release \
    -o "build/examples/ring-fibers$exe" > /dev/null
  ring=$(build/examples/ring-fibers$exe | tr -d '\r')
  if [ "$ring" != "1000000 messages passed between 10000 fibers" ]; then
    echo "skeinc: ring-fibers printed: $ring"
    exit 1
  fi
  echo "skeinc: ring-fibers ok"
  # The dev fixtures (M2.6, D-081) test what only native --eval builds have, such as
  # backtraces, the debugger and the REPL: each, given its .input file (if it has one) on
  # standard input, prints what its .expected file says.
  for program in host/tests/fixtures/dev/*.skn; do
    name=dev-$(basename "$program" .skn)
    input="${program%.skn}.input"
    [ -f "$input" ] || input=/dev/null
    "$skeinc" build "$program" --eval -o "build/examples/$name$exe" > /dev/null
    "build/examples/$name$exe" < "$input" > "build/examples/$name.out" 2>&1
    if ! diff --strip-trailing-cr "${program%.skn}.expected" "build/examples/$name.out" \
         > /dev/null; then
      echo "skeinc: $name differs from its .expected"
      diff --strip-trailing-cr "${program%.skn}.expected" "build/examples/$name.out" | head -20
      exit 1
    fi
    echo "skeinc: $name ok"
  done
  # Without --eval, eval and its relatives are errors (D-078).
  "$skeinc" build host/tests/fixtures/native-eval.skn -o "build/examples/no-eval$exe" > /dev/null
  if "build/examples/no-eval$exe" > /dev/null 2> build/examples/no-eval.err \
     || ! grep -qF "macroexpand-1 needs a native build made with --eval" \
          build/examples/no-eval.err; then
    echo "skeinc: a build without --eval didn't refuse macroexpand-1"
    cat build/examples/no-eval.err
    exit 1
  fi
  echo "skeinc: no eval without --eval"
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
  # STM keeps heap values in transactions and refs (D-092).
  for program in host/tests/fixtures/stm/*.skn; do
    name=stm-$(basename "$program" .skn)
    if ! SKEIN_GC_VERIFY=1 "build/examples/$name$exe" 2> "build/examples/$name.verify-err" \
         | diff --strip-trailing-cr "${program%.skn}.expected" - > /dev/null; then
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
