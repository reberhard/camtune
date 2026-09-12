import Foundation
import AppKit

struct CallActivity: Sendable {
    let state: String
    let app: String?
    let reason: String
}

enum CallActivityService {
    /// Read-only, bounded accessibility evidence. Running applications and
    /// old Meet tabs alone never open or close a call session.
    @MainActor static func observe(previousApp: String? = nil) async -> CallActivity {
        let allowed = ["zoom.us", "Microsoft Teams", "Google Chrome", "Safari", "Arc", "FaceTime", "Webex"]
        if let previousApp, allowed.contains(previousApp), !NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == previousApp }) {
            return CallActivity(state:"ended",app:previousApp,reason:"Previously observed call application exited")
        }
        let previous = previousApp.flatMap { allowed.contains($0) ? $0 : nil } ?? ""
        let script = """
        set endedApp to ""
        tell application "System Events"
          repeat with p in (application processes whose background only is false)
            set n to name of p
            if n is in {"zoom.us", "Microsoft Teams", "Google Chrome", "Safari", "Arc", "FaceTime", "Webex"} then
              try
                repeat with w in windows of p
                  set hasLeave to false
                  set hasMedia to false
                  repeat with e in entire contents of w
                    if role of e is "AXButton" then
                      set d to description of e as text
                      if d is in {"Leave call", "Leave meeting", "End meeting", "Leave", "Hang Up"} then set hasLeave to true
                      if d contains "Mute" or d contains "microphone" or d contains "camera" or d contains "Stop Video" then set hasMedia to true
                    else if role of e is "AXStaticText" and n is "\(previous)" then
                      set v to value of e as text
                      if v is in {"You left the meeting", "You've left the meeting", "The meeting has ended", "You left the call"} then set endedApp to n
                    end if
                  end repeat
                  if hasLeave and hasMedia then return n & "|active"
                end repeat
              end try
            end if
          end repeat
        end tell
        if endedApp is not "" then return endedApp & "|ended"
        return "unknown"
        """
        do {
            let output = try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeout: .seconds(4))
            let parts = output.split(separator: "|")
            if parts.count == 2, allowed.contains(String(parts[0])), ["active","ended"].contains(String(parts[1])) {
                return CallActivity(state: String(parts[1]), app: String(parts[0]), reason: parts[1] == "active" ? "Live leave-call and media controls observed" : "Explicit call-ended message observed")
            }
            return CallActivity(state: "unknown", app: nil, reason: "No verified call activity; an app or tab may still be open")
        } catch {
            return CallActivity(state: "unknown", app: nil, reason: "Call accessibility evidence unavailable")
        }
    }
}
