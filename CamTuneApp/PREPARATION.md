# Preparation capability and error repairs

The default Make Me Look Good action leaves room controls alone. It invokes the
existing camera-matched, physically calibrated framing transaction, including
bounded corrections, readback, fresh image measurements, manual supersession and
rollback. It then performs a full scene check. An unchanged/balanced framing result
is success, not an error. Framing success never means the whole scene is ready.

Room adjustments and AI room-response selection still require a matching camera
receipt, Stage 1 acceptance, verified room effects, and nonempty response rows.
Unavailable room/AI controls are disabled and the UI states the camera-only scope.
No calibration evidence is invented and no device-controller gate is weakened.

Root cause reproduced September 28: AppState required room_effects_verified even
with allowSceneRoomChanges false, so the default action always refused on the
mini's camera-calibrated but room-unmeasured receipt. Separately, Fix Framing treated
the engine's successful unchanged result as an error and never used its recheck
parameter. Tests: PreparationTests.swift and CameraControlTests.swift. Transaction
outcomes also receive a framing_result diagnostic row with operation and camera ID.

Deployment scope: native gg-mini app only. Python engines, device controllers,
credentials and background workers are unchanged. Laptop activation is unverified;
netcup is Linux with no Ojo/camtune systemd unit. Preserve the installed signed
bundle before installing the declared-commit build; restore it if startup or
transaction acceptance fails. Full room calibration and real-call verification
remain separate work, not completed by these repairs.
