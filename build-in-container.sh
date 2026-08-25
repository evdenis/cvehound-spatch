#!/bin/bash
# Host-side wrapper: run build.sh inside the manylinux image.
#
#   ./build-in-container.sh [VAR=value ...]      # knobs are forwarded to build.sh
#
# The opam root (compiler build, ~10-15 min cold) is cached under
# ~/.cache/cvehound-spatch-build/ across runs. Uses podman if present,
# otherwise docker.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ARCH=$(uname -m)
IMAGE=${IMAGE:-quay.io/pypa/manylinux_2_28_$ARCH}
CACHE=${CACHE:-$HOME/.cache/cvehound-spatch-build}
ENGINE=${ENGINE:-$(command -v podman || command -v docker)}

mkdir -p "$CACHE"

ENVARGS=()
for kv in "$@"; do
    ENVARGS+=(-e "$kv")
done

exec "$ENGINE" run --rm \
    -v "$HERE:/io" -v "$CACHE:/opam" \
    ${ENVARGS[@]+"${ENVARGS[@]}"} \
    "$IMAGE" /bin/bash /io/build.sh
