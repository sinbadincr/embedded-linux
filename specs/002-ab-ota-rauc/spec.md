# Feature Specification: A/B Atomic OTA Update with Automatic Rollback

**Feature Branch**: `002-ab-ota-rauc`

**Created**: 2026-10-27

**Status**: Draft

**Input**: User description: "A/B atomic OTA update for board images using RAUC. A device running an image built from this repo can be updated to a new image in the field, atomically, with automatic rollback if the new image fails to boot, and the update bundle is produced by the normal build. Two redundant rootfs slots; bootloader tracks boot attempts and falls back without human intervention; a booted slot must be explicitly marked good; bundles are signed and an untrusted bundle is refused; persistent data survives an update; the build produces both a factory image and an update bundle; an operator can query booted slot, slot health and installed version. Decided direction: RAUC (BR2_PACKAGE_RAUC), first board beaglebone_black on removable SD card, GPT layout boot (FAT ~32M) + rootfs.A (512M) + rootfs.B (512M) + data (remaining), U-Boot bootcount/altbootcmd slot selection with RAUC's U-Boot environment backend, boot logic in the external tree only, generic enough for a second board to adopt later. Out of scope: OTA server / fleet management, delta updates, secure boot, flashing to eMMC."

## Clarifications

### Session 2026-10-27

- Q: Does an update replace the kernel and device tree as well as userspace? → A: Yes. Kernel, device tree and modules live inside each rootfs slot and are updated with it; the bootloader loads them from the active slot. The shared FAT partition holds only the bootloader stages, which OTA never writes.
- Q: Does the A/B layout replace the current single-rootfs image for `beaglebone_black`, or become a variant? → A: It replaces it in place. `beaglebone_black` becomes A/B-capable and there is one flashable artifact per board; the single-slot layout is not kept.
- Q: Is the running slot's root filesystem mounted read-only, or writable as in the current image? → A: Read-only. Temporary files, runtime state and logs go to volatile storage; the separate persistent data area is the only writable storage that survives a reboot. This makes "the running slot is never modified" enforceable rather than a convention, and keeps the running slot identical to the signed bundle it came from.
- Q: Where do the development signing key and certificate live? → A: The development certificate is committed, because it is public and is what the device trusts. The matching private key is never committed: it is generated locally by a documented project command into a version-control-ignored location, and a build that needs it but cannot find it fails with a message naming that command.
- Q: Where does the boot-selection state live on the medium, and does the spec reserve space for it? → A: The layout gains a fifth component: a dedicated region, in no filesystem, outside the bootloader area, that nothing but the boot-selection state writes. The spec stays neutral on whether that is an unpartitioned reserved region or a partition of its own, because the MBR four-primary-partition limit is already reached by the four areas above, so a partition of its own depends on whether this board's ROM can boot from a GPT medium. Research decides; the implementation documents the choice and proves no overlap. The upstream RAUC integration guide takes the same position: its own example uses a dedicated raw area and states the state need not be on an actual MBR/GPT partition, while insisting it live outside the bootloader partition.
- Q: Which boot attempt counter is authoritative, given the board's bootloader config already enables a second one? → A: Exactly one counter, in the boot-selection state, and it must survive power loss. The inherited SoC bootcount keeps its counter in an RTC scratch register, which this board loses on power removal because it has no RTC battery, so it must not be left active alongside the first.
- Q: May a boot taken through the last-resort path be confirmed good? → A: Yes, under the same conditions as any other boot except the pending-slot one, with the record saying it was a last-resort boot. Refusing would leave a device whose only remaining slot passes every health check in a permanent cycle: the watchdog feeder is only started by a confirmation, so the hardware resets the board after 60 seconds, and the same last-resort boot follows. Decided during implementation, after the first hardware run of that path showed RAUC cannot name a primary slot there.
- Q: What stops a slot that boots and then hangs, since the boot attempt counter only acts at boot? → A: Such a slot must be reset automatically within a bounded time, and whatever prevents that reset must depend on the system actually working. Otherwise a hang leaves the device running forever with boot attempts still unspent, which is the exact failure this feature exists to prevent. Added as FR-032 and SC-014 after review.
- Q: Where does the failure reason required by FR-014 live, given that volatile state is discarded at reboot? → A: In the persistent data area. A failed slot is always discovered after a reboot, and the slot itself is overwritten by the next update, so neither volatile storage nor the slot can hold the record. Clarified in FR-014 and FR-028 after review.
- Q: How is the boot-time budget of SC-008 measured? → A: From the bootloader's first serial output to the login prompt, by the method recorded in `docs/boot-baseline-beaglebone-black.md`, against a measured baseline of 11.50 s. Power-on cannot be observed on the serial line, so the earlier "from power-on" wording was not reproducible.
- Q: Does the factory image use a fixed layout, or grow the data area to fill the medium on first boot? → A: Fixed, with no growing: bootloader area 32 MB, two OS slots of 512 MB, data area 256 MB, giving an image of roughly 1.3 GB and a documented minimum medium of 2 GB. Space beyond that on a larger medium is left unused. Growing the data area on first boot would put partition-table surgery at the riskiest moment of the device's life and would make a resize bug indistinguishable from an update bug while the update path is still being brought up; it can be added later once A/B is proven.
- Q: What must the freshly booted system check before it confirms the new slot is good? → A: Four local conditions, no network: the init sequence completed, the running slot is the slot that was pending, the persistent data area is mounted and writable, and the boot-selection state is readable and writable. All four must hold; anything else leaves the slot unconfirmed and therefore subject to rollback.

