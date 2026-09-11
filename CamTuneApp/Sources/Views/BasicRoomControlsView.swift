import SwiftUI

struct BasicLightsView: View {
    @Bindable var room: RoomControlService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Power and brightness").font(.caption)
                Spacer()
                Button("Refresh") { room.refresh() }
                    .disabled(room.isRefreshing)
                    .accessibilityIdentifier("room-refresh")
            }
            ForEach(["overheads", "cafe", "pie"], id: \.self) { target in
                BasicLightRow(room: room, target: target)
            }
            VStack(alignment: .leading) {
                Text("Scenes — set power and color").font(.caption2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 95))]) {
                    ForEach(LightService.scenes) { scene in
                        Button(scene.name) { room.light(scene.id, target: scene.id == "reading" ? "pie" : "all") }
                            .accessibilityIdentifier("scene-\(scene.id)")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct BasicLightRow: View {
    @Bindable var room: RoomControlService
    let target: String
    @State private var level = 50.0
    @State private var hue = 30.0
    @State private var saturation = 5.0
    private var name: String { target == "overheads" ? "Overhead Lights" : target == "cafe" ? "Café Lamp" : "Floor Lamp" }
    private var enabled: Bool { room.summary(target) == "On" || room.summary(target) == "Adjusting…" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.caption).fontWeight(.medium)
                Spacer()
                Text(room.summary(target)).font(.caption2)
                    .accessibilityIdentifier("\(target)-status")
                Button("On") { room.light("on", target: target) }
                    .accessibilityIdentifier("\(target)-on")
                Button("Off") { room.light("off", target: target) }
                    .accessibilityIdentifier("\(target)-off")
            }
            HStack {
                Slider(value: $level, in: 1...100, step: 1)
                    .accessibilityLabel("\(name) brightness")
                    .accessibilityIdentifier("\(target)-brightness")
                    .disabled(!enabled)
                    .onChange(of: level) { _, _ in adjust() }
                Text(room.brightness(target).map { "\($0)%" } ?? "—").font(.caption2)
            }
            DisclosureGroup("Color") {
                Slider(value: $hue, in: 0...360, step: 1).accessibilityLabel("\(name) hue")
                    .onChange(of: hue) { _, _ in adjust() }
                Slider(value: $saturation, in: 0...100, step: 1).accessibilityLabel("\(name) saturation")
                    .onChange(of: saturation) { _, _ in adjust() }
            }.font(.caption2).disabled(!enabled)
            ForEach(room.errors(target), id: \.self) { message in
                Text(message).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !room.errors(target).isEmpty {
                Button("Dismiss error") { room.dismiss(target) }
            }
        }
        .onAppear { synchronize() }
        .onChange(of: room.devices[target == "overheads" ? "overhead-left" : target]?.observedAt) { _, _ in synchronize() }
    }

    private func synchronize() {
        let id = target == "overheads" ? "overhead-left" : target
        if let observed = room.devices[id]?.observation {
            level = Double(observed.brightness ?? 50)
            hue = Double(observed.hue ?? 30)
            saturation = Double(observed.saturation ?? 5)
        }
    }

    private func adjust() {
        guard enabled else { return }
        let id = target == "overheads" ? "overhead-left" : target
        let observed = room.devices[id]?.observation
        guard Int(level) != observed?.brightness || Int(hue) != observed?.hue || Int(saturation) != observed?.saturation else { return }
        room.adjust(target: target, hue: Int(hue), saturation: Int(saturation), brightness: Int(level))
    }
}

struct BasicCurtainsView: View {
    @Bindable var room: RoomControlService
    @State private var target = "both"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Curtain", selection: $target) {
                Text("Left").tag("left")
                Text("Right").tag("right")
                Text("Both").tag("both")
            }.pickerStyle(.segmented)
            Text(room.summary(target, curtains: true)).font(.caption)
                .accessibilityIdentifier("curtain-status")
            HStack {
                Button("Open") { room.curtain("open", target: target) }
                    .accessibilityIdentifier("curtain-open")
                Button("Close") { room.curtain("close", target: target) }
                    .accessibilityIdentifier("curtain-close")
                Button("Stop") { room.curtain("stop", target: target) }
                    .accessibilityIdentifier("curtain-stop")
            }
            HStack {
                ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                    Button("\(percent)%") { room.curtain("set", target: target, position: percent) }
                        .accessibilityIdentifier("curtain-position-\(percent)")
                }
            }
            ForEach(room.errors(target, curtains: true), id: \.self) { message in
                Text(message).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !room.errors(target, curtains: true).isEmpty {
                Button("Dismiss error") { room.dismiss(target, curtains: true) }
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }
}
