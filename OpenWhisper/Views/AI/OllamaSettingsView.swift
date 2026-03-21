import SwiftUI

struct OllamaSettingsView: View {
    let appState: AppState

    private var discovery: OllamaDiscovery { appState.ollamaDiscovery }

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Detection status
            GroupBox("Status") {
                HStack {
                    if discovery.isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ollama detected")
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("Ollama not detected")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(isRefreshing ? "Refreshing..." : "Refresh") {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        Task {
                            await discovery.detect()
                            isRefreshing = false
                        }
                    }
                    .disabled(isRefreshing)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }

            if !discovery.isInstalled {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ollama is not running on localhost:11434.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Install Ollama at ollama.com", destination: URL(string: "https://ollama.com")!)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Discovered models
            if !discovery.discoveredModels.isEmpty {
                GroupBox("Discovered Models (\(discovery.discoveredModels.count))") {
                    VStack(spacing: 0) {
                        ForEach(discovery.discoveredModels, id: \.id) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                        .fontWeight(.medium)
                                    if let footprint = model.memoryFootprint {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                // Capability tags
                                HStack(spacing: 4) {
                                    ForEach(Array(model.capabilities).prefix(2).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { cap in
                                        Text(cap.rawValue)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.1))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption2)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            if model.id != discovery.discoveredModels.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            } else if discovery.isInstalled {
                GroupBox {
                    Text("No models found. Pull a model with: ollama pull llama3.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}