### Session 2026-10-28

- Q: A board with no RTC cold-boots into 2000 and `rauc install` rejects a certificate that is not yet valid, with no way to skip the check. Does the device or the operator fix the clock? → A: The device. At boot it raises its clock to the build time of its image when it is earlier (FR-033). The build time is a floor, not the real time, so log timestamps are still wrong by the time the device was off; real time needs an RTC or a time source and is a separate feature. Every later spec that depends on the target's clock must read the note in `CLAUDE.md` first.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Flash and boot a device with redundant slots (Priority: P1)

An operator writes the factory image for a board to blank media, powers the device, and it boots
to a login prompt from the first of its two redundant OS slots. The device reports which slot it
booted and that the slot is healthy. The second slot is present but empty, and persistent storage
is available and empty. Nothing about the day-to-day build, flash and boot workflow changes for
someone who does not care about updating.

**Why this priority**: The redundant layout, slot selection and health bookkeeping are the
foundation every later story stands on, and they are the part that can brick a device. Delivered
alone this is already a viable product: a board that boots exactly as before, on a layout that is
ready to be updated.

**Independent Test**: Write the factory image to blank media, boot the device, confirm a login
prompt on the serial console, and confirm the on-device status command names the booted slot and
reports it good.

**Acceptance Scenarios**:

1. **Given** blank media and the factory image for a board, **When** the image is written and the
   device powered on, **Then** the device boots to a login prompt from the first OS slot.
2. **Given** a freshly flashed device, **When** the operator asks for slot status, **Then** the
   booted slot is named, reported as good, and the second slot is reported as present and unused.
3. **Given** a freshly flashed device, **When** it boots, **Then** persistent storage is mounted
   and writable, and survives a power cycle.
4. **Given** a freshly flashed device, **When** the operator reads the on-device build
   information, **Then** it states the board, the source version and the build environment
   version of the running slot.

---

### User Story 2 - Update a running device to a new image (Priority: P2)

A maintainer builds a newer image, which also produces an update bundle. The bundle is placed on
the device by any available means, and a single operator command installs it. The installation
writes only the slot that is not running, so the running system stays usable throughout and a
failure during installation leaves the device exactly as it was. After a reboot the device runs
the new image, and once it has proven itself healthy the new slot is recorded as good and becomes
the one the device falls back to in future.

**Why this priority**: This is the feature's reason to exist, and it is the first story that
delivers field value. It depends on Story 1 but adds the whole installation path.

**Independent Test**: On a device flashed from Story 1, install a bundle built from a visibly
different source revision, reboot, and confirm the device now runs the new revision from the other
slot while the first slot still holds the previous one.

**Acceptance Scenarios**:

1. **Given** a device running slot A and a trusted bundle on local storage, **When** the operator
   installs it, **Then** the bundle is written to slot B, slot A is untouched, and the command
   reports success.
