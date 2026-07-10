#!/usr/bin/env python3
"""
ojo — AI-powered webcam optimizer for macOS.

Captures a frame from your webcam, sends it to Claude for visual analysis,
and applies recommended UVC settings. Iterates until the image looks right.

Usage:
    python3 ojo.py                  # Optimize with auto-detected camera
    python3 ojo.py --dry-run        # Show recommendations without applying
    python3 ojo.py --save           # Optimize and save profile
    python3 ojo.py restore          # Restore saved profile
    python3 ojo.py --camera "Brio"  # Target a specific camera

Requires: imagesnap (brew), uvcc (npm), anthropic (pip), pyobjc-framework-Quartz (pip)
"""

import argparse
import base64
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

__version__ = "2.1.0"

CAPTURE_PATH = "/tmp/camtune-capture.png"
PREV_CAPTURE_PATH = "/tmp/camtune-capture-prev.png"
DEFAULT_PROFILE_DIR = os.path.expanduser("~/.config/camtune")
DEFAULT_PROFILE_PATH = os.path.join(DEFAULT_PROFILE_DIR, "profile.json")
PROFILE_MAP_PATH = os.path.join(DEFAULT_PROFILE_DIR, "lighting-profiles.json")
EVENTS_PATH = os.path.join(DEFAULT_PROFILE_DIR, "events.jsonl")
FEEDBACK_PATH = os.path.join(DEFAULT_PROFILE_DIR, "feedback.jsonl")
COMMENTS_PATH = os.path.join(DEFAULT_PROFILE_DIR, "comments.jsonl")
CHECK_CACHE_PATH = os.path.join(DEFAULT_PROFILE_DIR, "pre-call-check-cache.json")
WARMUP_SECS = 3
SETTLE_SECS = 3
DEBOUNCE_SECS = 60
MAX_LOG_BYTES = 1_000_000  # 1MB


LAUNCHAGENT_LABEL = "com.camtune.daemon"
LAUNCHAGENT_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LAUNCHAGENT_LABEL}.plist")
DAEMON_LOG_PATH = os.path.join(DEFAULT_PROFILE_DIR, "daemon.log")
ENV_CONFIG_PATH = os.path.join(DEFAULT_PROFILE_DIR, "env.json")

# Fallback ranges for common UVC controls. Used when `uvcc ranges` fails
# (which happens on some cameras due to LIBUSB errors).
FALLBACK_RANGES = {
    "white_balance_temperature": (2800, 7500),
    "brightness": (0, 255),
    "contrast": (0, 255),
    "gain": (0, 255),
    "saturation": (0, 255),
    "sharpness": (0, 255),
    "exposure_time_absolute": (3, 2047),
}

ANALYSIS_PROMPT = """\
You are a professional colorist and lighting designer for video calls.
Analyze the FULL FRAME and recommend adjustments to camera settings and
controllable lights.

IMPORTANT: This image is captured DIRECTLY FROM THE CAMERA SENSOR via imagesnap,
so it is the unprocessed sensor output that gets fed to video-call platforms.
The frame has been face-cropped via macOS Vision framework — the face fills
most of the frame with ~30% margin for ambient context. Optimize this raw
frame. The call platform (Meet, Zoom, etc.) will add some codec compression
but face detail is largely preserved when the input is clean. Optimize the
raw frame, not "what Meet shows."

## SUBJECT PREFERENCES (overrides generic aesthetic guidance below)

Learned from observed feedback. These preferences win any conflict with the
generic "podcast guest" aesthetic:

1. **Visible tonal variation on the face is required.** The subject must be
   able to see his own cheek color, forehead tone differences, shadow
   definition under the eye sockets, and jawline shading. A face that reads
   as "uniformly lit" or "one tone" is a FAILURE, even if the histogram
   looks fine. If you see a face with no tonal variation, the image is too
   bright — reduce brightness and/or shorten exposure_time_absolute until
   tonal variation appears.

2. **The subject dislikes "hazy," "white-looking," "blown out," or "flat lit"
   appearance.** These are his exact complaints. If the skin reads as pale
   white without color variation, any of these conditions is present. Fix by
   reducing brightness (primary lever), reducing exposure_time_absolute
   (secondary), and raising saturation toward 120 to restore visible skin
   color.

3. **The subject has a light tan.** If the skin reads as pale/white with no
   warmth or color variation, saturation is too low (raise toward 120-130)
   or exposure is too bright (lower it). The tan should be visible on
   forehead and cheeks.

4. **Prefer slight underexposure with visible texture over full exposure with
   flat tonality.** A face that is "slightly darker than technically ideal
   but shows skin texture and contour shadows" is better than a face that
   is "perfectly lit but uniformly bright with no depth."

When in doubt between brighter-and-flatter or darker-and-more-dimensional,
choose darker-and-more-dimensional. The subject has stated this preference
explicitly.

## #1 PRIORITY: Do not blow out skin.

The single worst outcome is overexposed skin: face glowing white, features
washed out, no texture or dimension. This is worse than being slightly too dark.
If you see ANY of these signs, your ONLY job is to fix them before touching
anything else:
- Skin appears white or near-white instead of having natural color and texture
- Forehead, nose, or cheeks are clipped (featureless bright patches)
- The face looks "angelic" or "glowing" with no visible pores or contour
- The overall image feels flat and bright with no shadows on the face

To fix overexposure: reduce brightness (try 90-110), switch to manual exposure
mode (auto_exposure_mode: 1) with exposure_time_absolute around 200-350, and
reduce gain. Do NOT increase brightness or leave auto exposure on if the face
is already bright.

## Goal

Natural, dimensional, warm. Think "podcast guest who looks great without trying"
not "studio portrait." Visible skin texture and facial contour. Warm tones
(slightly amber/golden). Gentle shadows that give the face depth. The background
should be dimmer than the face with warm ambient color.

The controllable lights should COLOR-MATCH the ambient/natural light in the
room. Read the frame for clues: daylight color on walls, shadow color, skin
undertone. Set the lights and camera white balance so everything looks like one
coherent light source, not a mix of competing color temperatures.

Camera: {camera_name}
Current camera settings: {current_settings}
Valid camera ranges: {ranges}
{env_section}
## Camera controls reference

- **brightness** (0-255): Shifts the entire image lighter/darker. Adjust to
  produce VISIBLE TONAL VARIATION on the face (cheek color, shadow under eye
  sockets, forehead/jaw tone differences). A uniformly lit face with no
  tonal variation means brightness is too high — reduce it. Typical landings:
  70-90 in daylight-dominant rooms (windows + overhead spill), 90-115 in
  tungsten-only rooms. Err LOWER. Above 100 in daylight conditions tends to
  produce the "hazy / white-looking / blown-out" failure mode the subject
  dislikes. Above 130 nearly always washes skin out. Below 60 genuinely
  underexposes. Adjust in steps of 5-10. Do NOT default to a fixed "sweet
  spot" — read the face tonal variation in the current frame and choose
  accordingly.
- **contrast** (0-255): Difference between darks and lights. 100-130 is
  natural. Above 150 crushes shadows and blows highlights. Below 80 looks flat
  and hazy. Keep conservative.
- **saturation** (0-255): Color intensity. 100-130 is natural skin tone range.
  Above 150 makes skin look orange/red. Below 80 looks washed out. Err toward
  lower rather than higher.
- **gain** (0-255): Signal amplification. Lower is always better (less noise).
  Below 20 is ideal. Above 40 introduces visible grain. Only raise gain as a
  last resort if the image is too dark after lowering exposure_time_absolute.
- **sharpness** (0-255): Edge enhancement. 100-140 is natural. Above 180
  creates halos around edges. Below 80 looks soft. Leave near default unless
  visibly soft or oversharpened.
- **white_balance_temperature** (2800-7500): Color temperature in Kelvin.
  ~3200K = warm/tungsten, ~4000K = warm indoor, ~5000K = daylight, ~6500K =
  cloudy/cool. MATCH the dominant light source hitting the face. If daylight
  from windows is the primary source (bright, white/blue shadows, outdoor
  light visible), use 4800-5500K. If artificial light dominates (warm shadows,
  no window light), use 3500-4200K. Getting this wrong creates a color cast:
  too-warm WB under daylight = magenta/purple tint. Always prefer MANUAL
  white balance (auto_white_balance_temperature: 0) so you control the color.
- **exposure_time_absolute** (3-2047): Shutter speed in 0.1ms units.
  Lower = less motion blur but darker. Higher = brighter but more blur.
  200-400 is good for 30fps video calls. Only meaningful when
  auto_exposure_mode is MANUAL (1).
- **auto_white_balance_temperature**: 0 = manual (PREFERRED, you set the
  temperature for consistent warm tones), 1 = auto (camera decides, often
  picks cold/clinical tones). Default to manual (0) with a warm temperature.
- **auto_exposure_mode**: 1 = manual (PREFERRED, you control
  exposure_time_absolute and gain for consistent results), 8 = auto (camera
  controls exposure, often overexposes faces). Default to manual (1). Auto
  exposure is the #1 cause of the "glowing face" problem because the camera
  firmware brightens the image when it sees a face.

## Lighting design principles (for environment controls)

- **Read the ambient light first.** Before adjusting anything, assess the
  natural/ambient light in the frame: window light direction, color temperature,
  and intensity. Look for color casts on walls, shadows, and skin. The
  controllable lights should COMPLEMENT the ambient light, not fight it.
  - If natural daylight is dominant (cool, blue-white shadows, bright patches
    near windows): set controllable lights slightly warm (hue 30-40, sat 3-8)
    to balance the cool ambient. Do NOT try to overpower daylight.
  - If the room is mostly artificial light (warm tungsten shadows, no blue
    daylight): keep controllable lights in the same warm family. Match, don't
    contrast.
  - If mixed lighting (daylight from one side, warm lamps from another): choose
    one color temperature for the controllable lights and set the camera white
    balance to split the difference. Mixed color temps on the face look worst.
  - Adjust the camera white_balance_temperature to match the DOMINANT light
    source hitting the face, then use the controllable lights to fill in the
    same color family.
- **No dedicated face light exists.** The subject's face is lit by ambient
  room light (strong natural daylight from windows on two sides + overhead
  spill). You cannot directly light the face with any controllable light.
  In daylight conditions, the face is usually well-lit already. Do NOT
  over-compensate with high camera exposure or brightness. Read the actual
  face brightness in the image before adjusting. The overheads provide
  indirect fill but are behind/above the subject, not on the face.
- **Overhead lights** (overhead_lights): Two pendant lights behind and above
  the subject. Primary controllable light source. They cast ambient fill on
  the face and light the background wall. Push brightness higher when the
  room is dim. These are doing most of the work.
- **Accent lamp** (accent_lamp): Warm desk lamp visible in frame. Provides
  background warmth and visual depth. Think "cozy office."
- **NOTE:** There is no dedicated face/key light. A future Elgato key light
  will be added behind the webcam. Until then, face illumination comes from
  ambient daylight and overhead spill only.
- **Color harmony**: All lights should be in the same color family as the
  dominant ambient light, or a deliberate complement. Never random.
- **Brightness ratio**: Face should be the brightest thing in frame. Since
  there is no dedicated face light, the overheads and ambient daylight are
  the main face sources. Do NOT set background/accent lights brighter than
  the overheads, that flattens the image and backlit the subject.
- **Saturation**: Keep LOW (1-10 for most scenes). High saturation colored
  light looks like a gaming setup. Exception: accent lamp at 15-30 for warmth.

## Decision guidelines

- Make SMALL adjustments. Change one or two settings by 10-15 units, not five
  settings by large amounts. You can refine on the next round.
- Camera and lights interact. If you change light brightness, camera exposure
  will need to compensate. Think holistically.
- If the image already looks great, leave it alone or make minimal tweaks.
- PREFER manual modes. Set auto_exposure_mode to 1 and auto_white_balance to 0
  unless you have a specific reason not to. This gives you control.
- Never set contrast and saturation both above 130.
- When unsure between brighter and darker, choose darker. Slightly underexposed
  with visible skin texture always beats overexposed and washed out.
{comparison_note}
Respond with ONLY a JSON object (no markdown, no explanation):
{{
    "assessment": "1-2 sentence assessment. FIRST mention if face is overexposed/washed out.",
    "changes": {{
        "brightness": 105,
        "contrast": 110
    }},
    "auto_white_balance_temperature": 0,
    "auto_exposure_mode": 1,
    "env": {{
        "overhead_lights": {{"hue": 30, "saturation": 5, "brightness": 25}},
        "accent_lamp": {{"hue": 25, "saturation": 20, "brightness": 20}}
    }}
}}

"changes" should ONLY include camera settings that need adjustment.
"env" should ONLY include lights that need adjustment. Omit lights that look good.
If everything looks good, return empty changes and empty env.
Values must be integers within valid ranges.
"""

