import SwiftUI

struct LocalModelsSettingsView: View {
    let appState: AppState
    @State private var showScanResult = false
    @State private var scanResultMessage: String?

    private var registry: ProviderRegistry { appState.providerRegistry }
    private var mlxManager: MLXModelManager { appState.mlxModelManager }

    private var memoryBudgetGB: Double {
        Double(registry.memoryBudget) / 1_073_741_824
    }
    private var memoryUsedGB: Double {
        Double(registry.totalMemoryUsage) / 1_073_741_824
    }
    private var memoryFraction: Double {
        guard registry.memoryBudget > 0 else { return 0 }
        return Double(registry.totalMemoryUsage) / Double(registry.memoryBudget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Memory usage
            GroupBox("Memory Budget") {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(memoryFraction, 1.0))
                        .tint(memoryFraction > 0.9 ? .red : memoryFraction > 0.7 ? .orange : .accentColor)

                    HStack {
                        Text(String(format: "%.1f GB used", memoryUsedGB))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f GB budget", memoryBudgetGB))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(
                        value: Binding(
                            get: { registry.memoryBudget / 1_073_741_824 },
                            set: { registry.memoryBudget = $0 * 1_073_741_824 }
                        ),
                        in: 1...64,
                        step: 1
                    ) {
                        Text("Budget: \(registry.memoryBudget / 1_073_741_824) GB")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }

            // Scan for existing models
            Button("Scan for Existing Models") {
                let matches = mlxManager.downloadManager.scanForExistingModels(catalog: MLXModelManager.catalog)
                for match in matches {
                    try? mlxManager.downloadManager.linkExternalModel(match)
                }
                scanResultMessage = matches.isEmpty
                    ? "No existing models found on this device."
                    : "Found and linked \(matches.count) model(s) from other tools."
                showScanResult = true
            }
            .font(.caption)

            if showScanResult, let message = scanResultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            // Model list
            GroupBox("MLX Models") {
                VStack(spacing: 0) {
                    ForEach(MLXModelManager.catalog, id: \.id) { entry in
                        MLXModelRow(entry: entry, mlxManager: mlxManager, registry: registry)
                        if entry.id != MLXModelManager.catalog.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct MLXModelRow: View {
    let entry: MLXModelCatalogEntry
    let mlxManager: MLXModelManager
    let registry: ProviderRegistry

    private var provider: MLXProvider? {
        mlxManager.providers[entry.id]
    }

    private var status: ProviderStatus {
        provider?.status ?? (mlxManager.downloadManager.isDownloaded(modelID: entry.id) ? .available : .notDownloaded)
    }

    private var downloadProgress: MLXDownloadManager.DownloadProgress? {
        mlxManager.downloadManager.activeDownloads[entry.id]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Status indicator
            statusIcon
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name)
                        .fontWeight(.medium)
                    Text(entry.parameterCount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.memoryGB) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Capability tags
                HStack(spacing: 4) {
                    ForEach(Array(entry.capabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { cap in
                        Text(cap.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }

                // Download progress
                if let progress = downloadProgress {
                    ProgressView(value: progress.fraction)
                    Text(String(format: "Downloading... %.0f%%", progress.fraction * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Action button
            actionButton
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .loaded:
            Text("Loaded")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .available:
            Button("Load") {
                Task {
                    try? await provider?.load()
                }
            }
        case .notDownloaded:
            Button("Download") {
                Task {
                    try? await provider?.load()
                }
            }
        case .downloading, .loading:
            Button("Cancel") {}
                .disabled(true)
        case .error:
            Button("Retry") {
                Task {
                    try? await provider?.load()
                }
            }
        }
    }
}
