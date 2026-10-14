# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A containerized Buildroot workbench for building embedded Linux images. The repo itself holds
only the environment definition (`Dockerfile`, `run.sh`); the Buildroot tree, its download cache
and all build output are gitignored.

Buildroot 2026.08 is baked into the image at `/buildroot` (unpacked from
`buildroot-$BR_VERSION.tar.xz` at image build time), so the tarball must be present in the repo
root before `docker build`. It is not committed — re-fetch it if missing:

```bash
wget https://buildroot.org/downloads/buildroot-2026.08.tar.xz
```

## Commands

```bash
docker build -t br-build .          # build the environment image (needs the tarball present)
./run.sh                            # interactive shell in /buildroot
./run.sh make list-defconfigs       # one-shot command inside the container
./run.sh make qemu_x86_64_defconfig # select a board config (305 under configs/)
./run.sh make menuconfig            # tweak the selected config
./run.sh make                       # full build; images land in output/images/
./run.sh make <pkg>-rebuild         # rebuild a single package after editing it
```

`run.sh` passes its arguments straight to `docker run` as the container command, so anything
valid in `/buildroot` works. It bind-mounts `./output` and `./dl` and uses `--rm`, so **anything
written outside those two directories is lost when the container exits** — Buildroot config
changes (`.config`) survive only because they live under `output/`.

## Architecture notes

- **The image runs as a non-root user (`br`, UID/GID 1000)** because Buildroot refuses to build
  as root. `UID`/`GID` are build args; rebuild with `--build-arg UID=$(id -u)` if the host user
  isn't 1000, otherwise the bind-mounted `output/` and `dl/` get wrong ownership.
- **`dl/` is the shared download cache.** Keeping it mounted across runs avoids re-downloading
  every upstream tarball on each fresh container.
- **Out-of-tree builds are not used**; the build happens in the in-image `/buildroot` tree with
  `output/` mounted over its default output path. Treat `/buildroot` as disposable except for
  that mount.
- **Pinned toolchain-adjacent deps** (ncurses, python3, mercurial/svn, locales) are installed in
  the Dockerfile; a Buildroot package that needs a new host tool means editing the Dockerfile and
  rebuilding the image, not `apt-get` inside a running container.
