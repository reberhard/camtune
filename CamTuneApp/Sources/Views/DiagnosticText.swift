import SwiftUI

/// Mirrors displayed text at appearance/change, including transient errors.
/// Transport failures are recorded independently even if the popover is closed.
/// `live: true` is for values that change every second (camera meters): they are
/// rendered the same way but not journaled, because they flooded real errors
/// out of the 2 MB journal within the hour (2026-11-16).
struct DiagnosticText: View {
    private let text: String
    private let source: String
    private let live: Bool
    init(_ text: String, live: Bool = false, file: String = #fileID, line: Int = #line) {
        self.text = text
        self.source = "\(file):\(line)"
        self.live = live
    }
    var body: some View {
        Text(text)
            .onAppear { if !live { Diagnostics.shared.visible(text, source: source) } }
            .onChange(of: text) { _, value in if !live { Diagnostics.shared.visible(value, source: source) } }
    }
}