2. **Given** a completed installation, **When** the device reboots, **Then** it boots the newly
   written slot and the on-device build information shows the new source version.
3. **Given** the newly booted slot has proven healthy, **When** the health bookkeeping runs,
   **Then** that slot is recorded as good and the previous slot is retained as the fallback.
4. **Given** an installation is in progress, **When** it is interrupted by power loss, **Then** on
   the next boot the device still runs the previously good slot, unchanged and healthy.
5. **Given** a device whose last update has not yet been confirmed healthy, **When** another
   installation is attempted, **Then** the attempt is refused with a message naming the pending
   state, and nothing is written.

---

### User Story 3 - Automatic rollback when the new image fails (Priority: P3)

A maintainer installs an update that turns out to be broken: it does not reach a working system, or
it reaches one that fails its own health check. Without anybody touching the device, it returns to
the image it was running before and stays there, reporting that the attempted slot is bad. The
field device is never lost to a bad update.

**Why this priority**: It is the safety property that makes updating acceptable at all, but it can
only be demonstrated once installation works.

**Independent Test**: Install a bundle deliberately built to fail to boot (or to fail its health
check), reboot, and confirm the device returns on its own to the previous image within a bounded
number of attempts and reports the attempted slot as bad.

**Acceptance Scenarios**:

1. **Given** a device with a newly installed slot that cannot boot, **When** it is powered on,
   **Then** after at most a bounded, documented number of attempts it boots the previously good
   slot without operator action.
2. **Given** a device whose newly booted slot never confirms its health, **When** it is rebooted,
   **Then** the previously good slot is selected and the unconfirmed slot is marked bad.
3. **Given** a rolled-back device, **When** the operator asks for slot status, **Then** the
   running slot is reported good and the failed slot is reported bad with the reason available.
4. **Given** a slot marked bad, **When** a later trusted bundle is installed, **Then** it is
   written to that slot and the slot becomes eligible again.
5. **Given** both slots are marked bad, **When** the device is powered on, **Then** it still
   attempts to boot a documented slot rather than halting with no attempt, and the situation is
   visible on the serial console.

---

### User Story 4 - Only trusted, intact bundles are accepted (Priority: P4)

A device is handed a bundle that was not produced by the project, was signed with an unknown key,
or was corrupted in transit. The device refuses it, says why, and leaves both slots as they were.
A bundle built for a different board is likewise refused.

**Why this priority**: Required before any image travels outside a lab, but testable only once
installation exists.

**Independent Test**: Attempt to install, in turn, an unsigned bundle, one signed by an untrusted
key, one whose payload has been altered after signing, and one built for a different board; confirm
each is refused, with distinct messages, and that slot contents are unchanged after each attempt.

**Acceptance Scenarios**:

1. **Given** a bundle with no signature or a signature from an untrusted key, **When** installation
   is attempted, **Then** it is refused before anything is written and the message names the trust
   failure.
2. **Given** a bundle whose payload was altered after signing, **When** installation is attempted,
   **Then** it is refused and the message names the integrity failure.
3. **Given** a bundle built for a different board, **When** installation is attempted on this
   board, **Then** it is refused and the message names the mismatch.
4. **Given** any refused bundle, **When** the operator inspects the device afterwards, **Then**
   both slots and the boot selection are exactly as before the attempt.

---

### User Story 5 - Inspect and reason about update state (Priority: P5)

Someone holding a device, or reading a support report from the field, can tell which slot is
running, what version it holds, what the other slot holds, which slots are good or bad, and whether
an update is awaiting confirmation. The same information is obtainable from the serial console
during boot.

**Why this priority**: Pure observability. It makes the other stories supportable, but none of them
depend on it.

**Independent Test**: On a device that has been updated once, read the status output and confirm it
reports both slots with their versions and health, and the pending/confirmed state of the last
update.

**Acceptance Scenarios**:

1. **Given** a device in any state, **When** the operator runs the documented status command,
   **Then** the booted slot, both slots' versions and health, and any pending confirmation are
   reported in one output.
2. **Given** a device booting, **When** an operator watches the serial console, **Then** the
   selected slot is identifiable from the boot output.
3. **Given** a device that has rolled back, **When** the status is read, **Then** the output makes
   the rollback evident rather than looking like a normal boot.

---

