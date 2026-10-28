# Boot baseline: BeagleBone Black (single-slot image)

Boot evidence and timing baseline for the single-rootfs `beaglebone_black` image, captured before
the A/B OTA work in `specs/002-ab-ota-rauc/` changes the storage layout and the boot path.

It serves two purposes:

- the boot smoke test the constitution requires for any change touching the kernel, bootloader,
  device tree, bootargs, partition layout or init (Principle IV);
- the "before" half of the boot-time budget that the same work must not regress by more than 10%
  (Principle VI, and SC-008 of feature 002).

## What was booted

| | |
|---|---|
| Image | `output/beaglebone_black/images/sdcard.img`, 76 MiB |
| Source revision | `6255255` ("Record the paused state of the CI/CD pipeline feature"), clean tree |
| Buildroot | `2026.08-274-gd6061d653d` |
| Kernel | 6.18.38, in-tree `omap2plus` defconfig, `ti/omap/am335x-boneblack` device tree |
| U-Boot | 2026.07, `am335x_evm` defconfig, built 2026-10-26 |
| Medium | SD card, S2 (BOOT) held at power-on |
| Console | serial on header J1, 115200 8N1 |

The image identified itself on the device exactly as built:

```
OTA embedded Linux beaglebone-black /dev/console
beaglebone-black login: root
# uname -r
6.18.38
# cat /etc/build-info
BOARD=beaglebone_black
VERSION=6255255
BUILDROOT=2026.08-274-gd6061d653d
```

That confirms the whole provenance chain end to end: a running device names the commit it was
built from, the kernel version the defconfig pins, and the Buildroot submodule commit. It also
confirms both overlay layers reached the image, `/etc/issue` from `board/ota/common/` and
`/etc/hostname` from `board/ota/beaglebone_black/`.

## Method

Captured with `grabserial`, which timestamps each serial line, so the measurement covers the
bootloader as well — `/proc/uptime` on the device cannot, because it only starts counting when the
kernel does:

```bash
grabserial -d /dev/ttyUSB0 -b 115200 -t -m "U-Boot SPL" -q "login:" \
           -o docs/logs/boot-baseline-runN.log
# power on the board (holding S2) only after grabserial is running
```

`-m "U-Boot SPL"` puts t=0 at the SPL banner and `-q "login:"` stops at the login prompt, so the
figure below is **SPL banner to login prompt**. Three runs, raw logs in `docs/logs/`.

Notes on the raw logs, which are kept exactly as captured:

- `boot-baseline-run3.log` shows the first two lines at 0.000007 and 0.502264 before the clock
  resets at the SPL match. That 0.50 s is ROM to SPL banner, i.e. the part the other two runs do
  not include. Add it for a power-on figure.
- The same file contains one NUL byte emitted by the serial line, so git treats it as binary.
  Grep it with `grep -a`.
- Each line carries `[absolute delta]`; kernel messages add their own `[seconds]` in a second
  bracket, which runs about 4.8 s behind the serial clock because the kernel clock starts at
  handover.

## Result

| Run | SPL banner to login prompt |
|---|---|
| 1 | 11.58 s |
| 2 | 11.45 s |
| 3 | 11.47 s |
| **mean** | **11.50 s** |

Spread is 0.13 s (1.2%), well inside the 10% budget the boot-time rule allows, so the method is
precise enough to detect a real regression. Adding the 0.50 s of ROM time gives **about 12.0 s from
power-on to login prompt**.

### Where the time goes (run 1)

| Phase | Seconds | Note |
|---|---|---|
| ROM to SPL banner | 0.50 | measured in run 3 only |
| SPL loads U-Boot | 0.66 | |
| U-Boot init | 0.67 | DRAM, 164 devices, MMC, Ethernet, watchdog |
| `bootdelay` countdown | **2.08** | pure wait: "Hit any key to stop autoboot: 2 1 0" |
| Scan FAT, load `zImage` + dtb | 0.57 | `/extlinux/extlinux.conf`, then 7.3 MiB `zImage` in 0.49 s |
| "Starting kernel ..." to first kernel message | 1.69 | decompression and pre-console init, no output |
| Kernel and init to login prompt | 5.89 | |
| **Total from SPL banner** | **11.58** | |

## Footprint of the same image

| | Used | Capacity | % |
|---|---|---|---|
| Root filesystem contents | 29.5 MiB (`target/`), 31.9 MiB as a tar | | |
| `rootfs.ext4` | ~39 MiB | 60 MiB filesystem | 65% |
| `rootfs.ext4` inside its partition | 60 MiB | 512 MiB partition | 12% |
| FAT16 boot partition | 9.0 MiB | 16 MiB | 56% |
| `sdcard.img` | 76 MiB | | |

