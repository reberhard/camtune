# Ojo resource and check-log repair — September 28, 2026

## Failure and fix

The installed app reported Bad file descriptor for every light. Unified logs
also reported Too many open files while camera-effect assets were loading.
An isolated reproduction using the original ShellRunner grew from 3 to 163
open descriptors after 80 successful /usr/bin/true calls. The regression test
failed against the original runner (165 descriptors versus a ceiling of 7).

All five native Process creation sites now explicitly close their pipes.
The shared runner closes stdout, stderr and optional stdin on all exits,
terminates children on cancellation, and preserves controller exit code 2
and stderr failures. SIGTERM remains cooperative so the curtain controller
can send Stop; force-kill is not introduced.

Additional findings from the event ledger:

- Preview frames generated manual-check events every second. Only an explicit
  check now writes a check event, preserving its manual/auto origin; a failed
  event write becomes visible without discarding the assessment.
- Old confirmed room readings produced an unknown assessment whose UI text
  said Lights look fine. The reason now names stale readings. Explicit Check
  waits for fresh read-only room status, sharing any already-running refresh,
  then uses a fresh camera frame. Staleness limits are unchanged.

## Validation and limits

Swift regressions exercise descriptor stability, nonzero and launch failures,
stdin round-trip, partial controller receipts, timeout, cancellation, preview
event behavior, failed event writes and shared refresh completion. Python
regression covers the stale room reading reason. Existing camera/room tests
remain required. No package or dependency changes.

Post-install validation must check the installed process, read-only device
status, resource growth with the preview open and a manual Check receipt.
Apple camera-effect, layout and Control Center errors are assessed again after
resource recovery; their disappearance cannot be inferred from unit tests.
Missing profiles, room-effect calibration and call signatures are separate
unfinished setup; no readiness evidence is fabricated by this repair.

## Fleet and rollback

Mini: native app plus existing local Python support file. Preserve the prior
signed app bundle and the prior scene_contract.py before replacing either.
Record declared source commit, installed binary hash and new PID.

Laptop: SSH unavailable during investigation. Shared source may be retrieved
there later, but no installation or runtime parity is claimed. Netcup: Linux,
no Ojo/camtune systemd units; no server change. Native/worker send adapters and
credentials are unchanged. No lighting, curtain or camera setting is changed
by read-only validation.

Rollback restores the saved app and prior support file, then restarts the app.
Do not roll back user data, profiles, calibration, controller journals or
unrelated shared source. Source changes go through ordinary Git commits/PRs.
