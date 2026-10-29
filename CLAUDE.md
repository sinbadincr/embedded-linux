# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A containerized Buildroot project for building embedded Linux images for several boards. The
repo root **is a `BR2_EXTERNAL` tree** (name `OTA`): it holds the board configs, overlays,
scripts, internal packages and patches, plus the build environment (`Dockerfile`, top-level
`Makefile`). Buildroot itself is the `buildroot/` git submodule (tracking the `2026.08.x` stable
branch) and is never modified. The download cache and all build output are gitignored.

```bash
git submodule update --init         # or: git clone --recurse-submodules <repo>
git submodule update --remote buildroot   # bump to the latest 2026.08.x, then commit the new pointer
```

## Language convention

Everything committed to the repo — documentation, code, comments, commit messages — is written
in **English**. Discussion with the user happens in Vietnamese; do not let that leak into files.

## Commands

```bash
# on the host
make docker-build                   # build the environment image (once, or after Dockerfile edits)
make docker-shell                   # shell in the container, repo mounted at /workspace
make docker-check                   # docker-build, then `make check` in the container (what CI runs)

# inside the container
make list-boards                    # boards = configs/<board>_defconfig
make beaglebone_black_defconfig     # select a board; output goes to output/<board>/
make build                          # full build; images land in output/<board>/images/
make check                          # static checks (shell lint incl. overlay init scripts, defconfig round-trip, image layout, storage layout agreement)
make menuconfig                     # any other target is forwarded to Buildroot for the board
make savedefconfig                  # writes back to configs/<board>_defconfig
make linux-menuconfig               # also <pkg>-rebuild, clean, ...
make BOARD=<other> build            # act on a board other than the selected one
```

`--rm` only discards the container: the repo root is bind-mounted, so `output/`, `dl/` and any
edit persist on the host.

## Layout

```
configs/<board>_defconfig            one per board (and variants, e.g. <board>_dev_defconfig)
board/ota/common/                    shared by every board: rootfs_overlay/, post-build.sh
board/ota/<board>/                   board-only: rootfs_overlay/, post-image.sh, genimage.cfg, ...
package/<name>/                      internal packages; add a `source` line to package/Config.in
patches/<pkg>/                       BR2_GLOBAL_PATCH_DIR: patches and .hash files per package
external.desc, Config.in, external.mk   BR2_EXTERNAL glue
scripts/check.sh                     static checks behind `make check` (POSIX sh)
.github/workflows/                   CI: ci.yml (checks on branch push / PR to master), build.yml (boards, manual/tag only)
```

Adding a board: create `board/ota/<board>/` and `configs/<board>_defconfig`, then
`make <board>_defconfig && make build`.

## Architecture notes

- **Makefile split.** `docker-*` targets run on the host; every other target refuses to run
  outside the container (`/.dockerenv` check) and calls
  `make -C buildroot BR2_EXTERNAL=/workspace BR2_DL_DIR=/workspace/dl O=/workspace/output/<board>`.
  The selected board is stored in `.current_board` (gitignored) by `<board>_defconfig`; a
  catch-all `%:` rule forwards any unknown target. `Makefile` and `.current_board` have empty
  rules so the catch-all does not try to remake them.
- **Paths in defconfigs use `$(BR2_EXTERNAL_OTA_PATH)/...`.** Overlays are space-separated
  (common first, then board). Post-build/post-image scripts run with cwd = `buildroot/`, so
  they can call `support/scripts/genimage.sh` relatively; `BR2_EXTERNAL_OTA_PATH`, `BASE_DIR`,
  `BINARIES_DIR` etc. are exported to them. `BASE_DIR`'s basename is the board name.
- **`BR2_DOWNLOAD_FORCE_CHECK_HASHES=y`** (inherited from upstream `beaglebone_defconfig`) needs
  a `.hash` for custom-version kernel/U-Boot in `patches/{linux,linux-headers,uboot}/`. Bumping
  `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` or the U-Boot version means adding its hash line there
  (a single `.hash` file may hold several versions, so boards can share it).
- **Kernel/U-Boot configs** currently come from in-tree defconfigs (`omap2plus`, `am335x_evm`).
  To customize, switch the defconfig to `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` with
  `BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/linux.config"`
  and generate it with `make linux-update-defconfig` (same pattern for U-Boot).