COMPARISON_NOTE_FIRST = ""
COMPARISON_NOTE_FOLLOWUP = """
## Comparison
The FIRST image is BEFORE your previous adjustments. The SECOND image is AFTER.

Compare them carefully:
1. Is the face MORE or LESS overexposed in the second image? If skin got
   brighter or lost texture, your changes made things WORSE. Revert brightness
   and exposure changes.
2. Did skin tones get warmer or cooler? Warmer (golden/amber) is better.
   Cooler (blue/grey) is worse.
3. Is there more or less visible facial detail (pores, stubble, contour)?
   More detail = better. Less detail = overexposed, revert.

If the second image is brighter but skin looks washed out, that is NOT an
improvement. Reduce brightness and exposure even below the first image's levels.
"""

VERIFY_PROMPT = """\
You are a video quality judge. Compare these two images from a video call.

The FIRST image is BEFORE AI optimization. The SECOND image is AFTER.

The SUBJECT of these images has stated these preferences explicitly:
- Visible tonal variation on the face is REQUIRED (cheek color, shadow under
  eye sockets, forehead/jaw tone differences). A "uniformly lit" face is a
  failure.
- The subject dislikes "hazy," "white-looking," "blown out," or "flat lit"
  appearances. These are failure modes regardless of technical correctness.
- The subject has a light tan that should be visible.
- The subject prefers slight underexposure with visible texture over full
  exposure with flat tonality.

Judge the AFTER image relative to BEFORE against THOSE preferences, in this
order of priority:
1. Tonal variation: Does the AFTER image show more or less visible tonal
   range on the face? More = better. A flatter/more-uniformly-lit face = worse.
2. "Hazy / white / blown" check: Does the AFTER image look hazier, whiter,
   or more blown out than BEFORE? If yes, verdict is WORSE regardless of
   other improvements.
3. Skin tone visibility: Is the subject's "light tan" more or less visible?
   Pale-white-uniform = worse. Visible warm tone variation = better.
4. Technical correctness: color cast, white balance, exposure — secondary to
   the three above. A technically-correct but flat-lit face is still a failure.

Respond with ONLY a JSON object:
{{
    "verdict": "better" or "worse" or "same",
    "reason": "One sentence explaining the verdict in terms of the subject's preferences"
}}

Be strict. The subject has explicitly said he'd rather be slightly
underexposed with texture than fully lit and flat. Apply that bias.
"""


CAMTUNE_STATE_PATH = os.path.join(DEFAULT_PROFILE_DIR, "state.json")

# Prefer visible skin texture and warm tonal variation over a technically
# bright face. These limits intentionally flag the pale/flat look before clip
# metrics would call it overexposed.
FACE_WHITE_LUMA_WARN = 126
FACE_WHITE_P95_WARN = 195
FACE_WHITE_TONAL_RANGE_WARN = 130
FACE_WHITE_SEPARATION_WARN = 55

