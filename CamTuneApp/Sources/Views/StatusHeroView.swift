import SwiftUI

/// The top of the popover: how you look right now, in one plain sentence,
/// and the two things you can do about it.
struct StatusHeroView: View {
    @Bindable var state: AppState

    var body: some View {
        OjoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.16))
                        Image(systemName: symbol)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        DiagnosticText(title)
                            .font(Ojo.Style.title)
                        DiagnosticText(subtitle)
                            .font(Ojo.Style.subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    if let app = state.detectedCallApp {
                        Label(app, systemImage: "video.fill")
                            .font(Ojo.Style.badge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }

                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        DiagnosticText(progressLabel)
                            .font(Ojo.Style.chip)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .transition(.opacity)
                } else {
                    HStack(spacing: 10) {
                        // Make Me Look Good adjusts the Brio; with the iPhone it has nothing to move.
                        if !state.usingIPhone {
                            Button {
                                Task { await state.meetingReadyNow() }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "sparkles")
                                    DiagnosticText("Make Me Look Good")
                                }
                            }
                            .buttonStyle(OjoPrimaryButtonStyle())
                            .disabled(!state.canPrepareScene || state.currentDevice == nil)
                            .accessibilityIdentifier("make-me-look-good")
                        }

                        Button {
                            Task { await state.checkNow() }
                        } label: {
                            DiagnosticText("Check")
                        }
                        .buttonStyle(OjoSecondaryButtonStyle())
                        .frame(maxWidth: state.usingIPhone ? .infinity : 88)
                        .disabled(state.activeCameraName == nil)
                        .accessibilityIdentifier("check-now")
                    }
                    .transition(.opacity)
                }

                if let network = state.network {
                    ConnectionRow(sample: network)
                }

                if let footnote {
                    DiagnosticText(footnote)
                        .font(Ojo.Style.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(Ojo.spring, value: isBusy)
        }
    }

    // MARK: State → words

    private var isBusy: Bool {
        state.isChecking || state.isMeetingReadyRunning || state.isCalibrating || state.isDeepRepairing
    }

    private var progressLabel: String {
        if state.isMeetingReadyRunning { return "Getting you ready…" }
        if state.isDeepRepairing { return "Repairing…" }
        if state.isCalibrating { return "Calibrating…" }
        return "Checking your camera…"
    }

    /// What the card is about, before colour. "Not checked yet" was the first thing Ryan saw on
    /// most opens (982 times in the 2026-11-20 diagnostics); an empty chair or a waking camera
    /// is not a problem to shout about.
    private enum Mood { case result(String), looking, away, cameraSilent, idle }

    private var mood: Mood {
        let raw = state.preCallState?.lowercased()
        // No face is "sit in view", not red: nothing is wrong with an empty chair.
        if state.lastScene?.faceCount == 0, state.hasLiveResult { return .away }
        if let raw, ["green", "yellow", "red"].contains(raw) { return .result(raw) }
        if state.captureSession != nil, !state.hasLiveResult {
            return state.previewWaitExpired ? .cameraSilent : .looking
        }
        return .idle
    }

    private var level: String? {
        if case .result(let raw) = mood { return raw }
        return nil
    }

    private var title: String {
        switch mood {
        case .result("green"): return "You look good"
        case .result("yellow"): return "Almost there"
        case .result: return "Needs attention"
        case .looking: return "Looking…"
        case .away: return "Sit in view"
        case .cameraSilent: return "Camera is quiet"
        case .idle: return "Ready when you are"
        }
    }

    private var subtitle: String {
        switch mood {
        case .looking:
            return state.usingIPhone ? "Waking the iPhone camera." : "Starting the camera."
        case .away:
            return "Ojo checks how you look as soon as it sees you."
        case .cameraSilent:
            return state.usingIPhone ? "No picture yet. Wake the phone or check it's on its mount." : "No picture yet. Check the webcam."
        case .idle:
            return "Tap Check to see how you look."
        case .result:
            break
        }
        if level == "green" {
            return "Camera, framing and lighting all check out."
        }
        if let issue = state.preCallQualityIssue ?? state.preCallReason, !issue.isEmpty {
            return Self.sentence(AppState.plainLanguage(issue))
        }
        return "Tap Check to see how you look."
    }

    private var footnote: String? {
        // The footer already names the camera; the card only adds when it was checked.
        if state.usingIPhone, !isBusy, state.statusMessage?.isEmpty ?? true {
            if let checked = state.preCallLastChecked, level != nil { return "Checked " + Self.relative(checked) }
            return nil
        }
        if let note = state.scheduledNote, !isBusy { return note }
        if let message = state.statusMessage, !message.isEmpty, !isBusy { return Self.plainStatus(message) }
        // One line: when it was checked, or what the button will and will not touch.
        if let checked = state.preCallLastChecked, level != nil {
            return "Checked " + Self.relative(checked) + " · " + Self.shortScope(state.preparationScope, brief: true)
        }
        return Self.shortScope(state.preparationScope)
    }

    private var symbol: String {
        switch mood {
        case .result("green"): return "checkmark.circle.fill"
        case .result("yellow"): return "exclamationmark.circle.fill"
        case .result: return "xmark.octagon.fill"
        case .looking: return "eye.circle.fill"
        case .away: return "person.crop.circle"
        case .cameraSilent: return "video.slash.fill"
        case .idle: return "video.circle.fill"
        }
    }

    private var tint: Color {
        switch level {
        case "green": return .green
        case "yellow": return .orange
        case "red": return .red
        default: return .secondary
        }
    }

    /// AppState's outcome sentences end with an engineering pointer ("see scene check
    /// for remaining issues"); the hero already shows the remaining issue itself.
    private static func plainStatus(_ message: String) -> String {
        message.replacingOccurrences(of: "; see scene check for remaining issues.", with: ".")
            .replacingOccurrences(of: "Lights and curtains unchanged", with: "Lights and curtains untouched")
    }

    /// The scope text comes from AppState; say the same thing in fewer words.
    private static func shortScope(_ scope: String, brief: Bool = false) -> String {
        if scope.contains("stay as you set them") {
            return brief ? "Camera only" : "Camera only — lights and curtains stay put"
        }
        if scope.contains("measured room adjustments") { return "Camera and measured room adjustments" }
        return scope
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capped = first.uppercased() + text.dropFirst()
        return capped.hasSuffix(".") ? capped : capped + "."
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}


/// One line on the card: the call-quality number, its colour and a plain verdict.
private struct ConnectionRow: View {
    let sample: NetworkSample

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            DiagnosticText("Connection")
                .font(Ojo.Style.chipSmall)
                .foregroundStyle(.secondary)
            DiagnosticText(sample.jitterLabel, live: true)
                .font(Ojo.Style.chipSmall)
            Spacer(minLength: 4)
            DiagnosticText(sample.verdict, live: true)
                .font(Ojo.Style.note)
                .foregroundStyle(sample.level == .good ? .secondary : color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-quality")
    }

    private var color: Color {
        switch sample.level {
        case .good: return .green
        case .shaky: return .orange
        case .poor: return .red
        }
    }
}
