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
0x040000  │ (secondary source; verify against the AM335x TRM during implementation)
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

**To verify during implementation** (cheap, and wrong assumptions here are expensive):

1. Which binary names RAUC 1.15.2 actually invokes for the environment, and that `uboot-tools`
   installs all of them — `fw_getenv` may need a symlink.
2. The ROM's raw-image offsets against the AM335x TRM, before trusting 0x80000 (R2).
3. That `genimage` in this tree supports a region outside the partition table
   (`in-partition-table = false`), which is how the environment region gets into the factory image.

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

## Consequences for the spec

Two items in the spec are affected and are handled in `plan.md` rather than silently:

- **FR-001's open choice is now closed**: the boot-selection state is a reserved region, because
  GPT is unavailable (R1). The spec's neutral wording stands; the implementation records the choice.
- **FR-020's "the development certificate MAY be committed"**: nothing is committed. One documented
  command generates a CA and a signing certificate into an ignored directory, and the build copies
  the CA certificate into the image's keyring (R7). FR-020 permits this: it requires only that the
  private key is not committed and that the material is unmistakably development-only, which the
  certificate subjects state in words.
