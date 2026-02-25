#!/usr/bin/env python3
"""
camtune — AI-powered webcam optimizer for macOS.

Captures a frame from your webcam, sends it to Claude for visual analysis,
and applies recommended UVC settings. Iterates until the image looks right.

Usage:
    python3 camtune.py                  # Optimize with auto-detected camera
    python3 camtune.py --dry-run        # Show recommendations without applying
    python3 camtune.py --save           # Optimize and save profile
    python3 camtune.py restore          # Restore saved profile
    python3 camtune.py --camera "Brio"  # Target a specific camera

Requires: imagesnap (brew), uvcc (npm), claude CLI (npm)
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time

__version__ = "1.1.1"

CAPTURE_PATH = "/tmp/camtune-capture.jpg"
DEFAULT_PROFILE_DIR = os.path.expanduser("~/.config/camtune")
DEFAULT_PROFILE_PATH = os.path.join(DEFAULT_PROFILE_DIR, "profile.json")
WARMUP_SECS = 2
DEBOUNCE_SECS = 60
MAX_LOG_BYTES = 1_000_000  # 1MB

LAUNCHAGENT_LABEL = "com.camtune.daemon"
LAUNCHAGENT_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LAUNCHAGENT_LABEL}.plist")
DAEMON_LOG_PATH = os.path.join(DEFAULT_PROFILE_DIR, "daemon.log")

# Fallback ranges for common UVC controls. Used when `uvcc ranges` fails
# (which happens on some cameras due to LIBUSB errors).
FALLBACK_RANGES = {
    "white_balance_temperature": (2800, 7500),
    "brightness": (0, 255),
    "contrast": (0, 255),
    "gain": (0, 255),
    "saturation": (0, 255),
    "sharpness": (0, 255),
}

ANALYSIS_PROMPT = """\
You are a webcam calibration assistant. Analyze this webcam image and recommend
UVC camera setting adjustments to optimize image quality for video calls.

Current camera settings:
{current_settings}

Valid ranges for each control:
{ranges}

Evaluate:
1. White balance — is there a color cast (yellow/warm, blue/cool, green, magenta)?
2. Brightness — is the face well-lit or too dark/bright?
3. Contrast — are shadows too deep or image too flat?
4. Saturation — are colors oversaturated or washed out?
5. Gain — is there visible noise from high gain?
6. Sharpness — is the image soft or oversharpened?

Also consider whether auto_white_balance should be on (1) or off (0).
If auto WB is on, you can still recommend other setting changes.
If the image looks good, say so — don't change settings unnecessarily.

Respond with ONLY a JSON object (no markdown fences, no explanation) like:
{{
    "assessment": "Brief 1-2 sentence assessment of current image quality",
    "changes": {{
        "brightness": 100,
        "contrast": 115
    }},
    "auto_white_balance_temperature": 1
}}

