import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class AppState {
    var isRecording = false
    var statusMessage = "Ready"
    var isTranscribing = false

    @ObservationIgnored
    @AppStorage("systemPrompt") var systemPrompt: String = ""

    @ObservationIgnored
    @AppStorage("showIdlePill") var showIdlePill: Bool = true

    let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    let pasteService = PasteService()
    let modelManager = ModelManager()
    let overlayState = OverlayState()
    let historyStore = HistoryStore()
    let serverManager = InferenceServerManager()
    let logger = TranscriptionLogger.shared
    private(set) var overlayController: OverlayController?

    /// Whether the server is being set up in the background after selecting a server model.
    var isSettingUpServer = false

    /// Set this to navigate the main window to a specific tab.
    var desiredTab: AppTab?

    // MARK: - Settings confirmation state

    private var originalToggleShortcut: KeyboardShortcuts.Shortcut?
    private var originalCancelShortcut: KeyboardShortcuts.Shortcut?
    private var originalPTTShortcut: KeyboardShortcuts.Shortcut?
    private var hasSnapshot = false

    var hasUnsavedHotkeyChanges: Bool {
        guard hasSnapshot else { return false }
        let currentToggle = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        let currentCancel = KeyboardShortcuts.getShortcut(for: .cancelRecording)
        let currentPTT = KeyboardShortcuts.getShortcut(for: .pushToTalkRecording)
        return currentToggle != originalToggleShortcut
            || currentCancel != originalCancelShortcut
            || currentPTT != originalPTTShortcut
    }

    init() {
        overlayController = OverlayController(appState: self)

        // Register both toggle and push-to-talk hotkeys
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.toggleRecording()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pushToTalkRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isRecording else { return }
                self.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pushToTalkRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRecording else { return }
                await self.stopRecordingAndTranscribe()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .cancelRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.cancelRecording()
            }
        }

        syncCancelRecordingHotkey()

        // Show idle pill on launch
        if showIdlePill {
            overlayController?.showIdlePill()
        }

        // Auto-download whisper model on first launch
        modelManager.ensureModelAvailable()

        // If a server model was previously selected, start the server in the background
        if modelManager.selectedModel.requiresServer {
            startServerInBackground(for: modelManager.selectedModel)
        }

        logger.info("AppState initialized", category: .general)
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        _ = audioRecorder.stopRecording()
        isRecording = false
        statusMessage = "Ready"
        overlayState.phase = .cancelled
        overlayController?.updateForPhase(.cancelled)
        syncCancelRecordingHotkey()
        logger.info("Recording cancelled by user", category: .transcription)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.showIdlePill {
                self.overlayState.phase = .idle
                self.overlayController?.updateForPhase(.idle)
            } else {
                self.overlayState.phase = .hidden
                self.overlayController?.updateForPhase(.hidden)
            }
        }
    }

    func onModelChanged(_ model: TranscriptionModel) {
        modelManager.selectModel(model)

        if model.requiresServer {
            startServerInBackground(for: model)
        } else {
            if serverManager.isRunning {
                serverManager.stop()
            }
        }
    }

    func setShowIdlePill(_ show: Bool) {
        showIdlePill = show
        if show {
            if overlayState.phase == .hidden {
                overlayState.phase = .idle
                overlayController?.updateForPhase(.idle)
            }
        } else {
            if overlayState.phase == .idle {
                overlayState.phase = .hidden
                overlayController?.updateForPhase(.hidden)
            }
        }
    }

    /// Navigate the main window to a specific tab and bring it forward.
    func showTab(_ tab: AppTab) {
        desiredTab = tab
        Self.showMainWindow()
    }

    // MARK: - Settings confirmation

    func snapshotHotkeySettings() {
        originalToggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        originalCancelShortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording)
        originalPTTShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalkRecording)
        hasSnapshot = true
    }

    func revertHotkeyChanges() {
        guard hasSnapshot else { return }
        KeyboardShortcuts.setShortcut(originalToggleShortcut, for: .toggleRecording)
        KeyboardShortcuts.setShortcut(originalCancelShortcut, for: .cancelRecording)
        KeyboardShortcuts.setShortcut(originalPTTShortcut, for: .pushToTalkRecording)
        hasSnapshot = false
    }

    func acceptHotkeyChanges() {
        if hasSnapshot {
            originalToggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
            originalCancelShortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording)
            originalPTTShortcut = KeyboardShortcuts.getShortcut(for: .pushToTalkRecording)
        }
        hasSnapshot = false
    }

    // MARK: - Recording

    func startRecording() {
        let model = modelManager.selectedModel

        if model.backend == .whisperCpp {
            guard modelManager.isModelReady else {
                if modelManager.isDownloading {
                    overlayState.phase = .modelDownloading
                    overlayController?.updateForPhase(.modelDownloading)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self else { return }
                        guard self.overlayState.phase == .modelDownloading else { return }
                        if self.showIdlePill {
                            self.overlayState.phase = .idle
                            self.overlayController?.updateForPhase(.idle)
                        } else {
                            self.overlayState.phase = .hidden
                            self.overlayController?.updateForPhase(.hidden)
                        }
                    }
                } else {
                    statusMessage = "Model not downloaded yet"
                }
                return
            }
        } else {
            guard serverManager.isRunning else {
                if isSettingUpServer {
                    statusMessage = "Server is starting up — try again shortly"
                    logger.info("Recording blocked: server still starting", category: .server)
                } else {
                    statusMessage = "Starting server..."
                    startServerInBackground(for: model)
                }
                return
            }
        }

        if !Permissions.isMicrophoneAuthorized {
            statusMessage = "Microphone permission required"
            Permissions.requestMicrophone()
            Self.showMainWindow()
            return
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.updateForPhase(.recording)
            syncCancelRecordingHotkey()
            logger.info("Recording started", category: .transcription)
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
            logger.error("Mic error: \(error.localizedDescription)", category: .transcription)
        }
    }

    // MARK: - Transcription

    func stopRecordingAndTranscribe() async {
        let samples = audioRecorder.stopRecording()
        isRecording = false
        syncCancelRecordingHotkey()

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            if showIdlePill {
                overlayState.phase = .idle
                overlayController?.updateForPhase(.idle)
            } else {
                overlayState.phase = .hidden
                overlayController?.updateForPhase(.hidden)
            }
            logger.info("No audio captured", category: .transcription)
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."
        overlayState.phase = .transcribing
        overlayController?.updateForPhase(.transcribing)
        logger.info("Transcribing \(samples.count) samples...", category: .transcription)

        do {
            let text: String

            if modelManager.selectedModel.backend == .whisperCpp {
                guard let modelURL = modelManager.modelFileURL else {
                    statusMessage = "Model not available"
                    isTranscribing = false
                    if showIdlePill {
                        overlayState.phase = .idle
                        overlayController?.updateForPhase(.idle)
                    } else {
                        overlayState.phase = .hidden
                        overlayController?.updateForPhase(.hidden)
                    }
                    return
                }
                text = try await transcriptionService.transcribe(
                    audioFrames: samples,
                    modelURL: modelURL
                )
            } else {
                text = try await transcriptionService.transcribe(
                    audioFrames: samples,
                    using: serverManager
                )
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "No speech detected"
                logger.info("No speech detected in audio", category: .transcription)
            } else {
                pasteService.paste(text: text)
                historyStore.add(text: text)
                statusMessage = "Pasted: \(String(text.prefix(50)))\(text.count > 50 ? "..." : "")"
            }
        } catch {
            statusMessage = "Transcription error: \(error.localizedDescription)"
            logger.error("Transcription error: \(error.localizedDescription)", category: .transcription)
        }

        isTranscribing = false
        if showIdlePill {
            overlayState.phase = .idle
            overlayController?.updateForPhase(.idle)
        } else {
            overlayState.phase = .hidden
            overlayController?.updateForPhase(.hidden)
        }
    }

    // MARK: - Server lifecycle

    func startServerInBackground(for model: TranscriptionModel) {
        guard !isSettingUpServer else { return }
        isSettingUpServer = true
        logger.info("Starting server setup for \(model.rawValue) in background...", category: .server)

        Task {
            do {
                try await serverManager.ensureRunning(model: model)
                statusMessage = "Server ready — \(model.displayName)"
                logger.info("Server is ready for \(model.rawValue)", category: .server)
            } catch {
                statusMessage = "Server error: \(error.localizedDescription)"
                logger.error("Server setup failed: \(error.localizedDescription)", category: .server)
            }
            isSettingUpServer = false
        }
    }

    func resetServerEnvironment() {
        let model = modelManager.selectedModel
        guard model.requiresServer else { return }

        do {
            try serverManager.resetEnvironment(for: model)
            statusMessage = "Reset inference environment for \(model.displayName)"
            logger.info("Reset inference environment for \(model.rawValue)", category: .server)
        } catch {
            statusMessage = "Reset failed: \(error.localizedDescription)"
            logger.error("Reset inference environment failed: \(error.localizedDescription)", category: .server)
        }
    }

    // MARK: - Helpers

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if window.identifier?.rawValue == "main" ||
               window.title == "OpenWhisper" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        if let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func syncCancelRecordingHotkey() {
        if isRecording {
            KeyboardShortcuts.enable(.cancelRecording)
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
        }
    }
}