`zImage` alone is 7.29 MiB of the 9.0 MiB used in the boot partition. The 60 MiB filesystem comes
from `BR2_TARGET_ROOTFS_EXT2_SIZE="60M"` and does not grow into the 512 MiB partition that
`genimage.cfg` gives it.

## Findings that feed feature 002

These came out of reading the logs, and each one is a concrete input to `plan.md`:

1. **The U-Boot environment is a FAT file and does not exist yet**:
   `Loading Environment from FAT... Unable to read "uboot.env" from mmc0:1`. U-Boot is therefore
   running its built-in default environment. This matters because A/B slot selection keeps its
   state in that environment and the running system has to write it; `fw_setenv` from
   `uboot-tools` handles raw block-device and MTD environments, not a file inside a FAT
   filesystem. Deciding where the environment lives — and making `/etc/fw_env.config` agree with
   it byte for byte — is the first task of feature 002, because getting it wrong makes every
   update roll back even when the image is perfect.
2. **Booting goes through `extlinux.conf`, not `uEnv.txt`**: the log shows
   `Found /extlinux/extlinux.conf` and no use of `uEnv.txt` at all. The board currently ships two
   boot configurations and uses one. The A/B boot script replaces this path, and `uEnv.txt` can go.
3. **2.08 s of the 11.50 s is the autoboot countdown.** Setting `bootdelay` low in the new
   environment pays for the slot-selection logic several times over, which is worth knowing before
   measuring feature 002 against SC-008.
4. **U-Boot already starts the watchdog** (`WDT: Started wdt@44e35000 ... 60s timeout`) and the
   kernel takes it over (`omap_wdt ... initial timeout 60 sec`). A hardware watchdog plus a boot
   attempt counter is exactly what catches a slot that hangs instead of failing cleanly, so this is
   an asset for the rollback story rather than a detail to ignore.
5. **Slot sizing is not the 512 MiB it looks like.** With the kernel moving inside the OS slot, slot
   contents become about 37 MiB, while the filesystem built into the slot is fixed at 60 MiB and the
   slot partition is 512 MiB. The read-only OS slot that feature 002 settled on also makes a
   compressed read-only filesystem an option, which would shrink both the slot and every update
   bundle. The boot partition, by contrast, only needs the two bootloader stages (about 1.7 MiB)
   once the kernel leaves it.
6. Two benign messages to expect in any future comparison, both present here and unrelated to this
   work: `PM: Cannot get wkup_m3_ipc handle` and
   `PM: bootloader does not support rtc-only!`. The CM3 power-management firmware itself loads
   correctly (`CM3 Firmware Version = 0x192`).

## After the A/B layout (feature 002, User Story 1)

Measured on 2026-10-28 on the image built from commit `a3ce015`, by the method above, from
`docs/logs/boot-baseline-run4.log` to `run6.log`. Same board, same card.

| Run | Path taken | "Starting kernel" | Login prompt |
|---|---|---|---|
| 4 | last resort | 2.918 s | 10.532 s |
| 5 | normal | 2.929 s | 10.525 s |
| 6 | normal | 2.929 s | 10.481 s |
| **mean** | | 2.925 s | **10.512 s** |

The spread is 0.051 s (0.49%). The budget is 12.65 s (the 11.50 s baseline plus 10%), so this
passes with 2.14 s to spare.

Against the baseline it is 0.99 s faster. That is not the A/B machinery speeding anything up, and
it should not be quoted as if it were. Splitting the time at the moment the kernel starts:

| | Baseline | Now | Change |
|---|---|---|---|
| SPL banner to "Starting kernel" | 3.991 s | 2.925 s | -1.066 s |
| "Starting kernel" to login prompt | 7.510 s | 7.587 s | +0.078 s |

The whole gain is the autoboot countdown. `bootdelay` went from 2 to 1 second, and the countdown
fell from 2.08 s to 1.01 s, which is -1.07 s against a total change of -1.066 s. The rest of the
bootloader phase is a wash: the environment now loads from raw MMC rather than from a FAT file, the
kernel and device tree come from `ext4load` rather than a FAT scan, and `saveenv` costs about 11 ms
(run 4 skips it, because it took the last-resort path, and its "Starting kernel" is 11 ms earlier
than runs 5 and 6). Like for like, the A/B boot is therefore about 0.08 s, or 0.7%, slower than the
single-slot one, all of it between kernel start and the login prompt. That 0.08 s has not been
attributed; a `/data` mount with a journal replay after a power cut is one candidate.

Run 4 took the last-resort path ("OTA: no eligible slot, BOOT_ORDER=A") because earlier boots had
spent every attempt without a `rauc status mark-good`. It is kept because its login time is within
0.007 s of run 5, which also shows the last-resort path costs nothing measurable.

This covers User Story 1 only. The health script and the watchdog feeder add work after init, so
the figure is measured again, and the README baseline updated, once those exist.
