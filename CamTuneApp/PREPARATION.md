# Preparation capability and error repairs

The default Make Me Look Good action leaves room controls alone. It invokes the
camera-matched, physically calibrated framing transaction, including
bounded corrections, readback, fresh image measurements, manual supersession and
rollback, followed by bounded measured exposure correction. It then performs a full scene check. An unchanged/balanced framing result
is success, not an error. Framing success never means the whole scene is ready.

Exposure correction changes only camera brightness, at most three 8-unit steps,
with a 25-second deadline. It does not disable auto exposure or white balance.
Each result needs fresh matched-camera frames, improved measured face luminance,
no worsening of exposure/color/background category, and stable framing. Failure
restores the original brightness with readback unless a newer manual intent owns
the camera. The native transaction budget covers framing, exposure and a final
whole-room verification. A new accepted profile is saved only after that final
verification passes every non-profile check. Save failures remain visible without
erasing the successful correction record. Ordinary Fix Framing remains framing-only.
Accepted profiles store replayable commands, not auto-controlled gain, exposure,
white-balance or focus readings. Selecting an older accepted profile applies the
same filtering without rewriting the original file. Explicit manual settings are
preserved. Regression: test_profile_auto_controls.py.

Calibration CLI: scene_repair.py calibrate-light with an explicit camera identity,
operation UUID/original issued time, device and brightness. It runs one light A/B/A
trial through the shared controller, restores the original state, and emits a
measured candidate only if face geometry, camera settings, other room controls and
restored baseline remain stable. Off lights are never enabled. Failed restoration
is explicit; superseded trials never overwrite newer manual choices. It journals
measurements, including rejected trials, but never automatically flips the receipt.
Measured responses are eligible only at their baseline device and camera settings;
the planner uses the same exposure classifier as Check, not the obsolete85..165
luminance-only rule. Tests: test_room_calibration.py, test_camera_preparation.py.

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

Deployment scope: native gg-mini app and its Python support. Shared device controllers,
credentials and background workers are unchanged. Laptop activation is unverified;
netcup is Linux with no Ojo/camtune systemd unit. Preserve the installed signed
bundle and Python support before installing the declared-commit build; restore both
if startup or transaction acceptance fails. Full room calibration and real-call verification
remain separate work, not completed by these repairs.
