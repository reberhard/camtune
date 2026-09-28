# Ojo diagnostics

The native app writes local JSON lines to `~/.config/camtune/diagnostics/errors.jsonl`.
One previous file is retained; rotation occurs at 2 MB. Files are mode 0600 in a
0700 directory. Rows identify timestamp, process, session, app version and source
commit embedded during bundling.

`DiagnosticText` mirrors view text on appearance and changes. This includes
errors, warnings and readiness messages, not only red error labels. Repeated
unchanged text at the same source location is suppressed. General app errors
are also recorded on assignment, including when the view is closed. Room and
camera failures record device/control, action and operation where available.
AppState catches record the function, NSError domain/code and description.
ShellRunner records launch/read/exit/timeout failures with a unique operation,
executable and command/subcommand. JSON payloads, stdin, images, prompts and
arbitrary argument lists are not recorded. Common secret assignments are redacted
and individual values are capped at 8,000 characters.

If journal writes fail, the error and sanitized message are emitted to macOS
unified logging under subsystem `com.ojo.app`, category `diagnostics`. A filesystem
failure can prevent durable capture; do not promise that disk-full errors cannot
lose records. These records capture app-reported symptoms, not proof of root cause.

Scope: gg-mini native Ojo; no changes to device controllers or worker adapters.
Laptop SSH was unreachable during this change; no laptop install is performed.
Netcup returned Linux and no Ojo/camtune service in its systemd inventory.
Shared source publication does not establish installation on other hosts.

Validate the installed build by triggering a harmless precondition failure,
reading its exact visible message in the journal and matching its build identity.
Also verify room/camera and subprocess failure tests and rotation/redaction tests.
Rollback: preserve the currently installed signed app before replacement; quit
the new process and restore that bundle if needed. Keep diagnostics and user data.
Regression guard: `Tests/DiagnosticsTests.swift` plus all-view text coverage audit.
