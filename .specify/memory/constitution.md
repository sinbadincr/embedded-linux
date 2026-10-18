# OTA Constitution

OTA builds reproducible embedded Linux images for multiple boards. The repo root is a Buildroot
`BR2_EXTERNAL` tree (name `OTA`); upstream Buildroot is a pinned submodule; all builds run in a
Docker container. These principles govern every change to this repository.

## Core Principles

### I. Upstream Is Immutable; The External Tree Is the Only Place to Change Behavior

Nothing under `buildroot/` is ever edited, patched in place, or committed to except moving the
submodule pointer. All project behavior lives in the BR2_EXTERNAL tree: `configs/`, `board/ota/`,
`package/`, `patches/`, `external.*`, `Config.in`.

- Per-package fixes MUST be delivered as patches under `patches/<pkg>/` (via
  `BR2_GLOBAL_PATCH_DIR`) or as an internal package, never by editing the submodule.
- Shared behavior MUST live in `board/ota/common/`; board-specific behavior MUST live in
  `board/ota/<board>/`. A board file overrides a common file only by sharing its path in the
  later overlay; such overrides MUST be intentional and visible in review.
- Internal packages MUST be registered with a `source` line in `package/Config.in` and follow
  Buildroot package conventions (`<name>.mk`, `Config.in`, `.hash` for downloaded sources).
- A Buildroot bump is its own change: one commit moving the pointer, preceded by a successful
  build of every board.

Rationale: an untouched upstream makes Buildroot upgrades a pointer move and keeps every
customization discoverable in one tree.

### II. Reproducible, Contained, Integrity-Checked Builds

The same commit MUST produce the same inputs on any developer machine.

- Every build command except `docker-*` targets runs inside the build container; the `/.dockerenv`
  guard in the `Makefile` MUST NOT be weakened.
- Host tool needs are met by editing the `Dockerfile` and rebuilding the image, never by
  `apt-get` in a running container, and never by relying on host-installed tools.
- `BR2_DOWNLOAD_FORCE_CHECK_HASHES=y` MUST stay enabled. Every custom kernel, kernel-headers or
  U-Boot version, and every downloaded source in an internal package, MUST have a matching `.hash`
  line in `patches/<pkg>/` or `package/<name>/`, with its provenance in a comment (upstream
  signature file, or "Locally calculated" plus how it was verified).
- Versions are pinned explicitly (kernel, U-Boot, toolchain, Buildroot submodule commit). Floating
  references are not allowed in committed configuration.
- The repo root MUST be mounted as a single volume (`/workspace`); `output/` and `dl/` MUST NOT be
  mounted separately (kconfig `rename()` fails with `EXDEV` across filesystems).
- Build output (`output/`, `dl/`) and local state (`.current_board`) stay gitignored.

Rationale: embedded images are shipped to devices; an unverifiable or non-reproducible input is a
supply-chain and field-debugging risk.

### III. Code Quality: Small, Declarative, Idiomatic

Configuration is the primary artifact; code is kept minimal and consistent with its neighbors.

- **Defconfigs** are generated, not hand-grown: change them via `make menuconfig` then
  `make savedefconfig`, and commit only the resulting minimal defconfig. Paths MUST use
  `$(BR2_EXTERNAL_OTA_PATH)/...`; no absolute or host-specific paths. Overlays are listed common
  first, board second.
- **Shell scripts** (`post-build.sh`, `post-image.sh`, future helpers) MUST be POSIX `sh`, start
  with `set -eu`, quote all expansions, use the variables Buildroot exports (`TARGET_DIR`,
  `BINARIES_DIR`, `BASE_DIR`, `BR2_EXTERNAL_OTA_PATH`) rather than hardcoded paths, and carry a
  one-line header comment stating purpose and working directory assumptions. Board-specific
  logic MUST NOT leak into `board/ota/common/`.
- **Makefile**: every new target MUST be declared `.PHONY`, MUST fail with an actionable message
  (stderr, non-zero exit) when preconditions are missing, and MUST NOT break the catch-all
  forwarding rule.
- **Language**: everything committed — code, comments, docs, commit messages — is English.
- **Comments** explain why (non-obvious constraints, upstream quirks), not what. Match the
  surrounding density.
- **Simplicity**: no speculative abstractions, no unused options, no dead files. Prefer upstream
  Buildroot mechanisms over custom scripting.
- **Commits** are single-purpose with a descriptive imperative subject and a body explaining why.

Rationale: a tree this small stays maintainable only if each file does one declared job in a
recognizable style.

### IV. Verification Standards (NON-NEGOTIABLE: No Change Merges Unverified)

The repo has no unit-test framework; verification is build- and image-level. A change is verified
by the checks matching what it touches, and the evidence MUST be stated in the commit or PR.

