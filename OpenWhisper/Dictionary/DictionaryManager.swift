import Foundation
import SwiftUI

@MainActor
@Observable
final class DictionaryManager {

    // MARK: - State

    private(set) var entries: [DictionaryEntry] = []
    private var soundexIndex: [String: [DictionaryEntry]] = [:]
    private var metaphoneIndex: [String: [DictionaryEntry]] = [:]

    /// Selected text captured when the user triggers the "add to dictionary" hotkey.
    /// The dictionary view reads this to pre-fill the word input field.
    var pendingWordToAdd: String?

    private let store: DictionaryStore

    @ObservationIgnored
    @AppStorage("dictionaryTier1MaxSize") var tier1MaxSize: Int = 100

    @ObservationIgnored
    @AppStorage("dictionaryPromptBudget") var promptBudget: Int = 200

    // MARK: - Init

    init(store: DictionaryStore = LocalDictionaryStore()) {
        self.store = store
        loadEntries()
    }

    // MARK: - CRUD

    func addEntry(_ entry: DictionaryEntry) {
        entries.append(entry)
        rebuildIndexes()
        save()
    }

    func updateEntry(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            rebuildIndexes()
            save()
        }
    }

    func deleteEntry(id: UUID) {
        // Delete associated audio file
        if let entry = entries.first(where: { $0.id == id }),
           let audioFilename = entry.audioFilename {
            let audioURL = store.audioDirectory().appendingPathComponent(audioFilename)
            try? FileManager.default.removeItem(at: audioURL)
        }
        entries.removeAll { $0.id == id }
        rebuildIndexes()
        save()
    }

    func entry(for id: UUID) -> DictionaryEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Activation Engine

    /// Returns the most relevant dictionary words for the current context.
    /// Used to inject into transcription prompt (initial_prompt / hot-words).
    func relevantWords(for context: AccessibilityContext?) -> [String] {
        let tier1 = tier1Entries()
        let tier2 = tier2Entries(for: context)

        var combined = tier1.map(\.spelling)
        let tier1IDs = Set(tier1.map(\.id))
        for entry in tier2 where !tier1IDs.contains(entry.id) {
            combined.append(entry.spelling)
            if combined.count >= promptBudget { break }
        }

        return Array(combined.prefix(promptBudget))
    }

    /// Returns the computed tier for an entry.
    func tier(for entry: DictionaryEntry) -> ActivationTier {
        if let override = entry.tierOverride {
            switch override {
            case .alwaysActive: return .tier1
            case .postProcessOnly: return .tier3
            }
        }
        let tier1Set = Set(tier1Entries().map(\.id))
        if tier1Set.contains(entry.id) { return .tier1 }
        // Tier 2 check: used recently or in matching app context
        if let lastUsed = entry.lastUsedDate,
           Date().timeIntervalSince(lastUsed) < 7 * 24 * 3600 {
            return .tier2
        }
        return .tier3
    }

    // MARK: - Correction Engine

    /// Post-process transcription text to correct misrecognized words.
    func correctTranscription(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespaces)
        var corrected: [String] = []

        for word in words {
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            guard !stripped.isEmpty else {
                corrected.append(word)
                continue
            }

            // Don't correct real English words
            if PhoneticEngine.isStandardEnglishWord(stripped) {
                corrected.append(word)
                continue
            }

            // Find phonetic matches
            let matches = PhoneticEngine.findMatches(
                for: stripped,
                soundexIndex: soundexIndex,
                metaphoneIndex: metaphoneIndex
            )

            if let bestMatch = matches.sorted(by: { $0.usageCount > $1.usageCount }).first {
                // Preserve surrounding punctuation
                let prefix = word.prefix(while: \.isPunctuation)
                let suffix = word.reversed().prefix(while: \.isPunctuation).reversed()
                corrected.append("\(prefix)\(bestMatch.spelling)\(String(suffix))")
            } else {
                corrected.append(word)
            }
        }

        return corrected.joined(separator: " ")
    }

    // MARK: - Usage Stats

    /// Update usage statistics after a transcription.
    func updateUsageStats(transcribedText: String, bundleIdentifier: String?) {
        let transcribedWords = Set(
            transcribedText.components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        )

        for i in entries.indices {
            if transcribedWords.contains(entries[i].spelling.lowercased()) {
                entries[i].usageCount += 1
                entries[i].lastUsedDate = Date()
                if let bundleID = bundleIdentifier {
                    if !entries[i].appContexts.contains(bundleID) {
                        entries[i].appContexts.append(bundleID)
                        if entries[i].appContexts.count > 20 {
                            entries[i].appContexts.removeFirst()
                        }
                    }
                }
            }
        }
        save()
    }

    // MARK: - Search & Filter

    func search(query: String) -> [DictionaryEntry] {
        guard !query.isEmpty else { return entries }
        let lower = query.lowercased()
        return entries.filter {
            $0.spelling.lowercased().contains(lower) ||
            $0.tags.contains(where: { $0.lowercased().contains(lower) }) ||
            ($0.contextDescription?.lowercased().contains(lower) ?? false) ||
            ($0.phoneticAnnotation?.lowercased().contains(lower) ?? false)
        }
    }

    func entries(withTag tag: String) -> [DictionaryEntry] {
        entries.filter { $0.tags.contains(tag) }
    }

    var allTags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted()
    }

    // MARK: - Private

    private func tier1Entries() -> [DictionaryEntry] {
        let pinned = entries.filter { $0.tierOverride == .alwaysActive }
        let byUsage = entries
            .filter { $0.tierOverride != .postProcessOnly && $0.tierOverride != .alwaysActive }
            .sorted { $0.usageCount > $1.usageCount }
        let remaining = tier1MaxSize - pinned.count
        return pinned + Array(byUsage.prefix(max(0, remaining)))
    }

    private func tier2Entries(for context: AccessibilityContext?) -> [DictionaryEntry] {
        guard let context else { return [] }
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return entries
            .filter { $0.tierOverride != .postProcessOnly }
            .filter { entry in
                // Match by app context
                if let bundleID = context.bundleIdentifier,
                   entry.appContexts.contains(bundleID) { return true }
                // Match by recency
                if let lastUsed = entry.lastUsedDate, lastUsed > sevenDaysAgo { return true }
                return false
            }
            .sorted { ($0.lastUsedDate ?? .distantPast) > ($1.lastUsedDate ?? .distantPast) }
    }

    private func rebuildIndexes() {
        let indexes = PhoneticEngine.buildIndexes(from: entries)
        soundexIndex = indexes.soundex
        metaphoneIndex = indexes.metaphone
    }

    private func loadEntries() {
        entries = (try? store.loadEntries()) ?? []
        rebuildIndexes()
    }

    private func save() {
        try? store.saveEntries(entries)
    }
}
