import Foundation
import Observation

struct DeviceObservation: Codable, Sendable {
    var on: Bool?
    var brightness: Int?
    var hue: Int?
    var saturation: Int?
    var temperature: Int?
    var position: Int?
    var moving: Bool?
    var control: String?
}

struct DeviceReceipt: Decodable, Sendable {
    let device: String
    let operation_id: String
    let status: String
    let observed: DeviceObservation?
    let observed_at: Double?
    let error: String?
}

struct ControlReceipt: Decodable, Sendable {
    let schema_version: Int
    let operation_id: String
    let status: String
    let devices: [DeviceReceipt]
}

struct RoomDevice: Sendable {
    var observation: DeviceObservation?
    var observedAt: Date?
    var pending: String?
    var error: String?
    var failed = false
    var operation: String?
}

@MainActor @Observable
final class RoomControlService {
    static let lightGroups = ["overheads": ["overhead-left", "overhead-right"],
        "cafe": ["cafe"], "pie": ["pie"],
        "all": ["overhead-left", "overhead-right", "cafe", "pie"]]
    static let curtainGroups = ["left": ["curtain-left"], "right": ["curtain-right"],
        "both": ["curtain-left", "curtain-right"]]
    var devices: [String: RoomDevice] = [:]
    var isRefreshing = false
    var intentGeneration = 0
    private var debounces: [String: Task<Void, Never>] = [:]
    private var started = false

