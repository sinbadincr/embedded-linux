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
`/data`. The bench is a direct cable: the host holds `192.168.0.1/24`, the board configures
`192.168.0.2/24` itself at boot (no `udhcpc`: nothing answers DHCP on that cable). On the host, in
`output/beaglebone_black/images/`, run `python3 -m http.server 8000 --bind 192.168.0.1`; on the board,
`ping -c 3 192.168.0.1` first, then
`wget -O /data/<bundle>.raucb http://192.168.0.1:8000/<bundle>.raucb`, and compare the size with
`ls -l`. Do not set the clock:
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

Five trials. The bundle installed must be a *different* revision from the running one, or "the
previous version" cannot be told from a half-written new one. Run the newest image and install an
older bundle (a downgrade is permitted); keep it on the host in its own directory and serve that
directory. On the board, once: `wget -O /data/old.raucb http://192.168.0.1:8000/<older>.raucb` and
check the SHA-256.

Each trial: start `rauc install /data/old.raucb`, watch the console, and **pull the power** (not
`reboot`, not `sysrq`) when the point below is on screen. The last progress line before the board
goes silent is the point of interruption; keep the whole serial capture, not a copy of the answers.

| Trial | Cut at |
|---|---|
| 1 | before the first write: within a second of pressing Enter, during the signature check or the pre-install handler (about 1 s) |
| 2 | early in the write: 46% to 55% `Copying image`, about a second after `Marking ... (bad)`. The 80 ms between that line and the first write is not reachable by hand; the state it leaves is the same |
| 3 | mid-write, about 70% |
| 4 | late in the write, about 90% |
| 5 | in the pause at 99%, before `Copying image ... done` (about 4 s) |

Optional sixth, different outcome: right after `Marking target slot ... as bootable`. The install
has completed by then, so the board correctly boots the *new* version; this is not a failure.

After each, power on and let it boot with no hand on the keyboard until the login prompt:

```sh
cat /etc/build-info         # the PREVIOUS version, every time
rauc status                 # booted the previously good slot, good
mount | grep ' / '          # ro, intact
fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT   # the interrupted slot is not in BOOT_ORDER
cat /data/keep              # unchanged
```

The console must also show `OTA: booting slot <the old one>` and `ota-health: ... confirmed good`.
Trials chain without cleanup: the pre-install handler lets a device with nothing pending install
again, whatever the other slot holds. Five out of five must pass. Finish with one uninterrupted
install of the same bundle: a slot left half-written must take a good install (FR-015).

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

Two different things are being tested, with the times in `contracts/boot-interface.md`.

**A. The system stops working after it was confirmed** (the feeder, at most 30 s). On a running,
confirmed slot:

```sh
ps | grep '[w]atchdog'                # the BusyBox feeder is there
ls -l /proc/$(pidof watchdog)/fd      # descriptor 3 is /dev/watchdog
killall -9 watchdog                   # no "magic close": the watchdog stays armed
# expected: the board resets by itself within 30 s, boots the same slot, and confirms it again
```

and a hung kernel (`CONFIG_MAGIC_SYSRQ` is on, `panic=0` means it hangs rather than reboots):

```sh
echo c > /proc/sysrq-trigger         # expected: dead console, then a reset within 30 s (24 s measured)
```

**B. A slot that never confirms is retired** (the attempt counter, about 50 s per reset). Install a bundle
whose init is made to hang before `S99ota-health` (the way to make one without a rebuild is to write
a copy of its `rootfs.ext4` with `debugfs -w` and re-sign it), reboot, and leave the board alone:

```
expect: a reset about 50 s after each kernel start, BOOT_<slot>_LEFT counting 3 -> 2 -> 1 -> 0,
        then the other slot, good, with nobody touching anything
```

Three trials of B, since that is SC-014; A is the quick check that the feeder is real. A "before" run
of the unmodified image (the build before `early_enable`, whose watchdog is stopped at 0.47 s) shows
the difference: it never resets.

## 7. Untrusted and broken bundles are refused — SC-004, FR-016..FR-019

Five bundles, each of which the device must refuse *before* anything is written, with a message that
tells the five apart, and `rauc status` plus both slots unchanged afterwards. A sixth, genuine one is
the control: it shows that a refusal is about the bundle and not about the setup.

