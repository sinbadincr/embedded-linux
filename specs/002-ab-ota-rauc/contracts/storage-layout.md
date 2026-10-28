# Contract: SD card storage layout

The byte-level contract between `genimage.cfg`, U-Boot, `/etc/fw_env.config`, `/etc/fstab` and
RAUC's `system.conf`. Five files have to agree on these numbers; a disagreement in any one of them
is silent until a device rolls back or stops booting.

## Layout

```
offset      size      what                                        written by
──────────────────────────────────────────────────────────────────────────────────────────
0x000000    512 B     MBR: four primary entries, 0xAA55 signature  flashing only
0x000200    ~511 KiB  unused. The ROM inspects 0x0, 0x20000,       nobody
                      0x40000 and 0x60000 for a raw boot image,
                      so nothing of ours may live there
0x080000    128 KiB   boot-selection state, primary copy           U-Boot, fw_setenv, flashing
0x0A0000    128 KiB   boot-selection state, redundant copy         U-Boot, fw_setenv, flashing
0x0C0000    256 KiB   headroom, unused                             nobody
0x100000    32 MiB    p1  boot, FAT16, bootable, type 0x0C         flashing only
                      MLO, u-boot.img
            512 MiB   p2  rootfs.A, ext4 (128 MiB filesystem)      flashing, rauc install
            512 MiB   p3  rootfs.B, ext4 (128 MiB filesystem)      flashing, rauc install
            256 MiB   p4  data, ext4, mounted rw at /data          the running system
──────────────────────────────────────────────────────────────────────────────────────────
total       ~1.3 GB   minimum medium 2 GB; extra space is unused
```

## Rules

1. **MBR, not GPT.** The AM335x ROM reads the MBR and looks for a bootable FAT partition; on a GPT
   medium it finds only the protective 0xEE entry and never loads `MLO`. This is why the
   boot-selection state is a reserved region and not a fifth partition: the four primaries are
   spoken for. See [research.md](../research.md) R1.
2. **Partition 1 starts at 1 MiB.** Anything earlier would collide with the state region.
3. **`ENV_OFFSET` is set explicitly.** Its `ARCH_OMAP2PLUS` default is `0x260000`, which is inside
   partition 1. Enabling `ENV_IS_IN_MMC` without overriding it corrupts the boot partition.
4. **The state region is in the factory image.** `genimage` places it outside the partition table
   (`in-partition-table = false`) and writes `uboot-env.bin` at both offsets. That file is built by
   `BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE` from `uboot-env.txt`, so a freshly flashed device boots
   with `BOOT_ORDER="A B"` and full counters, and `fw_printenv` can read the state on the first
   boot. Seeding is not a nicety: `fw_printenv` cannot see U-Boot's built-in default environment,
   so an unseeded region fails the health check of FR-012 immediately.
5. **The boot partition is written only by flashing.** No update touches `MLO` or `u-boot.img`
   (FR-004). The state region is not part of it, so writing the state never risks the bootloader.
6. **The slot filesystem is smaller than the slot.** 128 MiB of ext4 inside a 512 MiB partition.
   RAUC writes the filesystem image; the remainder of the partition is unused headroom for a larger
   filesystem later.

## The five files that must agree

| File | What it fixes |
|---|---|
| `board/ota/beaglebone_black/genimage.cfg` | every offset and size above, and the reserved region |
| `board/ota/beaglebone_black/uboot.config` | `ENV_OFFSET=0x80000`, `ENV_OFFSET_REDUND=0xA0000`, `ENV_SIZE=0x20000`, `ENV_MMC_DEVICE_INDEX=0` |
| `board/ota/beaglebone_black/fw_env.config` | the same two offsets and size, as seen from Linux |
| `board/ota/beaglebone_black/rauc-system.conf` | `/dev/mmcblk0p2` and `/dev/mmcblk0p3` as the two slots |
| `board/ota/beaglebone_black/rootfs_overlay/etc/fstab` | `/dev/mmcblk0p4` at `/data`, root read-only, tmpfs for volatile state |

`scripts/check.sh` asserts what it can without hardware: that the offsets in `genimage.cfg`,
`uboot.config` and `fw_env.config` are the same numbers, and that the kernel is inside the slot
rather than listed among the boot partition's files.

## Known risk: device naming

`/dev/mmcblk0` is the SD card when the board boots from SD, but SD and eMMC enumeration can swap.
`fw_env.config`, `fstab` and `system.conf` all name `mmcblk0` literally. If enumeration ever
changes, the health check of FR-012 fails on its fourth condition — the state is not writable — and
the device rolls back rather than silently misbehaving. That is the designed failure mode, not a
mitigation; a mitigation would generate these files from the actual root device at boot.
