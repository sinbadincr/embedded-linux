# Quickstart: validating the CI/CD pipeline

Prerequisites: Docker, GNU Make, Git on the host; submodules initialised
(`git submodule update --init`).

## 1. Local check passes on a clean tree

```bash
make docker-check
```
Expected: exit 0; one `ok:` line per check (shell syntax, shell lint, defconfig round-trip,
make dry run, image layout, board parity).

## 2. Seeded failures are caught (SC-002)

Run each on a scratch branch, expect `make docker-check` to fail naming the problem, then discard:

| Seed | Expected failure |
|---|---|
| add `echo $x` unquoted to `board/ota/common/post-build.sh` | shell lint names the file |
| add `foo(` to a `*.sh` | shell syntax names the file |
| append a blank/reordered line to `configs/beaglebone_black_defconfig` | round-trip diff for that board |
| remove `am335x-boneblack.dtb` from `genimage.cfg` | image-layout check names the DTB |
| remove `post-image.sh` from a board dir | board parity names the file |
| add a nonexistent package to `Dockerfile` | environment build fails |

After each: `git checkout -- . && git clean -fd` (on the scratch branch only).

## 3. CI on push/PR

Push the branch and open a PR. Expected: `ci` workflow runs `make docker-check` only, passes within
10 minutes; pushing a seed from step 2 turns it red with the same message.

## 4. Manual full build

Actions -> `build` -> Run workflow. Expected: one matrix job per `configs/*_defconfig`; each uploads
`<board>-image`. Download one, `sha256sum -c SHA256SUMS`, `xzcat sdcard.img.xz | head -c 512 | file -`.
Re-run with unchanged inputs: the job summary shows the `dl/` cache restored with an exact key hit
and `0` source downloads (SC-004). Total time is not a criterion; compilation dominates it.

## 5. Tag release

```bash
git tag v0.0.1-test && git push origin v0.0.1-test
```
Expected: builds for every board, then a **draft** release with `<board>-sdcard.img.xz`,
`SHA256SUMS` and the notes from the release contract. Delete the draft and tag afterwards. Force
one board to fail (scratch branch) and confirm no draft is created.

## 6. Boot (manual, not CI)

Flash a downloaded image and boot to a login prompt on the serial console (README procedure)
before publishing any release; record the result.
