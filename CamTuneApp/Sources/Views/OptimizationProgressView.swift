import SwiftUI

struct OptimizationProgressView: View {
    let round: Int
    let total: Int
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Round \(round)/\(total)")
                    .font(.caption)
                    .fontWeight(.medium)
                if let message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
