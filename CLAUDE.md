# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A containerized Buildroot workbench for building embedded Linux images. The repo itself holds
only the environment definition (`Dockerfile`, `run.sh`); the Buildroot tree, its download cache
and all build output are gitignored.

The Buildroot tree is **not** baked into the image — it is a host-side git clone that `run.sh`
bind-mounts. Clone it first (default location `./buildroot`, override with `BR_DIR`):

```bash
git clone https://gitlab.com/buildroot.org/buildroot.git buildroot
git -C buildroot checkout 2026.08   # the clone defaults to master
```

## Commands

```bash
docker build -t br-build .          # build the environment image
./run.sh                            # interactive shell in /work/output
./run.sh make list-defconfigs       # one-shot command inside the container
./run.sh make qemu_x86_64_defconfig # select a board config
./run.sh make menuconfig            # tweak the selected config
./run.sh make                       # full build; images land in output/images/
./run.sh make <pkg>-rebuild         # rebuild a single package after editing it
```

`run.sh` passes its arguments straight to `docker run` as the container command. `--rm` only
discards the container: the repo root is bind-mounted, so `.config`, `output/`, `dl/` and any
edit to the source tree persist on the host.

## Architecture notes

- **The image runs as a non-root user (`br`, UID/GID 1000)** because Buildroot refuses to build
  as root. `UID`/`GID` are build args; rebuild with `--build-arg UID=$(id -u)` if the host user
  isn't 1000, otherwise the mounted files get wrong ownership.
- **Out-of-tree build.** The source tree stays clean; `.config` and all output live in
  `output/` (`BASE_DIR`/`O`), downloads in `dl/` (`BR2_DL_DIR`, passed as an env var — that one
  Buildroot does read from the environment).
- **Buildroot only honours `O=` from the command line**, not from the environment
  (`buildroot/Makefile`, the `$(origin O)` check). Rather than injecting `O=` into every
  command, `run.sh` generates Buildroot's out-of-tree makefile wrapper into `output/Makefile`
  once (`make O=/work/output outputmakefile`) and runs everything from `output/`; the wrapper
  forwards each target to the source tree with `O=` set.
- **The repo root is mounted as a single volume (`/work`), and must stay that way.** Do not
  mount `output/` or `dl/` separately: that puts `.config` and the generated config on different
  filesystems, and `conf_write_autoconf()` in `support/kconfig/confdata.c` finishes by
  `rename()`-ing its temp files across them. `rename()` returns `EXDEV` and the build dies with
  the unhelpful `*** Error during update of the configuration.` An earlier revision of this repo
  baked the tree into the image with `output/` mounted over it, and hit exactly that.
- **Pinned toolchain-adjacent deps** (ncurses, python3, mercurial/svn, locales) are installed in
  the Dockerfile; a Buildroot package that needs a new host tool means editing the Dockerfile and
  rebuilding the image, not `apt-get` inside a running container.
