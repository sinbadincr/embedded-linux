#!/bin/sh
# Runs from the Buildroot tree (make -C buildroot), so support/ is reachable relatively.
set -eu

BOARD_DIR="$(dirname "$0")"

cp "${BOARD_DIR}/uEnv.txt" "${BINARIES_DIR}/uEnv.txt"
install -m 0644 -D "${BOARD_DIR}/extlinux.conf" "${BINARIES_DIR}/extlinux/extlinux.conf"

exec support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
