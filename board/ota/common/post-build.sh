#!/bin/sh
# Shared post-build step for every board: stamp the rootfs with what was built.
set -eu

BOARD="$(basename "${BASE_DIR}")"
VERSION="$(git -C "${BR2_EXTERNAL_OTA_PATH}" describe --always --dirty 2>/dev/null || echo unknown)"

cat > "${TARGET_DIR}/etc/build-info" <<EOF
BOARD=${BOARD}
VERSION=${VERSION}
BUILDROOT=${BR2_VERSION_FULL}
EOF
