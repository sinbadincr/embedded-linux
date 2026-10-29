---

description: "Task list for the A/B Atomic OTA Update feature"
---

# Tasks: A/B Atomic OTA Update with Automatic Rollback

**Input**: Design documents from `/specs/002-ab-ota-rauc/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/storage-layout.md,
contracts/boot-interface.md, contracts/signing-chain.md, quickstart.md

**Tests**: No unit-test framework exists (Principle IV) and none was requested. Tasks marked
"Verify" run the checks the constitution requires; those marked "Verify (hardware)" need the board
and produce the serial evidence that goes in the PR. A green `make check` is not a boot test.

**Organization**: Grouped by user story so each can be implemented and verified independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 flash and boot, US2 update, US3 rollback, US4 trust, US5 observability
- All shell is POSIX `sh`, `set -eu`, quoted expansions, one-line header comment (Principle III)
- Every defconfig change is made with `make menuconfig` and written back with `make savedefconfig`;
  never hand-edited (Principle III)
- Everything committed is English

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: the build environment and the signing material, both of which everything else needs.

- [X] T001 Add `openssl` to the `apt-get install` list in `Dockerfile`, explicitly rather than
      relying on it arriving as a dependency of `ca-certificates`, then rebuild the image with
      `make docker-build` (Principle II forbids `apt-get` inside a running container)
- [X] T002 [P] Add `/keys/` to `.gitignore`, in the same group as `/output/` and `/dl/`, with a
      one-line comment saying it holds development signing material
- [X] T003 [P] Create `scripts/gen-dev-keys.sh`: POSIX `sh`, `set -eu`, `umask 077` **before**
      `mkdir`, generating into `$1` the four files of contracts/signing-chain.md — `dev-ca.key.pem`
      (RSA 4096), `dev-ca.cert.pem` (`basicConstraints=critical,CA:TRUE,pathlen:0`,
      `keyUsage=critical,keyCertSign,cRLSign`, 3650 days), `dev-signing.key.pem` (RSA 2048) and
      `dev-signing.cert.pem` (`CA:FALSE`, `keyUsage=critical,digitalSignature`,
      `extendedKeyUsage=codeSigning`, 1825 days, issued by the CA). Both subjects carry
      `NOT FOR PRODUCTION` in the common name (FR-020). Extensions go through a `mktemp` file with a
      `trap ... EXIT`, never bash process substitution. Refuse to run when
      `dev-ca.key.pem` already exists, with a message saying that replacing the CA invalidates every
      image already flashed and naming `rm -rf` as the deliberate way out. End with `chmod 600` on
      the keys and `644` on the certificates
- [X] T004 In `Makefile`: add `KEYS_DIR ?= $(ROOT_DIR)/keys/dev`; add and `export` `OTA_KEYRING`,
      `OTA_SIGNING_CERT` and `OTA_SIGNING_KEY` with the defaults in contracts/boot-interface.md; add
      a `check_keys` macro that passes when the selected board's defconfig has no
      `BR2_PACKAGE_RAUC=y` and otherwise requires `$(OTA_SIGNING_KEY)` to exist, failing to stderr
      with `make ota-dev-keys` named; add the `ota-dev-keys` target guarded by `$(check_env)` and
      calling `scripts/gen-dev-keys.sh $(KEYS_DIR)`; add it to `.PHONY` so the catch-all `%:` rule
      cannot forward it to Buildroot; add one line for it to `help`
- [X] T005 Verify: `make ota-dev-keys` creates the four files with the documented modes;
      `openssl verify -CAfile keys/dev/dev-ca.cert.pem keys/dev/dev-signing.cert.pem` passes;
      `openssl x509 -noout -text` shows `CA:TRUE` on the CA, `CA:FALSE` plus `Code Signing` on the
      signing certificate, and `NOT FOR PRODUCTION` in both subjects; a second run refuses and
      changes nothing

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the three research items that must be confirmed before committing to offsets, and the
U-Boot and kernel configuration switchover. **Nothing in any user story can be trusted until T016
passes**: if the running system and the bootloader disagree about where the boot-selection state
lives, every update rolls back while every image is sound.

- [X] T006 [P] Verify the AM335x boot ROM's raw-image offsets against the current TRM and confirm
      that 0x80000 is clear of all of them; the 0 / 128K / 256K / 384K list in research.md R2 comes
      from a secondary source. Record the finding and its reference in `research.md` R2
- [X] T007 [P] Verify that the `genimage` in this tree supports a region outside the partition
      table (`in-partition-table = false`) by reading its documentation in
      `output/beaglebone_black/build/genimage-*/`; record the exact syntax in
      `contracts/storage-layout.md`
- [X] T008 [P] Verify which environment binaries RAUC 1.15.2 invokes, by reading the U-Boot
      bootloader backend in `output/beaglebone_black/build/rauc-1.15.2/src/`, and confirm
      `BR2_PACKAGE_UBOOT_TOOLS_FWPRINTENV` installs all of them; note in `research.md` R6 whether
      `fw_getenv` needs a symlink
- [X] T009 In `configs/beaglebone_black_defconfig`, switch U-Boot to a custom configuration:
      `BR2_TARGET_UBOOT_USE_CUSTOM_CONFIG=y` with
      `BR2_TARGET_UBOOT_CUSTOM_CONFIG_FILE="$(BR2_EXTERNAL_OTA_PATH)/board/ota/beaglebone_black/uboot.config"`,
      and point `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE` at
      `$(BR2_EXTERNAL_OTA_PATH)/board/ota/beaglebone_black/uboot-env.txt`. A config fragment would be
      shorter but the constitution's Technical Constraints require a generated custom config
- [X] T010 Create `board/ota/beaglebone_black/uboot-env.txt` with the defaults and the
      slot-selection script of contracts/boot-interface.md: `BOOT_ORDER="A"`, `BOOT_A_LEFT=3` and
      `BOOT_B_LEFT=0` (only slot A is populated in the factory image, so B starts ineligible: RAUC
      calls a slot good when it is listed in `BOOT_ORDER` with attempts left, and an empty slot must
      never be selected), and a `bootcmd` that walks `BOOT_ORDER`, skips a slot whose counter is 0,
      otherwise decrements it, runs `saveenv`, announces the chosen slot on the console (FR-027),
      loads `/boot/zImage` and the device tree from that slot with `ext4load`, and boots it with
      `root=` pointing at that slot mounted read-only
- [X] T011 Generate `board/ota/beaglebone_black/uboot.config` with `make uboot-menuconfig` followed
      by `make uboot-update-defconfig`: enable `ENV_IS_IN_MMC` and disable `ENV_IS_IN_FAT`; set
      `ENV_OFFSET=0x80000`, `ENV_OFFSET_REDUND=0xA0000`, `ENV_SIZE=0x20000`,
      `ENV_MMC_DEVICE_INDEX=0` and `ENV_REDUNDANT=y`; disable `BOOTCOUNT_LIMIT` and
      `BOOTCOUNT_AM33XX` so exactly one attempt counter is active (FR-003); lower `BOOTDELAY` from
      the measured 2 s. `ENV_OFFSET` must be set explicitly: its `ARCH_OMAP2PLUS` default of
      0x260000 lands inside partition 1
- [X] T012 In `configs/beaglebone_black_defconfig`, enable
      `BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE` with `_SOURCE` set to the same `uboot-env.txt`,
      `_SIZE="0x20000"` and `_REDUNDANT=y`, producing `uboot-env.bin` in `BINARIES_DIR` for
      `genimage` to write into the reserved region. Same file as T009, so run them in sequence
- [X] T013 Create `board/ota/beaglebone_black/fw_env.config` with the two lines of
      contracts/storage-layout.md — `/dev/mmcblk0 0x80000 0x20000` and `/dev/mmcblk0 0xa0000
      0x20000` — and install it to `/etc/fw_env.config` through the board's `rootfs_overlay/`
- [X] T014 In `configs/beaglebone_black_defconfig`, switch the kernel to a custom configuration
      (`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` with
      `board/ota/beaglebone_black/linux.config`), then generate that file with
      `make linux-menuconfig` and `make linux-update-defconfig`: build `WATCHDOG_CORE` and
      `OMAP_WATCHDOG` in rather than as modules, and set a non-zero
      `CONFIG_WATCHDOG_OPEN_TIMEOUT` so the kernel stops covering an unopened watchdog. Today
      `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` with an open timeout of 0 makes the kernel ping the
      bootloader's watchdog forever, so a hung slot is never reset and FR-032 cannot be met
- [X] T015 In `configs/beaglebone_black_defconfig`, add the packages and sizes: `BR2_PACKAGE_RAUC`,
      `BR2_PACKAGE_HOST_RAUC`, `BR2_PACKAGE_UBOOT_TOOLS` with
      `BR2_PACKAGE_UBOOT_TOOLS_FWPRINTENV`, `BR2_PACKAGE_HOST_UBOOT_TOOLS`,
      `BR2_TARGET_ROOTFS_EXT2_SIZE="128M"` (29.5 MiB of content plus a 7.3 MiB kernel, about 30% of
      the filesystem), and the kernel image plus device tree installed into `/boot` of the rootfs so
      a slot is self-contained (FR-002); confirm the device tree lands there and copy it in
      `post-build.sh` if it does not
- [X] T016 Verify (hardware): build and flash, then prove the running system and the bootloader
      agree on the state. **Ordering correction found while implementing**: this cannot be run until
      T017 puts `uboot-env.bin` into the image, because an unseeded region makes `fw_printenv` fail
      its CRC check and the test would prove nothing. Either run T017 first, or run this with a
      manual `saveenv` at the U-Boot prompt to populate the region once. `fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT` in Linux must print what
      `printenv` prints at the U-Boot prompt; `fw_setenv BOOT_A_LEFT 2` followed by a reboot must be
      visible to U-Boot. This is the single most expensive thing to get wrong in this feature, and
      the most commonly reported failure in systems of this kind

---

## Phase 3: User Story 1 - Flash and boot a device with redundant slots (Priority: P1) 🎯 MVP

**Goal**: a card written from the factory image boots to a login prompt from slot A on the new
four-partition layout, reports its slot as good, and has a writable persistent area — while the
day-to-day build, flash and boot workflow is unchanged for anyone who does not care about updating.

**Independent Test**: write `sdcard.img` to a blank card, boot, confirm a login prompt on the serial
console, and confirm `rauc status` names the booted slot and reports it good with slot B unused.

- [X] T017 [US1] Rewrite `board/ota/beaglebone_black/genimage.cfg` to the layout of
      contracts/storage-layout.md: MBR; `uboot-env.bin` written at 0x80000 and 0xA0000 outside the
      partition table; `p1` boot FAT16 32 MiB bootable type 0x0C starting at 1 MiB holding only
      `MLO` and `u-boot.img`; `p2` and `p3` 512 MiB each from `rootfs.ext4`; `p4` 256 MiB ext4 for
      data. `p3` and `p4` are empty in the factory image
- [X] T018 [P] [US1] Create `board/ota/beaglebone_black/rootfs_overlay/etc/fstab`: root read-only,
      `/dev/mmcblk0p4` at `/data` read-write, and tmpfs for `/tmp`, `/run` and `/var` so a read-only
      slot does not prevent normal operation (FR-028)
- [X] T019 [P] [US1] Create `board/ota/beaglebone_black/rauc-system.conf` with
      `compatible=ota-beaglebone-black`, `bootloader=uboot`, the keyring at `/etc/rauc/keyring.pem`,
      the slot status file on `/data` so a failure record outlives the reboot that reveals it
      (FR-014), and the two slots of data-model.md — `rootfs.0` on `/dev/mmcblk0p2` with
      `bootname=A` and `rootfs.1` on `/dev/mmcblk0p3` with `bootname=B`, both type `ext4`. Install
      it to `/etc/rauc/system.conf` through the board's `rootfs_overlay/`
- [X] T020 [US1] Extend `board/ota/common/post-build.sh`: when the board's configuration has
      `BR2_PACKAGE_RAUC=y`, install `$OTA_KEYRING` to `${TARGET_DIR}/etc/rauc/keyring.pem` with mode
      0644, failing with a message naming `make ota-dev-keys` when it is missing. This is the
      backstop for build paths that do not go through the `build` target; keep it board-independent
      (FR-029)
- [X] T021 [US1] Rewrite `board/ota/beaglebone_black/post-image.sh`: drop the `uEnv.txt` and
      `extlinux.conf` copying, keep the `genimage.sh` call, and keep `set -eu` with the one-line
      header comment stating the working directory assumption
- [X] T022 [US1] Delete `board/ota/beaglebone_black/uEnv.txt` and
      `board/ota/beaglebone_black/extlinux.conf`. The boot baseline proves the board boots through
      `extlinux.conf` and never reads `uEnv.txt`; both are replaced by the slot-selection script
- [X] T023 [US1] In `configs/beaglebone_black_defconfig`, stop remounting the root filesystem
      read-write, so the running slot cannot diverge from the bundle it came from (FR-006)
- [X] T024 [US1] Verify (hardware): quickstart scenario 1 — flash, boot to a login prompt,
      `rauc status` shows slot A booted and good with B not bootable, `BOOT_ORDER="A"` with
      `BOOT_A_LEFT` at 3 (2 after the first boot, until `rauc status mark-good` restores it) and
      `BOOT_B_LEFT` at 0, a write to `/` fails, a write to `/data` succeeds and survives a power
      cycle, and the console names slot A during boot
- [X] T025 [US1] Verify (hardware): quickstart scenario 2 — three `grabserial` runs by the method in
      `docs/boot-baseline-beaglebone-black.md`; the mean from the SPL banner to the login prompt
      must be at most 12.65 s, which is the measured 11.50 s plus 10% (SC-008)

---

## Phase 4: User Story 2 - Update a running device to a new image (Priority: P2)

**Goal**: one operator command installs a signed bundle into the slot that is not running, a reboot
brings the new slot up, and the system confirms its own health before that slot is recorded good.

**Independent Test**: on a device from US1, install a bundle built from a visibly different revision,
reboot, and confirm the device runs the new revision from the other slot while the first slot still
holds the previous one.

- [X] T026 [US2] Extend `board/ota/beaglebone_black/post-image.sh` to build the bundle: stage
      `rootfs.ext4` and a `manifest.raucm` carrying `compatible=ota-beaglebone-black` and the
      `version` from `git describe --always --dirty` (the same string `post-build.sh` writes to
      `/etc/build-info`, so FR-024 holds), then call `$HOST_DIR/bin/rauc bundle` with
      `--cert "$OTA_SIGNING_CERT"` and `--key "$OTA_SIGNING_KEY"` to produce
      `beaglebone_black-<version>.raucb` in `BINARIES_DIR`. No `--intermediate`: the chain is two
      levels and `--cert` already embeds the signing certificate in the CMS signature
      (built: `beaglebone_black-<version>.raucb`, 23.1 MB for a 128 MiB `rootfs.ext4`. The build does
      not verify the signature: `rauc info` loop-mounts a plain bundle, which the unprivileged build
      container cannot do, so the first signature check is the device's, in T029)
- [X] T027 [US2] Create `board/ota/common/rootfs_overlay/etc/init.d/S99ota-health`,
      board-independent (FR-029), running the four conditions of FR-012 in order — the init sequence
      reached this script; the running slot is the slot that was pending, according to RAUC rather
      than a guess; `/data` is mounted and a write to it succeeds; `fw_printenv` reads the state and
      `fw_setenv` writes it back — and calling `rauc status mark-good` only when all four hold. No
      network check: a board on a bench with no uplink must still be able to confirm a good update.
      **Last-resort boots** (T025 captured one: RAUC reports "Unable to find primary boot slot"
      because the slot has no attempts left) have no pending slot, so condition two reads: RAUC
      names the booted slot as primary, or RAUC names no primary at all. A different slot named as
      primary is an inconsistent state and fails. A last-resort boot that passes is confirmed like
      any other and the script logs, to `/data`, that it was one (see the clarification in spec.md)
      (written; checked on the host with stubbed `rauc`, `fw_printenv`, `fw_setenv` for nine paths:
      normal, primary mismatch, last resort, `/data` unmounted, `/data` unwritable, state unreadable,
      state unwritable, `mark-good` failing, RAUC reporting nothing. Its failures and last-resort
      confirmations go to `/data/ota-health.log`, which T038 makes the documented path. The
      watchdog feeder is T032, not this task.
      **First boot on hardware (`bbb2f49`) found a defect the stubs could not**: it refused to
      confirm slot A, `RAUC names slot 'A' as primary but '/dev/mmcblk0p2' is running`, because with
      `root=/dev/mmcblk0p2` RAUC puts the device in `RAUC_SYSTEM_BOOTED_BOOTNAME`, not the boot name,
      and the stubs had assumed the latter. Fixed by taking the slot whose state is `booted`.
      **Confirmed on the second boot (`520f1aa`)**: `slot A confirmed good`, `BOOT_A_LEFT=3`. Only the
      confirm path is proven on hardware; the refuse and last-resort paths are host-tested)
- [X] T028 [US2] Verify (hardware): with an update installed and not yet confirmed, a second `rauc install` is
      refused with a message naming the pending state and `rauc status` is unchanged afterwards
      (FR-009). **First run, 2026-10-29, failed**: the second install was not refused, it rewrote
      the pending slot (`docs/logs/t029-install-and-switch.log`); T048 adds the refusal. Verify again
      on an image that has T048, in the state "installed, not yet rebooted", and also with two
      `rauc install` started at once. **Passed for the pending condition**, on `1c7e147` which was
      itself installed over the air: the second install is refused, names slot B as pending and slot
      A as running, writes nothing, and `rauc status` is unchanged
      (`docs/logs/t028-refused-while-pending.log`). Two installs at once is host-checked only
- [X] T046 [US2] Implement research R8 option B, approved by the user on 2026-10-28 (FR-033):
      `board/ota/common/post-build.sh` writes `BUILD_DATE=<epoch seconds>` to `/etc/build-info`, and
      `board/ota/common/rootfs_overlay/etc/init.d/S00ota-clock` raises the clock to it, at the start
      of boot, only when the clock is earlier. Done when `sh -n` and `shellcheck` are clean and the
      script's four paths (cold boot, clock already past the floor, no `BUILD_DATE`, non-numeric
      `BUILD_DATE`) behave as R8 describes. Hardware evidence is carried by T029 and T030, boot time
      by T043. **T029 depends on this task.**
      **First boot on hardware (`bbb2f49`) failed this task's purpose**: the script raised the clock,
      then the RTC driver, a module loaded later, set it back to 2000. Fixed by building the driver
      in (`CONFIG_RTC_DRV_OMAP=y`); research R8, "What the first boot showed". **Confirmed on the
      second boot (`520f1aa`)**: the `ota-clock:` line, then a `date` at the build time with no
      `date -s` typed (`docs/logs/t046-t027-second-hardware-boot.log`)
- [X] T047 [US2] Give `beaglebone_black` a static `eth0` in the image, 192.168.0.2/24 with gateway
      192.168.0.1 (`board/ota/beaglebone_black/rootfs_overlay/etc/network/interfaces`), so the
      bundle can be fetched without typing an address after every cold boot. Decided by the user on
      2026-10-29 after `ping` and `wget` worked with the address set by hand (research R8). No new
      package and no listening port. Confirmed on `d6cfccb` by the user's report: address up at
      boot, ping, and the bundle fetched into `/data` with an identical SHA-256
      (`docs/logs/t047-network-and-delivery.log`; only the hash was pasted, so T029's console log
      should show the rest). Its boot-time effect is measured by T043
- [X] T048 [US2] Refuse an installation while an earlier update is pending or another one runs
      (FR-009), found missing by T028: `board/ota/common/rootfs_overlay/usr/lib/ota/pre-install`,
      wired in as `[handlers] pre-install` in the board's `system.conf`. It runs after the bundle is
      verified and mounted and before RAUC marks the target slot bad, so a refusal writes nothing.
      Pending means RAUC's primary slot is not the running one; a rolled-back device or one on the
      last-resort path has nothing pending and can still be updated. Host-checked for five states
      (nothing pending, pending, booted into the update, last resort, a second `rauc install`
      running); the pending case confirmed on the board (T028)
- [X] T029 [US2] Verify (hardware): quickstart scenario 3 — **preparation, decided in research R8,
      do not re-ask**: deliver the bundle with `python3 -m http.server` on the host and
      `udhcpc -i eth0` plus `wget -O /data/<bundle>.raucb` on the board (no defconfig change, so
      SC-008 is untouched by the delivery path). The board has its address from the image (T047):
      first `ping -c 3 192.168.0.1`, then the `wget` into `/data`, and compare the size and, on both
      ends, `sha256sum`. **No `date -s`**: `rauc install` checks
      certificate validity against the clock and has no `--no-check-time`, and the board cold-boots
      at 2000-01-01, which T046 handles at boot. The log must show the console line
      `ota-clock: clock was 2000-01-01 ... raised to image build time ...` after the cold boot and a
      `rauc install` that succeeds without anyone having set the clock. Then: install, `BOOT_ORDER` becomes `"B A"`,
      reboot, `/etc/build-info` shows the new version, `rauc status` shows the new slot good and the
      old slot still holding the previous version, and the file written to `/data` in US1 is
      unchanged (SC-006)
      **First attempt, 2026-10-29 (`docs/logs/t029-first-install-attempt.log`)**: delivery and the clock
      worked; `rauc install` refused the bundle with `unsuitable certificate purpose` and wrote nothing.
      Fixed in the board's `system.conf` (`check-purpose=codesign`), which needs the fixed image
      flashed. **Second attempt**: the signature verified, then the mount of the bundle failed on
      the read-only slot (`mountprefix=/run/rauc`), and behind it the kernel had no SquashFS
      (`CONFIG_SQUASHFS=y`, `_ZLIB=y`), both fixed in `4ae0c69`. **Third attempt: it worked**
      (`docs/logs/t029-install-and-switch.log`): install in about 8 s, `BOOT_ORDER="B A"`, boot of slot
      B, the bundle's `VERSION`, health confirmed. Done, with one reading to be careful of: the install, `BOOT_ORDER="B A"`, the
      boot of the new slot, its `VERSION`, health, and `/data/keep` unchanged after two installs and
      two reboots (SC-006) are all on record (`t029-*.log`, `t028-*.log`). `rauc status` prints
      boot status, not versions; the per-slot versions are `rauc status --detailed`, asked of T039
- [X] T030 [US2] Verify (hardware): quickstart scenario 4 — five trials cutting power at a different
      point of the installation; every trial must boot the previous version to a login prompt with
      the previous version reported and the root filesystem intact (SC-002). Record the point of
      interruption per trial. **Install a bundle of a different, older revision** than the running
      one, or the check "previous version reported" cannot tell the old slot from a half-written new
      one; the procedure and the five cut points are in quickstart scenario 4. The edge case "power
      loss between installation and first boot" passed on 2026-10-29, as the user reported it
      (`docs/logs/edge-power-loss-before-first-boot.log`). **Closed with a waiver, 2026-10-29: 3 of 5
      trials run, all 3 pass** (`docs/logs/t030-power-cut-trials.log`): 1 before the first write, 2
      about a second into the write (53%), 5 in the pause at 99%. Trials 3 (about 70%) and 4 (about
      90%) were **not run**: the user decided to stop at three. They are waived, not passed, and
      SC-002's "5 of 5" is not demonstrated as written. The closing uninterrupted install (FR-015)
      is left to User Story 3's hardware tasks
      (each trial's board cold-boots into 2000; T046 raises the clock at boot, so no step is
      repeated by hand, and each trial's log must show the `ota-clock:` line)

---

## Phase 5: User Story 3 - Automatic rollback when the new image fails (Priority: P3)

**Goal**: a broken or hanging update returns the device to the last good slot with no operator
action, and the failure is recorded where it survives.

**Independent Test**: install a bundle that cannot boot, reboot, and watch the device return to the
previous slot on its own within the documented number of attempts.

- [ ] T031 [US3] Extend `board/ota/beaglebone_black/uboot-env.txt` with the exhausted-slots path:
      when every slot is at 0 attempts, announce it on the console, restore one attempt to the first
      slot in `BOOT_ORDER` and try it, rather than halting at a prompt
- [ ] T032 [US3] **The kernel change of T014 is not sufficient on its own**: T016 measured 253
      seconds at an idle shell with no watchdog client and no reset, so start by finding out what
      actually keeps the watchdog from firing (research.md R5 lists three candidates in order of
      likelihood), then extend `S99ota-health` to start the BusyBox `watchdog` feeder **only** after
      `rauc status mark-good` succeeds, and to log the reason to `/data` and leave the feeder stopped
      when any condition fails, so an unhealthy slot is reset and retired by the attempt counter
      (FR-032)
- [ ] T033 [US3] Verify (hardware): quickstart scenario 5 — three trials with a bundle whose kernel
      is deliberately unusable; the counter must walk 3 → 2 → 1 → 0 across attempts, the device must
      then boot the previous slot unaided, and `rauc status` must show the failed slot bad with the
      reason readable from `/data` (SC-003, FR-014)
- [ ] T034 [US3] Verify (hardware): quickstart scenario 6 — three trials with a slot made to hang
      after boot; the watchdog must reset the board within the documented window and the device must
      end on the previous good slot (SC-014). Capture a "before" run on the unmodified image too:
      it cannot pass this at all, which is the clearest evidence the kernel change was necessary
- [ ] T035 [US3] Verify (hardware): quickstart scenario 8 — with `/etc/fw_env.config` pointed at a
      wrong offset on a test image, the health check must fail its fourth condition, the slot must
      never be marked good, the device must roll back, and the reason must survive the reboot in
      `/data` (SC-013)

---

## Phase 6: User Story 4 - Only trusted, intact bundles are accepted (Priority: P4)

**Goal**: a bundle that is unsigned, signed outside the device's trust domain, altered after
signing, or built for another board is refused before anything is written.

**Independent Test**: attempt all four and confirm each is refused with a distinct message and both
slots are untouched afterwards.

- [ ] T036 [US4] Document in `quickstart.md` the exact commands for the untrusted-bundle case:
      generate a second CA and signing pair into a scratch directory with `scripts/gen-dev-keys.sh`,
      then build a bundle with `OTA_SIGNING_CERT` and `OTA_SIGNING_KEY` pointed at it, so the
      refusal under test is a chain that does not reach the device's CA. Add a fifth case: a
      certificate issued by the device's own CA but without the Code Signing usage, which the
      device must refuse by purpose (`check-purpose=codesign`, found on the first install)
- [ ] T037 [US4] Verify (hardware): quickstart scenario 7 — five refusals, each with a distinct
      message, nothing written, `rauc status` and both slots unchanged after every attempt (SC-004,
      FR-016 to FR-019)

---

## Phase 7: User Story 5 - Inspect and reason about update state (Priority: P5)

**Goal**: anyone holding the device, or reading a report from one, can tell which slot is running,
what each slot holds, which are good or bad, and whether an update awaits confirmation.

**Independent Test**: on a device that has been updated once and rolled back once, read the status
output and confirm it answers all of that in one command.

- [ ] T038 [US5] Make the failure record the health script writes to `/data` readable on its own:
      which slot, which condition failed, and when, in a single documented file path named in
      `contracts/boot-interface.md`
- [ ] T039 [US5] Verify (hardware): `rauc status` in one invocation reports the booted slot, both
      slots' versions and health, and any pending confirmation (FR-026, SC-005); the boot console
      identifies the selected slot (FR-027); and a rolled-back device is distinguishable from a
      normal boot (SC-013)

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T040 Extend `scripts/check.sh`: lint the new scripts with `sh -n` and `shellcheck`, **including
      the init scripts under `rootfs_overlay/etc/init.d/`, which have no `.sh` extension and are
      invisible to the current `*.sh` filter** (`S00ota-clock` was linted by hand for that reason); assert
      that the offsets in `genimage.cfg`, `uboot.config` and `fw_env.config` are the same numbers;
      assert the kernel is inside the OS slot rather than listed among the boot partition's files;
      keep the existing device-tree and board-parity assertions working with the new layout (FR-031)
- [ ] T041 [P] Update `README.md`: the four-partition layout with its reserved region, the 2 GB
      minimum card and the unused space beyond the layout, the update and rollback procedures, the
      `make ota-dev-keys` step, and the limitation that the bootloader is never updated in the field
      (FR-004, FR-030)
- [ ] T042 [P] Update `CLAUDE.md` with the same facts an agent needs: the new layout, the reserved
      region, the custom U-Boot and kernel configurations, the three `OTA_*` variables, and the one
      counter rule. The target-clock note is already there (added with T046); keep it current
- [ ] T043 Re-measure and record in `README.md` every figure the layout change invalidates: both
      slots' and the boot partition's usage, the data area, `sdcard.img`, the bundle size, and the
      boot time against the 11.50 s baseline, now including S00ota-clock (Principle VI, SC-007,
      SC-008)
- [ ] T044 Record the hardware evidence from T016, T024, T025, T029, T030, T033, T034, T035, T037
      and T039 under `docs/logs/` and summarise it in the PR; Principle IV requires the evidence to
      be stated, and a green check run is explicitly not a boot test
- [ ] T045 Verify: `make docker-check` is green from a clean checkout, and
      `make beaglebone_black_defconfig && make savedefconfig` leaves no diff

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)** has no dependencies. T005 depends on T003 and T004.
- **Phase 2 (Foundational)** depends on Phase 1 for the signing material, since a build of an A/B
  board refuses to start without it. **It blocks every user story.**
- **Phase 3 (US1)** depends on all of Phase 2, T016 included.
- **Phase 4 (US2)** depends on US1: there is nothing to update until a device boots from a slot.
  T029 and T030 depend on T046, which is a task of Phase 4 numbered last because it was added
  after the list was first written.
- **Phase 5 (US3)** depends on US2: rollback is observed by installing something and letting it
  fail.
- **Phase 6 (US4)** depends on US2 for the install path; independent of US3.
- **Phase 7 (US5)** depends on US2 and US3 for something to report, but its implementation task
  T038 can be written any time after T027.
- **Phase 8 (Polish)** comes last, except that T040 can be written as soon as the layout of T017 is
  fixed.

### Within Phase 2

T006, T007 and T008 are independent of everything and of each other. T009 → T010 → T011 → T012 →
T013 is a chain: the defconfig must point at the files before they can be generated, and T009 and
T012 edit the same defconfig. T014 and T015 also edit that defconfig, so they follow T012 rather
than running beside it. T016 needs all of them.

### Parallel Opportunities

- T002, T003 in Phase 1
- T006, T007, T008 at the start of Phase 2 — all three are reading, not writing
- T018, T019 in US1 (different new files)
- T041, T042 in Phase 8
- Nothing that edits `configs/beaglebone_black_defconfig` is ever parallel: T009, T012, T014, T015
  and T023 share one file, and each ends with `make savedefconfig`

## Parallel Example: Phase 2 research

```
# Three readers, no writers in common:
T006  AM335x TRM raw-image offsets          -> research.md R2
T007  genimage in-partition-table support   -> contracts/storage-layout.md
T008  which fw_* binaries RAUC invokes      -> research.md R6
```

## Implementation Strategy

### MVP first (User Story 1 only)

Phase 1 → Phase 2 → Phase 3, then stop and evaluate. That is already a shippable state: a board
that boots exactly as before, on a layout that is ready to be updated, with `rauc status` answering
and the boot-time budget proven. It is also where the brick risk lives, so it deserves its own
commit and its own serial capture before anything else starts.

### Incremental delivery

1. Phases 1–3 → a device on the A/B layout (US1)
2. Phase 4 → it can be updated (US2)
3. Phase 5 → a bad update cannot keep it (US3)
4. Phase 6 → only trusted bundles get in (US4)
5. Phase 7 → its state is legible (US5)
6. Phase 8 → documentation, checks and re-measured budgets

Each step is a commit with its hardware evidence. Do not batch the hardware verifications to the
end: T016 in particular tells you whether the whole design works, and finding out after Phase 5
means unpicking five phases.

## Notes

- 45 tasks: 5 setup, 11 foundational, 9 for US1, 5 for US2, 5 for US3, 2 for US4, 2 for US5,
  6 polish.
- 15 tasks need the board. They are the deliverable evidence, not a formality: this feature changes
  the partition layout, the bootloader environment, the kernel configuration, the bootargs and init,
  every one of which the constitution lists as requiring a boot smoke test.
- Three tasks exist only because reading the boot baseline contradicted an assumption: T011 disables
  a second boot counter nobody knew was enabled, T014 fixes a watchdog that looks like protection
  and provides none, and T022 deletes a boot configuration file the board never reads.
