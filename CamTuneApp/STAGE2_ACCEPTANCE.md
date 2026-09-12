# Stage 2 implementation and acceptance ledger

Status: in progress, not installed or accepted. September 12, 2026.

Contract: gg-steve/memory/grill-packets/grill-with-docs-ojo-repair-stages-2026-09-10.md.
Ryan authorized Stage 2 implementation; his deferral of live office testing remains in force.

## Implemented in this branch

- Camera writes use Stage 1 shared per-device intent/lock arbitration through `Support/camera_control.py`, explicitly select one UVC camera, validate ranges/auto ownership, and confirm readback. Swift controls debounce, retain failures, and discard late results. Range-query failures no longer expose fabricated sliders. Unsupported resolutions and degree FoV presets are not guessed.
- Preview uses unmirrored full-frame geometry and explicit BGRA photometry. No face, multiple faces and capture failures emit invalidation. Captured timestamps are not refreshed by UI redraw; missing frames expire readiness.
- CLI and Swift execute `Support/scene_contract.py` for one assessment. Required missing/stale/invalid evidence cannot be Green. Device failures are independent of image quality.
- `scene_repair.py` implements numeric framing, bounded corrections, post-write image/readback evaluation, cancellation ownership, and pan/tilt/zoom rollback. The explicit UI button has a real CLI adapter, blocked until a camera-matched office validation receipt exists. No validation receipt was fabricated and no framing command was executed.
- One accepted-profile v2 store with Mexico City buckets, camera/room/ambient compatibility, fresh-scene acceptance, locked atomic saves and non-destructive legacy candidates. Active Swift and CLI save/select paths use it; raw legacy files no longer authorize restore.
- Lighting planner/preparation transaction tested with injected IO: only verified room-effect records, preserve manual overrides, require readback plus fresh post-action gain, restore on no improvement/failure, and never rollback over a newer manual intent.
- Call detector uses bounded accessibility observation of leave-call controls instead of process/tab presence. Missing evidence is Unknown, not a fabricated call boundary. Automatic checking stays disabled.

## Remaining engineering and acceptance (not claimed complete)

1. Stage 1 S1-01 through S1-06 physical/app tests still pending.
2. Validate actual Brio capture/UVC identity, unmirrored full-frame versus real call self-view, direction and response coefficients, per-zoom pan/tilt limits and missing device step resolution. Prove the three-correction/15-second framing budget and rollback with real controls.
3. Measure fixture/daylight/curtain effects. Connect the scene-preparation transaction to real room IO and the app after those constraints are known; explicit bounded AI proposal integration remains disabled/unimplemented in this branch. Do not equate a tested planner with completed Make Me Look Good or AI Tune.
4. Validate accepted profile migration/restore in the real room, newer manual changes, and post-restore scene results. Legacy candidates are deliberately not auto-accepted.
5. Validate call-control signatures against actual Zoom/Teams/Meet; implement/verify positive call-end evidence and final rollup lifecycle. Unknown currently preserves an open session; it cannot claim the session ended. No real call cycle has been verified.
6. Final integration, branch publication/review, matched install and complete Stage 1/2 installed acceptance remain. The Stage 1 installed app is unchanged by this work.

## Repeatable non-actuating checks

From repo root: `/Users/eberhard/gg/.venv/bin/python3 -m pytest -q -p no:cacheprovider tests`.

From CamTuneApp: `swift test`, then `swift build -c release`. The bridge test explicitly selects its worktree's shared source, not the installed app or any hardware-validation state.

Regression prevention: `tests/test_ojo_stage2.py`, `CamTuneApp/Tests/CameraControlTests.swift`, plus retained Stage 1 tests. Test adapters do not run hardware commands. Shared-bridge test invokes only the pure assessment command with empty evidence.

Rollback: this branch is not deployed. Installed Stage 1 app/controller pair remains the rollback baseline. Do not merge/redeploy this partial Stage 2 checkpoint as an accepted release.
