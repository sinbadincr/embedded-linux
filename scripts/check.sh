#!/bin/sh
# Fast static checks behind `make check`; run from the repo root inside the build container.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

FAILED=0
TMPDIR_CHECK="$(mktemp -d)"
SAVED_BOARD="${TMPDIR_CHECK}/current_board"
HAD_BOARD=0

# The round-trip check runs `make <board>_defconfig`, which rewrites .current_board.
if [ -f .current_board ]; then
	HAD_BOARD=1
	cp .current_board "${SAVED_BOARD}"
fi
restore_state() {
	if [ "${HAD_BOARD}" -eq 1 ]; then
		cp "${SAVED_BOARD}" .current_board
	else
		rm -f .current_board
	fi
	rm -rf "${TMPDIR_CHECK}"
}
trap restore_state EXIT

ok() {
	echo "ok: $*"
}

fail() {
	echo "FAIL: $*" >&2
	FAILED=$((FAILED + 1))
}

# Value of KEY="value" in a defconfig, without the quotes.
defconfig_value() {
	sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1"
}

BOARDS="$(for f in configs/*_defconfig; do
	[ -e "${f}" ] || continue
	basename "${f}" _defconfig
done)"

if [ -z "${BOARDS}" ]; then
	echo "FAIL: no configs/*_defconfig found; add a board first." >&2
	exit 1
fi

# --- shell syntax and lint -------------------------------------------------
SCRIPTS="$(find . \( -path ./buildroot -o -path ./output -o -path ./dl -o -path ./.git -o -path ./.specify -o -path ./.claude \) -prune \
	-o -name '*.sh' -type f -print)"

for s in ${SCRIPTS}; do
	if sh -n "${s}" 2>"${TMPDIR_CHECK}/err"; then
		ok "shell syntax: ${s}"
	else
		cat "${TMPDIR_CHECK}/err" >&2
		fail "shell syntax: ${s} does not parse; fix the error above."
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	# shellcheck disable=SC2086 # SCRIPTS is a newline-separated list of paths without spaces
	if shellcheck ${SCRIPTS}; then
		ok "shell lint: shellcheck clean"
	else
		fail "shell lint: shellcheck reported problems above; fix them or justify a suppression."
	fi
else
	fail "shell lint: shellcheck not found; run 'make docker-build' to rebuild the build environment."
fi

# --- per-board checks ------------------------------------------------------
for b in ${BOARDS}; do
	cfg="configs/${b}_defconfig"

	# defconfig round-trip: regenerate the minimal defconfig next to the build output and
	# compare with the working-tree file, so uncommitted edits are checked and configs/ is
	# never modified.
	if make "${b}_defconfig" >"${TMPDIR_CHECK}/log" 2>&1; then
		tmp="${ROOT}/output/${b}/.savedefconfig.check"
		if make BOARD="${b}" savedefconfig BR2_DEFCONFIG="${tmp}" >"${TMPDIR_CHECK}/log" 2>&1; then
			if cmp -s "${tmp}" "${cfg}"; then
				ok "defconfig round-trip: ${b}"
			else
				diff -u "${cfg}" "${tmp}" >&2 || true
				fail "defconfig round-trip: ${cfg} is not minimal; run 'make ${b}_defconfig && make savedefconfig' and commit the result."
			fi
		else
			cat "${TMPDIR_CHECK}/log" >&2
			fail "defconfig round-trip: 'make savedefconfig' failed for ${b}."
		fi
		rm -f "${tmp}"
	else
		cat "${TMPDIR_CHECK}/log" >&2
		fail "defconfig round-trip: 'make ${b}_defconfig' failed; ${cfg} is not a valid configuration."
	fi

	# Makefile dry run
	if make -n BOARD="${b}" build >/dev/null 2>"${TMPDIR_CHECK}/err"; then
		ok "make dry run: ${b}"
	else
		cat "${TMPDIR_CHECK}/err" >&2
		fail "make dry run: 'make -n BOARD=${b} build' failed."
	fi

	# Board directory comes from the post-image script path, so <board>_<variant> configs
	# resolve to their base board directory.
	post_image="$(defconfig_value "${cfg}" BR2_ROOTFS_POST_IMAGE_SCRIPT)"
	bdir="$(printf '%s' "${post_image}" | sed -n 's#.*/board/ota/\([^/]*\)/post-image\.sh$#\1#p')"
	if [ -z "${bdir}" ]; then
		fail "board parity: ${cfg} must set BR2_ROOTFS_POST_IMAGE_SCRIPT to \$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/post-image.sh."
		continue
	fi
	bpath="board/ota/${bdir}"

	missing=""
	for f in genimage.cfg post-image.sh rootfs_overlay; do
		[ -e "${bpath}/${f}" ] || missing="${missing} ${bpath}/${f}"
	done
	# shellcheck disable=SC2016 # literal Makefile expression as written in the defconfig
	overlay='$(BR2_EXTERNAL_OTA_PATH)/board/ota/common/rootfs_overlay $(BR2_EXTERNAL_OTA_PATH)/board/ota/'"${bdir}"'/rootfs_overlay'
	# shellcheck disable=SC2016 # literal Makefile expression as written in the defconfig
	postbuild='$(BR2_EXTERNAL_OTA_PATH)/board/ota/common/post-build.sh'
	if [ -n "${missing}" ]; then
		fail "board parity: ${b} is missing:${missing}."
	elif [ "$(defconfig_value "${cfg}" BR2_ROOTFS_OVERLAY)" != "${overlay}" ]; then
		fail "board parity: ${cfg} BR2_ROOTFS_OVERLAY must be exactly: ${overlay}"
	elif [ "$(defconfig_value "${cfg}" BR2_ROOTFS_POST_BUILD_SCRIPT)" != "${postbuild}" ]; then
		fail "board parity: ${cfg} BR2_ROOTFS_POST_BUILD_SCRIPT must be: ${postbuild}"
	else
		ok "board parity: ${b}"
	fi

	# Every DTB the kernel builds for the board must be in genimage.cfg, and vice versa.
	if [ -f "${bpath}/genimage.cfg" ]; then
		built="$(defconfig_value "${cfg}" BR2_LINUX_KERNEL_INTREE_DTS_NAME | tr ' ' '\n' | sed '/^$/d; s#.*/##; s#$#.dtb#')"
		listed="$(grep -o '[A-Za-z0-9_.-]*\.dtb' "${bpath}/genimage.cfg" || true)"
		layout_ok=1
		for d in ${built}; do
			if ! printf '%s\n' "${listed}" | grep -qx "${d}"; then
				fail "image layout: ${d} is built by ${cfg} but not listed in ${bpath}/genimage.cfg."
				layout_ok=0
			fi
		done
		for d in ${listed}; do
			if ! printf '%s\n' "${built}" | grep -qx "${d}"; then
				fail "image layout: ${bpath}/genimage.cfg lists ${d}, which ${cfg} does not build."
				layout_ok=0
			fi
		done
		if [ "${layout_ok}" -eq 1 ]; then
			ok "image layout: ${b}"
		fi
	fi
done

if [ "${FAILED}" -ne 0 ]; then
	echo "make check: ${FAILED} check(s) failed." >&2
	exit 1
fi
echo "make check: all checks passed."
