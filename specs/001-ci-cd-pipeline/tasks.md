---

description: "Task list for the Automated CI/CD Pipeline feature"
---

# Tasks: Automated CI/CD Pipeline

**Input**: Design documents from `/specs/001-ci-cd-pipeline/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, contracts/workflows.md, quickstart.md

**Tests**: No unit-test framework exists (Principle IV) and none was requested. Verification tasks
(marked "Verify") run the checks the constitution requires and record evidence for the commit/PR.

**Organization**: Grouped by user story so each can be implemented and verified independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 fast checks, US2 board builds, US3 artifacts and releases
- All shell is POSIX `sh`, `set -eu`, quoted expansions, one-line header comment (Principle III)
- Everything committed is English

## Phase 1: Setup

**Purpose**: Resolve inputs every later task needs

- [X] T001 Create `scripts/` and `.github/workflows/` directories (empty dirs are created by the first file added to each; this task only fixes the layout from plan.md)
- [X] T002 Resolve and record the full commit SHAs (with version tag in a trailing comment) for `actions/checkout`, `actions/cache`, `actions/upload-artifact` and `actions/download-artifact` using `git ls-remote --tags https://github.com/actions/<name>` or `gh api`; keep the table in `specs/001-ci-cd-pipeline/contracts/workflows.md` (Pinning) so workflow tasks can copy them

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The container must carry the lint tool before any check can run

**CRITICAL**: US1 cannot be verified until this is done

- [X] T003 Add `shellcheck` to the apt package list in `Dockerfile` (under the build-tools or misc group, keep one package per line and the existing comment style)
- [X] T004 Verify (Principle IV, Dockerfile row): `make docker-build` from scratch succeeds and `docker run --rm ota-build-env:latest shellcheck --version` prints a version

**Checkpoint**: container has `shellcheck`; user story work can begin

---

## Phase 3: User Story 1 - Fast automatic checks on every change (Priority: P1) MVP

**Goal**: One command, `make docker-check`, runs all fast checks locally and in CI with the same verdict.

**Independent Test**: Quickstart steps 1-3: clean tree passes; each seeded failure is reported by name; a pushed PR runs `ci` and goes green/red accordingly.

### Implementation for User Story 1

- [X] T005 [US1] Create `scripts/check.sh` skeleton: header comment, `set -eu`, repo-root resolution, a `fail()` helper that records the failure to stderr with the remedy and continues, a final summary that exits non-zero if any check failed (contracts/cli.md output format `ok:` / `FAIL:`)
- [X] T006 [US1] In `scripts/check.sh` add the shell syntax check: `sh -n` on every `*.sh` tracked by git outside `buildroot/` and `output/` (FR-002)
- [X] T007 [US1] In `scripts/check.sh` add the shell lint check: `shellcheck` on the same file set; a missing `shellcheck` is a failure that tells the user to run `make docker-build`
- [X] T008 [US1] In `scripts/check.sh` add the defconfig round-trip: for each `configs/*_defconfig` run `make <b>_defconfig`, then `make savedefconfig BR2_DEFCONFIG=<tmpfile>` with `<tmpfile>` created under `output/<b>/`, and `cmp` the temp file against the working-tree `configs/<b>_defconfig`; never write to `configs/` and never rely on git state, so uncommitted edits are checked too; restore the original `.current_board` afterwards (remove it if it did not exist) and delete the temp file; the failure message names the board, shows the `diff` of the two files, and gives `make <b>_defconfig && make savedefconfig` as the remedy
- [X] T009 [US1] In `scripts/check.sh` add the Makefile dry run: `make -n BOARD=<b> build >/dev/null` for each board (FR-002, Principle IV Makefile row)
- [X] T010 [US1] In `scripts/check.sh` add the image-layout consistency check: every basename of `BR2_LINUX_KERNEL_INTREE_DTS_NAME` in `configs/<b>_defconfig` appears as `<name>.dtb` in `board/ota/<b>/genimage.cfg` and every `*.dtb` in genimage.cfg is built by the defconfig (Principle IV artifact consistency)
- [X] T011 [US1] In `scripts/check.sh` add the board-parity check: each board has `board/ota/<b>/genimage.cfg`, `board/ota/<b>/post-image.sh` and `board/ota/<b>/rootfs_overlay/`, and its defconfig lists `board/ota/common/rootfs_overlay` before the board overlay and `board/ota/common/post-build.sh` (Principles V, III; edge case "new board without required files")
- [X] T012 [US1] Add `check` and `docker-check` to `Makefile`: declare both in `.PHONY`; `check` uses `$(check_env)` and runs `sh scripts/check.sh`; `docker-check` depends on `docker-build` and runs `docker run --rm -v $(ROOT_DIR):/workspace -w /workspace -u $(USER_ID):$(GROUP_ID) $(DOCKER_IMAGE_NAME) make check`; add one line each to the `help` recipe; place `check` above the catch-all `%:` rule
- [X] T013 [US1] Create `.github/workflows/ci.yml` per contracts/workflows.md: `on: push` and `pull_request`, `permissions: contents: read`, concurrency group per ref with `cancel-in-progress: true`, one job on `ubuntu-24.04` (pinned label, never `ubuntu-latest`) that checks out with `submodules: recursive` (SHA from T002) and runs `make docker-check`
- [X] T014 [US1] Verify (Principle IV): `sh -n` and `shellcheck` clean on `scripts/check.sh`; `make -n check` and `make -n docker-check` from the host; `make check` outside the container fails with the existing `check_env` message (stderr, non-zero); `make docker-check` passes on the clean tree
- [X] T015 [US1] Verify quickstart step 2: run each seeded failure from the table on a scratch branch, confirm the named failure, discard the changes; record the output lines for the commit message
- [X] T016 [US1] Verify quickstart step 3: push the branch, open a PR, confirm `ci` passes under 10 minutes (SC-001) and fails on one seeded change

