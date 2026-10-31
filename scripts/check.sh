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

# Init scripts and RAUC handlers in a rootfs overlay have no .sh extension (S99ota-health,
# usr/lib/ota/pre-install), so the filter above cannot see them. They are found by their
# shebang instead, and must be executable: BusyBox init and RAUC both run them directly, and a
# script that lost its mode is skipped without a word.
OVERLAY_SCRIPTS="$(find board -path '*/rootfs_overlay/*' -type f | sort | while read -r f; do
	case "$(head -n 1 "${f}" 2>/dev/null)" in
		'#!'*sh*) echo "${f}" ;;
	esac
done)"
SCRIPTS="$(printf '%s\n%s\n' "${SCRIPTS}" "${OVERLAY_SCRIPTS}" | sed 's#^\./##; /^$/d' | sort -u)"

for f in ${OVERLAY_SCRIPTS}; do
	if [ -x "${f}" ]; then
		ok "overlay script is executable: ${f}"
	else
		fail "overlay script ${f} is not executable; run 'chmod 755 ${f}' and 'git add' it, or init and RAUC will skip it."
	fi
done

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

# --- helpers for the storage layout check ------------------------------------
# Bytes in a genimage-style size or offset: 0x80000, 1M, 32K or a plain number.
to_bytes() {
	case "$1" in
		*M) echo $((${1%M} * 1048576)) ;;
		*K) echo $((${1%K} * 1024)) ;;
		*) echo $(($1)) ;;
	esac
}

# genimage_field FILE PARTITION KEY: the value of KEY inside `partition PARTITION { ... }`.
genimage_field() {
	awk -v name="$2" -v key="$3" '
		$1 == "partition" { cur = $2 }
		$1 == key && $2 == "=" && cur == name { print $3; exit }' "$1"
}

# genimage_pnum FILE PARTITION: its number in the MBR, counting only entries that are in the
# partition table (the boot-selection regions are not).
genimage_pnum() {
	awk -v name="$2" '
		$1 == "partition" { cur = $2; intable[cur] = 1; order[++n] = cur }
		$1 == "in-partition-table" && $3 == "false" { intable[cur] = 0 }
		END {
			for (i = 1; i <= n; i++)
				if (intable[order[i]]) {
					k++
					if (order[i] == name) { print k; exit }
				}
		}' "$1"
}

# A defconfig path with Buildroot's external-tree variable turned into a path from the repo root.
# shellcheck disable=SC2016 # the literal Makefile expression, as it is written in the defconfig
external_path() {
	sed 's#\$(BR2_EXTERNAL_OTA_PATH)#.#'
}

