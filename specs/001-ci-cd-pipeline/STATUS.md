# Status: CI/CD pipeline (001)

Last updated: 2026-10-22. State: **paused**, implementation complete.

## Why it is paused

The first `ci` run on GitHub failed before any step ran because the repository owner's GitHub
account billing was locked ("Your payment authorization has failed"). This is an account problem,
not a defect in the workflows. No code change is needed to resume.

## What is verified (locally, in the build container)

- `make docker-check` passes on a clean tree; seven seeded failures are each caught by name.
- `actionlint` is clean on `ci.yml` and `build.yml`.
- The `build.yml` build command for `beaglebone_black` exits 0; the partition layout matches
  `genimage.cfg`. This was an incremental build, so there is no cold-build baseline yet.

## What is not verified (needs GitHub runners)

T016, T023, T024, T029, T030, T035, T037 in `tasks.md`. T036 (constitution PATCH bump to 1.0.1)
needs the maintainer's approval.

## How to resume

1. Resolve the billing lock, then re-run the failed `ci` run (Actions tab). No new push needed.
2. Record the `make docker-check` duration, split into `docker-build` and the checks, and the
   total job time. SC-001 targets under 10 minutes.
3. Continue with the open tasks in `tasks.md` in order. Take baselines (T035) only from real runs.
4. Check that `.specify/feature.json` points to `specs/001-ci-cd-pipeline`; a later feature's
   `/speckit-specify` overwrites it.

## Decisions not recorded elsewhere

- **Docker image caching: measure first.** The environment image is rebuilt from scratch on every
  CI run (about 1 minute locally). Keep that design. Add a layer cache only if `ci.yml` exceeds
  about 10 minutes on the first real runs, trying buildx `type=gha` or an `actions/cache` tarball
  before GHCR. GHCR trade-offs: the UID is baked into the image while runners use UID 1001,
  `packages: write` permission, a public package, digest pinning, and Dockerfile changes becoming
  a two-step process.
- **Open analysis findings (MEDIUM/LOW), deliberately left:** C2 (runner tools `jq`, `xz`, `gh`
  not noted in the plan), A1 (SC-001 "warm environment" wording), U1 (FR-002 "boot files
  referenced" versus T010 checking only DTBs), A2, U2, G1, G2, T1, T2. None blocks resuming.
