import SwiftUI
import KeyboardShortcuts

struct SettingsTabView: View {
    let appState: AppState
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Toggle Recording") {
                    ShortcutRecorder(name: .toggleRecording)
                }
                LabeledContent("Cancel Recording") {
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Model") {
                Picker("Model", selection: Binding(
                    get: { appState.modelManager.selectedModel },
                    set: { appState.onModelChanged($0) }
                )) {
                    ForEach(TranscriptionModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                modelStatusView
            }

            if appState.modelManager.selectedModel.requiresServer {
                Section("Inference Server") {
                    serverStatusView
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    if micAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            Permissions.requestMicrophone()
                        }
                    }
                }

                LabeledContent("Accessibility") {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }

                // App location — helps identify the right entry in System Settings
                VStack(alignment: .leading, spacing: 4) {
                    Text("App location:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Permissions.appBundlePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        Permissions.revealAppInFinder()
                    }
                    .controlSize(.small)

                    Button("Reset Accessibility") {
                        Permissions.resetAndRePromptAccessibility()
                    }
                    .controlSize(.small)
                    .help("Clears the stale Accessibility entry (useful after rebuilds) and re-prompts for permission.")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
        .onAppear {
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
    }

    // MARK: - Model status

    @ViewBuilder
    private var modelStatusView: some View {
        let model = appState.modelManager.selectedModel

        if model.backend == .whisperCpp {
            // Whisper model — show download status
            if appState.modelManager.isModelReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if appState.modelManager.isDownloading {
                VStack(alignment: .leading) {
                    Text("Downloading model...")
                    ProgressView(value: appState.modelManager.downloadProgress)
                    Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = appState.modelManager.errorMessage {
                VStack(alignment: .leading) {
                    Label("Download failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry Download") {
                        appState.modelManager.startDownload()
                    }
                }
            } else {
                Button("Download Model") {
                    appState.modelManager.startDownload()
                }
            }
        } else {
            // Server model — show brief info
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text("Requires local inference server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model == .graniteSpeech {
                Text("Note: Granite uses Apple MLX Audio with the BF16 Granite 4.0 1B Speech model and downloads about 4.5 GB on first setup.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Server status

    @ViewBuilder
    private var serverStatusView: some View {
        let state = appState.serverManager.state

        HStack {
            Circle()
                .fill(serverStatusColor(state))
                .frame(width: 8, height: 8)
            Text(state.displayString)
                .font(.caption)
        }

        if case .loadingModel(let progress) = state {
            VStack(alignment: .leading) {
                ProgressView(value: progress)
                Text("Downloading model files... \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if case .error(let msg) = state {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)

            Button("Restart Server") {
                appState.startServerInBackground(for: appState.modelManager.selectedModel)
            }
        }

        if case .running = state {
            Button("Stop Server") {
                appState.serverManager.stop()
            }
            .controlSize(.small)
        }

        if case .stopped = state {
            Button("Start Server") {
                appState.startServerInBackground(for: appState.modelManager.selectedModel)
            }
            .controlSize(.small)
        }

        HStack(spacing: 8) {
            Button("Reset Environment") {
                appState.resetServerEnvironment()
            }
            .controlSize(.small)
            .help("Removes the server virtual environment and downloaded files for the current server model so setup can start cleanly.")
        }
    }

    private func serverStatusColor(_ state: InferenceServerManager.ServerState) -> Color {
        switch state {
        case .running: return .green
        case .error: return .red
        case .stopped: return .gray
        default: return .orange
        }
    }
}