# rauc_slot_device CONF BOOTNAME: the device of the [slot.*] section with that bootname.
rauc_slot_device() {
	awk -v bn="$2" '
		function flush() { if (b == bn) print dev }
		/^\[/ { flush(); dev = ""; b = "" }
		/^device=/ { dev = substr($0, 8) }
		/^bootname=/ { b = substr($0, 10) }
		END { flush() }' "$1"
}

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

	# Where the kernel and its device tree live is a board decision, and the two
	# places are mutually exclusive. A board that installs them into the rootfs
	# boots them from its OS slot, so neither may also sit in the boot partition;
	# any other board must list every DTB it builds, and no DTB it does not build.
	if [ -f "${bpath}/genimage.cfg" ]; then
		built="$(defconfig_value "${cfg}" BR2_LINUX_KERNEL_INTREE_DTS_NAME | tr ' ' '\n' | sed '/^$/d; s#.*/##; s#$#.dtb#')"
		listed="$(grep -o '[A-Za-z0-9_.-]*\.dtb' "${bpath}/genimage.cfg" || true)"
		layout_ok=1
		if grep -q '^BR2_LINUX_KERNEL_INSTALL_TARGET=y' "${cfg}"; then
			for d in ${listed}; do
				fail "image layout: ${bpath}/genimage.cfg lists ${d}, but ${cfg} installs the kernel and device tree into the rootfs, so they must not also be in the boot partition."
				layout_ok=0
			done
			if grep -qE '"(zImage|uImage|Image)"' "${bpath}/genimage.cfg"; then
				fail "image layout: ${bpath}/genimage.cfg puts a kernel image in the boot partition, but ${cfg} installs it into the rootfs."
				layout_ok=0
			fi
		else
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
		fi
		if [ "${layout_ok}" -eq 1 ]; then
			ok "image layout: ${b}"
		fi
	fi

	# A board that updates with RAUC keeps its boot-selection state in a raw region of the card,
	# and five files have to agree on where it is and which partition is which (the contract is
	# specs/002-ab-ota-rauc/contracts/storage-layout.md). A disagreement is silent until a device
	# rolls back every update or fails to boot, so it is checked here, on the numbers themselves.
	if grep -q '^BR2_PACKAGE_RAUC=y' "${cfg}"; then
		gen="${bpath}/genimage.cfg"
		fwenv="${bpath}/rootfs_overlay/etc/fw_env.config"
		fstab="${bpath}/rootfs_overlay/etc/fstab"
		sysconf="${bpath}/rootfs_overlay/etc/rauc/system.conf"
		ubcfg="$(defconfig_value "${cfg}" BR2_TARGET_UBOOT_CUSTOM_CONFIG_FILE | external_path)"
		ubenv="$(defconfig_value "${cfg}" BR2_TARGET_UBOOT_DEFAULT_ENV_FILE | external_path)"
		envsize_cfg="$(defconfig_value "${cfg}" BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE_SIZE)"

		missing=""
		for f in "${gen}" "${fwenv}" "${fstab}" "${sysconf}" "${ubcfg}" "${ubenv}"; do
			[ -f "${f}" ] || missing="${missing} ${f:-<unset in the defconfig>}"
		done
		if [ -n "${missing}" ]; then
			fail "storage layout: ${b} uses RAUC but is missing:${missing}."
			continue
		fi

		bad=0
		mismatch() {
			fail "storage layout: ${b}: $1"
			bad=1
		}

		# The two copies of the boot-selection state: genimage, U-Boot and fw_env.config.
		g1="$(to_bytes "$(genimage_field "${gen}" env offset)")"
		g2="$(to_bytes "$(genimage_field "${gen}" env-redund offset)")"
		u1="$(to_bytes "$(sed -n 's/^CONFIG_ENV_OFFSET=\(.*\)$/\1/p' "${ubcfg}")")"
		u2="$(to_bytes "$(sed -n 's/^CONFIG_ENV_OFFSET_REDUND=\(.*\)$/\1/p' "${ubcfg}")")"
		f1="$(awk '!/^#/ && NF >= 3 { print $2; exit }' "${fwenv}")"
		f2="$(awk '!/^#/ && NF >= 3 { n++; if (n == 2) { print $2; exit } }' "${fwenv}")"
		fsz1="$(awk '!/^#/ && NF >= 3 { print $3; exit }' "${fwenv}")"
		fsz2="$(awk '!/^#/ && NF >= 3 { n++; if (n == 2) { print $3; exit } }' "${fwenv}")"
		fdev="$(awk '!/^#/ && NF >= 3 { print $1; exit }' "${fwenv}")"
		if [ -z "${g1}" ] || [ -z "${g2}" ] || [ -z "${u1}" ] || [ -z "${u2}" ] || [ -z "${f1}" ] || [ -z "${f2}" ]; then
			mismatch "could not read one of the state offsets (genimage '${g1}' '${g2}', uboot.config '${u1}' '${u2}', fw_env.config '${f1}' '${f2}')."
		else
			f1="$(to_bytes "${f1}")"
			f2="$(to_bytes "${f2}")"
			if [ "${g1}" != "${u1}" ] || [ "${u1}" != "${f1}" ]; then
				mismatch "primary state offset differs: genimage.cfg ${g1}, uboot.config ${u1}, fw_env.config ${f1}."
			fi
			if [ "${g2}" != "${u2}" ] || [ "${u2}" != "${f2}" ]; then
				mismatch "redundant state offset differs: genimage.cfg ${g2}, uboot.config ${u2}, fw_env.config ${f2}."
			fi
		fi

		# Its size: fw_env.config for both copies, against the environment image the build makes.
		if [ -n "${envsize_cfg}" ] && [ -n "${fsz1}" ] && [ -n "${fsz2}" ]; then
			es="$(to_bytes "${envsize_cfg}")"
			if [ "$(to_bytes "${fsz1}")" != "${es}" ] || [ "$(to_bytes "${fsz2}")" != "${es}" ]; then
				mismatch "state size differs: fw_env.config ${fsz1} and ${fsz2}, but BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE_SIZE is ${envsize_cfg}."
			fi
			# The two regions must not overlap each other or reach the first partition.
			boot_off="$(to_bytes "$(genimage_field "${gen}" boot offset)")"
			if [ -n "${boot_off}" ] && [ -n "${g1}" ] && [ -n "${g2}" ] &&
				{ [ $((g1 + es)) -gt "${g2}" ] || [ $((g2 + es)) -gt "${boot_off}" ]; }; then
				mismatch "the state regions overlap each other or the boot partition (primary ${g1}, redundant ${g2}, size ${es}, boot partition at ${boot_off})."
			fi
		else
			mismatch "could not read the state size (fw_env.config '${fsz1}' '${fsz2}', defconfig '${envsize_cfg}')."
		fi

		# The device the tools read must be the card itself, not one of its partitions.
		case "${fdev}" in
			/dev/mmcblk[0-9]) ;;
			*) mismatch "fw_env.config reads '${fdev}'; it must be the whole card, /dev/mmcblkN." ;;
		esac

		# Which partition is which: genimage's order against U-Boot, RAUC and fstab.
		pa="$(genimage_pnum "${gen}" rootfs-a)"
		pb="$(genimage_pnum "${gen}" rootfs-b)"
		pd="$(genimage_pnum "${gen}" data)"
		if [ -z "${pa}" ] || [ -z "${pb}" ] || [ -z "${pd}" ]; then
			mismatch "genimage.cfg must define the partitions rootfs-a, rootfs-b and data."
		else
			ua="$(sed -n 's/^ota_part_A=//p' "${ubenv}")"
			ub="$(sed -n 's/^ota_part_B=//p' "${ubenv}")"
			[ "${ua}" = "${pa}" ] || mismatch "U-Boot boots slot A from partition '${ua}' (ota_part_A), genimage.cfg makes rootfs-a partition ${pa}."
			[ "${ub}" = "${pb}" ] || mismatch "U-Boot boots slot B from partition '${ub}' (ota_part_B), genimage.cfg makes rootfs-b partition ${pb}."
			ra="$(rauc_slot_device "${sysconf}" A)"
			rb="$(rauc_slot_device "${sysconf}" B)"
			[ "${ra}" = "${fdev}p${pa}" ] || mismatch "RAUC's slot A is '${ra}', genimage.cfg makes rootfs-a ${fdev}p${pa}."
			[ "${rb}" = "${fdev}p${pb}" ] || mismatch "RAUC's slot B is '${rb}', genimage.cfg makes rootfs-b ${fdev}p${pb}."
			fd="$(awk '$1 !~ /^#/ && $2 == "/data" { print $1 }' "${fstab}")"
			[ "${fd}" = "${fdev}p${pd}" ] || mismatch "fstab mounts /data from '${fd}', genimage.cfg makes data ${fdev}p${pd}."
		fi

		if [ "${bad}" -eq 0 ]; then
			ok "storage layout agreement: ${b}"
		fi
	fi
done

if [ "${FAILED}" -ne 0 ]; then
	echo "make check: ${FAILED} check(s) failed." >&2
	exit 1
fi
echo "make check: all checks passed."
