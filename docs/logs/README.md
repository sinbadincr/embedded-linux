# Hardware evidence for feature 002 (A/B updates with RAUC)

Every claim that needs a board is backed by a file in this directory, or is listed under *Not shown*.
A green `make check` and a clean build are not a boot test (constitution, Principle IV); the defects this
feature found only on hardware are listed at the end.

All runs are on a BeagleBone Black booting from an SD card, serial console on J1, 115200 8N1. The
bracketed timestamps in the logs are the capturing terminal's clock, not the device's: the device clock
is the image's build time plus uptime (`CLAUDE.md`, research R8).

## How to read the status column

| Word | Meaning |
|---|---|
| **Shown** | the log is a console capture of the check, and the check's expected result is in it |
| **Reported** | the operator described the result; no capture, so nothing in it was observed by whoever wrote the log |
| **Waived** | the operator decided not to run it. It is not a pass |
| **Not run** | never done on hardware |

## Result per check

| Task | What it checks | Status | Log | Not shown, or not as written |
|---|---|---|---|---|
| T016 | The running system and the bootloader read the same boot-selection state; Linux writes it and U-Boot sees it | **Shown**, both directions | `t016-env-agreement.log`, with the write direction in `t024-us1-second-capture.log` | The write direction is proven with `rauc status mark-good` (counter set to 3, U-Boot then spends one), not with the literal `fw_setenv BOOT_A_LEFT 2` of the task |
| T024 | Scenario 1: flash, boot, slot A booted and good, slot B not bootable, root read-only, `/data` writable and surviving an unclean power loss, the console names the slot | **Shown** over two captures | `t024-us1-first-capture.log`, `t024-us1-second-capture.log` | The first capture found that an empty slot B was reported good; the second shows that fixed and found `seedrng` writing to a read-only `/var/lib`, whose fix is shown in `t025-mark-good.log` |
| T025 | Scenario 2: boot time, three `grabserial` runs (SC-008, budget 12.65 s) | **Shown**: 10.51 s before the health script, then 11.61 s with it (T043) | `boot-baseline-run4.log` to `run6.log`, then `run7.log` to `run9.log`; `t025-mark-good.log`; method and breakdown in `../boot-baseline-beaglebone-black.md` | The 0.9 s of the health script is read from neighbouring timestamps, not measured on its own |
| T028 | An install is refused while an earlier one is pending (FR-009) | **Shown** | `t028-refused-while-pending.log` | The second condition, two installs at once, is host-checked only |
| T029 | Scenario 3: install over the cable, slot switch, new version running, `/data` untouched (SC-006) | **Shown**, third attempt | `t029-install-and-switch.log`; the two failed attempts in `t029-first-install-attempt.log` | Three attempts were needed: `check-purpose` missing, then `mountprefix` and SquashFS missing, each fixed and re-flashed. Delivery and the static address (`t047-network-and-delivery.log`) are **Reported**, not captured |
| T030 | Scenario 4: power pulled during `rauc install`, five trials (SC-002) | 3 of 5 **Shown** (1, 2, 5); trials 3 and 4 **Waived** | `t030-power-cut-trials.log`; `edge-power-loss-before-first-boot.log` | "5 of 5" is not demonstrated. The closing uninterrupted install (FR-015) passed. The edge case "power lost between install and first boot" is **Reported** |
| T031 | The exhausted-slots path boots slot A without spending an attempt; `ota_fallback_slot` as workaround | Default path **Shown**; the fix of the `itest` operator **Reported** | `t031-last-resort-fallback-slot.log`, `boot-baseline-run4.log` | Booting B through `ota_fallback_slot B` was not stated as tried |
| T033 | Scenario 5: a bundle with an unusable kernel is retired and the device rolls back (SC-003, FR-014) | 1 of 3 trials **Shown**; trials 2 and 3 **Waived** | `t033-broken-kernel-trial1.log` | **FR-014 not met for the failed slot**: its kernel never runs, so no reason reaches `/data`; only the counter and `ota-status` say it was retired |
| T034 | Scenario 6: the watchdog resets a hung system and a slot that never confirms is retired (SC-014) | A: **Shown** (feeder killed: reset in 25 s; kernel panic with `echo c > /proc/sysrq-trigger`: 24 s). B: 1 of 3 trials **Shown**; the rest **Waived** | `t034-watchdog-feeder-killed.log` | The "before" run on the unmodified image was not repeated; `t016-env-agreement.log` (253 s, no reset) stands in for it. |
| T035 | Scenario 8: the boot state cannot be written from the new slot (SC-013) | **Shown** for the end state; the three reboots are **Reported** | `t035-fw-env-wrong-offset.log` | Only the last of six health-log records was shown; the per-attempt U-Boot lines are the operator's account |
| T037 | Scenario 7: five untrusted bundles refused, five distinct messages (SC-004, FR-016 to FR-019) | **Shown** | `t037-untrusted-bundles.log` | None of the five wrote anything; the control bundle installed, booted and confirmed |
| T039 | `ota-status` says where the device stands (FR-026, SC-005) | **Shown** in the states below | `t039-ota-status.log`, `t039-status-reporting.log`, and later `ota-status` output in `t033-broken-kernel-trial1.log` | See the list below |
| T043 | Footprint and boot time re-measured (SC-007, SC-008) | Sizes: from the build output. Boot time: **Shown** | README, `../boot-baseline-beaglebone-black.md`, `boot-baseline-run7.log` to `run9.log` | |
| T046, T027 | Clock floor at boot; the health script confirms a slot | **Shown** | `t046-t027-first-hardware-boot.log`, `t046-t027-second-hardware-boot.log` | The first boot found the RTC module overwriting the clock |