    // Tests inject the transport; production always uses the same CLI contract.
    var transport: @Sendable (String, [String], Duration) async throws -> String = { script, args, timeout in
        try await ShellRunner.controller(executablePath: "/opt/homebrew/bin/python3",
            arguments: [script] + args, timeout: timeout)
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func members(_ target: String, curtains: Bool = false) -> [String] {
        (curtains ? Self.curtainGroups : Self.lightGroups)[target] ?? []
    }

    func summary(_ target: String, curtains: Bool = false) -> String {
        let ids = members(target, curtains: curtains)
        let rows = ids.map { devices[$0] ?? RoomDevice() }
        if let pending = rows.compactMap(\.pending).first { return pending }
        if rows.contains(where: { $0.failed }) { return "Not confirmed — retry or refresh" }
        guard rows.allSatisfy({ $0.observation != nil }) else { return "Unknown" }
        if curtains {
            return zip(ids, rows).map { id, row in
                let name = id == "curtain-left" ? "Left" : "Right"
                if row.observation?.moving == true { return "\(name): moving" }
                return "\(name): \(row.observation?.position.map { "\($0)%" } ?? "unknown")"
            }.joined(separator: " · ")
        }
        let on = rows.compactMap { $0.observation?.on }
        guard on.count == rows.count else { return "Unknown" }
        if on.allSatisfy({ !$0 }) { return "Off" }
        if on.allSatisfy({ $0 }) { return "On" }
        return "Mixed"
    }

    func brightness(_ target: String) -> Int? {
        let values = members(target).compactMap { devices[$0]?.observation?.brightness }
        guard values.count == members(target).count, Set(values).count == 1 else { return nil }
        return values.first
    }

    func errors(_ target: String, curtains: Bool = false) -> [String] {
        members(target, curtains: curtains).compactMap { id in
            devices[id]?.error.map { "\(id): \($0)" }
        }
    }

    func dismiss(_ target: String, curtains: Bool = false) {
        for id in members(target, curtains: curtains) { devices[id]?.error = nil }
    }

    func light(_ action: String, target: String, values: [String] = []) {
        intentGeneration += 1
        send(action, target: target, values: values, curtains: false)
    }

    func curtain(_ action: String, target: String, position: Int? = nil) {
        intentGeneration += 1
        send(action, target: target, values: position.map { [String($0)] } ?? [], curtains: true)
    }

    func adjust(target: String, hue: Int, saturation: Int, brightness: Int) {
        intentGeneration += 1
        let ids = members(target)
        let operation = UUID().uuidString
        let issued = String(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        for id in ids {
            debounces[id]?.cancel()
            devices[id, default: RoomDevice()].pending = "Adjusting…"
            devices[id, default: RoomDevice()].operation = operation
        }
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            self.send("adjust", target: target,
                values: [String(hue), String(saturation), String(brightness)], curtains: false,
                operationID: operation, issuedAt: issued)
        }
        for id in ids { debounces[id] = task }
    }

    private func send(_ action: String, target: String, values: [String], curtains: Bool,
                      operationID: String? = nil, issuedAt: String? = nil) {
        let ids = members(target, curtains: curtains)
        guard !ids.isEmpty else { return }
        let operation = operationID ?? UUID().uuidString
        let issued = issuedAt ?? String(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        for id in ids {
            debounces[id]?.cancel()
            debounces[id] = nil
            devices[id, default: RoomDevice()].operation = operation
            devices[id, default: RoomDevice()].pending = action == "stop" ? "Stopping…" :
                (curtains ? (action == "set" ? "Moving to \(values.first ?? "?")%…" : "\(action.capitalized)…") : "Applying…")
        }
        let args = [action] + values + [target, "--json", "--operation-id", operation, "--issued", issued]
        Task { await execute(args, ids: ids, operation: operation, curtains: curtains,
                             timeout: curtains && action != "stop" ? .seconds(120) : .seconds(20)) }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            async let lights: Void = refreshGroup(curtains: false)
            async let curtains: Void = refreshGroup(curtains: true)
            _ = await (lights, curtains)
            isRefreshing = false
        }
    }

    private func refreshGroup(curtains: Bool) async {
        let target = curtains ? "both" : "all"
        let ids = members(target, curtains: curtains).filter { devices[$0]?.pending == nil }
        guard !ids.isEmpty else { return }
        await execute(["status", target, "--json"], ids: ids, operation: nil,
                      curtains: curtains, timeout: .seconds(20))
    }

    private func execute(_ args: [String], ids: [String], operation: String?, curtains: Bool,
                         timeout: Duration) async {
        let generations = Dictionary(uniqueKeysWithValues: ids.map { ($0, devices[$0]?.operation ?? "") })
        func acceptsResult(_ id: String) -> Bool {
            accepts(id, operation: operation) && (operation != nil || (devices[id]?.operation ?? "") == generations[id])
        }
        let key = curtains ? "CAMTUNE_BLINDS_SCRIPT" : "CAMTUNE_LIGHT_SCRIPT"
        let name = curtains ? "office-blinds.py" : "office-lights.py"
        let script = ProcessInfo.processInfo.environment[key] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("gg/scripts/\(name)").path
        do {
            let output = try await transport(script, args, timeout)
            let receipt = try JSONDecoder().decode(ControlReceipt.self, from: Data(output.utf8))
            guard receipt.schema_version == 1, !receipt.devices.isEmpty,
                  operation == nil || receipt.operation_id == operation else { throw CocoaError(.fileReadCorruptFile) }
            for id in ids where acceptsResult(id) {
                guard let row = receipt.devices.first(where: { $0.device == id }),
                      row.operation_id == receipt.operation_id else { throw CocoaError(.fileReadCorruptFile) }
                devices[id, default: RoomDevice()].pending = nil
                if row.status == "confirmed", let observed = row.observed, let at = row.observed_at {
                    guard curtains ? observed.control != nil : observed.on != nil else { throw CocoaError(.fileReadCorruptFile) }
                    devices[id, default: RoomDevice()].observation = observed
                    devices[id, default: RoomDevice()].observedAt = Date(timeIntervalSince1970: at)
                    devices[id, default: RoomDevice()].failed = false
                    devices[id, default: RoomDevice()].error = nil
                } else {
                    devices[id, default: RoomDevice()].failed = true
                    devices[id, default: RoomDevice()].error = row.error ?? "Result not confirmed"
                }
            }
        } catch {
            for id in ids where acceptsResult(id) {
                devices[id, default: RoomDevice()].pending = nil
                devices[id, default: RoomDevice()].failed = true
                devices[id, default: RoomDevice()].error = error.localizedDescription
            }
        }
    }

    private func accepts(_ id: String, operation: String?) -> Bool {
        if let operation { return devices[id]?.operation == operation }
        return devices[id]?.pending == nil
    }
}