| Change touches | Required verification |
|---|---|
| Any shell script | `sh -n` passes; `shellcheck` is clean or each suppression is justified |
| Any defconfig | `make <board>_defconfig && make savedefconfig` yields no diff (round-trip clean) |
| Makefile | `make -n` on affected targets, from host and from container; error paths exercised |
| Dockerfile | `make docker-build` from scratch succeeds; then a board build succeeds |
| Overlay, genimage, post-* scripts | Full `make build` for each affected board; resulting `sdcard.img` partition layout inspected |
| Kernel/U-Boot/toolchain version or patch | Clean build with hash checking on; boot smoke test |
| Buildroot submodule bump | Clean build of EVERY board; boot smoke test of each |
| New board | Everything above, plus the board checklist in Principle V |

- **Boot smoke test**: for any change that alters the kernel, bootloader, device tree,
  bootargs, partition layout, rootfs contents or init, the image MUST be booted (on hardware, or
  QEMU where the board is emulatable) to a login prompt on the serial console, and the result
  recorded. "It builds" is not sufficient evidence for a boot-affecting change.
- **Artifact consistency checks**: files referenced by `genimage.cfg` MUST exist in
  `BINARIES_DIR` after a build, and every device tree built via
  `BR2_LINUX_KERNEL_INTREE_DTS_NAME` that the board is meant to boot MUST be listed in
  `genimage.cfg` (and vice versa).
- **Bug fixes** MUST include a reproduction (failing command or symptom) and show it no longer
  occurs.
- **Known gaps (to be closed, not to be normalized)**: there is no CI, no shellcheck/lint
  automation, and no scripted smoke test. New work SHOULD move these toward automation (a
  `make check` target and container-run CI job are the intended shape). Until then the manual
  evidence above is mandatory. Adding automation is an ordinary change under this principle and
  needs no amendment.

Rationale: the failure mode of this project is a bricked or unbootable device. Verification must
therefore reach the boot, not stop at compilation.

### V. Consistent Developer and Operator Experience

Developers and device users meet the same conventions on every board.

- **Developer interface**: the documented `make` surface (`docker-build`, `docker-shell`,
  `list-boards`, `<board>_defconfig`, `build`, any forwarded Buildroot target, `BOARD=` override)
  is a public contract. Changes to it are breaking and need an updated README, CLAUDE.md and
  `make help` in the same change.
- **Messages**: errors name the problem and the exact remedy command, are written to stderr, and
  exit non-zero (model: the existing `check_env` / `check_board` messages).
- **Board parity**: every board MUST have `configs/<board>_defconfig` and `board/ota/<board>/`
  with `genimage.cfg`, `post-image.sh` and `rootfs_overlay/`; MUST reuse `board/ota/common/`
  overlay and post-build script; MUST output to `output/<board>/images/` with an `sdcard.img` (or
  documented equivalent) as the flashable artifact; and MUST have its flashing/boot/serial
  procedure in the README. Variants use the `<board>_<variant>_defconfig` name.
- **On-device conventions**: every image carries `/etc/build-info` (board, git version,
  Buildroot version) and `/etc/issue` from the common overlay; each board sets a unique
  `/etc/hostname`; the serial console is configured explicitly in both `extlinux.conf` and
  `uEnv.txt` and kept in agreement.
- **Docs are part of the change**: README.md (human workflow) and CLAUDE.md (agent guidance)
  MUST be updated in the same commit as any behavior, layout or command they describe; they MUST
  NOT contradict each other or the code.

Rationale: a second board or a new contributor should need no tribal knowledge to build, flash
and identify an image.

### VI. Performance and Footprint Budgets

Performance here means build efficiency, image size, and boot time. They MUST be considered in
every change and MUST NOT regress without justification.

- **Build efficiency**: incremental builds MUST remain incremental. Changes MUST NOT invalidate
  the toolchain or force full rebuilds without cause; the shared `dl/` cache MUST be reused; the
  `.NOTPARALLEL` Makefile wrapper must not serialize Buildroot's own parallelism (parallel build
  is delegated to the inner `$(MAKE)`). A first full build of one board is expected to take on
  the order of one hour; a change that materially lengthens it needs justification.
- **Image size**: the boot partition is fixed at 16M and the rootfs at 512M in `genimage.cfg`.
  Every change that adds packages or kernel features MUST report the resulting `rootfs.ext4`
  used size and boot partition usage, and MUST NOT push either above 80% of its partition
  without resizing deliberately and noting it. Enable only packages the board needs; prefer
  BusyBox applets over full packages.
- **Boot time and runtime**: changes to init, kernel config, or bootloader environment that
  plausibly affect boot time MUST record time-to-login-prompt before and after (serial
  timestamps or `dmesg`/`systemd-analyze`-equivalent). A regression larger than 10% needs
  justification in the PR.
- **Dependencies**: add a package, host tool or kernel option only when a stated requirement
  needs it; remove it when the requirement goes away.