# Non-call processes that trigger camera events but aren't video calls.
def _read_state():
    """Read the shared state file (written by CamTune.app)."""
    try:
        with open(CAMTUNE_STATE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _write_state(data):
    """Write to the shared state file."""
    os.makedirs(os.path.dirname(CAMTUNE_STATE_PATH), exist_ok=True)
    with open(CAMTUNE_STATE_PATH, "w") as f:
        json.dump(data, f, indent=2)


def is_video_call_active():
    """Check if a video call app is actively using the camera.

    Checks the shared state file written by CamTune.app. If the app's preview
    is active, the camera event is from our own app, not a video call.
    """
    state = _read_state()
    if state.get("preview_active"):
        return False, None
    return True, "external"


def load_env_config():
    """Load environment control config (lights, etc.) if present."""
    if not os.path.exists(ENV_CONFIG_PATH):
        return None
    try:
        with open(ENV_CONFIG_PATH) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def probe_env_reachability(env_config, timeout=25):
    """Probe which environment lights are reachable.

    Returns dict mapping control name to status:
      "online"   - all bulbs in group responding
      "degraded" - some bulbs responding, some not
      "offline"  - no bulbs responding or command failed entirely
    """
    if not env_config or not env_config.get("controls"):
        return {}

    status = {}
    for ctrl in env_config["controls"]:
        cmd_template = ctrl.get("set_command", "")
        if not cmd_template:
            continue
        # Extract the target group from the set_command (last word after office-lights.py)
        parts = cmd_template.split()
        script_idx = next(
            (i for i, p in enumerate(parts) if p.endswith("office-lights.py")), None
        )
        if script_idx is None:
            continue
        target = parts[-1] if parts[-1] not in ("{hue}", "{saturation}", "{brightness}") else "all"
        script_path = parts[script_idx]
        try:
            r = subprocess.run(
                [parts[0], script_path, "status", target],
                capture_output=True, text=True, timeout=timeout,
            )
            output = r.stdout + r.stderr
            if r.returncode == 0:
                status[ctrl["name"]] = "online"
            elif "Reachable: 0/" in output:
                status[ctrl["name"]] = "offline"
            else:
                # Partial: some bulbs OK, some failed
                status[ctrl["name"]] = "degraded"
        except (subprocess.TimeoutExpired, OSError):
            status[ctrl["name"]] = "offline"

    return status


def build_env_prompt_section(env_config, light_status=None):
    """Build the environment controls section for the analysis prompt.

    light_status: dict mapping control name to "online"/"degraded"/"offline".
    """
    if not env_config or not env_config.get("controls"):
        return ""

    if light_status is None:
        light_status = {}

    lines = ["\n## Environment controls (lights you can adjust)\n"]
    has_issues = False
    for ctrl in env_config["controls"]:
        name = ctrl["name"]
        desc = ctrl.get("description", "")
        ranges = ctrl.get("ranges", {})
        range_str = ", ".join(f"{k}: {v[0]}-{v[1]}" for k, v in ranges.items())
        st = light_status.get(name, "online")
        if st == "offline":
            lines.append(f"- **{name}**: OFFLINE (all bulbs unreachable). {desc}.")
            has_issues = True
        elif st == "degraded":
            lines.append(f"- **{name}**: DEGRADED (some bulbs unreachable). {desc}. Ranges: {range_str}")
            has_issues = True
        else:
            lines.append(f"- **{name}**: {desc}. Ranges: {range_str}")

    if has_issues:
        lines.append("")
        lines.append(
            "**WARNING: Some lights are offline or degraded.** You MUST compensate "
            "for reduced lighting by increasing brightness on the remaining lights "
            "and/or adjusting camera exposure settings (higher exposure_time_absolute, "
            "slightly higher gain or brightness) to maintain proper face illumination. "
            "The face must not be underlit just because a light is down."
        )

    lines.append("")
    lines.append("Include an \"env\" object in your response to adjust these.")
    lines.append("Only include lights that need changes. Omit lights that look good.")
    lines.append("Do NOT include offline lights in your env response.")
    lines.append("")
    return "\n".join(lines)


def apply_env_changes(env_changes, env_config, dry_run=False):
    """Apply environment control changes (lights, etc.)."""
    if not env_changes or not env_config:
        return []

    controls_by_name = {c["name"]: c for c in env_config.get("controls", [])}
    applied = []

    for name, values in env_changes.items():
        ctrl = controls_by_name.get(name)
        if not ctrl:
            continue

        cmd_template = ctrl.get("set_command", "")
        if not cmd_template:
            continue

        # Substitute values into command template
        cmd = cmd_template.format(
            hue=values.get("hue", 0),
            saturation=values.get("saturation", 0),
            brightness=values.get("brightness", 0),
        )

        tag = " (dry run)" if dry_run else ""
        h, s, b = values.get("hue", 0), values.get("saturation", 0), values.get("brightness", 0)
        applied.append(f"  {name}: H:{h} S:{s} B:{b}{tag}")

        if not dry_run:
            try:
                result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
                if result.returncode != 0:
                    err = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
                    applied.append(f"  {name}: FAILED ({err})")
            except (subprocess.TimeoutExpired, OSError) as e:
                applied.append(f"  {name}: FAILED ({e})")

    return applied


def run_deactivate_hook(env_config):
    """Run the on_deactivate command when camera stops."""
    if not env_config:
        return
    cmd = env_config.get("on_deactivate", "")
    if cmd:
        try:
            subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        except (subprocess.TimeoutExpired, OSError):
            pass


def check_dependencies(require_claude=True):
    """Verify required CLI tools are installed."""
    missing = []

    if not shutil.which("imagesnap"):
        missing.append(("imagesnap", "brew install imagesnap"))

    # Check for uvcc — could be global or via npx
    uvcc_ok = False
    if shutil.which("uvcc"):
        uvcc_ok = True
    else:
        try:
            subprocess.run(
                ["npx", "uvcc", "--version"],
                capture_output=True, timeout=15,
            )
            uvcc_ok = True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
    if not uvcc_ok:
        missing.append(("uvcc", "npm install -g uvcc"))

    if require_claude and not shutil.which("claude"):
        missing.append(("claude", "npm install -g @anthropic-ai/claude-code"))

    if missing:
        print("Missing required tools:\n", file=sys.stderr)
        for tool, install in missing:
            print(f"  {tool:12s}  →  {install}", file=sys.stderr)
        print("\nInstall them and try again.", file=sys.stderr)
        sys.exit(1)


def uvcc(*args):
    """Run a uvcc command and return stdout."""
    # Use npx to avoid requiring global install
    cmd = ["npx", "uvcc"] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return result.stdout.strip()


def detect_imagesnap_cameras():
    """Return camera names visible to imagesnap."""
    try:
        result = subprocess.run(
            ["imagesnap", "-l"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []

    cameras = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("=>"):
            name = line[2:].strip()
            if name:
                cameras.append(name)
    return cameras


def detect_camera(preferred=None):
    """Auto-detect a UVC camera. Returns (name, vendor, product) or exits."""
    try:
        output = uvcc("devices")
        devices = json.loads(output) if output else []
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        devices = []

    if preferred:
        for d in devices:
            if preferred.lower() in d["name"].lower():
                return d["name"], d["vendor"], d["product"]
        for name in detect_imagesnap_cameras():
            if preferred.lower() in name.lower():
                return name, None, None
        print(f"Camera matching '{preferred}' not found.", file=sys.stderr)
        print("Available cameras:", file=sys.stderr)
        for d in devices:
            print(f"  - {d['name']}", file=sys.stderr)
        for name in detect_imagesnap_cameras():
            print(f"  - {name} (capture-only)", file=sys.stderr)
        sys.exit(1)

    if not devices:
        cameras = detect_imagesnap_cameras()
        if cameras:
            return cameras[0], None, None
        print("No cameras detected. Is your webcam connected?", file=sys.stderr)
        sys.exit(1)

    d = devices[0]
    return d["name"], d["vendor"], d["product"]


def get_ranges(vendor, product):
    """Query dynamic UVC ranges, falling back to well-known defaults."""
    try:
        output = uvcc("ranges", "--vendor", str(vendor), "--product", str(product))
        ranges = json.loads(output) if output else {}
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        ranges = {}

    if not ranges:
        return dict(FALLBACK_RANGES)

    # Normalize uvcc range format: {"control": {"min": N, "max": N}} → {"control": (min, max)}
    result = {}
    for control, info in ranges.items():
        if isinstance(info, dict) and "min" in info and "max" in info:
            result[control] = (info["min"], info["max"])
        elif isinstance(info, list) and len(info) == 2:
            result[control] = (info[0], info[1])
    return result or dict(FALLBACK_RANGES)


def _find_video_call_window():
    """Find a video call window via CGWindowList. Returns (app_name, window_id, title) or None.

    Uses pyobjc to get Core Graphics window IDs, which work with screencapture -l
    regardless of window z-order (captures even when behind other windows).
    """
    try:
        import Quartz
    except ImportError:
        print("pyobjc-framework-Quartz not installed. Run: pip3 install pyobjc-framework-Quartz",
              file=sys.stderr)
        return None

    # App names and window title keywords that indicate a video call
    video_call_patterns = [
        ("Google Chrome", ["Meet -", "Google Meet"]),
        ("Arc", ["Meet -", "Google Meet"]),
        ("Safari", ["Meet -", "Google Meet", "FaceTime"]),
        ("zoom.us", ["Zoom Meeting"]),
        ("FaceTime", ["FaceTime"]),
    ]

    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    if not windows:
        return None

    for app_name, title_keywords in video_call_patterns:
        for w in windows:
            owner = w.get("kCGWindowOwnerName", "")
            name = str(w.get("kCGWindowName", "") or "")
            wid = w.get("kCGWindowNumber", 0)
            if owner != app_name or not name:
                continue
            if title_keywords:
                if any(kw in name for kw in title_keywords):
                    return (app_name, int(wid), name)
            else:
                return (app_name, int(wid), name)

    return None


def capture_screen(path=CAPTURE_PATH):
    """Capture the video call window via screencapture -l (by CG window ID).

    Works regardless of window z-order. The Meet window can be behind other windows.
    """
    match = _find_video_call_window()
    if not match:
        return False
    app_name, window_id, window_title = match
    short_title = window_title[:60] + "..." if len(window_title) > 60 else window_title
    print(f"Capturing from: {app_name} - {short_title}")
    result = subprocess.run(
        ["screencapture", "-l", str(window_id), "-x", "-o", path],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0 or not os.path.exists(path):
        print(f"screencapture failed: {result.stderr}", file=sys.stderr)
        return False
    return True


def detect_face_bboxes(image_path):
    """Detect faces in an image using macOS Vision framework.

    Returns bounding boxes in normalized coordinates (bottom-left origin, 0..1).
    Fails soft — returns [] when no face is detected or detection fails.
    """
    try:
        import Vision
        from Foundation import NSURL
    except ImportError:
        return []

    try:
        url = NSURL.fileURLWithPath_(str(image_path))
        handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, None)
        request = Vision.VNDetectFaceRectanglesRequest.alloc().init()
        success, _ = handler.performRequests_error_([request], None)
        if not success:
            return []

        results = request.results() or []
        if not results:
            return []

        boxes = []
        for obs in results:
            r = obs.boundingBox()
            boxes.append((r.origin.x, r.origin.y, r.size.width, r.size.height))
        return boxes
    except Exception:
        return []


def detect_face_bbox(image_path):
    """Detect the largest face in an image using macOS Vision framework."""
    boxes = detect_face_bboxes(image_path)
    if not boxes:
        return None
    return max(boxes, key=lambda box: box[2] * box[3])


def crop_to_face(image_path, output_path, margin=0.3):
    """Crop an image to the largest face + margin. In-place safe (src==dst OK).

    Returns True if cropped, False if no face detected (caller falls back
    to full frame). Fails soft — never raises.
    """
    try:
        from PIL import Image
    except ImportError:
        return False

    bbox = detect_face_bbox(image_path)
    if bbox is None:
        return False

    try:
        img = Image.open(image_path)
        img_w, img_h = img.size

        x_n, y_n, w_n, h_n = bbox
        # Vision gives bottom-left origin; PIL wants top-left.
        x_px = x_n * img_w
        w_px = w_n * img_w
        h_px = h_n * img_h
        y_top = img_h - (y_n * img_h) - h_px

        pad_w = w_px * margin
        pad_h = h_px * margin
        crop_box = (
            int(max(0, x_px - pad_w)),
            int(max(0, y_top - pad_h)),
            int(min(img_w, x_px + w_px + pad_w)),
            int(min(img_h, y_top + h_px + pad_h)),
        )
        cropped = img.crop(crop_box)
        cropped.save(output_path)
        return True
    except Exception:
        return False


def capture_frame(camera_name, path=CAPTURE_PATH, source="screen", warmup_secs=WARMUP_SECS):
    """Capture a frame. Tries screen capture first (what the call sees), falls back to imagesnap."""
    if source in ("screen", "auto"):
        if capture_screen(path):
            return True
        if source == "screen":
            print("No video call window found. Use --source camera for raw capture.", file=sys.stderr)
            return False
        print("No video call window found, falling back to camera capture...")

    result = subprocess.run(
        ["imagesnap", "-d", camera_name, "-w", str(warmup_secs), path],
        capture_output=True, text=True, timeout=30,
    )
    if not os.path.exists(path):
        print(f"Failed to capture frame: {result.stderr}", file=sys.stderr)
        return False
    return True


def get_current_settings(vendor, product):
    """Read current UVC settings."""
    try:
        output = uvcc("export", "--vendor", str(vendor), "--product", str(product))
        settings = json.loads(output) if output else {}
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        settings = {}
    return settings


def set_uvc(control, value, vendor, product):
    """Set a single UVC control."""
    uvcc("set", control, str(value), "--vendor", str(vendor), "--product", str(product))


def _detect_media_type(path):
    """Detect image media type from file header bytes."""
    with open(path, "rb") as f:
        header = f.read(4)
    if header[:4] == b"\x89PNG":
        return "image/png"
    if header[:2] == b"\xff\xd8":
        return "image/jpeg"
    return "image/png"  # screencapture default


def _get_api_key():
    """Read Anthropic API key from the process environment."""
    return os.environ.get("ANTHROPIC_API_KEY")


# Model mapping: short names to API model IDs
MODEL_MAP = {
    "haiku": "claude-haiku-4-5-20251001",
    "sonnet": "claude-sonnet-4-6",
    "opus": "claude-opus-4-7",
}


def call_claude_vision(image_path, prompt, model="sonnet", prev_image_path=None):
    """Send image(s) to Claude for visual analysis via direct API call.

    Uses Anthropic API directly for speed (~2s vs ~35s via CLI).
    Cost is negligible: ~$0.002/call with Haiku vision.
    """
    try:
        import anthropic
    except ImportError:
        print("anthropic SDK not installed. Run: pip3 install anthropic", file=sys.stderr)
        return None

    api_key = _get_api_key()
    if not api_key:
        print("No Anthropic API key found in ANTHROPIC_API_KEY", file=sys.stderr)
        return None

    client = anthropic.Anthropic(api_key=api_key)
    content = []

    # If we have a previous image, send it first for before/after comparison
    if prev_image_path and os.path.exists(prev_image_path):
        with open(prev_image_path, "rb") as f:
            prev_data = f.read()
        content.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": _detect_media_type(prev_image_path),
                "data": base64.b64encode(prev_data).decode("utf-8"),
            },
        })

    with open(image_path, "rb") as f:
        image_data = f.read()

    content.append({
        "type": "image",
        "source": {
            "type": "base64",
            "media_type": _detect_media_type(image_path),
            "data": base64.b64encode(image_data).decode("utf-8"),
        },
    })
    content.append({"type": "text", "text": prompt})

    model_id = MODEL_MAP.get(model, model)

    try:
        response = client.messages.create(
            model=model_id,
            max_tokens=1024,
            messages=[{"role": "user", "content": content}],
        )
        return response.content[0].text
    except Exception as e:
        print(f"Claude vision failed: {e}", file=sys.stderr)
        return None


