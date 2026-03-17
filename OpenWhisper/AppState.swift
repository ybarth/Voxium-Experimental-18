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

    init() {
        // Create overlay controller after all properties are initialized
        overlayController = OverlayController(overlayState: overlayState, audioRecorder: audioRecorder)

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.toggleRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .cancelRecording) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.cancelRecording()
            }
        }

        syncCancelRecordingHotkey()

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
        syncCancelRecordingHotkey()
        logger.info("Recording cancelled by user", category: .transcription)

        // Show "Recording Cancelled" briefly, then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.overlayState.phase = .hidden
            self?.overlayController?.dismiss()
        }
    }

    /// Called when the user switches models in settings.
    func onModelChanged(_ model: TranscriptionModel) {
        modelManager.selectModel(model)

        if model.requiresServer {
            startServerInBackground(for: model)
        } else {
            // Stop the server if switching to a whisper model
            if serverManager.isRunning {
                serverManager.stop()
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        let model = modelManager.selectedModel

        // Check model/server readiness
        if model.backend == .whisperCpp {
            guard modelManager.isModelReady else {
                if modelManager.isDownloading {
                    overlayState.phase = .modelDownloading
                    overlayController?.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard self?.overlayState.phase == .modelDownloading else { return }
                        self?.overlayState.phase = .hidden
                        self?.overlayController?.dismiss()
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
            overlayController?.show()
            syncCancelRecordingHotkey()
            logger.info("Recording started", category: .transcription)
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
            logger.error("Mic error: \(error.localizedDescription)", category: .transcription)
        }
    }

    // MARK: - Transcription

    private func stopRecordingAndTranscribe() async {
        let samples = audioRecorder.stopRecording()
        isRecording = false
        syncCancelRecordingHotkey()

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            logger.info("No audio captured", category: .transcription)
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."
        overlayState.phase = .transcribing
        logger.info("Transcribing \(samples.count) samples...", category: .transcription)

        do {
            let text: String

            if modelManager.selectedModel.backend == .whisperCpp {
                guard let modelURL = modelManager.modelFileURL else {
                    statusMessage = "Model not available"
                    isTranscribing = false
                    overlayState.phase = .hidden
                    overlayController?.dismiss()
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
        overlayState.phase = .hidden
        overlayController?.dismiss()
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
