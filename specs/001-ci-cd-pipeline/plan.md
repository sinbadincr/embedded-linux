# Implementation Plan: Automated CI/CD Pipeline

**Branch**: `001-ci-cd-pipeline` | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-ci-cd-pipeline/spec.md`

## Summary

Add fast, identical-everywhere verification (`make check` in the container, wrapped by
`make docker-check` on the host) and two GitHub Actions workflows: `ci.yml` runs
`make docker-check` on every push/PR; `build.yml` builds every board's image on manual trigger or
`v*` tag with a cached `dl/`, uploads xz-compressed images as 14-day artifacts, and on tags creates
a **draft** GitHub Release for a maintainer to publish after a hardware boot test. Hosted standard
runners only; no PR builds, no schedule.

## Technical Context

**Language/Version**: POSIX `sh` (check script), GNU Make, GitHub Actions YAML; Debian bookworm
build container; Buildroot 2026.08.x (unchanged)

**Primary Dependencies**: `shellcheck` (added to the Dockerfile), Docker, `jq`/`gh`/`xz` already on
hosted runners; first-party `actions/{checkout,cache,upload-artifact,download-artifact}` pinned by SHA

**Storage**: N/A (CI-held artifacts, caches and releases; see data-model.md)

**Testing**: no unit framework (Principle IV); verification is seeded-failure runs of
`make docker-check`, a manual and a tag-triggered workflow run, and `actionlint`/`shellcheck`
on new files (see quickstart.md)

**Target Platform**: GitHub-hosted `ubuntu-24.04` runners (pinned label, not `ubuntu-latest`, per Principle II); local Linux hosts with Docker

**Project Type**: build-system / infrastructure repo (Buildroot BR2_EXTERNAL tree)

**Performance Goals**: fast checks verdict under 10 min (SC-001); repeat board build with unchanged
inputs downloads 0 source archives (SC-004); image retrievable in under 2 min (SC-005)

**Constraints**: single `/workspace` volume; build as unprivileged user; hash checking stays on;
runner about 14 GB disk and 6 h job cap; `/.dockerenv` guard untouched; no secrets

**Scale/Scope**: 1 board today (`beaglebone_black`), matrix grows with `configs/`; cache budget
10 GB per repository

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment | Status |
|---|---|---|
| I. Upstream immutable | Nothing under `buildroot/` is touched; all changes are in the external tree plus `.github/`. The check reads the submodule but does not write it. | Pass |
| II. Reproducible, contained, integrity-checked | All build commands run through the container with one `/workspace` mount; `/.dockerenv` guard unchanged; the host tool need (`shellcheck`) is met by editing the Dockerfile; `BR2_DOWNLOAD_FORCE_CHECK_HASHES` stays on so a cache cannot bypass verification; actions pinned by SHA (no floating refs). | Pass |
| III. Code quality | `scripts/check.sh` is POSIX `sh`, `set -eu`, quoted, header comment, no board logic in `common/`; new Makefile targets are `.PHONY`, fail with actionable stderr messages, keep the catch-all intact; English only; no speculative options. | Pass |
| IV. Verification | Plan includes: `sh -n` + shellcheck of new scripts, `make -n` of new targets from host and container with error paths, from-scratch `make docker-build` (Dockerfile changed), a real board build via the new workflow, boot smoke test still manual and explicitly not replaced. This feature also closes the "no CI / no lint / no `make check`" gap. | Pass |
| V. Consistent experience | Public `make` surface only gains `check` and `docker-check`; README, CLAUDE.md and `make help` updated in the same change; error messages follow `check_env` style; board parity enforced by the check. | Pass |
| VI. Performance and footprint | `dl/` cached per board with a restore/save split; no change to what Buildroot rebuilds; job summary reports image size and elapsed time; `PERF_BASELINES` TODO gets its first measured build time from the first real run. | Pass |
| VII. Secure defaults | No secrets; `GITHUB_TOKEN` only; default `contents: read`, `contents: write` only on the tag-only release job; third-party actions avoided; release is a draft and notes carry the dev-image/passwordless-root warning because the repository is public. | Pass |

**Post-design re-check**: unchanged after Phase 1; no violations. Complexity Tracking not needed.

**New top-level paths (documented purpose, per Technical Constraints)**: `scripts/` holds repo-level
maintenance scripts (currently `check.sh`); `.github/` holds CI definitions.

## Project Structure

### Documentation (this feature)

```text
specs/001-ci-cd-pipeline/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── cli.md           # make check / docker-check
│   └── workflows.md     # ci.yml / build.yml / release contract
└── tasks.md             # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
.github/workflows/
├── ci.yml               # push/PR: make docker-check
└── build.yml            # manual/tag: matrix board builds, artifacts, draft release
scripts/
└── check.sh             # fast checks (POSIX sh)
Makefile                 # + check, docker-check, help lines
Dockerfile               # + shellcheck
README.md                # + CI / checks / releases section, flashing .xz images
CLAUDE.md                # + commands and architecture notes
.specify/memory/constitution.md   # PATCH 1.0.1 after implementation (via /speckit-constitution)
```

**Structure Decision**: single repo, no source tree: one script, one Makefile delta, one
Dockerfile line, two workflows, docs. The script lives in a new `scripts/` directory rather than
`board/ota/common/` because it is not part of any image (Principle III: no leakage into the
board tree).

## Complexity Tracking

No constitution violations to justify.
