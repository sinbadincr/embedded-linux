# Research: Automated CI/CD Pipeline

All Technical Context unknowns are resolved here. No `NEEDS CLARIFICATION` remains.

## R1. Where the fast checks live, and how CI and local runs stay identical

- **Decision**: One POSIX `sh` script, `scripts/check.sh`, run by a new in-container Makefile target
  `make check`. A new host target `make docker-check` runs `docker-build` and then
  `docker run ... make check`. CI calls `make docker-check`; a contributor runs the same command.
- **Rationale**: Spec FR-001/SC-003 need one command with the same verdict locally and in CI. The
  `/.dockerenv` guard (Principle II) means `check` runs in the container, while "rebuild the
  environment from scratch" (FR-002) can only run on the host, so the host wrapper is what
  unifies them. Logic in a script (not Makefile recipes) keeps the Makefile small and lets
  `shellcheck` cover it (Principle III).
- **Alternatives**: all logic in Makefile recipes (hard to lint, long shell-in-make); a workflow
  that duplicates the commands inline (CI and local drift apart, violates SC-003); a Python or
  Node checker (new host dependency, no benefit).

## R2. What `scripts/check.sh` verifies

| Check | How | Source requirement |
|---|---|---|
| Shell syntax | `sh -n` on every `*.sh` outside `buildroot/` and `output/` | FR-002 |
| Shell lint | `shellcheck` on the same files | FR-002, Principle IV |
| Defconfig round-trip | for each `configs/*_defconfig`: `make <b>_defconfig`, `make savedefconfig BR2_DEFCONFIG=<tmpfile under output/<b>/>`, then `cmp` the temp file with the working-tree `configs/<b>_defconfig` (no git state, no writes to `configs/`); restore `.current_board` afterwards | FR-002, Principle IV |
| Makefile dry run | `make -n BOARD=<b> build` for each board | FR-002, Principle IV |
| Image-layout consistency | every `*.dtb` implied by `BR2_LINUX_KERNEL_INTREE_DTS_NAME` is listed in `board/ota/<b>/genimage.cfg`, and every `.dtb` in genimage.cfg is built | FR-002, Principle IV "artifact consistency" |
| Board parity | each board has `board/ota/<b>/{genimage.cfg,post-image.sh,rootfs_overlay}` | FR-010, Principle V |

- **Rationale**: `savedefconfig` only needs Buildroot's host `conf` tool (built in seconds), not
  the toolchain, so the round-trip is cheap. Existence of files named in `genimage.cfg` inside
  `BINARIES_DIR` can only be checked after a build; genimage itself fails when one is missing, so
  the build job relies on that (no duplicate check).
- **Alternatives**: `hadolint` for the Dockerfile (not requested, extra tool); checking `.hash`
  coverage for custom kernel/U-Boot versions (valuable but outside the spec; candidate follow-up).

## R3. Tooling inside the build container

- **Decision**: add `shellcheck` to the `Dockerfile` apt list.
- **Rationale**: Principle II forbids relying on host tools and `apt-get` in a running container;
  Debian bookworm ships shellcheck 0.9.0. This means a Dockerfile change, so it is verified by a
  from-scratch `make docker-build` (Principle IV).
- **Alternatives**: a third-party shellcheck GitHub Action (host dependency outside the
  container, extra supply-chain surface).

## R4. Workflow shape

- **Decision**: two workflows.
  - `ci.yml`: `on: push` and `pull_request`; one job; checkout with submodules; `make docker-check`;
    `permissions: contents: read`; concurrency group per ref with `cancel-in-progress: true`.
  - `build.yml`: `on: workflow_dispatch` and `push: tags: ['v*']`; jobs `boards` -> `build`
    (matrix, `fail-fast: false`) -> `release` (tag only).
- **Rationale**: Matches the clarified trigger policy (builds only on manual/tag, never PR or
  schedule). Splitting keeps the fast path permissionless and fast; only the `release` job gets
  `contents: write`.
- **Alternatives**: a single workflow with conditional jobs (more `if:` logic, broader default
  permissions); `pull_request_target` (unneeded risk for fork PRs).

## R5. Board matrix without editing the workflow

- **Decision**: `boards` job lists `configs/*_defconfig`, strips the suffix, emits a JSON array via
  `jq` (preinstalled on hosted runners) as a job output consumed by `strategy.matrix`. It fails if
  the list is empty.
- **Rationale**: FR-010 (zero automation edits for a new board) and the "no boards" edge case.
  Variants such as `beaglebone_black_dev` are also boards in `make list-boards`, so they are
  built too, consistent with the Makefile's own definition.
- **Alternatives**: static matrix in YAML (needs an edit per board); calling `make list-boards`
  (requires the container just to list files).

## R6. Build execution and runner UID

- **Decision**: in `build`, run `make docker-build` (passes the runner's `id -u`/`id -g`, typically
  1001) and then `docker run --rm -v "$PWD:/workspace" -w /workspace ota-build-env:latest sh -c
  'make <b>_defconfig && make build'`. Single bind mount only.
