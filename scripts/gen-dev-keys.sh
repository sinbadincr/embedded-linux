#!/bin/sh
# Generates the development CA and bundle-signing material for OTA update bundles.
# Runs in the build container; writes only into the directory given as $1.
set -eu

KEYS_DIR="${1:?usage: gen-dev-keys.sh <dir>}"

CA_DAYS=3650
SIGN_DAYS=1825
SUBJ_O="OTA development"

# Replacing the CA is not an ordinary regeneration: every image already flashed
# trusts it, and a new CA leaves those devices unable to install any bundle.
if [ -e "${KEYS_DIR}/dev-ca.key.pem" ]; then
	echo "A development CA already exists in ${KEYS_DIR}." >&2
	echo "Replacing it would leave every image already flashed with it unable to" >&2
	echo "install any bundle. To start over deliberately: rm -rf ${KEYS_DIR}" >&2
	exit 1
fi

# Before mkdir, so the directory itself is not created world-readable.
umask 077
mkdir -p "${KEYS_DIR}"

# The CA certifies the signing key and nothing else. Keeping it out of the
# bundle path is what lets a signing key be replaced without reflashing.
openssl req -x509 -newkey rsa:4096 -noenc \
	-keyout "${KEYS_DIR}/dev-ca.key.pem" \
	-out "${KEYS_DIR}/dev-ca.cert.pem" \
	-days "${CA_DAYS}" \
	-subj "/O=${SUBJ_O}/CN=OTA development CA - NOT FOR PRODUCTION" \
	-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
	-addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -noenc \
	-keyout "${KEYS_DIR}/dev-signing.key.pem" \
	-out "${KEYS_DIR}/dev-signing.csr.pem" \
	-subj "/O=${SUBJ_O}/CN=OTA development bundle signing - NOT FOR PRODUCTION"

# POSIX sh has no process substitution, so the extensions need a real file.
EXT_FILE="$(mktemp)"
trap 'rm -f "${EXT_FILE}"' EXIT
cat > "${EXT_FILE}" <<-EXT
	basicConstraints=critical,CA:FALSE
	keyUsage=critical,digitalSignature
	extendedKeyUsage=codeSigning
EXT

openssl x509 -req -in "${KEYS_DIR}/dev-signing.csr.pem" \
	-CA "${KEYS_DIR}/dev-ca.cert.pem" \
	-CAkey "${KEYS_DIR}/dev-ca.key.pem" \
	-days "${SIGN_DAYS}" \
	-extfile "${EXT_FILE}" \
	-out "${KEYS_DIR}/dev-signing.cert.pem"

chmod 600 "${KEYS_DIR}"/dev-ca.key.pem "${KEYS_DIR}"/dev-signing.key.pem
chmod 644 "${KEYS_DIR}"/dev-ca.cert.pem "${KEYS_DIR}"/dev-signing.cert.pem

echo "Development signing material written to ${KEYS_DIR}:"
echo "  dev-ca.cert.pem       trust anchor, installed as /etc/rauc/keyring.pem"
echo "  dev-signing.cert.pem  signs bundles, travels inside each bundle"
echo "Development only: a bundle signed with this material installs only on an"
echo "image built with the same CA."
