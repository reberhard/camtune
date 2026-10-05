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
