# Feature Specification: Automated CI/CD Pipeline

**Feature Branch**: `001-ci-cd-pipeline`

**Created**: 2026-10-21

**Status**: Draft

**Input**: User description: "Add GitHub Actions CI/CD: on every push/PR run static checks (sh -n, shellcheck, defconfig round-trip, make -n, docker build) via a make check target; build board images on demand/tag in the build container with cached dl/; publish sdcard.img as artifact / GitHub Release on tags."

## Clarifications

### Session 2026-10-21

- Q: Which runners execute the jobs? → A: GitHub-hosted standard runners for both the fast checks and the board builds.
- Q: When do board builds run? → A: Only on manual trigger or release tag (confirmed; never on PR or schedule).
- Q: What happens when a board build exceeds the runner's time or disk limit? → A: The run fails clearly, naming the limit exceeded; reclaiming runner disk space before building is part of the job; nothing is published.
- Q: Is a tag-triggered release published publicly or left as a draft? → A: Created as a draft; a maintainer publishes it manually after the hardware boot smoke test.
- Q: Is the repository public or private? → A: Public; hosted runner minutes are free and release images are downloadable by anyone once published.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fast automatic checks on every change (Priority: P1)

A maintainer or contributor pushes a commit or opens a pull request. Without any manual step, the
project's static verification runs and reports pass/fail on the change within minutes, so broken
scripts, drifting board configurations and a broken build environment are caught before merge.
The same verification can be run locally with a single command, so a contributor sees the same
result before pushing.

**Why this priority**: This closes the "no CI, no lint automation" gap recorded in the
constitution (Principle IV) and delivers value on its own, with no long builds involved.

**Independent Test**: Push a branch containing a deliberately broken shell script (or a board
configuration that does not round-trip) and confirm the change is reported as failed with a message
naming the problem; push a correct change and confirm it is reported as passed.

**Acceptance Scenarios**:

1. **Given** a pull request with valid scripts, configurations and build environment, **When** it
   is opened or updated, **Then** the checks run automatically and report success.
2. **Given** a change that introduces a shell syntax or lint error, **When** the checks run,
   **Then** the change is reported as failed and the output names the offending file.
3. **Given** a board configuration that changes after being regenerated in minimal form, **When**
   the checks run, **Then** the change is reported as failed and the difference is shown.
4. **Given** a change to the build-environment definition that no longer builds, **When** the
   checks run, **Then** the change is reported as failed.
5. **Given** a contributor on their own machine, **When** they run the single documented check
   command, **Then** they get the same checks and the same verdict as the automatic run.

---

### User Story 2 - Full board image builds on demand and on release tags (Priority: P2)

A maintainer wants confidence that every supported board still builds into a flashable image,
without waiting on a long build for every pull request. Full image builds for all boards are
started manually and whenever a release tag is created. Repeated builds
reuse previously downloaded sources so they are noticeably faster than the first one.

**Why this priority**: It verifies the thing that actually ships (the images) but is slow and
resource-heavy, so it runs less often than the P1 checks.

**Independent Test**: Trigger a manual build; confirm one build per board runs, each succeeds or
fails independently, and a second run reuses cached sources.

**Acceptance Scenarios**:

1. **Given** the list of supported boards, **When** a full build is triggered manually, **Then**
   each board is built in its own job and the flashable image is produced for each.
2. **Given** a release tag is pushed, **When** the build runs, **Then** all boards are built from
   exactly the tagged commit.
3. **Given** one board fails to build, **When** the run completes, **Then** the other boards'
   results are still reported.
4. **Given** a previous successful run, **When** a build runs again with unchanged inputs,
   **Then** source downloads are reused rather than fetched again.

---

### User Story 3 - Downloadable images and tagged releases (Priority: P3)

After a full build, a maintainer or tester can download the flashable image for each board from the
run without building locally. When a release tag is created, the images are attached to a
draft release together with checksums; once a maintainer has boot-tested and published it,
testers and operators get a stable, verifiable download.

**Why this priority**: Convenience and distribution on top of the builds; the project is usable
without it.

**Independent Test**: After a successful full build, download the image for one board and verify it
against its checksum; push a release tag and confirm a draft release exists with all boards' images and
checksums attached.

**Acceptance Scenarios**:

1. **Given** a successful board build, **When** the run finishes, **Then** that board's flashable
   image is available for download from the run.
2. **Given** a release tag, **When** all board builds succeed, **Then** a draft release is
   created containing every board's image and a checksum file, for a maintainer to publish after
   a manual boot test.
3. **Given** a release tag where any board fails to build, **When** the run finishes, **Then** no
   release (draft or public) is created.

---

### Edge Cases

- The Buildroot submodule is missing or at the wrong commit: the run fails early with a message
  telling the maintainer to fetch submodules.
- The CI runner's user/group IDs differ from the build image defaults: files in the workspace are
  still writable and the run does not fail on permissions.
- Two runs start concurrently for the same branch: the older, superseded run is cancelled for
  change checks; release-tag runs are never cancelled.
- The cache is empty, evicted or corrupt: the build still succeeds, only slower.
- The runner does not have enough disk space or time for a full board build: the run fails with a
  message naming the limit exceeded rather than hanging, and nothing is published.
