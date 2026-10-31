#!/bin/sh
# Runs ON THE BOARD, not in the build container. Defines try_bundle, which fetches one bundle from
# the build host, tries to install it, and reports whether anything changed: quickstart scenario 7.
# It is sourced, not executed:
#
#   wget -O /tmp/try.sh http://192.168.0.1:8000/try-bundle.sh && . /tmp/try.sh
#   try_bundle beaglebone_black-<revision>-unsigned.raucb
#
# make-untrusted-bundles.sh copies this file next to the bundles as try-bundle.sh. HOST and PORT
# default to the development bench and can be set before sourcing.
HOST="${HOST:-192.168.0.1}"
PORT="${PORT:-8000}"

try_bundle() {
	f="$1"
	if [ -z "${f}" ]; then
		echo "usage: try_bundle <bundle file name on the host>"
		return 2
	fi

	# The slot that is not running is the one an install would write. The running one is on the
	# kernel command line, which is also what RAUC goes by.
	run="$(sed -n 's/.*root=\/dev\/mmcblk0p\([0-9]\).*/\1/p' /proc/cmdline)"
	case "${run}" in
		2) tgt=3 ;;
		3) tgt=2 ;;
		*)
			echo "cannot tell the running slot from /proc/cmdline"
			return 2
			;;
	esac
	echo "== ${f}"
	echo "   running slot: /dev/mmcblk0p${run}; an install would write /dev/mmcblk0p${tgt}"

	state_before="$(fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT)"
	slot_before="$(dd if=/dev/mmcblk0p"${tgt}" bs=1M count=128 2> /dev/null | sha256sum)"

	rm -f /data/t.raucb
	if ! wget -q -O /data/t.raucb "http://${HOST}:${PORT}/${f}"; then
		echo "   download failed: is the server running on the host?"
		return 2
	fi
	echo "   sha256 on the board: $(sha256sum /data/t.raucb | cut -d' ' -f1)"

	rauc install /data/t.raucb > /tmp/install.out 2>&1
	rc=$?
	echo "--- rauc install, without the progress lines:"
	grep -v -E 'Copying image|^ *[0-9]+% ' /tmp/install.out
	echo "--- rauc install exit status: ${rc}"

	state_after="$(fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT)"
	slot_after="$(dd if=/dev/mmcblk0p"${tgt}" bs=1M count=128 2> /dev/null | sha256sum)"
	if [ "${state_before}" = "${state_after}" ]; then
		echo "   boot-selection state: UNCHANGED"
	else
		echo "   boot-selection state: CHANGED"
		echo "   before: $(echo "${state_before}" | tr '\n' ' ')"
		echo "   after:  $(echo "${state_after}" | tr '\n' ' ')"
	fi
	if [ "${slot_before}" = "${slot_after}" ]; then
		echo "   slot p${tgt} (first 128 MiB): UNCHANGED"
	else
		echo "   slot p${tgt} (first 128 MiB): CHANGED"
	fi
	rm -f /data/t.raucb
	if [ "${rc}" -ne 0 ]; then
		echo "RESULT: refused"
	else
		echo "RESULT: installed (reboot to run it; nothing has been confirmed yet)"
	fi
}

echo "try_bundle is defined: try_bundle <file>   (server ${HOST}:${PORT})"