The "changes" object should ONLY include settings that need adjustment.
If the image looks good, use an empty changes object: {{}}.
Values must be integers within the valid ranges listed above.
"""


def check_dependencies():
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

    if not shutil.which("claude"):
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


def detect_camera(preferred=None):
    """Auto-detect a UVC camera. Returns (name, vendor, product) or exits."""
    try:
        output = uvcc("devices")
        devices = json.loads(output) if output else []
    except (json.JSONDecodeError, subprocess.TimeoutExpired):
        devices = []

    if not devices:
        print("No UVC cameras detected. Is your webcam connected?", file=sys.stderr)
        sys.exit(1)

    if preferred:
        for d in devices:
            if preferred.lower() in d["name"].lower():
                return d["name"], d["vendor"], d["product"]
        print(f"Camera matching '{preferred}' not found.", file=sys.stderr)
        print("Available cameras:", file=sys.stderr)
        for d in devices:
            print(f"  - {d['name']}", file=sys.stderr)
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


def capture_frame(camera_name, path=CAPTURE_PATH):
    """Capture a frame from the webcam."""
    result = subprocess.run(
        ["imagesnap", "-d", camera_name, "-w", str(WARMUP_SECS), path],
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


def call_claude_vision(image_path, prompt, model="sonnet"):
    """Send image to Claude for visual analysis."""
    with open(image_path, "rb") as f:
        image_data = base64.b64encode(f.read()).decode("utf-8")

    message = {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": image_data,
                    },
                },
                {"type": "text", "text": prompt},
            ],
        },
    }

    cmd = [
        "claude", "--print", "--verbose",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--model", model,
        "--no-session-persistence",
    ]

    # Strip CLAUDECODE env var to avoid nesting issues
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

    proc = subprocess.run(
        cmd,
        input=json.dumps(message) + "\n",
        capture_output=True, text=True,
        timeout=120,
        env=env,
    )

    if proc.returncode != 0:
        print(f"Claude vision failed: {proc.stderr[:500]}", file=sys.stderr)
        return None

    for line in proc.stdout.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
            if msg.get("type") == "result":
                return msg.get("result", "")
        except json.JSONDecodeError:
            continue

    print("No result found in Claude output.", file=sys.stderr)
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

    applied = []
    tag = " (dry run)" if dry_run else ""

    if awb is not None:
        val = 1 if awb else 0
        if not dry_run:
            set_uvc("auto_white_balance_temperature", val, vendor, product)
        applied.append(f"  auto_white_balance_temperature: {val}{tag}")
        if val == 1:
            changes.pop("white_balance_temperature", None)

    for control, value in changes.items():
        value = clamp(value, control, ranges)
        if not dry_run:
            set_uvc(control, value, vendor, product)
        applied.append(f"  {control}: {value}{tag}")

    return applied


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
    for round_num in range(1, args.rounds + 1):
        if args.rounds > 1:
            print(f"\n--- Round {round_num}/{args.rounds} ---")

        print("Reading current settings...")
        current = get_current_settings(vendor, product)

        print("Capturing frame...")
        if not capture_frame(camera_name):
            sys.exit(1)

        print(f"Analyzing with Claude ({args.model})...")
        ranges_str = "\n".join(
            f"- {k}: {lo}-{hi}" for k, (lo, hi) in sorted(ranges.items())
        )
        prompt = ANALYSIS_PROMPT.format(
            current_settings=json.dumps(current, indent=2),
            ranges=ranges_str,
        )
        response = call_claude_vision(CAPTURE_PATH, prompt, model=args.model)
        if not response:
            sys.exit(1)

        recs = parse_recommendations(response)
        if not recs:
            sys.exit(1)

        assessment = recs.get("assessment", "No assessment provided")
        print(f"\nAssessment: {assessment}")

        changes = recs.get("changes", {})
        awb = recs.get("auto_white_balance_temperature")
        if not changes and awb is None:
            print("No changes needed — image looks good.")
            break

        print("\nApplying changes:" if not args.dry_run else "\nRecommended changes:")
        applied = apply_changes(recs, ranges, vendor, product, dry_run=args.dry_run)
        for line in applied:
            print(line)

        if not args.dry_run and round_num < args.rounds:
            print("Waiting for settings to settle...")
            time.sleep(2)

    if args.save and not args.dry_run:
        print("\nSaving profile...")
        save_profile(vendor, product, args.profile)
        print(f"Profile saved to {args.profile}")


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

    last_trigger = 0
    consecutive_failures = 0

    cmd = [
        "log", "stream", "--predicate",
        'subsystem == "com.apple.cmio" AND eventMessage CONTAINS "adding stream"',
    ]

    while running:
        _log("Watching for camera activation...")
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
                if "adding stream" not in line:
                    continue

                now = time.time()
                if now - last_trigger < DEBOUNCE_SECS:
                    continue
                last_trigger = now

                _log("Camera activation detected.")

                try:
                    camera_name, vendor, product = detect_camera()
                    _log(f"Camera: {camera_name}")

                    # Phase 1: Instant profile restore
                    if os.path.exists(args.profile):
                        _log("Restoring profile...")
                        restore_profile(vendor, product, args.profile)
                        _log("Profile restored.")
                    else:
                        _log(f"No profile at {args.profile}, skipping restore.")

                    # Phase 2: AI optimization (optional)
                    if args.optimize:
                        _log("Running AI optimization...")
                        ranges = get_ranges(vendor, product)
                        opt_args = argparse.Namespace(
                            rounds=1, dry_run=False, save=True,
                            profile=args.profile, model="sonnet",
                        )
                        cmd_optimize(opt_args, camera_name, vendor, product, ranges)
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
        prog="camtune",
        description="AI-powered webcam optimizer. Captures a frame, analyzes it with "
        "Claude's vision, and applies recommended UVC settings.",
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
        "--model", default="sonnet",
        help="Claude model for analysis (default: sonnet)",
    )

    sub = parser.add_subparsers(dest="command")

    # Default (optimize) flags on the main parser
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

    # Restore subcommand
    sub.add_parser("restore", help="Restore camera settings from saved profile")

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

    check_dependencies()

    camera_name, vendor, product = detect_camera(preferred=args.camera)
    print(f"Camera: {camera_name}")

    if args.command == "restore":
        restore_profile(vendor, product, args.profile)
    else:
        ranges = get_ranges(vendor, product)
        cmd_optimize(args, camera_name, vendor, product, ranges)

    print("\nDone.")


if __name__ == "__main__":
    main()
