#!/bin/sh

set -e

VERSION="1.8.0"

MAJMIN="$(echo "${VERSION}" | cut -d'.' -f 1).$(echo "${VERSION}" | cut -d'.' -f 2)"
URL="https://julialang-s3.julialang.org/bin/freebsd/x64/${MAJMIN}/julia-${VERSION}-freebsd-x86_64.tar.gz"

curl -s -L --retry 7 "${URL}" | tar -C "${HOME}/julia" -x -z --strip-components=1 -f -
ln -fs "${HOME}/julia/bin/julia" /usr/local/bin/julia
