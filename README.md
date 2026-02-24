# camtune

AI-powered webcam optimizer for macOS. Captures a frame from your webcam, sends it to Claude for visual analysis, and applies recommended UVC settings. Iterates until the image is right.

No sliders, no GUI — just run a command and let the AI fix your webcam.

## How it works

1. **Capture** a frame from your webcam via `imagesnap`
2. **Analyze** the image with Claude's vision (white balance, brightness, contrast, saturation, gain, sharpness)
3. **Apply** recommended UVC settings via `uvcc`
4. **Repeat** if needed — run multiple rounds to dial it in

```
$ python3 camtune.py

Camera: Brio 505
Reading current settings...
Capturing frame...
Analyzing with Claude (sonnet)...

Assessment: Image has a warm yellow cast from mixed lighting. Brightness is
too low and contrast is making shadows harsh.

Applying changes:
  auto_white_balance_temperature: 0
  white_balance_temperature: 4200
  brightness: 120
  contrast: 100
  gain: 40

Done.
```

## Requirements

- **macOS** (imagesnap is macOS-only)
- **Python 3.8+** (no pip dependencies — stdlib only)
- [imagesnap](https://github.com/rharber/imagesnap) — `brew install imagesnap`
- [uvcc](https://github.com/niclasku/uvcc) — `npm install -g uvcc`
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

```bash
git clone https://github.com/reberhard/camtune.git
cd camtune
python3 camtune.py --version
```

That's it. Single file, no setup.

## Usage

```bash
# Optimize with auto-detected camera
python3 camtune.py

# Preview recommendations without applying
python3 camtune.py --dry-run

# Multiple rounds of refinement
python3 camtune.py --rounds 3

# Optimize and save the result as a profile
python3 camtune.py --save

# Restore a saved profile (no AI needed)
python3 camtune.py restore

# Target a specific camera
python3 camtune.py --camera "Brio 505"

# Use a different Claude model
python3 camtune.py --model opus
```

### Profiles

Profiles save your optimized settings to `~/.config/camtune/profile.json`. Use `--save` after optimizing, then `restore` to reapply anytime — useful after reboots or camera reconnects.

```bash
# Save after optimizing
python3 camtune.py --save

# Restore later
python3 camtune.py restore

# Custom profile path
python3 camtune.py --save --profile ~/my-webcam.json
python3 camtune.py restore --profile ~/my-webcam.json
```

## Linux / Windows

camtune is macOS-only because it depends on `imagesnap`. If you're on Linux, you could swap in `ffmpeg` for frame capture — the rest of the pipeline (uvcc + claude) works cross-platform. PRs welcome.

## Background

Built this after realizing that dragging webcam sliders is exactly the kind of task an AI with vision should handle. The full story: [My AI Controls My Webcam](https://www.gaugesgreen.com/log/ai-controls-my-webcam).

## License

MIT
