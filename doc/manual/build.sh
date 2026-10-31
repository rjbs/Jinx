#!/bin/sh
# Builds or serves the Jinx manual with mkdocs-material, run in Docker so
# that nothing need be installed locally beyond Docker itself.
#
#   doc/manual/build.sh          # builds into doc/manual/site/
#   doc/manual/build.sh serve    # serves at http://localhost:8000 with reload
set -e
cd "$(dirname "$0")"

image=squidfunk/mkdocs-material:9

case "${1:-build}" in
  build)
    exec docker run --rm -v "$PWD":/docs "$image" build --strict
    ;;
  serve)
    exec docker run --rm -it -p 8000:8000 -v "$PWD":/docs "$image" serve --dev-addr 0.0.0.0:8000
    ;;
  *)
    echo "usage: $0 [build|serve]" >&2
    exit 1
    ;;
esac
