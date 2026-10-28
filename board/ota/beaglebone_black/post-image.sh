#!/bin/sh
# Runs from the Buildroot tree (make -C buildroot), so support/ is reachable
# relatively. Builds the empty filesystem for the persistent data area, then assembles
# the SD card image.
set -eu

BOARD_DIR="$(dirname "$0")"
DATA_SIZE=256M

# Buildroot hands genimage an empty rootpath, so genimage cannot build this
# filesystem from the target tree: it is made here instead. The file stays sparse,
# which is why sdcard.img is far smaller than the layout it declares.
rm -f "${BINARIES_DIR}/data.ext4"
truncate -s "${DATA_SIZE}" "${BINARIES_DIR}/data.ext4"
"${HOST_DIR}/sbin/mke2fs" -q -t ext4 -L data -F "${BINARIES_DIR}/data.ext4"

exec support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
