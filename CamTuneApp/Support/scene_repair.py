"""Measured, bounded repair transactions. Adapters must retain device ownership.

The installed UI cannot enable these engines until a real office calibration
supplies the direction/response map and call-preview parity receipt. Tests use
injected clocks, frames and devices, never actual camera/room writes.
"""
import math
import time
import threading
from scene_contract import assess, finite, fresh

_shutdown = threading.Event()


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
            if clock() >= deadline:
                raise TimeoutError("Framing measurement exceeded the correction budget")
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
    outcomes = []
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
        # Prefer a currently compatible accepted profile, never a legacy raw
        # file. It joins the same baseline/rollback transaction as room changes.
        profile_changed = False
        if hasattr(io,"select_profile"):
            selection = io.select_profile(before)
            if selection.get("status") == "compatible":
                camera_before = io.read(deadline)
                desired = selection["profile"]["settings"]
                changes = {k:v for k,v in desired.items() if camera_before.get(k)!=v}
                if changes:
                    baseline = {before["camera_id"]:camera_before}
                    touched.append(before["camera_id"])
                    observed = io.write(changes,deadline)
                    if any(observed.get(k)!=v for k,v in changes.items()):
                        raise ValueError("Profile readback mismatch")
                    profile_changed = True
        planning_scene = io.frame(clock(),deadline) if profile_changed else before
        plan = lighting_plan(planning_scene, calibration.get("responses", []), manual_overrides,
                             curtains_validated=calibration.get("curtains_validated", False))
        if plan["status"] != "planned" and not profile_changed:
            return dict(plan, assessment=assessment)
        baseline = dict(baseline or {}, **io.snapshot([r["device"] for r in plan["changes"]], deadline))
        for change in plan["changes"]:
            if not current():
                raise Cancelled()
            if change["device"] in manual_overrides:
                raise ValueError("Manual override preserved")
            touched.append(change["device"])
            outcome = {"device":change["device"], "requested":change.get("request"), "status":"pending"}
            outcomes.append(outcome)
            try:
                receipt = io.apply(change, deadline)
                outcome.update(receipt)
            except Exception as exc:
                outcome.update(status="failed",error=str(exc))
                raise
            if receipt.get("status") != "confirmed":
                raise ValueError("Actuator change not confirmed")
        after_time = clock()
        after = io.frame(after_time, deadline)
        if clock() >= deadline:
            raise TimeoutError("Final measurement exceeded preparation budget")
        if not fresh(after.get("measured_at"), clock()) or after["measured_at"] <= after_time or after.get("camera_id") != before["camera_id"]:
            raise ValueError("Fresh final measurement unavailable")
        final = assess(after, clock())
        if final["checks"]["face"]["state"] != "green" or final["checks"]["lights"]["state"] != "green":
            raise ValueError("Final face/actuator evidence incomplete")
        rank = {"green":0,"yellow":1,"red":2,"unknown":3}
        measured = ("framing", "exposure", "white_balance", "background")
        if any(rank[final["checks"][k]["state"]] > rank[assessment["checks"][k]["state"]] for k in measured):
            raise ValueError("Preparation worsened scene")
        if framing_error(after)>framing_error(before)+.001:
            raise ValueError("Preparation worsened numeric framing")
        gain = (abs(125-before["face_luma_mean"])-abs(125-after["face_luma_mean"])
                +100*(framing_error(before)-framing_error(after))
                +10*sum(rank[assessment["checks"][k]["state"]]-rank[final["checks"][k]["state"]] for k in measured))
        if gain <= 1:
            raise ValueError("No measured exposure improvement")
        if not current():
            raise Cancelled()
        return {"status":"improved", "assessment":final, "exposure_gain":gain,
                "baseline":baseline, "touched":touched, "outcomes":outcomes}
    except Exception as exc:
        if not current() or isinstance(exc, Cancelled):
            return {"status":"cancelled", "reason":"New manual intent or cancellation; no stale rollback", "outcomes":outcomes}
        if not touched or baseline is None:
            return {"status":"could_not_verify", "reason":str(exc), "outcomes":outcomes}
        try:
            receipt = io.restore(baseline, touched, clock() + 10)
            if receipt.get("status") != "confirmed":
                raise ValueError("Restoration not confirmed")
            return {"status":"worse_or_unverified_restored", "reason":str(exc), "outcomes":outcomes}
        except Exception as restore_error:
            return {"status":"rollback_failed", "reason":str(restore_error), "original_error":str(exc), "outcomes":outcomes}


