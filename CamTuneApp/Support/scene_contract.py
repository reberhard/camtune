"""Single, fail-closed assessment/profile contract for Ojo CLI and Swift.

No device writes, dependencies, image storage, or model calls in this module.
Coordinates are normalized upper-left, measurements are UTC epoch seconds.
"""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import tempfile
import time
from zoneinfo import ZoneInfo


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


CALIBRATION_KEYS = ("face_x_per_pan", "face_y_per_tilt", "face_height_per_zoom")


def clamp_box(box):
    """Clip a normalized upper-left face rectangle to the frame.

    Vision extrapolates a full rectangle for a face cut off at an edge (found
    live 2026-09-14: the camera pointed at the ceiling and the box hung below
    the frame). Returns (box, clipped); (None, False) when no usable overlap.
    """
    if not (isinstance(box, list) and len(box) == 4 and all(finite(v) for v in box)):
        return None, False
    x, y, w, h = box
    if w <= 0 or h <= 0:
        return None, False
    x0, y0, x1, y1 = max(0.0, x), max(0.0, y), min(1.0, x + w), min(1.0, y + h)
    if x1 - x0 <= 0.01 or y1 - y0 <= 0.01:
        return None, False
    clipped = x < -0.002 or y < -0.002 or x + w > 1.002 or y + h > 1.002
    return ([x0, y0, x1 - x0, y1 - y0] if clipped else list(box)), clipped


def clipped_edges(box):
    x, y, w, h = box
    return [name for hit, name in ((y < -0.002, "top"), (y + h > 1.002, "bottom"),
                                   (x < -0.002, "left"), (x + w > 1.002, "right")) if hit]


def fresh(timestamp, now, age=2):
    return finite(timestamp) and 0 <= now - timestamp <= age


def bucket(now=None):
    hour = dt.datetime.fromtimestamp(time.time() if now is None else now,
                                    ZoneInfo("America/Mexico_City")).hour
    return "morning" if 5 <= hour < 11 else "midday" if 11 <= hour < 15 else "afternoon" if 15 <= hour < 19 else "evening"


