import SwiftUI

/// Ojo's visual language. One place for spacing, radii, type and the few
/// custom controls the popover needs, so every screen reads as one product.
/// Strings still go through DiagnosticText (see DiagnosticsTests) so the
/// operations journal sees exactly what Ryan sees.
enum Ojo {
    enum Space {
        static let page: CGFloat = 16
        static let card: CGFloat = 14
        static let gap: CGFloat = 12
        static let tight: CGFloat = 6
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 12
    }

    static let spring = Animation.snappy(duration: 0.26, extraBounce: 0.04)

    /// One typeface (SF Pro) and one scale. Sizes are explicit because macOS text
    /// styles are small (.subheadline is 11 pt, .caption 10 pt) and looked tiny
    /// beside 46 pt buttons and full-size switches.
    enum Style {
        static let title = Font.system(size: 22, weight: .semibold)
        static let heading = Font.system(size: 17, weight: .semibold)
        static let subtitle = Font.system(size: 14)
        static let rowTitle = Font.system(size: 15, weight: .semibold)
        static let rowCaption = Font.system(size: 13)
        static let note = Font.system(size: 12)
        static let tile = Font.system(size: 12, weight: .medium)
        static let chip = Font.system(size: 14, weight: .medium)
        static let chipSmall = Font.system(size: 12, weight: .semibold)
        static let sectionLabel = Font.system(size: 12, weight: .semibold)
        static let primaryButton = Font.system(size: 16, weight: .semibold)
        static let secondaryButton = Font.system(size: 15, weight: .medium)
        static let badge = Font.system(size: 12, weight: .medium)
    }

    /// Colors for the named light scenes. Purely decorative: they hint at what
    /// the button does before it is pressed.
    static func sceneTint(_ id: String) -> Color {
        switch id {
        case "warm-white": return Color(red: 1.0, green: 0.80, blue: 0.45)
        case "soft-rose": return Color(red: 0.98, green: 0.48, blue: 0.62)
        case "warm-amber": return Color(red: 1.0, green: 0.62, blue: 0.20)
        case "lavender": return Color(red: 0.62, green: 0.50, blue: 0.95)
        case "pitcher-green": return Color(red: 0.30, green: 0.78, blue: 0.45)
        case "70s-orange": return Color(red: 0.93, green: 0.42, blue: 0.14)
        case "reading": return Color(red: 0.35, green: 0.62, blue: 0.98)
        default: return Color.secondary
        }
    }
}

// MARK: - Containers

/// A rounded, softly bordered surface. Used for every group of controls.
struct OjoCard<Content: View>: View {
    var padding: CGFloat = Ojo.Space.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Ojo.Radius.card, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ojo.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct OjoSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        DiagnosticText(text)
            .font(Ojo.Style.sectionLabel)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

// MARK: - Buttons

struct OjoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ojo.Style.primaryButton)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.80)],
                        startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.accentColor.opacity(isEnabled ? 0.28 : 0), radius: 8, y: 3)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

struct OjoSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ojo.Style.secondaryButton)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

/// Small round icon-only button (refresh, dismiss, back).
struct OjoIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.0)))
            .contentShape(Circle())
    }
}

// MARK: - Gradient slider

/// A slider whose track shows what it controls (a rainbow for color, a ramp
/// for saturation). `onCommit` fires when the drag ends, `onChange` while it moves.
struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var colors: [Color]
    var label: String
    var onChange: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knob: CGFloat = 20
            let span = max(width - knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
                    .offset(x: span * fraction)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let t = min(max((drag.location.x - knob / 2) / span, 0), 1)
                        let next = range.lowerBound + (range.upperBound - range.lowerBound) * t
                        if abs(next - value) >= 1 {
                            value = next.rounded()
                            onChange()
                        }
                    }
            )
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onChange()
        }
    }
}

extension Color {
    /// Full-saturation rainbow stops for a 0...360 hue track.
    static let hueSpectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
        Color(hue: $0, saturation: 0.85, brightness: 1.0)
    }
}
