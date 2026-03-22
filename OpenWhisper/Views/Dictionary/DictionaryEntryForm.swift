import SwiftUI

private let predefinedTags = [
    "Names", "Technical", "Foreign Language", "Medical",
    "Legal", "Scientific", "Abbreviations", "Slang/Informal"
]

struct DictionaryEntryForm: View {
    let appState: AppState
    var editingEntry: DictionaryEntry?
    var initialSpelling: String?
    let onDismiss: () -> Void

    @State private var spelling = ""
    @State private var selectedTags: Set<String> = []
    @State private var customTagInput = ""
    @State private var contextDescription = ""
    @State private var phoneticAnnotation = ""
    @State private var tierOverride: TierOverride?
    @State private var pronunciationRecorder = DictionaryPronunciationRecorder()
    @State private var audioFilename: String?

    private var dictionaryManager: DictionaryManager { appState.dictionaryManager }
    private var isEditing: Bool { editingEntry != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Word" : "Add Word")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    cleanupUnusedRecording()
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(spelling.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Spelling
                    FormSection(title: "Word", systemImage: "textformat") {
                        TextField("e.g. Kubernetes, Yishai, CRISPR", text: $spelling)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }

                    // Tags
                    FormSection(title: "Tags", systemImage: "tag") {
                        VStack(alignment: .leading, spacing: 8) {
                            // Predefined tag chips
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(predefinedTags, id: \.self) { tag in
                                    Toggle(tag, isOn: Binding(
                                        get: { selectedTags.contains(tag) },
                                        set: { isOn in
                                            if isOn { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
                                        }
                                    ))
                                    .toggleStyle(TagToggleStyle())
                                }
                            }

                            // Custom tag input
                            HStack(spacing: 6) {
                                TextField("Add custom tag…", text: $customTagInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                                    .onSubmit { addCustomTag() }

                                Button("Add") { addCustomTag() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(customTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            }

                            // Custom tags display
                            let customTags = selectedTags.filter { !predefinedTags.contains($0) }.sorted()
                            if !customTags.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(customTags, id: \.self) { tag in
                                        HStack(spacing: 4) {
                                            Text(tag)
                                                .font(.caption.weight(.medium))
                                            Button {
                                                selectedTags.remove(tag)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8, weight: .bold))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }

                    // Pronunciation
                    FormSection(title: "Pronunciation", systemImage: "waveform.badge.mic") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                if pronunciationRecorder.isRecording {
                                    Button {
                                        let filename = pronunciationRecorder.stopRecording()
                                        if let filename {
                                            // If editing, remove old file
                                            if let old = audioFilename {
                                                pronunciationRecorder.deleteAudio(filename: old)
                                            }
                                            audioFilename = filename
                                        }
                                    } label: {
                                        Label("Stop Recording", systemImage: "stop.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)

                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 6, height: 6)
                                        Text(String(format: "%.1fs", pronunciationRecorder.recordingDuration))
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
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
                                                systemImage: pronunciationRecorder.isPlaying
                                                    ? "stop.fill" : "play.fill"
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)

                                        Button {
                                            pronunciationRecorder.startRecording()
                                        } label: {
                                            Label("Re-record", systemImage: "mic.badge.plus")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)

                                        Button(role: .destructive) {
                                            pronunciationRecorder.deleteAudio(filename: filename)
                                            audioFilename = nil
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                        .tint(.red)
                                    } else {
                                        Button {
                                            pronunciationRecorder.startRecording()
                                        } label: {
                                            Label("Record Pronunciation", systemImage: "mic.circle")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                    }
                                }
                            }

                            if let error = pronunciationRecorder.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            if audioFilename != nil {
                                Label("Pronunciation recorded", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    // Phonetic annotation
                    FormSection(title: "Phonetic Annotation", systemImage: "textformat.abc", optional: true) {
                        TextField("e.g. yee-SHAY, koo-ber-NET-eez", text: $phoneticAnnotation)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }

                    // Context notes
                    FormSection(title: "Context Notes", systemImage: "note.text", optional: true) {
                        ZStack(alignment: .topLeading) {
                            if contextDescription.isEmpty {
                                Text("e.g. Name of a colleague, medical device brand, project name…")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 6)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $contextDescription)
                                .font(.body)
                                .frame(minHeight: 64, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Tier override
                    FormSection(title: "Tier Override", systemImage: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Tier Override", selection: $tierOverride) {
                                Text("Auto (recommended)").tag(Optional<TierOverride>.none)
                                Text("Always Active (Tier 1)").tag(Optional<TierOverride>.some(.alwaysActive))
                                Text("Post-Processing Only (Tier 3)").tag(Optional<TierOverride>.some(.postProcessOnly))
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()

                            Text(tierOverrideDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 480, maxWidth: 540, minHeight: 520)
        .onAppear { populateFields() }
    }

    // MARK: - Private

    private var tierOverrideDescription: String {
        switch tierOverride {
        case .none:
            return "The system automatically promotes frequently-used words to Tier 1."
        case .alwaysActive:
            return "Always included in the transcription prompt, regardless of usage frequency."
        case .postProcessOnly:
            return "Never injected into the prompt — only used during post-processing correction."
        }
    }

    private func populateFields() {
        if let entry = editingEntry {
            spelling = entry.spelling
            selectedTags = Set(entry.tags)
            contextDescription = entry.contextDescription ?? ""
            phoneticAnnotation = entry.phoneticAnnotation ?? ""
            tierOverride = entry.tierOverride
            audioFilename = entry.audioFilename
        } else if let pending = initialSpelling {
            spelling = pending
        }
    }

    private func addCustomTag() {
        let tag = customTagInput.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        selectedTags.insert(tag)
        customTagInput = ""
    }

    private func cleanupUnusedRecording() {
        // If we recorded a new file but are cancelling the form, clean it up
        // (but only if it wasn't the original entry's file)
        if let filename = audioFilename, filename != editingEntry?.audioFilename {
            pronunciationRecorder.deleteAudio(filename: filename)
        }
    }

    private func save() {
        let trimmed = spelling.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if var entry = editingEntry {
            entry.spelling = trimmed
            entry.tags = Array(selectedTags).sorted()
            entry.contextDescription = contextDescription.isEmpty ? nil : contextDescription
            entry.phoneticAnnotation = phoneticAnnotation.isEmpty ? nil : phoneticAnnotation
            entry.tierOverride = tierOverride
            entry.audioFilename = audioFilename
            entry.recomputePhoneticCodes()
            dictionaryManager.updateEntry(entry)
        } else {
            let entry = DictionaryEntry(
                spelling: trimmed,
                audioFilename: audioFilename,
                phoneticAnnotation: phoneticAnnotation.isEmpty ? nil : phoneticAnnotation,
                contextDescription: contextDescription.isEmpty ? nil : contextDescription,
                tags: Array(selectedTags).sorted(),
                tierOverride: tierOverride
            )
            dictionaryManager.addEntry(entry)
        }

        onDismiss()
    }
}

// MARK: - Supporting Views

private struct FormSection<Content: View>: View {
    let title: String
    let systemImage: String
    var optional = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if optional {
                    Text("optional")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

private struct TagToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    configuration.isOn
                        ? Color.accentColor
                        : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(configuration.isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