### Edge Cases

- **Power loss during installation**: the inactive slot is left partially written; the device must
  still boot the active slot and the partial slot must not become bootable.
- **Power loss between installation and first boot of the new slot**: the pending-but-unconfirmed
  state must survive and still be subject to rollback.
- **Both slots bad**: documented, deterministic behaviour and a visible message, not a silent
  hang.
- **Bundle too large for a slot**: refused before writing, naming the size limit.
- **Media smaller than the layout requires**: flashing or first boot on a medium under the
  documented 2 GB minimum fails with a message naming the required size, rather than producing a
  half-working device.
- **No room to stage the bundle**: the persistent area must hold at least one update bundle, and an
  installation that cannot be staged must be refused with a message naming the space needed.
- **Persistent storage full or corrupt**: must not prevent the device booting or updating.
- **Same or older version installed**: permitted (it is a normal recovery action) and not treated
  as an error.
- **Bootloader environment corrupt or missing**: the device must still boot a documented slot.
- **Boot-selection state readable but not writable from the running system**: every update would
  then roll back even though the image is sound, so the health confirmation must treat this as a
  failure and the condition must be visible rather than silent.
- **First boot after flashing, with the second slot empty**: the empty slot must never be selected.
- **Clock far from real time on a device checking a certificate validity window**: must not make a
  legitimate bundle unusable without a clear message. A device without a battery-backed clock
  starts from the build time of its image (FR-033), so the common case, a cold boot into the year
  2000, no longer arises; a clock that is still outside the window gets RAUC's own message.
- **Installation attempted while another is running**: the second attempt is refused, not
  interleaved.
- **Signing key absent on a fresh clone**: the build must stop with a message naming the command
  that generates the development key, rather than producing an unsigned or unusable bundle.
- **Something on the device needs to write outside the persistent area**: with a read-only OS slot
  this must fail visibly during integration, rather than appearing to work and then losing the data
  at the next update.

## Requirements *(mandatory)*

### Functional Requirements

**Layout and boot selection**

- **FR-001**: Each A/B-capable board MUST provide two redundant OS slots of equal size on its
  storage medium, plus a separate persistent data area, a bootloader area, and a dedicated region
  for the boot-selection state. That state region MUST NOT be part of any filesystem, MUST lie
  outside the bootloader area so that it is unaffected by anything written there, and MUST NOT be
  writable by any update other than the boot-selection state itself. Whether it is an
  unpartitioned reserved region or a partition of its own is left to the implementation, which
  MUST document the choice and MUST ensure no other partition overlaps it.
- **FR-002**: An OS slot MUST contain everything needed to run that version of the system,
  including kernel, device tree and kernel modules, so that one slot is updated as a single unit.
- **FR-003**: The bootloader MUST select the OS slot to boot from recorded state, MUST count boot
  attempts per slot, and MUST stop selecting a slot that exceeds a documented attempt limit. There
  MUST be exactly one such counter: a second, independent boot counter MUST NOT be left active,
  because two sources of truth for "how many attempts are left" cannot be reasoned about. The
  counter MUST survive loss of power, so a counter held only in volatile or battery-backed storage
  that this board does not have is not acceptable.
- **FR-004**: The bootloader area MUST NOT be written by any update; the bootloader stages are
  established only at flashing time. This limitation MUST be documented.
- **FR-005**: Slot selection logic MUST live in this repository's external tree; the upstream
  bootloader source MUST NOT be modified.

**Installing an update**

- **FR-006**: The system MUST install an update bundle to the slot that is not currently running,
  and MUST NOT modify the running slot. The running slot's root filesystem MUST be mounted
  read-only, so that it cannot diverge from the signed bundle it was installed from and so that an
  unclean power loss cannot corrupt it.
- **FR-007**: An installation MUST be atomic from the device's point of view: until it completes
  and the boot selection is switched, the device MUST still boot the previously good slot.
- **FR-008**: After a successful installation the system MUST mark the newly written slot as the
  next slot to boot, in a pending state that has not yet been confirmed.
- **FR-009**: The system MUST refuse to start an installation when an earlier update is still
  pending confirmation, or when another installation is in progress, and MUST say which condition
  applies.
- **FR-010**: Installation MUST be startable by a single documented operator command on the
  device, given a bundle already present on local storage.

