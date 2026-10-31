# Contract: GitHub Actions workflows

## `.github/workflows/ci.yml`

| Item | Value |
|---|---|
| Runner | `ubuntu-24.04` (pinned label; every job in both workflows, never `ubuntu-latest`) |
| Triggers | `push` (all branches, not tags), `pull_request` targeting `master` |
| Permissions | `contents: read` only |
| Concurrency | group per ref, `cancel-in-progress: true` |
| Checkout | submodules recursive |
| Single step of substance | `make docker-check` |
| Secrets | none |
| Never does | board builds, publishing, cache writes |

## `.github/workflows/build.yml`

| Item | Value |
|---|---|
| Triggers | `workflow_dispatch` (no inputs), `push` of tags `v*`. No `pull_request`, no `schedule` |
| Default permissions | `contents: read` |
| Concurrency | group per ref, `cancel-in-progress: false` |

### Jobs

1. **boards**: derive the board list from `configs/*_defconfig`; output JSON array; fail if empty.
2. **build** (`needs: boards`, matrix `board`, `fail-fast: false`, `timeout-minutes: 350`):
   checkout (submodules recursive, full history and tags so the image `VERSION` is meaningful) ->
   free runner disk -> restore `dl/` cache -> write `keys/dev/` from the secrets
   `OTA_KEYRING_PEM`, `OTA_SIGNING_CERT_PEM`, `OTA_SIGNING_KEY_PEM` and verify the pair -> `make docker-build` -> build board in container ->
   compress image, write `SHA256SUMS`, copy `build-info` -> upload artifact `<board>-image`
   (retention 14 days) -> save `dl/` cache (`if: always()`) -> on failure, print disk usage and an
   error naming the exceeded limit. Writes a job summary with image size and elapsed time.
3. **release** (`needs: build`, only when `github.ref_type == 'tag'`, `permissions: contents: write`):
   download every `*-image` artifact -> merge checksums -> `gh release create <tag> --draft`
   with assets and notes. Skipped automatically if any `build` job failed.

### Artifact naming and contents

`<board>-image`: `sdcard.img.xz`, `SHA256SUMS`, `build-info`.

### Release contract

- Draft only; automation never sets it public.
- Assets: each board's `sdcard.img.xz` (named `<board>-sdcard.img.xz` in the release), combined
  `SHA256SUMS`.
- Notes MUST state: per file, the image variant; for dev images, passwordless root login and not
  for deployment; and that a boot smoke test on hardware is required before publishing.

### Pinning

Only `actions/checkout`, `actions/cache`, `actions/upload-artifact`, `actions/download-artifact`,
each pinned to a full commit SHA with the version as a comment. Resolved 2026-10-21 from
lightweight release tags (tag SHA = commit SHA):

| Action | Version | Commit SHA |
|---|---|---|
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/cache` | v6.1.0 | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` |
| `actions/upload-artifact` | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| `actions/download-artifact` | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
