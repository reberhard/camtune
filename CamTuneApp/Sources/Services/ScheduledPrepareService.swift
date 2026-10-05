import Foundation
import ServiceManagement

/// When "Keep camera ready" runs. Pure so it can be tested without a camera or a clock.
struct ScheduledPreparePolicy: Sendable {
    /// Seconds between runs. The hidden `scheduledPrepareIntervalSeconds` default exists
    /// only to verify the schedule without waiting half an hour; it cannot go below 30.
    var intervalSeconds: TimeInterval = 30 * 60
    /// The first run after launch, so a login at 8:05 does not wait until 8:35.
    var initialDelaySeconds: TimeInterval = 90
    /// Monday to Friday, startHour <= hour < endHour, in the Mac's current time zone.
    var startHour = 8
    var endHour = 18

    func isWorkTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday ... 7 = Saturday
        guard (2...6).contains(weekday) else { return false }
        return (startHour..<endHour).contains(calendar.component(.hour, from: date))
    }

    static func current(defaults: UserDefaults = .standard) -> ScheduledPreparePolicy {
        var policy = ScheduledPreparePolicy()
        let override = defaults.double(forKey: "scheduledPrepareIntervalSeconds")
        if override >= 30 {
            policy.intervalSeconds = override
            policy.initialDelaySeconds = min(override, 90)
        }
        return policy
    }
}

enum ScheduledOutcome: Equatable, Sendable {
    case ok                      // looked fine, or the correction made no change
    case corrected               // the camera was adjusted
    case skipped(String)         // nothing to do right now (no face, busy, outside hours)
    case failed(String)
}

/// Two corrections in a row means something keeps changing the camera (or the correction
/// does not hold). Stop and say so instead of fighting it all day: on 2026-09-10 an
/// automatic framing loop drove the camera tilt to a bad angle.
struct CorrectionLoopGuard: Sendable {
    static let limit = 2
    private(set) var consecutiveCorrections = 0

    /// Returns true when the schedule should pause.
    mutating func record(_ outcome: ScheduledOutcome) -> Bool {
        switch outcome {
        case .corrected:
            consecutiveCorrections += 1
        case .ok:
            consecutiveCorrections = 0
        case .skipped, .failed:
            break   // neutral: neither proves it holds nor that it is fighting
        }
        return consecutiveCorrections >= Self.limit
    }

    mutating func reset() { consecutiveCorrections = 0 }
}

/// Preferences, with the defaults Ryan asked for (2026-10-05): both on.
enum OjoPreferences {
    static let keepCameraReadyKey = "keepCameraReady"
    static let openAtLoginKey = "openAtLogin"

    static func keepCameraReady(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepCameraReadyKey) as? Bool ?? true
    }

    static func openAtLogin(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: openAtLoginKey) as? Bool ?? true
    }
}

/// Launch Ojo at login through the system's own login-item mechanism (visible and
/// removable in System Settings > General > Login Items).
enum LoginItemService {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Words for the menu when the system is waiting on the user.
    static var statusNote: String? {
        status == .requiresApproval ? "Allow Ojo in System Settings → General → Login Items" : nil
    }
}
