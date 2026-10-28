# Phase 0 Research: A/B Atomic OTA Update

Six questions had to be settled before the design could be written. Every finding below was
checked against the pinned sources in this tree (`buildroot/`, `output/beaglebone_black/build/`)
or against the measured baseline in `docs/boot-baseline-beaglebone-black.md`, not against memory.

## R1. Partition table: MBR or GPT, and where the boot-selection state lives

**Decision**: MBR with four primary partitions, and the boot-selection state in an **unpartitioned
reserved region** before the first partition, not in a partition of its own.

**Rationale**: the AM335x boot ROM reads the MBR, checks the 0xAA55 signature and then looks
through the partition entries for a bootable FAT partition. A GPT medium presents only a
protective MBR with a single 0xEE entry, so the ROM finds no FAT partition and never loads `MLO`.
That closes the door FR-001 left open: with GPT unavailable and all four MBR primaries spoken for
by boot, rootfs.A, rootfs.B and data, the state cannot be a partition, so it becomes a reserved
region and `genimage` must be told to keep it out of the partition table.

**Alternatives considered**:

- *GPT with a state partition*: semantically the nicest (every tool sees the region is taken, which
  is how Android's `misc` partition works) but it costs the ability to boot.
- *ROM raw boot mode plus GPT*: the ROM's raw mode does boot from a GPT medium, since it ignores
  the partition table and reads the image from a fixed offset. Rejected: it moves `MLO` to a raw
  offset, abandons the FAT boot partition the board already uses, and those same fixed offsets are
  where the state region would want to live.
- *An extended/logical partition for the state*: a path almost nobody walks with this ROM and this
  bootloader, for no gain over a reserved region.

**Follow-up**: the exact reserved offsets depend on where the ROM looks for a raw image, which is
R2. One caveat worth carrying into implementation: a FAT volume-size field written by some
`mkfs.fat` versions has been reported to stop an AM335x from booting. The current image boots, so
the container's `dosfstools` is fine today; if the boot partition stops being found after a
`dosfstools` bump, look there first.

## R2. Relocating the U-Boot environment out of FAT

**Decision**: `ENV_IS_IN_MMC` on device 0 with a redundant copy, primary at **0x80000** and
redundant at **0xA0000**, each `ENV_SIZE` 0x20000 (the value already configured); the first
partition starts at 1 MiB. `/etc/fw_env.config` names the same two offsets. The factory image
ships this region already populated.

```
0x000000  MBR (sector 0)
0x000000  ┐
0x020000  │ offsets where the ROM looks for a raw boot image: 0, 128K, 256K, 384K
0x040000  │ (corroborated below, not read from the TRM directly)
0x060000  ┘
0x080000  environment, primary        128 KiB
0x0A0000  environment, redundant copy 128 KiB
0x0C0000  unused headroom             256 KiB
0x100000  partition 1 (boot, FAT) begins at 1 MiB / sector 2048
```

**Rationale**: the baseline log shows the board running
`CONFIG_ENV_IS_IN_FAT` with `uboot.env` on `mmc 0:1`, a file that does not exist yet, so U-Boot is
using its built-in default environment. Two reasons to move it:

1. Every boot attempt decrements `BOOT_<slot>_LEFT` and writes the environment. In FAT that write
   lands in the same filesystem as `MLO` and `u-boot.img`, and vfat has no journal, so an
   interrupted write can cost the device its bootloader. SC-002 requires surviving five power cuts.
   A raw redundant environment is the mechanism designed for exactly that.
2. Writing it from Linux would otherwise require mounting the boot partition read-write, which
   contradicts a read-only OS slot and opens the bootloader's filesystem to every process.

0x80000 sits past all four offsets the ROM inspects for a raw image, which is why it is the
conventional choice on this SoC, and it is comfortably inside the 1 MiB gap before partition 1.

**Confirmation status of those four offsets** (T006): four independent secondary sources agree on
0x0, 0x20000, 0x40000 and 0x60000, each 128 KiB, and one quotes the TRM section for raw-mode MMC/SD
boot (SPRUH73 section 26.1.8.5.5). The TRM itself has still not been read, so this is corroboration
rather than proof. The only thing this design needs from it is that 0x80000 sits past all four,
which it does by 128 KiB, and nothing of ours is placed below 0x80000.

**Correction to an earlier claim in this feature's discussion**: `fw_setenv` *can* address an
environment stored as a file in a FAT filesystem — `tools/env/fw_env.config` in U-Boot 2026.07
carries a "VFAT example". The reason to move the environment is power-fail atomicity, not tool
support.

**Symbol names**: RAUC's integration guide still names `CONFIG_SYS_REDUNDAND_ENVIRONMENT`, which no
longer exists. The symbols actually present in `output/beaglebone_black/build/uboot-2026.07/env/Kconfig`
are `ENV_IS_IN_MMC`, `ENV_OFFSET`, `ENV_OFFSET_REDUND`, `ENV_REDUNDANT`, `ENV_MMC_DEVICE_INDEX` and
`ENV_SOURCE_FILE`. Copying configuration out of the RAUC docs will not work.

**A trap to avoid**: `ENV_OFFSET` defaults to `0x260000` for `ARCH_OMAP2PLUS`. That is 2.5 MiB,
which lands *inside* partition 1 in this layout. Enabling `ENV_IS_IN_MMC` without setting the
offset explicitly would silently corrupt the boot partition after a few updates.

**How the environment text file reaches both places, without a script**: Buildroot has two options
for this and neither was in the first draft of this plan, which proposed hand-rolling `mkenvimage`
in `post-image.sh`. Principle III prefers an upstream mechanism over custom scripting, and here
there are two:

- `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE` takes a path to the text file, resolves it, and sets
  `CONFIG_ENV_USE_DEFAULT_ENV_TEXT_FILE` plus `CONFIG_ENV_DEFAULT_ENV_TEXT_FILE` — both of which
  exist in U-Boot 2026.07 (`env/Kconfig` lines 800 and 810). The file becomes U-Boot's built-in
  default environment.
- `BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE`, with `_SOURCE` pointing at the same file, `_SIZE` at
  `0x20000` and `_REDUNDANT` enabled, produces `uboot-env.bin` in `BINARIES_DIR` for `genimage` to
  write into the reserved region.

Note that there is no `BR2_TARGET_UBOOT_ENVIMAGE`; the option lives under `host-uboot-tools`.

U-Boot's own `CONFIG_ENV_SOURCE_FILE` cannot be used: its help states the file "must be in the
board directory and have a .env extension", inside the U-Boot source tree, and that "if the file
is not present, an error is produced". Pointing it at the external tree is not possible, so using
it would mean shipping the boot logic inside a patch instead of as a reviewable file.

**The default environment is compiled into the SPL too, and the SPL has a hard ceiling** (found by
building, not by reading). On this board `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE` alone breaks the link:

```
arm-linux-ld: u-boot-spl section `__u_boot_list' will not fit in region `.sram'
arm-linux-ld: region `.sram' overflowed by 512 bytes
```

Two controlled builds isolate it: the upstream `am335x_evm` configuration links cleanly as a custom
config, and the same configuration with a 2916-byte environment text file does not. None of the
environment or command options added for this feature is responsible; bisecting them all left the
failure in place.

The fix is to stop the SPL carrying what this board cannot use: `# CONFIG_SPL_NET is not set`. The
SPL was compiling TFTP, NFS and Ethernet support for a board that boots from an SD card. `MLO`
drops from 110928 to 79008 bytes, which both makes room for the environment and leaves headroom for
the boot script to grow. Principle VI asks for exactly this — enable only what the board needs.

Rejected alternatives: shrinking the environment text to fit, which would break again the next time
the boot script grows, and at a moment nobody is watching; dropping the compiled-in default
environment and seeding only the region, which gives up the "environment corrupt or missing" edge
case because U-Boot would fall back to an upstream default that looks for the `extlinux.conf` this
feature deletes; and moving the logic into a `boot.scr` on the FAT partition, which still needs a
built-in environment to find and run it.

If more SPL room is ever needed, `SPL_NAND_*` (the boot log records `NAND: 0 MiB` on this board),
`SPL_USB_ETHER`/`SPL_USB_ETH_RNDIS` and `SPL_YMODEM_SUPPORT` are all unused here. They were left
alone because nothing needs them removed yet.

Both mechanisms are needed, because they fail differently. The built-in default is what boots the
board when the reserved region is unreadable. The seeded region is what the running system reads:
`fw_printenv` has no access to U-Boot's built-in default, so an unseeded region fails the fourth
condition of FR-012 on the first boot and every update would roll back.

**Alternatives considered**:

- *Environment at the end of the medium* (`ENV_OFFSET_REDUND_RELATIVE_END`, negative offsets):
  avoids the gap arithmetic, but the region then falls outside the 1.3 GB factory image, so a
  freshly flashed device has no environment and its absolute position changes with the size of the
  card.
- *Leaving the environment in FAT*: cheapest, and upstream RAUC does list `CONFIG_ENV_IS_IN_FAT` as
  a legal choice, but it fails the power-cut requirement above.
- *An eMMC hardware boot partition*: out of scope, this board boots from SD.

## R3. Filesystem for the read-only OS slot

**Decision**: **ext4, mounted read-only**, as a 128 MiB filesystem inside each 512 MiB slot. RAUC
slot type `ext4`.

**Rationale**: the obvious companion to a read-only slot is a read-only filesystem, but
`output/beaglebone_black/build/linux-6.18.38/.config` has `# CONFIG_SQUASHFS is not set`. The
kernel support is only the smallest part of that cost: squashfs also changes the rootfs image
produced by Buildroot, the slot type RAUC writes, and how the slot's size relates to its contents.
Doing it in the same change as the layout, the bootloader environment and the rollback path would
make a failure hard to attribute. ext4 mounted read-only satisfies FR-006 today.

Sizing: the measured rootfs content is 29.5 MiB and `zImage` is 7.29 MiB, so a slot holds about
37 MiB once the kernel moves in. The current `BR2_TARGET_ROOTFS_EXT2_SIZE` of 60 MiB would be at
62% — under the 80% ceiling but with little room for the data a real feature would add. 128 MiB
puts it near 30% and still writes in seconds.

**Alternatives considered**:

- *squashfs now*: smaller slots, smaller bundles, and read-only by construction rather than by
  mount option. Deferred, not rejected: worth doing once A/B is proven, and it becomes cheaper
  because this feature already introduces a custom kernel configuration (R5).
- *A 512 MiB filesystem filling the slot*: no benefit, and every install would write 512 MiB.
- *dm-verity on the slot*: needs kernel device-mapper support this configuration lacks, and
  verified boot is explicitly out of scope.

## R4. One boot counter, not two

**Decision**: count attempts only in `BOOT_<slot>_LEFT` in the environment. Turn off the inherited
`CONFIG_BOOTCOUNT_LIMIT` and `CONFIG_BOOTCOUNT_AM33XX` in the board's U-Boot configuration.

**Rationale**: the board's current U-Boot configuration already has `CONFIG_BOOTCOUNT_LIMIT=y` and
`CONFIG_BOOTCOUNT_AM33XX=y`, inherited from `am335x_evm`, held harmless only because
`CONFIG_BOOTCOUNT_BOOTLIMIT=0`. That counter lives in an RTC scratch register, and this board has
no RTC backup battery, so it is lost on power removal — the very event SC-002 exercises five times.
Leaving a second counter configured invites someone to enable it later and produce a device with
two disagreeing answers to "how many attempts are left". FR-003 forbids it.

**Alternatives considered**: using the SoC counter as the primary mechanism (rejected: not
power-fail safe here, and RAUC's U-Boot interface does not read it); leaving it configured but
disabled (rejected: FR-003, and it is one grep away from being switched on by accident).

## R5. Marking a slot good, and catching a hang, under BusyBox init

**Decision**: one init script late in the BusyBox sequence checks the four conditions of FR-012,
calls `rauc status mark-good`, and only then starts the watchdog feeder. The kernel is configured
to stop covering an already-running watchdog after a bounded grace period, so the window before
that script runs is covered too.

**Rationale**: RAUC's documentation assumes systemd — *"It is a good idea to wait for the system to
be fully started before marking it as successfully booted"*, implemented as a service ordered after
the others. This image uses BusyBox init, so the equivalent is an `S99` script; the principle
survives, only the mechanism changes.

The hang half needs a kernel change, and the baseline explains why.
`output/beaglebone_black/build/linux-6.18.38/.config` has:

```
CONFIG_WATCHDOG=y
CONFIG_WATCHDOG_CORE=m
CONFIG_OMAP_WATCHDOG=m
CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y
CONFIG_WATCHDOG_OPEN_TIMEOUT=0
```

U-Boot starts the watchdog with a 60 s timeout, as the baseline log shows. With
`HANDLE_BOOT_ENABLED=y` and an open timeout of 0, the kernel takes over an already-running
watchdog and pings it **indefinitely** while no userspace process has opened `/dev/watchdog`. A
device that boots and then hangs is therefore never reset, which is precisely the failure FR-032
rules out. The watchdog looks like protection and provides none.

The configuration this feature needs: the core and the driver built in rather than modules, so the
window between kernel start and module loading is not a gap, and a non-zero
`CONFIG_WATCHDOG_OPEN_TIMEOUT` so the kernel's courtesy pings stop if userspace never claims the
device. After the health script claims it, keeping the device alive depends on a userspace process
continuing to run, which is what FR-032 asks for.

The feeder itself is the BusyBox `watchdog` applet, already enabled in this image's BusyBox
configuration, so no new package is needed.

**Measured on hardware (T016), and not yet working**: with the kernel configuration above in place,
the board sat at an idle shell for 253 seconds with no userspace watchdog client and was never
reset, although U-Boot reports starting the watchdog with a 60 second timeout and the kernel
registers `omap_wdt`. So the configuration change is necessary but not sufficient, and FR-032 is not
satisfied yet. Three things to check when T032 lands, in order of likelihood: whether U-Boot stops
the watchdog before handing over, whether `omap_wdt` reports the device as already running so
`WATCHDOG_HANDLE_BOOT_ENABLED` has anything to take over, and whether the open timeout applies only
to a device the kernel itself started. Evidence in `docs/logs/t016-env-agreement.log`.

**Alternatives considered**:

- *The `watchdog` package* (in Buildroot, supports test and repair scripts): a better fit once there
  is an application whose health is worth testing. Today it would only wrap the same checks the
  init script already makes.
- *Feeding the watchdog from early init*: rejected, it restores exactly the "looks like protection"
  situation above.
- *No watchdog, rely on the attempt counter alone*: rejected by FR-032; the counter only acts at
  boot, so nothing would ever reboot a hung device.

## R6. Bundle format and the tools around it

**Decision**: RAUC 1.15.2 from the pinned Buildroot tree, `plain` bundle format, bundles produced
at build time by `host-rauc`, environment access on the device through `fw_printenv`/`fw_setenv`
from `uboot-tools`.

**Rationale**: `buildroot/package/rauc/` carries RAUC 1.15.2 with a `host-rauc` variant for
creating bundles, selects `squashfs` as a runtime dependency (a bundle *is* a signed squashfs), and
its help text states plainly that *"The U-Boot bootloader support requires fw_getenv / fw_setenv
from uboot-tools"*, so `BR2_PACKAGE_UBOOT_TOOLS_FWPRINTENV` is the matching option. No internal
package has to be written and no new hash file is needed: every new dependency is an upstream
Buildroot package with its own hash, and the kernel and U-Boot versions do not change.

`plain` is chosen because it needs nothing from the kernel. The `verity` format and streaming
installs want device-mapper support this configuration does not enable, and streaming is pointless
while bundle delivery is out of scope.

**What the U-Boot backend actually does** (T008, read from `src/bootloaders/uboot.c` at the 1.15.2
tag). Two of these change the boot script and one removes a packaging worry:

- It runs exactly two binaries, `fw_printenv` with a variable name and `fw_setenv` with a name and
  value, through `r_subprocess_new()`. There is no `fw_getenv` in the backend at all, so
  `BR2_PACKAGE_UBOOT_TOOLS_FWPRINTENV` is sufficient and no symlink is needed. Buildroot's package
  help, which says "fw_getenv / fw_setenv", is imprecise.
- **`BOOT_<slot>_LEFT` is stored as a hexadecimal string.** The boot script and the seeded
  environment must agree with that reading. It makes no difference for a single-digit counter and
  would for a limit above 9.
- **Marking a slot bad removes it from `BOOT_ORDER`** as well as setting its counter to 0, and a
  slot counts as good only when it is *listed in* `BOOT_ORDER` with a counter above zero. The
  exhausted-slots path in the boot script therefore has to handle `BOOT_ORDER` being short or
  empty, not merely every counter being zero.
- Marking good restores the counter to the configured attempts, defaulting to 3
  (`UBOOT_DEFAULT_ATTEMPTS`), and making a slot primary moves it to the front of `BOOT_ORDER` with
  the same default. The attempt limit assumed in the spec is RAUC's own default.

**Still to verify during implementation**: nothing from this list remains. The ROM offsets (R2) are
corroborated, `genimage` support for a region outside the partition table is confirmed against
version 20 in this tree and recorded with its exact syntax in
[contracts/storage-layout.md](contracts/storage-layout.md), and the environment binaries are settled
above.

## R7. Development signing material: a two-tier CA, not a single self-signed key

**Decision**: `make ota-dev-keys` generates **two** pairs into the ignored `keys/dev/` directory —
a CA (`dev-ca.key.pem`, `dev-ca.cert.pem`, `CA:TRUE`, ten years) that only ever certifies other
keys, and a bundle-signing pair (`dev-signing.key.pem`, `dev-signing.cert.pem`, `CA:FALSE`,
`codeSigning`, five years) certified by that CA. The device keyring holds the **CA** certificate;
the signing certificate travels inside each bundle's CMS signature. Neither private key is
committed, and the certificates are generated rather than committed. See
[contracts/signing-chain.md](contracts/signing-chain.md).

**Rationale**: RAUC documents three PKI strategies, and the difference between them is whether a
key can ever be replaced without reflashing every device. With a single self-signed key, the
certificate in the keyring *is* the signing certificate, and RAUC states plainly that you then
"can't replace expired certificates without updating the keyring" and "can't revoke a compromised
key". The keyring lives in the rootfs, so updating it means reflashing. With a CA in the keyring,
a lost or compromised signing key is answered by issuing a new certificate, and the devices do not
change. That difference cannot be retrofitted: moving from a single key to a CA later invalidates
every card already flashed, so the structure has to be right in this feature even though only one
environment exists today.

No `--intermediate` argument is needed. The chain is two levels, and `rauc bundle --cert` already
embeds the signing certificate in the CMS signature; `--intermediate` is for closing a chain that
has a CA *between* the signing certificate and the trust anchor. RAUC is explicit that
intermediates "should not be added to the keyring", which is only for trust anchors.

**Alternatives considered**:

- *One self-signed key, certificate committed*: the shortest path, and what this feature's
  clarification log originally pictured. It cannot work as described: a committed certificate is
  only useful if every developer shares the matching private key, which FR-020 forbids, so an image
  built from the committed certificate would reject the bundles of the developer who generated
  their own key.
- *One self-signed key, nothing committed*: coherent, and what the plan said before this round.
  Rejected because of the reflash trap above.
- *A three-tier chain (root, per-environment CA, signing certificate)*: the right shape if several
  environments shared one root, but RAUC's "Separate CAs" strategy is the opposite — each device
  carries only its own environment's CA, which is exactly the isolation wanted — so a third tier
  buys nothing here.

**Build-time plumbing**: three variables resolve the material, defaulting to `keys/dev/`, so a
later feature can point them at staging or production material, or at PKCS#11 URLs for an HSM,
without touching a script: `OTA_KEYRING` (read by `post-build.sh`, installed as
`/etc/rauc/keyring.pem`), `OTA_SIGNING_CERT` and `OTA_SIGNING_KEY` (read by `post-image.sh`). RAUC
accepts PKCS#11 URLs in place of filenames for `--cert` and `--key`, so that path needs no new code.

**Consequence to document**: a bundle installs only on an image built with the same key. That is
what a trust domain means, and it is the behaviour staging and production separation relies on.

## R8. Getting a bundle onto the board, and the clock that rejects it

Found while preparing T029, before any hardware run. Both points are about what happens *between*
a built bundle and a successful `rauc install`, which the spec deliberately leaves to the operator
(FR-010: "a bundle already present on local storage"; Assumptions: delivery is the operator's
problem).

### Delivery path

**Decision (working default for US2)**: bring the interface up by hand and fetch with BusyBox
`wget` from the build host. Nothing in the image changes.

```sh
# on the build host, in output/beaglebone_black/images/
python3 -m http.server 8000
# on the board
udhcpc -i eth0
wget -O /data/<bundle>.raucb http://<host-ip>:8000/<bundle>.raucb
```

**Why**: the image has no SSH server, `nc`, `ftpget`, `httpd` or `telnetd`, and RAUC is built
without libcurl, so `rauc install https://...` is unavailable and only local files install. BusyBox
does have `wget`, `tftp` and `udhcpc`. `BR2_SYSTEM_DHCP` is empty, so `eth0` is down after boot;
bringing it up by hand costs nothing at boot. Setting `BR2_SYSTEM_DHCP="eth0"` would make the
network script wait for a lease on every boot, which is a SC-008 risk (T025 passed at 10.51 s of a
12.65 s budget) and would need a re-measurement, so it is not done here. A DHCP client opens no
listening port, so Principle VII is not at stake either way.

**Fallbacks**, none tested: a USB stick (`usb-storage.ko` and `musb_hdrc.ko` are in the image, ext4
and vfat are built in), or pulling the card and copying onto p4 from the host (p4 is ext4 at byte
offset 1108344832). Pulling the card five times is not realistic for T030, which is why the
network path is preferred.

The bundle size is an estimate (15-20 MB, from the 14.7 MB compressed image of the baseline).
T026 gives the real number; `/data` is 256 MiB.

### The clock rejects the signing certificate

`rauc install` checks the certificate validity period against the system clock. In RAUC 1.15.2
`install.c:1569` calls `check_bundle(..., CHECK_BUNDLE_DEFAULT, ...)`; the `--no-check-time` flag
exists for `rauc resign` and `rauc info` only, not for `rauc install`. The board has no RTC backup
and cold-boots at 2000-01-01T00:00:00 UTC (measured twice, `docs/logs/t016-env-agreement.log` and
`docs/logs/t024-us1-second-capture.log`). The development certificates carry `notBefore`
2026-10-28 05:31:03 GMT. So the first `rauc install` on a freshly booted board fails with a
"not yet valid"-type error. This is not a staging/production concern: it happens with the
development keys, on the first install.

| Option | What it is | Verdict |
|---|---|---|
| A | `date -s "2026-10-28 18:00:00"` (any time after the certificates' `notBefore`) before `rauc install` | Superseded by B. No code; an operator step, not a fix. It stays valid as a manual override on a device whose image predates its certificate (see below) |
| B | An early init script that raises the clock to the image build time when it is earlier (the `fake-hwclock` idea): a `BUILD_DATE` line in `/etc/build-info`, written by `post-build.sh`. `check_keys` forces the keys to exist before the build, so a certificate generated before the build is valid at that time | **Adopted in this feature (T046), approved 2026-10-28.** Every board without an RTC cold-boots into the past, so the fix belongs in the image, not in an operator step. The clock no longer starts in 2000, which is a deliberate system-behaviour change recorded as FR-033 |
| C | Generate the certificates with `notBefore` at or before 2000-01-01 | Rejected: needs `openssl ca -startdate` and a config file because OpenSSL 3.0 `x509 -req` has no `-not_before`, and it hides the problem instead of removing it |
| D | libfaketime in the build container | Rejected: affects only the host, and the failing check runs on the board |

### What option B does, and what it does not

`post-build.sh` writes `BUILD_DATE=<epoch seconds>` (plain `date -u +%s`, taken at build time) into
`/etc/build-info`. `board/ota/common/rootfs_overlay/etc/init.d/S00ota-clock` runs before every other
init script and, only when `date +%s` is smaller than `BUILD_DATE`, sets the clock to it with
`date -u -s @<BUILD_DATE>` (BusyBox 1.38 accepts `@seconds`, `libbb/time.c`) and logs one line to
the console. A clock already past the floor is never touched, so a board with a working RTC, or one
that has been given real time, is unaffected.

- **It is a floor, not the real time.** Log timestamps stay wrong by however long the device was off.
  Real time needs an RTC or a time source (NTP over a network the device does not have today). That
  is a separate feature and nothing here depends on it.
- **`SOURCE_DATE_EPOCH` is not used.** It is a commit time under a reproducible build and can
  predate the certificate. The build time cannot, because `check_keys` refuses to build without
  the keys, so the certificate was issued before the floor was taken.
- **One gap remains.** If the signing certificate is re-issued from the same CA (the loss row of
  the table in `contracts/signing-chain.md`) *after* the image on the device was built, the
  certificate's `notBefore` is later than the device's floor, and `rauc install` refuses the new
  bundle until the clock passes it. The device never has a clock later than its own build time
  unless something sets it. Handle it by setting the clock by hand once (option A), or by
  rebuilding the running image after the re-issue. A device with real time is not affected.
- **Cost.** One shell script of a few lines at the start of boot. SC-008 is re-measured by T043
  rather than assumed unchanged.

The spec's edge case "Clock far from real time" still asks for a clear error when the clock really
is outside the window, which RAUC gives; B removes the *common* cause of it, not the error.

## Consequences for the spec

Two items in the spec are affected and are handled in `plan.md` rather than silently:

- **FR-001's open choice is now closed**: the boot-selection state is a reserved region, because
  GPT is unavailable (R1). The spec's neutral wording stands; the implementation records the choice.
- **FR-020's "the development certificate MAY be committed"**: nothing is committed. One documented
  command generates a CA and a signing certificate into an ignored directory, and the build copies
  the CA certificate into the image's keyring (R7). FR-020 permits this: it requires only that the
  private key is not committed and that the material is unmistakably development-only, which the
  certificate subjects state in words.
