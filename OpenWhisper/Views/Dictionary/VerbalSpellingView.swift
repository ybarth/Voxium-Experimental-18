import SwiftUI

// MARK: - VerbalSpellingView

/// A sheet view for spelling a word verbally, letter by letter.
///
/// Supports three modes:
/// - **Regular**: speak each letter name ("ay", "bee", "see"…)
/// - **NATO**: use NATO phonetic alphabet ("Alpha", "Bravo", "Charlie"…)
/// - **IPA**: speak IPA symbols to build a phonetic annotation
///
/// When the user taps Done, the assembled word is passed to the completion
/// handler so the caller can present `DictionaryEntryForm` or save directly.
struct VerbalSpellingView: View {

    let appState: AppState
    /// Called when the user confirms. Provides (spelling, ipaAnnotation, mode).
    let onComplete: (_ spelling: String, _ ipaAnnotation: String?, _ mode: PhoneticMethod) -> Void
    let onDismiss: () -> Void

    @State private var engine = VerbalSpellingEngine()
    @State private var pronunciationRecorder = DictionaryPronunciationRecorder()
    @State private var isListening = false
    @State private var isTranscribing = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Spell by Voice")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    stopListeningIfNeeded()
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 24) {

                    // Mode picker
                    Picker("Mode", selection: $engine.mode) {
                        ForEach(PhoneticMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .onChange(of: engine.mode) { _, _ in
                        stopListeningIfNeeded()
                        errorMessage = nil
                    }

                    // Instructions
                    Text(instructionsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    // Assembled word display
                    VStack(spacing: 6) {
                        Text(displayedWord.isEmpty ? "…" : displayedWord)
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundStyle(displayedWord.isEmpty ? .tertiary : .primary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 20)

                        if engine.mode == .ipa && !engine.ipaAnnotation.isEmpty {
                            Text("/\(engine.ipaAnnotation)/")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Recording status
                    recordingStatusView

                    // Error
                    if let error = errorMessage ?? pronunciationRecorder.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Control row: Undo / Clear
                    HStack(spacing: 12) {
                        Button {
                            engine.undoLastCharacter()
                        } label: {
                            Label("Undo Last", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .disabled(displayedWord.isEmpty)

                        Button {
                            engine.clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(displayedWord.isEmpty)
                    }
                }
                .padding(.vertical, 20)
            }

            Divider()

            // Footer
            HStack(spacing: 12) {
                // Main mic button
                Button {
                    toggleListening()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isListening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3)
                        Text(isListening ? "Stop Listening" : "Start Listening")
                    }
                }
                .buttonStyle(.bordered)
                .tint(isListening ? .red : .accentColor)
                .controlSize(.large)
                .disabled(isTranscribing)

                Spacer()

                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Done") {
                    stopListeningIfNeeded()
                    let word = engine.assembledWord
                    let ipa = engine.ipaAnnotation.isEmpty ? nil : engine.ipaAnnotation
                    onComplete(word, ipa, engine.mode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayedWord.isEmpty || isTranscribing)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 400, idealWidth: 460, maxWidth: 520, minHeight: 480)
    }

    // MARK: - Recording Status

    @ViewBuilder
    private var recordingStatusView: some View {
        HStack(spacing: 8) {
            if isTranscribing {
                ProgressView()
                    .controlSize(.mini)
                Text("Processing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isListening {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(isListening ? 1 : 0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isListening)
                Text("Listening…")
                    .font(.subheadline)
                    .foregroundStyle(.red)

                if pronunciationRecorder.isRecording {
                    Text(String(format: "%.1fs", pronunciationRecorder.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tap \"Start Listening\" and speak letters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Computed Helpers

    private var displayedWord: String {
        engine.currentWord()
    }

    private var instructionsText: String {
        switch engine.mode {
        case .regular:
            return "Speak each letter name: \"ay\", \"bee\", \"see\"…"
        case .nato:
            return "Use NATO alphabet: \"Alpha\", \"Bravo\", \"Charlie\"…"
        case .ipa:
            return "Speak IPA symbols: \"ʃ\", \"æ\", \"ɪ\"…"
        }
    }

    // MARK: - Recording Flow

    private func toggleListening() {
        if isListening {
            stopListeningIfNeeded()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard !pronunciationRecorder.isRecording, !isTranscribing else { return }
        errorMessage = nil
        pronunciationRecorder.startRecording()
        isListening = true
    }

    /// Stops active recording, converts the CAF to Float32, and transcribes.
    private func stopListeningIfNeeded() {
        guard isListening else { return }
        isListening = false

        guard pronunciationRecorder.isRecording else { return }
        guard let filename = pronunciationRecorder.stopRecording() else { return }

        let audioDir = LocalDictionaryStore().audioDirectory()
        let fileURL = audioDir.appendingPathComponent(filename)

        transcribeSpellingAudio(at: fileURL)
    }

    /// Reads the recorded CAF file, resamples to 16 kHz Float32, and passes to Whisper.
    private func transcribeSpellingAudio(at fileURL: URL) {
        isTranscribing = true
        errorMessage = nil

        Task {
            defer {
                // Always clean up the temp audio file used for spelling
                try? FileManager.default.removeItem(at: fileURL)
                isTranscribing = false
            }

            // Decode audio to 16 kHz Float32
            let importer = AudioFileImporter()
            let importResult: AudioFileImporter.ImportResult
            do {
                importResult = try await importer.decodeFile(url: fileURL)
            } catch {
                errorMessage = "Audio decode failed: \(error.localizedDescription)"
                return
            }

            guard importResult.samples.count > 0 else {
                errorMessage = "No audio captured"
                return
            }

            // Transcribe using the app's active model
            do {
                let transcriptionResult: TranscriptionResult

                if appState.modelManager.selectedModel.backend == .whisperCpp {
                    guard let modelURL = appState.modelManager.modelFileURL else {
                        errorMessage = "Whisper model not available"
                        return
                    }
                    transcriptionResult = try await appState.transcriptionService.transcribe(
                        audioFrames: importResult.samples,
                        modelURL: modelURL
                    )
                } else {
                    transcriptionResult = try await appState.transcriptionService.transcribe(
                        audioFrames: importResult.samples,
                        using: appState.serverManager
                    )
                }

                let text = transcriptionResult.text
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = "No speech detected — try again"
                } else {
                    engine.processTranscribedText(text)
                }
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }
}
