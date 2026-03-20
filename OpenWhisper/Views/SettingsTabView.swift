import SwiftUI
import KeyboardShortcuts

struct SettingsTabView: View {
    let appState: AppState
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted
    @AppStorage("textInsertionMethod") private var textInsertionMethod: String = TextInsertionMethod.accessibility.rawValue
    @AppStorage("ttsMode") private var ttsMode: String = TTSMode.off.rawValue
    @AppStorage("echoModeEnabled") private var echoModeEnabled: Bool = false
    @AppStorage("echoModeDockPosition") private var echoModeDockPosition: String = DockPosition.bottom.rawValue

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Toggle Recording") {
                    ShortcutRecorder(name: .toggleRecording)
                }
                LabeledContent("Push-to-Talk") {
                    ShortcutRecorder(name: .pushToTalkRecording)
                }
                LabeledContent("Cancel Recording") {
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Overlay") {
                Toggle("Show floating pill when idle", isOn: Binding(
                    get: { appState.showIdlePill },
                    set: { appState.setShowIdlePill($0) }
                ))
            }

            Section("Microphone") {
                let devices = AudioRecorder.availableInputDevices()
                Picker("Input Device", selection: Binding(
                    get: { appState.audioRecorder.selectedDeviceUID ?? "" },
                    set: { appState.audioRecorder.selectedDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
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

            Section("Timing Analysis (Sherpa)") {
                HStack {
                    Circle()
                        .fill(timingStatusColor)
                        .frame(width: 8, height: 8)
                    Text(timingStatusText)
                        .font(.caption)
                }

                if appState.serverManager.isTimingLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading Parakeet CTC...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = appState.serverManager.timingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                if appState.serverManager.timingModelLoaded {
                    Button("Stop Timing Server") {
                        appState.serverManager.stop()
                    }
                    .controlSize(.small)
                } else if appState.isSettingUpServer || appState.serverManager.isTimingLoading {
                    Button("Starting...") {}
                        .disabled(true)
                        .controlSize(.small)
                } else {
                    Button("Start Timing Server") {
                        appState.startTimingServer()
                    }
                    .controlSize(.small)
                }

                Text("Provides accurate word-level timestamps for playback highlighting via Parakeet CTC. Runs automatically when new entries are created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bar Appearance") {
                AppearanceEditor(
                    label: "Waveform Bars",
                    appearance: Binding(
                        get: { AppearanceStore.globalBarAppearance },
                        set: { AppearanceStore.setBarAppearance($0) }
                    )
                )
            }

            Section("Entry Background") {
                AppearanceEditor(
                    label: "Entry Rows",
                    appearance: Binding(
                        get: { AppearanceStore.globalEntryAppearance },
                        set: { AppearanceStore.setEntryAppearance($0) }
                    )
                )
            }

            Section("Text Insertion") {
                Picker("Insertion Method", selection: Binding(
                    get: { TextInsertionMethod(rawValue: textInsertionMethod) ?? .paste },
                    set: { textInsertionMethod = $0.rawValue }
                )) {
                    ForEach(TextInsertionMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }

                switch TextInsertionMethod(rawValue: textInsertionMethod) ?? .paste {
                case .paste:
                    Text("Copies text to clipboard and simulates ⌘V. Most compatible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .keyPresses:
                    Text("Simulates individual key presses. Works without clipboard access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .accessibility:
                    Text("Inserts text directly via Accessibility API. Enables in-app echo mode (no floating panel needed).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Backups") {
                HStack {
                    Text("Backup Folder")
                    Spacer()
                    Text(appState.historyStore.backupFolderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Button("Change...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Select Backup Folder"
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.historyStore.setBackupFolder(url)
                        }
                    }
                    .controlSize(.small)

                    Button("Reset to Default") {
                        appState.historyStore.setBackupFolder(nil)
                    }
                    .controlSize(.small)

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appState.historyStore.backupFolderPath)
                    }
                    .controlSize(.small)
                }
            }

            Section("Text to Speech") {
                Picker("TTS Mode", selection: Binding(
                    get: { TTSMode(rawValue: ttsMode) ?? .off },
                    set: { ttsMode = $0.rawValue }
                )) {
                    ForEach(TTSMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if TTSMode(rawValue: ttsMode) == .speechify {
                    Text("Requires Speechify desktop app with backtick (`) configured as the read shortcut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Echo Mode", isOn: $echoModeEnabled)

                    if echoModeEnabled {
                        Picker("Dock Position", selection: Binding(
                            get: { DockPosition(rawValue: echoModeDockPosition) ?? .bottom },
                            set: { echoModeDockPosition = $0.rawValue }
                        )) {
                            ForEach(DockPosition.allCases, id: \.self) { pos in
                                Text(pos.displayName).tag(pos)
                            }
                        }

                        Text("Shows a floating panel with the latest transcription. Automatically reads new dictations aloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: ttsMode) { _, newValue in
                appState.ttsMode = newValue
                appState.onTTSSettingsChanged()
            }
            .onChange(of: echoModeEnabled) { _, newValue in
                appState.echoModeEnabled = newValue
                appState.onTTSSettingsChanged()
            }
            .onChange(of: echoModeDockPosition) { _, newValue in
                appState.echoModeDockPosition = newValue
                appState.onTTSSettingsChanged()
                appState.echoModeController?.updateDockPosition(
                    DockPosition(rawValue: newValue) ?? .bottom
                )
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
            appState.snapshotHotkeySettings()
        }
        .onDisappear {
            appState.acceptHotkeyChanges()
        }
    }

    // MARK: - Model status

    @ViewBuilder
    private var modelStatusView: some View {
        let model = appState.modelManager.selectedModel

        if model.backend == .whisperCpp {
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

    // MARK: - Timing status

    private var timingStatusColor: Color {
        if appState.serverManager.timingModelLoaded { return .green }
        if appState.serverManager.isTimingLoading { return .orange }
        if appState.serverManager.timingError != nil { return .red }
        return .gray
    }

    private var timingStatusText: String {
        if appState.serverManager.timingModelLoaded { return "Running" }
        if appState.serverManager.isTimingLoading { return "Loading..." }
        if appState.serverManager.timingError != nil { return "Error" }
        return "Stopped"
    }
}
