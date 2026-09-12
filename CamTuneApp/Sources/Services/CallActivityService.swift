import Foundation

struct CallActivity: Sendable {
    let state: String
    let app: String?
    let reason: String
}

enum CallActivityService {
    /// Read-only, bounded accessibility evidence. Running applications and
    /// old Meet tabs alone never open or close a call session.
    static func observe() async -> CallActivity {
        let script = """
        tell application "System Events"
          repeat with p in (application processes whose background only is false)
            set n to name of p
            if n is in {"zoom.us", "Microsoft Teams", "Google Chrome", "Safari", "Arc", "FaceTime", "Webex"} then
              try
                repeat with w in windows of p
                  repeat with e in entire contents of w
                    if role of e is "AXButton" then
                      set d to description of e as text
                      if d is in {"Leave call", "Leave meeting", "End meeting", "Leave", "Hang Up"} then return n & "|active"
                    end if
                  end repeat
                end repeat
              end try
            end if
          end repeat
        end tell
        return "unknown"
        """
        do {
            let output = try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeout: .seconds(4))
            let parts = output.split(separator: "|")
            if parts.count == 2, parts[1] == "active" {
                return CallActivity(state: "active", app: String(parts[0]), reason: "Live leave-call control observed")
            }
            return CallActivity(state: "unknown", app: nil, reason: "No verified call activity; an app or tab may still be open")
        } catch {
            return CallActivity(state: "unknown", app: nil, reason: "Call accessibility evidence unavailable")
        }
    }
}