### Making them

In the build container (`make docker-shell`), after the board has been built once and
`make ota-dev-keys` has been run:

```sh
sh scripts/make-untrusted-bundles.sh              # the selected board, or: ... beaglebone_black
ls output/beaglebone_black/untrusted/
```

It writes six files named `<board>-<revision>-<case>.raucb`, prints the size and SHA-256 of each, and
shows what `openssl` makes of its signature against the device's CA. The hashes change on every run (a
CMS signature is not reproducible), so compare the hash on the board with the one printed for the file
you copied. Nothing here is committed; the second CA's keys are in the same ignored directory.

| Case | How it is made | Host `openssl` against the device's CA | What the device said (2026-10-30) |
|---|---|---|---|
| `good` (control) | the genuine bundle, signed by the development material | signature and chain verify | installs; it is a genuine bundle of the running revision |
| `unsigned` | the genuine bundle with its signature cut off and a zero-length trailer | no signature | `Invalid bundle format: Signature size is 0`; stops before any signature check |
| `wrongca` | a **second CA and signing pair**, generated with `scripts/gen-dev-keys.sh` into `output/<board>/untrusted/other-ca/`, signs a bundle with the same `rauc bundle --cert/--key` call as `post-image.sh` | unable to get local issuer certificate | `signature verification failed: Verify error: unable to get local issuer certificate` |
| `altered` | the genuine bundle with one payload byte (offset 1 MiB) inverted, signature untouched | content verify error | `signature verification failed: ... CMS routines::verification failure` (content, not chain) |
| `wrongboard` | valid signature, `compatible=ota-other-board` | signature and chain verify | `Compatible mismatch: Expected 'ota-beaglebone-black' but bundle manifest has 'ota-other-board'`; refused after the mount and the pre-install handler, nothing written |
| `nousage` | a certificate **issued by the device's own CA** but without the Code Signing usage, so the chain is good and only the purpose is wrong | signature and chain verify (the host does not apply RAUC's purpose check) | `Signer certificate does not specify extended key usage code signing`, then `Verify error: unsuitable certificate purpose` (`check-purpose=codesign`) |

Two details behind the table, because both would otherwise make a case test the wrong thing:

- The `nousage` certificate is dated from the CA's own `notBefore` with `openssl ca -startdate`. Issued
  with `openssl x509 -req` it would carry today's date, later than the build of the image on the board,
  and the device would refuse it as *not yet valid* instead of by purpose (the gap in research R8).
- The `wrongca` certificates are dated today too, but the chain error comes first: with the board's clock
  modelled as the image's build time, OpenSSL still reports "unable to get local issuer certificate".

The right-hand column is the wording the device printed on 2026-10-30 (`docs/logs/t037-untrusted-bundles.log`);
the control had not been run yet.

### Running them

On the host, serve the directory that holds the bundles and the board-side helper:

```sh
cd output/beaglebone_black/untrusted && python3 -m http.server 8000 --bind 192.168.0.1
```

On the board, once per boot, fetch the helper and load it; then one command per bundle:

```sh
wget -O /tmp/try.sh http://192.168.0.1:8000/try-bundle.sh && . /tmp/try.sh
try_bundle beaglebone_black-<revision>-unsigned.raucb
```

`try_bundle` (from `scripts/try-bundle-on-board.sh`) works out which slot is running and which one an
install would write, records the boot-selection state and a checksum of the first 128 MiB of that slot,
downloads the file and prints its SHA-256 (compare it with the one the build container printed),
runs `rauc install` and shows its message and exit status, then says whether the state and the slot
are `UNCHANGED`, and ends with `RESULT: refused` or `RESULT: installed`. Paste the whole output of each
call. Type the commands yourself or paste them without comments: a comment pasted into the serial
console is typed into it too.

Run the five refused ones first, the control (`good`) last: it installs into the other slot, which is a
real update and changes the state. Expected: five different messages, five `UNCHANGED` pairs, five
`RESULT: refused`, and a control that ends `RESULT: installed`. Then `reboot` once and let the control
run: it should boot, confirm itself, and `cat /etc/build-info` shows its revision.

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
