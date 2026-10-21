# Data Model: Automated CI/CD Pipeline

There is no persistent store. These entities are the records the pipeline produces; their
"storage" is the CI system's own run, artifact, cache and release records.

## Check run
Execution of `make docker-check` for one commit/PR.
- **Fields**: commit SHA; trigger (`push` | `pull_request`); per-check results (shell syntax,
  shell lint, defconfig round-trip, make dry run, image-layout consistency, board parity,
  environment build); verdict; log.
- **Rules**: verdict is pass only if every check passes (FR-001). A superseded run on the same
  ref is cancelled (edge case: concurrent runs).
- **States**: `queued -> running -> (passed | failed | cancelled)`.

## Board build
Execution of the full image build for one board at one commit.
- **Fields**: board name (from `configs/<board>_defconfig`); commit SHA; trigger (`manual` | `tag`);
  tag name (tag runs only); start/end time; verdict; failure reason (`build error` |
  `disk exhausted` | `time limit`).
- **Rules**: one per board per run, independent of others (FR-006); board list derived from
  `configs/` (FR-010); empty list is an error.
- **States**: `queued -> running -> (succeeded | failed | cancelled)`.

## Image artifact
Output of a succeeded Board build.
- **Fields**: board; commit SHA; `sdcard.img.xz` (compressed flashable image, or documented
  equivalent); `build-info` (board, version, Buildroot version, copied from the image);
  `SHA256SUMS`; retention (14 days).
- **Rules**: exists only for succeeded builds (FR-008); name is `<board>-image`.
- **States**: `available -> expired` (after retention).

## Release
Draft collection created for a release tag.
- **Fields**: tag (`v*`); draft flag; assets (every board's `sdcard.img.xz`, combined
  `SHA256SUMS`); notes (image variant per file, dev-image warning, "not boot-tested" statement).
- **Rules**: created only when every Board build for the tag succeeded (FR-009); created as draft
  and never published by automation; a maintainer publishes after a hardware boot test.
- **States**: `absent -> draft -> published` (last transition is manual).

## Source cache
Reusable store of downloaded sources (`dl/`).
- **Fields**: key (board, hash of defconfig + patches + package definitions, Buildroot
  submodule SHA); size; last used.
- **Rules**: keyed so config or Buildroot changes invalidate it (FR-007); download hash checking
  stays enabled, so content is verified regardless of cache provenance; a missing or corrupt
  entry only slows the build.
- **States**: `miss -> saved -> restored -> evicted`.

## Relationships
Check run and Board build are independent executions on a commit. A tag commit yields N Board
builds (one per board) -> N Image artifacts -> 0 or 1 Release. Board builds read and write the
Source cache.