**Health confirmation and rollback**

- **FR-011**: A slot booted from a pending update MUST be confirmed healthy by the running system
  before it is recorded as good; a slot that is never confirmed MUST be treated as failed.
- **FR-012**: The health confirmation MUST run automatically on boot and MUST record the slot as
  good only when all of the following hold: the init sequence completed; the running slot is the
  slot that was pending; the persistent data area is mounted and writable; and the boot-selection
  state is both readable and writable. It MUST NOT depend on network reachability, so that a device
  with no uplink can still confirm a good update. A boot taken through the bootloader's last-resort
  path, because every slot is out of attempts, has no pending slot to match; it is confirmed under
  the remaining conditions, and the record states that it was a last-resort boot.
- **FR-013**: When the pending slot fails to boot, or boots without confirming health, the
  bootloader MUST return to the last slot recorded good, without operator action.
- **FR-014**: A slot that failed MUST be recorded as bad, and the reason MUST be retrievable on the
  device afterwards. That record MUST live in the persistent data area, because a failed slot is
  only ever discovered after a reboot and the slot itself is overwritten by the next update; it MUST
  NOT live only in volatile storage, nor inside either OS slot.
- **FR-015**: A slot recorded bad MUST become eligible again when a later trusted bundle is
  installed to it.
- **FR-032**: A slot that boots and then stops working MUST be reset automatically within a
  bounded, documented time, so that the boot attempt counter can retire it. A hang MUST NOT leave
  the device running indefinitely with boot attempts still unspent. Whatever prevents that reset
  MUST depend on the system actually working, so that a system which can no longer confirm its own
  health also stops keeping itself alive.

**Trust and integrity**

- **FR-016**: Update bundles MUST be signed, and a device MUST refuse any bundle that is not signed
  by a key it trusts, or whose signing certificate is not meant for signing code.
- **FR-017**: A device MUST verify bundle integrity and refuse a bundle whose contents changed
  after signing.
- **FR-018**: A bundle MUST identify the board or hardware variant it is built for, and a device
  MUST refuse a bundle that does not match it.
- **FR-019**: Verification MUST happen before anything is written to the inactive slot.
- **FR-020**: Development signing material MUST be unmistakably identified as development-only and
  MUST NOT be usable as a production trust root by accident. The development certificate MAY be
  committed to the repository, because it is public and is exactly what a device must trust; the
  matching private key MUST NOT be committed. The project MUST provide a documented command that
  generates the development private key locally into a version-control-ignored location, and a
  build that requires the key but cannot find it MUST fail with a message naming that command.
- **FR-033**: A device with no battery-backed clock MUST NOT run with a clock earlier than the
  build time of the image it booted, so that a bundle signed with a certificate issued before
  that image was built is not refused as not yet valid. The corrected clock is a floor, not the
  real time, and the documentation MUST say so. A clock already later than the floor MUST NOT be
  changed.

**Build outputs**

- **FR-021**: A build of an A/B-capable board MUST produce a flashable factory image for blank
  media, with the first OS slot populated, the second empty, and the persistent area empty. The
  layout MUST be fixed at build time (32 MB bootloader area, two 512 MB OS slots, 256 MB persistent
  data area) and MUST NOT be resized on the device; space beyond the layout on a larger medium is
  left unused and this MUST be documented. The factory image MUST ship the boot-selection state
  already populated, so that a freshly flashed device boots without needing a first write to it.
- **FR-022**: The same build MUST produce a signed update bundle for that board.
- **FR-023**: Both artifacts MUST be produced by the project's normal documented build command,
  with no manual post-processing step.
- **FR-024**: Both artifacts MUST carry an identifiable version derived from the source revision,
  matching the version the device reports once running.
- **FR-025**: A board that does not opt into A/B MUST continue to build and produce its existing
  artifacts unchanged. Until a second board exists, this requirement is verified by review of the
  shared layer rather than by test, and that limitation is stated rather than implied: no success
  criterion claims to demonstrate it.

**Observability**

- **FR-026**: The device MUST provide a single command reporting the booted slot, both slots'
  versions and health state, and whether an update awaits confirmation.