- A change comes from a fork (the repository is public): checks run, but no release or
  publishing step is possible and no secrets are exposed.
- A newly added board without the required files: the checks fail and name the missing file.
- No boards exist in `configs/`: the full build reports an error instead of silently succeeding.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A single documented command MUST run all fast verification checks locally and in
  automation, exit non-zero on any failure, and print an actionable message to stderr naming the
  failing check and file.
- **FR-002**: The fast checks MUST cover: syntax and lint of every shell script in the repo;
  regeneration of every board's minimal configuration producing no difference; a dry run of the
  affected documented build commands; consistency between each board's image layout file and the
  boot files it references; and a successful rebuild of the build environment from scratch.
- **FR-003**: The fast checks MUST run automatically on every push to a branch and every pull request
  targeting `master`, and the result MUST be visible on the change.
- **FR-004**: Build commands in automation MUST run inside the project's build environment, with
  the repository mounted as a single workspace volume, as an unprivileged user, preserving the
  rules in the constitution (Principles II, VII).
- **FR-005**: A full build of every board listed in `configs/` MUST be startable manually, MUST
  run when a release tag is created. No scheduled (nightly) builds are run.
- **FR-006**: Each board MUST be built independently so a failure on one board does not hide the
  result of another.
- **FR-007**: Downloaded source archives MUST be cached between runs, keyed so that a change in
  board configuration or the Buildroot version invalidates stale entries; hash verification of
  downloads MUST stay enabled.
- **FR-007a**: Before a board build, the job MUST free runner disk space not needed by the
  build, and a build that still exceeds the runner's time or disk limit MUST fail with a message
  naming the limit.
- **FR-008**: Each successful board build MUST make its flashable image (`sdcard.img` or the
  documented equivalent) and the build information of the image downloadable from the run, for a
  defined retention period.
- **FR-009**: When a release tag is created and every board builds successfully, a draft release
  MUST be created with each board's image and a checksum file attached; the automation MUST NOT
  publish it publicly (a maintainer does so after the boot smoke test); if any board fails, no
  release MUST be created.
- **FR-009a**: Because the repository is public, each release's notes MUST state which image
  variant each file is and, for development images, that they allow passwordless root login and
  are not for deployment (constitution Principle VII).
- **FR-010**: Adding a new board MUST require no edits to the automation: it is picked up from
  `configs/`.
- **FR-011**: The automation MUST NOT contain secrets in the repository and MUST grant only the
  minimum permissions each job needs; publishing permission is limited to release-tag runs.
- **FR-012**: README.md, CLAUDE.md and the `make help` output MUST describe the new check command
  and the automation behavior in the same change, and the constitution's "Known gaps" note MUST be
  updated once the checks exist.
- **FR-013**: The automation MUST NOT claim a boot test: documentation MUST state that a build
  passing does not replace the boot smoke test required for boot-affecting changes.

### Key Entities

- **Check run**: One execution of the fast verification for a commit or pull request; has a
  verdict and per-check results.
- **Board build**: One execution of the full image build for a single board at a given commit;
  has a verdict, duration and produced image.
- **Image artifact**: The flashable image and build information produced by a board build; has a
  board name, commit and retention period.
- **Release**: A published, tag-identified collection of every board's image plus a checksum
  file.
- **Source cache**: Reusable store of downloaded sources shared between board builds and runs.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A contributor receives the pass/fail verdict of the fast checks on a pull request
  within 10 minutes of pushing, on a warm environment.
- **SC-002**: 100% of the known-bad changes in a seeded set (broken script, non-minimal board
  configuration, missing referenced boot file, broken build environment) are reported as failed.
- **SC-003**: The same single local command gives the same verdict as the automatic run on 100%
  of sampled commits.
- **SC-004**: A repeat full build of a board with unchanged inputs downloads 0 source archives:
  100% of them are restored from the cache saved by an earlier run, and the run's summary states
  the cache result and the number of downloads.
- **SC-005**: A maintainer can obtain a flashable image for any supported board from a completed
  run in under 2 minutes without building locally.
- **SC-006**: Pushing a release tag results in a draft release with every board's image and
  checksums, with no manual step before the draft exists, in 100% of tag runs where all boards
  build.
- **SC-007**: Adding a new board requires zero changes to the automation to include it in
  checks and builds.
- **SC-008**: No secret or credential appears in the repository or in run logs.

## Assumptions

- The repository is hosted on GitHub and all jobs run on GitHub-hosted standard runners;
  self-hosted and paid larger runners are out of scope for this feature.
- The full build of one board fits within the hosted runner's time and disk limits; if it does
  not, a larger runner is a follow-up decision.
- Scheduled (nightly) builds are explicitly out of scope; full builds happen only on manual
  trigger or release tag.
- Image artifacts are kept for a limited period (default 14 days); releases are kept
  indefinitely.
- Release tags follow the `v*` pattern.
- Pull requests never run full board builds; they get the fast checks only.
- Boot smoke testing on hardware remains manual and is out of scope for this feature.
- The existing public developer interface (`docker-build`, `docker-shell`, `build`, ...) is not
  changed; only a new check command is added.
