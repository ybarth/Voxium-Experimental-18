import SwiftUI

struct ChainOfThoughtView: View {
    let contextStore: AccessibilityContextStore

    @State private var selectedSubTab: SubTab = .currentContext

    enum SubTab: String, CaseIterable {
        case currentContext = "Current Context"
        case contextHistory = "Context History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sub-tab picker
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch selectedSubTab {
            case .currentContext:
                currentContextPanel
            case .contextHistory:
                contextHistoryPanel
            }
        }
    }

    // MARK: - Current Context

    @ViewBuilder
    private var currentContextPanel: some View {
        if let snapshot = contextStore.currentContext {
            ScrollView {
                contextDetailView(snapshot)
                    .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No Context Captured",
                systemImage: "eye.slash",
                description: Text("Context will appear here when you start a recording.\nThe accessibility tree is read when you press the hotkey.")
            )
        }
    }

    // MARK: - Context History

    @ViewBuilder
    private var contextHistoryPanel: some View {
        if contextStore.history.isEmpty {
            ContentUnavailableView(
                "No Context History",
                systemImage: "clock",
                description: Text("Past accessibility contexts will accumulate here as you dictate in different apps.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(contextStore.history.count) of \(contextStore.maxHistoryCount) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Stepper(
                        "Max: \(contextStore.maxHistoryCount)",
                        value: Binding(
                            get: { contextStore.maxHistoryCount },
                            set: { contextStore.maxHistoryCount = $0 }
                        ),
                        in: 10...100,
                        step: 10
                    )
                    .font(.caption)
                    .fixedSize()

                    Button("Clear") {
                        contextStore.clearHistory()
                    }
                    .controlSize(.small)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Divider()

                List(contextStore.history) { snapshot in
                    DisclosureGroup {
                        contextDetailView(snapshot)
                    } label: {
                        historyRowLabel(snapshot)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Shared detail view

    private func contextDetailView(_ snapshot: AccessibilityContextSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // App identification
            Group {
                sectionHeader("Application")
                detailRow("App Name", value: snapshot.context.applicationName)
                detailRow("Bundle ID", value: snapshot.context.bundleIdentifier)
            }

            Divider()

            // Field classification
            Group {
                sectionHeader("Text Field")
                detailRow("Field Type", value: snapshot.context.fieldType.rawValue)
            }

            Divider()

            // Cursor context
            Group {
                sectionHeader("Cursor Context")
                detailRow("Text Before Cursor", value: snapshot.context.textBeforeCursor, isCode: true)
                detailRow("Text After Cursor", value: snapshot.context.textAfterCursor, isCode: true)
                detailRow("Selected Text", value: snapshot.context.selectedText, isCode: true)
                if let point = snapshot.context.cursorScreenPoint {
                    detailRow("Cursor Position", value: String(format: "(%.0f, %.0f)", point.x, point.y))
                } else {
                    detailRow("Cursor Position", value: nil)
                }
            }

            Divider()

            // Formatting
            Group {
                sectionHeader("Formatting")
                detailRow("Applied", value: snapshot.formattingApplied ?? "None")
            }

            // Timestamp
            Divider()
            HStack {
                Text("Captured at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.context.capturedAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func historyRowLabel(_ snapshot: AccessibilityContextSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconForFieldType(snapshot.context.fieldType))
                .foregroundStyle(colorForFieldType(snapshot.context.fieldType))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayName)
                    .font(.body)
                Text(snapshot.context.fieldType.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(snapshot.context.capturedAt, format: .dateTime.hour().minute().second())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func detailRow(_ label: String, value: String?, isCode: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            if let value, !value.isEmpty {
                if isCode {
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(4)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(value)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func iconForFieldType(_ type: AccessibilityContext.TextFieldType) -> String {
        switch type {
        case .plainText: return "text.cursor"
        case .richText: return "text.badge.star"
        case .codeEditor: return "chevron.left.forwardslash.chevron.right"
        case .searchField: return "magnifyingglass"
        case .urlBar: return "globe"
        case .terminal: return "terminal"
        case .chatMessage: return "bubble.left"
        case .unknown: return "questionmark.circle"
        case .noTextField: return "xmark.circle"
        }
    }

    private func colorForFieldType(_ type: AccessibilityContext.TextFieldType) -> Color {
        switch type {
        case .plainText: return .primary
        case .richText: return .blue
        case .codeEditor: return .green
        case .searchField: return .orange
        case .urlBar: return .purple
        case .terminal: return .green
        case .chatMessage: return .blue
        case .unknown: return .secondary
        case .noTextField: return .red
        }
    }
}