- **FR-027**: The selected slot MUST be identifiable from the serial console output during boot.
- **FR-028**: Persistent data MUST survive an update, a rollback and a power cycle, and MUST NOT
  live inside either OS slot. Volatile runtime state (temporary files, runtime state, logs) MUST
  live on storage that is discarded at reboot and is part of neither OS slot, so that a read-only
  OS slot does not prevent normal operation. Records that must outlive a reboot, such as the slot
  health and failure reason of FR-014, belong to the persistent data area and MUST NOT be kept in
  volatile storage.

**Project constraints**

- **FR-029**: The board-independent parts of the mechanism MUST live in the shared layer, so a
  second board can adopt A/B by adding only board-local files.
- **FR-030**: Documentation MUST be updated in the same change: flashing procedure, update
  procedure, rollback demonstration, the new storage layout, and the minimum media size.
- **FR-031**: The project's existing static checks MUST continue to pass, and MUST be extended to
  cover the new layout and scripts.

### Key Entities

- **OS slot**: one of two interchangeable, equally sized homes for a complete bootable system
  (kernel, device tree, modules, userspace). Identified by a stable name, has a health state
  (good, bad, or pending confirmation), a version, and at most one of the two is running.
- **Update bundle**: a single signed, board-targeted file holding one OS slot's contents plus the
  metadata needed to verify it (signature, target board identifier, version).
- **Boot selection state**: the small, persistent record the bootloader and the running system both
  read and write: preferred slot order, remaining attempts per slot, and health marks. It survives
  power loss and lives outside both OS slots.
- **Trust anchor**: the certificate material on the device that decides which bundles are
  acceptable. Development and production anchors are distinct and distinguishable.
- **Persistent data area**: storage for configuration and application state that updates and
  rollbacks never touch.
- **Version stamp**: the identifier written into an image at build time from the source revision,
  reported by the running device and carried in the bundle.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with a bundle on the device can complete an update with one command plus
  one reboot, and the device runs the new version within 5 minutes of starting, unattended.
- **SC-002**: In 5 of 5 trials, cutting power at an arbitrary point during installation leaves the
  device booting its previous version to a login prompt, with its previous version reported.
- **SC-003**: A deliberately broken update rolls back to the previous working version with no
  operator action, within a bounded and documented number of boot attempts, in 5 of 5 trials.
- **SC-004**: 100% of bundles that are unsigned, signed by an untrusted key, altered after signing,
  or built for another board are refused, with no change to either slot.
- **SC-005**: Anyone holding the device can determine the booted slot, both slots' versions, both
  slots' health, and any pending confirmation, from a single command, without consulting the build
  tree.
- **SC-006**: Data written to the persistent area before an update is byte-identical after the
  update, and again after a rollback.
- **SC-007**: The factory image fits on commonly available 2 GB media, neither OS slot nor the
  bootloader area exceeds 80% usage, and the persistent area holds at least one update bundle with
  room to spare; the figures are recorded in the project documentation.
- **SC-008**: Time from the bootloader's first serial output to the login prompt grows by no more
  than 10% against the recorded single-slot baseline of 11.50 s for `beaglebone_black`, measured by
  the method in `docs/boot-baseline-beaglebone-black.md`, or the regression is justified in writing.
  Power-on itself is not observable on the serial line, so it is not the reference point.
- **SC-009**: A reviewer can describe, from the documentation alone, what a second board must add
  to become A/B-capable, and the list contains no changes to shared files.
- **SC-010**: The end-to-end update and the rollback are each demonstrated on physical hardware and
  the serial evidence is recorded in the repository.
- **SC-011**: A developer starting from a fresh clone can produce a signed update bundle after
  running one documented command, and the build tells them that command if they have not run it.
- **SC-012**: A write to the running OS slot is rejected on a running device, and no documented
  boot, update, rollback or status operation requires such a write.
- **SC-013**: A device that cannot write its boot-selection state never reports an update as good:
  it rolls back instead, and an operator reading the console or the status output can tell that
  this is what happened.
- **SC-014**: A slot that is made to hang after booting returns the device to the previous working
  version with no operator action, within a documented time, in 3 of 3 trials.

## Assumptions