### `ota-status` states

Seen on the board: `RUNNING, confirmed`, `RUNNING, NOT CONFIRMED YET` (during the failed boots of
`t033-broken-kernel-trial1.log`), `STANDBY`, `PENDING`, `RETIRED`, `EMPTY`, and the freshly flashed card
(slot A with no RAUC record, slot B empty; same file).

**Not seen**: `UNUSABLE`, and the note `a last-resort boot: U-Boot ran it without spending one`.

## Not shown anywhere

- `rauc status mark-bad`, the command meant for forcing a rollback: not exercised.
- The reason a slot that hangs or fails before `S99ota-health` was retired: derivable only from
  `BOOT_<slot>_LEFT`, `rauc status` and `ota-status`, never from `/data` (T033, T034).
- `ota_fallback_slot B` booting slot B (T031).
- The mirror of T033: the broken bundle in slot A while B runs. The default last-resort slot is A, so this
  is where a further failure on the third boot would end at the U-Boot prompt. Reasoned from the script,
  not seen.
- SC-002 as written (5 of 5), SC-003 as written (3 trials), SC-014 as written (3 trials).

## What only the board showed

Defects that a green `make check` and host-side stubs coexisted with, each found on a capture here. The
first seven are the list in `CLAUDE.md`; the last two were found afterwards.

1. The RTC driver built as a module overwrote the clock set at boot (`t046-t027-first-hardware-boot.log`).
2. `RAUC_SYSTEM_BOOTED_BOOTNAME` held a device path, not a boot name (`t046-t027-first-hardware-boot.log`).
3. `check-purpose=codesign` missing: every bundle refused (`t029-first-install-attempt.log`).
4. `mountprefix` pointing at a read-only place (`t029-*.log`, second attempt).
5. SquashFS missing from the kernel, so a bundle could not be mounted (`t029-*.log`, second attempt).
6. No refusal of a second install while one was pending (`t028-refused-while-pending.log`).
7. The watchdog stopped by `omap_wdt` at probe, so nothing reset a hung board (`t016-env-agreement.log`).
8. `seedrng` writing into a read-only `/var/lib` (`t024-us1-second-capture.log`).
9. `itest` has no operator `eq` (`t031-last-resort-fallback-slot.log`).

Found while running the board, and not fixed: a bad kernel falls through to the next slot in the same
power-up, so the good slot spends an attempt per boot and is refused confirmation until both counters are
0 (`t033-broken-kernel-trial1.log`); that third confirmation is labelled `last-resort` though U-Boot did not
take its last-resort path.
