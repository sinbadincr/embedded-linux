# Contract: boot interface, device commands and make surface

What the bootloader, the running system, the operator and the build agree on. The storage numbers
live in [storage-layout.md](storage-layout.md).

## U-Boot: the slot-selection script

Lives in `board/ota/beaglebone_black/uboot-env.txt`, a `key=value` text file in this repository.
Buildroot wires that one file in twice, so neither a custom script nor a U-Boot patch is needed
(FR-005):

| Option | Effect |
|---|---|
| `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE` | the file becomes U-Boot's **built-in default** environment. Buildroot resolves the path and sets `CONFIG_ENV_USE_DEFAULT_ENV_TEXT_FILE` and `CONFIG_ENV_DEFAULT_ENV_TEXT_FILE`, both present in U-Boot 2026.07 |
| `BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE`, `_SOURCE` set to the same file, `_SIZE=0x20000`, `_REDUNDANT=y` | the same file becomes `uboot-env.bin` in `BINARIES_DIR`, which `genimage` writes into the reserved region at both offsets |

Both are needed, for different failures. The built-in default is what boots the board if the
reserved region is ever unreadable. The seeded region is what `fw_printenv` reads: the running
system cannot see U-Boot's built-in default at all, so without the seed the health check of FR-012
fails on its fourth condition on the very first boot, and every update would roll back.

**Size limit on this file.** Its contents are compiled into the SPL as well as U-Boot proper, and
the AM335x SPL runs from internal SRAM with a hard ceiling. At 2916 bytes it already requires
`# CONFIG_SPL_NET is not set` in `uboot.config` to fit; growing it much further will break the link
with `region '.sram' overflowed`, not with a message about the environment. The failure is loud, so
the rule is simply to expect it: if a change here stops U-Boot linking, trim the SPL rather than the
script (`SPL_NAND_*`, `SPL_USB_ETHER`, `SPL_YMODEM_SUPPORT` are all unused on this board).

U-Boot's own `CONFIG_ENV_SOURCE_FILE` is not usable here. It requires the file to sit inside the
U-Boot source tree as `board/<vendor>/<board>/<name>.env` and errors out when it is absent, which
would mean carrying the boot logic in a patch instead of in a reviewable file.

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

### The failure record: `/data/ota-health.log` (FR-014)

The one place to look on a device, or in a support report, for why a slot did not confirm. One line per
event, written by `S99ota-health` and nothing else, plain text, readable without any tool:

```
2026-10-30 01:23:45 UTC up=12s build=fb19ed4 slot=B condition=boot-state: NOT CONFIRMED: boot-selection state is not writable (BOOT_B_LEFT)
```

| Field | Meaning |
|---|---|
| date | the system clock, which is the image's **build time plus the uptime**, not the real time: the device has no battery-backed clock (`CLAUDE.md`, "The target clock is a floor"). Read it as an ordering within one boot, not as a wall-clock time |
| `up=` | seconds since the kernel started, when the record was written |
| `build=` | `VERSION` from `/etc/build-info` of the image that wrote it, so a record names the revision even after the slot has been overwritten |
| `slot=` | the boot name of the running slot, `A` or `B` (`?` if RAUC could not say) |
| `condition=` | which check failed, below |

| `condition=` | Check | Written when |
|---|---|---|
| `running-slot` | 2: RAUC's primary slot is the running one | RAUC names another slot as primary, or names no booted slot; the slot is not confirmed |
| `data-writable` | 3: `/data` is mounted and writable | it is not. The write usually fails too, so this one is mostly **console only** |
| `boot-state` | 4: the boot-selection state reads and writes back | `fw_printenv` or `fw_setenv` fails; the slot is not confirmed |
| `mark-good` | `rauc status mark-good` | it fails after 1 to 4 held |
| `watchdog` | `/dev/watchdog` exists | it does not; the slot was confirmed, but nothing can feed the watchdog |
| `last-resort` | (information, not a failure) | a boot taken because every slot was out of attempts was confirmed |

A healthy ordinary boot writes nothing. The file is bounded: once it is over 64 KiB it is renamed to
`ota-health.log.1`, replacing the previous one, so a device that fails in a loop keeps about the last
64 to 128 KiB and no more.

What it cannot hold, and where to look instead: condition 1 (the init sequence reached the script) cannot
fail from inside the script, and a slot that **hangs before** `S99ota-health` writes no record at all.
For such a slot the evidence is the boot-selection state: `fw_printenv BOOT_<slot>_LEFT` at 0 and the
slot absent from `BOOT_ORDER`, and `rauc status` calling it `bad`. That records *that* it was retired,
not *why*; the reason is "it never confirmed".

## Watchdog

| Layer | Behaviour |
|---|---|
| U-Boot | starts the watchdog, 60 s timeout, as the baseline log shows |
| Kernel | `omap_wdt` and the watchdog core built in; **`omap_wdt.early_enable=1`** from the built-in command line (`CONFIG_CMDLINE`, `CONFIG_CMDLINE_EXTEND=y`), without which the driver *stops* the watchdog at probe; `CONFIG_WATCHDOG_OPEN_TIMEOUT=60`, after which the kernel stops pinging a device nobody opened |
| Userspace | the BusyBox `watchdog` applet, `-t 5 -T 30 /dev/watchdog`, started **only** by a successful health check, after `rauc status mark-good` |

Keeping the device alive depends on userspace that proved itself. Without `early_enable` the kernel
disables the watchdog U-Boot started and nothing ever resets a hung device.

### Documented reset times (FR-032, SC-014)

The watchdog is armed by the kernel at about 0.5 s with a 60 s timeout, and `omap_wdt` expires about 18%
sooner than its nominal figure on this board, so each time below is **nominal, then measured**. The
kernel's watchdog core pings an unopened, running watchdog once, at registration, and arranges for the
hardware to expire at `CONFIG_WATCHDOG_OPEN_TIMEOUT` (60 s); it does not keep it alive until then and
then add another 60 s.

| Situation | Nominal | Measured | Why |
|---|---|---|---|
| Init, or `S99ota-health`, hangs; or the slot never confirms; or confirmation fails; or `/dev/watchdog` is missing | 60 s from kernel start | **49 s**, three times | nobody opens the device, so the one window that began at registration is all there is |
| Kernel hangs or panics before userspace has claimed the watchdog | 60 s | not measured separately; same window as the row above | the kernel's own timeout |
| Kernel hangs or panics after the slot is confirmed (`panic=0`) | 30 s after the last feed | **24 s** | the feeder set the timeout to 30 s and fed every 5 s |
| A confirmed slot stops working later (feeder killed or hung, system wedged) | 30 s after the last feed | **25 s** | same |

Each reset spends a boot attempt. A slot that never confirms is retired after three of them, about 49 s
each plus U-Boot and the kernel's start: **2 min 45 s from the `reboot` to the fallback slot's login
prompt**, measured once (`docs/logs/t034-watchdog-feeder-killed.log`). A slot that does confirm gets its
attempts back, so a single hang costs one reset and the device stays on the slot.

A boot that has not reached `S99ota-health` after about 45 s is reset, so a slot that legitimately needs
longer than that to start would be retired. This image reaches it in about 10 s.

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