- **Rationale**: Reuses the documented build path (Principle II), keeps `output/` and `dl/` on one
  filesystem (avoids `EXDEV`), and file ownership matches the runner user so cache/artifact steps
  can read them. The image's `USER br` already carries the build-arg UID.
- **Alternatives**: `container:` job on a prebuilt registry image (needs a registry, secrets and
  digest pinning; deferred); `docker run -u` override (redundant, image user already matches).

## R7. Source cache (`dl/`)

- **Decision**: `actions/cache/restore` before the build and `actions/cache/save` with
  `if: always()` after it, key `dl-<board>-<hash of configs/<board>_defconfig, patches/**,
  package/**>-<buildroot submodule SHA>`, `restore-keys: dl-<board>-` then `dl-`.
- **Rationale**: FR-007 invalidation on config/Buildroot change; `save` on failure preserves
  downloads when a late stage fails after a long fetch. `BR2_DOWNLOAD_FORCE_CHECK_HASHES=y`
  stays on, so a stale or tampered cache entry cannot produce an unverified input (Principle II).
  The cache saves network fetches, not compile time (kernel and U-Boot compilation dominates a
  build), so SC-004 measures downloads avoided (0 on an exact-key hit), not wall-clock speedup.
  Downloads are counted as files newly added to `dl/` (before/after listing), not from the log:
  Buildroot prints `Downloading` for every package even when the archive is already cached.
  Cache size (about 1-2 GB per board) fits the repository's 10 GB cache budget for a few boards;
  least-recently-used eviction is acceptable (cold build is only slower, per edge cases).
- **Alternatives**: caching `output/` or ccache (large, risk of non-reproducible state, and
  Principle VI warns against cache tricks that hide rebuild cost); a single shared key for all
  boards (one board's changes evict the others').

## R8. Runner disk and time limits

- **Decision**: first step removes preinstalled toolchains the build never uses (`/usr/share/dotnet`,
  `/usr/local/lib/android`, `/opt/ghc`, `/opt/hostedtoolcache/CodeQL`) with plain `rm -rf`, no
  third-party action; `timeout-minutes: 350` (below the 6 h hard cap so the failure is ours and
  named); a `if: failure()` step prints `df -h` and emits `::error::` naming the exhausted disk
  or the elapsed time against the limit.
- **Rationale**: FR-007a. Hosted standard runners have about 14 GB free; a single-board build
  (toolchain download, kernel, U-Boot, rootfs, 530 MB image) is estimated at 6-8 GB, so it fits
  after cleanup. The first real run measures it; if it does not fit, the spec's out-of-scope
  larger runner becomes a follow-up decision, not a silent change.
- **Alternatives**: third-party "free disk space" actions (supply-chain surface); building on
  larger paid runners (out of scope by clarification).

## R9. Artifacts and release

- **Decision**: per board, compress `sdcard.img` with `xz -T0`, add `SHA256SUMS` and a copy of
  `output/<b>/target/etc/build-info`, upload as artifact `<board>-image` with
  `retention-days: 14`. The `release` job (tag only, `contents: write`) downloads all
  `*-image` artifacts, merges checksums, and runs `gh release create "$GITHUB_REF_NAME" --draft`
  with the images, a combined `SHA256SUMS`, and generated notes. No release is created when any
  matrix job failed (`needs` without `if: always()`).
- **Rationale**: Raw `sdcard.img` is about 530 MB and mostly empty space; xz makes uploads and
  downloads far smaller (SC-005). `--draft` implements the clarified policy; `gh` is preinstalled
  and uses `GITHUB_TOKEN` (no secrets, Principle VII). Notes state image variant and the
  passwordless-root caveat (FR-009a) and that a boot smoke test is still required (FR-013).
- **Alternatives**: third-party release actions (supply-chain); uploading raw images (slow,
  wasteful); publishing the release directly (rejected in clarification).

## R10. Pinning and trust

- **Decision**: only first-party `actions/*` actions (`checkout`, `cache`, `upload-artifact`,
  `download-artifact`), each pinned to a full commit SHA with the version in a trailing comment;
  SHAs are resolved and verified at implementation time, not guessed in this plan.
- **Rationale**: Principle II (no floating references) and VII (no widened exposure). Dependabot
  or manual bumps are a follow-up.
- **Alternatives**: major-version tags (floating, mutable).

## R11. Boot smoke test

- **Decision**: not automated in this feature. CI states in the release notes and docs that a
  green build is not a boot test (FR-013).
- **Rationale**: BeagleBone Black cannot be booted on stock QEMU to the same fidelity; the spec
  scopes hardware testing out. Principle IV's "known gaps" note is narrowed, not removed.

## R12. Documentation and constitution follow-up

- **Decision**: same change updates `README.md`, `CLAUDE.md` and `make help` (Principle V). After
  the checks exist, run `/speckit-constitution` for a PATCH bump to 1.0.1 that rewrites the
  Principle IV "Known gaps" bullet (CI and check target now exist; boot test still manual).
