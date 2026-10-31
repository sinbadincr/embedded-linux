# OTA — Embedded Linux with Buildroot

Builds embedded Linux images for several boards with [Buildroot](https://buildroot.org), inside
Docker so the whole team shares one build environment. Supported boards: **BeagleBone Black**,
which updates in the field with **A/B slots and automatic rollback** ([RAUC](https://rauc.io);
see *Updating a device* below).

## Concept

| Layer | Where | Role |
|---|---|---|
| Upstream Buildroot | `buildroot/` (git submodule, branch `2026.08.x`) | Upstream code, **never modified** |
| Project files | Repo root = `BR2_EXTERNAL` tree named `OTA` | Defconfigs, overlays, scripts, packages, patches |
| Build environment | `Dockerfile` | All host tools Buildroot needs; every build command runs in the container |

Upgrading Buildroot is just moving the submodule pointer; the project files stay as they are.

## Layout

```
ota/
├── Makefile                  # entry point: Docker targets + forwarding to Buildroot
├── Dockerfile                # build environment
├── scripts/
│   ├── check.sh                     # static checks run by `make check`
│   ├── gen-dev-keys.sh              # `make ota-dev-keys`: development CA + bundle-signing pair
│   └── make-untrusted-bundles.sh    # the bundles a device must refuse (quickstart scenario 7)
├── keys/dev/                 # [gitignored] development signing material
├── specs/002-ab-ota-rauc/    # the A/B feature: spec, plan, research, contracts, quickstart, tasks
├── docs/                     # boot-time baseline; docs/logs/ holds the hardware captures
├── .github/workflows/        # CI: ci.yml (checks), build.yml (board images, releases)
├── external.desc             # BR2_EXTERNAL name: OTA
├── Config.in, external.mk    # hook package/ into Buildroot
├── buildroot/                # [submodule] Buildroot 2026.08.x
├── configs/
│   └── beaglebone_black_defconfig   # one file per board/variant
├── board/ota/
│   ├── common/               # shared by every board
│   │   ├── rootfs_overlay/          # /etc/issue, init.d/S00ota-clock, init.d/S99ota-health,
│   │   │                            #   usr/lib/ota/pre-install (the RAUC handler)
│   │   └── post-build.sh            # /etc/build-info (board, git version, Buildroot, build date),
│   │                                #   the trust anchor, the /data mount point
│   └── beaglebone_black/     # BBB only
│       ├── rootfs_overlay/          # /etc: fstab, fw_env.config, hostname, network/interfaces, rauc/system.conf
│       ├── post-image.sh            # builds data.ext4 and the signed .raucb, then runs genimage
│       ├── genimage.cfg             # the SD card: boot, two OS slots, data, and the state region
│       ├── uboot.config             # U-Boot configuration (environment in raw MMC, watchdog, ...)
│       ├── uboot-env.txt            # the slot-selection script and its default environment
│       └── linux.config             # kernel configuration
├── package/                  # internal packages (declared in package/Config.in)
├── patches/                  # patches + .hash files per package (linux, uboot, ...)
├── output/<board>/           # [gitignored] build output, one directory per board
└── dl/                       # [gitignored] downloaded sources, shared
```

Defconfigs refer to repo files as `$(BR2_EXTERNAL_OTA_PATH)/...`. The common overlay is copied
first and the board overlay second, so a board file wins over a common one with the same path.

## Getting started

Host requirements: Git, GNU Make, Docker.

```bash
git clone --recurse-submodules <repo-url> ota    # already cloned: git submodule update --init
cd ota
make docker-build                                 # build the image (once, or after Dockerfile edits)
```

## Building

```bash
make docker-shell                  # shell in the container, repo mounted at /workspace

# inside the container:
make list-boards                   # boards in configs/
make beaglebone_black_defconfig    # select a board (recorded in .current_board)
make build                         # → output/beaglebone_black/images/sdcard.img
```

The first build takes about an hour (toolchain, kernel, U-Boot); later builds are much faster.

Other commands (inside the container, for the selected board):

```bash
make menuconfig           # edit the Buildroot configuration
make savedefconfig        # write it back to configs/<board>_defconfig → commit that file
make linux-menuconfig     # edit the kernel configuration
make <pkg>-rebuild        # rebuild one package
make clean                # remove the board's output
make BOARD=<other> build  # act on another board without changing the selected one
make help
```

Any target not defined in the `Makefile` is forwarded to Buildroot.

## Checks and CI

```bash
make docker-check          # host: rebuild the environment image, then run `make check` in it
make check                 # inside the container: the same checks without the image rebuild
```

`make check` runs `sh -n` and `shellcheck` on every script, including init scripts and RAUC handlers
in an overlay (found by their shebang, and required to be executable); regenerates each board's
minimal defconfig and compares it with `configs/<board>_defconfig`; dry-runs `make -n build` per
board; checks that each board has its `genimage.cfg`, `post-image.sh` and overlays and where its
kernel and device tree live; and, for a board that updates with RAUC, that `genimage.cfg`,
`uboot.config`, `fw_env.config`, `uboot-env.txt`, `system.conf` and `fstab` agree on the boot-selection
state's offsets and size and on which partition is slot A, slot B and `/data`. It exits non-zero on any
failure and names the file and the fix.

GitHub Actions (GitHub-hosted `ubuntu-24.04` runners):

- `ci.yml` runs `make docker-check` on every push to a branch and every pull request targeting `master`.
- `build.yml` builds every board in `configs/` in its own job. It runs only when started manually
  (Actions → build → Run workflow) or when a `v*` tag is pushed, never on pull requests. The
  downloaded sources in `dl/` are cached between runs. Each board's `sdcard.img.xz` is kept as a
  workflow artifact for 14 days. On a tag, if every board built, a **draft** release is created
  with the images and `SHA256SUMS`. `keys/dev/` is not in the repository, so `build.yml` writes it from
  three repository secrets, `OTA_KEYRING_PEM`, `OTA_SIGNING_CERT_PEM` and `OTA_SIGNING_KEY_PEM` (the
  contents of `dev-ca.cert.pem`, `dev-signing.cert.pem` and `dev-signing.key.pem`), and fails at once if
  one is missing or the certificate does not match the key. Every CI image then shares the CA of your
  local builds.

A green build is **not** a boot test. Boot each image on hardware to a login prompt on the serial
console before publishing a draft release. Images are xz-compressed: see Flashing below. Release
images are development images (passwordless `root`); do not deploy them.

> **The figures in the rest of this section describe the single-slot image from before the A/B
> change** (a 76 MiB `sdcard.img`, one 60 MiB root filesystem, a 16 MiB boot partition). The A/B image
> has a different layout and a different boot path and is re-measured separately (task T043 of
> `specs/002-ab-ota-rauc/tasks.md`); do not read the footprint or boot-time numbers below as its own.
> What is already known about the A/B image is in *Updating a device*, and its footprint follows.

Footprint of the A/B image (revision `6d5dbc6`, `beaglebone_black`, measured 2026-10-30 from the build
output with `dumpe2fs -h` and `mdir`, both in `output/<board>/host/`):

| Part | Size | Used | Limit (SC-007) |
|---|---|---|---|
| OS slot, filesystem (`rootfs.ext4`) | 128 MiB filesystem in a 512 MiB partition | 61.2 MiB: **47.8%** of the filesystem, 12.0% of the slot | 80% |
| Boot partition (FAT16, `MLO` + `u-boot.img`) | 32 MiB | 1.57 MiB: **4.9%** | 80% |
| Persistent data area (empty ext4) | 256 MiB | 26.4 MiB of filesystem overhead, **229.6 MiB free** | holds one bundle with room |
| Update bundle `<board>-<rev>.raucb` | 23.1 MB (22.1 MiB) | holds 128 MiB of filesystem, compressed | about 10 fit in `/data` |
| `sdcard.img` | 1313 MiB declared, **63.0 MiB** of real data | the rest are holes | fits a 2 GB card |
| Kernel inside each slot (`/boot/zImage`) | 7.3 MiB | | |

Boot time of the A/B image, with `S00ota-clock`, `S99ota-health`, the static address, the RTC driver and
SquashFS: **11.61 s** from the U-Boot SPL banner to the login prompt (mean of three `grabserial` runs, spread
0.12%), against a budget of 12.65 s and the 11.50 s single-slot baseline, so 1.0% slower. About a second of
that is the health script, which confirms the slot before the login prompt appears. Per-phase reading and
the raw logs (`boot-baseline-run7.log` to `run9.log`) are in
[docs/boot-baseline-beaglebone-black.md](docs/boot-baseline-beaglebone-black.md).

Measured on GitHub-hosted runners for `beaglebone_black` (`build.yml`, 2026-10-26):

| Run | `dl/` cache | Board build | Whole run |
|---|---|---|---|
| Cold | miss (432 MiB saved) | ~52 min | ~54 min |
| Warm | exact hit, 0 sources downloaded | 33-52 min | ~37-55 min |

The warm range is runner variance: two exact-hit runs took 33 and 52 min.
`make docker-check` (`ci.yml`) takes about 40 s cold. The warm build is still long because `dl/`
only saves the source downloads; the toolchain, kernel and U-Boot are rebuilt every run. The
artifact `sdcard.img.xz` is about 14.7 MB (`sdcard.img` is 76 MiB).

Footprint of that image: `rootfs.ext4` is a 60 MiB filesystem (512 MiB partition) with about
39 MiB used (65%); the FAT16 boot partition has about 9.0 MiB of its 16 MiB used (56%).

Boot time of the original single-slot image on hardware: **11.50 s** from the U-Boot SPL banner to the login prompt (mean of three
runs, spread 1.2%), about 12.0 s from power-on. Of that, 2.08 s is the `bootdelay` countdown and
5.89 s is kernel plus init. Method, per-phase breakdown and the serial logs are in
[docs/boot-baseline-beaglebone-black.md](docs/boot-baseline-beaglebone-black.md); reproduce it with
`grabserial` as documented there before and after any change that touches the kernel, bootloader,
device tree, bootargs, partition layout or init.

## Flashing and booting the BeagleBone Black

The card needs **at least 2 GB**. The layout is fixed (about 1.28 GiB) and is not grown to fill a larger
card: the space beyond it is simply unused. `sdcard.img` is sparse, so it is small on the host but
`dd` writes its whole length, and a flash takes as long as the declared layout, not as long as the data.

```bash
sudo dd if=output/beaglebone_black/images/sdcard.img of=/dev/sdX bs=4M conv=fsync
```

Images downloaded from CI or a release are xz-compressed:

```bash
xzcat beaglebone_black-sdcard.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync
```

As above, double-check `/dev/sdX` first: `dd` overwrites the target without asking.

Hold the **S2 (BOOT)** button while powering on to boot from the SD card. Serial console on
header J1, 115200 8N1. Log in as `root`, no password.

Flashing writes the bootloader and slot A only. Slot B starts out empty and ineligible (it is not in
`BOOT_ORDER` and has no attempts), so a freshly flashed card always boots slot A; the first update gives
slot B its attempts and moves it to the front.

## Updating a device (A/B, RAUC)

### What is on the card

```
0x000000   MBR (four primary entries; MBR and not GPT, because the AM335x ROM needs an MBR)
0x080000   boot-selection state, primary copy       128 KiB, in no filesystem
0x0A0000   boot-selection state, redundant copy     128 KiB
0x100000   p1  boot      32 MiB   FAT16   MLO, u-boot.img only
           p2  rootfs.A  512 MiB  ext4    kernel, device tree, modules and userspace, read-only
           p3  rootfs.B  512 MiB  ext4    the same, the other slot
           p4  data      256 MiB  ext4    the only persistent, writable area, mounted at /data
```

Each OS slot holds everything needed to run that revision, kernel included, and is mounted **read-only**;
temporary files and logs are on tmpfs, so an update replaces a slot completely and nothing drifts. The
boot-selection state lives in the raw region above the first partition because the four primary
partitions are already spent. U-Boot reads `BOOT_ORDER` and `BOOT_<slot>_LEFT` from it, spends one attempt
per try, and boots the first slot that still has one. That counter is the **only** boot-attempt counter.
The byte-level contract is [specs/002-ab-ota-rauc/contracts/storage-layout.md](specs/002-ab-ota-rauc/contracts/storage-layout.md).

### Building an update

Every build produces both artefacts in `output/<board>/images/`: the flashable `sdcard.img` and the
update `<board>-<revision>.raucb` (about 23 MB), signed and carrying `compatible=ota-beaglebone-black`
and the revision from `git describe`. A build of an A/B board refuses to start without signing material:

```bash
make ota-dev-keys          # once, inside the container: a development CA and a signing pair in keys/dev/
```

`keys/dev/` is gitignored and **development only**: the certificates say so in their subject. The device
trusts the CA, so a lost or leaked *signing* key is answered by issuing a new certificate; losing the CA
means reflashing every device. To sign with other material (staging, production) point `OTA_SIGNING_CERT`,
`OTA_SIGNING_KEY` and `OTA_KEYRING` at it, for example `make OTA_SIGNING_KEY=... build`.

### Installing it

Getting the file onto the device is **not** part of this project: use whatever you have. On the development
bench the board is cabled straight to the host, has the static address `192.168.0.2/24`, and fetches it
over HTTP (research R8 in the spec directory has the reasoning and the measured result):

```bash
# host, in output/<board>/images/:   python3 -m http.server 8000 --bind 192.168.0.1
# board:
wget -O /data/update.raucb http://192.168.0.1:8000/<board>-<revision>.raucb
rauc install /data/update.raucb       # verifies, writes the slot that is NOT running, flips BOOT_ORDER
reboot
```

A bundle is refused, before anything is written, if it is unsigned, signed by a CA the device does not
trust, altered after signing, built for another board, or signed with a certificate that may not sign
code. It is also refused while an earlier update is **pending** (installed but not yet booted) or while
another install runs. After the reboot:

```bash
cat /etc/build-info                              # the revision now running
ota-status                                       # running slot, confirmed or not, pending update, each slot's state and version
rauc status --detailed                           # the raw RAUC view it is built on
fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT   # the raw state
```

### Rollback

Nothing has to be done by hand. A new slot gets **three attempts**. After each boot, `S99ota-health` checks
four local conditions (the init sequence reached it; RAUC and U-Boot agree on the running slot; `/data` is
mounted and writable; the boot-selection state reads and writes back) and only then calls
`rauc status mark-good` and starts the hardware watchdog feeder. A slot that does not confirm leaves the
watchdog unfed; the board resets about **50 s** after the kernel started, an attempt is spent, and after the
third U-Boot skips the slot and boots the other one. Measured on the bench: three failed boots and a
fallback in under three minutes. A confirmed slot that later hangs (the feeder dies, the kernel panics) is
reset within about 30 s and, having confirmed, keeps its attempts.

Why a slot failed is in `/data/ota-health.log`, one line per event with the condition, the slot and the
revision (format in [contracts/boot-interface.md](specs/002-ab-ota-rauc/contracts/boot-interface.md)). A slot
that hung before the health script ran writes no line; its state, `BOOT_<slot>_LEFT=0` and `bad` in
`rauc status`, is the evidence, and `ota-status` says it in words (`RETIRED: it was tried and never confirmed`). `rauc status mark-bad` is meant for forcing a rollback while testing; the hardware runs of
this feature rolled back by other means (a hanging slot, a pulled plug) and did not exercise it.

### Limits worth knowing

- **The bootloader is never updated in the field.** `MLO` and `u-boot.img` are written when the card is
  flashed and no bundle touches them, nor the boot-selection region. A bootloader fix means reflashing.
- **The last resort is always slot A.** If every slot has run out of attempts, U-Boot says so on the
  console and boots slot A once without spending an attempt, not the first slot in `BOOT_ORDER`. With
  `BOOT_ORDER=B` and B exhausted that is A, which may be older or empty. To pick B instead, run
  `fw_setenv ota_fallback_slot B` from Linux, or `setenv ota_fallback_slot B; saveenv` at the U-Boot
  prompt (known issue and workaround: `specs/002-ab-ota-rauc/contracts/boot-interface.md`). The variable
  is untested on hardware, and a card flashed before it existed needs its reserved region written again.
- **Development images only.** `root` has no password and nothing is hardened; the signing material is
  development material. A bundle signed by it installs only on an image built with the same CA.
- **The clock is a floor, not the real time.** The board has no battery-backed clock; at boot it is raised
  to the image's build time. A certificate issued after the running image was built is "not yet valid"
  on it. Log timestamps on the device are that floor plus the uptime. See `CLAUDE.md`, research R8.
- **No update server, no delta updates, no secure boot.** A bundle carries a whole slot; the feature is the
  device side of an update, not the fleet side.
- **Boot affecting changes need the hardware.** `make check` and a green build cannot see the kernel, RAUC
  or the bootloader; defects in this feature were found on the board that no host check saw. Evidence from
  those runs is in `docs/logs/`.

## Extending

**Adding a board**
1. Create `board/ota/<board>/` (genimage.cfg, post-image.sh, rootfs_overlay/, ...).
2. Create `configs/<board>_defconfig`, using `$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/...` and
   keeping the `common/` overlay and post-build script.
3. `make <board>_defconfig && make build` → separate output in `output/<board>/`.

**Adding an internal package**: create `package/<name>/Config.in` and `<name>.mk`, then add
`source "$BR2_EXTERNAL_OTA_PATH/package/<name>/Config.in"` to `package/Config.in`.

**Kernel and U-Boot configuration**: `beaglebone_black` uses its own `linux.config`, `uboot.config` and
`uboot-env.txt` (`BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG`, `BR2_TARGET_UBOOT_USE_CUSTOM_CONFIG`). Change the
kernel with `make linux-menuconfig` and write it back with `make linux-update-defconfig` (same pattern for
U-Boot). Some options are load-bearing for A/B updates and are explained where they matter in the spec
directory: SquashFS and the loop device (RAUC mounts a bundle), the RTC driver built in (the clock floor),
`omap_wdt.early_enable=1` on the built-in command line (the watchdog), and the state offsets, which
`make check` compares across six files. `uboot-env.txt` is compiled into the SPL as well as U-Boot, and
the AM335x SPL has little room: growing that file much further breaks the link with an SRAM overflow.

**Changing the kernel/U-Boot version**: the defconfig enables `BR2_DOWNLOAD_FORCE_CHECK_HASHES`,
so add the new version's hash to `patches/linux/linux.hash` or `patches/uboot/uboot.hash`.

**Updating Buildroot**
```bash
git submodule update --remote buildroot   # latest commit on 2026.08.x
# test a build, then:
git add buildroot && git commit
```

## Notes

- **Mount a single volume.** The whole repo is mounted at `/workspace`. Do not mount `output/` or
  `dl/` separately: kconfig writes its configuration with `rename()`, which fails with `EXDEV`
  across filesystems (`*** Error during update of the configuration.`).
- **Do not build as root.** Buildroot refuses to run as root. `make docker-build` creates a user
  `br` with your UID/GID, so files in `output/` stay owned by you on the host.
- **Missing host tool** → edit the `Dockerfile` and `make docker-build`; do not `apt-get` inside a
  running container.

## Conventions

All documentation, code, comments and commit messages in this repo are written in English.
