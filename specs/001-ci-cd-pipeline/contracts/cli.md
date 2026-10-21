# Contract: Developer command surface (additions)

The documented `make` interface is a public contract (Principle V). This feature only adds; no
existing target changes. README.md, CLAUDE.md and `make help` list the additions in the same change.

## `make check` (in the container)

- **Preconditions**: inside the build container; Buildroot submodule present. Otherwise it fails
  through the existing `check_env` messages (stderr, exit 1).
- **Runs**: `scripts/check.sh` (see research R2).
- **Exit**: `0` all checks pass; non-zero on the first or any failure (all checks are attempted and
  a summary lists failures).
- **Output**: one line per check (`ok:` / `FAIL:`) naming the check and the file or board; failures
  go to stderr and end with the remedy command, for example
  `FAIL: defconfig round-trip: configs/x_defconfig differs after savedefconfig; run 'make x_defconfig && make savedefconfig' and commit the result.`
- **Side effects**: leaves `.current_board` as it found it; writes only under `output/<board>/`
  (the regenerated minimal defconfig goes to a temp file there and is compared with the
  working-tree `configs/<board>_defconfig`, so uncommitted edits are checked and `configs/` is
  never modified).
- Declared `.PHONY`; does not interfere with the catch-all `%:` rule.

## `make docker-check` (on the host)

- **Runs**: `make docker-build`, then `docker run --rm -v <repo>:/workspace -w /workspace -u <uid>:<gid> <image> make check`.
- **Exit**: same as `make check`, or the failing `docker-build` status.
- **Rule**: this is exactly what CI runs on push/PR (SC-003).
- Declared `.PHONY`; mounts the repo as the single `/workspace` volume.

## `make help`

Adds one line per new target in the Host / container sections.

## Unchanged

`docker-build`, `docker-shell`, `list-boards`, `<board>_defconfig`, `build`, forwarded Buildroot
targets, `BOARD=` override.