def parse_recommendations(text):
    """Parse JSON recommendations from Claude's response."""
    text = re.sub(r"^```(?:json)?\s*", "", text.strip())
    text = re.sub(r"\s*```$", "", text.strip())

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", text)
        if match:
            try:
                return json.loads(match.group())
            except json.JSONDecodeError:
                pass
    print(f"Could not parse recommendations:\n{text[:500]}", file=sys.stderr)
    return None


def clamp(value, control, ranges):
    """Clamp value to valid range for a control."""
    if control in ranges:
        lo, hi = ranges[control]
        return max(lo, min(hi, int(value)))
    return int(value)


def apply_changes(recs, ranges, vendor, product, dry_run=False):
    """Apply recommended changes."""
    changes = recs.get("changes", {})
    awb = recs.get("auto_white_balance_temperature")
    aem = recs.get("auto_exposure_mode")

    applied = []
    tag = " (dry run)" if dry_run else ""

    # Apply auto modes first — they affect whether manual values stick
    if awb is not None:
        val = 1 if awb else 0
        if not dry_run:
            set_uvc("auto_white_balance_temperature", val, vendor, product)
        applied.append(f"  auto_white_balance_temperature: {val}{tag}")
        if val == 1:
            changes.pop("white_balance_temperature", None)

    if aem is not None:
        val = int(aem)
        if not dry_run:
            set_uvc("auto_exposure_mode", val, vendor, product)
        applied.append(f"  auto_exposure_mode: {val}{tag}")
        if val == 8:  # auto mode — manual exposure/gain won't stick
            changes.pop("exposure_time_absolute", None)

    for control, value in changes.items():
        value = clamp(value, control, ranges)
        if not dry_run:
            set_uvc(control, value, vendor, product)
        applied.append(f"  {control}: {value}{tag}")

    return applied


def restore_settings(settings, vendor, product):
    for control, value in settings.items():
        if isinstance(value, list):
            continue
        set_uvc(control, str(value), vendor, product)


def _log_event(event):
    """Append one optimization event to events.jsonl. Fails silently — telemetry
    must never crash the optimizer.

    Schema (see specs/ojo.md §Telemetry & Feedback Loop):
      ts, source, model, rounds_run, verdict, reverted, dry_run, elapsed_ms
    """
    try:
        os.makedirs(DEFAULT_PROFILE_DIR, exist_ok=True)
        with open(EVENTS_PATH, "a") as f:
            f.write(json.dumps(event) + "\n")
    except OSError:
        pass


