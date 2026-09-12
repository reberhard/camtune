import Foundation
import Observation

@MainActor @Observable
final class CameraControlService {
    var pending: Set<String> = []
    var errors: [String: String] = [:]
    var observed = UVCSettings()
    private var generations: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var transport: @Sendable (CameraDevice, UVCSettings, UUID, Int64) async throws -> UVCSettings = { device, changes, operation, issued in
        try await UVCService.transaction(changes, vendor: device.vendor, product: device.product,
                                         operation: operation, issued: issued)
    }

    func set(_ control: String, value: UVCSettings.SettingValue, device: CameraDevice,
             completion: @escaping @MainActor (UVCSettings) -> Void) {
        let operation = UUID()
        let issued = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        generations[control] = operation
        tasks[control]?.cancel()
        pending.insert(control)
        tasks[control] = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard generations[control] == operation else { return }
                let result = try await transport(device, UVCSettings(values: [control: value]), operation, issued)
                guard generations[control] == operation else { return }
                guard result.values[control] == value else { throw CocoaError(.fileReadCorruptFile) }
                // Do not copy unrelated values from an older device snapshot.
                observed.values[control] = result.values[control]
                completion(UVCSettings(values: [control: value]))
                errors[control] = nil
            } catch is CancellationError {
                if generations[control] == operation { errors[control] = "Camera change cancelled — refresh" }
            } catch {
                if generations[control] == operation { errors[control] = error.localizedDescription }
            }
            if generations[control] == operation { pending.remove(control); tasks[control] = nil }
        }
    }
}
