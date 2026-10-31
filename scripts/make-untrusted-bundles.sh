#!/bin/sh
# Builds the bundles that quickstart scenario 7 installs, each of which a device must refuse,
# plus one good bundle as the control. Run in the build container after a build of the board
# (it needs the board's rootfs.ext4 and host tools) and after `make ota-dev-keys`.
#
#   sh scripts/make-untrusted-bundles.sh [board]        # default: the selected board
#
# Output goes to output/<board>/untrusted/, which is ignored by git. The signing material for
# the "second CA" case is generated there too and never leaves it.
set -eu

BOARD="${1:-}"
[ -n "${BOARD}" ] || BOARD="$(sed -n 's/^BOARD=//p' .current_board 2>/dev/null || true)"
if [ -z "${BOARD}" ]; then
	echo "usage: sh scripts/make-untrusted-bundles.sh <board>   (no board selected)" >&2
	exit 1
fi

BASE="output/${BOARD}"
IMAGES="${BASE}/images"
TARGET="${BASE}/target"
OUT="${BASE}/untrusted"
KEYS_DIR="${KEYS_DIR:-keys/dev}"
CERT="${OTA_SIGNING_CERT:-${KEYS_DIR}/dev-signing.cert.pem}"
KEY="${OTA_SIGNING_KEY:-${KEYS_DIR}/dev-signing.key.pem}"
CA_CERT="${OTA_KEYRING:-${KEYS_DIR}/dev-ca.cert.pem}"
CA_KEY="${KEYS_DIR}/dev-ca.key.pem"
SYSCONF="board/ota/${BOARD}/rootfs_overlay/etc/rauc/system.conf"

for f in "${IMAGES}/rootfs.ext4" "${TARGET}/etc/build-info" "${BASE}/host/bin/rauc" "${SYSCONF}"; do
	if [ ! -e "${f}" ]; then
		echo "missing ${f}: build the board first (make ${BOARD}_defconfig && make build)." >&2
		exit 1
	fi
done
for f in "${CERT}" "${KEY}" "${CA_CERT}" "${CA_KEY}"; do
	if [ ! -e "${f}" ]; then
		echo "missing ${f}: generate the development material first (make ota-dev-keys)." >&2
		exit 1
	fi
done

PATH="$(pwd)/${BASE}/host/bin:${PATH}"
VERSION="$(sed -n 's/^VERSION=//p' "${TARGET}/etc/build-info")"
COMPAT="$(sed -n 's/^compatible=//p' "${SYSCONF}")"
PREFIX="${BOARD}-${VERSION}"

rm -rf "${OUT}"
mkdir -p "${OUT}"
# The helper that runs on the board, served from the same directory as the bundles.
cp scripts/try-bundle-on-board.sh "${OUT}/try-bundle.sh"

# mkbundle NAME COMPATIBLE CERT KEY: the same `rauc bundle` call as post-image.sh, with the
# material and the board string given here.
mkbundle() {
	stage="${OUT}/stage-$1"
	mkdir -p "${stage}"
	cp -L "${IMAGES}/rootfs.ext4" "${stage}/rootfs.ext4"
	printf '[update]\ncompatible=%s\nversion=%s\n\n[bundle]\nformat=plain\n\n[image.rootfs]\nfilename=rootfs.ext4\n' \
		"$2" "${VERSION}" > "${stage}/manifest.raucm"
	if ! rauc bundle --cert "$3" --key "$4" "${stage}" "${OUT}/${PREFIX}-$1.raucb" > "${OUT}/rauc-$1.log" 2>&1; then
		cat "${OUT}/rauc-$1.log" >&2
		echo "rauc bundle failed for $1" >&2
		exit 1
	fi
	rm -rf "${stage}"
}

# Layout of a plain bundle: squashfs, then the CMS signature, then its length as 8 bytes big-endian.
cms_len() {
	od -An -tu1 -j"$(($(wc -c < "$1") - 8))" -N8 "$1" | awk '{ n = 0; for (i = 1; i <= 8; i++) n = n * 256 + $i; print n }'
}

# 0. The control: genuine, signed by the project's development material for this board.
mkbundle good "${COMPAT}" "${CERT}" "${KEY}"

# 1. Unsigned: the genuine bundle with its signature cut off and a zero-length trailer.
good="${OUT}/${PREFIX}-good.raucb"
size="$(wc -c < "${good}")"
head -c "$((size - 8 - $(cms_len "${good}")))" "${good}" > "${OUT}/${PREFIX}-unsigned.raucb"
printf '\000\000\000\000\000\000\000\000' >> "${OUT}/${PREFIX}-unsigned.raucb"

# 2. Signed by a second CA and signing pair that the device has never heard of.
if ! sh scripts/gen-dev-keys.sh "${OUT}/other-ca" > "${OUT}/other-ca.log" 2>&1; then
	cat "${OUT}/other-ca.log" >&2
	exit 1