- **The image runs as a non-root user (`br`)** because Buildroot refuses to build as root.
  `make docker-build` passes the host UID/GID as build args and `docker-shell` runs with `-u`
  the same IDs, so files in the mount keep host ownership.
- **The repo root is mounted as a single volume (`/workspace`), and must stay that way.** Do not
  mount `output/` or `dl/` separately: that puts `.config` and the generated config on different
  filesystems, and `conf_write_autoconf()` in `support/kconfig/confdata.c` finishes by
  `rename()`-ing its temp files across them. `rename()` returns `EXDEV` and the build dies with
  the unhelpful `*** Error during update of the configuration.`
- **Pinned toolchain-adjacent deps** (ncurses, python3, mercurial/svn, locales) are installed in
  the Dockerfile; a Buildroot package that needs a new host tool means editing the Dockerfile and
  rebuilding the image, not `apt-get` inside a running container.
- **CI split.** `ci.yml` runs `make docker-check` on every branch push and every PR to `master` (no board build). `build.yml`
  builds every `configs/*_defconfig` in its own job, only on manual dispatch or a `v*` tag, with
  `dl/` cached by `actions/cache`; a tag run ends in a **draft** release. The `release` job is the
  only one with `contents: write`. All jobs use `ubuntu-24.04` and `actions/*` pinned by commit
  SHA (table in `specs/001-ci-cd-pipeline/contracts/workflows.md`); no floating references. CI
  builds in the container with the same single `/workspace` mount; the runner's UID/GID reach the
  image through `make docker-build`. A green build is not a boot test: boot-affecting changes
  still need the manual smoke test from the constitution.
- **The target clock is a floor, not the real time.** The boards here have no battery-backed RTC:
  the kernel clock starts at 1970-01-01, and the board's RTC driver then sets it to the RTC's
  power-on value, 2000-01-01 (BeagleBone Black measured). That driver must be **built in**
  (`CONFIG_RTC_DRV_OMAP=y`): as a module it registers seconds into boot and overwrites anything
  an init script set before it (seen on hardware, research R8). `board/ota/common/post-build.sh`
  writes `BUILD_DATE` (epoch seconds) to `/etc/build-info`, and
  `board/ota/common/rootfs_overlay/etc/init.d/S00ota-clock` raises the clock to it at the start of
  boot, only when the clock is earlier. Anything on the device that checks a time window
  (`rauc install` certificate validity, TLS, token expiry, a log or file that needs a true
  timestamp) therefore sees the **image's build time** after a cold boot, never the real time.
  When writing a spec or plan that touches the target's clock: (1) a certificate or token issued
  *after* the running image was built is "not yet valid" on that device until something sets the
  clock; (2) timestamps on the device are wrong by however long it was off, so do not use them as
  evidence or ordering across reboots; (3) real time needs an RTC or a time source and is its own
  feature, not an assumption; (4) a new build-time artefact that the device validates must be
  created *before* the image is built (this is why `check_keys` refuses to build without the keys);
  (5) `SOURCE_DATE_EPOCH` is deliberately not the floor, since a commit time can predate the
  certificate. Rationale and the one known gap: `specs/002-ab-ota-rauc/research.md` R8, FR-033.
- **`CONFIG_CMDLINE` is read last.** The beaglebone kernel uses `CONFIG_CMDLINE_EXTEND`, and
  `drivers/of/fdt.c` appends the built-in string *after* what U-Boot passes (the Kconfig help says
  the opposite), so on a duplicate the built-in value wins. It carries only `omap_wdt.early_enable=1`,
  without which the driver stops the watchdog U-Boot started (research R5). Never put `root=` or
  `console=` there: `root=` is set per slot by `uboot-env.txt`, and a built-in one would override it.
- **`make check` also guards the card layout.** For a RAUC board it compares the numbers that five
  files must share (`genimage.cfg`, `uboot.config`, `fw_env.config`, `uboot-env.txt`, `system.conf`,
  `fstab`): state offsets and size, partition numbers of slot A, slot B and `/data`. A mismatch there
  is silent on a device and shows up as every update rolling back. It also lints and checks the mode of
  overlay scripts without an extension (init scripts, RAUC handlers), found by their shebang.
- **`make check`** compares the regenerated minimal defconfig against the working-tree file in a
  temp file (never writes `configs/`, never relies on git state). New boards need no CI edits;
  they are discovered from `configs/`.