def assess(scene, now=None):
    now = time.time() if now is None else now
    checks = {}

    def put(key, state, reason):
        checks[key] = {"state": state, "reason": reason}

    camera = scene.get("camera_id")
    camera_fresh = fresh(scene.get("measured_at"), now)
    camera_ok = camera and camera_fresh and scene.get("camera_validated") is True
    put("camera", "green" if camera_ok else "unknown",
        "fresh validated camera frame" if camera_ok else "camera identity missing" if not camera
        else "camera frame stale" if not camera_fresh else "camera calibration receipt missing or mismatched")
    count = scene.get("face_count")
    if type(count) is not int or count < 0:
        count = None
    put("face", "green" if count == 1 else "red" if count in (0,) or (finite(count) and count > 1) else "unknown",
        "one face detected" if count == 1 else "no face detected" if count == 0 else "multiple faces detected" if finite(count) and count > 1 else "face detection unavailable")
    box, clipped = clamp_box(scene.get("face_box"))
    framing = []
    if box and count == 1:
        x, y, w, h = box
        if clipped:
            framing.append("face cut off at " + "/".join(clipped_edges(scene["face_box"])))
        rules = [(x + w / 2, .38, .62, "face too far left", "face too far right"),
                 (y + h / 2, .42, .58, "face too high", "face too low")]
        if not clipped:  # size of a partly visible face is unknown
            rules.append((h, .25, .55, "face too small", "face too large"))
        for value, low, high, below, above in rules:
            if value < low:
                framing.append(below)
            elif value > high:
                framing.append(above)
        put("framing", "yellow" if framing else "green", ", ".join(framing) or "framing looks balanced")
    else:
        put("framing", "unknown", "one face rectangle overlapping the frame required")

    required = ["face_luma_mean", "face_luma_p05", "face_luma_p95", "highlight_clip_pct", "shadow_clip_pct"]
    if count != 1 or not all(finite(scene.get(k)) for k in required):
        put("exposure", "unknown", "face exposure measurements unavailable")
    else:
        mean, p05, p95, high, low = (scene[k] for k in required)
        if not (0 <= p05 <= mean <= p95 <= 255 and 0 <= high <= 100 and 0 <= low <= 100):
            put("exposure", "unknown", "invalid exposure measurements")
        elif high >= 3 or low >= 15 or p95 >= 252 or p05 <= 3:
            put("exposure", "red", "severe clipping in face region")
        elif mean >= 126 and (p95 >= 198 or p95 - p05 < 120 or
                              (finite(scene.get("background_luma_mean")) and mean - scene["background_luma_mean"] > 55)):
            put("exposure", "yellow", "face reads too white or flat for the saved preference")
        elif mean < 85 or mean > 165 or high >= .5 or low >= 5:
            put("exposure", "yellow", "face exposure needs adjustment")
        else:
            put("exposure", "green", "face exposure in range")
    rgb = scene.get("rgb_balance")
    if count != 1 or not isinstance(rgb, list) or len(rgb) != 3 or not all(finite(v) and v > 0 for v in rgb):
        put("white_balance", "unknown", "color measurements unavailable")
    else:
        drift = max(abs(v - 1) for v in rgb)
        put("white_balance", "red" if drift >= .35 else "yellow" if drift >= .18 else "green",
            "severe color imbalance" if drift >= .35 else "mild white-balance issue" if drift >= .18 else "color balance in range")
    face, background = scene.get("face_luma_mean"), scene.get("background_luma_mean")
    if count != 1 or not finite(face) or not finite(background) or not 0 <= background <= 255:
        put("background", "unknown", "background measurements unavailable")
    else:
        separation = face - background
        put("background", "green" if 10 <= separation <= 65 else "yellow",
            "face/background separation in range" if 10 <= separation <= 65 else "face/background separation needs adjustment")
    profile = scene.get("profile_status", "unknown")
    put("profile", "green" if profile == "compatible" else "yellow" if profile in ("missing", "stale", "incompatible") else "unknown",
        "accepted compatible profile" if profile == "compatible" else "profile " + str(profile))
    lights = scene.get("actuator_status", "unknown")
    failed = scene.get("actuator_failed")
    failed = [str(d) for d in failed] if isinstance(failed, list) else []
    # room_readback() runs before camera capture and Vision face detection
    # (ojo.py run_pre_call_check), and `now` here is assessment time at the
    # end of that pipeline, not readback time. A fully current, confirmed
    # readback can measure >10s "stale" purely from the rest of a normal
    # check's own latency (elapsed_ms routinely 10-13s; found live, real
    # checks on 2026-09-15/16 read "unknown"/"required actuator state
    # confirmed" for this reason with nothing actually wrong). 30s covers
    # observed pipeline latency with margin; genuine staleness (a readback
    # reused from a much older run) is still orders of magnitude past this.
    if lights == "confirmed" and fresh(scene.get("actuators_at"), now, 30):
        put("lights", "green", "required actuator readback confirmed")
    elif lights == "failed":
        # A bulb we could not read is missing evidence. It is a blocker only
        # when the face also needs light (2026-09-14: one lost discovery reply
        # painted a well-lit scene red as "required actuator state failed").
        needs_light = checks["exposure"]["state"] != "green"
        who = ": " + ", ".join(failed) if failed else ""
        put("lights", "red" if needs_light else "unknown",
            "light readback failed" + who + ("; face needs light" if needs_light else "") + " (Refresh to retry)")
    else:
        put("lights", "unknown", "required actuator state " + str(lights))
    state = next((s for s in ("red", "unknown", "yellow") if any(c["state"] == s for c in checks.values())), "green")
    if scene.get("trigger") == "auto" and count == 0 and checks["camera"]["state"] == "green":
        state = "idle"
    reasons = [c["reason"] for c in checks.values() if c["state"] == state]
    return {"schema_version": 2, "state": state, "reason": reasons[0] if reasons else "no one in frame (idle)" if state == "idle" else "all required checks passed",
            "camera_id": camera, "measured_at": scene.get("measured_at"), "assessed_at": now,
            "checks": checks, "scene": scene,
            "quality": {"issues": [c["reason"] for c in checks.values() if c["state"] not in ("green", "not_applicable")],
                        "strengths": [c["reason"] for c in checks.values() if c["state"] == "green"]}}


def profile_status(record, camera_id, ambient, now=None):
    now = time.time() if now is None else now
    if not record:
        return "missing"
    if not isinstance(record, dict) or record.get("schema_version") != 2 or not record.get("accepted"):
        return "incompatible"
    if record.get("camera_id") != camera_id or record.get("room") != "polanco-office" or record.get("bucket") != bucket(now):
        return "incompatible"
    if not fresh(record.get("accepted_at"), now, 8 * 3600):
        return "stale"
    prior = record.get("background_luma_mean")
    if not finite(prior) or not finite(ambient) or abs(prior - ambient) > 20:
        return "incompatible"
    return "compatible"


