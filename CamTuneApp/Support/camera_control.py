"""Verified UVC writes under the same cross-process ownership as room controls."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path.home() / "gg/scripts"))
from lib.ojo_controls import run_devices, require_current, cooperative_signals


def uvcc(arguments, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Camera deadline exceeded")
    result = subprocess.run(["/opt/homebrew/bin/uvcc", *map(str, arguments)],
                            capture_output=True, text=True, timeout=min(remaining, 5), check=True)
    return result.stdout


def validate_setting(control, value, ranges, settings):
    discrete = {"auto_exposure_mode": {1, 2, 4, 8}, "auto_white_balance_temperature": {0, 1}, "auto_focus": {0, 1}}
    if control in discrete:
        if control not in settings or type(value) is not int or value not in discrete[control]:
            raise ValueError("Unsupported auto mode")
        return
    if control not in settings or control not in ranges:
        raise ValueError("Unsupported camera control")
    info = ranges[control]
    if not isinstance(info, dict):
        raise ValueError("Camera range unavailable")
    low, high = info.get("min"), info.get("max")
    # uvcc ranges exports MIN/MAX only. UVC specifies unit resolution for
    # these controls; other missing resolutions cannot be guessed.
    unit_resolution = {"brightness", "contrast", "saturation", "sharpness", "gain", "absolute_zoom"}
    step = info.get("res", info.get("resolution", 1 if control in unit_resolution else None))
    values = value if isinstance(value, list) else [value]
    lows = low if isinstance(low, list) else [low]
    highs = high if isinstance(high, list) else [high]
    steps = step if isinstance(step, list) else [step] * len(values)
    if len(values) != len(lows) or len(values) != len(highs) or len(steps) != len(values):
        raise ValueError("Camera range dimensions mismatch")
    if any(type(v) is not int or type(lo) is not int or type(hi) is not int or
           type(st) is not int or st <= 0 or not lo <= v <= hi or (v - lo) % st
           for v, lo, hi, st in zip(values, lows, highs, steps)):
        raise ValueError("Camera value outside supported range/resolution")
    if control == "white_balance_temperature" and settings.get("auto_white_balance_temperature") != 0:
        raise ValueError("Disable automatic white balance first")
    if control in ("exposure_time_absolute", "gain") and settings.get("auto_exposure_mode") != 1:
        raise ValueError("Disable automatic exposure first")
    if control == "absolute_focus" and settings.get("auto_focus") != 0:
        raise ValueError("Disable automatic focus first")
    if control == "absolute_pan_tilt" and settings.get("absolute_zoom", 0) <= 100:
        raise ValueError("Pan/tilt requires validated zoom headroom")


def execute(vendor, product, changes, *, operation=None, issued=None, store=None, backend=uvcc):
    if type(vendor) is not int or type(product) is not int or vendor <= 0 or product <= 0:
        raise ValueError("Explicit camera identity required")
    identity = f"camera:{vendor}:{product}"
    selector = ["--vendor", vendor, "--product", product]

    def work(_, current, deadline):
        devices = json.loads(backend(["devices"], deadline))
        if len([d for d in devices if d.get("vendor") == vendor and d.get("product") == product]) != 1:
            raise ValueError("Camera identity missing or ambiguous")
        settings = json.loads(backend(["export", *selector], deadline))
        ranges = json.loads(backend(["ranges", *selector], deadline))
        if not isinstance(settings, dict) or not settings or not isinstance(ranges, dict):
            raise ValueError("Camera readback unavailable")
        # Validate the entire request before the first write. Camera compound
        # transactions must put auto-mode changes in a separate confirmed step.
        changed = {k: v for k, v in changes.items() if settings.get(k) != v}
        projected = dict(settings, **changed)
        for control, value in changed.items():
            validate_setting(control, value, ranges, projected)
        ordered = sorted(changed, key=lambda k: (not k.startswith("auto_"), k))
        for control in ordered:
            value = changed[control]
            require_current(current)
            validate_setting(control, value, ranges, settings)
            values = value if isinstance(value, list) else [value]
            backend(["set", control, *values, *selector], deadline)
            settings = json.loads(backend(["export", *selector], deadline))
            if settings.get(control) != value:
                raise ValueError("Camera write readback mismatch")
        require_current(current)
        return {"settings": settings, "ranges": ranges, "camera_id": identity}

    return run_devices([identity], {"action": "set" if changes else "status", "changes": changes},
                       work, operation=operation, issued=issued, store=store)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("payload")
    args = parser.parse_args()
    payload = json.loads(args.payload)
    cooperative_signals()
    result = execute(payload["vendor"], payload["product"], payload.get("changes", {}),
                     operation=payload.get("operation_id"), issued=payload.get("issued"))
    print(json.dumps(result))
    return 0 if result["status"] == "confirmed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
