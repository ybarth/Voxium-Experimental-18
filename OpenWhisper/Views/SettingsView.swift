import ServiceManagement
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    let appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var storageBytes: Int64 = 0
    @AppStorage("ttsMode") private var ttsMode: String = TTSMode.off.rawValue
    @AppStorage("echoModeEnabled") private var echoModeEnabled: Bool = false
    @AppStorage("echoModeDockPosition") private var echoModeDockPosition: String = DockPosition.bottom.rawValue

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Audio Input") {
                Picker("Input Mode", selection: Binding(
                    get: { AudioInputMode(rawValue: appState.audioInputMode) ?? .microphone },
                    set: { appState.audioInputMode = $0.rawValue }
                )) {
                    ForEach(AudioInputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if let mode = AudioInputMode(rawValue: appState.audioInputMode),
                   (mode == .systemAudio || mode == .mixed),
                   !Permissions.isScreenRecordingAuthorized {
                    HStack {
                        Label("Screen recording permission required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Spacer()
                        Button("Grant") {
                            Permissions.requestScreenRecording()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Hotkeys") {
                HStack {
                    Text("Toggle Recording:")
                    Spacer()
                    ShortcutRecorder(name: .toggleRecording)
                }
                HStack {
                    Text("Cancel Recording:")
                    Spacer()
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Text Insertion") {
                Toggle("Context-aware formatting", isOn: Binding(
                    get: { appState.contextAwareFormatting },
                    set: { appState.contextAwareFormatting = $0 }
                ))

                Toggle("Direct text insertion (experimental)", isOn: Binding(
                    get: { appState.useDirectInsertion },
                    set: { appState.useDirectInsertion = $0 }
                ))
                .disabled(!appState.contextAwareFormatting)

                if appState.contextAwareFormatting {
                    Text("Adjusts capitalization and spacing based on cursor position and app context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
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
                            Task {
                                await appState.modelManager.downloadModel()
                            }
                        }
                    }
                } else {
                    Button("Download Model") {
                        Task {
                            await appState.modelManager.downloadModel()
                        }
                    }
                }
            }

            if appState.modelManager.selectedModel.requiresServer {
                Section("Inference Server") {
                    HStack {
                        Text("Status")
                        Spacer()
                        serverStatusView
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        Text(appState.serverManager.loadedModelName ?? "None")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if appState.serverManager.isRunning {
                            Button("Stop Server") {
                                appState.serverManager.stop()
                            }
                        } else if appState.isSettingUpServer {
                            Button("Starting...") {}
                                .disabled(true)
                        } else {
                            Button("Start Server") {
                                appState.startServerInBackground(
                                    for: appState.modelManager.selectedModel
                                )
                            }
                        }

                        Spacer()

                        Button("Reset Environment") {
                            appState.resetServerEnvironment()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            Section("Timing Analysis (Sherpa)") {
                HStack {
                    Text("Status")
                    Spacer()
                    timingStatusView
                }

                HStack {
                    if appState.serverManager.timingModelLoaded {
                        Button("Stop") {
                            appState.serverManager.stop()
                        }
                    } else if appState.serverManager.isTimingLoading || appState.isSettingUpServer {
                        Button("Loading...") {}
                            .disabled(true)
                    } else {
                        Button("Start Timing Server") {
                            appState.startTimingServer()
                        }
                    }
                    Spacer()
                }

                Text("Provides accurate word-level timestamps for playback highlighting via Parakeet CTC. Runs automatically when entries are created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                HStack {
                    Text("Audio storage used")
                    Spacer()
                    Text(formatBytes(storageBytes))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("History entries")
                    Spacer()
                    Text("\(appState.historyStore.entries.count)")
                        .foregroundStyle(.secondary)
                }

                Picker("Max history entries", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "maxHistoryEntries").clamped(fallback: 200) },
                    set: { UserDefaults.standard.set($0, forKey: "maxHistoryEntries") }
                )) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("Unlimited").tag(0)
                }

                Picker("Auto-delete after", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "maxHistoryAgeDays").clamped(fallback: 90) },
                    set: { UserDefaults.standard.set($0, forKey: "maxHistoryAgeDays") }
                )) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Never").tag(0)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    if Permissions.isMicrophoneAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Request") {
                            Permissions.requestMicrophone()
                        }
                    }
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    if Permissions.isAccessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }

                HStack {
                    Text("Screen Recording")
                    Spacer()
                    if Permissions.isScreenRecordingAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant") {
                            Permissions.requestScreenRecording()
                        }
                    }
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

            Section {
                Text("Build 2026.03.20-A")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 720)
        .onAppear {
            storageBytes = AudioFileManager.shared.totalStorageBytes()
        }
    }

    @ViewBuilder
    private var serverStatusView: some View {
        switch appState.serverManager.state {
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .settingUp:
            Label("Setting up Python...", systemImage: "gear")
                .foregroundStyle(.orange)
                .font(.caption)
        case .installingDependencies:
            Label("Installing dependencies...", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .starting:
            Label("Starting...", systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .loadingModel(let progress):
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading model (\(Int(progress * 100))%)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var timingStatusView: some View {
        if appState.serverManager.timingModelLoaded {
            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if appState.serverManager.isTimingLoading {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Parakeet CTC...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = appState.serverManager.timingError {
            Label(error, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        } else {
            Label("Stopped", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private extension Int {
    func clamped(fallback: Int) -> Int {
        self == 0 && UserDefaults.standard.object(forKey: "maxHistoryEntries") == nil ? fallback : self
    }
}
