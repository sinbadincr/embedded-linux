#!/bin/sh
# Shared post-build step for every board: stamp the rootfs with what was built, and
# for a board that does A/B updates, give it the trust anchor and the mount point its
# persistent data area needs. Board-independent on purpose (FR-029): a second board
# adopts A/B by adding board-local files, not by changing this.
set -eu

BOARD="$(basename "${BASE_DIR}")"
VERSION="$(git -C "${BR2_EXTERNAL_OTA_PATH}" describe --always --dirty 2>/dev/null || echo unknown)"

cat > "${TARGET_DIR}/etc/build-info" <<EOF2
BOARD=${BOARD}
VERSION=${VERSION}
BUILDROOT=${BR2_VERSION_FULL}
EOF2

# The presence of rauc in the target is what makes a board A/B-capable; testing for
# it needs no knowledge of which option switched it on.
if [ -x "${TARGET_DIR}/usr/bin/rauc" ]; then
	if [ ! -f "${OTA_KEYRING:-}" ]; then
		echo "post-build: no keyring at '${OTA_KEYRING:-<unset>}'." >&2
		echo "post-build: generate the development material first: make ota-dev-keys" >&2
		exit 1
	fi
	install -m 0644 -D "${OTA_KEYRING}" "${TARGET_DIR}/etc/rauc/keyring.pem"

	# Mount point for the persistent data area. Created here rather than carried in
	# an overlay so no placeholder file ends up in the image.
	mkdir -p "${TARGET_DIR}/data"
fi
