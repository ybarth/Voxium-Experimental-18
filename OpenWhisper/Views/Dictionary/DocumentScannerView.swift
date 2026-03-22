import SwiftUI

// MARK: - DocumentScannerView

/// A two-phase sheet view for importing unknown words from a scanned document.
///
/// Phase 1 — Triage: shows a list of detected unknown words with checkboxes
///   so the user can choose which ones to add.
/// Phase 2 — Guided recording: walks through each selected word, letting the
///   user optionally record a pronunciation before confirming.
struct DocumentScannerView: View {

    let unknownWords: [UnknownWord]
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Triage state
    @State private var selectedIDs: Set<UUID> = []

    // MARK: - Guided recording state
    @State private var phase: Phase = .triage
    @State private var wordsToProcess: [UnknownWord] = []
    @State private var currentIndex: Int = 0
    @State private var pronunciationRecorder = DictionaryPronunciationRecorder()
    @State private var audioFilename: String?

    private var dictionaryManager: DictionaryManager { appState.dictionaryManager }

    // MARK: - Phase

    private enum Phase {
        case triage
        case guidedRecording
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .triage:
                triageView
            case .guidedRecording:
                guidedRecordingView
            }
        }
        .frame(minWidth: 520, minHeight: 440)
        .onAppear {
            // Pre-select all words
            selectedIDs = Set(unknownWords.map(\.id))
        }
    }

    // MARK: - Triage Phase

    private var triageView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanned Words")
                        .font(.headline)
                    Text("\(selectedIDs.count) of \(unknownWords.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Deselect All") {
                    selectedIDs = []
                }
                .controlSize(.small)

                Button("Select All") {
                    selectedIDs = Set(unknownWords.map(\.id))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if unknownWords.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No unknown words detected")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("The document appears to contain only standard vocabulary.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                List(unknownWords) { word in
                    TriageRowView(
                        word: word,
                        isSelected: selectedIDs.contains(word.id),
                        onToggle: { isOn in
                            if isOn { selectedIDs.insert(word.id) } else { selectedIDs.remove(word.id) }
                        }
                    )
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add Selected (\(selectedIDs.count))") {
                    beginGuidedRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Guided Recording Phase

    private var guidedRecordingView: some View {
        VStack(spacing: 0) {
            // Header with progress
            HStack {
                Text("Add Pronunciation")
                    .font(.headline)
                Spacer()
                Text("Word \(currentIndex + 1) of \(wordsToProcess.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Progress bar
            ProgressView(value: Double(currentIndex), total: Double(max(1, wordsToProcess.count)))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            Spacer()

            if currentIndex < wordsToProcess.count {
                let currentWord = wordsToProcess[currentIndex]

                VStack(spacing: 20) {
                    // Current word display
                    VStack(spacing: 6) {
                        Text(currentWord.word)
                            .font(.largeTitle.bold())

                        Text(currentWord.contextSentence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 20)
                    }

                    // Pronunciation recorder controls
                    recordingControls
                }
                .padding(.horizontal, 20)
            }

            Spacer()

            Divider()

            // Footer action buttons
            HStack(spacing: 12) {
                Button("Skip") {
                    advanceToNext()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Confirm") {
                    if currentIndex < wordsToProcess.count {
                        saveCurrentWord()
                        advanceToNext()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Recording Controls

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 12) {
            // Record / Stop
            Button {
                if pronunciationRecorder.isRecording {
                    if let filename = pronunciationRecorder.stopRecording() {
                        if let old = audioFilename {
                            pronunciationRecorder.deleteAudio(filename: old)
                        }
                        audioFilename = filename
                    }
                } else {
                    pronunciationRecorder.startRecording()
                }
            } label: {
                Label(
                    pronunciationRecorder.isRecording ? "Stop" : "Record",
                    systemImage: pronunciationRecorder.isRecording ? "stop.circle.fill" : "mic.circle"
                )
                .foregroundStyle(pronunciationRecorder.isRecording ? .red : .primary)
            }
            .buttonStyle(.bordered)

            // Play
            if let filename = audioFilename {
                Button {
                    if pronunciationRecorder.isPlaying {
                        pronunciationRecorder.stopPlayback()
                    } else {
                        pronunciationRecorder.play(filename: filename)
                    }
                } label: {
                    Label(
                        pronunciationRecorder.isPlaying ? "Stop" : "Play",
                        systemImage: pronunciationRecorder.isPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
            }

            // Status indicator
            if pronunciationRecorder.isRecording {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(String(format: "%.1fs", pronunciationRecorder.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if audioFilename != nil {
                Label("Recorded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        if let error = pronunciationRecorder.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func beginGuidedRecording() {
        wordsToProcess = unknownWords.filter { selectedIDs.contains($0.id) }
        currentIndex = 0
        audioFilename = nil
        phase = .guidedRecording
    }

    private func saveCurrentWord() {
        guard currentIndex < wordsToProcess.count else { return }

        // Stop any active recording first
        if pronunciationRecorder.isRecording {
            if let filename = pronunciationRecorder.stopRecording() {
                if let old = audioFilename {
                    pronunciationRecorder.deleteAudio(filename: old)
                }
                audioFilename = filename
            }
        }

        let word = wordsToProcess[currentIndex]
        let entry = DictionaryEntry(
            spelling: word.word,
            audioFilename: audioFilename,
            contextDescription: word.contextSentence
        )
        dictionaryManager.addEntry(entry)
    }

    private func advanceToNext() {
        // Stop any playback or recording before moving on
        pronunciationRecorder.stopPlayback()
        if pronunciationRecorder.isRecording {
            pronunciationRecorder.stopRecording()
        }
        audioFilename = nil

        let next = currentIndex + 1
        if next >= wordsToProcess.count {
            dismiss()
        } else {
            currentIndex = next
        }
    }
}

// MARK: - TriageRowView

private struct TriageRowView: View {
    let word: UnknownWord
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(word.word)
                    .font(.body.bold())

                Text(word.contextSentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Confidence bar: lower score = more likely custom
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.2))
                            .frame(height: 4)
                        Capsule()
                            .fill(confidenceColor(for: word.confidenceScore))
                            .frame(width: geo.size.width * (1.0 - word.confidenceScore), height: 4)
                    }
                }
                .frame(height: 4)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle(!isSelected)
        }
    }

    private func confidenceColor(for score: Double) -> Color {
        // Score near 0 = very likely custom → accent color
        // Score near 1 = probably standard → gray
        if score < 0.4 { return .accentColor }
        if score < 0.7 { return .orange }
        return .secondary
    }
}
