import SwiftUI

struct LightsControlView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !state.lightControlAvailable {
                    unavailableView
                } else {
                    controlsView
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Lights unavailable", systemImage: "lightbulb.slash")
                .font(.headline)
            Text("Ojo can still guide your laptop setup, but this Mac is not connected to the desk lights.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await state.applyProductionLighting() }
            } label: {
                Label("Get Lighting Guidance", systemImage: "theatermasks")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var controlsView: some View {
        VStack(spacing: 12) {
            Button {
                Task { await state.applyProductionLighting() }
            } label: {
                Label("TV Quality Lighting", systemImage: "theatermasks")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if let summary = state.lightingPlanSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scenes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 6) {
                        ForEach(LightService.scenes) { scene in
                            Button {
                                Task { await state.applyLightScene(scene.id) }
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: scene.icon)
                                        .font(.caption)
                                    Text(scene.name)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Divider()

                // Per-fixture controls
                ForEach(Array(state.lightFixtures.enumerated()), id: \.element.id) { index, fixture in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(fixture.name)
                                .font(.caption)
                                .fontWeight(.medium)

                            Spacer()

                            Toggle("", isOn: fixtureOnBinding(index: index))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                        }

                        if fixture.isOn {
                            fixtureSliders(index: index)
                        }
                    }
                    .padding(.vertical, 2)

                    if index < state.lightFixtures.count - 1 {
                        Divider()
                    }
                }
        }
    }

    private func fixtureOnBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { state.lightFixtures[index].isOn },
            set: { newValue in
                Task { await state.setFixtureEnabled(index: index, enabled: newValue) }
            }
        )
    }

    @ViewBuilder
    private func fixtureSliders(index: Int) -> some View {
        let fixture = state.lightFixtures[index]

        VStack(spacing: 4) {
            hsvSlider(label: "H", value: fixture.hue, range: 0...360) { newVal in
                state.lightFixtures[index].hue = newVal
                Task { await state.applyFixtureHSV(index: index) }
            }
            hsvSlider(label: "S", value: fixture.saturation, range: 0...100) { newVal in
                state.lightFixtures[index].saturation = newVal
                Task { await state.applyFixtureHSV(index: index) }
            }
            hsvSlider(label: "B", value: fixture.brightness, range: 0...100) { newVal in
                state.lightFixtures[index].brightness = newVal
                Task { await state.applyFixtureHSV(index: index) }
            }
        }
    }

    private func hsvSlider(
        label: String, value: Int, range: ClosedRange<Double>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: range,
                step: 1
            )
            .controlSize(.small)
            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
