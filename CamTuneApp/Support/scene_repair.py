"""Measured, bounded repair transactions. Adapters must retain device ownership.

The installed UI cannot enable these engines until a real office calibration
supplies the direction/response map and call-preview parity receipt. Tests use
injected clocks, frames and devices, never actual camera/room writes.
"""
import math
import time
from scene_contract import assess, finite, fresh


class Cancelled(Exception):
    pass


def framing_error(scene):
    box = scene.get("face_box")
    if scene.get("face_count") != 1 or not isinstance(box, list) or len(box) != 4 or not all(finite(v) for v in box):
        raise ValueError("One numeric face rectangle required")
    x, y, w, h = box
    if min(x, y) < 0 or min(w, h) <= 0 or x + w > 1 or y + h > 1:
        raise ValueError("Invalid face geometry")
    # Error is distance OUTSIDE the accepted composition region, not a
    # cosmetic score. Zero is balanced, and zero gain is never improvement.
    def distance(v, low, high):
        return max(low - v, 0, v - high)
    return distance(x + w / 2, .38, .62) + distance(y + h / 2, .42, .58) + distance(h, .25, .55)


def bounded(value, spec):
    low, high, step = spec
    if not all(finite(v) for v in spec) or low > high or step <= 0:
        raise ValueError("Unverified control range")
    steps = min(math.floor((high - low) / step), max(0, round((value - low) / step)))
    return int(low + steps * step)


def framing_plan(scene, settings, calibration):
    if not calibration.get("call_preview_parity") or calibration.get("camera_id") != scene.get("camera_id"):
        raise ValueError("Camera direction and call-preview parity not validated")
    framing_error(scene)
    x, y, w, h = scene["face_box"]
    pan, tilt = settings["absolute_pan_tilt"]
    zoom = settings["absolute_zoom"]
    # Measured signed response per unit, not assumed arrow direction.
    dx = calibration["face_x_per_pan"]
    dy = calibration["face_y_per_tilt"]
    dz = calibration["face_height_per_zoom"]
    if not all(finite(v) and v != 0 for v in (dx, dy, dz)):
        raise ValueError("Camera response calibration missing")
    zoom_ranges = calibration["ranges"]["absolute_zoom"]
    # Current zoom's measured pan/tilt limits must be provided by calibration.
    limits = calibration["pan_tilt_by_zoom"].get(str(zoom))
    if not limits:
        raise ValueError("Pan/tilt limits at this zoom are unverified")
    changes = {}
    px, py = x + w / 2, y + h / 2
    if not .38 <= px <= .62:
        pan = bounded(pan + max(-3600, min(3600, (.5 - px) / dx)), limits[0])
    if not .42 <= py <= .58:
        tilt = bounded(tilt + max(-3600, min(3600, (.5 - py) / dy)), limits[1])
    if [pan, tilt] != settings["absolute_pan_tilt"]:
        changes["absolute_pan_tilt"] = [pan, tilt]
    if not .25 <= h <= .55:
        desired = bounded(zoom + max(-20, min(20, (.4 - h) / dz)), zoom_ranges)
        if desired != zoom:
            changes["absolute_zoom"] = desired
    return changes


def guard_frame(scene, camera, after, now):
    if scene.get("camera_id") != camera or not fresh(scene.get("measured_at"), now) or scene["measured_at"] <= after:
        raise ValueError("Fresh post-actuation frame from the same camera required")
    framing_error(scene)
    checks = assess(scene, now)["checks"]
    if checks["exposure"]["state"] not in ("green", "yellow") or checks["white_balance"]["state"] not in ("green", "yellow"):
        raise ValueError("Exposure/color cannot be verified")
    return checks


