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

                        Button {
                            Task { await state.checkNow() }
                        } label: {
                            DiagnosticText("Check")
                        }
                        .buttonStyle(OjoSecondaryButtonStyle())
                        .frame(width: 88)
                        .disabled(state.currentDevice == nil)
                        .accessibilityIdentifier("check-now")
                    }
                    .transition(.opacity)
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

    private var level: String? { state.preCallState?.lowercased() }

    private var title: String {
        switch level {
        case "green": return "You look good"
        case "yellow": return "Almost there"
        case "red": return "Needs attention"
        default: return "Not checked yet"
        }
    }

    private var subtitle: String {
        if level == "green" {
            return "Camera, framing and lighting all check out."
        }
        if let issue = state.preCallQualityIssue ?? state.preCallReason, !issue.isEmpty {
            return Self.sentence(AppState.plainLanguage(issue))
        }
        return "Tap Check to see how you look."
    }

    private var footnote: String? {
        if let message = state.statusMessage, !message.isEmpty, !isBusy { return Self.plainStatus(message) }
        // One line: when it was checked, or what the button will and will not touch.
        if let checked = state.preCallLastChecked, level != nil {
            return "Checked " + Self.relative(checked) + " · " + Self.shortScope(state.preparationScope, brief: true)
        }
        return Self.shortScope(state.preparationScope)
    }

    private var symbol: String {
        switch level {
        case "green": return "checkmark.circle.fill"
        case "yellow": return "exclamationmark.circle.fill"
        case "red": return "xmark.octagon.fill"
        default: return "video.circle.fill"
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