def _append_jsonl(path, event):
    """Append a JSON object to a JSONL file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(event, sort_keys=True) + "\n")


def load_recent_check_cache(max_age_seconds, cache_path=CHECK_CACHE_PATH):
    if not max_age_seconds:
        return None
    try:
        with open(cache_path) as f:
            payload = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    ts = payload.get("cache_written_at")
    try:
        age = time.time() - float(ts)
    except (TypeError, ValueError):
        return None
    if age > max_age_seconds:
        return None
    result = dict(payload.get("result") or {})
    if not result:
        return None
    result["cached"] = True
    result["cache_age_seconds"] = round(age, 1)
    return result


def write_check_cache(result, cache_path=CHECK_CACHE_PATH):
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w") as f:
            json.dump({
                "cache_written_at": time.time(),
                "result": result,
            }, f, indent=2, sort_keys=True)
    except OSError:
        pass


def _utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = (len(ordered) - 1) * pct
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return float(ordered[int(rank)])
    return float(ordered[lower] * (upper - rank) + ordered[upper] * (rank - lower))


def _bbox_to_pixels(bbox, img_w, img_h):
    x_n, y_n, w_n, h_n = bbox
    x_px = int(max(0, x_n * img_w))
    w_px = int(min(img_w - x_px, w_n * img_w))
    h_px = int(min(img_h, h_n * img_h))
    y_top = int(max(0, img_h - (y_n * img_h) - h_px))
    return (x_px, y_top, x_px + w_px, y_top + h_px)


def _mean_luma(pixels):
    if not pixels:
        return 0.0
    lumas = [(0.2126 * r + 0.7152 * g + 0.0722 * b) for r, g, b in pixels]
    return sum(lumas) / len(lumas)


def _profile_age_minutes(profile_path=DEFAULT_PROFILE_PATH):
    if not os.path.exists(profile_path):
        return None
    try:
        return int((time.time() - os.path.getmtime(profile_path)) / 60)
    except OSError:
        return None


def current_time_bucket(now=None):
    now = now or time.localtime()
    hour = now.tm_hour
    if 5 <= hour < 11:
        return "morning"
    if 11 <= hour < 15:
        return "midday"
    if 15 <= hour < 19:
        return "afternoon"
    return "evening"


def load_profile_map(path=PROFILE_MAP_PATH):
    if not os.path.exists(path):
        return {"schema_version": 1, "profiles": {}}
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"schema_version": 1, "profiles": {}}
        data.setdefault("schema_version", 1)
        data.setdefault("profiles", {})
        return data
    except (OSError, json.JSONDecodeError):
        return {"schema_version": 1, "profiles": {}}


def select_profile_status(scene, profile_map=None):
    profile_map = profile_map or load_profile_map()
    bucket = current_time_bucket()
    profiles = profile_map.get("profiles", {})
    profile = profiles.get(bucket)
    return {
        "bucket": bucket,
        "profile_id": bucket if profile else None,
        "profile_available": bool(profile),
        "profile_map_exists": bool(profiles),
    }


def update_profile_map(
    settings,
    scene,
    profile_map_path=PROFILE_MAP_PATH,
    room="default",
):
    profile_map = load_profile_map(profile_map_path)
    bucket = current_time_bucket()
    profile_map.setdefault("schema_version", 1)
    profiles = profile_map.setdefault("profiles", {})
    profiles[bucket] = {
        "schema_version": 1,
        "room": room,
        "time_bucket": bucket,
        "updated_at": _utc_now(),
        "ambient": {
            "luma_mean": scene.get("face_luma_mean"),
            "rgb_balance": scene.get("rgb_balance"),
            "face_detected": scene.get("face_detected"),
            "background_luma_mean": scene.get("background_luma_mean"),
        },
        "camera": {
            "settings": settings,
        },
        "lights": scene.get("light_status", {}),
        "quality": {
            "last_verified_at": _utc_now(),
            "look_score": scene.get("look_score"),
            "manual_rescue_count": 0,
        },
    }
    os.makedirs(os.path.dirname(profile_map_path), exist_ok=True)
    with open(profile_map_path, "w") as f:
        json.dump(profile_map, f, indent=2, sort_keys=True)
    return profiles[bucket]


def framing_metrics(face_bbox):
    if not face_bbox:
        return {
            "face_center_x": None,
            "face_center_y": None,
            "face_height_pct": 0.0,
            "headroom_pct": None,
            "framing_state": "red",
            "framing_reason": "no face detected",
        }
    x, y, w, h = face_bbox
    center_x = x + w / 2
    center_y = y + h / 2
    headroom = 1 - (y + h)
    issues = []
    if center_x < 0.38:
        issues.append("face too far left")
    elif center_x > 0.62:
        issues.append("face too far right")
    if h < 0.25:
        issues.append("face too small")
    elif h > 0.55:
        issues.append("face too large")
    if headroom < 0.04:
        issues.append("too little headroom")
    elif headroom > 0.24:
        issues.append("too much headroom")
    return {
        "face_center_x": round(center_x, 3),
        "face_center_y": round(center_y, 3),
        "face_height_pct": round(h, 3),
        "headroom_pct": round(headroom, 3),
        "framing_state": "yellow" if issues else "green",
        "framing_reason": ", ".join(issues) if issues else "framing looks balanced",
    }


def describe_scene(image_path, face_bboxes, light_status=None, profile_path=DEFAULT_PROFILE_PATH):
    """Build local scene metrics for deterministic Green/Yellow/Red checks."""
    try:
        from PIL import Image
    except ImportError as e:
        raise RuntimeError("Pillow is required for scene metrics") from e

    light_status = light_status or {}
    img = Image.open(image_path).convert("RGB")
    img_w, img_h = img.size
    face_bbox = detect_largest_bbox(face_bboxes)
    face_pixels_box = _bbox_to_pixels(face_bbox, img_w, img_h) if face_bbox else None
    region = img.crop(face_pixels_box) if face_pixels_box else img
    pixels = list(region.getdata())
    if not pixels:
        raise RuntimeError("captured frame is unreadable")

    lumas = [(0.2126 * r + 0.7152 * g + 0.0722 * b) for r, g, b in pixels]
    full_pixels = list(img.getdata())
    background_luma = _mean_luma(full_pixels)
    if face_pixels_box:
        mask = Image.new("L", img.size, 0)
        try:
            from PIL import ImageDraw
            draw = ImageDraw.Draw(mask)
            draw.rectangle(face_pixels_box, fill=255)
            bg_pixels = [px for px, m in zip(full_pixels, mask.getdata()) if not m]
            background_luma = _mean_luma(bg_pixels) if bg_pixels else background_luma
        except Exception:
            pass
    count = len(lumas)
    means = [sum(channel) / count for channel in zip(*pixels)]
    avg_rgb = sum(means) / 3 if means else 1.0
    rgb_balance = [round(v / avg_rgb, 3) if avg_rgb else 1.0 for v in means]
    profile_age = _profile_age_minutes(profile_path)
    offline = [name for name, status in light_status.items() if status == "offline"]
    degraded = [name for name, status in light_status.items() if status == "degraded"]

    scene = {
        "face_detected": bool(face_bboxes),
        "face_count": len(face_bboxes),
        "face_bbox": [round(v, 4) for v in face_bbox] if face_bbox else None,
        "face_luma_mean": round(sum(lumas) / count, 2),
        "face_luma_p05": round(_percentile(lumas, 0.05), 2),
        "face_luma_p95": round(_percentile(lumas, 0.95), 2),
        "face_tonal_range": round(_percentile(lumas, 0.95) - _percentile(lumas, 0.05), 2),
        "background_luma_mean": round(background_luma, 2),
        "highlight_clip_pct": round(sum(1 for v in lumas if v >= 245) / count * 100, 3),
        "shadow_clip_pct": round(sum(1 for v in lumas if v <= 10) / count * 100, 3),
        "rgb_balance": rgb_balance,
        "profile_age_minutes": profile_age,
        "profile_exists": profile_age is not None,
        "lights_reachable": not offline,
        "lights_degraded": bool(degraded),
        "light_status": light_status,
    }
    scene.update(framing_metrics(face_bbox))
    scene["background_separation"] = round(scene["face_luma_mean"] - scene["background_luma_mean"], 2)
    scene["look_score"] = score_look(scene)["score"]
    return scene


def score_look(scene):
    """Score how good the scene looks beyond bare pass/fail."""
    score = 100
    strengths = []
    issues = []

    tonal_range = scene.get("face_tonal_range", 0)
    if tonal_range < 80:
        score -= 18
        issues.append("face lacks dimensional tonal variation")
    else:
        strengths.append("good face tonal variation")

    face_mean = scene.get("face_luma_mean", 0)
    p95 = scene.get("face_luma_p95", 0)
    separation = scene.get("background_separation", 0)
    face_reads_white = (
        face_mean >= FACE_WHITE_LUMA_WARN
        and (
            p95 >= FACE_WHITE_P95_WARN
            or tonal_range < FACE_WHITE_TONAL_RANGE_WARN
            or separation > FACE_WHITE_SEPARATION_WARN
        )
    )
    if face_mean < 85:
        score -= 12
        issues.append("face reads a little dark")
    elif face_reads_white:
        score -= 18
        issues.append("face reads too white or flat for the saved preference")
    elif face_mean > 165:
        score -= 16
        issues.append("face risks looking too bright or flat")
    else:
        strengths.append("face exposure is in the flattering range")

    if separation < 10:
        score -= 12
        issues.append("background is not separated enough from face")
    elif separation > 65:
        score -= 6
        issues.append("background may be too dark relative to face")
    else:
        strengths.append("face/background separation is good")

    rgb_balance = scene.get("rgb_balance") or [1.0, 1.0, 1.0]
    drift = max(abs(v - 1.0) for v in rgb_balance)
    if drift > 0.18:
        score -= 14
        issues.append("white balance is visibly uneven")
    else:
        strengths.append("white balance is coherent")

    if scene.get("framing_state") != "green":
        score -= 12
        issues.append(scene.get("framing_reason", "framing needs adjustment"))
    else:
        strengths.append("framing is balanced")

    if scene.get("highlight_clip_pct", 0) > 0.2:
        score -= 10
        issues.append("small highlight clipping risk")
    if scene.get("shadow_clip_pct", 0) > 1.0:
        score -= 8
        issues.append("small shadow clipping risk")

    score = max(0, min(100, int(round(score))))
    if score >= 88:
        label = "great"
    elif score >= 75:
        label = "good"
    elif score >= 60:
        label = "acceptable"
    else:
        label = "needs work"
    return {
        "score": score,
        "label": label,
        "strengths": strengths[:4],
        "issues": issues[:5],
    }


def scene_needs_light_help(checks):
    """Whether unreachable lights should be a hard blocker for this scene."""
    for name in ("face", "exposure", "white_balance"):
        if checks.get(name, {}).get("state") == "red":
            return True
    exposure_reason = checks.get("exposure", {}).get("reason", "")
    return "dark" in exposure_reason or "shadow" in exposure_reason


def detect_largest_bbox(face_bboxes):
    if not face_bboxes:
        return None
    return max(face_bboxes, key=lambda box: box[2] * box[3])


def classify_scene(scene):
    """Classify local scene metrics into Green/Yellow/Red."""
    checks = {
        "camera": {"state": "green", "reason": "camera reachable"},
        "face": {"state": "green", "reason": "one face detected"},
        "framing": {"state": "green", "reason": "framing looks balanced"},
        "exposure": {"state": "green", "reason": "face exposure within conservative range"},
        "white_balance": {"state": "green", "reason": "rgb balance within conservative range"},
        "background": {"state": "green", "reason": "background separation looks good"},
        "profile": {"state": "green", "reason": "profile fresh or not required"},
        "lights": {"state": "green", "reason": "required lights reachable or not configured"},
    }

    if not scene.get("face_detected"):
        checks["face"] = {"state": "red", "reason": "no face detected"}
    elif scene.get("face_count", 0) > 1:
        checks["face"] = {"state": "red", "reason": "multiple faces detected"}

    if scene.get("framing_state") == "red":
        checks["framing"] = {"state": "red", "reason": scene.get("framing_reason", "framing blocked")}
    elif scene.get("framing_state") == "yellow":
        checks["framing"] = {"state": "yellow", "reason": scene.get("framing_reason", "framing needs adjustment")}

    p95 = scene.get("face_luma_p95", 0)
    p05 = scene.get("face_luma_p05", 0)
    mean = scene.get("face_luma_mean", 0)
    tonal_range = scene.get("face_tonal_range", 0)
    separation = scene.get("background_separation", 0)
    highlight_clip = scene.get("highlight_clip_pct", 0)
    shadow_clip = scene.get("shadow_clip_pct", 0)
    face_reads_white = (
        mean >= FACE_WHITE_LUMA_WARN
        and (
            p95 >= FACE_WHITE_P95_WARN
            or tonal_range < FACE_WHITE_TONAL_RANGE_WARN
            or separation > FACE_WHITE_SEPARATION_WARN
        )
    )
    if highlight_clip >= 3 or shadow_clip >= 15 or p95 >= 252 or p05 <= 3:
        checks["exposure"] = {"state": "red", "reason": "severe clipping in face region"}
    elif mean < 70 or shadow_clip >= 5:
        checks["exposure"] = {"state": "yellow", "reason": "mild dark/shadow exposure issue"}
    elif face_reads_white:
        checks["exposure"] = {"state": "yellow", "reason": "face reads too white or flat for the saved preference"}
    elif mean > 185 or highlight_clip >= 0.5:
        checks["exposure"] = {"state": "yellow", "reason": "mild bright/highlight exposure issue"}

    rgb_balance = scene.get("rgb_balance") or [1.0, 1.0, 1.0]
    max_channel_drift = max(abs(v - 1.0) for v in rgb_balance)
    if max_channel_drift >= 0.35:
        checks["white_balance"] = {"state": "red", "reason": "severe color imbalance"}
    elif max_channel_drift >= 0.18:
        checks["white_balance"] = {"state": "yellow", "reason": "mild white-balance issue"}

    if separation < -20:
        checks["background"] = {"state": "yellow", "reason": "background is brighter than face"}
    elif separation < 10:
        checks["background"] = {"state": "yellow", "reason": "weak face/background separation"}
    elif separation > 65:
        checks["background"] = {"state": "yellow", "reason": "background too dark relative to face"}

    profile_age = scene.get("profile_age_minutes")
    if profile_age is None:
        checks["profile"] = {"state": "yellow", "reason": "no recent accepted tune profile"}
    elif profile_age > 8 * 60:
        checks["profile"] = {"state": "yellow", "reason": f"profile stale ({profile_age}m old)"}

    if not scene.get("lights_reachable", True):
        if scene_needs_light_help(checks):
            checks["lights"] = {
                "state": "red",
                "reason": "lights unreachable and scene needs lighting help",
            }
        else:
            checks["lights"] = {
                "state": "yellow",
                "reason": "lights unreachable but scene metrics are acceptable",
            }
    elif scene.get("lights_degraded", False):
        checks["lights"] = {"state": "yellow", "reason": "one or more lights degraded"}

    if any(check["state"] == "red" for check in checks.values()):
        state = "red"
    elif any(check["state"] == "yellow" for check in checks.values()):
        state = "yellow"
    else:
        state = "green"

    reasons = [check["reason"] for check in checks.values() if check["state"] == state]
    quality = score_look(scene)
    return {
        "state": state,
        "reason": reasons[0] if reasons else "all checks passed",
        "checks": checks,
        "quality": quality,
        "scene": scene,
    }


def run_pre_call_check(args, camera_name, profile_path=DEFAULT_PROFILE_PATH):
    start = time.time()
    env_config = load_env_config()
    if getattr(args, "skip_lights", False):
        light_status = {}
    else:
        light_status = probe_env_reachability(env_config, timeout=getattr(args, "light_timeout", 1.5))
    capture_path = getattr(args, "capture_path", CAPTURE_PATH)
    warmup_secs = getattr(args, "warmup_seconds", 1)

    if not capture_frame(camera_name, capture_path, source="camera", warmup_secs=warmup_secs):
        raise RuntimeError("unable to capture raw camera frame")

    face_bboxes = detect_face_bboxes(capture_path)
    scene = describe_scene(
        capture_path,
        face_bboxes,
        light_status=light_status,
        profile_path=profile_path,
    )
    result = classify_scene(scene)
    result["profile_status"] = select_profile_status(scene)
    result["elapsed_ms"] = int((time.time() - start) * 1000)
    result["ts"] = _utc_now()

    if getattr(args, "log", False):
        event = {
            "ts": result["ts"],
            "event_type": "pre_call_check",
            "state": result["state"],
            "reason": result["reason"],
            "camera_detected": True,
            "face_detected": scene["face_detected"],
            "profile_applied": False,
            "ai_tune_run": False,
            "scene": scene,
            "checks": result["checks"],
            "quality": result["quality"],
            "profile_status": result["profile_status"],
            "elapsed_ms": result["elapsed_ms"],
        }
        _log_event(event)

    return result


def cmd_check(args, camera_name):
    cached = load_recent_check_cache(getattr(args, "max_age_seconds", 0))
    if cached:
        if args.json:
            print(json.dumps(cached, sort_keys=True))
        else:
            print(f"{cached['state'].capitalize()}: {cached['reason']} (cached)")
        return cached

    try:
        result = run_pre_call_check(args, camera_name, profile_path=args.profile)
    except Exception as e:
        if args.json:
            print(json.dumps({
                "state": "red",
                "reason": str(e),
                "checks": {"camera": {"state": "red", "reason": str(e)}},
                "scene": {},
            }))
        else:
            print(f"Red: {e}", file=sys.stderr)
        sys.exit(1)

    write_check_cache(result)
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(f"{result['state'].capitalize()}: {result['reason']}")
    return result


def build_feedback_event(kind, note, call_session_id=None, snapshot=None):
    return {
        "ts": _utc_now(),
        "kind": kind,
        "note": note,
        "call_session_id": call_session_id,
        "state_snapshot": snapshot,
    }


def cmd_feedback(args):
    path = FEEDBACK_PATH if args.feedback_kind == "bad" else COMMENTS_PATH
    snapshot = load_recent_check_cache(10 * 60)
    if snapshot:
        snapshot.pop("cached", None)
    event = build_feedback_event(
        args.feedback_kind,
        args.note,
        call_session_id=args.call_session_id,
        snapshot=snapshot,
    )
    if args.dry_run:
        print(json.dumps(event, sort_keys=True))
        return event
    _append_jsonl(path, event)
    print(f"Logged {args.feedback_kind}.")
    return event


def cmd_profiles(args):
    profile_map = load_profile_map(args.profile_map)
    status = select_profile_status({}, profile_map)
    output = {
        "schema_version": profile_map.get("schema_version", 1),
        "profile_count": len(profile_map.get("profiles", {})),
        "current": status,
    }
    if args.json:
        print(json.dumps(output, sort_keys=True))
    else:
        available = "available" if status["profile_available"] else "missing"
        print(f"{status['bucket']}: {available} ({output['profile_count']} profiles)")
    return output


def ai_repair_needed(check_result):
    checks = check_result.get("checks", {})
    quality = check_result.get("quality", {})
    if quality.get("score", 100) < 60:
        return True
    for name in ("exposure", "white_balance"):
        if checks.get(name, {}).get("state") == "red":
            return True
    return False


def calibration_recommendation(check_result):
    issue = ""
    quality = check_result.get("quality", {})
    issues = quality.get("issues") or []
    if issues:
        issue = issues[0]
    else:
        issue = check_result.get("reason", "")
    if "headroom" in issue or "too far" in issue or "face too" in issue:
        return "Use Apply Framing Fix or the composition arrows; AI Tune is not needed."
    if "background" in issue:
        return "Background separation needs adjustment; use room lighting or framing, not AI Tune."
    if "white balance" in issue:
        return "Scene is acceptable; avoid AI Tune unless color is visibly bad."
    if "lights" in issue:
        return "Scene metrics are acceptable; fix light reachability separately."
    return "Scene does not need AI Tune."


def cmd_calibrate(args, camera_name, vendor, product):
    pre_args = argparse.Namespace(
        log=not args.dry_run,
        json=True,
        profile=args.profile,
        skip_lights=False,
        light_timeout=1.0,
        warmup_seconds=1,
    )
    pre = run_pre_call_check(pre_args, camera_name, profile_path=args.profile)
    if not args.force_ai and not ai_repair_needed(pre):
        result = {
            "skipped_ai_tune": True,
            "profile_updated": False,
            "pre_state": pre["state"],
            "pre_quality": pre["quality"],
            "scene": pre.get("scene", {}),
            "recommendation": calibration_recommendation(pre),
        }
        if args.json or args.dry_run:
            print(json.dumps(result, sort_keys=True))
        else:
            print(result["recommendation"])
        return result

    if args.dry_run:
        print(json.dumps({
            "would_run_ai_tune": True,
            "would_update_profile_bucket": current_time_bucket(),
            "pre_state": pre["state"],
            "pre_quality": pre["quality"],
        }, sort_keys=True))
        return None

    ranges = get_ranges(vendor, product)
    opt_args = argparse.Namespace(
        rounds=1,
        dry_run=False,
        save=True,
        profile=args.profile,
        model=args.model,
        source="camera",
        verify=True,
    )
    tune_event = cmd_optimize(opt_args, camera_name, vendor, product, ranges)
    if tune_event.get("reverted"):
        print("Calibration rejected: AI Tune verified worse and reverted.", file=sys.stderr)
        sys.exit(1)
    if tune_event.get("verdict") not in ("better", "same"):
        print("Calibration rejected: no successful verification verdict.", file=sys.stderr)
        sys.exit(1)

    post = run_pre_call_check(pre_args, camera_name, profile_path=args.profile)
    settings = get_current_settings(vendor, product)
    profile = update_profile_map(settings, post["scene"], profile_map_path=args.profile_map)
    result = {
        "bucket": profile["time_bucket"],
        "pre_state": pre["state"],
        "post_state": post["state"],
        "pre_quality": pre["quality"],
        "post_quality": post["quality"],
        "profile_updated": True,
    }
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(
            f"Calibrated {profile['time_bucket']}: "
            f"{post['state']} / {post['quality']['label']} ({post['quality']['score']})"
        )
    return result


def save_profile(vendor, product, profile_path):
    """Save current settings as a profile."""
    settings = get_current_settings(vendor, product)
    os.makedirs(os.path.dirname(profile_path), exist_ok=True)
    with open(profile_path, "w") as f:
        json.dump(settings, f, indent=2)
    return settings


def restore_profile(vendor, product, profile_path):
    """Restore settings from a saved profile."""
    if not os.path.exists(profile_path):
        print(f"No saved profile at {profile_path}", file=sys.stderr)
        sys.exit(1)

    with open(profile_path) as f:
        settings = json.load(f)

    print(f"Restoring profile from {profile_path}")
    for control, value in settings.items():
        set_uvc(control, str(value), vendor, product)
        print(f"  {control}: {value}")
    print("Profile restored.")


def cmd_optimize(args, camera_name, vendor, product, ranges):
    """Run the optimize loop."""
    opt_start = time.time()
    event = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": getattr(args, "source", "auto"),
        "model": args.model,
        "rounds_planned": args.rounds,
        "rounds_run": 0,
        "verdict": None,
        "reverted": False,
        "dry_run": args.dry_run,
    }
    prev_capture = None
    env_config = load_env_config()

    # Probe which lights are reachable before asking Claude to use them
    light_status = probe_env_reachability(env_config)
    issues = {n: s for n, s in light_status.items() if s != "online"}
    if issues:
        for name, st in sorted(issues.items()):
            print(f"Light {st}: {name}")

    env_section = build_env_prompt_section(env_config, light_status)

    if env_config and env_config.get("controls"):
        total = len(env_config["controls"])
        offline_count = sum(1 for s in light_status.values() if s == "offline")
        print(f"Environment controls: {total - offline_count}/{total} lights available")

    # Save pre-optimization capture for verification pass
    pre_opt_capture = None
    pre_opt_settings = None

    for round_num in range(1, args.rounds + 1):
        event["rounds_run"] = round_num
        if args.rounds > 1:
            print(f"\n--- Round {round_num}/{args.rounds} ---")

        # Capture frame and read UVC settings in parallel
        from concurrent.futures import ThreadPoolExecutor
        source = getattr(args, "source", "auto")
        with ThreadPoolExecutor(max_workers=2) as pool:
            settings_future = pool.submit(get_current_settings, vendor, product)
            capture_future = pool.submit(capture_frame, camera_name, CAPTURE_PATH, source)
            current = settings_future.result()
            if not capture_future.result():
                sys.exit(1)

        # Crop analysis frame to face + 30% margin. Eliminates scene clutter
        # and focuses Claude's attention on what matters (face exposure,
        # skin tone). Fails soft — on no-face-detected or any error, falls
        # through to full-frame analysis.
        if crop_to_face(CAPTURE_PATH, CAPTURE_PATH):
            event["face_cropped"] = True
        else:
            event["face_cropped"] = False
            print("No face detected; analyzing full frame.")

        # Keep the very first capture for verification (before any AI changes)
        if round_num == 1 and getattr(args, "verify", False):
            import shutil as _shutil
            pre_opt_capture = "/tmp/camtune-pre-opt.png"
            pre_opt_settings = dict(current)
            _shutil.copy2(CAPTURE_PATH, pre_opt_capture)

        # Build prompt with or without comparison note
        is_followup = prev_capture is not None
        comparison_note = COMPARISON_NOTE_FOLLOWUP if is_followup else COMPARISON_NOTE_FIRST
        ranges_str = "\n".join(
            f"- {k}: {lo}-{hi}" for k, (lo, hi) in sorted(ranges.items())
        )
        prompt = ANALYSIS_PROMPT.format(
            camera_name=camera_name,
            current_settings=json.dumps(current, indent=2),
            ranges=ranges_str,
            env_section=env_section,
            comparison_note=comparison_note,
        )

        print(f"Analyzing with Claude ({args.model})...")
        response = call_claude_vision(
            CAPTURE_PATH, prompt, model=args.model,
            prev_image_path=prev_capture if is_followup else None,
        )
        if not response:
            sys.exit(1)

        recs = parse_recommendations(response)
        if not recs:
            sys.exit(1)

        assessment = recs.get("assessment", "No assessment provided")
        print(f"\nAssessment: {assessment}")

        changes = recs.get("changes", {})
        env_changes = recs.get("env", {})
        awb = recs.get("auto_white_balance_temperature")
        aem = recs.get("auto_exposure_mode")
        if not changes and not env_changes and awb is None and aem is None:
            print("No changes needed — image looks good.")
            break

        # Apply camera changes
        if changes or awb is not None or aem is not None:
            print("\nCamera:" if not args.dry_run else "\nCamera (recommended):")
            applied = apply_changes(recs, ranges, vendor, product, dry_run=args.dry_run)
            for line in applied:
                print(line)

        # Apply environment changes (lights)
        if env_changes:
            print("\nLighting:" if not args.dry_run else "\nLighting (recommended):")
            env_applied = apply_env_changes(env_changes, env_config, dry_run=args.dry_run)
            for line in env_applied:
                print(line)

        # Save current capture as "before" for next round's comparison
        if not args.dry_run and round_num < args.rounds:
            import shutil as _shutil
            _shutil.copy2(CAPTURE_PATH, PREV_CAPTURE_PATH)
            prev_capture = PREV_CAPTURE_PATH
            # Longer settle time when lights changed — bulbs need time to transition
            settle = SETTLE_SECS + (2 if env_changes else 0)
            print(f"Waiting {settle}s for settings to settle...")
            time.sleep(settle)

    # Verification pass: capture result, compare before/after, revert if worse
    if getattr(args, "verify", False) and not args.dry_run and pre_opt_capture:
        settle = SETTLE_SECS + 2  # extra time for lights
        print(f"\nVerification: waiting {settle}s for settings to settle...")
        time.sleep(settle)

        verify_path = "/tmp/camtune-verify.png"
        source = getattr(args, "source", "auto")
        if capture_frame(camera_name, verify_path, source):
            # Match the analysis crop so before/after comparison is apples-to-apples.
            crop_to_face(verify_path, verify_path)
            print(f"Verifying with Claude ({args.model})...")
            response = call_claude_vision(
                verify_path, VERIFY_PROMPT, model=args.model,
                prev_image_path=pre_opt_capture,
            )
            if response:
                verdict = parse_recommendations(response)
                if verdict:
                    v = verdict.get("verdict", "same")
                    reason = verdict.get("reason", "")
                    event["verdict"] = v
                    event["verdict_reason"] = reason[:200]
                    print(f"Verdict: {v} — {reason}")
                    if v == "worse":
                        print("Reverting to pre-tune camera settings...")
                        if pre_opt_settings:
                            restore_settings(pre_opt_settings, vendor, product)
                        else:
                            restore_profile(vendor, product, args.profile)
                        print("Reverted. Original camera settings restored.")
                        event["reverted"] = True
                        event["elapsed_ms"] = int((time.time() - opt_start) * 1000)
                        _log_event(event)
                        return event
                else:
                    event["verdict"] = "failed"
                    event["verdict_reason"] = "verification response could not be parsed"
            else:
                event["verdict"] = "failed"
                event["verdict_reason"] = "verification model call failed"
        else:
            event["verdict"] = "failed"
            event["verdict_reason"] = "verification capture failed"

        if event.get("verdict") == "failed":
            print("Verification failed; reverting to pre-tune camera settings...", file=sys.stderr)
            if pre_opt_settings:
                restore_settings(pre_opt_settings, vendor, product)
            event["reverted"] = True
            event["elapsed_ms"] = int((time.time() - opt_start) * 1000)
            _log_event(event)
            return event

    if args.save and not args.dry_run:
        print("\nSaving profile...")
        save_profile(vendor, product, args.profile)
        print(f"Profile saved to {args.profile}")

    event["elapsed_ms"] = int((time.time() - opt_start) * 1000)
    _log_event(event)
    return event


def daemon_install(args):
    """Install the LaunchAgent to auto-optimize on camera activation."""
    if not os.path.exists(args.profile):
        print(
            f"No saved profile at {args.profile}\n"
            "Run 'camtune --save' first to create a profile, then install the daemon.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Unload existing daemon if reinstalling
    if os.path.exists(LAUNCHAGENT_PATH):
        subprocess.run(["launchctl", "unload", LAUNCHAGENT_PATH],
                        capture_output=True, check=False)

    camtune_path = os.path.abspath(__file__)
    program_args = [
        "        <string>/usr/bin/python3</string>",
        f"        <string>{camtune_path}</string>",
        "        <string>daemon</string>",
        "        <string>run</string>",
    ]
    if args.optimize:
        program_args.append("        <string>--optimize</string>")
    if args.profile != DEFAULT_PROFILE_PATH:
        program_args.append("        <string>--profile</string>")
        program_args.append(f"        <string>{args.profile}</string>")

    # Build PATH that includes Homebrew so uvcc/npx/imagesnap are found
    path_dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    path_value = ":".join(path_dirs)

    plist = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LAUNCHAGENT_LABEL}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{path_value}</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
{chr(10).join(program_args)}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{DAEMON_LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>{DAEMON_LOG_PATH}</string>
</dict>
</plist>
"""

    os.makedirs(os.path.dirname(LAUNCHAGENT_PATH), exist_ok=True)
    os.makedirs(os.path.dirname(DAEMON_LOG_PATH), exist_ok=True)

    with open(LAUNCHAGENT_PATH, "w") as f:
        f.write(plist)

    subprocess.run(["launchctl", "load", LAUNCHAGENT_PATH], check=True)

    mode = "restore + AI optimize" if args.optimize else "restore only"
    print(f"Daemon installed ({mode}).")
    print(f"  Plist: {LAUNCHAGENT_PATH}")
    print(f"  Log:   {DAEMON_LOG_PATH}")


