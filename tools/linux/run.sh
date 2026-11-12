#!/usr/bin/env bash
# Run a command in Linux, in Docker (on macOS, Colima's: colima start --memory 10), on a
# copy of this checkout: make test unless a command is given.
#
#   tools/linux/run.sh                       make test
#   tools/linux/run.sh make test-host        any command, in the copy's root
#   tools/linux/run.sh --build ...           build the image again first
#
# The image is skein-linux (tools/linux/Dockerfile), built when missing. The copy lives
# in the Docker volume skein-linux-work, without build/, the caches and .claude/, so the
# Mac's build files stay apart and Linux's build cache is kept between runs; each run's
# container is removed when it ends. Colima shares only the home directory, so the
# checkout must be in it. To free the space: docker volume rm skein-linux-work and
# docker rmi skein-linux.
set -euo pipefail
cd "$(dirname "$0")/../.."
image=skein-linux
if [ "${1:-}" = --build ]; then
  shift
  docker build -t "$image" tools/linux
  docker image prune -f > /dev/null    # the image it replaced
elif ! docker image inspect "$image" > /dev/null 2>&1; then
  docker build -t "$image" tools/linux
fi
command="${*:-make test}"
exec docker run --rm -v "$PWD:/src:ro" -v skein-linux-work:/work "$image" bash -c \
  "rsync -a --delete --exclude build/ --exclude .skein-cache/ --exclude .claude/ \
     --exclude .zig-cache/ --exclude zig-out/ /src/ /work/ && cd /work && $command"
