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
make check                          # static checks (shell lint, defconfig round-trip, image layout)
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
- **`make check`** compares the regenerated minimal defconfig against the working-tree file in a
  temp file (never writes `configs/`, never relies on git state). New boards need no CI edits;
  they are discovered from `configs/`.
