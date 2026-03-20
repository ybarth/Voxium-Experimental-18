import SwiftUI
import os.log

struct LogsView: View {
    let logger: TranscriptionLogger
    @State private var selectedCategory: LogCategory?
    @State private var searchText = ""

    private var filteredEntries: [LogEntry] {
        var result = logger.entries
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Picker("Category", selection: $selectedCategory) {
                    Text("All").tag(nil as LogCategory?)
                    ForEach(LogCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(cat as LogCategory?)
                    }
                }
                .frame(width: 140)

                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear") {
                    logger.clearEntries()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text",
                    description: Text("Log entries will appear here as the app runs.")
                )
            } else {
                ScrollViewReader { proxy in
                    List(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                    .listStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .onChange(of: logger.entries.count) {
                        if let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(entry.category.rawValue.prefix(5).uppercased())
                .foregroundStyle(categoryColor(entry.category))
                .frame(width: 50, alignment: .leading)

            Text(entry.levelString)
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 40, alignment: .leading)

            Text(entry.message)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func categoryColor(_ cat: LogCategory) -> Color {
        switch cat {
        case .general: return .primary
        case .download: return .blue
        case .server: return .purple
        case .transcription: return .green
        case .model: return .orange
        case .tts: return .cyan
        }
    }

    private func levelColor(_ level: OSLogType) -> Color {
        switch level {
        case .error, .fault: return .red
        case .debug: return .secondary
        default: return .primary
        }
    }
}
