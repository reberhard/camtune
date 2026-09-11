import AppKit
import AVFoundation
import Foundation
import Observation

private let ojoStateURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/camtune")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("state.json")
}()

private let faceWhiteLumaWarn = 126.0
private let faceWhiteSeparationWarn = 55.0
private let faceCrownHeightMultiplier = 0.55

enum OjoTab: String, CaseIterable {
    case status = "Status"
    case camera = "Camera"
    case lights = "Lights"
    case tv = "TV"

    static let visibleCases: [OjoTab] = [.status, .camera, .lights]

    var icon: String {
        switch self {
        case .status: return "sparkles"
        case .camera: return "camera"
        case .lights: return "lightbulb"
        case .tv: return "tv"
        }
    }
}

struct SceneMetrics: Sendable {
    let faceBox: CGRect?
    let faceCenterX: Double?
    let faceCenterY: Double?
    let headroomPct: Double?
    let faceHeightPct: Double?
    let faceLumaMean: Double?
    let backgroundLumaMean: Double?
    let backgroundSeparation: Double?
    let exposureHint: String?

    init(payload: [String: Any]) {
        if let values = payload["face_bbox"] as? [Double], values.count == 4 {
            faceBox = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else if let values = payload["face_bbox"] as? [NSNumber], values.count == 4 {
            faceBox = CGRect(
                x: values[0].doubleValue,
                y: values[1].doubleValue,
                width: values[2].doubleValue,
                height: values[3].doubleValue
            )
        } else {
            faceBox = nil
        }
        faceCenterX = (payload["face_center_x"] as? NSNumber)?.doubleValue
        // ojo.py receives Vision's lower-left coordinates; the Swift preview
        // uses upper-left coordinates. Keep one visual convention in the UI.
        if let centerY = (payload["face_center_y"] as? NSNumber)?.doubleValue {
            faceCenterY = 1 - centerY
        } else {
            faceCenterY = nil
        }
        headroomPct = (payload["headroom_pct"] as? NSNumber)?.doubleValue
        faceHeightPct = (payload["face_height_pct"] as? NSNumber)?.doubleValue
        faceLumaMean = (payload["face_luma_mean"] as? NSNumber)?.doubleValue
        backgroundLumaMean = (payload["background_luma_mean"] as? NSNumber)?.doubleValue
        backgroundSeparation = (payload["background_separation"] as? NSNumber)?.doubleValue
        exposureHint = nil
    }

    init(
        faceBox: CGRect,
        faceLumaMean: Double? = nil,
        backgroundLumaMean: Double? = nil
    ) {
        self.faceBox = faceBox
        faceCenterX = faceBox.midX
        faceCenterY = faceBox.midY
        // Vision's face rectangle starts below the crown. Use an estimated
        // crown for composition so Ojo does not call empty facial space
        // "headroom" and show a misleadingly low-in-frame face as balanced.
        headroomPct = max(0, faceBox.minY - faceBox.height * faceCrownHeightMultiplier)
        faceHeightPct = faceBox.height
        self.faceLumaMean = faceLumaMean
        self.backgroundLumaMean = backgroundLumaMean
        if let faceLumaMean, let backgroundLumaMean {
            backgroundSeparation = faceLumaMean - backgroundLumaMean
        } else {
            backgroundSeparation = nil
        }
        if let faceLumaMean, faceLumaMean < 85 {
            exposureHint = "Face looks dark"
        } else if let faceLumaMean,
                  faceLumaMean >= faceWhiteLumaWarn,
                  let backgroundSeparation,
                  backgroundSeparation > faceWhiteSeparationWarn {
            exposureHint = "Face looks too white"
        } else if let faceLumaMean, faceLumaMean > 165 {
            exposureHint = "Face looks bright"
        } else if let separation = backgroundSeparation, separation < 10 {
            exposureHint = "Background too close"
        } else {
            exposureHint = nil
        }
    }
}

@MainActor
@Observable
final class AppState {
    let room = RoomControlService()
    static let sceneRepairEnabled = false
    var currentDevice: CameraDevice?
    var currentSettings = UVCSettings()
    var ranges: [String: UVCRange] = [:]
    var savedProfileExists = ProfileService.exists()
    var isOptimizing = false
    var isCalibrating = false
    var optimizationRound = 0
    var totalRounds = 2
    var lastAssessment: String?
    var preCallState: String?
    var preCallReason: String?
    var preCallQualityLabel: String?
    var preCallQualityScore: Int?
    var preCallQualityIssue: String?
    var preCallQualityIssues: [String] = []
    var preCallQualityStrengths: [String] = []
    var lastScene: SceneMetrics?
    var preCallLastChecked: Date?
    var preCallBlockingIssue: String?
    var isChecking = false
    var autoCheckEnabled = true
    var detectedCallApp: String?
    var lastAutoCheckReason: String?
    var isDeepRepairing = false
    var isMeetingReadyRunning = false
    var notificationStatus = "Notifications unknown"
    var browserAutomationStatus = "Browser automation untested"
    var lightControlAvailable = false
    var daemonStatus: DaemonStatus = .unknown
    var error: String?
    var statusMessage: String?
    var lightingPlanSummary: String?
    var selectedTab: OjoTab = .status
    var compositionStep = 3600
    var lastComposition: [Int]?
    private var lastSceneUpdatedAt: Date?
    private var lastPreviewAssessmentAt = Date.distantPast

    // Lights state
    var lightFixtures: [LightFixture] = LightService.defaultFixtures

    // Curtains state
    var curtainControlAvailable = false
    var curtainStatusByTarget: [String: CurtainStatus] = [:]
    var isCurtainBusy = false

    // Call session tracking (Phase 2, 2026-09-04): bounded by
    // activeVideoCallAppName() transitions in runAutomaticCheckIfNeeded.
    // Written to calls.jsonl on session end via `ojo.py calls log`.
    private var activeCallSession: CallSession?

