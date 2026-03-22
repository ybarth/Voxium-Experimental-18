import SwiftUI

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let appState: AppState

    @State private var isExpanded = false
    @State private var showEditForm = false
    @State private var showDeleteConfirm = false
    @State private var pronunciationRecorder = DictionaryPronunciationRecorder()

    private var dictionaryManager: DictionaryManager { appState.dictionaryManager }

    private var tier: ActivationTier { dictionaryManager.tier(for: entry) }

    private var tierColor: Color {
        switch tier {
        case .tier1: return .green
        case .tier2: return .orange
        case .tier3: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    // Spelling
                    Text(entry.spelling)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    // Tags
                    if !entry.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(entry.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(tagColor(for: tag).opacity(0.15),
                                                in: Capsule())
                                    .foregroundStyle(tagColor(for: tag))
                            }
                            if entry.tags.count > 3 {
                                Text("+\(entry.tags.count - 3)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Usage count
                    if entry.usageCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                            Text("\(entry.usageCount)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Tier badge
                    Text(tier.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tierColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(tierColor)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                expandedContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showEditForm) {
            DictionaryEntryForm(appState: appState, editingEntry: entry) {
                showEditForm = false
            }
        }
        .confirmationDialog(
            "Delete \"\(entry.spelling)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                dictionaryManager.deleteEntry(id: entry.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the word and its pronunciation recording.")
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Pronunciation
            VStack(alignment: .leading, spacing: 6) {
                Label("Pronunciation", systemImage: "waveform.badge.mic")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if pronunciationRecorder.isRecording {
                        Button {
                            if let filename = pronunciationRecorder.stopRecording() {
                                var updated = entry
                                // Delete old audio if exists
                                if let old = entry.audioFilename {
                                    pronunciationRecorder.deleteAudio(filename: old)
                                }
                                updated.audioFilename = filename
                                dictionaryManager.updateEntry(updated)
                            }
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text(String(format: "%.1fs", pronunciationRecorder.recordingDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        if let filename = entry.audioFilename {
                            Button {
                                pronunciationRecorder.play(filename: filename)
                            } label: {
                                Label(pronunciationRecorder.isPlaying ? "Playing…" : "Play",
                                      systemImage: pronunciationRecorder.isPlaying ? "speaker.wave.2.fill" : "play.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(pronunciationRecorder.isPlaying)

                            Button {
                                pronunciationRecorder.startRecording()
                            } label: {
                                Label("Re-record", systemImage: "mic.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button {
                                pronunciationRecorder.startRecording()
                            } label: {
                                Label("Record", systemImage: "mic.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let error = pronunciationRecorder.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Phonetic annotation
            if let phonetic = entry.phoneticAnnotation, !phonetic.isEmpty {
                LabeledRow(label: "Phonetic", value: phonetic)
            }

            // Context description
            if let context = entry.contextDescription, !context.isEmpty {
                LabeledRow(label: "Notes", value: context)
            }

            // App contexts
            if !entry.appContexts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Used in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(entry.appContexts, id: \.self) { bundleID in
                            Text(bundleID)
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Tier override picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Tier Override")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Tier Override", selection: Binding(
                    get: { entry.tierOverride },
                    set: { newValue in
                        var updated = entry
                        updated.tierOverride = newValue
                        dictionaryManager.updateEntry(updated)
                    }
                )) {
                    Text("Auto").tag(Optional<TierOverride>.none)
                    Text("Always Active (Tier 1)").tag(Optional<TierOverride>.some(.alwaysActive))
                    Text("Post-Processing Only (Tier 3)").tag(Optional<TierOverride>.some(.postProcessOnly))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Edit / Delete buttons
            HStack(spacing: 8) {
                Button {
                    showEditForm = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()

                if let lastUsed = entry.lastUsedDate {
                    Text("Last used \(lastUsed.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func tagColor(for tag: String) -> Color {
        let knownColors: [String: Color] = [
            "Names": .purple,
            "Technical": .blue,
            "Foreign Language": .teal,
            "Medical": .red,
            "Legal": .indigo,
            "Scientific": .cyan,
            "Abbreviations": .orange,
            "Slang/Informal": .pink
        ]
        return knownColors[tag] ?? .secondary
    }
}

// MARK: - Helpers

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

/// A simple horizontal flow layout that wraps to the next line when needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
                totalHeight = currentY
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
