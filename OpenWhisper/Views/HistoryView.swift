import AVFoundation
import SwiftUI

enum HistoryViewMode: String, CaseIterable {
    case text = "Text"
    case bars = "Bars"
    case hybrid = "Hybrid"
}

struct HistoryView: View {
    let historyStore: HistoryStore
    let appState: AppState
    @State private var entryToDelete: TranscriptionEntry?
    @State private var showDeleteAllConfirmation = false
    @State private var copiedEntryID: UUID?
    @State private var now = Date()
    @State private var expandedEntryID: UUID?
    @State private var playbackManager = AudioPlaybackManager()
    @State private var continuousPlayback = false
    @State private var continuousAscending = false
    @State private var showBackupList = false
    @State private var backupError: String?
    @State private var viewMode: HistoryViewMode = .text
    @State private var showSilentRegions = false
    @State private var loadedWaveforms: [UUID: WaveformData] = [:]
    @State private var selectionMode = false
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var showDeleteSelectedConfirmation = false
    @State private var entryAppearances: [UUID: EntryAppearanceOverride] = [:]
    @State private var appearancePopoverEntryID: UUID?

    var body: some View {
        if historyStore.entries.isEmpty {
            ContentUnavailableView(
                "No Transcriptions Yet",
                systemImage: "clock",
                description: Text("Your transcription history will appear here.")
            )
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Picker("", selection: $viewMode) {
                        ForEach(HistoryViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if viewMode == .bars {
                        Toggle("Show trimmed", isOn: $showSilentRegions)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .fixedSize()
                    }

                    Spacer()

                    Button {
                        startContinuousReading(ascending: false)
                    } label: {
                        Label("Read All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Read all entries, newest first")

                    Button {
                        appState.importAudioFile()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .disabled(appState.isImporting)

                    Button {
                        selectionMode.toggle()
                        if !selectionMode { selectedEntryIDs.removeAll() }
                    } label: {
                        Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(selectionMode ? "Exit selection mode" : "Select entries")

                    Menu {
                        Button("Backup History") {
                            createBackup()
                        }
                        Button("Restore Backup...") {
                            showBackupList = true
                        }
                        Divider()
                        Button("Delete All", role: .destructive) {
                            showDeleteAllConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Batch action bar (visible when entries are selected)
                if selectionMode && !selectedEntryIDs.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(selectedEntryIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Select All") {
                            selectedEntryIDs = Set(historyStore.entries.map(\.id))
                        }
                        .controlSize(.small)
                        .font(.caption)

                        Button("Copy") {
                            let texts = historyStore.entries
                                .filter { selectedEntryIDs.contains($0.id) }
                                .map(\.text)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
                        }
                        .controlSize(.small)
                        .font(.caption)

                        Button("Delete", role: .destructive) {
                            showDeleteSelectedConfirmation = true
                        }
                        .controlSize(.small)
                        .font(.caption)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(.bar)
                }

                List {
                    ForEach(historyStore.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            if selectionMode {
                                Button {
                                    if selectedEntryIDs.contains(entry.id) {
                                        selectedEntryIDs.remove(entry.id)
                                    } else {
                                        selectedEntryIDs.insert(entry.id)
                                    }
                                } label: {
                                    Image(systemName: selectedEntryIDs.contains(entry.id)
                                          ? "checkmark.circle.fill"
                                          : "circle")
                                        .font(.body)
                                        .foregroundStyle(selectedEntryIDs.contains(entry.id) ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 4)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                // Content area — branches on view mode
                                entryContentView(entry: entry)

                            HStack {
                                Text(relativeTime(from: entry.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let durationMs = entry.durationMs {
                                    Text("(\(formatDuration(durationMs)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if entry.hasAudio {
                                    Button {
                                        togglePlayback(for: entry)
                                    } label: {
                                        Image(systemName: expandedEntryID == entry.id
                                              ? "chevron.up.circle"
                                              : "play.circle")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(expandedEntryID == entry.id ? "Collapse" : "Play audio")
                                }

                                Button {
                                    copyEntry(entry)
                                } label: {
                                    if copiedEntryID == entry.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")

                                Button {
                                    appearancePopoverEntryID = entry.id
                                } label: {
                                    Image(systemName: "paintbrush")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Customize appearance")
                                .popover(isPresented: Binding(
                                    get: { appearancePopoverEntryID == entry.id },
                                    set: { if !$0 { appearancePopoverEntryID = nil } }
                                )) {
                                    EntryAppearancePopover(
                                        entryID: entry.id,
                                        overrides: entryAppearances[entry.id] ?? EntryAppearanceOverride(),
                                        onSave: { overrides in
                                            entryAppearances[entry.id] = overrides
                                            AudioFileManager.shared.saveEntryAppearance(overrides, for: entry.id)
                                        },
                                        onReset: {
                                            entryAppearances.removeValue(forKey: entry.id)
                                            let url = AudioFileManager.shared.appearanceFileURL(for: entry.id)
                                            try? FileManager.default.removeItem(at: url)
                                        }
                                    )
                                }

                                Button {
                                    entryToDelete = entry
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete")
                            }

                            // Inline playback controls
                            if expandedEntryID == entry.id {
                                PlaybackControlsView(
                                    playbackManager: playbackManager,
                                    continuousMode: $continuousPlayback
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .padding(.vertical, 4)
                            }
                            }
                        } // end HStack (checkbox + content)
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Copy") {
                                copyEntry(entry)
                            }
                            if entry.hasAudio {
                                Divider()
                                Button("Export Audio...") {
                                    exportAudio(for: entry)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                entryToDelete = entry
                            }
                        }
                    }

                    // Bottom continuous reading button
                    HStack {
                        Spacer()
                        Button {
                            startContinuousReading(ascending: true)
                        } label: {
                            Label("Read All (oldest first)", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 8)
                }
                .listStyle(.plain)
            }
            .alert("Delete All Transcriptions?", isPresented: $showDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) {
                    playbackManager.stop()
                    expandedEntryID = nil
                    historyStore.clearAll()
                }
            } message: {
                Text("This will permanently delete all \(historyStore.entries.count) transcriptions.")
            }
            .alert("Delete Selected?", isPresented: $showDeleteSelectedConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete \(selectedEntryIDs.count)", role: .destructive) {
                    for id in selectedEntryIDs {
                        if expandedEntryID == id {
                            playbackManager.stop()
                            expandedEntryID = nil
                        }
                        historyStore.delete(id: id)
                    }
                    selectedEntryIDs.removeAll()
                }
            } message: {
                Text("Delete \(selectedEntryIDs.count) selected transcriptions?")
            }
            .onAppear { startTimer() }
            .alert("Delete Transcription?",
                   isPresented: Binding(
                    get: { entryToDelete != nil },
                    set: { if !$0 { entryToDelete = nil } }
                   )
            ) {
                Button("Cancel", role: .cancel) {
                    entryToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let entry = entryToDelete {
                        if expandedEntryID == entry.id {
                            playbackManager.stop()
                            expandedEntryID = nil
                        }
                        historyStore.delete(id: entry.id)
                        entryToDelete = nil
                    }
                }
            } message: {
                if let entry = entryToDelete {
                    Text("Delete \"\(String(entry.text.prefix(60)))\(entry.text.count > 60 ? "..." : "")\"?")
                }
            }
            .sheet(isPresented: $showBackupList) {
                BackupListView(historyStore: historyStore, isPresented: $showBackupList)
            }
        }
    }

    // MARK: - Entry content by view mode

    @ViewBuilder
    private func entryContentView(entry: TranscriptionEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id

        switch viewMode {
        case .text:
            if isExpanded {
                PlayingEntryRow(entry: entry, playbackManager: playbackManager)
                    .transition(.opacity)
            } else {
                HighlightedTextView(
                    text: entry.text,
                    activeWordIndex: -1,
                    wordTimestamps: entry.wordTimestamps ?? [],
                    onWordTapped: { startPlayback(for: entry, atWord: $0) },
                    lineLimit: 4
                )
                .transition(.opacity)
            }

        case .bars:
            if let waveform = waveformForEntry(entry) {
                if isExpanded {
                    PlayingWaveformRow(
                        waveformData: waveform,
                        playbackManager: playbackManager,
                        showSilentRegions: showSilentRegions,
                        barAppearance: barAppearance(for: entry),
                        entryAppearance: entryAppearance(for: entry)
                    )
                } else {
                    WaveformBarView(
                        waveformData: waveform,
                        currentTimeMs: 0,
                        durationMs: entry.durationMs ?? waveform.trimmedDurationMs,
                        isPlaying: false,
                        showSilentRegions: showSilentRegions,
                        barAppearance: barAppearance(for: entry),
                        entryAppearance: entryAppearance(for: entry),
                        onSeek: { ms in startPlayback(for: entry, atMs: ms) }
                    )
                    .frame(height: 48)
                }
            } else {
                Text(entry.text)
                    .font(.body)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .onAppear { loadWaveform(for: entry); loadEntryAppearance(for: entry) }
            }

        case .hybrid:
            if isExpanded {
                VStack(spacing: 4) {
                    if let waveform = waveformForEntry(entry) {
                        PlayingWaveformRow(
                            waveformData: waveform,
                            playbackManager: playbackManager,
                            showSilentRegions: showSilentRegions,
                            barAppearance: barAppearance(for: entry),
                            entryAppearance: entryAppearance(for: entry)
                        )
                    }
                    PlayingEntryRow(entry: entry, playbackManager: playbackManager)
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let waveform = waveformForEntry(entry) {
                        WaveformBarView(
                            waveformData: waveform,
                            currentTimeMs: 0,
                            durationMs: entry.durationMs ?? waveform.trimmedDurationMs,
                            isPlaying: false,
                            showSilentRegions: showSilentRegions,
                            barAppearance: barAppearance(for: entry),
                            entryAppearance: entryAppearance(for: entry),
                            onSeek: { ms in startPlayback(for: entry, atMs: ms) }
                        )
                        .frame(height: 36)
                    }
                    HighlightedTextView(
                        text: entry.text,
                        activeWordIndex: -1,
                        wordTimestamps: entry.wordTimestamps ?? [],
                        onWordTapped: { startPlayback(for: entry, atWord: $0) },
                        lineLimit: 4
                    )
                }
                .transition(.opacity)
                .onAppear { loadWaveform(for: entry) }
            }
        }
    }

    private func waveformForEntry(_ entry: TranscriptionEntry) -> WaveformData? {
        if let cached = loadedWaveforms[entry.id] { return cached }
        return nil
    }

    private func loadWaveform(for entry: TranscriptionEntry) {
        guard loadedWaveforms[entry.id] == nil else { return }
        if let data = AudioFileManager.shared.loadWaveformData(for: entry.id) {
            loadedWaveforms[entry.id] = data
        }
    }

    private func barAppearance(for entry: TranscriptionEntry) -> BarAppearance {
        entryAppearances[entry.id]?.resolvedBar ?? AppearanceStore.globalBarAppearance
    }

    private func entryAppearance(for entry: TranscriptionEntry) -> BarAppearance {
        entryAppearances[entry.id]?.resolvedEntry ?? AppearanceStore.globalEntryAppearance
    }

    private func loadEntryAppearance(for entry: TranscriptionEntry) {
        guard entryAppearances[entry.id] == nil else { return }
        if let overrides = AudioFileManager.shared.loadEntryAppearance(for: entry.id) {
            entryAppearances[entry.id] = overrides
        }
    }

    // MARK: - Playback

    private func togglePlayback(for entry: TranscriptionEntry) {
        if expandedEntryID == entry.id {
            playbackManager.stop()
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedEntryID = nil
            }
        } else {
            startPlayback(for: entry)
        }
    }

    private func startPlayback(for entry: TranscriptionEntry, atWord wordIndex: Int? = nil) {
        playbackManager.stop()
        guard let audioURL = AudioFileManager.shared.loadAudioURL(for: entry.id) else { return }

        // Use the latest timestamps from the history store (timing analysis
        // may have updated them since this entry reference was captured).
        let latestEntry = historyStore.entries.first(where: { $0.id == entry.id }) ?? entry
        let timestamps = latestEntry.wordTimestamps ?? []

        playbackManager.load(
            url: audioURL,
            entryText: latestEntry.text,
            storedTimestamps: timestamps
        )

        // Wire continuous-playback callback
        playbackManager.onPlaybackFinished = { [self] in
            if continuousPlayback {
                advanceToNextEntry(after: entry)
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEntryID = entry.id
        }

        if let wordIndex {
            playbackManager.seekToWord(at: wordIndex)
        }
        playbackManager.togglePlayPause()

        // If timestamps look synthetic (start at 0 with no gaps), trigger
        // timing analysis and reload when done.
        if timestamps.isEmpty || (timestamps.first?.startTimeMs == 0 && entry.hasAudio) {
            Task {
                do {
                    try await appState.serverManager.ensureTimingAvailable()
                    guard let url = AudioFileManager.shared.loadAudioURL(for: entry.id) else { return }

                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return }
                    try file.read(into: buffer)
                    guard let data = buffer.floatChannelData else { return }
                    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))

                    let serverTs = try await appState.serverManager.analyzeTiming(audioFrames: samples)
                    guard !serverTs.isEmpty else { return }

                    let entryWords = latestEntry.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    let wordTs: [WordTimestamp]
                    if serverTs.count == entryWords.count {
                        wordTs = entryWords.enumerated().map { i, w in
                            WordTimestamp(id: i, word: w, startTimeMs: serverTs[i].startMs, endTimeMs: serverTs[i].endMs)
                        }
                    } else {
                        wordTs = serverTs.enumerated().map { i, ts in
                            WordTimestamp(id: i, word: ts.word, startTimeMs: ts.startMs, endTimeMs: ts.endMs)
                        }
                    }

                    historyStore.updateTimestamps(id: entry.id, wordTimestamps: wordTs)

                    // Reload into playback manager if still playing this entry
                    if expandedEntryID == entry.id {
                        let currentMs = playbackManager.currentTimeMs
                        let wasPlaying = playbackManager.isPlaying
                        playbackManager.load(url: audioURL, entryText: latestEntry.text, storedTimestamps: wordTs)
                        playbackManager.seek(toMs: currentMs)
                        if wasPlaying { playbackManager.togglePlayPause() }
                    }
                } catch {
                    // Non-fatal — playback continues with existing timestamps
                }
            }
        }
    }

    /// Start playback at a specific millisecond position (used by bar view click-to-seek).
    private func startPlayback(for entry: TranscriptionEntry, atMs ms: Int) {
        playbackManager.stop()
        guard let audioURL = AudioFileManager.shared.loadAudioURL(for: entry.id) else { return }

        let latestEntry = historyStore.entries.first(where: { $0.id == entry.id }) ?? entry
        playbackManager.load(
            url: audioURL,
            entryText: latestEntry.text,
            storedTimestamps: latestEntry.wordTimestamps ?? []
        )
        playbackManager.onPlaybackFinished = { [self] in
            if continuousPlayback { advanceToNextEntry(after: entry) }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEntryID = entry.id
        }
        playbackManager.seek(toMs: ms)
        playbackManager.togglePlayPause()
    }

    /// Advance to the next entry in the list for continuous playback.
    private func advanceToNextEntry(after current: TranscriptionEntry) {
        guard let currentIndex = historyStore.entries.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = continuousAscending ? currentIndex - 1 : currentIndex + 1

        guard nextIndex >= 0, nextIndex < historyStore.entries.count else {
            // Reached the end
            continuousPlayback = false
            return
        }

        let nextEntry = historyStore.entries[nextIndex]
        guard nextEntry.hasAudio else {
            advanceToNextEntry(after: nextEntry)
            return
        }
        startPlayback(for: nextEntry)
    }

    private func startContinuousReading(ascending: Bool) {
        continuousAscending = ascending
        continuousPlayback = true

        let entries = historyStore.entries // already sorted newest-first
        let startEntry = ascending
            ? entries.last(where: { $0.hasAudio })
            : entries.first(where: { $0.hasAudio })

        guard let entry = startEntry else { return }
        startPlayback(for: entry)
    }

    // MARK: - Backup

    private func createBackup() {
        do {
            let url = try historyStore.createBackup()
            backupError = nil
            TranscriptionLogger.shared.info("Backup created at \(url.path)", category: .general)
        } catch {
            backupError = error.localizedDescription
            TranscriptionLogger.shared.error("Backup failed: \(error)", category: .general)
        }
    }

    // MARK: - Export

    private func exportAudio(for entry: TranscriptionEntry) {
        guard let audioURL = AudioFileManager.shared.loadAudioURL(for: entry.id) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcription_\(entry.date.formatted(.dateTime.year().month().day()))"
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            let format = AudioExportFormat.from(url: destURL)
            try AudioExporter.export(sourceURL: audioURL, to: destURL, format: format)
        } catch {
            TranscriptionLogger.shared.error("Export failed: \(error)", category: .general)
        }
    }

    // MARK: - Helpers

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in now = Date() }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }
        let hours = Int(seconds / 3600)
        if hours < 24 {
            return hours == 1 ? "1 hr ago" : "\(hours) hrs ago"
        }
        let days = Int(seconds / 86400)
        if days == 1 {
            return "yesterday"
        }
        return "\(days) days ago"
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }

    private func copyEntry(_ entry: TranscriptionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedEntryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }
}

// MARK: - Playing entry row (isolated observation scope)

/// Extracted so that playbackManager.activeWordIndex changes (at 30 Hz)
/// only re-render the highlighted text, not the entire List body.
private struct PlayingEntryRow: View {
    let entry: TranscriptionEntry
    let playbackManager: AudioPlaybackManager

    var body: some View {
        HighlightedTextView(
            text: entry.text,
            activeWordIndex: playbackManager.activeWordIndex,
            wordTimestamps: playbackManager.timestamps,
            onWordTapped: { playbackManager.seekToWord(at: $0) }
        )
    }
}

// MARK: - Playing waveform row (isolated observation scope)

/// Isolated so playbackManager.currentTimeMs at 30Hz only re-renders the playhead,
/// not the entire List body.
private struct PlayingWaveformRow: View {
    let waveformData: WaveformData
    let playbackManager: AudioPlaybackManager
    var showSilentRegions: Bool = false
    var barAppearance: BarAppearance = AppearanceStore.globalBarAppearance
    var entryAppearance: BarAppearance = AppearanceStore.globalEntryAppearance

    var body: some View {
        WaveformBarView(
            waveformData: waveformData,
            currentTimeMs: playbackManager.currentTimeMs,
            durationMs: playbackManager.durationMs,
            isPlaying: playbackManager.isPlaying,
            showSilentRegions: showSilentRegions,
            barAppearance: barAppearance,
            entryAppearance: entryAppearance,
            onSeek: { playbackManager.seek(toMs: $0) }
        )
        .frame(height: 48)
    }
}

// MARK: - Backup list sheet

private struct BackupListView: View {
    let historyStore: HistoryStore
    @Binding var isPresented: Bool
    @State private var backups: [(name: String, url: URL, date: Date?)] = []
    @State private var restoreError: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Restore from Backup")
                .font(.headline)
                .padding()

            if backups.isEmpty {
                Text("No backups available.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(backups, id: \.name) { backup in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(backup.name)
                                .font(.body)
                            if let date = backup.date {
                                Text(date.formatted(.dateTime))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Restore") {
                            restoreBackup(backup.url)
                        }
                        .controlSize(.small)
                    }
                }
            }

            if let error = restoreError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .onAppear {
            backups = historyStore.availableBackups()
        }
    }

    private func restoreBackup(_ url: URL) {
        do {
            try historyStore.restoreBackup(from: url)
            restoreError = nil
            isPresented = false
        } catch {
            restoreError = "Restore failed: \(error.localizedDescription)"
        }
    }
}
