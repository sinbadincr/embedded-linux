# Contract: boot interface, device commands and make surface

What the bootloader, the running system, the operator and the build agree on. The storage numbers
live in [storage-layout.md](storage-layout.md).

## U-Boot: the slot-selection script

Lives in `board/ota/beaglebone_black/uboot-env.txt`, compiled into U-Boot's default environment
through `CONFIG_ENV_SOURCE_FILE`, so the logic is a reviewable text file in this repository and
upstream U-Boot source stays untouched (FR-005).

Behaviour, in order:

1. Read `BOOT_ORDER`. For each boot name in it, in order:
   - if `BOOT_<name>_LEFT` is 0, skip this slot;
   - otherwise decrement it, `saveenv`, announce the chosen slot on the console (FR-027), load
     `/boot/zImage` and the device tree from that slot's partition with `ext4load`, set `bootargs`
     with that slot as `root=`, mounted read-only, and boot.
2. If every slot is exhausted: announce it on the console, restore one attempt to the first slot in
   `BOOT_ORDER` and try it, rather than halting at a prompt (the "both slots bad" edge case).

`bootdelay` is reduced from the measured 2 s; see the boot-time budget in [plan.md](../plan.md).
`CONFIG_BOOTCOUNT_LIMIT` and `CONFIG_BOOTCOUNT_AM33XX` are off, so `BOOT_<name>_LEFT` is the only
counter (FR-003).

## Linux: environment access

`/etc/fw_env.config` points `fw_printenv`/`fw_setenv` at the same two offsets. RAUC's `uboot`
bootloader backend reads and writes `BOOT_ORDER` and `BOOT_<name>_LEFT` through them.

## Operator commands on the device

| Command | Purpose | Requirement |
|---|---|---|
| `rauc status` | booted slot, both slots' version and health, pending confirmation | FR-026, SC-005 |
| `rauc install /data/<bundle>.raucb` | verify, then write the slot that is not running | FR-006, FR-010 |
| `rauc status mark-good` | record the running slot good and restore its counter | FR-011 |
| `rauc status mark-bad` | force the running slot bad, for testing rollback | SC-003 |
| `fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT` | see the raw state | debugging |
| `cat /etc/build-info` | board, revision, Buildroot version of the running slot | FR-024 |

## Health confirmation

`board/ota/common/rootfs_overlay/etc/init.d/S99ota-health`, board-independent (FR-029), runs late in
the BusyBox init sequence and checks the four conditions of FR-012 in this order:

1. the init sequence reached this script;
2. the running slot is the slot that was pending — RAUC's own view, not a guess;
3. `/data` is mounted and a write to it succeeds;
4. `fw_printenv` reads the state and `fw_setenv` writes it back.

All four hold → `rauc status mark-good`, then start the watchdog feeder. Any fail → log the reason
to `/data`, leave the slot unconfirmed, and do **not** start the feeder, so the device is reset and
the attempt counter retires the slot (FR-032).

## Watchdog

| Layer | Behaviour |
|---|---|
| U-Boot | starts the watchdog, 60 s timeout, as the baseline log shows |
| Kernel | watchdog core and `omap_wdt` built in, not modules, so the early window is covered; `CONFIG_WATCHDOG_OPEN_TIMEOUT` non-zero so the kernel stops covering an unopened watchdog |
| Userspace | the BusyBox `watchdog` applet, started **only** by a successful health check |

The point of the ordering: keeping the device alive depends on userspace that proved itself. Today
`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` with an open timeout of 0 means the kernel pings forever
and a hung device is never reset.

## Build surface

| Command | Behaviour |
|---|---|
| `make ota-dev-keys` | generate the development CA and bundle-signing material into `keys/dev/` (gitignored), via `scripts/gen-dev-keys.sh`. Refuses to overwrite an existing CA, because a new CA invalidates every image already flashed with the old one. |
| `make build` | produces `sdcard.img` **and** `beaglebone_black-<version>.raucb`, with no manual step (FR-023). Checks for the signing key *before* invoking Buildroot and fails with a message naming `make ota-dev-keys`, so a missing key costs three milliseconds rather than an hour of building (FR-020, SC-011). |
| `make check` | additionally lints the new scripts and asserts the layout agreement described in [storage-layout.md](storage-layout.md) |

Three variables resolve the signing material, so a later feature can point them at staging or
production material, or at PKCS#11 URLs, without editing a script:

| Variable | Default | Read by |
|---|---|---|
| `OTA_KEYRING` | `keys/dev/dev-ca.cert.pem` | `post-build.sh`, installed as `/etc/rauc/keyring.pem` |
| `OTA_SIGNING_CERT` | `keys/dev/dev-signing.cert.pem` | `post-image.sh`, passed to `rauc bundle --cert` |
| `OTA_SIGNING_KEY` | `keys/dev/dev-signing.key.pem` | `post-image.sh`, passed to `rauc bundle --key` |

`rauc bundle` takes no `--intermediate` argument here: the chain is two levels and `--cert` already
embeds the signing certificate in the CMS signature. See
[signing-chain.md](signing-chain.md) for the whole chain.

Adding `ota-dev-keys` changes the documented make surface, so `README.md`, `CLAUDE.md` and
`make help` change with it (Principle V). The `openssl` command line becomes a build-environment
dependency and is added to the `Dockerfile` explicitly rather than relied on as a transitive
dependency of `ca-certificates`.