def daemon_uninstall(args):
    """Unload and remove the LaunchAgent."""
    if not os.path.exists(LAUNCHAGENT_PATH):
        print("Daemon is not installed.", file=sys.stderr)
        sys.exit(1)

    subprocess.run(["launchctl", "unload", LAUNCHAGENT_PATH], check=False)
    os.remove(LAUNCHAGENT_PATH)
    print("Daemon uninstalled.")


def daemon_status(args):
    """Check if the daemon is installed and running."""
    if not os.path.exists(LAUNCHAGENT_PATH):
        print("Not installed.")
        return

    result = subprocess.run(
        ["launchctl", "list", LAUNCHAGENT_LABEL],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        # Parse PID from launchctl list output
        for line in result.stdout.splitlines():
            if '"PID"' in line:
                pid = re.search(r"(\d+)", line)
                if pid:
                    print(f"Running (PID {pid.group(1)}).")
                    break
        else:
            print("Installed, not currently running.")
    else:
        print("Installed, not currently running.")

    print(f"  Plist: {LAUNCHAGENT_PATH}")
    print(f"  Log:   {DAEMON_LOG_PATH}")


def daemon_run(args):
    """Watch for camera activation and auto-restore/optimize."""
    import signal

    def _log(msg):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    # Log rotation — truncate if over 1MB
    if os.path.exists(DAEMON_LOG_PATH):
        try:
            if os.path.getsize(DAEMON_LOG_PATH) > MAX_LOG_BYTES:
                with open(DAEMON_LOG_PATH, "w") as f:
                    f.write("")
                _log("Log truncated (exceeded 1MB).")
        except OSError:
            pass

    _log(f"camtune daemon started (optimize={'yes' if args.optimize else 'no'}).")

    # Validate dependencies at startup (warn, don't exit — they might appear later)
    for tool in ["imagesnap", "npx"]:
        if not shutil.which(tool):
            _log(f"WARNING: '{tool}' not found in PATH. Camera restore will fail.")

    # Graceful shutdown
    running = True

    def _shutdown(signum, frame):
        nonlocal running
        _log(f"Received signal {signum}, shutting down.")
        running = False

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # Start with current time to ignore stale events replayed from log stream history.
    # The daemon won't respond to camera events for the first DEBOUNCE_SECS after startup.
    last_trigger = time.time()
    consecutive_failures = 0

    env_config = load_env_config()
    if env_config and env_config.get("controls"):
        _log(f"Environment controls: {len(env_config['controls'])} lights loaded")

    camera_active = False

    cmd = [
        "log", "stream", "--predicate",
        'subsystem == "com.apple.cmio" AND '
        '(eventMessage CONTAINS "adding stream" OR eventMessage CONTAINS "removing stream")',
    ]

    while running:
        _log("Watching for camera events...")
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
            consecutive_failures = 0
        except OSError as e:
            _log(f"Failed to start log stream: {e}")
            consecutive_failures += 1
            backoff = min(10 * consecutive_failures, 120)
            time.sleep(backoff)
            continue

        try:
            for line in proc.stdout:
                if not running:
                    break

                now = time.time()

                # Camera deactivation — only if we previously activated for a call
                if "removing stream" in line and camera_active:
                    if now - last_trigger < DEBOUNCE_SECS:
                        continue
                    last_trigger = now
                    camera_active = False

                    _log("Camera deactivated. Restoring normal lighting.")
                    run_deactivate_hook(env_config)
                    continue

                # Camera activation
                if "adding stream" not in line:
                    continue

                if now - last_trigger < DEBOUNCE_SECS:
                    continue

                # Check if this is just CamTune.app's preview, not a real call
                call_active, app_name = is_video_call_active()
                if not call_active:
                    _log("Camera event ignored (CamTune preview, not a video call).")
                    continue

                last_trigger = now
                camera_active = True

                _log("Camera activation detected.")

                try:
                    camera_name, vendor, product = detect_camera()
                    _log(f"Camera: {camera_name}")

                    # Phase 1: Conditional pre-warm.
                    # Apply stored profile only if fresh (<=2h). A stale profile
                    # from a different time-of-day can be worse than letting the
                    # platform's auto-WB/AE run until the optimizer sets the final
                    # state. Phase 4 calibration replaces this heuristic with a
                    # time-of-day-keyed profile map.
                    if os.path.exists(args.profile):
                        age_secs = time.time() - os.path.getmtime(args.profile)
                        fresh = age_secs < 2 * 3600
                        if fresh or not args.optimize:
                            _log(f"Restoring profile (age: {age_secs/60:.0f}m)...")
                            restore_profile(vendor, product, args.profile)
                            _log("Profile restored.")
                        else:
                            _log(f"Profile is {age_secs/3600:.1f}h old (stale). Skipping restore; platform auto-WB will run until optimizer sets final state.")
                    else:
                        _log(f"No profile at {args.profile}, skipping restore.")

                    # Phase 2: AI optimization (camera + lights)
                    if args.optimize:
                        _log("Running AI optimization (camera + environment)...")
                        ranges = get_ranges(vendor, product)
                        opt_args = argparse.Namespace(
                            rounds=1, dry_run=False, save=True,
                            profile=args.profile, model="opus",
                            source="camera", verify=True,
                        )
                        cmd_optimize(opt_args, camera_name, vendor, product, ranges)
                        # Reset debounce timer after optimization completes.
                        # imagesnap opens/closes the camera during optimization,
                        # generating buffered "adding stream" events that would
                        # re-trigger us without this.
                        last_trigger = time.time()
                        _log("AI optimization complete.")
                except (Exception, SystemExit) as e:
                    _log(f"Error during camera optimization: {e}")

        except KeyboardInterrupt:
            running = False
        finally:
            proc.terminate()
            proc.wait()

        # Backoff if log stream exited unexpectedly (not from shutdown)
        if running:
            consecutive_failures += 1
            backoff = min(5 * consecutive_failures, 60)
            _log(f"Log stream exited, restarting in {backoff}s...")
            time.sleep(backoff)

    _log("Daemon stopped.")


def main():
    parser = argparse.ArgumentParser(
        prog="ojo",
        description="Pre-call scene controller and verified webcam optimizer.",
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    parser.add_argument(
        "--camera", metavar="NAME",
        help="Camera name to use (default: auto-detect first UVC camera)",
    )
    parser.add_argument(
        "--profile", metavar="PATH", default=DEFAULT_PROFILE_PATH,
        help=f"Profile save/restore path (default: {DEFAULT_PROFILE_PATH})",
    )
    parser.add_argument(
        "--model", default="opus",
        help="Claude model for analysis: opus (default, best judgment), sonnet (cheaper/faster), haiku (fastest)",
    )

    sub = parser.add_subparsers(dest="command")

    # Default (optimize) flags on the main parser
    parser.add_argument(
        "--source", choices=["screen", "camera", "auto"], default="camera",
        help="Capture source: screen (video call window), camera (raw imagesnap), "
        "auto (screen first, camera fallback). Default: camera",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show recommendations without applying changes",
    )
    parser.add_argument(
        "--rounds", type=int, default=1,
        help="Number of capture-analyze-adjust rounds (default: 1)",
    )
    parser.add_argument(
        "--save", action="store_true",
        help="Save final settings as profile after optimizing",
    )
    parser.add_argument(
        "--verify", action="store_true",
        help="Verify the optimized image and revert if it is worse",
    )

    # Check subcommand
    check_parser = sub.add_parser("check", help="Run a local pre-call scene check")
    check_parser.add_argument(
        "--json", action="store_true",
        help="Print machine-readable Green/Yellow/Red result",
    )
    check_parser.add_argument(
        "--log", action="store_true",
        help="Append a pre_call_check event to events.jsonl",
    )
    check_parser.add_argument(
        "--max-age-seconds", type=int, default=0,
        help="Return a recent cached check if one exists within this age",
    )
    check_parser.add_argument(
        "--warmup-seconds", type=int, default=1,
        help="Camera warmup for raw capture during checks (default: 1)",
    )
    check_parser.add_argument(
        "--skip-lights", action="store_true",
        help="Skip light reachability probes for a faster camera-only check",
    )
    check_parser.add_argument(
        "--light-timeout", type=float, default=1.0,
        help="Per-light status timeout in seconds (default: 1.0)",
    )

    # Restore subcommand
    sub.add_parser("restore", help="Restore camera settings from saved profile")

    # Feedback subcommand
    feedback_parser = sub.add_parser("feedback", help="Record manual Ojo feedback")
    feedback_sub = feedback_parser.add_subparsers(dest="feedback_kind", required=True)
    for kind, help_text in [
        ("bad", "Record that the user marked the scene bad"),
        ("comment", "Record an external video-quality compliment"),
    ]:
        kind_parser = feedback_sub.add_parser(kind, help=help_text)
        kind_parser.add_argument("--note", required=True, help="Short feedback note")
        kind_parser.add_argument(
            "--call-session-id",
            help="Optional call session identifier to associate with this feedback",
        )
        kind_parser.add_argument(
            "--dry-run", action="store_true",
            help="Print the JSONL row without writing it",
        )

    profiles_parser = sub.add_parser("profiles", help="Inspect profile-map status")
    profiles_parser.add_argument(
        "--json", action="store_true",
        help="Print machine-readable profile-map status",
    )
    profiles_parser.add_argument(
        "--profile-map", default=PROFILE_MAP_PATH,
        help=f"Profile-map path (default: {PROFILE_MAP_PATH})",
    )

    calibrate_parser = sub.add_parser(
        "calibrate",
        help="Run a safe local pre-check; AI Tune only runs with --force-ai or severe local failure",
    )
    calibrate_parser.add_argument(
        "--json", action="store_true",
        help="Print machine-readable calibration result",
    )
    calibrate_parser.add_argument(
        "--dry-run", action="store_true",
        help="Run the pre-check and print what calibration would do",
    )
    calibrate_parser.add_argument(
        "--force-ai", action="store_true",
        help="Run verified AI Tune even when the local check says it is not needed",
    )
    calibrate_parser.add_argument(
        "--profile-map", default=PROFILE_MAP_PATH,
        help=f"Profile-map path (default: {PROFILE_MAP_PATH})",
    )

    # Daemon subcommand
    daemon_parser = sub.add_parser("daemon", help="Auto-optimize on camera activation")
    daemon_sub = daemon_parser.add_subparsers(dest="daemon_command")

    install_parser = daemon_sub.add_parser("install", help="Install LaunchAgent")
    install_parser.add_argument(
        "--optimize", action="store_true",
        help="Also run AI optimization after restoring profile",
    )
    install_parser.add_argument(
        "--profile", metavar="PATH", default=DEFAULT_PROFILE_PATH,
        help=f"Profile path for restore (default: {DEFAULT_PROFILE_PATH})",
    )

    daemon_sub.add_parser("uninstall", help="Remove LaunchAgent")
    daemon_sub.add_parser("status", help="Show daemon status")

    run_parser = daemon_sub.add_parser("run", help="Run the watcher (called by LaunchAgent)")
    run_parser.add_argument(
        "--optimize", action="store_true",
        help="Run AI optimization after restoring profile",
    )
    run_parser.add_argument(
        "--profile", metavar="PATH", default=DEFAULT_PROFILE_PATH,
        help=f"Profile path for restore (default: {DEFAULT_PROFILE_PATH})",
    )

    args = parser.parse_args()

    if args.command == "feedback":
        cmd_feedback(args)
        return

    if args.command == "profiles":
        cmd_profiles(args)
        return

    # Daemon subcommands don't need camera detection or dep checks up front
    if args.command == "daemon":
        if args.daemon_command == "install":
            daemon_install(args)
        elif args.daemon_command == "uninstall":
            daemon_uninstall(args)
        elif args.daemon_command == "status":
            daemon_status(args)
        elif args.daemon_command == "run":
            daemon_run(args)
        else:
            daemon_parser.print_help()
        return

    check_dependencies(require_claude=args.command not in ("check", "calibrate"))

    camera_name, vendor, product = detect_camera(preferred=args.camera)

    if args.command == "check":
        cmd_check(args, camera_name)
    elif vendor is None or product is None:
        print(
            f"Camera '{camera_name}' supports capture but not UVC tuning. "
            "Use `ojo check`; AI Tune/restore require a UVC camera.",
            file=sys.stderr,
        )
        sys.exit(1)
    elif args.command == "calibrate":
        cmd_calibrate(args, camera_name, vendor, product)
    elif args.command == "restore":
        print(f"Camera: {camera_name}")
        restore_profile(vendor, product, args.profile)
    else:
        print(f"Camera: {camera_name}")
        ranges = get_ranges(vendor, product)
        cmd_optimize(args, camera_name, vendor, product, ranges)

    if not getattr(args, "json", False) and args.command != "check":
        print("\nDone.")


if __name__ == "__main__":
    main()