- TODO(PERF_BASELINES): record the measured baseline for `beaglebone_black` (rootfs used size,
  boot partition usage, time-to-login, clean and incremental build times) in the README so the
  thresholds above become absolute numbers.

Rationale: embedded targets are resource-constrained and a one-hour build makes needless rebuilds
expensive.

### VII. Secure and Safe Defaults

- No secrets, credentials, keys or tokens are committed. Downloaded artifacts are
  hash-verified (Principle II).
- Build as the unprivileged `br` user; never as root. Flashing instructions that use `dd` MUST
  keep a prominent device-selection warning.
- The current development images allow passwordless `root` login (documented in the README).
  This is acceptable ONLY for development images. Any image intended for deployment MUST be a
  distinct variant (`<board>_prod_defconfig` or equivalent) with root login disabled or
  password-protected and with debug-only packages removed. New defaults MUST NOT widen exposure
  (open ports, services) without a documented reason.
- Kernel/U-Boot version bumps SHOULD track upstream stable security releases; deferring one MUST
  be a conscious, recorded decision.

Rationale: OTA images are eventually field-deployed; development conveniences must not silently
become production exposure.

## Technical Constraints

- **Stack**: Buildroot (submodule on the `2026.08.x` stable branch) as BR2_EXTERNAL `OTA`;
  Docker (Debian bookworm) build environment with host-side GNU Make and Git only; external
  Bootlin toolchain per board; genimage for SD images.
- **Container base**: the `Dockerfile` base image SHOULD be pinned by digest or dated tag once
  stability matters, and the pin updated deliberately (TODO tracked under Principle II).
- **Layout** is as documented in CLAUDE.md and README.md; new top-level directories require a
  documented purpose.
- **Kernel/U-Boot configuration** starts from in-tree defconfigs. Customization MUST switch to
  `*_USE_CUSTOM_CONFIG` with a file under `board/ota/<board>/`, generated by
  `make linux-update-defconfig` (same for U-Boot), not hand-edited fragments of unknown origin.
- **Portability**: no dependency on the developer's host distribution; paths are relative to the
  repo or Buildroot-exported variables.

## Development Workflow & Quality Gates

1. **Plan**: features and non-trivial changes go through the Spec Kit flow
   (`specify → plan → tasks → implement`). The plan's Constitution Check MUST evaluate Principles
   I–VII and record any deviation in its complexity-tracking table.
2. **Implement**: smallest change that satisfies the spec; follow Principle III style; no
   unrelated edits in the same commit.
3. **Verify**: run the checks in the Principle IV table that match the change; capture the
   evidence (commands, resulting sizes, boot log excerpt).
4. **Review**: the reviewer (or self-review for single-maintainer work, done explicitly against
   this list) confirms: upstream untouched; hashes present; defconfig round-trips; docs updated;
   size/boot figures reported; verification evidence present.
5. **Merge/commit**: single-purpose commits with English messages; Buildroot bumps and
   toolchain/kernel/U-Boot version changes are separate commits.

A change that cannot meet a gate MUST state which gate, why, and the follow-up that closes it;
silent skipping is a violation.

## Governance

This constitution supersedes other practices and ad-hoc preferences for this repository.
CLAUDE.md and README.md provide runtime guidance and MUST remain consistent with it; on conflict,
the constitution wins and the conflicting document is corrected in the same change.

- **Compliance**: every plan, PR and review MUST check against Principles I–VII. Deviations
  require a written justification (what rule, why unavoidable, simpler alternative rejected,
  expiry or follow-up) in the plan's complexity-tracking section or the PR description.
  Unjustified deviations block merge.
- **Technical decisions**: when options conflict, resolve in this order — safety/integrity
  (II, IV, VII) over compatibility and consistency (I, V) over footprint and speed (VI) over
  convenience. Choose the option with the smaller footprint on the BR2_EXTERNAL tree when the
  higher-order concerns are equal. Record non-obvious decisions in the commit body.
- **Amendments**: propose a change to `.specify/memory/constitution.md` via
  `/speckit-constitution`, with the rationale and a migration note when existing files would
  become non-compliant. An amendment is accepted when the maintainer approves it and affected
  documents (README.md, CLAUDE.md, templates' runtime references) are updated in the same or an
  immediately following change.
- **Versioning** (semantic): MAJOR for removing or redefining a principle or governance rule in a
  backward-incompatible way; MINOR for adding a principle or section or materially expanding
  guidance; PATCH for clarifications, wording and typo fixes.
- **Review cadence**: re-read this constitution on every Buildroot bump and when the first CI or
  second board lands, since those events change which gates can be automated and which numeric
  budgets (Principle VI) are meaningful.

**Version**: 1.0.0 | **Ratified**: 2026-10-18 | **Last Amended**: 2026-10-18
