import SwiftUI

struct EchoModePanelContent: View {
    let entry: TranscriptionEntry?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)

                Text("Echo Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Spacer()

                if let entry {
                    Text(relativeTime(from: entry.date))
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
            .background(.ultraThinMaterial.opacity(0.5))

            Divider()

            // Text content
            if let entry {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                Text("Waiting for transcription...")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        )
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
