import Foundation
import CoreAudio
import CoreMediaIO

/// Video-call network quality, reduced to the one number that predicts how a call feels:
/// jitter, the average change in delay from one packet to the next (RFC 3550 style).
///
/// Why jitter (gg-mini, 2026-11-19/20): bandwidth tested 50-166 Mbps against ~3 needed,
/// latency to Google's Meet servers 10-15 ms, packet loss 0% in every test. Jitter was the
/// number that moved (4-14 ms on a good morning, 22-37 ms with 190 ms spikes on a bad
/// afternoon) and matched Ryan's bad calls. Loss still overrides when it appears.
struct NetworkSample: Codable, Equatable, Sendable {
    let jitterMs: Double
    let latencyMs: Double
    let lossPct: Double
    let measuredAt: Date

    enum Level: String { case good, shaky, poor }

    var level: Level {
        if lossPct >= 5 || jitterMs >= 30 { return .poor }
        if lossPct >= 1 || jitterMs >= 10 { return .shaky }
        return .good
    }

    /// Visible words for the status card. Engineering detail stays in the log.
    var verdict: String {
        switch level {
        case .good: return "Good"
        case .shaky: return lossPct >= 1 ? "Shaky: some packets lost" : "Shaky: expect some freezes"
        case .poor: return lossPct >= 5 ? "Poor: packets being lost" : "Poor: audio may break up"
        }
    }

    var jitterLabel: String { "\(Int(jitterMs.rounded())) ms jitter" }
}

enum NetworkQualityService {
    /// Google's STUN anycast, the first hop of every Meet call; answers ICMP from Mexico City
    /// in ~10 ms. Resolved by name each time so an anycast change cannot strand the probe.
    static let probeHost = "stun.l.google.com"

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/camtune/network-quality.jsonl")
    }

    /// Read by the root job com.clawd.gg-mini-call-awdl (gg repo), which turns AWDL off while
    /// a call is live. Fresh only while Ojo keeps rewriting it; a stale file means "no call".
    static var callSignalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/camtune/call-signal.json")
    }

    static let maxLogBytes = 2_000_000

    static func measure(host: String = probeHost, count: Int = 20) async -> NetworkSample? {
        let output: String
        do {
            output = try await ShellRunner.run(
                executablePath: "/sbin/ping",
                arguments: ["-n", "-c", "\(count)", "-i", "0.2", "-t", "10", host],
                timeout: .seconds(15))
        } catch ShellError.nonZeroExit(2, _) {
            // ping exits 2 when no reply came back at all: 100% loss, not "unknown".
            return NetworkSample(jitterMs: 0, latencyMs: 0, lossPct: 100, measuredAt: Date())
        } catch {
            return nil
        }
        return parse(output)
    }

    /// Parses `ping -n` output: per-reply `time=` values and the summary loss line.
    static func parse(_ output: String, now: Date = Date()) -> NetworkSample? {
        var rtts: [Double] = []
        var loss: Double?
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "time=") {
                let rest = line[range.upperBound...]
                if let value = Double(rest.prefix { $0.isNumber || $0 == "." }) { rtts.append(value) }
            } else if line.contains("packet loss"), let pct = line.split(separator: ",").first(where: { $0.contains("packet loss") }) {
                loss = Double(pct.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." })
            }
        }
        guard let loss else { return nil }
        if rtts.isEmpty { return NetworkSample(jitterMs: 0, latencyMs: 0, lossPct: loss, measuredAt: now) }
        var jitter = 0.0
        if rtts.count > 1 {
            jitter = zip(rtts.dropFirst(), rtts).map { abs($0 - $1) }.reduce(0, +) / Double(rtts.count - 1)
        }
        let sorted = rtts.sorted()
        let median = sorted[sorted.count / 2]
        return NetworkSample(jitterMs: jitter, latencyMs: median, lossPct: loss, measuredAt: now)
    }

    static func append(_ sample: NetworkSample, inCall: Bool, to url: URL = logURL) {
        let row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: sample.measuredAt),
            "jitter_ms": (sample.jitterMs * 10).rounded() / 10,
            "latency_ms": (sample.latencyMs * 10).rounded() / 10,
            "loss_pct": sample.lossPct,
            "level": sample.level.rawValue,
            "in_call": inCall,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxLogBytes,
           let old = try? Data(contentsOf: url) {
            // Keep the newer half; a minute-by-minute log only needs recent weeks.
            let tail = old.suffix(maxLogBytes / 2)
            let cut = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[cut...]).write(to: url, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func writeCallSignal(inCall: Bool, to url: URL = callSignalURL, now: Date = Date()) {
        let row: [String: Any] = ["in_call": inCall, "updated_at": now.timeIntervalSince1970, "source": "ojo camera+microphone"]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Call detection

    /// A video call is the camera and the microphone both running. Ojo's own preview uses
    /// only the camera and dictation only the microphone, so neither alone counts.
    static func videoCallLikely() -> Bool { anyCameraRunning() && microphoneRunning() }

    static func microphoneRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr
        else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices {
            var running = UInt32(0)
            if CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }
}
