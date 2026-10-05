import SwiftUI

/// Scenes, lights and curtains. Everything here talks to RoomControlService
/// exactly the way the old controls did; only the presentation changed.
struct RoomView: View {
    @Bindable var room: RoomControlService

    var body: some View {
        VStack(alignment: .leading, spacing: Ojo.Space.gap) {
            ScenesGrid(room: room)
            LightsCard(room: room)
            CurtainsCard(room: room)
        }
    }
}

// MARK: - Scenes

private struct ScenesGrid: View {
    @Bindable var room: RoomControlService
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(LightService.scenes) { scene in
                SceneTile(scene: scene) {
                    room.light(scene.id, target: scene.id == "reading" ? "pie" : "all")
                }
            }
        }
    }
}

private struct SceneTile: View {
    let scene: LightScene
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: scene.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Ojo.sceneTint(scene.id))
                    .frame(height: 24)
                DiagnosticText(scene.name)
                    .font(Ojo.Style.tile)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.95 : 0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .strokeBorder(Ojo.sceneTint(scene.id).opacity(hovering ? 0.55 : 0.0), lineWidth: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Ojo.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .accessibilityLabel(scene.name)
        .accessibilityIdentifier("scene-\(scene.id)")
    }
}

// MARK: - Lights

private struct LightsCard: View {
    @Bindable var room: RoomControlService
    private let targets = ["overheads", "cafe", "pie"]

    var body: some View {
        OjoCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(targets.enumerated()), id: \.element) { index, target in
                    LightRow(room: room, target: target)
                    if index < targets.count - 1 {
                        Divider().padding(.leading, 60).opacity(0.7)
                    }
                }
            }
        }
    }
}

private struct LightRow: View {
    @Bindable var room: RoomControlService
    let target: String
    @State private var expanded = false
    @State private var level = 50.0
    @State private var hue = 30.0
    @State private var saturation = 5.0

    private var name: String { target == "overheads" ? "Overhead Lights" : target == "cafe" ? "Café Lamp" : "Floor Lamp" }
    private var icon: String { target == "overheads" ? "lightbulb.2.fill" : target == "cafe" ? "lamp.desk.fill" : "lamp.floor.fill" }
    private var isOn: Bool { room.summary(target) == "On" || room.summary(target) == "Adjusting…" }
    private var observedID: String { target == "overheads" ? "overhead-left" : target }

    private var caption: String {
        let summary = room.summary(target)
        switch summary {
        case "On":
            return room.brightness(target).map { "On · \($0)%" } ?? "On"
        case "Adjusting…": return "Adjusting…"
        case "Off": return "Off"
        case "Mixed": return "One on, one off"
        case "Unknown": return "Checking…"
        default: return summary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(Ojo.spring) { expanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isOn ? Color.yellow : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill((isOn ? Color.yellow : Color.primary).opacity(0.14))
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            DiagnosticText(name)
                                .font(Ojo.Style.rowTitle)
                                .foregroundStyle(.primary)
                            DiagnosticText(caption)
                                .font(Ojo.Style.rowCaption)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("\(target)-status")
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) details")

                if room.summary(target) == "Unknown" {
                    // Not read back yet: say so with a spinner, never an empty switch.
                    ProgressView().controlSize(.small).frame(width: 38)
                } else {
                    Toggle("", isOn: Binding(
                        get: { isOn },
                        set: { room.light($0 ? "on" : "off", target: target) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(name)
                    .accessibilityIdentifier("\(target)-power")
                }
            }
            .padding(.horizontal, Ojo.Space.card)
            .padding(.vertical, 8)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    labelled("Brightness", value: "\(Int(level))%") {
                        GradientSlider(value: $level, range: 1...100,
                                       colors: [Color.primary.opacity(0.18), Color.yellow.opacity(0.9)],
                                       label: "\(name) brightness") { adjust() }
                            .accessibilityIdentifier("\(target)-brightness")
                    }
                    labelled("Color", value: nil) {
                        GradientSlider(value: $hue, range: 0...360, colors: Color.hueSpectrum,
                                       label: "\(name) color") { adjust() }
                    }
                    labelled("Saturation", value: "\(Int(saturation))%") {
                        GradientSlider(value: $saturation, range: 0...100,
                                       colors: [Color.white, Color(hue: hue / 360, saturation: 0.9, brightness: 1)],
                                       label: "\(name) saturation") { adjust() }
                    }
                }
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.45)
                .padding(.horizontal, Ojo.Space.card)
                .padding(.bottom, 14)
                .padding(.leading, 44)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ForEach(room.errors(target), id: \.self) { message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    DiagnosticText(message)
                        .font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { room.dismiss(target) } label: { Image(systemName: "xmark") }
                        .buttonStyle(OjoIconButtonStyle())
                        .accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, Ojo.Space.card)
                .padding(.bottom, 10)
            }
        }
        .onAppear { synchronize() }
        .onChange(of: room.devices[observedID]?.observedAt) { _, _ in synchronize() }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ title: String, value: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DiagnosticText(title).font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                Spacer()
                if let value {
                    DiagnosticText(value).font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            content()
        }
    }

    private func synchronize() {
        if let observed = room.devices[observedID]?.observation {
            level = Double(observed.brightness ?? 50)
            hue = Double(observed.hue ?? 30)
            saturation = Double(observed.saturation ?? 5)
        }
    }

    private func adjust() {
        guard isOn else { return }
        let observed = room.devices[observedID]?.observation
        guard Int(level) != observed?.brightness || Int(hue) != observed?.hue || Int(saturation) != observed?.saturation else { return }
        room.adjust(target: target, hue: Int(hue), saturation: Int(saturation), brightness: Int(level))
    }
}

