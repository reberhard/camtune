import SwiftUI

/// Mirrors displayed text at appearance/change, including transient errors.
/// Transport failures are recorded independently even if the popover is closed.
struct DiagnosticText: View {
    private let text: String
    private let source: String
    init(_ text: String, file: String = #fileID, line: Int = #line) {
        self.text = text
        self.source = "\(file):\(line)"
    }
    var body: some View {
        Text(text)
            .onAppear { Diagnostics.shared.visible(text, source: source) }
            .onChange(of: text) { _, value in Diagnostics.shared.visible(value, source: source) }
    }
}
