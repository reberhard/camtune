# Ojo

Pre-call scene controller for macOS. Ojo checks your camera, face exposure, white balance, profile freshness, and controllable light reachability before a video call, then reports Green / Yellow / Red.

AI Tune remains available as an explicit repair action. It captures a raw camera frame, asks Claude for adjustments, applies UVC/light changes, then verifies and reverts if the result is worse.

## How it works

1. **Check** a raw camera frame locally via `imagesnap`
2. **Detect** the face via macOS Vision
3. **Measure** face luma, clipping, RGB balance, profile age, and light reachability
4. **Report** Green / Yellow / Red without changing camera or lights
5. **Tune** only when explicitly requested

```
$ python3 ojo.py check --json
{"state": "yellow", "reason": "profile stale (540m old)", "checks": {...}, "scene": {...}}
```

## Requirements

- **macOS** (imagesnap is macOS-only)
- **Python 3.8+**
- [imagesnap](https://github.com/rharber/imagesnap) — `brew install imagesnap`
- [uvcc](https://github.com/niclasku/uvcc) — `npm install -g uvcc`
- Python packages used by current paths: `anthropic`, `Pillow`, `pyobjc-framework-Vision`, `pyobjc-framework-Quartz`

## Install

```bash
git clone https://github.com/reberhard/camtune.git
cd camtune
python3 ojo.py --version
```

That's it. Single file, no setup.

## Usage

```bash
# Local pre-call check; applies no changes
python3 ojo.py check --json

# Local pre-call check and append a pre_call_check event
python3 ojo.py check --json --log

# Preview recommendations without applying
python3 ojo.py --dry-run

# Multiple rounds of refinement
python3 ojo.py --rounds 3

# Explicit AI Tune path: raw camera, verify, save
python3 ojo.py --source camera --verify --save

# Restore a saved profile (no AI needed)
python3 ojo.py restore

# Record feedback
python3 ojo.py feedback bad --note "too bright"
python3 ojo.py feedback comment --note "client complimented the video"

# Target a specific camera
python3 ojo.py --camera "Brio 505" check --json

# Use a different Claude model
python3 ojo.py --model sonnet --source camera --verify --save
```

### Profiles

Profiles save your optimized settings to `~/.config/camtune/profile.json`. Use `--save` after optimizing, then `restore` to reapply anytime — useful after reboots or camera reconnects.

```bash
# Save after optimizing
python3 ojo.py --source camera --verify --save

# Restore later
python3 ojo.py restore

# Custom profile path
python3 ojo.py --source camera --verify --save --profile ~/my-webcam.json
python3 ojo.py --profile ~/my-webcam.json restore
```

### Daemon (auto-optimize on camera start)

The daemon watches for camera activation (e.g., joining a Zoom call) and automatically restores your saved profile. It uses macOS `log stream` to detect camera events in real time.

```bash
# First, save a profile you're happy with
python3 ojo.py --source camera --verify --save

# Install the daemon (restore-only — instant, no AI)
python3 ojo.py daemon install

# Or install with AI optimization after restore (~30s per trigger)
python3 ojo.py daemon install --optimize

# Check status
python3 ojo.py daemon status

# Uninstall
python3 ojo.py daemon uninstall
```

The daemon installs a LaunchAgent that starts on login and watches for camera activation. When triggered, it:

1. **Instantly restores** your saved profile (< 1 second)
2. **Optionally runs AI optimization** if installed with `--optimize`

Events are debounced (60s window) so multiple log events from a single camera start don't cause repeated adjustments. Logs are written to `~/.config/camtune/daemon.log`.

## Verification (Smoke Tests)

After installing or modifying the daemon, run these to confirm it works:

```bash
# 1. Confirm daemon is running
python3 ojo.py daemon status
# Expected: "Running (PID <number>)"

# 2. Trigger camera activation (opens Photo Booth, activates camera)
open -a "Photo Booth"

# 3. Check daemon log for successful restore (within 10 seconds)
tail -5 ~/.config/camtune/daemon.log
# Expected: "Camera activation detected" → "Profile restored"

# 4. Close the test app
osascript -e 'quit app "Photo Booth"'
```

**Failure test** (daemon should survive, not crash):
```bash
# Temporarily rename the profile to simulate missing file
mv ~/.config/camtune/profile.json ~/.config/camtune/profile.json.bak
open -a "Photo Booth"
sleep 5
tail -3 ~/.config/camtune/daemon.log
# Expected: "No profile at ..." (logged, daemon continues running)
mv ~/.config/camtune/profile.json.bak ~/.config/camtune/profile.json
osascript -e 'quit app "Photo Booth"'
```

## Linux / Windows

Ojo is macOS-only because it depends on `imagesnap`, macOS Vision, and UVC tooling commonly used with local UVC camera setups.

## Background

Built this after realizing that dragging webcam sliders is exactly the kind of task an AI with vision should handle. The full story: [My AI Controls My Webcam](https://www.gaugesgreen.com/log/ai-controls-my-webcam).

## License

MIT