class ProfileStore:
    def __init__(self, root=None):
        self.root = Path(root or Path.home() / ".config/camtune")
        self.path = self.root / "accepted-profiles-v2.json"

    def read(self):
        if not self.path.exists():
            return {"schema_version": 2, "profiles": {}}
        data = json.loads(self.path.read_text())
        if data.get("schema_version") != 2 or not isinstance(data.get("profiles"), dict):
            raise ValueError("Unsupported or corrupt profile store")
        return data

    def migrate_legacy(self):
        """Preserve originals and import only as unaccepted candidates.

        Legacy files have no reliable identity/measurement acceptance. A fresh
        explicit Save is required before any candidate can authorize tuning.
        """
        candidates = []
        for name in ("profile.json", "app-presets.json", "lighting-profiles.json"):
            path = self.root / name
            if path.exists():
                try:
                    data = json.loads(path.read_text())
                    candidates.append({"source":name, "accepted":False, "data":data,
                                       "reason":"camera identity and measured acceptance required"})
                except (ValueError, OSError):
                    candidates.append({"source":name, "accepted":False, "reason":"legacy file unreadable"})
        return candidates

    def select(self, scene, now=None):
        data = self.read()
        record = data["profiles"].get(str(scene.get("camera_id")) + ":" + bucket(now))
        return {"status": profile_status(record, scene.get("camera_id"), scene.get("background_luma_mean"), now), "profile": record}

    def save(self, scene, settings, now=None):
        now = time.time() if now is None else now
        result = assess(scene, now)
        if any(c["state"] != "green" for k, c in result["checks"].items() if k != "profile"):
            raise ValueError("Only a freshly measured acceptable scene can be saved")
        if not isinstance(settings, dict) or not settings or any(
            not (type(v) is int or (isinstance(v, list) and v and all(type(x) is int for x in v)))
            for v in settings.values()
        ):
            raise ValueError("Confirmed camera settings required")
        self.root.mkdir(parents=True, exist_ok=True)
        # Serialize read-modify-replace; old profile files are preserved and
        # deliberately never promoted to accepted merely because they exist.
        import fcntl
        with (self.root / "accepted-profiles-v2.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = self.read()
            record = {"schema_version": 2, "accepted": True, "accepted_at": now,
                      "camera_id": scene["camera_id"], "room": "polanco-office", "bucket": bucket(now),
                      "background_luma_mean": scene["background_luma_mean"], "settings": settings}
            data["profiles"][scene["camera_id"] + ":" + bucket(now)] = record
            fd, temporary = tempfile.mkstemp(dir=self.root, prefix=".profiles-")
            try:
                with os.fdopen(fd, "w") as out:
                    json.dump(data, out, allow_nan=False)
                    out.flush()
                    os.fsync(out.fileno())
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        return record


def call_activity(evidence, now=None):
    """App/process/tab presence is not proof of an active call."""
    now = time.time() if now is None else now
    if not fresh(evidence.get("observed_at"), now, 5):
        return {"state": "unknown", "reason": "call evidence missing or stale"}
    if evidence.get("source") == "accessibility" and evidence.get("leave_call_control") is True and evidence.get("media_control") is True and evidence.get("app"):
        return {"state": "active", "app": evidence["app"], "reason": "live leave-call control observed"}
    return {"state": "unknown", "reason": "app or tab presence does not establish call activity"}


def room_readback(runner=None, timeout=19):
    """Read-only receipt adapter shared by CLI checks; skipped reads stay Unknown."""
    import subprocess
    from concurrent.futures import ThreadPoolExecutor
    if runner is None:
        runner = lambda args: subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    root = Path.home() / "gg/scripts"
    commands = [["/opt/homebrew/bin/python3", str(root / "office-lights.py"), "status", "all", "--json"],
                ["/opt/homebrew/bin/python3", str(root / "office-blinds.py"), "status", "both", "--json"]]
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(runner, commands))
        rows = []
        for result in results:
            if result.returncode not in (0, 2):
                return {"actuator_status":"unknown"}
            data = json.loads(result.stdout)
            if data.get("schema_version") != 1:
                return {"actuator_status":"unknown"}
            rows.extend(data["devices"])
        ids = {"overhead-left", "overhead-right", "cafe", "pie", "curtain-left", "curtain-right"}
        if len(rows) != 6 or {r.get("device") for r in rows} != ids:
            return {"actuator_status":"unknown"}
        if any(r.get("status") == "failed" for r in rows):
            return {"actuator_status":"failed"}
        if any(r.get("status") != "confirmed" or not r.get("observed") or not finite(r.get("observed_at")) for r in rows):
            return {"actuator_status":"unknown"}
        return {"actuator_status":"confirmed", "actuators_at":min(r["observed_at"] for r in rows)}
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
        return {"actuator_status":"unknown"}


def camera_validated(camera_id, path=None):
    path=Path(path) if path else Path.home()/".config/camtune/stage2-office-validation.json"
    try:
        receipt=json.loads(path.read_text())
        # Camera movement needs the measured camera response, not Stage 1
        # light/curtain acceptance; room preparation checks stage1_accepted itself.
        return bool(camera_id and receipt.get("camera_id")==camera_id and receipt.get("call_preview_parity") is True
                    and receipt.get("validation_receipt")
                    and all(finite(receipt.get(k)) and receipt.get(k) != 0 for k in CALIBRATION_KEYS)
                    and isinstance(receipt.get("pan_tilt_by_zoom"), dict) and receipt["pan_tilt_by_zoom"])
    except (ValueError,OSError,AttributeError):
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["assess", "profile-select", "profile-save", "call"])
    parser.add_argument("payload")
    args = parser.parse_args()
    payload = json.loads(args.payload)
    if args.command == "assess":
        result = assess(payload)
    elif args.command == "call":
        result = call_activity(payload)
    elif args.command == "profile-select":
        result = ProfileStore().select(payload)
    else:
        result = ProfileStore().save(payload["scene"], payload["settings"])
    print(json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
