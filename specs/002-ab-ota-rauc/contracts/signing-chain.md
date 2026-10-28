# Contract: the signing chain

Four files in the gitignored `keys/dev/` directory, two certificate/key pairs. The first pair
decides **who is trusted**; the second **signs each bundle**. They are separate so that the second
can be replaced without reflashing a single device.

Produced once by `make ota-dev-keys` (`scripts/gen-dev-keys.sh`). The build never generates
signing material: generating it per build would create a new trust domain each time and strand
every card already flashed.

## The two pairs

| File | Key size | Certificate | Signs | Secret |
|---|---|---|---|---|
| `dev-ca.key.pem` | RSA 4096 | — | the signing certificate, once, at generation time | **yes, never leaves `keys/`** |
| `dev-ca.cert.pem` | — | `CA:TRUE`, `pathlen:0`, `keyCertSign,cRLSign`, 10 years | — | no, it is the trust anchor |
| `dev-signing.key.pem` | RSA 2048 | — | every update bundle | **yes, never leaves `keys/`** |
| `dev-signing.cert.pem` | — | `CA:FALSE`, `codeSigning`, 5 years, issued by the CA | — | no, it ships inside each bundle |

`dev-signing.csr.pem` is an intermediate artefact of generation. It can be deleted, or kept to
issue a replacement certificate from the same signing key.

Both certificate subjects state `NOT FOR PRODUCTION` in their common name, so the development
origin of a bundle is visible in `rauc info` and `openssl x509 -text` (FR-020).

## Phase 1 — generation, once per project

```
make ota-dev-keys
  │
  ├─ openssl req -x509   ──▶  dev-ca.key.pem  +  dev-ca.cert.pem
  │                           the CA pair, self-signed
  │
  ├─ openssl req         ──▶  dev-signing.key.pem  +  dev-signing.csr.pem
  │                           the bundle-signing key, and a request to certify it
  │
  └─ openssl x509 -req   ──▶  dev-signing.cert.pem
                              dev-ca.key.pem signs the request.
                              This is the only time the CA key is ever used.
```

## Phase 2 — build, two lanes that never meet

```
LANE A — trust anchor into the image        LANE B — signature onto the bundle
$OTA_KEYRING                                $OTA_SIGNING_KEY  $OTA_SIGNING_CERT
      │                                           │
dev-ca.cert.pem                             dev-signing.key.pem
      │                                     dev-signing.cert.pem
      │ board/ota/common/post-build.sh            │
      │ install -m 0644 -D                        │ board/ota/<board>/post-image.sh
      ▼                                           │ $HOST_DIR/bin/rauc bundle --cert --key
target/etc/rauc/keyring.pem                       ▼
      │                                     <board>-<version>.raucb
      ▼                                      ├── manifest.raucm   compatible, version
rootfs.ext4 ──▶ sdcard.img                   ├── rootfs.ext4
                                             └── CMS signature
                                                  └─ carries dev-signing.cert.pem
```

Invariant: **no private key enters the image, and the CA certificate never enters a bundle.** Each
file has exactly one path, which is why pointing the three `OTA_*` variables elsewhere is enough to
sign with staging or production material.

No `--intermediate` argument is used. The chain is two levels, `--cert` already embeds the signing
certificate in the CMS signature, and the keyring is for trust anchors only.

## Phase 3 — verification on the device, before any write

```
rauc install /data/<bundle>.raucb        /etc/rauc/keyring.pem (= dev-ca.cert.pem)
        │                                          │
        ▼                                          │
  1. unwrap the CMS signature, taking               │
     dev-signing.cert.pem out of it                 │
  2. chain that certificate to the keyring ─────────┘          FR-016
     issued by this CA? still valid?
  3. digest of rootfs.ext4 == the digest in the signed manifest FR-017
  4. compatible == ota-beaglebone-black                         FR-018
        │
        ├── all four pass ──▶ write the slot that is not running,
        │                     then flip BOOT_ORDER and refill the counter
        └── any one fails ──▶ refuse with a reason, write nothing,            FR-019
                              both slots exactly as before
```

## Who may see which file

| File | Leaves `keys/` | Into the image | Into a bundle |
|---|---|---|---|
| `dev-ca.key.pem` | no | no | no |
| `dev-ca.cert.pem` | yes | **yes** | no |
| `dev-signing.key.pem` | no | no | no |
| `dev-signing.cert.pem` | yes | no | **yes** |
| `dev-signing.csr.pem` | no | no | no |

## What a loss or a leak costs

This table is the whole reason for splitting the pairs. With a single self-signed key, every row
below would read "reflash every device".

| Event | Consequence | Reflash? |
|---|---|---|
| `dev-signing.key.pem` lost | issue a new certificate from the CA and carry on signing | no |
| `dev-signing.key.pem` leaked | someone else can sign bundles the devices accept; revoke through a CRL, or issue a new certificate | no |
| `dev-ca.key.pem` lost | no new certificates can be issued; devices keep working until the signing certificate expires | yes, within 5 years |
| `dev-ca.key.pem` leaked | the trust domain is gone | yes, all of them |
| either `.cert.pem` lost or leaked | nothing; they are public | no |

## Beyond development

Staging and production get their own CA each, following RAUC's "Separate CAs" strategy: a device
carries exactly one CA in its keyring, so a bundle from one environment cannot install on a device
from another. Their private keys do not live in this repository — a secret store for staging, and a
PKCS#11 token or cloud KMS for production, which RAUC supports by accepting PKCS#11 URLs in place
of filenames for `--cert` and `--key`. Two problems belong to that work rather than this one: this
board has no RTC battery, so its clock starts in 1970 and certificate validity windows need
deciding, and a CMS signature is not byte-reproducible, so two builds of the same commit produce
different bundles.
