import SwiftUI

struct CameraControlsView: View {
    @Bindable var state: AppState

    private static let sliderControls: [(key: String, label: String)] = [
        ("brightness", "Brightness"),
        ("contrast", "Contrast"),
        ("saturation", "Saturation"),
        ("sharpness", "Sharpness"),
        ("gain", "Gain"),
    ]

    private static let autoToggles: [(key: String, label: String, onValue: Int)] = [
        ("auto_exposure_mode", "Auto Exposure", 8),
        ("auto_white_balance_temperature", "Auto White Balance", 1),
        ("auto_focus", "Auto Focus", 1),
    ]

    private static let fovPresets = [90, 78, 65]
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if !state.cameraControls.pending.isEmpty {
                    Text("Camera change pending readback").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(state.cameraControls.errors.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(state.cameraControls.errors[key] ?? "Not confirmed")")
                        .font(.caption).foregroundStyle(.red)
                }
                if state.ranges.isEmpty { Text("Camera controls unavailable: no verified ranges").font(.caption) }
                // Auto toggles
                ForEach(Self.autoToggles, id: \.key) { control in
                    autoToggleRow(key: control.key, label: control.label, onValue: control.onValue)
                }

                Divider()

                // White balance temperature (special: shows Kelvin)
                if let range = state.ranges["white_balance_temperature"] {
                    let currentValue = state.currentSettings.intValue(for: "white_balance_temperature") ?? 4000
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Temperature")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(currentValue) K")
                                .font(.caption.monospacedDigit())
                                .fontWeight(.medium)
                        }
                        Slider(
                            value: sliderBinding(
                                key: "white_balance_temperature",
                                range: range
                            ),
                            in: Double(range.min)...Double(range.max),
                            step: Double(range.step)
                        )
                        .controlSize(.small)
                        .disabled(state.currentSettings.intValue(for: "auto_white_balance_temperature") == 1)
                    }
                }

                // Main sliders
                ForEach(Self.sliderControls, id: \.key) { control in
                    if let range = state.ranges[control.key] {
                        sliderRow(key: control.key, label: control.label, range: range)
                    }
                }

                Divider()

                // Exposure time (only when manual)
                if let range = state.ranges["exposure_time_absolute"] {
                    let currentValue = state.currentSettings.intValue(for: "exposure_time_absolute") ?? 300
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Exposure Time")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(currentValue)")
                                .font(.caption.monospacedDigit())
                                .fontWeight(.medium)
                        }
                        Slider(
                            value: sliderBinding(
                                key: "exposure_time_absolute",
                                range: range
                            ),
                            in: Double(range.min)...Double(range.max),
                            step: Double(range.step)
                        )
                        .controlSize(.small)
                        .disabled(state.currentSettings.intValue(for: "auto_exposure_mode") == 8)
                    }
                }

                // FoV presets
                VStack(alignment: .leading, spacing: 4) {
                    Text("Field of View — degree presets uncalibrated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(Self.fovPresets, id: \.self) { fov in
                            Button("\(fov)\u{00B0}") {
                                Task { await state.setFoV(fov) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption)
                            .disabled(true)
                        }
                    }
                }

                // Zoom
                if let range = state.ranges["absolute_zoom"] {
                    sliderRow(key: "absolute_zoom", label: "Zoom", range: range)
                }

                compositionControls
                    .disabled(!state.canAdjustComposition)
                if !state.canAdjustComposition {
                    Text("Pan/tilt needs zoom above 100 and a measured camera calibration receipt")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Button("Fix Framing — measured") {
                    Task { await state.applyFramingRecommendation() }
                }
                .disabled(state.currentDevice == nil || state.isChecking)
                .help("Moves the camera only with a measured calibration receipt; bounded, re-measured, rolled back if worse")

                Toggle("Allow this scene to adjust room controls", isOn: $state.allowSceneRoomChanges)
                    .font(.caption)
                    .help("Off preserves manual light and curtain choices; bulbs that are off remain off")
                HStack {
                    Button("Make Me Look Good") { Task { await state.meetingReadyNow() } }
                    Button("AI Tune") { Task { await state.deepRepairNow() } }
                        .help("Explicitly sends one preview image to Claude to choose among validated room adjustments")
                }
                .disabled(state.isChecking || state.isMeetingReadyRunning || state.currentDevice == nil)
                if state.activePreparationID != nil {
                    Button("Cancel preparation") { Task { await state.cancelPreparation() } }
                }
                ForEach(Array(state.preparationOutcomes.enumerated()), id: \.offset) { _, outcome in
                    Text("Preparation step — " + outcome).font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // Actions
                HStack(spacing: 8) {
                    Button("Reset") {
                        Task { await state.restoreProfile() }
                    }
                    .controlSize(.small)
                    .disabled(state.currentDevice == nil || !state.savedProfileExists)

                    Button("Save") {
                        Task { await state.saveProfile() }
                    }
                    .controlSize(.small)
                    .disabled(state.currentDevice == nil)
                }

                if state.isOptimizing || state.isCalibrating || state.isDeepRepairing || state.isMeetingReadyRunning {
                    OptimizationProgressView(
                        round: state.optimizationRound,
                        total: state.totalRounds,
                        message: state.statusMessage)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Components

    private var compositionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Composition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(state.panTiltText) / \(state.zoomText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("Step", selection: Binding(
                get: { state.compositionStep },
                set: { state.setCompositionStep($0) }
            )) {
                Text("Small").tag(1800)
                Text("Medium").tag(3600)
                Text("Large").tag(7200)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Spacer()
                    Button {
                        Task { await state.nudgeComposition(dx: 0, dy: state.compositionStep) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .help("Pan image up")
                    Spacer()
                }
                GridRow {
                    Button {
                        Task { await state.nudgeComposition(dx: -state.compositionStep, dy: 0) }
                    } label: {
                        Image(systemName: "arrow.left")
                    }
                    .help("Pan image left")

                    Button {
                        Task { await state.resetComposition() }
                    } label: {
                        Image(systemName: "scope")
                    }
                    .help("Reset pan/tilt")

                    Button {
                        Task { await state.nudgeComposition(dx: state.compositionStep, dy: 0) }
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .help("Pan image right")
                }
                GridRow {
                    Spacer()
                    Button {
                        Task { await state.nudgeComposition(dx: 0, dy: -state.compositionStep) }
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .help("Pan image down")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.currentDevice == nil)

            HStack(spacing: 6) {
                Button {
                    Task { await state.undoCompositionNudge() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(state.lastComposition == nil)

                Button {
                    Task { await state.applyFramingRecommendation() }
                } label: {
                    Label("Frame Me", systemImage: "scope")
                }
                .help("Correct headroom, centering, and zoom together")

                Button {
                    Task { await state.nudgeZoom(delta: -20) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")

                Button {
                    Task { await state.nudgeZoom(delta: 20) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.currentDevice == nil)
        }
    }

    private func autoToggleRow(key: String, label: String, onValue: Int) -> some View {
        let currentValue = state.currentSettings.intValue(for: key)
        let isOn = currentValue == onValue
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                let setValue = newValue ? onValue : (onValue == 8 ? 1 : 0)
                Task { await state.setUVCControl(key, value: setValue) }
            }
        )) {
            Text(label)
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(currentValue == nil)
    }

    private func sliderRow(key: String, label: String, range: UVCRange) -> some View {
        let currentValue = state.currentSettings.intValue(for: key) ?? range.min
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(currentValue)")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.medium)
            }
            Slider(
                value: sliderBinding(key: key, range: range),
                in: Double(range.min)...Double(range.max),
                step: Double(range.step)
            )
            .controlSize(.small)
            .disabled(state.currentSettings.values[key] == nil || (key == "gain" && state.currentSettings.intValue(for: "auto_exposure_mode") != 1))
        }
    }

    private func sliderBinding(key: String, range: UVCRange) -> Binding<Double> {
        Binding(
            get: {
                Double(state.currentSettings.intValue(for: key) ?? range.min)
            },
            set: { newValue in
                let intValue = range.clamp(Int(newValue))
                Task { await state.setUVCControl(key, value: intValue) }
            }
        )
    }
}
