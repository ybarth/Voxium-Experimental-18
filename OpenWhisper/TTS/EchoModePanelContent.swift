import SwiftUI

/// Header-only view for the Echo Mode panel. The text content is handled
/// by a real NSTextView in EchoModeController (required for Speechify
/// text selection via Accessibility API).
struct EchoModePanelHeader: View {
    let timestamp: Date?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

            Text("Echo Mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)

            Spacer()

            if let timestamp {
                Text(relativeTime(from: timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        return "\(hours)h ago"
    }
}
