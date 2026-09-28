"""Bounded light A/B/A measurements; no fabricated response or implicit power-on."""
import time
from scene_contract import assess, finite, fresh

CAMERA_KEYS = ("absolute_zoom", "absolute_pan_tilt", "brightness", "contrast",
               "saturation", "sharpness", "auto_exposure_mode", "auto_white_balance_temperature")


def stable_camera(settings):
    result = {k: settings[k] for k in CAMERA_KEYS if k in settings}
    if settings.get("auto_exposure_mode") == 1:
        result.update({k: settings[k] for k in ("absolute_exposure_time", "gain") if k in settings})
    if settings.get("auto_white_balance_temperature") == 0:
        result["white_balance_temperature"] = settings["white_balance_temperature"]
    return result


def valid_frame(scene, camera, now):
    if scene.get("camera_id") != camera or not fresh(scene.get("measured_at"), now):
        raise ValueError("Fresh camera-matched measurement required")
    checks = assess(scene, now)["checks"]
    if checks["face"]["state"] != "green" or checks["lights"]["state"] != "green":
        raise ValueError("Calibration evidence unavailable: " + checks["face"]["reason"] + "; " + checks["lights"]["reason"])
    if not finite(scene.get("face_luma_mean")) or not scene.get("face_box"):
        raise ValueError("Face measurements unavailable")
    x,y,w,h = scene["face_box"]
    if h < .2 or w < .1 or not .2 <= x+w/2 <= .8 or not .2 <= y+h/2 <= .8:
        raise ValueError("Sit normally in the camera frame for room calibration")


def measure_light(io, calibration, device, brightness, current=lambda: True, clock=time.time):
    deadline = clock() + 70
    baseline = None
    attempted = False
    restored = False
    measurements = {}
    try:
        if device not in ("overhead-left", "overhead-right", "cafe", "pie"):
            raise ValueError("Only known lights can be calibrated")
        if type(brightness) is not int or not 1 <= brightness <= 100:
            raise ValueError("Brightness must be 1 through 100")
        if not current():
            raise ValueError("Newer manual intent owns this operation")
        baseline = io.snapshot([device], deadline)
        prior = baseline[device]
        if not prior.get("on") or prior.get("temperature", 0) != 0:
            raise ValueError("Trial requires an already-on color-mode light; power and mode are preserved")
        if abs(prior["brightness"] - brightness) < 10:
            raise ValueError("Trial needs at least ten brightness points of separation")
        settings = stable_camera(io.read(deadline))
        before = io.frame(0, deadline)
        measurements["before"] = before
        valid_frame(before, calibration["camera_id"], clock())
        request = {"action": "adjust", "hue": prior["hue"], "saturation": prior["saturation"], "brightness": brightness}
        if not current():
            raise ValueError("Newer manual intent owns this operation")
        attempted = True
        receipt = io.apply({"device": device, "request": request}, deadline)
        if receipt.get("status") != "confirmed":
            raise ValueError("Trial readback failed")
        changed = io.frame(clock(), deadline)
        measurements["changed"] = changed
        valid_frame(changed, calibration["camera_id"], clock())
        if not current():
            raise ValueError("Newer manual intent owns this operation")
        if io.restore(baseline, [device], deadline).get("status") != "confirmed":
            raise ValueError("Restoration not confirmed")
        restored = True
        after = io.frame(clock(), deadline)
        measurements["restored"] = after
        valid_frame(after, calibration["camera_id"], clock())
        if clock() >= deadline or not current():
            raise ValueError("Trial expired or superseded")
        if stable_camera(io.read(deadline)) != settings:
            raise ValueError("Camera settings changed during trial")
        if before.get("room_states"):
            expected = dict(before["room_states"])
            expected[device] = dict(prior, brightness=brightness)
            if changed.get("room_states") != expected or after.get("room_states") != before["room_states"]:
                raise ValueError("Room state changed outside the measured trial")
        for sample in (changed, after):
            if max(abs(a-b) for a,b in zip(before["face_box"], sample["face_box"])) > .05:
                raise ValueError("Face moved during trial; measurement rejected")
        if abs(before["face_luma_mean"] - after["face_luma_mean"]) > 5 or abs(before["background_luma_mean"] - after["background_luma_mean"]) > 5:
            raise ValueError("Restored baseline drifted; measurement rejected")
        effect = changed["face_luma_mean"] - (before["face_luma_mean"] + after["face_luma_mean"]) / 2
        if abs(effect) < 3:
            raise ValueError("Effect too small to distinguish from measurement noise")
        return {"status": "measured", "restored": True, "response": {
            "id": f"{device}-brightness-{brightness}", "device": device,
            "request": request, "verified": True, "camera_id": calibration["camera_id"],
            "ambient": before["background_luma_mean"], "face_luma_delta": effect,
            "baseline_device": prior, "baseline_camera": settings,
            "measured_at": clock(), "measurements": {"before": before, "changed": changed, "restored": after}}}
    except Exception as exc:
        if attempted and not restored and current():
            try:
                restored = io.restore(baseline, [device], clock() + 15).get("status") == "confirmed"
            except Exception:
                restored = False
        return {"status": "rejected" if not attempted or restored else "restore_unconfirmed",
                "reason": str(exc), "restored": restored, "baseline": baseline, "measurements":measurements}
