# Quickstart: validating A/B OTA on hardware

How to prove the feature works. Nine scenarios, each naming the success criterion it discharges.
Scenarios 1–3 need one SD card and a serial console; 4 onwards need the ability to cut power.

Record every serial capture under `docs/logs/` and summarise the results in the PR: Principle IV
makes the hardware evidence mandatory, and a green `make check` is explicitly not a boot test.

## Prerequisites

```bash
# host, once
make docker-build
make docker-shell

# inside the container
make beaglebone_black_defconfig
make ota-dev-keys          # once: CA + signing pair into keys/dev/ ; the build names this
                           # command if the key is missing, before it starts building
make build                 # produces sdcard.img and beaglebone_black-<version>.raucb
```

Flashing and serial are unchanged from the README, including holding **S2** at power-on and the
`grabserial` invocation from `docs/boot-baseline-beaglebone-black.md`.

## 1. Flash and boot with redundant slots — SC-005, FR-021

```bash
sudo dd if=output/beaglebone_black/images/sdcard.img of=/dev/sdX bs=4M conv=fsync   # check sdX
```

On the device:

```sh
rauc status                 # booted: rootfs.0 (A), good; rootfs.1 (B) inactive
cat /etc/build-info         # BOARD, VERSION, BUILDROOT of the running slot
mount | grep ' / '          # ro
touch /mnt-test 2>&1        # must fail: read-only root            -> SC-012
touch /data/keep && sync    # must succeed
fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT
```

Expected on a freshly flashed card: `BOOT_ORDER="A"`, `BOOT_A_LEFT` at 3 and `BOOT_B_LEFT` at 0,
because only slot A is populated and the empty slot must never be selected. After the first boot
`BOOT_A_LEFT` reads 2 until the health script confirms the slot and `rauc status mark-good` restores
it to 3, which is the point of the counter. `rauc status` shows slot B as bad, since it is not
bootable. The console names slot A during boot (FR-027).

## 2. Boot time has not regressed — SC-008

Three `grabserial` runs, same method as the baseline. Mean from the SPL banner to the login prompt
must be **≤ 12.65 s** (11.50 s + 10%), or the regression is justified in writing.

## 3. Install an update and confirm it — SC-001, SC-006, FR-006..FR-012

Build a second, visibly different revision (any commit changes `VERSION`), copy its bundle to
`/data` (host `python3 -m http.server`, board `udhcpc -i eth0` and `wget`). Do not set the clock:
the board cold-boots into 2000, and `S00ota-clock` raises it to the image's build time, which is
after the certificate's `notBefore`, so the validity check passes (FR-033, research R8). The
console shows `ota-clock: clock was 2000-01-01 ... raised to image build time ...`; `date` on the
board reads the build time, not the real time. Then:

```sh
rauc install /data/beaglebone_black-<newver>.raucb
fw_printenv BOOT_ORDER      # "B A"
rauc status                 # rootfs.1 pending
reboot
# after reboot
cat /etc/build-info         # the new VERSION
rauc status                 # booted rootfs.1, good; rootfs.0 still holds the old version
cat /data/keep              # unchanged                              -> SC-006
```

Also confirm FR-009: attempt a second `rauc install` between install and reboot; it must be refused
with a message naming the pending state, and `rauc status` must be unchanged afterwards.

## 4. Power loss during install never costs the device — SC-002

Five trials. Start `rauc install`, cut power at a different point each time (early, mid-write,
near the end), then power on normally:

```sh
cat /etc/build-info         # the PREVIOUS version, every time
rauc status                 # booted the previously good slot, good
mount | grep ' / '          # ro, intact
```

Five out of five must pass. Record the point of interruption per trial.

## 5. A broken update rolls back by itself — SC-003, FR-013..FR-015

Build a bundle that cannot boot — the simplest honest break is a bundle whose kernel is replaced
with garbage, so U-Boot loads nothing. Install it, reboot, and watch the console without touching
the board:

```
expect: slot B chosen, BOOT_B_LEFT counts 3 -> 2 -> 1 -> 0 across attempts,
        then slot A chosen and booted
```

On the device afterwards: `rauc status` shows A good and running, B bad, and the reason is readable
from `/data`. Three trials.

## 6. A hung slot is reset and retired — SC-014, FR-032

Install a bundle whose health script is made to hang (or whose init stops before `S99ota-health`).
Reboot and leave the board alone:

```
expect: the watchdog resets the board within the documented window,
        each reset spends one attempt, and the device ends on the previous good slot
```

Three trials. This is the scenario the current image cannot pass at all, because
`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` with an open timeout of 0 makes the kernel ping the
watchdog forever — worth capturing a "before" run on the unmodified image to show the difference.

## 7. Untrusted and broken bundles are refused — SC-004, FR-016..FR-019

Four attempts, each must be refused *before* anything is written, with a distinct message, and
`rauc status` plus both slots unchanged afterwards:

| Bundle | Expected refusal |
|---|---|
| unsigned | no valid signature |
| signed by a second CA and signing pair, generated into a scratch directory with `OTA_SIGNING_*` pointed at it | the chain does not reach the CA in the device keyring |
| a trusted bundle with a byte flipped after signing | integrity failure |
| built with a different `compatible` string | wrong board |

## 8. State written where it cannot be lost — SC-013, FR-014

Make `fw_setenv` fail (point `/etc/fw_env.config` at a wrong offset on a test image). The health
check must fail its fourth condition, the slot must never be marked good, the device must roll
back, and the reason must survive the reboot in `/data`.

## 9. Footprint re-measured — SC-007

From the build host and the device, and then into the README:

```bash
ls -l output/beaglebone_black/images/{sdcard.img,*.raucb}
du -sh output/beaglebone_black/target
```

```sh
df -h /; df -h /data
```

Neither slot nor the boot partition above 80%; `/data` holds at least one bundle with room to
spare; the image still fits a 2 GB card.

## What `make check` covers, and what it cannot

`make check` lints the new scripts, asserts that `genimage.cfg`, `uboot.config` and
`fw_env.config` carry the same offsets, and asserts the kernel lives in the slot rather than the
boot partition. It cannot boot anything. Scenarios 1–9 are manual until this project has an
emulated board, which is the obvious next feature.
