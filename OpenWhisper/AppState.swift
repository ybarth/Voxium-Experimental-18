import SwiftUI
import KeyboardShortcuts

enum AudioInputMode: String, CaseIterable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"
    case mixed = "Mixed (Mic + System)"
}

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

    @ObservationIgnored
    @AppStorage("contextAwareFormatting") var contextAwareFormatting: Bool = true

    @ObservationIgnored
    @AppStorage("useDirectInsertion") var useDirectInsertion: Bool = false

    @ObservationIgnored
    @AppStorage("audioInputMode") var audioInputMode: String = AudioInputMode.microphone.rawValue

    let audioRecorder = AudioRecorder()
    let systemAudioRecorder = SystemAudioRecorder()
    let mixedAudioRecorder = MixedAudioRecorder()
    let transcriptionService = TranscriptionService()
    let pasteService = PasteService()
    let modelManager = ModelManager()
    let overlayState = OverlayState()
    let historyStore = HistoryStore()
    let serverManager = InferenceServerManager()
    let cursorPositionService = CursorPositionService()
    let contextStore = AccessibilityContextStore()
    let logger = TranscriptionLogger.shared
    private(set) var overlayController: OverlayController?

    // MARK: - Text Insertion

    let keyPressInsertionService = KeyPressInsertionService()
    let accessibilityInsertionService = AccessibilityInsertionService()

    @ObservationIgnored
    @AppStorage("textInsertionMethod") var textInsertionMethod: String = TextInsertionMethod.accessibility.rawValue

    // MARK: - TTS / Echo Mode

    let speechifyService = SpeechifyService()
    let echoModeState = EchoModeState()
    private(set) var echoModeController: EchoModeController?

    // MARK: - AI Provider Infrastructure

    let providerRegistry = ProviderRegistry()
    let taskRouter = TaskRouter()
    let councilStore = CouncilStore()
    let councilOrchestrator: CouncilOrchestrator
    let commercialKeyManager = CommercialKeyManager()
    let mlxModelManager = MLXModelManager()
    let ollamaDiscovery = OllamaDiscovery()
    let careModelService: CareModelService

    @ObservationIgnored
    @AppStorage("ttsMode") var ttsMode: String = TTSMode.off.rawValue

    @ObservationIgnored
    @AppStorage("echoModeEnabled") var echoModeEnabled: Bool = false

    @ObservationIgnored
    @AppStorage("echoModeDockPosition") var echoModeDockPosition: String = DockPosition.bottom.rawValue

    /// Whether the main app window is currently visible.
    var isMainWindowVisible: Bool = false

    /// The currently selected tab in the main window (synced from MainWindowView).
    var currentTab: AppTab = .home

    /// Whether the pill should be visible based on current state.
    /// Rules: show if insertion mode is paste or keyPresses, OR if main window is open.
    /// Hidden when on history tab, or if user explicitly dismissed it.
    var shouldShowIdlePill: Bool {
        guard showIdlePill else { return false }
        if currentTab == .history && isMainWindowVisible { return false }
        let method = TextInsertionMethod(rawValue: textInsertionMethod) ?? .accessibility
        let isPasteOrKeyPress = method == .paste || method == .keyPresses
        return isPasteOrKeyPress || isMainWindowVisible
    }

    /// Context captured at recording start for context-aware formatting.
    private var currentContext: AccessibilityContext?

    var currentInputMode: AudioInputMode {
        AudioInputMode(rawValue: audioInputMode) ?? .microphone
    }

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
        self.councilOrchestrator = CouncilOrchestrator(registry: providerRegistry)
        self.careModelService = CareModelService(
            registry: providerRegistry,
            taskRouter: taskRouter,
            historyStore: historyStore,
            cursorPositionService: cursorPositionService
        )

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
                await self.startRecording()
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
        if shouldShowIdlePill {
            overlayController?.showIdlePill()
        }

        // Auto-download whisper model on first launch
        modelManager.ensureModelAvailable()

        // If a server model was previously selected, start the server in the background
        if modelManager.selectedModel.requiresServer {
            startServerInBackground(for: modelManager.selectedModel)
        }

        // Initialize Echo Mode
        echoModeController = EchoModeController(state: echoModeState, speechifyService: speechifyService)
        updateMainWindowVisibility()
        syncEchoModeState()

        // Observe main window visibility changes
        NotificationCenter.default.addObserver(
            forName: AppDelegate.mainWindowVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMainWindowVisibility()
                self.updateIdlePillVisibility()
                self.updateEchoModePanel()
            }
        }

        logger.info("AppState initialized", category: .general)

        Task {
            await setupAIProviders()
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        // Stop whichever recorder is active
        switch currentInputMode {
        case .microphone:
            _ = audioRecorder.stopRecording()
        case .systemAudio:
            Task { await systemAudioRecorder.stopRecording() }
        case .mixed:
            Task { await mixedAudioRecorder.stopRecording() }
        }
        isRecording = false
        statusMessage = "Ready"
        overlayState.phase = .cancelled
        overlayController?.updateForPhase(.cancelled)
        syncCancelRecordingHotkey()
        logger.info("Recording cancelled by user", category: .transcription)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.shouldShowIdlePill {
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
        updateIdlePillVisibility()
    }

    /// Re-evaluates whether the pill should be visible based on current state.
    /// Call this when main window visibility, current tab, or insertion method changes.
    func updateIdlePillVisibility() {
        if shouldShowIdlePill {
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

    func startRecording() async {
        let model = modelManager.selectedModel

        if model.backend == .whisperCpp {
            guard modelManager.isModelReady else {
                if modelManager.isDownloading {
                    overlayState.phase = .modelDownloading
                    overlayController?.updateForPhase(.modelDownloading)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self else { return }
                        guard self.overlayState.phase == .modelDownloading else { return }
                        if self.shouldShowIdlePill {
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

        let mode = currentInputMode

        // Permission checks
        if mode == .microphone || mode == .mixed {
            if !Permissions.isMicrophoneAuthorized {
                statusMessage = "Microphone permission required"
                Permissions.requestMicrophone()
                Self.showMainWindow()
                return
            }
        }
        if mode == .systemAudio || mode == .mixed {
            if !Permissions.isScreenRecordingAuthorized {
                statusMessage = "Screen recording permission required for system audio"
                Permissions.requestScreenRecording()
                Self.showMainWindow()
                return
            }
        }

        // Capture accessibility context before recording starts (user is looking at target field)
        let captured = cursorPositionService.captureContext()
        if contextAwareFormatting {
            currentContext = captured
        } else {
            currentContext = nil
        }
        // Always record context for Chain of Thought visibility
        contextStore.recordContext(captured)

        do {
            switch mode {
            case .microphone:
                try audioRecorder.startRecording()
            case .systemAudio:
                try await systemAudioRecorder.startRecording()
            case .mixed:
                try await mixedAudioRecorder.startRecording()
            }
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.updateForPhase(.recording)
            syncCancelRecordingHotkey()
            logger.info("Recording started (mode: \(mode.rawValue))", category: .transcription)
        } catch {
            statusMessage = "Recording error: \(error.localizedDescription)"
            logger.error("Recording error: \(error.localizedDescription)", category: .transcription)
        }
    }

    // MARK: - Transcription

    func stopRecordingAndTranscribe() async {
        let mode = currentInputMode
        let samples: [Float]
        switch mode {
        case .microphone:
            samples = audioRecorder.stopRecording()
        case .systemAudio:
            samples = await systemAudioRecorder.stopRecording()
        case .mixed:
            samples = await mixedAudioRecorder.stopRecording()
        }
        isRecording = false
        syncCancelRecordingHotkey()

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            if shouldShowIdlePill {
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
            let result: TranscriptionResult

            if modelManager.selectedModel.backend == .whisperCpp {
                guard let modelURL = modelManager.modelFileURL else {
                    statusMessage = "Model not available"
                    isTranscribing = false
                    if shouldShowIdlePill {
                        overlayState.phase = .idle
                        overlayController?.updateForPhase(.idle)
                    } else {
                        overlayState.phase = .hidden
                        overlayController?.updateForPhase(.hidden)
                    }
                    return
                }
                result = try await transcriptionService.transcribe(
                    audioFrames: samples,
                    modelURL: modelURL
                )
            } else {
                result = try await transcriptionService.transcribe(
                    audioFrames: samples,
                    using: serverManager
                )
            }

            if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "No speech detected"
                logger.info("No speech detected in audio", category: .transcription)
            } else {
                // Apply context-aware formatting
                let formattedText = ContextAwareFormatter.format(result.text, context: currentContext)

                // Update Chain of Thought with formatting details
                if let ctx = currentContext {
                    let diff = formattedText != result.text
                        ? "Raw: \"\(result.text.prefix(60))\" -> Formatted: \"\(formattedText.prefix(60))\""
                        : "No changes applied"
                    contextStore.recordContext(ctx, formattingApplied: diff)
                }

                // Insert text using the configured method
                let insertionMethod = TextInsertionMethod(rawValue:
                    UserDefaults.standard.string(forKey: "textInsertionMethod") ?? "paste") ?? .paste
                var axInsertionResult: InsertionResult?

                switch insertionMethod {
                case .paste:
                    pasteService.paste(text: formattedText)
                case .keyPresses:
                    keyPressInsertionService.insert(text: formattedText)
                case .accessibility:
                    let result = accessibilityInsertionService.insert(text: formattedText)
                    axInsertionResult = result
                    if case .fallbackToPaste = result {
                        pasteService.paste(text: formattedText)
                    }
                }

                // Save original audio, then trim and save trimmed copy
                let entryID = UUID()
                do {
                    try AudioFileManager.shared.saveOriginalAudio(
                        samples: samples, entryID: entryID
                    )
                } catch {
                    logger.error("Failed to save original audio: \(error)", category: .general)
                }

                let trimResult = SilenceAnalyzer.trimLeadingSilence(from: samples)
                var audioFilename: String?
                do {
                    audioFilename = try AudioFileManager.shared.saveAudio(
                        samples: trimResult.samples,
                        entryID: entryID
                    )
                } catch {
                    logger.error("Failed to save audio: \(error)", category: .general)
                }

                // Generate and save waveform data
                let waveformData = WaveformDataGenerator.generate(
                    originalSamples: samples,
                    trimmedSamples: trimResult.samples,
                    trimOffsetMs: trimResult.trimOffsetMs,
                    sampleRate: 16000
                )
                AudioFileManager.shared.saveWaveformData(waveformData, for: entryID)

                // Shift timestamps to match trimmed audio (subtract the silence offset)
                let adjustedTimestamps: [WordTimestamp]?
                if !result.wordTimestamps.isEmpty, trimResult.trimOffsetMs > 0 {
                    adjustedTimestamps = result.wordTimestamps.map {
                        WordTimestamp(
                            id: $0.id, word: $0.word,
                            startTimeMs: max(0, $0.startTimeMs - trimResult.trimOffsetMs),
                            endTimeMs: max(0, $0.endTimeMs - trimResult.trimOffsetMs)
                        )
                    }
                } else if !result.wordTimestamps.isEmpty {
                    adjustedTimestamps = result.wordTimestamps
                } else {
                    adjustedTimestamps = nil
                }

                let trimmedDurationMs = Int(Double(trimResult.samples.count) / 16000 * 1000)
                let entry = TranscriptionEntry(
                    id: entryID,
                    text: result.text,
                    audioFilename: audioFilename,
                    wordTimestamps: adjustedTimestamps,
                    durationMs: trimmedDurationMs,
                    audioSource: {
                        switch mode {
                        case .microphone: return .microphone
                        case .systemAudio: return .systemAudio
                        case .mixed: return .mixed
                        }
                    }(),
                    appName: currentContext?.applicationName,
                    bundleIdentifier: currentContext?.bundleIdentifier
                )
                historyStore.addEntry(entry)

                // Trigger Echo Mode read-aloud if active
                if let axResult = axInsertionResult, case .success(let element, let range) = axResult {
                    echoNewEntryViaAX(entry, element: element, range: range)
                } else {
                    echoNewEntry(entry)
                }

                // Run timing analysis in the background if the server is available
                if entry.hasAudio {
                    processEntryTiming(entryID: entry.id, audioSamples: trimResult.samples)
                }

                statusMessage = "Pasted: \(String(formattedText.prefix(50)))\(formattedText.count > 50 ? "..." : "")"
            }
        } catch {
            statusMessage = "Transcription error: \(error.localizedDescription)"
            logger.error("Transcription error: \(error.localizedDescription)", category: .transcription)
        }

        isTranscribing = false
        if shouldShowIdlePill {
            overlayState.phase = .idle
            overlayController?.updateForPhase(.idle)
        } else {
            overlayState.phase = .hidden
            overlayController?.updateForPhase(.hidden)
        }
    }

    // MARK: - Audio file import

    var isImporting = false

    func importAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioFileImporter.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        statusMessage = "Importing audio..."

        Task {
            do {
                let importer = AudioFileImporter()
                let importResult = try await importer.decodeFile(url: url)

                guard modelManager.selectedModel.backend == .whisperCpp,
                      let modelURL = modelManager.modelFileURL else {
                    statusMessage = "Local model required for import transcription"
                    isImporting = false
                    return
                }

                let result = try await transcriptionService.transcribe(
                    audioFrames: importResult.samples,
                    modelURL: modelURL
                )

                let entryID = UUID()
                var audioFilename: String?
                do {
                    audioFilename = try AudioFileManager.shared.saveAudio(
                        samples: importResult.samples,
                        entryID: entryID
                    )
                } catch {
                    logger.error("Failed to save imported audio: \(error)", category: .general)
                }

                let entry = TranscriptionEntry(
                    id: entryID,
                    text: result.text,
                    audioFilename: audioFilename,
                    wordTimestamps: result.wordTimestamps.isEmpty ? nil : result.wordTimestamps,
                    durationMs: importResult.durationMs,
                    audioSource: .imported
                )
                historyStore.addEntry(entry)
                statusMessage = "Imported: \(url.lastPathComponent)"
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
                logger.error("Import failed: \(error.localizedDescription)", category: .transcription)
            }
            isImporting = false
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

    /// Start the timing model (Sherpa/Parakeet CTC) for word-level timestamps.
    /// Also ensures the main transcription model stays loaded if it's server-based.
    func startTimingServer() {
        guard !isSettingUpServer else { return }
        isSettingUpServer = true
        logger.info("Starting timing server...", category: .server)

        Task {
            do {
                // If the main model is server-based, ensure it's running first
                // so the venv has all deps and the main model stays loaded.
                if modelManager.selectedModel.requiresServer {
                    try await serverManager.ensureRunning(model: modelManager.selectedModel)
                }
                try await serverManager.ensureTimingAvailable()
                statusMessage = "Timing server ready"
                logger.info("Timing server is ready", category: .server)
            } catch {
                statusMessage = "Timing server error: \(error.localizedDescription)"
                logger.error("Timing server setup failed: \(error.localizedDescription)", category: .server)
            }
            isSettingUpServer = false
        }
    }

    /// Run timing analysis on a newly created entry in the background.
    /// Sends audio to the Sherpa timing model for CTC word-level timestamps
    /// and updates the entry.
    private func processEntryTiming(entryID: UUID, audioSamples: [Float]) {
        Task {
            do {
                // Ensure timing model is available (starts server if needed)
                try await serverManager.ensureTimingAvailable()

                let timestamps = try await serverManager.analyzeTiming(audioFrames: audioSamples)
                guard !timestamps.isEmpty else { return }

                // Match timing words to entry text
                guard let entry = historyStore.entries.first(where: { $0.id == entryID }) else { return }
                let entryWords = entry.text.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }

                let wordTimestamps: [WordTimestamp]
                if timestamps.count == entryWords.count {
                    wordTimestamps = entryWords.enumerated().map { i, word in
                        WordTimestamp(id: i, word: word, startTimeMs: timestamps[i].startMs, endTimeMs: timestamps[i].endMs)
                    }
                } else {
                    // Word count mismatch — use timing model's words directly
                    wordTimestamps = timestamps.enumerated().map { i, ts in
                        WordTimestamp(id: i, word: ts.word, startTimeMs: ts.startMs, endTimeMs: ts.endMs)
                    }
                }

                historyStore.updateTimestamps(id: entryID, wordTimestamps: wordTimestamps)
                logger.info("Timing analysis updated entry \(entryID) with \(wordTimestamps.count) word timestamps", category: .transcription)
            } catch {
                logger.debug("Timing analysis skipped for entry \(entryID): \(error.localizedDescription)", category: .transcription)
            }
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

    // MARK: - Echo Mode

    /// Sync EchoModeState from UserDefaults.
    /// Reads directly from UserDefaults rather than @AppStorage properties,
    /// because @AppStorage on non-View types can hold stale values.
    func syncEchoModeState() {
        let currentTTSMode = TTSMode(rawValue: UserDefaults.standard.string(forKey: "ttsMode") ?? "off") ?? .off
        let currentEchoEnabled = UserDefaults.standard.bool(forKey: "echoModeEnabled")
        let currentDockPos = DockPosition(rawValue: UserDefaults.standard.string(forKey: "echoModeDockPosition") ?? "bottom") ?? .bottom

        echoModeState.isActive = currentEchoEnabled && currentTTSMode == .speechify
        echoModeState.dockPosition = currentDockPos
        updateMainWindowVisibility()
        logger.info("Echo mode sync: active=\(echoModeState.isActive), mainWindowVisible=\(isMainWindowVisible), tts=\(currentTTSMode.rawValue), echo=\(currentEchoEnabled)", category: .tts)
        updateEchoModePanel()
    }

    /// Show or hide the echo mode panel based on current state.
    private func updateEchoModePanel() {
        let active = echoModeState.isActive
        let windowVisible = isMainWindowVisible
        let shouldShow = active && !windowVisible
        logger.info("Echo panel: active=\(active), windowVisible=\(windowVisible), shouldShow=\(shouldShow)", category: .tts)
        if shouldShow {
            echoModeController?.showPanel()
        } else {
            echoModeController?.hidePanel()
        }
    }

    /// Check if the main window is currently visible.
    private func updateMainWindowVisibility() {
        isMainWindowVisible = NSApplication.shared.windows.contains {
            !($0 is NSPanel) && $0.isVisible &&
            ($0.title == "OpenWhisper" || $0.identifier?.rawValue == "main")
        }
    }

    /// Called when TTS settings change.
    func onTTSSettingsChanged() {
        syncEchoModeState()
    }

    /// Called after a new transcription entry is added — triggers echo mode read via panel.
    private func echoNewEntry(_ entry: TranscriptionEntry) {
        guard echoModeState.isActive, !isMainWindowVisible else { return }
        echoModeController?.displayEntry(entry)
    }

    /// Echo mode via AX: select the inserted text range in the target app and trigger Speechify.
    /// No floating panel needed — the text is already in the target app's text field.
    private func echoNewEntryViaAX(_ entry: TranscriptionEntry, element: AXUIElement, range: CFRange) {
        guard echoModeState.isActive else { return }

        // Select the inserted text range in the target app
        accessibilityInsertionService.selectRange(element: element, range: range)

        // Trigger Speechify — target app is already active with the selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.speechifyService.triggerRead()
            self?.logger.info("Echo Mode (AX): triggered Speechify for entry \(entry.id)", category: .tts)
        }
    }

    // MARK: - AI Setup

    private func setupAIProviders() async {
        // Register MLX providers first (lightweight — just creates objects)
        for provider in mlxModelManager.createProviders() {
            providerRegistry.register(provider)
        }

        // Do heavy I/O work (filesystem scanning, network calls) in background
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Scan for models already on disk from other tools
            let catalog = MLXModelManager.catalog
            let downloadManager = await self.mlxModelManager.downloadManager
            let existingModels = await downloadManager.scanForExistingModels(catalog: catalog)
            for match in existingModels {
                do {
                    try await downloadManager.linkExternalModel(match)
                    await self.logger.info("Linked existing model \(match.modelID) from \(match.sourceName)", category: .general)
                } catch {
                    await self.logger.error("Failed to link model \(match.modelID): \(error)", category: .general)
                }
            }

            // Discover Ollama models (network call — may timeout if Ollama not running)
            await self.ollamaDiscovery.detect()
            let ollamaModels = await self.ollamaDiscovery.discoveredModels
            for provider in ollamaModels {
                await self.providerRegistry.register(provider)
            }

            // Register commercial providers (network calls to test keys)
            await self.registerCommercialProviders()
        }

        // Don't start care model on launch — it polls every 5s with AI inference.
        // User must explicitly enable it in Settings.
    }

    private func registerCommercialProviders() async {
        for service in CommercialKeyManager.Service.allCases {
            guard await commercialKeyManager.hasKey(for: service) else { continue }
            let result = await commercialKeyManager.testConnection(for: service, depth: .basic)
            guard result.success else { continue }

            let defaultCapabilities: Set<AICapability> = [.reasoning, .creativity, .editorialAnalysis, .codeGeneration, .multilingual]

            for modelID in result.accessibleModels {
                let provider: any AIProvider
                switch service {
                case .claude:
                    provider = ClaudeProvider(modelID: modelID, name: "Claude: \(modelID)", capabilities: defaultCapabilities.union([.longContext]), keyManager: await commercialKeyManager)
                case .gpt:
                    provider = GPTProvider(modelID: modelID, name: "GPT: \(modelID)", capabilities: defaultCapabilities, keyManager: await commercialKeyManager)
                case .gemini:
                    provider = GeminiProvider(modelID: modelID, name: "Gemini: \(modelID)", capabilities: defaultCapabilities.union([.fastInference]), keyManager: await commercialKeyManager)
                case .grok:
                    provider = GrokProvider(modelID: modelID, name: "Grok: \(modelID)", capabilities: defaultCapabilities, keyManager: await commercialKeyManager)
                }
                await providerRegistry.register(provider)
            }
        }
    }
}