    // TV state
    var audioRoute: AudioRoute = .tv

    private(set) var captureSession: AVCaptureSession?
    private let cameraService = CameraCaptureService()

    // Debounce UVC slider changes
    private var pendingUVCTask: Task<Void, Never>?
    private var autoCheckTask: Task<Void, Never>?
    private var lastAutoCheck: Date?
    private var lastCallGuardNotification: Date?

    // MARK: - Lifecycle

    var panTiltText: String {
        let values = currentSettings.intArrayValue(for: "absolute_pan_tilt") ?? [0, 0]
        return "P \(values.first ?? 0) / T \(values.dropFirst().first ?? 0)"
    }

    var zoomText: String {
        let value = currentSettings.intValue(for: "absolute_zoom") ?? 0
        return value == 0 ? "Zoom -" : "Zoom \(value)"
    }

    var menuBarTitle: String {
        if !Self.sceneRepairEnabled { return "Ojo" }
        switch preCallState?.lowercased() {
        case "green": return "Ojo Green"
        case "yellow": return "Ojo Yellow"
        case "red": return "Ojo Red"
        default: return "Ojo"
        }
    }

    var menuBarSystemImage: String {
        if !Self.sceneRepairEnabled { return "eye" }
        switch preCallState?.lowercased() {
        case "green": return "checkmark.circle.fill"
        case "yellow": return "exclamationmark.triangle.fill"
        case "red": return "xmark.octagon.fill"
        default: return "eye"
        }
    }

