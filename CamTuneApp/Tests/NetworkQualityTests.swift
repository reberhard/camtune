import Foundation
import Testing
@testable import OjoApp

private let goodPing = """
PING stun.l.google.com (74.125.250.129): 56 data bytes
64 bytes from 74.125.250.129: icmp_seq=0 ttl=117 time=10.0 ms
64 bytes from 74.125.250.129: icmp_seq=1 ttl=117 time=12.0 ms
64 bytes from 74.125.250.129: icmp_seq=2 ttl=117 time=11.0 ms
64 bytes from 74.125.250.129: icmp_seq=3 ttl=117 time=13.0 ms

--- stun.l.google.com ping statistics ---
4 packets transmitted, 4 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 10.0/11.5/13.0/1.1 ms
"""

@Test func jitterIsMeanChangeBetweenConsecutiveReplies() throws {
    let sample = try #require(NetworkQualityService.parse(goodPing))
    // |12-10| + |11-12| + |13-11| = 5 over 3 steps
    #expect(abs(sample.jitterMs - 5.0 / 3.0) < 0.001)
    #expect(sample.latencyMs == 12.0)
    #expect(sample.lossPct == 0)
    #expect(sample.level == .good)
    #expect(sample.verdict == "Good")
}

@Test func spikyLinkReadsShakyAndThenPoor() {
    let shaky = NetworkSample(jitterMs: 22, latencyMs: 15, lossPct: 0, measuredAt: Date())
    #expect(shaky.level == .shaky)
    #expect(shaky.verdict == "Shaky: expect some freezes")
    let poor = NetworkSample(jitterMs: 45, latencyMs: 15, lossPct: 0, measuredAt: Date())
    #expect(poor.level == .poor)
    #expect(poor.jitterLabel == "45 ms jitter")
}

@Test func packetLossOverridesALowJitter() {
    let lossy = NetworkSample(jitterMs: 2, latencyMs: 10, lossPct: 6, measuredAt: Date())
    #expect(lossy.level == .poor)
    #expect(lossy.verdict == "Poor: packets being lost")
    let someLoss = NetworkSample(jitterMs: 2, latencyMs: 10, lossPct: 2, measuredAt: Date())
    #expect(someLoss.level == .shaky)
}

@Test func outputWithoutSummaryIsNotAReading() {
    #expect(NetworkQualityService.parse("ping: cannot resolve stun.l.google.com: Unknown host") == nil)
}

@Test func logRowsAppendAndTheFileStaysBounded() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("network-quality.jsonl")
    let sample = NetworkSample(jitterMs: 6.04, latencyMs: 10.2, lossPct: 0, measuredAt: Date(timeIntervalSince1970: 0))
    NetworkQualityService.append(sample, inCall: true, to: url)
    NetworkQualityService.append(sample, inCall: false, to: url)
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("\"in_call\":true"))
    #expect(lines[0].contains("\"jitter_ms\":6"))
    // Oversized log keeps only its newer half, starting on a whole line.
    let filler = String(repeating: "{\"x\":1}\n", count: NetworkQualityService.maxLogBytes / 8 + 10)
    try filler.write(to: url, atomically: true, encoding: .utf8)
    NetworkQualityService.append(sample, inCall: false, to: url)
    let trimmed = try Data(contentsOf: url)
    #expect(trimmed.count < NetworkQualityService.maxLogBytes)
    #expect(String(decoding: trimmed.prefix(7), as: UTF8.self) == "{\"x\":1}")
}

@Test func callSignalIsFreshJSONTheRootJobCanRead() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    NetworkQualityService.writeCallSignal(inCall: true, to: url, now: Date(timeIntervalSince1970: 100))
    let row = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(row["in_call"] as? Bool == true)
    #expect(row["updated_at"] as? Double == 100)
}

@Test func engineeringErrorsBecomePlainWords() {
    let raw = "Command failed (exit 1): No cameras detected. Is your webcam connected?\n"
    #expect(AppState.plainError(raw, usingIPhone: true) == "Ojo can't reach the iPhone camera. Wake the phone and check it's on its mount.")
    #expect(AppState.plainError(raw, usingIPhone: false) == "Ojo can't see a camera. Check the webcam is plugged in.")
    #expect(AppState.plainError("Command failed (exit 3): bulb offline", usingIPhone: true) == "bulb offline")
}
