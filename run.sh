#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

BR_DIR="${BR_DIR:-buildroot}"

if [ ! -f "$BR_DIR/Makefile" ]; then
  echo "No Buildroot tree at ./$BR_DIR -- clone one first:" >&2
  echo "  git clone https://gitlab.com/buildroot.org/buildroot.git $BR_DIR" >&2
  exit 1
fi

mkdir -p output dl

if [ ! -f output/Makefile ]; then
  docker run --rm \
    -v "$PWD:/work" -w "/work/$BR_DIR" \
    br-build make O=/work/output outputmakefile
fi

docker run -it --rm \
  -v "$PWD:/work" \
  -w /work/output \
  -e BR2_DL_DIR=/work/dl \
  br-build "$@"