fi
rm -f "${OUT}/other-ca.log"
mkbundle wrongca "${COMPAT}" "${OUT}/other-ca/dev-signing.cert.pem" "${OUT}/other-ca/dev-signing.key.pem"

# 3. Altered after signing: one byte of the payload inverted, the signature untouched.
cp "${good}" "${OUT}/${PREFIX}-altered.raucb"
off=1048576
orig="$(od -An -tu1 -j"${off}" -N1 "${OUT}/${PREFIX}-altered.raucb" | tr -d ' ')"
printf '%b' "\\0$(printf '%03o' $((orig ^ 255)))" |
	dd of="${OUT}/${PREFIX}-altered.raucb" bs=1 seek="${off}" conv=notrunc 2> /dev/null

# 4. Valid signature, built for a different board.
mkbundle wrongboard "ota-other-board" "${CERT}" "${KEY}"

# 5. Issued by the device's own CA, but without the Code Signing usage. `openssl x509 -req`
# would date it now, which is later than the build of the image on the board, and the device
# would refuse it as not yet valid instead of for its purpose; `openssl ca -startdate` dates it
# from the CA's own notBefore, so the only thing wrong with it is its purpose.
openssl req -newkey rsa:2048 -noenc -keyout "${OUT}/nousage.key.pem" -out "${OUT}/nousage.csr.pem" \
	-subj "/O=OTA development/CN=OTA test signer without code signing usage - NOT FOR PRODUCTION" 2> /dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' > "${OUT}/nousage.ext"
cat > "${OUT}/nousage.cnf" <<CNF
[ca]
default_ca = CA_default
[CA_default]
database = ${OUT}/nousage.index
new_certs_dir = ${OUT}
serial = ${OUT}/nousage.serial
default_md = sha256
policy = policy_any
unique_subject = no
[policy_any]
organizationName = optional
commonName = supplied
CNF
: > "${OUT}/nousage.index"
echo 01 > "${OUT}/nousage.serial"
start="$(date -u -d "$(openssl x509 -in "${CA_CERT}" -noout -startdate | sed 's/^notBefore=//')" +%Y%m%d%H%M%SZ)"
openssl ca -batch -config "${OUT}/nousage.cnf" -cert "${CA_CERT}" -keyfile "${CA_KEY}" \
	-in "${OUT}/nousage.csr.pem" -out "${OUT}/nousage.cert.pem" -notext \
	-startdate "${start}" -days 365 -extfile "${OUT}/nousage.ext" 2> /dev/null
mkbundle nousage "${COMPAT}" "${OUT}/nousage.cert.pem" "${OUT}/nousage.key.pem"

# What `openssl` makes of each bundle's signature against the device's CA. This is the host's
# view of the chain only; the device's verdict, and its wording, are what scenario 7 records.
check_cms() {
	f="$1"
	size="$(wc -c < "${f}")"
	n="$(cms_len "${f}")"
	if [ "${n}" -le 0 ] || [ "${n}" -ge "${size}" ]; then
		echo "no signature"
		return
	fi
	tail -c "$((n + 8))" "${f}" | head -c "${n}" > "${OUT}/cms.der"
	head -c "$((size - 8 - n))" "${f}" > "${OUT}/content.bin"
	if openssl cms -verify -binary -inform DER -in "${OUT}/cms.der" -content "${OUT}/content.bin" \
		-CAfile "${CA_CERT}" -purpose any -out /dev/null > "${OUT}/cms.log" 2>&1; then
		echo "signature and chain verify against the device's CA"
	else
		# The reason is either a "Verify error:" (the chain) or the CMS_verify routine's own
		# wording (the content), whichever comes first.
		sed -n 's/.*Verify error:\(.*\)/\1/p; s/.*CMS_verify:\([^:]*\):.*/\1/p' "${OUT}/cms.log" | head -1
	fi
}

echo
echo "Bundles in ${OUT} (board ${BOARD}, revision ${VERSION}, compatible=${COMPAT}):"
for name in good unsigned wrongca altered wrongboard nousage; do
	f="${OUT}/${PREFIX}-${name}.raucb"
	printf '\n%s\n  %s bytes, sha256 %s\n  host openssl: %s\n' "$(basename "${f}")" "$(wc -c < "${f}")" \
		"$(sha256sum "${f}" | cut -d' ' -f1)" "$(check_cms "${f}")"
done
rm -f "${OUT}/cms.der" "${OUT}/content.bin" "${OUT}/cms.log" "${OUT}"/nousage.index* "${OUT}"/nousage.serial* "${OUT}"/nousage.cnf "${OUT}"/nousage.ext "${OUT}"/0*.pem