def fix_framing(io, calibration, current=lambda: True, clock=time.time):
    """io.read/write/frame have deadlines; write confirms exact readback.

    io must hold the camera's shared intent for the WHOLE operation including
    rollback; current() must inspect that same intent before every write.
    """
    deadline = clock() + 15
    baseline = None
    attempted = False
    before_frame = None
    try:
        if not current():
            raise Cancelled()
        baseline = io.read(deadline)
        before_frame = io.frame(0, deadline)
        camera = calibration["camera_id"]
        baseline_checks = guard_frame(before_frame, camera, 0, clock())
        before = framing_error(before_frame)
        if before == 0:
            return {"status": "unchanged", "reason": "framing already balanced", "corrections": 0}
        settings, scene = baseline, before_frame
        for count in range(1, 4):
            if not current():
                raise Cancelled()
            if clock() >= deadline:
                raise TimeoutError()
            changes = framing_plan(scene, settings, calibration)
            if not changes:
                raise ValueError("No correction available inside validated limits")
            attempted = True
            settings = io.write(changes, deadline)
            if any(settings.get(k) != v for k, v in changes.items()):
                raise ValueError("Write readback mismatch")
            after = clock()
            scene = io.frame(after, deadline)
            checks = guard_frame(scene, camera, after, clock())
            rank = {"green": 0, "yellow": 1, "red": 2, "unknown": 3}
            if any(rank[checks[k]["state"]] > rank[baseline_checks[k]["state"]] for k in ("exposure", "white_balance")):
                raise ValueError("Correction worsened exposure or color")
            error = framing_error(scene)
            if error >= before - .001:
                raise ValueError("Correction did not improve framing")
            if error == 0:
                if not current():
                    raise Cancelled()
                return {"status": "improved", "corrections": count, "before_error": before,
                        "after_error": error, "baseline": baseline, "observed": settings,
                        "measured_at": scene["measured_at"]}
            before = error
        raise ValueError("Framing still outside accepted bounds after three corrections")
    except Exception as exc:
        if not current() or isinstance(exc, Cancelled):
            return {"status": "cancelled", "reason": "newer manual intent owns camera; no rollback"}
        if baseline is None or not attempted:
            return {"status": "could_not_verify", "reason": str(exc) or type(exc).__name__}
        try:
            restore = {k: baseline[k] for k in ("absolute_pan_tilt", "absolute_zoom")}
            if not current():
                raise Cancelled()
            restored = io.write(restore, clock() + 5)
            if any(restored.get(k) != v for k, v in restore.items()):
                raise ValueError("Restoration readback mismatch")
            return {"status": "worse_or_unverified_restored", "reason": str(exc), "observed": restored}
        except Cancelled:
            return {"status": "cancelled", "reason": "manual intent superseded rollback"}
        except Exception as restore_error:
            return {"status": "rollback_failed", "reason": str(restore_error), "original_error": str(exc)}


def lighting_plan(scene, responses, manual_overrides, *, curtains_validated=False):
    """Use only measured per-device effects. No hardcoded preset-as-repair."""
    face = scene.get("face_luma_mean")
    if not finite(face) or scene.get("face_count") != 1:
        return {"status": "could_not_verify", "reason": "fresh face exposure required", "changes": []}
    if 85 <= face <= 165:
        return {"status": "unchanged", "changes": []}
    candidates = []
    for response in responses:
        device = response.get("device")
        if device in manual_overrides or not response.get("verified"):
            continue
        if device.startswith("curtain-") and not curtains_validated:
            continue
        if response.get("camera_id") != scene.get("camera_id"):
            continue
        if not finite(response.get("ambient")) or abs(response["ambient"] - scene.get("background_luma_mean", -1000)) > 20:
            continue
        effect = response.get("face_luma_delta")
        if finite(effect) and abs(125 - (face + effect)) < abs(125 - face):
            candidates.append(response)
    if not candidates:
        return {"status": "could_not_verify", "reason": "No validated light adjustment preserves manual choices; adjust face lighting manually", "changes": []}
    selected = min(candidates, key=lambda r: abs(125 - face - r["face_luma_delta"]))
    return {"status": "planned", "changes": [selected]}


