#!/usr/bin/env bash
# make test: every test, in parts that run side by side. It prepares once (compiles the
# host's Lisp, bootstraps skeinc and builds the runtime libraries the tests link, so the
# parts don't do it at the same time), then runs the runtime's tests, the native
# compiler's (bootstrap.sh test) and four groups of host suites in parallel, each into
# build/test-logs/<part>.log. It prints each part's time and the log of each that failed,
# and exits with 1 if one did.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

sbcl=(${SBCL:-sbcl} --noinform --no-userinit --non-interactive)
zig=${ZIG:-zig}
logs=build/test-logs
rm -rf "$logs"
mkdir -p "$logs"
start=$(date +%s)

elapsed() { echo $(( $(date +%s) - $1 )); }

echo "test: preparing (compiling the host, bootstrapping skeinc, building the runtime)"
if ! { "${sbcl[@]}" --load host/tools/bootstrap.lisp --eval '(skein-quickload "skein/tests")' \
         && bash host/tools/bootstrap.sh prepare; } > "$logs/prepare.log" 2>&1; then
  cat "$logs/prepare.log"
  echo "test: preparing failed"
  exit 1
fi
echo "test: prepared in $(elapsed "$start") s"

# The host suites in groups of about a minute or two each; the rest is fast.
slow_host="skein.swank skein.repl skein.concurrency skein.backend.c"
parts=(runtime compiler host-swank host-repl host-c host-rest)
run_part() {
  local name=$1
  shift
  (
    local s
    s=$(date +%s)
    "$@" > "$logs/$name.log" 2>&1
    echo "$? $(elapsed "$s")" > "$logs/$name.status"
  ) &
}
host_tests() { "${sbcl[@]}" --load host/tools/run-tests.lisp --end-toplevel-options "$@"; }

run_part runtime bash -c "cd runtime && '$zig' build test --summary all"
run_part compiler bash host/tools/bootstrap.sh test
run_part host-swank host_tests only skein.swank
run_part host-repl host_tests only skein.repl skein.concurrency
run_part host-c host_tests only skein.backend.c
# shellcheck disable=SC2086 # the suite names are words
run_part host-rest host_tests except $slow_host
wait

failed=0
for part in "${parts[@]}"; do
  read -r status seconds < "$logs/$part.status"
  if [ "$status" = 0 ]; then
    printf 'test: %-10s ok      %4d s\n' "$part" "$seconds"
  else
    failed=1
    printf 'test: %-10s FAILED  %4d s (exit %s)\n' "$part" "$seconds" "$status"
  fi
done
for part in "${parts[@]}"; do
  read -r status _ < "$logs/$part.status"
  if [ "$status" != 0 ]; then
    echo
    echo "==== $part ($logs/$part.log) ===="
    cat "$logs/$part.log"
  fi
done
echo "test: $( [ "$failed" = 0 ] && echo "passed" || echo "FAILED" ) in $(elapsed "$start") s"
exit "$failed"