    func startUp() async {
        room.start()
        NotificationService.requestAuthorization()
        await refreshPermissionStatus()
        lightControlAvailable = LightService.isAvailable()
        curtainControlAvailable = CurtainService.isAvailable()
        refreshDaemonStatus()
        savedProfileExists = ProfileService.exists()
        if Self.sceneRepairEnabled { startAutomaticChecks() }
        if curtainControlAvailable {
            Task { await refreshCurtainStatus() }
        }

        do {
            let devices = try await UVCService.listDevices()
            guard let device = devices.first else {
                error = "No UVC camera detected"
                return
            }
            currentDevice = device
            ranges = try await UVCService.getRanges(vendor: device.vendor, product: device.product)
            currentSettings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
            // Camera session is NOT started here. It starts when the popover opens.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Start the camera preview (called when menu bar popover opens).
    func startPreview() {
        guard captureSession == nil else { return }
        do {
            if let avDevice = CameraCaptureService.findCamera() {
                cameraService.sceneHandler = { [weak self] scene in
                    guard let self else { return }
                    self.lastScene = scene
                    self.lastSceneUpdatedAt = Date()
                    self.refreshLivePreviewCheckIfNeeded(scene)
                }
                captureSession = try cameraService.startSession(device: avDevice)
                writeState(previewActive: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stop the camera preview (called when menu bar popover closes).
    func stopPreview() {
        guard captureSession != nil else { return }
        cameraService.stopSession()
        captureSession = nil
        writeState(previewActive: false)
    }

    /// Clear the preview state file (called on app quit/crash recovery).
    nonisolated static func clearPreviewState() {
        let data: [String: Any] = [
            "preview_active": false,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? json.write(to: ojoStateURL)
        }
    }

    private func writeState(previewActive: Bool) {
        let data: [String: Any] = [
            "preview_active": previewActive,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? json.write(to: ojoStateURL)
        }
    }

    // MARK: - Actions

    private var ojoPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/camtune/ojo.py").path
    }

    func checkNow(reason: String = "manual") async {
        guard !isChecking, !isCalibrating, !isDeepRepairing, !isMeetingReadyRunning else { return }
        if let scene = freshLiveScene {
            applyLivePreviewCheck(scene)
            maybeSendCallGuardNotification(reason: reason, state: preCallState)
            return
        }
        await performCheck(reason: reason, allowCached: reason != "manual" && reason != "framing fix" && reason != "meeting ready")
    }

    /// Every reason a check can carry that did NOT come from the 90s
    /// auto-poll. Anything else (a call app name from
    /// activeVideoCallAppName) is an "auto" trigger for --trigger and for
    /// ojo.py's idle gating.
    private static let manualCheckReasons: Set<String> = [
        "manual", "framing fix", "meeting ready",
        "background guidance", "background fix", "lighting guidance",
    ]

    private func performCheck(reason: String, allowCached: Bool) async {
        isChecking = true
        error = nil
        statusMessage = "Checking..."
        lastAutoCheckReason = reason == "manual" ? nil : reason
        let trigger = Self.manualCheckReasons.contains(reason) ? "manual" : "auto"

        do {
            var arguments = [ojoPath, "check", "--json", "--log", "--trigger", trigger]
            if allowCached {
                arguments.append(contentsOf: ["--max-age-seconds", "45"])
                arguments.append("--skip-lights")
            } else if reason == "manual" {
                // Found live 2026-09-04: 0.8s was even tighter than
                // ojo.py's old 1.0s default, which was already reading
                // genuinely-reachable-but-slow bulbs as offline. Probing is
                // now parallelized across controls in ojo.py, so this no
                // longer costs 0.8s-times-however-many-lights; 3.0s gives a
                // real bulb a fair chance while staying well under what
                // Ryan is willing to wait for on a manual click.
                arguments.append(contentsOf: ["--light-timeout", "3.0"])
            } else if reason == "framing fix" {
                // A pan/tilt/zoom nudge cannot change light or curtain
                // reachability, so this recheck doesn't need to re-probe
                // them. Found live 2026-09-03: with 2 of 4 lights offline,
                // this alone was adding ~1.3s+ to every "Fix Framing" click
                // on top of an already-slow ~4.4s camera-only check.
                arguments.append("--skip-lights")
            }
            let output = try await ShellRunner.run(
                executablePath: "/usr/bin/python3",
                arguments: arguments,
                timeout: .seconds(30)
            )
            guard let data = output.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let state = payload["state"] as? String
            preCallState = state
            preCallReason = payload["reason"] as? String
            applyQuality(payload["quality"] as? [String: Any])
            applyScene(payload["scene"] as? [String: Any])
            preCallLastChecked = Date()
            preCallBlockingIssue = state == "red" ? preCallReason : nil
            maybeSendCallGuardNotification(reason: reason, state: state)
            statusMessage = nil
        } catch {
            preCallState = "red"
            preCallReason = error.localizedDescription
            preCallBlockingIssue = error.localizedDescription
            self.error = error.localizedDescription
            statusMessage = nil
        }

        isChecking = false
    }

    private func applyLivePreviewCheck(_ scene: SceneMetrics) {
        error = nil
        statusMessage = nil
        lastAutoCheckReason = nil
        lastScene = scene
        lastSceneUpdatedAt = Date()
        preCallLastChecked = Date()

        var issues: [String] = []
        var strengths: [String] = []

        if scene.faceBox == nil {
            preCallState = "red"
            preCallReason = "no face detected"
            preCallBlockingIssue = "no face detected"
            preCallQualityLabel = nil
            preCallQualityScore = nil
            preCallQualityIssue = "no face detected"
            preCallQualityIssues = ["no face detected"]
            preCallQualityStrengths = []
            return
        }

        if let y = scene.faceCenterY {
            if y < 0.42 {
                issues.append("face too high")
            } else if y > 0.58 {
                issues.append("face too low")
            } else {
                strengths.append("face is vertically centered")
            }
        }

        if let x = scene.faceCenterX {
            if x < 0.38 {
                issues.append("face too far left")
            } else if x > 0.62 {
                issues.append("face too far right")
            } else {
                strengths.append("face is centered")
            }
        }

        if let height = scene.faceHeightPct {
            if height < 0.25 {
                issues.append("face too small")
            } else if height > 0.55 {
                issues.append("face too large")
            } else {
                strengths.append("zoom looks right")
            }
        }

        if let face = scene.faceLumaMean {
            if face < 85 {
                issues.append("face reads a little dark")
            } else if face >= faceWhiteLumaWarn,
                      let separation = scene.backgroundSeparation,
                      separation > faceWhiteSeparationWarn {
                issues.append("face reads too white or flat for the saved preference")
            } else if face > 165 {
                issues.append("face risks looking too bright or flat")
            } else {
                strengths.append("face exposure is in range")
            }
        }

        if let separation = scene.backgroundSeparation {
            if separation < 10 {
                issues.append("background is not separated enough from face")
            } else if separation > 65 {
                issues.append("background may be too dark relative to face")
            } else {
                strengths.append("face/background separation is good")
            }
        }

        let score = max(0, min(100, 100 - issues.count * 12))
        preCallQualityScore = score
        preCallQualityLabel = score >= 88 ? "great" : score >= 75 ? "good" : score >= 60 ? "acceptable" : "weak"
        preCallQualityIssues = issues
        preCallQualityStrengths = strengths
        preCallQualityIssue = issues.first

        if issues.isEmpty {
            preCallState = "green"
            preCallReason = "preview check passed"
            preCallBlockingIssue = nil
        } else {
            preCallState = "yellow"
            preCallReason = issues.first
            preCallBlockingIssue = nil
        }
    }

    func calibrateNow() async {
        guard Self.sceneRepairEnabled else { return }
        guard let device = currentDevice else { return }
        guard !isChecking, !isCalibrating, !isDeepRepairing, !isMeetingReadyRunning else { return }
        isCalibrating = true
        optimizationRound = 1
        totalRounds = 1
        error = nil
        lastAssessment = nil
        statusMessage = "Safe calibrating..."

        do {
            let output = try await ShellRunner.run(
                executablePath: "/usr/bin/python3",
                arguments: [ojoPath, "calibrate", "--json"],
                timeout: .seconds(35)
            )
            if let data = output.data(using: .utf8),
               let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if payload["skipped_ai_tune"] as? Bool == true {
                    if let state = payload["pre_state"] as? String {
                        preCallState = state
                    }
                    applyQuality(payload["pre_quality"] as? [String: Any])
                    applyScene(payload["scene"] as? [String: Any])
                    preCallReason = payload["recommendation"] as? String
                    preCallLastChecked = Date()
                    statusMessage = nil
                    isCalibrating = false
                    return
                }
                if let state = payload["post_state"] as? String {
                    preCallState = state
                }
                applyQuality(payload["post_quality"] as? [String: Any])
                preCallReason = "Calibrated current time-bucket profile"
                preCallLastChecked = Date()
            }

            currentSettings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }

        isCalibrating = false
    }

    func deepRepairNow() async {
        guard Self.sceneRepairEnabled else { return }
        guard let device = currentDevice else { return }
        guard !isChecking, !isCalibrating, !isDeepRepairing, !isMeetingReadyRunning else { return }
        isDeepRepairing = true
        error = nil
        statusMessage = "Deep repair running..."

        do {
            let output = try await ShellRunner.run(
                executablePath: "/usr/bin/python3",
                arguments: [ojoPath, "calibrate", "--json", "--force-ai"],
                timeout: .seconds(180)
            )
            if let data = output.data(using: .utf8),
               let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let state = payload["post_state"] as? String {
                    preCallState = state
                }
                applyQuality(payload["post_quality"] as? [String: Any])
                preCallReason = "Deep repair completed with verification"
                preCallLastChecked = Date()
            }
            currentSettings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }

        isDeepRepairing = false
    }

    func meetingReadyNow() async {
        guard Self.sceneRepairEnabled else { return }
        guard !isChecking, !isCalibrating, !isDeepRepairing, !isMeetingReadyRunning else { return }
        isMeetingReadyRunning = true
        statusMessage = "Preparing meeting setup..."

        if let device = currentDevice,
           let preset = try? ProfileService.loadContextPreset(appName: detectedCallApp) {
            try? await UVCService.applySettings(
                preset, vendor: device.vendor, product: device.product)
            currentSettings = preset
        }
        await applyProductionLighting(recheck: false)

        if let scene = lastScene {
            applyLivePreviewCheck(scene)
            await applyFramingRecommendation(recheck: false)
            if let updatedScene = lastScene {
                applyLivePreviewCheck(updatedScene)
            }
        } else {
            await performCheck(reason: "meeting ready", allowCached: true)
        }

        if hasBackgroundIssue {
            await applyBackgroundFix(recheck: false)
            if let scene = lastScene {
                applyLivePreviewCheck(scene)
            }
        }

        statusMessage = preCallState == "green" ? "Meeting ready" : "Needs review"
        try? await Task.sleep(for: .milliseconds(700))
        statusMessage = nil
        isMeetingReadyRunning = false
    }

    func markBad(note: String) async {
        await logFeedback(kind: "bad", note: note)
    }

    func someoneCommented(note: String) async {
        await logFeedback(kind: "comment", note: note)
    }

    private func logFeedback(kind: String, note: String) async {
        do {
            if kind == "comment" || note == "video looked good" {
                try? ProfileService.saveContextPreset(
                    settings: currentSettings,
                    appName: detectedCallApp,
                    qualityScore: preCallQualityScore
                )
            }
            if kind == "bad" {
                activeCallSession?.rescueCount += 1
            }
            var arguments = [ojoPath, "feedback", kind, "--note", note]
            if let sessionID = activeCallSession?.id {
                arguments.append(contentsOf: ["--call-session-id", sessionID])
            }
            _ = try await ShellRunner.run(
                executablePath: "/usr/bin/python3",
                arguments: arguments,
                timeout: .seconds(10)
            )
            statusMessage = kind == "bad" ? "Marked bad" : "Comment logged"
            try? await Task.sleep(for: .seconds(2))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveProfile() async {
        guard let device = currentDevice else { return }
        do {
            let settings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
            try ProfileService.save(settings)
            try? ProfileService.saveContextPreset(
                settings: settings,
                appName: detectedCallApp,
                qualityScore: preCallQualityScore
            )
            savedProfileExists = true
            // Phase 2 (2026-09-03): also bank this into the real
            // time-bucket profile map (specs/ojo.md), so the classifier's
            // profile-freshness check has a real, bucket-aware entry for
            // right now instead of only the single profile.json's mtime.
            // Best-effort: profile.json is already saved above regardless.
            _ = try? await ShellRunner.run(
                executablePath: "/usr/bin/python3",
                arguments: [ojoPath, "profiles", "--save", "--json", "--skip-lights"],
                timeout: .seconds(15)
            )
            statusMessage = "Profile saved"
            try? await Task.sleep(for: .seconds(2))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restoreProfile() async {
        guard let device = currentDevice else { return }
        do {
            let profile = try ProfileService.load()
            try await UVCService.applySettings(
                profile, vendor: device.vendor, product: device.product)
            currentSettings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
            statusMessage = "Profile restored"
            try? await Task.sleep(for: .seconds(2))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshSettings() async {
        guard let device = currentDevice else { return }
        do {
            currentSettings = try await UVCService.exportSettings(
                vendor: device.vendor, product: device.product)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshDaemonStatus() {
        daemonStatus = DaemonService.checkStatus()
    }

    func refreshPermissionStatus() async {
        notificationStatus = await NotificationService.settingsSummary()
        browserAutomationStatus = browserAutomationProbe()
    }

    func openNotificationSettings() {
        NotificationService.openSystemSettings()
    }

    func testBrowserAutomation() async {
        browserAutomationStatus = browserAutomationProbe()
        statusMessage = browserAutomationStatus
        try? await Task.sleep(for: .seconds(2))
        statusMessage = nil
    }

    private func applyQuality(_ quality: [String: Any]?) {
        guard let quality else {
            preCallQualityLabel = nil
            preCallQualityScore = nil
            preCallQualityIssue = nil
            preCallQualityIssues = []
            preCallQualityStrengths = []
            return
        }
        preCallQualityLabel = quality["label"] as? String
        preCallQualityScore = quality["score"] as? Int
        preCallQualityIssues = quality["issues"] as? [String] ?? []
        preCallQualityStrengths = quality["strengths"] as? [String] ?? []
        preCallQualityIssue = preCallQualityIssues.first
    }

    private func applyScene(_ scene: [String: Any]?) {
        guard let scene else {
            lastScene = nil
            lastSceneUpdatedAt = nil
            return
        }
        lastScene = SceneMetrics(payload: scene)
        lastSceneUpdatedAt = Date()
    }

    private var freshLiveScene: SceneMetrics? {
        guard let lastScene,
              let lastSceneUpdatedAt,
              Date().timeIntervalSince(lastSceneUpdatedAt) < 5
        else { return nil }
        return lastScene
    }

    private func refreshLivePreviewCheckIfNeeded(_ scene: SceneMetrics) {
        guard !isChecking, !isCalibrating, !isDeepRepairing, !isMeetingReadyRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewAssessmentAt) >= 2 else { return }
        lastPreviewAssessmentAt = now
        applyLivePreviewCheck(scene)
    }

    private func maybeSendCallGuardNotification(reason: String, state: String?) {
        guard Self.sceneRepairEnabled else { return }
        guard reason != "manual",
              reason != "framing fix",
              reason != "background fix",
              reason != "meeting ready",
              let state,
              state.lowercased() != "green",
              state.lowercased() != "idle" // empty room, not a real problem
        else { return }

        let now = Date()
        if let lastCallGuardNotification,
           now.timeIntervalSince(lastCallGuardNotification) < 15 * 60 {
            return
        }
        lastCallGuardNotification = now

        let action = recommendedNotificationAction()
        NotificationService.sendCallGuard(
            title: "Ojo: \(state.capitalized) before \(reason)",
            body: action,
            identifier: "ojo-call-guard-\(Int(now.timeIntervalSince1970))"
        )
    }

    private func recommendedNotificationAction() -> String {
        let issue = (preCallQualityIssues + [preCallReason ?? ""])
            .joined(separator: " ")
            .lowercased()
        if issue.contains("face too high")
            || issue.contains("face too low")
            || issue.contains("too far")
            || issue.contains("face too small")
            || issue.contains("face too large") {
            return "Open Ojo and apply the framing fix."
        }
        if issue.contains("background") {
            return "Open Ojo and apply the background light fix."
        }
        return "Open Ojo and run Meeting Ready."
    }

    private func startAutomaticChecks() {
        guard autoCheckTask == nil else { return }
        autoCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.runAutomaticCheckIfNeeded()
            }
        }
    }

    private func runAutomaticCheckIfNeeded() async {
        guard autoCheckEnabled else { return }
        guard let appName = activeVideoCallAppName() else {
            if detectedCallApp != nil {
                await finishCallSession() // call just ended
            }
            detectedCallApp = nil
            return
        }
        if activeCallSession == nil {
            activeCallSession = CallSession(
                id: UUID().uuidString, app: appName, startedAt: Date())
        }
        detectedCallApp = appName
        let now = Date()
        if let lastAutoCheck, now.timeIntervalSince(lastAutoCheck) < 90 {
            return
        }
        lastAutoCheck = now
        await checkNow(reason: appName)
        activeCallSession?.record(state: preCallState)
    }

    private static let iso8601 = ISO8601DateFormatter()

    /// Phase 2 (2026-09-04): writes the call rollup ojo.py's classifier and
    /// specs/ojo.md's leading metrics need — see build_call_rollup in
    /// ojo.py. Fire-and-forget: a rollup failing to write must never block
    /// or error the actual call-ended state transition.
    private func finishCallSession() async {
        guard let session = activeCallSession else { return }
        activeCallSession = nil
        var arguments = [
            ojoPath, "calls", "log",
            "--app", session.app,
            "--call-session-id", session.id,
            "--started-at", Self.iso8601.string(from: session.startedAt),
            "--ended-at", Self.iso8601.string(from: Date()),
            "--checks-run", "\(session.checksRun)",
            "--rescue-count", "\(session.rescueCount)",
        ]
        if session.reachedGreen { arguments.append("--reached-green") }
        if let worst = session.worstState {
            arguments.append(contentsOf: ["--worst-state", worst])
        }
        if let final = preCallState {
            arguments.append(contentsOf: ["--final-state", final])
        }
        _ = try? await ShellRunner.run(
            executablePath: "/usr/bin/python3", arguments: arguments, timeout: .seconds(10))
    }

    private func activeVideoCallAppName() -> String? {
        let apps: [String: String] = [
            "us.zoom.xos": "Zoom",
            "com.apple.FaceTime": "FaceTime",
            "com.microsoft.teams2": "Teams",
            "com.microsoft.teams": "Teams",
            "com.cisco.webexmeetingsapp": "Webex",
        ]
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let name = apps[bundleID]
            else { continue }
            return name
        }
        return activeBrowserCallName()
    }

    private func activeBrowserCallName() -> String? {
        let browsers: [(app: String, label: String)] = [
            ("Google Chrome", "Chrome Meet"),
            ("Arc", "Arc Meet"),
            ("Safari", "Meet"),
        ]
        for browser in browsers {
            guard NSWorkspace.shared.runningApplications.contains(where: {
                $0.localizedName == browser.app
            }) else { continue }
            if browserHasCallURL(appName: browser.app) {
                return browser.label
            }
        }
        return nil
    }

    private func browserHasCallURL(appName: String) -> Bool {
        let script = """
        tell application "\(appName)"
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u contains "meet.google.com" or u contains "teams.microsoft.com" or u contains "zoom.us/wc" then return "yes"
            end repeat
          end repeat
        end tell
        return "no"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return result == "yes"
        } catch {
            return false
        }
    }

    private func browserAutomationProbe() -> String {
        for appName in ["Google Chrome", "Arc", "Safari"] {
            guard NSWorkspace.shared.runningApplications.contains(where: {
                $0.localizedName == appName
            }) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"\(appName)\" to count windows"]
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return "\(appName) automation allowed"
                }
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "blocked"
                return "\(appName) automation blocked: \(message.prefix(80))"
            } catch {
                return "\(appName) automation unavailable"
            }
        }
        return "No supported browser running"
    }

    // MARK: - Camera Controls (real-time slider changes)

    func setUVCControl(_ control: String, value: Int) async {
        guard let device = currentDevice else { return }
        // Update local state immediately for responsive UI
        currentSettings.values[control] = .int(value)
        // Debounce the actual UVC call + profile save
        pendingUVCTask?.cancel()
        pendingUVCTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            try? await UVCService.set(
                control: control, value: value,
                vendor: device.vendor, product: device.product)
            // Write to profile.json so the daemon hold loop picks up the change
            // instead of reverting it
            try? ProfileService.save(currentSettings)
        }
    }

    func setFoV(_ degrees: Int) async {
        guard let device = currentDevice else { return }
        // Brio 505 FoV maps to absolute_zoom ranges
        // 90 = 100 (min zoom), 78 = 150, 65 = 200
        let zoomValue: Int
        switch degrees {
        case 90: zoomValue = 100
        case 78: zoomValue = 150
        case 65: zoomValue = 200
        default: zoomValue = 100
        }
        currentSettings.values["absolute_zoom"] = .int(zoomValue)
        try? await UVCService.set(
            control: "absolute_zoom", value: zoomValue,
            vendor: device.vendor, product: device.product)
    }

    func nudgeComposition(dx: Int, dy: Int) async {
        guard let device = currentDevice else { return }
        let current = currentSettings.intArrayValue(for: "absolute_pan_tilt") ?? [0, 0]
        lastComposition = current
        let pan = clampPanTilt((current.first ?? 0) + dx)
        let tilt = clampPanTilt((current.dropFirst().first ?? 0) + dy)
        let values = [pan, tilt]
        currentSettings.values["absolute_pan_tilt"] = .intArray(values)
        do {
            try await UVCService.set(
                control: "absolute_pan_tilt",
                values: values,
                vendor: device.vendor,
                product: device.product
            )
            try? ProfileService.save(currentSettings)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetComposition() async {
        guard let device = currentDevice else { return }
        lastComposition = currentSettings.intArrayValue(for: "absolute_pan_tilt") ?? [0, 0]
        let values = [0, 0]
        currentSettings.values["absolute_pan_tilt"] = .intArray(values)
        do {
            try await UVCService.set(
                control: "absolute_pan_tilt",
                values: values,
                vendor: device.vendor,
                product: device.product
            )
            try? ProfileService.save(currentSettings)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clampPanTilt(_ value: Int) -> Int {
        min(max(value, -72000), 72000)
    }

    func undoCompositionNudge() async {
        guard let device = currentDevice, let values = lastComposition else { return }
        currentSettings.values["absolute_pan_tilt"] = .intArray(values)
        do {
            try await UVCService.set(
                control: "absolute_pan_tilt",
                values: values,
                vendor: device.vendor,
                product: device.product
            )
            try? ProfileService.save(currentSettings)
            lastComposition = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setCompositionStep(_ value: Int) {
        compositionStep = value
    }

    func applyFramingRecommendation(recheck: Bool = true) async {
        guard Self.sceneRepairEnabled else { return }
        let previousScore = preCallQualityScore
        // A frame can be wrong in more than one dimension. The previous
        // implementation fixed only the first warning,
        // forcing a second click when the face was also too small. Build one
        // composed adjustment from every current framing issue, then verify
        // the resulting image once.
        let issue = (preCallQualityIssues + [preCallQualityIssue ?? "", preCallReason ?? ""])
            .joined(separator: " ")
            .lowercased()
        var horizontal = 0
        var vertical = 0
        var zoom = 0

        if issue.contains("face too low") {
            vertical += compositionStep
        } else if issue.contains("face too high") {
            vertical -= compositionStep
        }
        if issue.contains("too far right") {
            horizontal -= compositionStep
        } else if issue.contains("too far left") {
            horizontal += compositionStep
        }
        if issue.contains("face too small") {
            zoom += 20
        } else if issue.contains("face too large") {
            zoom -= 20
        }

        guard horizontal != 0 || vertical != 0 || zoom != 0 else {
            statusMessage = "Framing already balanced"
            try? await Task.sleep(for: .milliseconds(700))
            statusMessage = nil
            return
        }

        statusMessage = "Adjusting framing..."
        if horizontal != 0 || vertical != 0 {
            await nudgeComposition(dx: horizontal, dy: vertical)
        }
        if zoom != 0 {
            await nudgeZoom(delta: zoom)
        }
        if recheck {
            await performCheck(reason: "framing fix", allowCached: false)
        }
        if let previousScore, let score = preCallQualityScore {
            let delta = score - previousScore
            statusMessage = delta >= 0 ? "Framing fix improved +\(delta)" : "Framing fix changed \(delta)"
            try? await Task.sleep(for: recheck ? .seconds(2) : .milliseconds(700))
            statusMessage = nil
        }
    }

    private var hasFramingFix: Bool {
        let issue = (preCallQualityIssue ?? preCallReason ?? "").lowercased()
        return issue.contains("face too high")
            || issue.contains("face too low")
            || issue.contains("too far")
            || issue.contains("face too small")
            || issue.contains("face too large")
    }

    private var hasBackgroundIssue: Bool {
        let issue = (preCallQualityIssues + [preCallReason ?? ""])
            .joined(separator: " ")
            .lowercased()
        return issue.contains("background")
    }

    func nudgeZoom(delta: Int) async {
        guard let device = currentDevice else { return }
        let range = ranges["absolute_zoom"] ?? UVCRange(min: 100, max: 400)
        let current = currentSettings.intValue(for: "absolute_zoom") ?? range.min
        let value = range.clamp(current + delta)
        currentSettings.values["absolute_zoom"] = .int(value)
        do {
            try await UVCService.set(
                control: "absolute_zoom",
                value: value,
                vendor: device.vendor,
                product: device.product
            )
            try? ProfileService.save(currentSettings)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Light Controls

    func applyBackgroundFix(recheck: Bool = true) async {
        guard Self.sceneRepairEnabled else { return }
        guard lightControlAvailable else {
            lightingPlanSummary = "No controllable desk lights here. Move away from bright backgrounds or add a lamp beside the camera."
            statusMessage = "Lighting guidance ready"
            if recheck {
                await performCheck(reason: "background guidance", allowCached: false)
            }
            try? await Task.sleep(for: .seconds(1))
            statusMessage = nil
            return
        }
        statusMessage = "Adjusting background light..."
        do {
            try await LightService.turnOff(target: "overheads")
            try await LightService.setCustomHSV(hue: 28, saturation: 18, brightness: 38, target: "cafe")
            try await LightService.setCustomHSV(hue: 35, saturation: 5, brightness: 55, target: "pie")
            lightingPlanSummary = "Background separation: key light down, warm practicals up."
            statusMessage = "Background light adjusted"
            if recheck {
                await performCheck(reason: "background fix", allowCached: false)
            }
            try? await Task.sleep(for: .seconds(1))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }
    }

    func applyVideoReadyLights() async {
        guard Self.sceneRepairEnabled else { return }
        guard lightControlAvailable else {
            lightingPlanSummary = "No controllable desk lights here. Use soft light facing you and keep the background slightly dimmer."
            statusMessage = "Lighting guidance ready"
            return
        }
        statusMessage = "Applying video lights..."
        do {
            try await LightService.setCustomHSV(hue: 30, saturation: 6, brightness: 26, target: "overheads")
            try await LightService.setCustomHSV(hue: 28, saturation: 18, brightness: 34, target: "cafe")
            try await LightService.setCustomHSV(hue: 35, saturation: 4, brightness: 50, target: "pie")
            lightingPlanSummary = "Balanced video baseline: soft warm key light, practical key, neutral fill."
            statusMessage = "Video lights ready"
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }
    }

    func applyProductionLighting(recheck: Bool = true) async {
        guard Self.sceneRepairEnabled else { return }
        guard lightControlAvailable else {
            lightingPlanSummary = portableLightingGuidance()
            statusMessage = "Lighting guidance ready"
            if recheck {
                await performCheck(reason: "lighting guidance", allowCached: false)
            }
            try? await Task.sleep(for: .seconds(1))
            statusMessage = nil
            return
        }
        let plan = productionLightingPlan()
        statusMessage = "Designing TV-quality light..."
        do {
            try await LightService.setCustomHSV(
                hue: plan.keyLight.hue,
                saturation: plan.keyLight.saturation,
                brightness: plan.keyLight.brightness,
                target: "overheads"
            )
            try await LightService.setCustomHSV(
                hue: plan.accent.hue,
                saturation: plan.accent.saturation,
                brightness: plan.accent.brightness,
                target: "cafe"
            )
            try await LightService.setCustomHSV(
                hue: plan.background.hue,
                saturation: plan.background.saturation,
                brightness: plan.background.brightness,
                target: "pie"
            )
            syncLightFixtureState(plan)
            lightingPlanSummary = plan.summary
            statusMessage = "TV-quality lighting applied"
            if recheck {
                await performCheck(reason: "production lighting", allowCached: false)
            }
            try? await Task.sleep(for: .seconds(1))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }
    }

    private struct LightTargetPlan {
        let hue: Int
        let saturation: Int
        let brightness: Int
    }

    private struct ProductionLightingPlan {
        let keyLight: LightTargetPlan
        let accent: LightTargetPlan
        let background: LightTargetPlan
        let summary: String
    }

    private func productionLightingPlan() -> ProductionLightingPlan {
        let face = lastScene?.faceLumaMean
        let separation = lastScene?.backgroundSeparation

        if let face, face < 85 {
            return ProductionLightingPlan(
                keyLight: LightTargetPlan(hue: 30, saturation: 5, brightness: 34),
                accent: LightTargetPlan(hue: 28, saturation: 16, brightness: 48),
                background: LightTargetPlan(hue: 35, saturation: 4, brightness: 66),
                summary: "Underlit face: raise warm key/fill while keeping key light soft."
            )
        }

        if let face,
           face >= faceWhiteLumaWarn,
           let separation,
           separation > faceWhiteSeparationWarn {
            return ProductionLightingPlan(
                keyLight: LightTargetPlan(hue: 30, saturation: 5, brightness: 12),
                accent: LightTargetPlan(hue: 28, saturation: 22, brightness: 30),
                background: LightTargetPlan(hue: 35, saturation: 5, brightness: 42),
                summary: "Pale/flat face: reduce broad fill and keep warmer background contrast."
            )
        }

        if let face, face > 165 {
            return ProductionLightingPlan(
                keyLight: LightTargetPlan(hue: 30, saturation: 4, brightness: 14),
                accent: LightTargetPlan(hue: 28, saturation: 20, brightness: 28),
                background: LightTargetPlan(hue: 35, saturation: 4, brightness: 36),
                summary: "Overbright face: reduce broad light, keep a low warm practical."
            )
        }

        if let separation, separation < 10 {
            return ProductionLightingPlan(
                keyLight: LightTargetPlan(hue: 30, saturation: 5, brightness: 18),
                accent: LightTargetPlan(hue: 27, saturation: 24, brightness: 44),
                background: LightTargetPlan(hue: 36, saturation: 5, brightness: 58),
                summary: "Flat background: lower key light, add warm side/accent contrast."
            )
        }

        return ProductionLightingPlan(
            keyLight: LightTargetPlan(hue: 30, saturation: 6, brightness: 24),
            accent: LightTargetPlan(hue: 28, saturation: 18, brightness: 38),
            background: LightTargetPlan(hue: 35, saturation: 4, brightness: 54),
            summary: "TV baseline: warm key, gentle fill, separated background."
        )
    }

    private func portableLightingGuidance() -> String {
        let face = lastScene?.faceLumaMean
        let separation = lastScene?.backgroundSeparation
        if let face, face < 85 {
            return "Portable setup: face the brightest soft light source, avoid key light-only light."
        }
        if let face, face > 165 {
            return "Portable setup: turn away from direct window light or lower screen brightness."
        }
        if let face,
           face >= faceWhiteLumaWarn,
           let separation,
           separation > faceWhiteSeparationWarn {
            return "Portable setup: lower broad front light and keep a warmer, dimmer background."
        }
        if let separation, separation < 10 {
            return "Portable setup: choose a darker background or add side light on your face."
        }
        return "Portable setup: keep light in front of you and background slightly dimmer."
    }

    private func syncLightFixtureState(_ plan: ProductionLightingPlan) {
        for index in lightFixtures.indices {
            switch lightFixtures[index].id {
            case "overheads":
                lightFixtures[index].hue = plan.keyLight.hue
                lightFixtures[index].saturation = plan.keyLight.saturation
                lightFixtures[index].brightness = plan.keyLight.brightness
                lightFixtures[index].isOn = true
            case "cafe":
                lightFixtures[index].hue = plan.accent.hue
                lightFixtures[index].saturation = plan.accent.saturation
                lightFixtures[index].brightness = plan.accent.brightness
                lightFixtures[index].isOn = true
            case "pie":
                lightFixtures[index].hue = plan.background.hue
                lightFixtures[index].saturation = plan.background.saturation
                lightFixtures[index].brightness = plan.background.brightness
                lightFixtures[index].isOn = true
            default:
                break
            }
        }
    }

    func applyLightScene(_ sceneId: String) async {
        do {
            try await LightService.applyScene(sceneId)
            statusMessage = "Scene: \(sceneId)"
            try? await Task.sleep(for: .seconds(1))
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Curtains

    func refreshCurtainStatus() async {
        guard curtainControlAvailable, !isCurtainBusy else { return }
        do {
            let status = try await CurtainService.status(target: "both")
            curtainStatusByTarget = status
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openCurtains(target: String) async {
        await runCurtainCommand(statusMessage: "Opening \(target)...") {
            try await CurtainService.open(target: target)
        }
    }

    func closeCurtains(target: String) async {
        await runCurtainCommand(statusMessage: "Closing \(target)...") {
            try await CurtainService.close(target: target)
        }
    }

    func setCurtainPosition(_ percent: Int, target: String) async {
        await runCurtainCommand(statusMessage: "Setting \(target) to \(percent)%...") {
            try await CurtainService.setPosition(percent, target: target)
        }
    }

    private func runCurtainCommand(statusMessage: String, _ action: @escaping () async throws -> Void) async {
        guard curtainControlAvailable, !isCurtainBusy else { return }
        isCurtainBusy = true
        self.statusMessage = statusMessage
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
        await refreshCurtainStatus()
        isCurtainBusy = false
        self.statusMessage = nil
    }

    func applyFixtureHSV(index: Int) async {
        let fixture = lightFixtures[index]
        let target = fixture.target
        let h = fixture.hue
        let s = fixture.saturation
        let b = fixture.brightness

        do {
            try await LightService.setCustomHSV(
                hue: h, saturation: s, brightness: b, target: target)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setFixtureEnabled(index: Int, enabled: Bool) async {
        guard lightFixtures.indices.contains(index) else { return }
        lightFixtures[index].isOn = enabled
        if enabled {
            await applyFixtureHSV(index: index)
            return
        }
        do {
            try await LightService.turnOff(target: lightFixtures[index].target)
        } catch {
            self.error = error.localizedDescription
            lightFixtures[index].isOn = true
        }
    }

    // MARK: - TV Controls

    func tvPlayPause() async {
        do { try await TVService.playPause() }
        catch { self.error = error.localizedDescription }
    }

    func tvNext() async {
        do { try await TVService.next() }
        catch { self.error = error.localizedDescription }
    }

    func startConcert() async {
        statusMessage = "Starting concert series..."
        do {
            try await TVService.startConcertSeries()
            statusMessage = nil
        } catch {
            self.error = error.localizedDescription
            statusMessage = nil
        }
    }

    func setAudioRoute(_ route: AudioRoute) async {
        do { try await TVService.setAudioRoute(route) }
        catch { self.error = error.localizedDescription }
    }

    func tvSleep() async {
        do { try await TVService.sleep() }
        catch { self.error = error.localizedDescription }
    }

    func tvWake() async {
        do { try await TVService.wake() }
        catch { self.error = error.localizedDescription }
    }

    // MARK: - Private

    private func applyResult(_ result: OptimizationResult, device: CameraDevice) async throws {
        // Apply auto modes first
        if let awb = result.auto_white_balance_temperature {
            try await UVCService.set(
                control: "auto_white_balance_temperature",
                value: awb != 0 ? 1 : 0,
                vendor: device.vendor, product: device.product)
        }
        if let aem = result.auto_exposure_mode {
            try await UVCService.set(
                control: "auto_exposure_mode", value: aem,
                vendor: device.vendor, product: device.product)
        }

        // Apply individual changes
        var changes = result.changes ?? [:]

        // Remove conflicting manual controls if auto is on
        if result.auto_white_balance_temperature == 1 {
            changes.removeValue(forKey: "white_balance_temperature")
        }
        if result.auto_exposure_mode == 8 {
            changes.removeValue(forKey: "exposure_time_absolute")
        }

        for (control, value) in changes {
            let clamped = ranges[control]?.clamp(value) ?? value
            try await UVCService.set(
                control: control, value: clamped,
                vendor: device.vendor, product: device.product)
        }
    }
}

private struct CallSession {
    let id: String
    let app: String
    let startedAt: Date
    var checksRun: Int = 0
    var reachedGreen: Bool = false
    var worstState: String?
    var rescueCount: Int = 0

    /// green < yellow < red. "idle" (empty room) never counts as worst,
    /// since it isn't a real problem with the call scene.
    private static func rank(_ state: String) -> Int {
        switch state.lowercased() {
        case "green": return 0
        case "yellow": return 1
        case "red": return 2
        default: return -1 // idle, unknown — never worse than a real state
        }
    }

    mutating func record(state: String?) {
        guard let state, Self.rank(state) >= 0 else { return }
        checksRun += 1
        if state.lowercased() == "green" { reachedGreen = true }
        if worstState == nil || Self.rank(state) > Self.rank(worstState!) {
            worstState = state
        }
    }
}