**Checkpoint**: US1 is independently usable; this is the MVP and closes the "no CI / no `make check`" gap.

---

## Phase 4: User Story 2 - Full board image builds on demand and on release tags (Priority: P2)

**Goal**: Every board in `configs/` builds in its own job on manual trigger or `v*` tag, with a cached `dl/`.

**Independent Test**: Quickstart step 4 (manual run, then a faster re-run using the cache).

### Implementation for User Story 2

- [X] T017 [US2] Create `.github/workflows/build.yml` with `on: workflow_dispatch` and `push: tags: ['v*']` (no `pull_request`, no `schedule`), default `permissions: contents: read`, concurrency group per ref with `cancel-in-progress: false`
- [X] T018 [US2] In `.github/workflows/build.yml` add job `boards`: checkout, derive the list from `configs/*_defconfig` (strip directory and `_defconfig`), emit it with `jq -c` as a job output, and fail with a clear error if the list is empty (FR-010, edge case "no boards")
- [X] T019 [US2] In `.github/workflows/build.yml` add job `build` (`runs-on: ubuntu-24.04`, `needs: boards`, `strategy.matrix.board` from `fromJSON`, `fail-fast: false`, `timeout-minutes: 350`) with steps: checkout (`submodules: recursive`, `fetch-depth: 0` so `git describe` in `board/ota/common/post-build.sh` yields a meaningful VERSION), free runner disk with plain `rm -rf` of `/usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL` (research R8), `make docker-build`
- [X] T020 [US2] In the `build` job add the cache steps: `actions/cache/restore` for `dl/` before the build with key `dl-<board>-${{ hashFiles('configs/<board>_defconfig', 'patches/**', 'package/**') }}-<buildroot submodule SHA from git rev-parse HEAD:buildroot>` and `restore-keys` `dl-<board>-` then `dl-`; `actions/cache/save` with `if: always()` after the build step (research R7)
- [X] T021 [US2] In the `build` job add the build step: `docker run --rm -v "$PWD:/workspace" -w /workspace ota-build-env:latest sh -c 'make <board>_defconfig && make build'`, single `/workspace` mount only (Principle II), board name passed via env not string-interpolated into the script
- [X] T022 [US2] In the `build` job add the `if: failure()` step that prints `df -h` and writes an `::error::` naming the exhausted limit (disk free under 1 GiB, or elapsed time near `timeout-minutes`), and a final step that writes `$GITHUB_STEP_SUMMARY` with `ls -lh output/<board>/images`, elapsed time, the `dl/` cache result (`cache-hit` output of the restore step) and the number of source downloads counted as files newly added to `dl/` during the build (diff of `find dl` before and after; Buildroot prints `Downloading` for every package even when the archive is already cached, so the log cannot be used) (FR-007, FR-007a, SC-004, Principle VI)
- [X] T023 [US2] Verify (Principle IV, overlay/image row): run `build` manually for `beaglebone_black`; confirm `output/beaglebone_black/images/sdcard.img` exists and its partition layout via `fdisk -l` matches `genimage.cfg` (16M boot + 512M rootfs); record the first cold build duration and cache size
- [X] T024 [US2] Verify quickstart step 4 re-run: confirm the job summary reports an exact-key `dl/` cache hit and 0 source downloads (SC-004); confirm `build` does not run on a PR or on push to a branch

**Checkpoint**: US2 works with no artifact upload yet; builds are verifiable from the logs.

---

## Phase 5: User Story 3 - Downloadable images and tagged releases (Priority: P3)

**Goal**: Each succeeded board build yields a downloadable image; a tag yields a draft Release.

**Independent Test**: Quickstart steps 4-5.

### Implementation for User Story 3

