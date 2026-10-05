# Ojo popover design rules

The popover is a product, not a settings panel. Keep it that way.

- **One typeface, one scale.** SF Pro only. Every font comes from `Ojo.Style` in
  `Sources/Views/Theme.swift` (title 22, row title 15, caption 13, note 12, tile 13...).
  Do not use system text styles (`.caption`, `.subheadline`, `.headline`...): on macOS they are
  10-13 pt and look tiny next to full-size controls. `DesignTests.mainScreensUseTheOjoTypeScale`
  fails the build if they come back in the main screens.
- **Words.** Plain language ("You look good", "Almost there"). Engineering strings belong in
  `operations.jsonl` and `events.jsonl`; all visible text still goes through `DiagnosticText`
  so the journal records exactly what was shown (`DiagnosticsTests`).
- **Structure.** Status hero (one primary action) -> live camera preview (always on while the
  popover is open) -> Room (scene tiles, lamp cards that expand, one curtain control) -> footer
  (camera name, refresh, More menu). Diagnostics, repair and feedback live under More.
- **Surfaces.** Use `OjoCard`, `OjoPrimaryButtonStyle`, `OjoSecondaryButtonStyle` and `GradientSlider`;
  spacing comes from `Ojo.Space`, radii from `Ojo.Radius`.
- **Fit.** The popover must not scroll in its default state on a normal desktop display
  (height 930 pt, capped to the screen). Check changes with a window-scoped capture
  (`screencapture -l <window id>`), never a full-screen one.
- **Start the preview only after the camera is known** (`currentDevice != nil`); starting earlier
  raises a spurious "could not be matched" error.

## Background behavior (Ryan, 2026-10-05)

- **Keep camera ready** (footer ••• menu, on by default): every 30 minutes, Monday to Friday,
  8 AM to 6 PM in the Mac's time zone, Ojo runs a read-only check and, only if the scene is not
  green, the camera-only preparation. It never changes lights or curtains on a timer, skips when no
  face is in frame, and runs even when another app is using the camera. Two corrections in a row
  pause it and say so (`CorrectionLoopGuard`; on 2026-09-10 an automatic framing loop drove the
  tilt to a bad angle). Logic and limits: `Services/ScheduledPrepareService.swift`, tests in
  `ScheduledPrepareTests`. A hidden default `scheduledPrepareIntervalSeconds` (minimum 30) exists
  only to verify the schedule; delete it afterwards (`defaults delete com.ojo.app ...`).
- **Open at login** (same menu, on by default): the system's own login item
  (`SMAppService.mainApp`), visible in System Settings > General > Login Items. It replaced a
  hand-made LaunchAgent (`~/Library/LaunchAgents/com.ojo.app.plist`) that the menu switch could not
  control; two mechanisms would make the switch lie.
- Startup discovery runs at launch, not at first popover open, because the schedule must work for days
  without anyone opening the popover.
