#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p output dl

docker run -it --rm \
  -v "$PWD/output:/buildroot/output" \
  -v "$PWD/dl:/buildroot/dl" \
  br-build "$@"