// MARK: - Curtains

private struct CurtainsCard: View {
    @Bindable var room: RoomControlService
    @State private var expanded = false
    @State private var left = 100.0
    @State private var right = 100.0

    private enum Preset: CaseIterable {
        case open, half, closed
        var title: String { self == .open ? "Open" : self == .half ? "Half" : "Closed" }
        var icon: String { self == .open ? "blinds.horizontal.open" : self == .half ? "blinds.horizontal.closed" : "blinds.horizontal.closed" }
        var identifier: String { self == .open ? "curtain-open" : self == .half ? "curtain-position-50" : "curtain-close" }
    }

    private var positions: [Int?] {
        ["curtain-left", "curtain-right"].map { room.devices[$0]?.observation?.position }
    }
    private var moving: Bool {
        ["curtain-left", "curtain-right"].contains { room.devices[$0]?.observation?.moving == true }
            || room.devices["curtain-left"]?.pending != nil || room.devices["curtain-right"]?.pending != nil
    }

    private var current: Preset? {
        let known = positions.compactMap { $0 }
        guard known.count == 2, !moving else { return nil }
        if known.allSatisfy({ $0 >= 90 }) { return .open }
        if known.allSatisfy({ $0 <= 10 }) { return .closed }
        if known.allSatisfy({ abs($0 - 50) <= 12 }) { return .half }
        return nil
    }

    private var caption: String {
        if moving { return "Moving…" }
        if let current { return current.title == "Half" ? "Half open" : current.title }
        let known = positions
        guard known.allSatisfy({ $0 != nil }) else { return "Checking…" }
        return "Left \(known[0] ?? 0)% · Right \(known[1] ?? 0)%"
    }

    var body: some View {
        OjoCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "blinds.horizontal.closed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.teal)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.teal.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        DiagnosticText("Curtains")
                            .font(Ojo.Style.rowTitle)
                        DiagnosticText(caption)
                            .font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("curtain-status")
                    }
                    Spacer(minLength: 0)
                    if moving {
                        Button { room.curtain("stop", target: "both") } label: {
                            DiagnosticText("Stop")
                                .font(Ojo.Style.chipSmall)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.16)))
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("curtain-stop")
                    }
                    Button {
                        withAnimation(Ojo.spring) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(OjoIconButtonStyle())
                    .accessibilityLabel("Left and right curtain controls")
                }
                .padding(.horizontal, Ojo.Space.card)
                .padding(.top, 10)

                HStack(spacing: 8) {
                    ForEach(Preset.allCases, id: \.self) { preset in
                        Button { apply(preset) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: preset.icon).font(.system(size: 12, weight: .medium))
                                DiagnosticText(preset.title)
                            }
                            .font(Ojo.Style.chip)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(current == preset ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(current == preset ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(moving)
                        .accessibilityIdentifier(preset.identifier)
                    }
                }
                .animation(.snappy(duration: 0.2), value: current)
                .padding(.horizontal, Ojo.Space.card)
                .padding(.top, 8)
                .padding(.bottom, 10)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        sideSlider("Left curtain", value: $left, target: "left")
                        sideSlider("Right curtain", value: $right, target: "right")
                    }
                    .padding(.horizontal, Ojo.Space.card)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ForEach(room.errors("both", curtains: true), id: \.self) { message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        DiagnosticText(message)
                            .font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { room.dismiss("both", curtains: true) } label: { Image(systemName: "xmark") }
                            .buttonStyle(OjoIconButtonStyle())
                            .accessibilityLabel("Dismiss message")
                    }
                    .padding(.horizontal, Ojo.Space.card)
                    .padding(.bottom, 10)
                }
            }
        }
        .onAppear { synchronize() }
        .onChange(of: room.devices["curtain-left"]?.observedAt) { _, _ in synchronize() }
        .onChange(of: room.devices["curtain-right"]?.observedAt) { _, _ in synchronize() }
    }

    @ViewBuilder
    private func sideSlider(_ title: String, value: Binding<Double>, target: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DiagnosticText(title).font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                Spacer()
                DiagnosticText("\(Int(value.wrappedValue))%").font(Ojo.Style.rowCaption).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            // Commit on release: dragging must not send a motor command per pixel.
            CurtainSlider(value: value, label: title) { room.curtain("set", target: target, position: Int(value.wrappedValue)) }
        }
    }

    private func apply(_ preset: Preset) {
        switch preset {
        case .open: room.curtain("open", target: "both")
        case .closed: room.curtain("close", target: "both")
        case .half: room.curtain("set", target: "both", position: 50)
        }
    }

    private func synchronize() {
        if let value = room.devices["curtain-left"]?.observation?.position { left = Double(value) }
        if let value = room.devices["curtain-right"]?.observation?.position { right = Double(value) }
    }
}

/// Like GradientSlider but only reports when the drag ends.
private struct CurtainSlider: View {
    @Binding var value: Double
    let label: String
    let onCommit: () -> Void

    var body: some View {
        GradientSlider(value: $value, range: 0...100,
                       colors: [Color.primary.opacity(0.16), Color.teal.opacity(0.85)],
                       label: label) {}
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { _ in onCommit() }
            )
    }
}