def prepare_scene(io, calibration, manual_overrides, current=lambda: True, clock=time.time):
    """Explicit preparation using only a physically validated response map.

    Adapter contract: acquire the shared intent for all targeted devices before
    this call; preserve its issued time across every write/restore. io.snapshot,
    io.apply and io.restore use Stage 1 readback and per-device status. No light
    is turned on as a side effect of an adjustment. No AI output is itself a
    device command; any future proposal must pass this same planner/transaction.
    """
    deadline = clock() + 20
    baseline = None
    touched = []
    try:
        if not current():
            raise Cancelled()
        before = io.frame(0, deadline)
        if not fresh(before.get("measured_at"), clock()) or calibration.get("camera_id") != before.get("camera_id"):
            raise ValueError("Fresh camera-matched baseline required")
        assessment = assess(before, clock())
        if assessment["checks"]["lights"]["state"] != "green":
            raise ValueError("Actuator readback incomplete; preparation stopped")
        if assessment["state"] == "green":
            return {"status": "unchanged", "assessment": assessment}
        if not calibration.get("room_effects_verified"):
            raise ValueError("Room response measurements unavailable")
        plan = lighting_plan(before, calibration.get("responses", []), manual_overrides,
                             curtains_validated=calibration.get("curtains_validated", False))
        if plan["status"] != "planned":
            return dict(plan, assessment=assessment)
        baseline = io.snapshot([r["device"] for r in plan["changes"]], deadline)
        for change in plan["changes"]:
            if not current():
                raise Cancelled()
            if change["device"] in manual_overrides:
                raise ValueError("Manual override preserved")
            touched.append(change["device"])
            receipt = io.apply(change, deadline)
            if receipt.get("status") != "confirmed":
                raise ValueError("Actuator change not confirmed")
        after_time = clock()
        after = io.frame(after_time, deadline)
        if not fresh(after.get("measured_at"), clock()) or after["measured_at"] <= after_time or after.get("camera_id") != before["camera_id"]:
            raise ValueError("Fresh final measurement unavailable")
        final = assess(after, clock())
        if final["checks"]["face"]["state"] != "green" or final["checks"]["lights"]["state"] != "green":
            raise ValueError("Final face/actuator evidence incomplete")
        rank = {"green":0,"yellow":1,"red":2,"unknown":3}
        measured = ("framing", "exposure", "white_balance", "background")
        if any(rank[final["checks"][k]["state"]] > rank[assessment["checks"][k]["state"]] for k in measured):
            raise ValueError("Preparation worsened scene")
        gain = abs(125 - before["face_luma_mean"]) - abs(125 - after["face_luma_mean"])
        if gain <= 1:
            raise ValueError("No measured exposure improvement")
        if not current():
            raise Cancelled()
        return {"status":"improved", "assessment":final, "exposure_gain":gain,
                "baseline":baseline, "touched":touched}
    except Exception as exc:
        if not current() or isinstance(exc, Cancelled):
            return {"status":"cancelled", "reason":"New manual intent owns devices; no stale rollback"}
        if not touched or baseline is None:
            return {"status":"could_not_verify", "reason":str(exc)}
        try:
            receipt = io.restore(baseline, touched, clock() + 10)
            if receipt.get("status") != "confirmed":
                raise ValueError("Restoration not confirmed")
            return {"status":"worse_or_unverified_restored", "reason":str(exc)}
        except Exception as restore_error:
            return {"status":"rollback_failed", "reason":str(restore_error), "original_error":str(exc)}


