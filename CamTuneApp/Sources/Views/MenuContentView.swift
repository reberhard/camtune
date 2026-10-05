import SwiftUI

struct MenuContentView: View {
    @Bindable var state: AppState
    @State private var page: Page = .main

    private enum Page { case main, more }

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .main:
                mainPage
                    .transition(.opacity)
            case .more:
                MoreToolsView(state: state) {
                    withAnimation(Ojo.spring) { page = .main }
                }
                .transition(.opacity)
            }
            footer
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

    // MARK: Main page

    private var mainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StatusHeroView(state: state)

                if let error = state.error {
                    errorBanner(error)
                }

                cameraSection

                RoomView(room: state.room)
            }
            .padding(.horizontal, Ojo.Space.page)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
        // The preview is the point of the app, so it is always on while this page
        // is showing, and off when the popover closes or you open More tools.
        .onAppear { startPreviewIfReady() }
        // The camera is discovered after the popover first appears; start once it is known.
        // Starting earlier raises a spurious "could not be matched" error.
        .onChange(of: state.currentDevice?.name) { _, _ in startPreviewIfReady() }
        .onDisappear {
            if !state.isOptimizing && !state.isChecking && !state.isCalibrating
                && !state.isDeepRepairing && !state.isMeetingReadyRunning {
                state.stopPreview()
            }
        }
    }

    private func startPreviewIfReady() {
        guard state.currentDevice != nil else { return }
        state.startPreview()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            DiagnosticText(message)
                .font(Ojo.Style.subtitle)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            Spacer(minLength: 0)
            Button { state.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(OjoIconButtonStyle())
                .accessibilityLabel("Dismiss message")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    private var cameraSection: some View {
        OjoCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                QuickFramingControlsView(state: state)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if !state.canAdjustComposition {
                    DiagnosticText("Pan and tilt need more zoom, or aren't calibrated for this camera yet.")
                        .font(Ojo.Style.note).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Ojo.Radius.card, style: .continuous))
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Image(systemName: "web.camera")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                DiagnosticText(state.currentDevice?.name ?? "No camera found")
                    .font(Ojo.Style.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { state.room.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .symbolEffect(.pulse, isActive: state.room.isRefreshing)
                }
                .buttonStyle(OjoIconButtonStyle())
                .disabled(state.room.isRefreshing)
                .help("Refresh lights and curtains")
                .accessibilityLabel("Refresh lights and curtains")
                .accessibilityIdentifier("room-refresh")
                Menu {
                    Button("More tools…") { withAnimation(Ojo.spring) { page = .more } }
                    Toggle(AppState.observeChecksEnabled ? "Auto-check (observe only)" : "Auto-check (needs call validation)",
                           isOn: $state.autoCheckEnabled)
                        .disabled(!AppState.observeChecksEnabled)
                    Divider()
                    Button("Quit Ojo") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                .accessibilityIdentifier("more-menu")
            }
            .padding(.horizontal, Ojo.Space.page)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let session = state.captureSession {
            CameraPreviewView(session: session)
                .frame(maxWidth: .infinity)
                .frame(height: 207)
                .overlay {
                    CompositionOverlayView(scene: state.lastScene)
                }
                .overlay(alignment: .topTrailing) {
                    if let activityLabel {
                        ActivityBadge(text: activityLabel)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    SceneQualityPillsView(scene: state.lastScene)
                        .padding(10)
                }
        } else {
            Rectangle()
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 207)
                .overlay {
                    PreviewUnavailableView(
                        title: state.error == nil ? "Starting the camera" : "Camera unavailable",
                        message: state.error ?? "Starting the camera…",
                        systemImage: state.error == nil ? "video" : "camera.badge.exclamationmark"
                    )
                }
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
        HStack(spacing: 6) {
            FrameButton(icon: "arrow.left", help: "Move the camera image left") {
                await state.nudgeComposition(dx: -state.compositionStep, dy: 0)
            }
            FrameButton(icon: "arrow.up", help: "Move the camera image up") {
                await state.nudgeComposition(dx: 0, dy: state.compositionStep)
            }
            FrameButton(icon: "arrow.down", help: "Move the camera image down") {
                await state.nudgeComposition(dx: 0, dy: -state.compositionStep)
            }
            FrameButton(icon: "arrow.right", help: "Move the camera image right") {
                await state.nudgeComposition(dx: state.compositionStep, dy: 0)
            }
            Spacer(minLength: 4)
            FrameButton(icon: "minus.magnifyingglass", help: "Zoom out") {
                await state.nudgeZoom(delta: -20)
            }
            FrameButton(icon: "plus.magnifyingglass", help: "Zoom in") {
                await state.nudgeZoom(delta: 20)
            }
            Spacer(minLength: 4)
            FrameButton(icon: "arrow.uturn.backward", help: "Undo the last pan or tilt adjustment",
                        disabled: state.lastComposition == nil) {
                await state.undoCompositionNudge()
            }
        }
        .disabled(state.currentDevice == nil)
    }
}

private struct FrameButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 32)
        }
        .buttonStyle(FrameButtonStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FrameButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ActivityBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "sparkles")
            .font(Ojo.Style.note)
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
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            DiagnosticText(title)
                .font(Ojo.Style.rowTitle)
            DiagnosticText(message)
                .font(Ojo.Style.rowCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
        }
    }
}


// Camera sliders and calibration/advanced controls. Lights and curtains
// moved out of this disclosure (2026-09-03) onto the main popover screen —
// see MenuContentView.body. This stays collapsed by default because Ryan
// should not need to open it before an ordinary call.
private struct MoreToolsView: View {
    @Bindable var state: AppState
    let back: () -> Void
    @State private var section: FineTuneSection = .camera

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        DiagnosticText("Back")
                    }
                    .font(Ojo.Style.chip)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("more-back")
                Spacer()
                DiagnosticText("More tools")
                    .font(Ojo.Style.heading)
                Spacer()
                DiagnosticText("\(state.panTiltText) · \(state.zoomText)")
                    .font(Ojo.Style.note).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Ojo.Space.page)
            .padding(.top, Ojo.Space.page)

            Picker("", selection: $section) {
                ForEach(FineTuneSection.allCases, id: \.self) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Ojo.Space.page)
            .padding(.top, 12)

            ScrollView {
                Group {
                    switch section {
                    case .camera:
                        CameraControlsView(state: state)
                    case .advanced:
                        AdvancedView(state: state)
                    }
                }
                .padding(.horizontal, Ojo.Space.page)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private enum FineTuneSection: CaseIterable {
        case camera
        case advanced

        var title: String {
            switch self {
            case .camera: return "Camera"
            case .advanced: return "Tools"
            }
        }

        var icon: String {
            switch self {
            case .camera: return "camera"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }
}

private struct AdvancedView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticText(state.notificationStatus)
                .font(Ojo.Style.note)
                .foregroundStyle(.secondary)
            DiagnosticText(state.browserAutomationStatus)
                .font(Ojo.Style.note)
                .foregroundStyle(.secondary)
            DiagnosticText(state.callActivityReason)
                .font(Ojo.Style.note).foregroundStyle(.secondary)

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
        DiagnosticText(text)
            .font(Ojo.Style.note)
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
            DiagnosticText(label)
                .foregroundStyle(.secondary)
            DiagnosticText(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
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
