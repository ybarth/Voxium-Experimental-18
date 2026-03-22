import SwiftUI

struct RecordingOverlayContent: View {
    let appState: AppState

    private var overlayState: OverlayState { appState.overlayState }
    private var audioRecorder: AudioRecorder { appState.audioRecorder }

    var body: some View {
        Group {
            switch overlayState.phase {
            case .hidden:
                EmptyView()
            case .idle:
                idleView
            case .recording:
                recordingView
            case .transcribing:
                transcribingView
            case .cancelled:
                cancelledView
            case .modelDownloading:
                modelDownloadingView
            case .accessibilityRequired:
                accessibilityRequiredView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: overlayState.phase)
    }

    // MARK: - Idle pill with context menu

    private var idleView: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .onTapGesture {
                AppState.showMainWindow()
            }
            .contextMenu {
                if let lastEntry = appState.historyStore.entries.first {
                    Button("Paste Last Dictation") {
                        appState.pasteService.paste(text: lastEntry.text)
                    }
                    Divider()
                }

                Menu("Model") {
                    Picker("Model", selection: Binding(
                        get: { appState.modelManager.selectedModel },
                        set: { appState.onModelChanged($0) }
                    )) {
                        ForEach(TranscriptionModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                }

                Menu("Microphone") {
                    let devices = AudioRecorder.availableInputDevices()
                    let selectedUID = appState.audioRecorder.selectedDeviceUID ?? ""

                    Picker("Microphone", selection: Binding(
                        get: { selectedUID },
                        set: { appState.audioRecorder.selectedDeviceUID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("System Default").tag("")
                        Divider()
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }

                Menu("Processing Model") {
                    // Local transcription models
                    Picker("Transcription", selection: Binding(
                        get: { appState.modelManager.selectedModel },
                        set: { appState.onModelChanged($0) }
                    )) {
                        ForEach(TranscriptionModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }

                    // Cloud models (if API keys configured)
                    if appState.commercialKeyManager.hasKey(for: .gpt) {
                        Divider()
                        Text("OpenAI (via API key)").font(.caption)
                    }
                    if appState.commercialKeyManager.hasKey(for: .gemini) {
                        if !appState.commercialKeyManager.hasKey(for: .gpt) { Divider() }
                        Text("Gemini (via API key)").font(.caption)
                    }
                }

                Menu("Text to Speech") {
                    Picker("TTS Mode", selection: Binding(
                        get: { TTSMode(rawValue: UserDefaults.standard.string(forKey: "ttsMode") ?? "off") ?? .off },
                        set: {
                            UserDefaults.standard.set($0.rawValue, forKey: "ttsMode")
                            appState.ttsMode = $0.rawValue
                            appState.onTTSSettingsChanged()
                        }
                    )) {
                        ForEach(TTSMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if TTSMode(rawValue: UserDefaults.standard.string(forKey: "ttsMode") ?? "off") == .speechify {
                        Divider()

                        Toggle("Echo Mode", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "echoModeEnabled") },
                            set: {
                                UserDefaults.standard.set($0, forKey: "echoModeEnabled")
                                appState.echoModeEnabled = $0
                                appState.onTTSSettingsChanged()
                            }
                        ))
                    }
                }

                Divider()

                Button("Settings") {
                    appState.showTab(.settings)
                }

                Button("History") {
                    appState.showTab(.history)
                }

                Divider()

                Button("Hide Mini Dock") {
                    appState.setShowIdlePill(false)
                }
            }
    }

    // MARK: - Active state views

    private var recordingView: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .modifier(PulsingModifier())

            WaveformView(levels: audioRecorder.recentLevels)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var cancelledView: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))

            Text("Recording Cancelled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var modelDownloadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Model is downloading... give it a sec!")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var accessibilityRequiredView: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red.opacity(0.9))

            Text("Enable Accessibility in System Settings")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var transcribingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}

private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
