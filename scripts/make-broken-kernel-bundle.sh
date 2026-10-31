#!/bin/sh
# Builds the bundle that quickstart scenario 5 installs: genuine and signed by the project's
# material, but with the slot's kernel (/boot/zImage) replaced by garbage, so the slot installs
# cleanly and then cannot boot. Run in the build container after a build of the board and after
# `make ota-dev-keys`.
#
#   sh scripts/make-broken-kernel-bundle.sh [board]     # default: the selected board
#
# Output goes to output/<board>/broken/, which is ignored by git. The manifest version is the
# image's revision with "-brokenkernel" appended, so `ota-status` names the bundle for what it is;
# the /etc/build-info inside is unchanged.
set -eu

BOARD="${1:-}"
[ -n "${BOARD}" ] || BOARD="$(sed -n 's/^BOARD=//p' .current_board 2> /dev/null || true)"
if [ -z "${BOARD}" ]; then
	echo "usage: sh scripts/make-broken-kernel-bundle.sh <board>   (no board selected)" >&2
	exit 1
fi

BASE="output/${BOARD}"
IMAGES="${BASE}/images"
TARGET="${BASE}/target"
OUT="${BASE}/broken"
KEYS_DIR="${KEYS_DIR:-keys/dev}"
CERT="${OTA_SIGNING_CERT:-${KEYS_DIR}/dev-signing.cert.pem}"
KEY="${OTA_SIGNING_KEY:-${KEYS_DIR}/dev-signing.key.pem}"
SYSCONF="board/ota/${BOARD}/rootfs_overlay/etc/rauc/system.conf"

for f in "${IMAGES}/rootfs.ext4" "${TARGET}/etc/build-info" "${BASE}/host/bin/rauc" "${SYSCONF}" "${CERT}" "${KEY}"; do
	if [ ! -e "${f}" ]; then
		echo "missing ${f}: build the board first (make ${BOARD}_defconfig && make build) and run make ota-dev-keys." >&2
		exit 1
	fi
done
command -v debugfs > /dev/null 2>&1 || {
	echo "debugfs not found (e2fsprogs)" >&2
	exit 1
}

PATH="$(pwd)/${BASE}/host/bin:${PATH}"
VERSION="$(sed -n 's/^VERSION=//p' "${TARGET}/etc/build-info")"
COMPAT="$(sed -n 's/^compatible=//p' "${SYSCONF}")"
BUNDLE="${OUT}/${BOARD}-${VERSION}-brokenkernel.raucb"

rm -rf "${OUT}"
mkdir -p "${OUT}/stage"
cp -L "${IMAGES}/rootfs.ext4" "${OUT}/stage/rootfs.ext4"

# Replace the kernel with the same number of bytes of text, which is neither a zImage (U-Boot's
# bootz refuses it: bad magic) nor a file that is missing (ext4load would fail first).
size="$(debugfs -R 'stat /boot/zImage' "${OUT}/stage/rootfs.ext4" 2> /dev/null | sed -n 's/.*Size: \([0-9][0-9]*\).*/\1/p' | head -1)"
if [ -z "${size}" ] || [ "${size}" -le 0 ]; then
	echo "/boot/zImage is not in ${IMAGES}/rootfs.ext4" >&2
	exit 1
fi
yes 'NOT A KERNEL - scripts/make-broken-kernel-bundle.sh' | head -c "${size}" > "${OUT}/garbage.bin"
debugfs -w -R 'rm /boot/zImage' "${OUT}/stage/rootfs.ext4" > /dev/null 2>&1
debugfs -w -R "write ${OUT}/garbage.bin /boot/zImage" "${OUT}/stage/rootfs.ext4" > /dev/null 2>&1

# Check what was done, rather than assuming it: same size, the garbage on top, a clean filesystem.
debugfs -R "dump /boot/zImage ${OUT}/zImage.check" "${OUT}/stage/rootfs.ext4" > /dev/null 2>&1
if ! cmp -s "${OUT}/garbage.bin" "${OUT}/zImage.check"; then
	echo "the kernel in the slot image does not read back as the garbage that was written" >&2
	exit 1
fi
if ! e2fsck -fn "${OUT}/stage/rootfs.ext4" > "${OUT}/e2fsck.log" 2>&1; then
	cat "${OUT}/e2fsck.log" >&2
	echo "e2fsck reports the modified slot image as damaged" >&2
	exit 1
fi

printf '[update]\ncompatible=%s\nversion=%s-brokenkernel\n\n[bundle]\nformat=plain\n\n[image.rootfs]\nfilename=rootfs.ext4\n' \
	"${COMPAT}" "${VERSION}" > "${OUT}/stage/manifest.raucm"
if ! rauc bundle --cert "${CERT}" --key "${KEY}" "${OUT}/stage" "${BUNDLE}" > "${OUT}/rauc.log" 2>&1; then
	cat "${OUT}/rauc.log" >&2
	echo "rauc bundle failed" >&2
	exit 1
fi
rm -rf "${OUT}/stage" "${OUT}/garbage.bin" "${OUT}/zImage.check" "${OUT}/e2fsck.log"

printf '%s\n  %s bytes, sha256 %s\n  kernel replaced by %s bytes of text, filesystem checked clean\n' \
	"${BUNDLE}" "$(wc -c < "${BUNDLE}")" "$(sha256sum "${BUNDLE}" | cut -d' ' -f1)" "${size}"