- **Kernel inside the slot**: an OS slot contains its own kernel, device tree and modules, so an
  update replaces the whole OS atomically. Chosen over separate redundant boot areas because it
  keeps one unit of redundancy and avoids a kernel/userspace mismatch after a rollback.
- **The bootloader is not field-updatable**: the first-stage and second-stage bootloader are
  written once at flashing time. Updating them in the field is the largest bricking risk and buys
  little here; it is explicitly out of scope and documented as a limitation.
- **In-place replacement of the layout**: `beaglebone_black` moves to the A/B layout rather than
  gaining a parallel single-slot variant, so there is one artifact per board and one layout to
  verify. The documented size baselines are re-measured as part of this change.
- **Bundle delivery is the operator's problem**: the bundle arrives on the device by whatever means
  exist (removable media, network copy, a mounted share). No download client, server, scheduler or
  fleet management is part of this feature.
- **Health confirmation is a conservative, local check**: the four conditions in FR-012 and nothing
  more. It does not reach the network, because a device in a lab with no uplink must still be able
  to confirm a good update. Waiting for an application to declare itself ready is the right check
  once this project has an application to wait for; today there is none, so it would only add a
  meaningless timeout.
- **First board and medium**: `beaglebone_black` on removable SD card. On-board eMMC is untouched.
- **The development bench has a fixed network address**: `beaglebone_black` configures `eth0` as
  192.168.0.2/24 at boot, for a board cabled straight to the build host, so that a bundle can be
  fetched for testing. No package is added and nothing listens; the address is baked into the
  read-only slot and is not a product networking design (research R8).
- **Development images stay as they are otherwise**: passwordless root and the existing package set
  are unchanged by this feature; hardening remains the job of a future production variant. The one
  deliberate behavioural change is the read-only OS slot, which is a correctness requirement of
  A/B updating rather than hardening.
- **Fixed layout and sizes**: 32 MB bootloader area, 512 MB per OS slot, 256 MB persistent data
  area, about 1.3 GB of image in total and a 2 GB minimum medium. 512 MB per slot is generous
  against a current rootfs well under 100 MB plus a kernel; 256 MB of data comfortably stages one
  update bundle, which is the real driver of that number. Growing the data area to fill a larger
  medium is deliberately deferred until the update path is proven.
- **Attempt limit**: three boot attempts before the bootloader gives up on a slot, unless
  measurement during implementation shows a different number is warranted.
- **Boot-selection state is written far more often than anything else**: it changes on every boot
  attempt and on every update, so where it lives decides what an interrupted write can destroy.
  Keeping it out of any filesystem, and out of the area holding the bootloader, is what stops a
  half-finished write from costing the device its ability to boot at all. An atomic update of that
  state (for instance a second copy with a way to tell which is current) is what SC-002 demands in
  practice, even though an update framework need not require it in general.
- **One writer, one reader, one agreed location**: the most commonly reported failure in this class
  of system is a mismatch between where the bootloader keeps the state and where the running system
  looks for it. Nothing detects it by itself; every update simply rolls back. That is why FR-012
  makes writing the state a health condition rather than assuming it works.
- **A hang is caught by hardware, not by software goodwill**: the board already runs a hardware
  watchdog that the bootloader starts and the kernel takes over, so FR-032 asks for a mechanism that
  exists rather than new invention. The measured baseline in
  `docs/boot-baseline-beaglebone-black.md` records both.
- **Existing verification duties apply**: this change alters the partition layout, bootloader
  environment and init path, so the constitution's manual boot smoke test on hardware is mandatory
  and a green automated check run is not sufficient evidence.

## Dependencies

- The update framework must be available and buildable from the pinned upstream Buildroot
  submodule for this board's architecture, together with the bootloader-environment access tools
  the device needs to read and write boot selection state.
- Physical hardware, serial console access and removable media are required to satisfy SC-010;
  no automated boot test exists in this project yet.
- Documentation and the static-check script are part of this feature's scope, not follow-up work.

## Out of Scope

- Any OTA server, update distribution service, fleet management, scheduling or telemetry.
- Delta or incremental updates; a bundle carries a whole OS slot.
- Secure boot or a verified boot chain rooted in hardware.
- Flashing to or updating on the board's on-board eMMC.
- Field updates of the bootloader itself.
- A production-hardened image variant (root login policy, package trimming, service exposure).
