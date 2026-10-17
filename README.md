# OTA — Embedded Linux with Buildroot

Builds embedded Linux images for several boards with [Buildroot](https://buildroot.org), inside
Docker so the whole team shares one build environment. Supported boards: **BeagleBone Black**.

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
├── external.desc             # BR2_EXTERNAL name: OTA
├── Config.in, external.mk    # hook package/ into Buildroot
├── buildroot/                # [submodule] Buildroot 2026.08.x
├── configs/
│   └── beaglebone_black_defconfig   # one file per board/variant
├── board/ota/
│   ├── common/               # shared by every board
│   │   ├── rootfs_overlay/          # e.g. /etc/issue
│   │   └── post-build.sh            # writes /etc/build-info (board, git version, Buildroot)
│   └── beaglebone_black/     # BBB only
│       ├── rootfs_overlay/          # e.g. /etc/hostname
│       ├── post-image.sh            # copies uEnv.txt, extlinux.conf, then runs genimage
│       ├── genimage.cfg             # SD card: 16M FAT boot + 512M ext4 rootfs
│       └── uEnv.txt, extlinux.conf
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

## Flashing and booting the BeagleBone Black

```bash
sudo dd if=output/beaglebone_black/images/sdcard.img of=/dev/sdX bs=4M conv=fsync
```

Hold the **S2 (BOOT)** button while powering on to boot from the SD card. Serial console on
header J1, 115200 8N1. Log in as `root`, no password.

## Extending

**Adding a board**
1. Create `board/ota/<board>/` (genimage.cfg, post-image.sh, rootfs_overlay/, ...).
2. Create `configs/<board>_defconfig`, using `$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/...` and
   keeping the `common/` overlay and post-build script.
3. `make <board>_defconfig && make build` → separate output in `output/<board>/`.

**Adding an internal package**: create `package/<name>/Config.in` and `<name>.mk`, then add
`source "$BR2_EXTERNAL_OTA_PATH/package/<name>/Config.in"` to `package/Config.in`.

**Custom kernel/U-Boot config**: the in-tree defconfigs (`omap2plus`, `am335x_evm`) are used for
now. For a project-specific config, set `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y` and
`BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/linux.config"`,
then generate the file with `make linux-update-defconfig` (same pattern for U-Boot).

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
