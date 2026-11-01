#!/bin/sh
# Runs from the Buildroot tree (make -C buildroot), so support/ is reachable
# relatively. Stages the boot configuration next to the kernel, then assembles the
# SD card image.
set -eu

BOARD_DIR="$(dirname "$0")"

# U-Boot's am335x_evm environment boots from extlinux.conf; uEnv.txt is the older
# path some U-Boot builds still try first. Both carry the same console and root.
install -m 0644 "${BOARD_DIR}/uEnv.txt" "${BINARIES_DIR}/uEnv.txt"
install -m 0644 -D "${BOARD_DIR}/extlinux.conf" "${BINARIES_DIR}/extlinux/extlinux.conf"

exec support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
