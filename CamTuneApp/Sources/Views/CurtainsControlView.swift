import SwiftUI

struct CurtainsControlView: View {
    @Bindable var state: AppState
    @State private var selectedTarget: String = "both"

    private let targets: [(id: String, label: String)] = [
        ("left", "Left"), ("right", "Right"), ("both", "Both"),
    ]
    private let presets = [0, 25, 50, 75, 100]

    var body: some View {
        VStack(spacing: 10) {
            if !state.curtainControlAvailable {
                unavailableView
            } else {
                controlsView
            }
        }
    }

    private var unavailableView: some View {
        Label("Curtains unavailable", systemImage: "blinds.horizontal.closed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsView: some View {
        VStack(spacing: 8) {
            Picker("", selection: $selectedTarget) {
                ForEach(targets, id: \.id) { t in
                    Text(t.label).tag(t.id)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                positionLabel
                Spacer()
                Button {
                    Task { await state.openCurtains(target: selectedTarget) }
                } label: {
                    Label("Open", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isCurtainBusy)

                Button {
                    Task { await state.closeCurtains(target: selectedTarget) }
                } label: {
                    Label("Close", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isCurtainBusy)
            }

            HStack(spacing: 4) {
                ForEach(presets, id: \.self) { pct in
                    Button("\(pct)%") {
                        Task { await state.setCurtainPosition(pct, target: selectedTarget) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(state.isCurtainBusy)
                }
            }
        }
        .task { await state.refreshCurtainStatus() }
    }

    @ViewBuilder
    private var positionLabel: some View {
        if state.isCurtainBusy {
            Label("Moving...", systemImage: "arrow.left.arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let summary = positionSummary {
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Position unknown")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var positionSummary: String? {
        let statuses = state.curtainStatusByTarget.values.filter { $0.reachable }
        guard !statuses.isEmpty else { return nil }
        let parts = statuses.compactMap { s -> String? in
            guard let pct = s.positionPercent else { return nil }
            let short = s.target.replacingOccurrences(of: "Curtain ", with: "")
            return "\(short) \(pct)%"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
