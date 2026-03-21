import SwiftUI

struct APIKeysSettingsView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(CommercialKeyManager.Service.allCases, id: \.self) { service in
                APIKeyServiceSection(service: service, keyManager: appState.commercialKeyManager)
            }
        }
    }
}

struct APIKeyServiceSection: View {
    let service: CommercialKeyManager.Service
    let keyManager: CommercialKeyManager

    @State private var keyInput: String = ""
    @State private var isEditing: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResult: CommercialKeyManager.TestResult?
    @State private var testDepth: CommercialKeyManager.ValidationDepth = .guided
    @State private var saveError: String?

    private var maskedKey: String? {
        keyManager.maskedKey(for: service)
    }

    private var isFormatValid: Bool {
        keyInput.isEmpty ? false : keyManager.validateKeyFormat(keyInput, for: service)
    }

    var body: some View {
        GroupBox(service.displayName) {
            VStack(alignment: .leading, spacing: 10) {

                // Current key status
                if let masked = maskedKey, !isEditing {
                    HStack {
                        Text(masked)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change") {
                            isEditing = true
                            keyInput = ""
                        }
                        .controlSize(.small)
                        Button("Remove") {
                            keyManager.deleteKey(for: service)
                            testResult = nil
                        }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                } else {
                    // Key input
                    HStack {
                        SecureField("Paste API key...", text: $keyInput)
                            .font(.system(.body, design: .monospaced))

                        // Format validation indicator
                        if !keyInput.isEmpty {
                            if isFormatValid {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    HStack {
                        Button("Save Key") {
                            guard isFormatValid else { return }
                            do {
                                try keyManager.saveKey(keyInput, for: service)
                                keyInput = ""
                                isEditing = false
                                saveError = nil
                                testResult = nil
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                        .disabled(!isFormatValid)
                        .controlSize(.small)

                        if isEditing {
                            Button("Cancel") {
                                isEditing = false
                                keyInput = ""
                                saveError = nil
                            }
                            .controlSize(.small)
                        }

                        if let url = service.dashboardURL {
                            Spacer()
                            Link("Get API Key", destination: url)
                                .font(.caption)
                        }
                    }

                    if let error = saveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Connection test (only when key is saved)
                if keyManager.hasKey(for: service) {
                    Divider()

                    HStack {
                        Picker("Depth", selection: $testDepth) {
                            ForEach(CommercialKeyManager.ValidationDepth.allCases, id: \.self) { depth in
                                Text(depth.displayName).tag(depth)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Button(isTesting ? "Testing..." : "Test Connection") {
                            guard !isTesting else { return }
                            isTesting = true
                            testResult = nil
                            Task {
                                testResult = await keyManager.testConnection(for: service, depth: testDepth)
                                isTesting = false
                            }
                        }
                        .disabled(isTesting)
                        .controlSize(.small)
                    }

                    if let result = testResult {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.success ? .green : .red)
                                Text(result.message)
                                    .font(.caption)
                                if let latency = result.latencyMs {
                                    Text("(\(latency)ms)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if !result.accessibleModels.isEmpty {
                                Text("Models: \(result.accessibleModels.prefix(5).joined(separator: ", "))\(result.accessibleModels.count > 5 ? " +\(result.accessibleModels.count - 5) more" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let diagnostics = result.diagnostics {
                                Text(diagnostics)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            isEditing = !keyManager.hasKey(for: service)
        }
    }
}