def run_physical_framing(payload):
    """Explicit CLI/UI adapter. Never invoked by a timer or automatic check."""
    import importlib.util
    import json
    from pathlib import Path
    import subprocess
    import tempfile
    from camera_control import uvcc, validate_setting
    from lib.ojo_controls import IntentStore, require_current
    root = Path.home() / ".config/camtune"
    validation_path = root / "stage2-office-validation.json"
    if not validation_path.exists():
        return {"status":"could_not_verify", "reason":"Office camera direction, zoom limits and call-preview parity need validation"}
    calibration = json.loads(validation_path.read_text())
    vendor, product = payload["vendor"], payload["product"]
    identity = f"camera:{vendor}:{product}"
    if (calibration.get("camera_id") != identity or not calibration.get("call_preview_parity")
            or not calibration.get("stage1_accepted") or not calibration.get("validation_receipt")):
        return {"status":"could_not_verify", "reason":"Camera-matched office acceptance receipt is incomplete"}
    # A manual request is stamped before any subprocess; never refresh its
    # timestamp when a later step executes.
    operation, issued = payload["operation_id"], payload["issued"]
    store = IntentStore()
    store.register([identity], operation, issued)
    current = lambda: store.current(identity, operation)
    selector = ["--vendor",vendor,"--product",product]
    repo = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location("ojo_frame_adapter", repo / "ojo.py")
    ojo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ojo)

    def command(args, deadline):
        # Engine deadlines use epoch seconds, UVC backend uses monotonic time.
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError("Framing deadline exceeded")
        return uvcc(args, time.monotonic() + remaining)

    class PhysicalCamera:
        def read(self, deadline):
            devices = json.loads(command(["devices"], deadline))
            matching = [d for d in devices if d.get("vendor") == vendor and d.get("product") == product]
            if len(matching) != 1 or matching[0]["name"] != payload["camera_name"]:
                raise ValueError("Camera identity changed or is ambiguous")
            return json.loads(command(["export",*selector], deadline))

        def write(self, changes, deadline):
            observed = self.read(deadline)
            ranges = json.loads(command(["ranges",*selector], deadline))
            # Measured pan/tilt resolution is provided only by office receipt.
            limits = calibration["pan_tilt_by_zoom"].get(str(observed.get("absolute_zoom")))
            if limits:
                ranges["absolute_pan_tilt"] = {"min":[limits[0][0],limits[1][0]], "max":[limits[0][1],limits[1][1]], "res":[limits[0][2],limits[1][2]]}
            for key, value in changes.items():
                if observed.get(key) == value:
                    continue
                require_current(current)
                validate_setting(key,value,ranges,observed)
                values = value if isinstance(value,list) else [value]
                command(["set",key,*values,*selector],deadline)
                observed = self.read(deadline)
                if observed.get(key) != value:
                    raise ValueError("Camera result not confirmed")
            return observed

        def frame(self, after, deadline):
            remaining = deadline - time.time()
            if remaining <= .3:
                raise TimeoutError("No time for a settled frame")
            # Temporary private image exists only for local measurement and is
            # deleted by the context manager on success, cancellation or error.
            with tempfile.TemporaryDirectory(prefix="ojo-frame-") as directory:
                path = str(Path(directory)/"frame.jpg")
                subprocess.run(["/opt/homebrew/bin/imagesnap", "-d", payload["camera_name"], "-w", "0.3", path],
                               capture_output=True, timeout=min(remaining,3), check=True)
                captured = time.time()
                boxes = ojo.detect_face_bboxes(path)
                scene = ojo.describe_scene(path,boxes)
                scene.update(camera_id=identity,measured_at=captured)
                if scene.get("face_bbox"):
                    x,y,w,h = scene["face_bbox"]
                    scene["face_box"] = [x,1-y-h,w,h]
                return scene

    with store.lock(identity,time.monotonic()+20,current):
        result = fix_framing(PhysicalCamera(),calibration,current)
    store.record({"operation_id":operation,"action":"framing","result":result})
    return dict(result, operation_id=operation)


def main():
    import argparse
    import json
    parser = argparse.ArgumentParser()
    parser.add_argument("command",choices=["frame"])
    parser.add_argument("payload")
    args = parser.parse_args()
    try:
        result = run_physical_framing(json.loads(args.payload))
    except Exception as exc:
        result = {"status":"could_not_verify","reason":str(exc)}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