- [X] T025 [US3] In the `build` job of `.github/workflows/build.yml` add the packaging step: `xz -T0 -k` of `output/<board>/images/sdcard.img` into a staging dir, copy `output/<board>/target/etc/build-info`, write `SHA256SUMS` over the staged files (research R9)
- [X] T026 [US3] In the `build` job add `actions/upload-artifact` (SHA from T002) named `<board>-image` with `retention-days: 14`, uploading `sdcard.img.xz`, `SHA256SUMS`, `build-info` (FR-008, data-model Image artifact)
- [X] T027 [US3] In `.github/workflows/build.yml` add job `release` (`needs: build`, `if: github.ref_type == 'tag'`, `permissions: contents: write`) that downloads all `*-image` artifacts, renames each image to `<board>-sdcard.img.xz`, merges checksums into one `SHA256SUMS`, and runs `gh release create "$GITHUB_REF_NAME" --draft` with those assets using `GITHUB_TOKEN` (FR-009; no `if: always()`, so any failed board skips the job)
- [X] T028 [US3] In the `release` job generate the notes file: per asset the image variant, for development images a statement that they allow passwordless root login and are not for deployment, and that a boot smoke test on hardware is required before publishing (FR-009a, FR-013, Principle VII); the notes text lives in a heredoc in the workflow, not an external download
- [X] T029 [US3] Verify quickstart step 4 download: fetch one artifact, `sha256sum -c SHA256SUMS`, `xzcat sdcard.img.xz | head -c 512 | file -` shows a DOS/MBR boot sector (SC-005)
- [X] T030 [US3] Verify quickstart step 5: push a test tag; confirm a **draft** release with `<board>-sdcard.img.xz`, `SHA256SUMS` and the required notes; then break one board on a scratch branch tag and confirm no release is created; delete the test tags and drafts

**Checkpoint**: all three stories work independently.

---

## Phase 6: Polish and Cross-Cutting Concerns

**Purpose**: Docs, linting of new files, constitution follow-up

- [X] T031 [P] Update `README.md`: new "Checks and CI" section (`make check`, `make docker-check`, what ci.yml and build.yml do, how to run a manual build, how releases are drafted and must be boot-tested before publishing), flashing instructions for the `.xz` image (`xzcat ... | sudo dd ...` keeping the device-selection warning), add `scripts/` and `.github/` to the Layout tree with their purpose (FR-012, FR-013, Principle V)
- [X] T032 [P] Update `CLAUDE.md`: add `make check` / `make docker-check` to Commands, `scripts/` and `.github/` to Layout, and an Architecture note on the CI split (fast checks vs tag/manual builds, single `/workspace` mount in CI, runner UID passed through `docker-build`)
- [X] T033 [P] Run `actionlint` on `.github/workflows/*.yml` (via a pinned container image or a downloaded binary, not installed into the build image) and fix findings; run `shellcheck` on any inline workflow scripts extracted to a temp file
- [X] T034 Verify docs consistency (Principle V): README.md, CLAUDE.md and `make help` list the same targets and do not contradict each other or `contracts/cli.md`
- [X] T035 Record the first measured baselines (cold and warm build time, `rootfs.ext4` and boot partition usage, artifact size) in `README.md` to start closing the `TODO(PERF_BASELINES)` in the constitution (Principle VI)
- [X] T036 Run `/speckit-constitution` for the PATCH bump to 1.0.1 rewriting the Principle IV "Known gaps" bullet (CI and `make check` now exist; boot smoke test still manual; shellcheck automated), and re-check Principles I-VII against the final diff (Governance: review cadence "first CI lands")
- [X] T037 Final end-to-end run of `quickstart.md` steps 1-6 (step 6, the hardware boot, is recorded manually) and write the verification evidence into the PR description

---

## Dependencies and Execution Order

- Phase 1 -> Phase 2 -> Phase 3 (US1) is the MVP path.
- US2 depends only on Phase 2 and on `make docker-build`; it does not need US1's script, but its workflow file follows the same pinning from T002. It can start after Phase 2, in parallel with US1 if staffed.
- US3 modifies the `build` job created in US2 (T025-T026) and adds the `release` job, so it follows US2.
- Phase 6 follows the stories it documents; T036 is last because it records that the gaps are closed.

### Within each story

- `scripts/check.sh` tasks T005-T011 edit one file and run in order.
- T012 depends on T005 existing; T013 depends on T012 (it calls `make docker-check`) and T002.
- `.github/workflows/build.yml` tasks T017-T022, T025-T028 edit one file and run in order.

### Parallel opportunities

- T031, T032 and T033 touch different files and can run together.
- US1 (T005-T016) and US2 (T017-T024) can proceed in parallel after Phase 2 if two people are working, but the two workflows are separate files, so no conflicts.

## Implementation Strategy

1. MVP: Phases 1-3. Stop and validate with quickstart steps 1-3, merge: the repo now has CI, lint and the round-trip gate.
2. Add US2, validate with a manual run (this is also when the 14 GB disk assumption from research R8 is tested; if it fails, stop and raise the runner decision rather than working around it).
3. Add US3, validate with a test tag.
4. Polish, constitution PATCH, final evidence.
5. One purpose per commit (Principle III): Dockerfile; check script + Makefile; `ci.yml`; `build.yml` (build); packaging and release; docs; constitution.
