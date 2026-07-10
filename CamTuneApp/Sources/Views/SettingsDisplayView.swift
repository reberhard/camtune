import SwiftUI

struct SettingsDisplayView: View {
    let settings: UVCSettings
    let ranges: [String: UVCRange]

    private static let displayControls = [
        "brightness", "contrast", "saturation", "gain",
        "sharpness", "white_balance_temperature",
    ]

    private static let autoControls = [
        ("auto_white_balance_temperature", "Auto WB"),
        ("auto_exposure_mode", "Auto Exp"),
        ("auto_focus", "Auto Focus"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Auto mode indicators
            HStack(spacing: 12) {
                ForEach(Self.autoControls, id: \.0) { control, label in
                    if let value = settings.intValue(for: control) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(autoIsOn(control: control, value: value) ? .green : .secondary)
                                .frame(width: 6, height: 6)
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Main controls grid
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 4
            ) {
                ForEach(Self.displayControls, id: \.self) { control in
                    if let value = settings.intValue(for: control) {
                        HStack {
                            Text(formatLabel(control))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(value)")
                                .font(.caption.monospacedDigit())
                                .fontWeight(.medium)
                        }
                    }
                }
            }
        }
    }

    private func formatLabel(_ control: String) -> String {
        control
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "white balance temperature", with: "WB temp")
            .capitalized
    }

    private func autoIsOn(control: String, value: Int) -> Bool {
        switch control {
        case "auto_exposure_mode": return value == 8
        default: return value == 1
        }
    }
}
