# Phase 1 Data Model: A/B Atomic OTA Update

The six entities of the spec, as they exist concretely on this board. Nothing here is a database:
these are regions of an SD card, a handful of environment variables and one file per record.

## OS slot

Two of them, interchangeable, identical in size.

| Property | Slot A | Slot B |
|---|---|---|
| Boot name (what the environment and RAUC call it) | `A` | `B` |
| RAUC slot name | `rootfs.0` | `rootfs.1` |
| Device | `/dev/mmcblk0p2` | `/dev/mmcblk0p3` |
| Partition size | 512 MiB | 512 MiB |
| Filesystem | ext4, 128 MiB, mounted read-only | same |
| Contents | `/boot/zImage`, `/boot/am335x-boneblack.dtb`, `/lib/modules/6.18.38/`, the whole userspace | same |

Health state is one of **good**, **bad** or **pending** confirmation. Exactly one slot is running
at any moment; the other is the install target. A freshly flashed card has A populated and good,
B empty and never eligible (FR-021 and the "empty slot must never be selected" edge case).

## Boot-selection state

Three variables in the U-Boot environment, the only state both the bootloader and the running
system write. Stored in the reserved region, redundantly — see
[contracts/storage-layout.md](contracts/storage-layout.md).

| Variable | Meaning | Values |
|---|---|---|
| `BOOT_ORDER` | slot boot names in the order to try | `"A B"` or `"B A"` |
| `BOOT_A_LEFT` | attempts remaining for slot A | 0–3 |
| `BOOT_B_LEFT` | attempts remaining for slot B | 0–3 |

Rules that make the whole feature work:

- U-Boot spends one attempt from the slot it is about to boot, writes the environment, then boots.
- A slot at 0 attempts is skipped.
- `rauc status mark-good` restores the running slot's counter to 3.
- Installing a bundle puts the written slot first in `BOOT_ORDER` and sets its counter to 3.
- A slot whose counter reaches 0 is what "bad" means to the bootloader.

## Update bundle

One file, `beaglebone_black-<version>.raucb`: a signed squashfs holding one slot's filesystem image
plus a manifest. Produced by `host-rauc` during the build, never assembled by hand.

| Field | Source | Checked against |
|---|---|---|
| `compatible` | fixed per board: `ota-beaglebone-black` | the device's own `compatible` (FR-018) |
| `version` | `git describe --always --dirty`, the same string as `/etc/build-info` | nothing; downgrades are allowed |
| image | the slot's ext4 filesystem | its hash in the signed manifest (FR-017) |
| signature | the development key, detached CMS over the bundle | the device keyring (FR-016) |

## Trust anchor

Two certificate/key pairs, generated once into the ignored `keys/dev/` directory and detailed in
[contracts/signing-chain.md](contracts/signing-chain.md):

| File | Role | Where it goes | Secret |
|---|---|---|---|
| `dev-ca.key.pem` | certifies the signing key, once; never signs a bundle | nowhere | yes |
| `dev-ca.cert.pem` | the trust anchor | `/etc/rauc/keyring.pem` in the image | no |
| `dev-signing.key.pem` | signs every bundle | nowhere | yes |
| `dev-signing.cert.pem` | proves the signature chains to the CA | inside each bundle's CMS signature | no |

Neither private key is committed or leaves the build host. The keyring holds the **CA**
certificate, not the signing certificate, so a lost or compromised signing key is answered by
issuing a new certificate instead of reflashing every device. A bundle is installable only on an
image built with the same CA, which is what a trust domain means; staging and production would each
have their own CA.

## Persistent data area

`/dev/mmcblk0p4`, 256 MiB ext4, mounted read-write at `/data`. Holds two kinds of thing:

- RAUC's own slot status, including which slot is bad and why (FR-014) — it must outlive the reboot
  that reveals the failure and the overwriting of the failed slot, so it cannot live in a slot or
  in volatile storage;
- anything a future application wants to keep.

Volatile state (`/tmp`, `/run`, `/var`) is tmpfs and is gone at reboot (FR-028).

## Version stamp

`/etc/build-info`, already written by `board/ota/common/post-build.sh` and already proven on
hardware (`VERSION=6255255` resolved to a real commit in the boot baseline). The bundle manifest
carries the same string, so a device can be asked which revision each slot holds.

## State transitions

```
                      rauc install bundle.raucb
   ┌───────────────────────────────────────────────────────────────┐
   │  verify signature, compatible, integrity  ──fail──> refused,  │
   │  write the slot that is not running                 nothing   │
   │  BOOT_ORDER="B A", BOOT_B_LEFT=3                    written    │
   └───────────────────────────────────────────────────────────────┘
                                 │
   A good, running               ▼                     B pending
   B bad/empty          ──> reboot: U-Boot spends one attempt from B
                                 │
                 ┌───────────────┴────────────────┐
                 │                                │
         boots and the four            fails to boot, or hangs
         FR-012 checks pass            (watchdog resets it), or
                 │                     checks fail
                 ▼                                │
         rauc status mark-good                    ▼
         BOOT_B_LEFT=3                   BOOT_B_LEFT reaches 0
         B good, A kept as fallback      U-Boot skips B, boots A
                                         B recorded bad, reason in /data
```

The invariant behind every arrow: **until `BOOT_ORDER` is rewritten at the end of a successful
install, the device still boots the last slot recorded good.** That is what makes an interrupted
install a non-event.
