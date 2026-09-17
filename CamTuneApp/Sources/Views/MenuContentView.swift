import SwiftUI

struct MenuContentView: View {
    @Bindable var state: AppState
    @State private var cameraExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // readinessSummary already carries the reason inline
                    // ("Scene yellow — ..."); a second line repeating it was
                    // exactly the clutter Ryan flagged 2026-09-14.
                    Text(state.readinessSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !state.canAdjustComposition {
                        Text("Pan/tilt needs more zoom, or isn't calibrated for this camera yet")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !state.canPrepareScene {
                        Text("Make Me Look Good isn't set up for this room yet")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Check") { Task { await state.checkNow() } }
                        Button("Make Me Look Good") { Task { await state.meetingReadyNow() } }
                    }
                    .disabled(state.isChecking || state.isMeetingReadyRunning)

                    // Lights and curtains are the first screen, not behind a
                    // disclosure or a tab. Ryan, 2026-09-03: "I want to be
                    // able to easily control my lights and curtains... not
                    // buried once I click on it."
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BasicLightsView(room: state.room)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Curtains")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BasicCurtainsView(room: state.room)
                    }

                    DisclosureGroup("Camera preview & manual controls", isExpanded: $cameraExpanded) {
                        preview
                        FineTuneView(state: state)
                    }
                    .onChange(of: cameraExpanded) { _, expanded in
                        if expanded { state.startPreview() } else { state.stopPreview() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let error = state.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            if let msg = state.statusMessage, !state.isOptimizing {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Toggle(isOn: $state.autoCheckEnabled) {
                    Text(AppState.observeChecksEnabled ? "Auto-check (observe only)" : "Auto-check awaits call validation")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!AppState.observeChecksEnabled)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .task {
            await state.startUp()
        }
        .onAppear {
            state.room.refresh()
        }
        .onDisappear {
            if !state.isOptimizing
                && !state.isChecking
                && !state.isCalibrating
                && !state.isDeepRepairing
                && !state.isMeetingReadyRunning {
                state.stopPreview()
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let session = state.captureSession {
            CameraPreviewView(session: session)
                .frame(height: 205)
                .overlay {
                    CompositionOverlayView(scene: state.lastScene)
                }
                .overlay(alignment: .topTrailing) {
                    if let activityLabel {
                        ActivityBadge(text: activityLabel)
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.black.opacity(0.08), lineWidth: 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            SceneQualityPillsView(scene: state.lastScene)
                .padding(.horizontal, 16)

            QuickFramingControlsView(state: state)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(height: 205)
                .overlay {
                    PreviewUnavailableView(
                        title: state.error == nil ? "Camera preview starting" : "Camera unavailable",
                        message: state.statusMessage ?? "Ojo will keep controls available while the camera comes online.",
                        systemImage: state.error == nil ? "video" : "camera.badge.exclamationmark"
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
    }

    private var activityLabel: String? {
        if state.isMeetingReadyRunning { return "Making you look good" }
        if state.isDeepRepairing { return "Deep repair running" }
        if state.isCalibrating { return "Calibrating" }
        if state.isChecking { return "Checking" }
        return nil
    }
}

// Keep an operator-controlled escape hatch beside the image. Automatic
// framing is a convenience, not the only way Ryan can correct a bad frame.
private struct QuickFramingControlsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Manual framing", systemImage: "move.3d")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text("Small steps · Undo available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button {
                    Task { await state.nudgeComposition(dx: 0, dy: state.compositionStep) }
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .help("Move the camera image up")

                Button {
                    Task { await state.nudgeComposition(dx: -state.compositionStep, dy: 0) }
                } label: {
                    Label("Left", systemImage: "arrow.left")
                }
                .help("Move the camera image left")

                Button {
                    Task { await state.nudgeComposition(dx: state.compositionStep, dy: 0) }
                } label: {
                    Label("Right", systemImage: "arrow.right")
                }
                .help("Move the camera image right")

                Button {
                    Task { await state.nudgeComposition(dx: 0, dy: -state.compositionStep) }
                } label: {
                    Label("Down", systemImage: "arrow.down")
                }
                .help("Move the camera image down")

                Divider()
                    .frame(height: 18)

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

                Button {
                    Task { await state.undoCompositionNudge() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo the last pan or tilt adjustment")
                .disabled(state.lastComposition == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.currentDevice == nil)
        }
    }
}

private struct ActivityBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "sparkles")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.58), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct PreviewUnavailableView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
        }
    }
}

private struct ReadinessView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if let app = state.detectedCallApp {
                    Label(app, systemImage: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let score = state.preCallQualityScore, let label = state.preCallQualityLabel {
                Text("\(label.capitalized) \(score)")
                    .font(.caption2)
                    .foregroundStyle(score >= 88 ? .green : .secondary)
            }
        }
    }

    private var title: String {
        switch state.preCallState?.lowercased() {
        case "green": return "Ready for video"
        case "yellow": return "Needs adjustment"
        case "red": return "Blocked"
        default: return "Ready check"
        }
    }

    private var message: String {
        if let issue = state.preCallQualityIssue {
            return AppState.plainLanguage(issue)
        }
        if let reason = state.preCallReason {
            return AppState.plainLanguage(reason)
        }
        return "Ojo will check framing, lighting, and camera settings before your call."
    }

    private var statusColor: Color {
        switch state.preCallState?.lowercased() {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .secondary
        }
    }
}

private struct PrimaryActionsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await state.meetingReadyNow() }
            } label: {
                Label("Make Me Look Good", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)

            HStack(spacing: 8) {
                Button {
                    Task { await state.checkNow() }
                } label: {
                    Label("Check", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if let action = recommendedAction {
                    Button {
                        Task { await runRecommendedAction(action) }
                    } label: {
                        Label(action.title, systemImage: action.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }
            }

            if state.isChecking || state.isCalibrating || state.isDeepRepairing || state.isMeetingReadyRunning {
                ProgressView(progressLabel)
                    .controlSize(.small)
            }

            if let summary = state.lightingPlanSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isBusy: Bool {
        state.currentDevice == nil
            || state.isChecking
            || state.isCalibrating
            || state.isDeepRepairing
            || state.isMeetingReadyRunning
    }

    private var progressLabel: String {
        if state.isMeetingReadyRunning { return "Making you look good..." }
        if state.isDeepRepairing { return "Repairing..." }
        if state.isCalibrating { return "Calibrating..." }
        return "Checking..."
    }

    private struct RecommendedAction {
        let title: String
        let icon: String
        let kind: Kind

        enum Kind {
            case framing
            case lighting
            case background
        }
    }

    private var recommendedAction: RecommendedAction? {
        let issue = (state.preCallQualityIssues + [state.preCallReason ?? ""])
            .joined(separator: " ")
            .lowercased()

        if issue.contains("face too high")
            || issue.contains("face too low")
            || issue.contains("too far")
            || issue.contains("face too small")
            || issue.contains("face too large") {
            return RecommendedAction(title: "Fix Framing", icon: "scope", kind: .framing)
        }
        if issue.contains("background") {
            return RecommendedAction(title: "Improve Background", icon: "lightbulb.2", kind: .background)
        }
        if state.preCallState?.lowercased() == "yellow" || state.preCallState?.lowercased() == "red" {
            return RecommendedAction(title: "Studio Lighting", icon: "theatermasks", kind: .lighting)
        }
        return nil
    }

    private func runRecommendedAction(_ action: RecommendedAction) async {
        switch action.kind {
        case .framing:
            await state.applyFramingRecommendation()
        case .lighting:
            await state.applyProductionLighting()
        case .background:
            await state.applyBackgroundFix()
        }
    }
}

// Camera sliders and calibration/advanced controls. Lights and curtains
// moved out of this disclosure (2026-09-03) onto the main popover screen —
// see MenuContentView.body. This stays collapsed by default because Ryan
// should not need to open it before an ordinary call.
private struct FineTuneView: View {
    @Bindable var state: AppState
    @State private var isExpanded = false
    @State private var section: FineTuneSection = .camera

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $section) {
                    ForEach(FineTuneSection.allCases, id: \.self) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .camera:
                    CameraControlsView(state: state)
                        .frame(maxHeight: 260)
                case .advanced:
                    AdvancedView(state: state)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Camera & More")
                    .font(.headline)
                Spacer()
                Text("\(state.panTiltText) · \(state.zoomText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum FineTuneSection: CaseIterable {
        case camera
        case advanced

        var title: String {
            switch self {
            case .camera: return "Camera"
            case .advanced: return "More"
            }
        }

        var icon: String {
            switch self {
            case .camera: return "camera"
            case .advanced: return "gearshape"
            }
        }
    }
}

private struct AdvancedView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.notificationStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(state.browserAutomationStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(state.callActivityReason)
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button("Refresh") {
                    Task { await state.refreshPermissionStatus() }
                }
                Button("Notifications") {
                    state.openNotificationSettings()
                }
            }
            .controlSize(.small)

            Button("Test Browser Access") {
                Task { await state.testBrowserAutomation() }
            }
            .controlSize(.small)

            Divider()

            Button("Calibrate Camera (unavailable during repair)") {
                Task { await state.calibrateNow() }
            }
            .controlSize(.small)
            .disabled(true)

            Button(role: .destructive) {
                Task { await state.deepRepairNow() }
            } label: {
                Label("Deep Repair", systemImage: "wand.and.stars.inverse")
            }
            .controlSize(.small)
            .disabled(true)

            Divider()

            HStack {
                feedbackMenu("Bad", icon: "xmark.circle", kind: "bad")
                feedbackMenu("Good", icon: "quote.bubble", kind: "comment")
            }
            .controlSize(.small)
        }
    }

    private func feedbackMenu(_ title: String, icon: String, kind: String) -> some View {
        Menu {
            if kind == "bad" {
                Button("Too bright") { Task { await state.markBad(note: "too bright") } }
                Button("Too dark") { Task { await state.markBad(note: "too dark") } }
                Button("Weird color") { Task { await state.markBad(note: "weird color") } }
                Button("Bad framing") { Task { await state.markBad(note: "bad framing") } }
            } else {
                Button("Video looked good") { Task { await state.someoneCommented(note: "video looked good") } }
                Button("Lighting compliment") { Task { await state.someoneCommented(note: "lighting compliment") } }
                Button("Camera compliment") { Task { await state.someoneCommented(note: "camera quality compliment") } }
            }
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

private struct CompositionOverlayView: View {
    let scene: SceneMetrics?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                guideLines(in: geometry.size)
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

                faceCenterTarget(in: geometry.size)
                    .stroke(.green.opacity(0.52), lineWidth: 2)

                if let box = scene?.faceBox {
                    let rect = CGRect(
                        x: box.minX * geometry.size.width,
                        y: box.minY * geometry.size.height,
                        width: box.width * geometry.size.width,
                        height: box.height * geometry.size.height
                    )
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.green, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                if let exposureHint = scene?.exposureHint {
                    hintLabel(exposureHint)
                        .position(x: geometry.size.width / 2, y: 22)
                }

                if let hint {
                    hintLabel(hint)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 22)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func guideLines(in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width / 2, y: 0))
        path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        path.move(to: CGPoint(x: 0, y: size.height * 0.5))
        path.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
        return path
    }

    private func faceCenterTarget(in size: CGSize) -> Path {
        var path = Path()
        let top = size.height * 0.42
        let bottom = size.height * 0.58
        path.move(to: CGPoint(x: size.width * 0.20, y: top))
        path.addLine(to: CGPoint(x: size.width * 0.80, y: top))
        path.move(to: CGPoint(x: size.width * 0.20, y: bottom))
        path.addLine(to: CGPoint(x: size.width * 0.80, y: bottom))
        return path
    }

    private func hintLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }

    private var hint: String? {
        guard let scene else { return nil }
        if let y = scene.faceCenterY {
            if y > 0.58 { return "Pan image up" }
            if y < 0.42 { return "Pan image down" }
        }
        if let x = scene.faceCenterX {
            if x < 0.42 { return "Pan image right" }
            if x > 0.58 { return "Pan image left" }
        }
        if let height = scene.faceHeightPct {
            if height < 0.30 { return "Zoom in" }
            if height > 0.62 { return "Zoom out" }
        }
        return nil
    }
}

private struct SceneQualityPillsView: View {
    let scene: SceneMetrics?

    var body: some View {
        HStack(spacing: 6) {
            pill(label: "Vertical", value: verticalValue, good: verticalGood)
            pill(label: "Center", value: centerValue, good: centerGood)
            pill(label: "Zoom", value: zoomValue, good: zoomGood)
        }
    }

    private func pill(label: String, value: String, good: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color(for: good))
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
    }

    private func color(for good: Bool?) -> Color {
        guard let good else { return .secondary }
        return good ? .green : .yellow
    }

    private var verticalValue: String {
        guard let y = scene?.faceCenterY else { return "--" }
        let offset = Int(((y - 0.5) * 100).rounded())
        if abs(offset) < 2 { return "ok" }
        return offset < 0 ? "\(abs(offset))% high" : "\(offset)% low"
    }

    private var verticalGood: Bool? {
        guard let y = scene?.faceCenterY else { return nil }
        return (0.42...0.58).contains(y)
    }

    private var centerValue: String {
        guard let x = scene?.faceCenterX else { return "--" }
        let offset = Int(((x - 0.5) * 100).rounded())
        if abs(offset) < 2 { return "ok" }
        return offset < 0 ? "\(abs(offset))% L" : "\(offset)% R"
    }

    private var centerGood: Bool? {
        guard let x = scene?.faceCenterX else { return nil }
        return (0.42...0.58).contains(x)
    }

    private var zoomValue: String {
        guard let height = scene?.faceHeightPct else { return "--" }
        return "\(Int((height * 100).rounded()))%"
    }

    private var zoomGood: Bool? {
        guard let height = scene?.faceHeightPct else { return nil }
        return (0.30...0.62).contains(height)
    }
}
