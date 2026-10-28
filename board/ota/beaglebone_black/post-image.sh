#!/bin/sh
# Runs from the Buildroot tree (make -C buildroot), so support/ is reachable
# relatively. Builds the empty filesystem for the persistent data area, then assembles
# the SD card image.
set -eu

BOARD_DIR="$(dirname "$0")"
BOARD="$(basename "${BASE_DIR}")"
DATA_SIZE=256M

# Buildroot hands genimage an empty rootpath, so genimage cannot build this
# filesystem from the target tree: it is made here instead. The file stays sparse,
# which is why sdcard.img is far smaller than the layout it declares.
rm -f "${BINARIES_DIR}/data.ext4"
truncate -s "${DATA_SIZE}" "${BINARIES_DIR}/data.ext4"
"${HOST_DIR}/sbin/mke2fs" -q -t ext4 -L data -F "${BINARIES_DIR}/data.ext4"

# The update bundle (FR-022): the rootfs the slot will hold, a manifest naming the board it
# is for and the version it carries, and a CMS signature over both. The version is read back
# from the image's own /etc/build-info rather than recomputed, so the bundle and the system
# it installs can never report different versions (FR-024). Not verified here: `rauc info`
# loop-mounts a plain bundle, which the unprivileged build container cannot do, so the first
# check against the keyring is the device's own (T029).
VERSION="$(sed -n 's/^VERSION=//p' "${TARGET_DIR}/etc/build-info")"
if [ -z "${VERSION}" ]; then
	echo "post-image: no VERSION in ${TARGET_DIR}/etc/build-info" >&2
	exit 1
fi
BUNDLE="${BINARIES_DIR}/${BOARD}-${VERSION}.raucb"
STAGING="${BASE_DIR}/bundle-staging"
rm -rf "${STAGING}" "${BUNDLE}"
mkdir -p "${STAGING}"
# rootfs.ext4 is a symlink to rootfs.ext2; link or copy the file it points at.
ln -L "${BINARIES_DIR}/rootfs.ext4" "${STAGING}/rootfs.ext4" 2>/dev/null \
	|| cp -L "${BINARIES_DIR}/rootfs.ext4" "${STAGING}/rootfs.ext4"
cat > "${STAGING}/manifest.raucm" <<EOF2
[update]
compatible=ota-beaglebone-black
version=${VERSION}

[bundle]
format=plain

[image.rootfs]
filename=rootfs.ext4
EOF2
"${HOST_DIR}/bin/rauc" bundle \
	--cert "${OTA_SIGNING_CERT}" --key "${OTA_SIGNING_KEY}" \
	"${STAGING}" "${BUNDLE}"
rm -rf "${STAGING}"

exec support/scripts/genimage.sh -c "${BOARD_DIR}/genimage.cfg"