def run_physical_framing(payload, mode="frame", *, validation_path=None, intent_store=None, io_factory=None):
    """Explicit CLI/UI adapter. Never invoked by a timer or automatic check."""
    import importlib.util
    import json
    from pathlib import Path
    import subprocess
    import tempfile
    from camera_control import uvcc, validate_setting, calibrated_ranges, write_order
    from lib.ojo_controls import IntentStore, require_current, run_devices, light_io, LIGHTS
    from scene_contract import room_readback, ProfileStore
    import asyncio
    root = Path.home() / ".config/camtune"
    validation_path = Path(validation_path) if validation_path is not None else root / "stage2-office-validation.json"
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
    store = intent_store or IntentStore()
    store.register([identity], operation, issued)
    owned = {identity}
    current = lambda: not _shutdown.is_set() and all(store.current(device, operation) for device in owned)
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
            ranges = calibrated_ranges(ranges,calibration,changes.get("absolute_zoom",observed.get("absolute_zoom")))
            changes = {k:v for k,v in changes.items() if observed.get(k) != v}
            for key,value in changes.items():
                validate_setting(key,value,ranges,dict(observed,**changes))
            for key in sorted(changes,key=write_order):
                value = changes[key]
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
                scene.update(camera_id=identity,measured_at=captured,camera_validated=True)
                if scene.get("face_bbox"):
                    x,y,w,h = scene["face_bbox"]
                    scene["face_box"] = [x,1-y-h,w,h]
                return scene

    class PhysicalRoom(PhysicalCamera):
        def select_profile(self, scene):
            return ProfileStore().select(scene)
        def frame(self, after, deadline):
            remaining = deadline-time.time()
            if remaining <= 0:
                raise TimeoutError("No time for room readback")
            evidence = room_readback(timeout=min(19,remaining))
            result = super().frame(after, deadline)
            result.update(evidence)
            result["profile_status"] = ProfileStore().select(result)["status"]
            return result

        def control(self, device, request, deadline):
            require_current(current)
            remaining = deadline-time.time()
            if remaining <= 0:
                raise TimeoutError("Scene preparation deadline exceeded")
            if request["action"] != "status":
                owned.add(device)
            if device in LIGHTS:
                action = request.get("action")
                if action not in ("status","off","custom","adjust","reading"):
                    raise ValueError("Unsupported planned light action")
                if action in ("custom","adjust") and not all(type(request.get(k)) is int and lo <= request[k] <= hi
                    for k,lo,hi in (("hue",0,360),("saturation",0,100),("brightness",1,100))):
                    raise ValueError("Invalid measured light setting")
                result = run_devices([device],request,
                    lambda d,c,limit:asyncio.run(light_io(d,request,lambda:c() and current(),limit)),
                    operation=operation,issued=issued,store=store,timeout=min(18,remaining))
            elif device in ("curtain-left","curtain-right") and calibration.get("curtains_validated"):
                target = "left" if device.endswith("left") else "right"
                action = request["action"]
                if action == "set" and type(request.get("percent")) is int and 0 <= request["percent"] <= 100:
                    args = ["set",str(request["percent"]),target]
                elif action == "status":
                    args = ["status",target]
                else:
                    raise ValueError("Unsupported measured curtain action")
                process = subprocess.Popen(["/opt/homebrew/bin/python3",str(Path.home()/"gg/scripts/office-blinds.py"),
                    *args,"--json","--operation-id",operation,"--issued",str(issued)],
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                while True:
                    if time.time() >= deadline or not current():
                        # Stage 1's cooperative SIGTERM sends Stop before
                        # releasing the motor lock. Never SIGKILL a moving motor.
                        process.terminate()
                        try:
                            process.communicate(timeout=8)
                        except subprocess.TimeoutExpired:
                            pass  # Worker retains the motor lock and cleanup duty.
                        raise TimeoutError("Curtain interrupted; final motor state requires readback")
                    try:
                        stdout,_ = process.communicate(timeout=min(.2,max(.01,deadline-time.time())))
                        result=json.loads(stdout)
                        break
                    except subprocess.TimeoutExpired:
                        continue
            else:
                raise ValueError("Unvalidated room actuator")
            if result.get("status") != "confirmed":
                raise ValueError("Room actuator result not confirmed")
            return result["devices"][0]["observed"]

        def snapshot(self, devices, deadline):
            return {device:self.control(device,{"action":"status"},deadline) for device in devices}

        def apply(self, change, deadline):
            request = change.get("request")
            if not isinstance(request,dict):
                raise ValueError("Measured response lacks a device request")
            # General preparation never powers on a manually off bulb.
            if change["device"] in LIGHTS and request.get("action") not in ("adjust","off"):
                raise ValueError("Preparation cannot implicitly turn lights on")
            observed = self.control(change["device"],request,deadline)
            return {"status":"confirmed", "observed":observed, "observed_at":time.time()}

        def restore(self, baseline, devices, deadline):
            for device in devices:
                require_current(current)
                prior=baseline[device]
                if device == identity:
                    observed = self.write(prior,deadline)
                    if any(observed.get(k)!=v for k,v in prior.items()):
                        raise ValueError("Camera profile restoration not confirmed")
                    continue
                elif device in LIGHTS:
                    if not prior["on"]:
                        request={"action":"off"}
                    elif prior.get("temperature",0)>0:
                        request={"action":"reading","temperature":prior["temperature"],"brightness":prior["brightness"]}
                    else:
                        request={"action":"custom","hue":prior["hue"],"saturation":prior["saturation"],"brightness":prior["brightness"]}
                else:
                    request={"action":"set","percent":prior["position"]}
                self.control(device,request,deadline)
            return {"status":"confirmed"}

    with store.lock(identity,time.monotonic()+5,current):
        if mode == "frame":
            result = fix_framing(io_factory() if io_factory else PhysicalCamera(),calibration,current)
        else:
            if payload.get("response_id") is not None:
                calibration = dict(calibration,responses=[r for r in calibration.get("responses",[]) if r.get("id")==payload["response_id"]])
                if not calibration["responses"]:
                    return {"status":"could_not_verify","reason":"AI proposal is not a validated room response"}
            overrides = set() if payload.get("allow_room_changes") is True else set(LIGHTS) | {"curtain-left","curtain-right"}
            result = prepare_scene(io_factory() if io_factory else PhysicalRoom(),calibration,overrides,current)
    store.record({"operation_id":operation,"action":mode,"result":result})
    return dict(result, operation_id=operation)


def main():
    import argparse
    import json
    import signal
    # Parent timeouts must leave the worker alive long enough to stop a motor.
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: _shutdown.set())
    parser = argparse.ArgumentParser()
    parser.add_argument("command",choices=["frame","prepare","cancel"])
    parser.add_argument("payload")
    args = parser.parse_args()
    try:
        payload=json.loads(args.payload)
        if args.command == "cancel":
            from camera_control import run_devices  # establishes shared library path
            from lib.ojo_controls import IntentStore
            count=cancel_operation(IntentStore(),payload["operation_id"],f'camera:{payload["vendor"]}:{payload["product"]}')
            result={"status":"cancel_requested","invalidated_devices":count,
                    "reason":"Only this operation was invalidated; physical cleanup/readback remains pending"}
        else:
            result = run_physical_framing(payload,args.command)
    except Exception as exc:
        result = {"status":"could_not_verify","reason":str(exc)}
    print(json.dumps(result))


def cancel_operation(store, operation, camera_id):
    """Compare-and-swap only the cancelled owner; never cancel a newer manual intent."""
    import uuid
    devices=[camera_id,"overhead-left","overhead-right","cafe","pie","curtain-left","curtain-right"]
    with store.connect() as db:
        db.execute("BEGIN IMMEDIATE")
        result=db.execute("UPDATE intents SET issued=?, operation=?, version=version+1 WHERE operation=? AND device IN (?,?,?,?,?,?,?)",
                          (time.time_ns(),str(uuid.uuid4()),operation,*devices))
        return result.rowcount


if __name__ == "__main__":
    main()
