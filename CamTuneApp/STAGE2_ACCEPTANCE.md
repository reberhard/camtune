# Stage 2 implementation and acceptance ledger

Status: framing and Stage 1 accepted on hardware September 14, 2026; room preparation and call signatures still gated. (September 12 text below is historical.)

## September 14, 2026 update

- Root cause of the framing failure: the September 10 auto-framing loop tilted the Brio to +32400 with an inverted sign; this build then gated every pan/tilt write behind a receipt no code creates, rejected pan/tilt in its validator (no uvcc step size), and ran Vision in Homebrew Python, which has no Vision framework. Fixed in PR #3 (`94a00de`) and PR #4 (`8e02da1`); shared controller fixes in clawd-workspace PR #63 and #64.
- Receipt `~/.config/camtune/stage2-office-validation.json` written from a live calibration with Ryan in frame (negative tilt = face up, negative pan = face right, no movement at zoom 100, response scales with zoom). `stage1_accepted` and `curtains_validated` true after the installed-UI acceptance round; `room_effects_verified` and `call_signatures_verified` false.
- Hardware evidence: low face centered in one correction (3.8 s); ceiling position centered in two (6.8 s); Stage 1 S1-01/02/03/05/06 confirmed in the controller journal with Ryan observing; Stop settle defect fixed.
- Remaining items 1-2 below are done; item 3 (room effects), 5 (call signatures) and the UX pass are open. Resume plan: `gg-steve/memory/working-context/ojo-next-phases-resume-2026-09-14.md`.


Contract: gg-steve/memory/grill-packets/grill-with-docs-ojo-repair-stages-2026-09-10.md.
Ryan authorized Stage 2 implementation; his deferral of live office testing remains in force.

## Implemented in this branch

- Camera writes use Stage 1 shared per-device intent/lock arbitration through `Support/camera_control.py`, explicitly select one UVC camera, validate ranges/auto ownership, and confirm readback. Swift controls debounce, retain failures, and discard late results. Range-query failures no longer expose fabricated sliders. Unsupported resolutions and degree FoV presets are not guessed.
- Preview uses unmirrored full-frame geometry and explicit BGRA photometry. No face, multiple faces and capture failures emit invalidation. Captured timestamps are not refreshed by UI redraw; missing frames expire readiness.
- CLI and Swift execute `Support/scene_contract.py` for one assessment. Required missing/stale/invalid evidence cannot be Green. Device failures are independent of image quality.
- `scene_repair.py` implements numeric framing, bounded corrections, post-write image/readback evaluation, cancellation ownership, and pan/tilt/zoom rollback. The explicit UI button has a real CLI adapter, blocked until a camera-matched office validation receipt exists. No validation receipt was fabricated and no framing command was executed.
- One accepted-profile v2 store with Mexico City buckets, camera/room/ambient compatibility, fresh-scene acceptance, locked atomic saves and non-destructive legacy candidates. Active Swift and CLI save/select paths use it; raw legacy files no longer authorize restore.
- Lighting preparation is wired through the app to shared Stage 1 room controllers, accepted camera profiles, fresh image measurements and rollback. Only validated response records are eligible; prior manual room choices are protected by default and newer commands always supersede preparation. Curtains use cooperative Stop on cancellation/timeouts. Tests inject room IO; the physical adapter is not hardware-proven.
- Make Me Look Good and explicit AI Tune use the same guarded transaction. AI may choose one validated response, not invent device commands; one image request has tools disabled, an eight-second capture deadline and a bounded model subprocess. The operation retains its original timestamp across the proposal, preventing an old proposal from overriding a newer command. No AI request was executed during development.
- Call detector requires accessibility leave-call and media controls in the same window. Explicit end messages or exit of a previously observed call application provide end evidence. Missing evidence is Unknown, not a fabricated boundary. Active observations survive restart with interruption labeling; durable, retryable, idempotent rollups retain failed writes. Automatic checks are observe-only and remain gated on real call-signature validation.

## Remaining engineering and acceptance (not claimed complete)

1. Stage 1 S1-01 through S1-06 physical/app tests still pending.
2. Validate actual Brio capture/UVC identity, unmirrored full-frame versus real call self-view, direction and response coefficients, per-zoom pan/tilt limits and missing device step resolution. Prove the three-correction/15-second framing budget and rollback with real controls.
3. Measure fixture/daylight/curtain effects and validate the connected preparation/AI path on real devices. The software integration exists, but remains blocked by the absent real office-validation receipt. Verify time budgets, motor Stop and restoration; injected tests do not prove physical effects.
4. Validate accepted profile migration/restore in the real room, newer manual changes, and post-restore scene results. Legacy candidates are deliberately not auto-accepted.
5. Validate call-start/end signatures against actual Zoom/Teams/Meet and verify the integrated rollup lifecycle through a real call, including restart and unavailable accessibility evidence. Unknown preserves an open session; it cannot claim the session ended. No real call cycle has been verified.
6. Branch publication/review, matched install and complete Stage 1/2 installed acceptance remain. The Stage 1 installed app is unchanged by this work.

## Repeatable non-actuating checks

September 12 software evidence: 102 Python tests and 19 Swift tests pass; release build and whitespace/diff checks pass. These include delayed measurements, readback failures, cancellation ownership, rollback, calibration bounds, stale readiness, missing office receipts, late photo callbacks and durable call-rollup retries. No device actuation, AI request or real call was used for this evidence.

From repo root: `/Users/eberhard/gg/.venv/bin/python3 -m pytest -q -p no:cacheprovider tests`.

From CamTuneApp: `swift test`, then `swift build -c release`. The bridge test explicitly selects its worktree's shared source, not the installed app or any hardware-validation state.

Regression prevention: `tests/test_ojo_stage2.py`, `CamTuneApp/Tests/CameraControlTests.swift`, plus retained Stage 1 tests. Test adapters do not run hardware commands. Shared-bridge test invokes only the pure assessment command with empty evidence.

Rollback: this branch is not deployed. Installed Stage 1 app/controller pair remains the rollback baseline. Software verification is not physical acceptance; do not label a subsequent installation an accepted release before the office cases pass.
