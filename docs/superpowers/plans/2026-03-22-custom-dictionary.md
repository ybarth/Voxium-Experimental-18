# Custom Dictionary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a custom word dictionary with pronunciation recordings, phonetic matching, tiered activation, document scanning, and transcription integration.

**Architecture:** Semi-independent `DictionaryManager` subsystem with two narrow integration points into `AppState`'s transcription flow (prompt injection before transcription, correction after). Storage via JSON + audio files with a protocol abstraction for future sync. Phonetic matching via Soundex + Metaphone indexes for O(1) correction lookups.

**Tech Stack:** Swift/SwiftUI, AVAudioEngine (pronunciation recording), PDFKit (PDF extraction), Soundex/Metaphone (in-house), system dictionary (`/usr/share/dict/words`)

**Spec:** `docs/superpowers/specs/2026-03-20-custom-dictionary-design.md`

**Note on testing:** This project has no test infrastructure (per CLAUDE.md). Each task verifies correctness via build + manual verification.

---

## File Structure

### New Directory: `OpenWhisper/Dictionary/`

**Data & Storage:**
- `DictionaryEntry.swift` — `DictionaryEntry` struct, `PhoneticMethod`, `TierOverride`, `ActivationTier` enums
- `DictionaryStore.swift` — `DictionaryStore` protocol + `LocalDictionaryStore` (JSON persistence + audio file management)

**Core Logic:**
- `DictionaryManager.swift` — `@Observable` orchestrator: activation engine, correction engine, usage stats
- `PhoneticEngine.swift` — Soundex + Metaphone computation, phonetic index, correction matching
- `DictionaryPronunciationRecorder.swift` — Own `AVAudioEngine` for recording/playing pronunciations

**Features:**
- `VerbalSpellingEngine.swift` — Regular/NATO/IPA letter mapping + word assembly
- `DocumentScanner.swift` — Text extraction (PDF/DOCX/RTF/MD), unknown word detection, confidence scoring

### New Directory: `OpenWhisper/Views/Dictionary/`

- `DictionaryView.swift` — Main dictionary tab (toolbar + list + status bar)
- `DictionaryEntryRow.swift` — Collapsed/expanded entry row
- `DictionaryEntryForm.swift` — Add/edit form (shared by all add-word modes)
- `DictionaryQuickPopup.swift` — Small floating NSPanel for Quick Pop-up mode
- `DocumentScannerView.swift` — Triage list + guided recording wizard
- `VerbalSpellingView.swift` — Real-time letter assembly UI

### Modified Files

- `OpenWhisper/Hotkey/HotkeyNames.swift` — Add `addToDictionary` shortcut
- `OpenWhisper/AppState.swift` — Add `DictionaryManager`, integrate into transcription flow, register hotkey
- `OpenWhisper/Transcription/TranscriptionService.swift` — Accept optional `dictionaryWords: [String]` parameter
- `OpenWhisper/Views/MainWindowView.swift` — Add Dictionary tab
- `OpenWhisper/Views/SettingsView.swift` or `OpenWhisper/Views/SettingsTabView.swift` — Add Dictionary settings section

---

## Task 1: Data Model & Storage

**Files:**
- Create: `OpenWhisper/Dictionary/DictionaryEntry.swift`
- Create: `OpenWhisper/Dictionary/DictionaryStore.swift`

- [ ] **Step 1: Create the Dictionary directory**

```bash
mkdir -p "OpenWhisper/Dictionary"
```

- [ ] **Step 2: Write DictionaryEntry.swift**

All data types for dictionary entries:

```swift
import Foundation

struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    var spelling: String
    var audioFilename: String?
    var phoneticAnnotation: String?
    var phoneticMethod: PhoneticMethod?
    var contextDescription: String?
    var soundexCode: String
    var metaphoneCode: String
    var tags: [String]
    var usageCount: Int
    var lastUsedDate: Date?
    var appContexts: [String]
    var createdDate: Date
    var tierOverride: TierOverride?

    init(
        id: UUID = UUID(),
        spelling: String,
        audioFilename: String? = nil,
        phoneticAnnotation: String? = nil,
        phoneticMethod: PhoneticMethod? = nil,
        contextDescription: String? = nil,
        tags: [String] = [],
        tierOverride: TierOverride? = nil
    ) {
        self.id = id
        self.spelling = spelling
        self.audioFilename = audioFilename
        self.phoneticAnnotation = phoneticAnnotation
        self.phoneticMethod = phoneticMethod
        self.contextDescription = contextDescription
        self.soundexCode = PhoneticEngine.soundex(spelling)
        self.metaphoneCode = PhoneticEngine.metaphone(spelling)
        self.tags = tags
        self.usageCount = 0
        self.lastUsedDate = nil
        self.appContexts = []
        self.createdDate = Date()
        self.tierOverride = tierOverride
    }

    mutating func recomputePhoneticCodes() {
        soundexCode = PhoneticEngine.soundex(spelling)
        metaphoneCode = PhoneticEngine.metaphone(spelling)
    }
}

enum PhoneticMethod: String, Codable, CaseIterable {
    case regular
    case nato
    case ipa

    var displayName: String {
        switch self {
        case .regular: return "Regular Alphabet"
        case .nato: return "NATO Alphabet"
        case .ipa: return "IPA"
        }
    }
}

enum TierOverride: String, Codable, CaseIterable {
    case alwaysActive
    case postProcessOnly

    var displayName: String {
        switch self {
        case .alwaysActive: return "Always Active (Tier 1)"
        case .postProcessOnly: return "Post-Processing Only (Tier 3)"
        }
    }
}

enum ActivationTier: String {
    case tier1
    case tier2
    case tier3

    var displayName: String {
        switch self {
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        case .tier3: return "Tier 3"
        }
    }
}
```

Note: `DictionaryEntry.init` calls `PhoneticEngine.soundex/metaphone` — PhoneticEngine is created in Task 2. For this task to compile, either create a stub or implement Tasks 1 and 2 together. The plan groups them so the subagent should create both files before building.

- [ ] **Step 3: Write DictionaryStore.swift**

```swift
import Foundation

protocol DictionaryStore: Sendable {
    func loadEntries() throws -> [DictionaryEntry]
    func saveEntries(_ entries: [DictionaryEntry]) throws
    func audioDirectory() -> URL
}

final class LocalDictionaryStore: DictionaryStore {
    private let baseDirectory: URL
    private let dictionaryFile: URL
    private let audioDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("OpenWhisper/Dictionary", isDirectory: true)
        self.dictionaryFile = baseDirectory.appendingPathComponent("dictionary.json")
        self.audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    func loadEntries() throws -> [DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: dictionaryFile.path) else { return [] }
        let data = try Data(contentsOf: dictionaryFile)
        return try JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    func saveEntries(_ entries: [DictionaryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: dictionaryFile, options: .atomic)
    }

    func audioDirectory() -> URL { audioDir }
}
```

- [ ] **Step 4: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/DictionaryEntry.swift OpenWhisper/Dictionary/DictionaryStore.swift
git commit -m "feat: add DictionaryEntry data model and LocalDictionaryStore with JSON persistence"
```

---

## Task 2: Phonetic Engine (Soundex + Metaphone)

**Files:**
- Create: `OpenWhisper/Dictionary/PhoneticEngine.swift`

- [ ] **Step 1: Write PhoneticEngine.swift**

Implements Soundex and Metaphone algorithms plus a phonetic index for fast lookups. Also loads the system dictionary for the "is this a real English word?" check.

```swift
import Foundation

struct PhoneticEngine {

    // MARK: - Soundex

    static func soundex(_ word: String) -> String {
        let upper = word.uppercased().filter(\.isLetter)
        guard let first = upper.first else { return "" }

        let mapping: [Character: Character] = [
            "B": "1", "F": "1", "P": "1", "V": "1",
            "C": "2", "G": "2", "J": "2", "K": "2", "Q": "2", "S": "2", "X": "2", "Z": "2",
            "D": "3", "T": "3",
            "L": "4",
            "M": "5", "N": "5",
            "R": "6",
        ]

        var code = String(first)
        var lastCode: Character? = mapping[first]

        for char in upper.dropFirst() {
            guard let mapped = mapping[char] else {
                lastCode = nil
                continue
            }
            if mapped != lastCode {
                code.append(mapped)
                if code.count == 4 { break }
            }
            lastCode = mapped
        }

        while code.count < 4 { code.append("0") }
        return code
    }

    // MARK: - Metaphone

    static func metaphone(_ word: String) -> String {
        let upper = word.uppercased().filter(\.isLetter)
        guard !upper.isEmpty else { return "" }

        var chars = Array(upper)
        var result = ""
        var i = 0

        // Drop initial silent letters
        if chars.count >= 2 {
            let prefix = String(chars.prefix(2))
            if ["AE", "GN", "KN", "PN", "WR"].contains(prefix) {
                chars.removeFirst()
            }
        }

        while i < chars.count && result.count < 6 {
            let c = chars[i]
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            // Skip duplicate adjacent letters (except C)
            if c == prev && c != "C" {
                i += 1
                continue
            }

            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { result.append(c) }
            case "B":
                if prev != "M" { result.append("B") }
            case "C":
                if next == "H" { result.append("X"); i += 1 }
                else if next == "I" || next == "E" || next == "Y" { result.append("S") }
                else { result.append("K") }
            case "D":
                if next == "G" { /* skip */ } else { result.append("T") }
            case "F": result.append("F")
            case "G":
                if next == "H" && i + 2 < chars.count && !"AEIOU".contains(chars[i + 2]) {
                    i += 1
                } else if i > 0 && (next == "N" || next == nil) {
                    // silent
                } else { result.append("J") }
            case "H":
                if "AEIOU".contains(next ?? " ") && (prev == nil || !"AEIOU".contains(prev!)) {
                    result.append("H")
                }
            case "J": result.append("J")
            case "K":
                if prev != "C" { result.append("K") }
            case "L": result.append("L")
            case "M": result.append("M")
            case "N": result.append("N")
            case "P":
                if next == "H" { result.append("F"); i += 1 }
                else { result.append("P") }
            case "Q": result.append("K")
            case "R": result.append("R")
            case "S":
                if next == "H" { result.append("X"); i += 1 }
                else if next == "I" && i + 2 < chars.count && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X"); i += 2
                }
                else { result.append("S") }
            case "T":
                if next == "H" { result.append("0"); i += 1 }
                else if next == "I" && i + 2 < chars.count && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X"); i += 2
                }
                else { result.append("T") }
            case "V": result.append("F")
            case "W", "Y":
                if let next, "AEIOU".contains(next) { result.append(c) }
            case "X": result.append("KS")
            case "Z": result.append("S")
            default: break
            }
            i += 1
        }

        return result
    }

    // MARK: - System Dictionary

    private static let systemWords: Set<String> = {
        guard let data = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(data.components(separatedBy: .newlines).map { $0.lowercased() })
    }()

    static func isStandardEnglishWord(_ word: String) -> Bool {
        systemWords.contains(word.lowercased())
    }

    // MARK: - Phonetic Index

    /// Builds lookup indexes from dictionary entries for fast correction.
    /// Returns: (soundexIndex, metaphoneIndex)
    static func buildIndexes(from entries: [DictionaryEntry]) -> (soundex: [String: [DictionaryEntry]], metaphone: [String: [DictionaryEntry]]) {
        var soundex: [String: [DictionaryEntry]] = [:]
        var metaphone: [String: [DictionaryEntry]] = [:]
        for entry in entries {
            soundex[entry.soundexCode, default: []].append(entry)
            metaphone[entry.metaphoneCode, default: []].append(entry)
        }
        return (soundex, metaphone)
    }

    /// Find dictionary entries that phonetically match a given word.
    /// Both Soundex AND Metaphone must match for a confident result.
    static func findMatches(
        for word: String,
        soundexIndex: [String: [DictionaryEntry]],
        metaphoneIndex: [String: [DictionaryEntry]]
    ) -> [DictionaryEntry] {
        let wordSoundex = soundex(word)
        let wordMetaphone = metaphone(word)

        let soundexMatches = Set(soundexIndex[wordSoundex, default: []].map(\.id))
        let metaphoneMatches = Set(metaphoneIndex[wordMetaphone, default: []].map(\.id))
        let bothMatch = soundexMatches.intersection(metaphoneMatches)

        let allEntries = (soundexIndex[wordSoundex, default: []] + metaphoneIndex[wordMetaphone, default: []])
        return allEntries.filter { bothMatch.contains($0.id) }
            .reduce(into: [UUID: DictionaryEntry]()) { $0[$1.id] = $1 }
            .values.map { $0 }
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/PhoneticEngine.swift
git commit -m "feat: add PhoneticEngine with Soundex, Metaphone, system dictionary check, and phonetic indexing"
```

---

## Task 3: Dictionary Manager (Core Orchestrator)

**Files:**
- Create: `OpenWhisper/Dictionary/DictionaryManager.swift`

- [ ] **Step 1: Write DictionaryManager.swift**

The central orchestrator with activation engine, correction engine, and usage stats:

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class DictionaryManager {

    // MARK: - State

    private(set) var entries: [DictionaryEntry] = []
    private var soundexIndex: [String: [DictionaryEntry]] = [:]
    private var metaphoneIndex: [String: [DictionaryEntry]] = [:]

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
```

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/DictionaryManager.swift
git commit -m "feat: add DictionaryManager with activation engine, correction engine, and usage stats"
```

---

## Task 4: Pronunciation Recorder

**Files:**
- Create: `OpenWhisper/Dictionary/DictionaryPronunciationRecorder.swift`

- [ ] **Step 1: Write DictionaryPronunciationRecorder.swift**

Own AVAudioEngine instance for recording and playing pronunciation audio, separate from the main transcription recorder. Records to CAF files in the dictionary audio directory.

Key points:
- Records at 44.1kHz (standard for playback, unlike the 16kHz transcription recorder)
- Saves to the dictionary audio directory with a UUID filename
- Playback via AVAudioPlayer
- Returns the filename so it can be stored on the DictionaryEntry

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/DictionaryPronunciationRecorder.swift
git commit -m "feat: add DictionaryPronunciationRecorder with AVAudioEngine recording and playback"
```

---

## Task 5: Verbal Spelling Engine

**Files:**
- Create: `OpenWhisper/Dictionary/VerbalSpellingEngine.swift`

- [ ] **Step 1: Write VerbalSpellingEngine.swift**

Maps spoken letters (regular alphabet), NATO words, or IPA symbols to characters. Includes the full NATO alphabet lookup table. Processes transcribed text from the speech recognition engine and assembles the spelled word character by character.

Key points:
- NATO lookup: "Alpha" → "A", "Bravo" → "B", etc. (case-insensitive)
- Regular: Recognizes spoken letter names ("ay" → "A", "bee" → "B", etc.)
- IPA: Validates against known IPA symbols, stores as annotation rather than building spelling
- Supports undo-last-character and clear operations

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/VerbalSpellingEngine.swift
git commit -m "feat: add VerbalSpellingEngine with Regular, NATO, and IPA letter mapping"
```

---

## Task 6: Document Scanner

**Files:**
- Create: `OpenWhisper/Dictionary/DocumentScanner.swift`

- [ ] **Step 1: Write DocumentScanner.swift**

Text extraction from PDF/DOCX/RTF/Markdown, tokenization, and unknown word detection with confidence scoring.

Key points:
- PDF: Use PDFKit's `PDFDocument` to extract text page by page
- DOCX: Shell out to `textutil -convert txt` (ships with macOS)
- RTF: Use `NSAttributedString(url:documentAttributes:)`
- Markdown: Read as plain text string
- Tokenize into unique words
- Check each against: `PhoneticEngine.isStandardEnglishWord()`, heuristics (capitalized mid-sentence, non-ASCII, camelCase)
- Return `[UnknownWord]` with the word, context sentence, and confidence score
- Runs on background thread

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Dictionary/DocumentScanner.swift
git commit -m "feat: add DocumentScanner with PDF/DOCX/RTF/MD extraction and unknown word detection"
```

---

## Task 7: Hotkey Registration & AppState Integration

**Files:**
- Modify: `OpenWhisper/Hotkey/HotkeyNames.swift`
- Modify: `OpenWhisper/AppState.swift`
- Modify: `OpenWhisper/Transcription/TranscriptionService.swift`

- [ ] **Step 1: Add dictionary hotkey to HotkeyNames.swift**

```swift
static let addToDictionary = Self("addToDictionary")
```

- [ ] **Step 2: Add DictionaryManager to AppState**

Add property:
```swift
let dictionaryManager = DictionaryManager()
```

Add hotkey registration in `init()`:
```swift
KeyboardShortcuts.onKeyUp(for: .addToDictionary) { [weak self] in
    guard let self else { return }
    Task { @MainActor in
        self.handleAddToDictionary()
    }
}
```

Add `handleAddToDictionary()` method that captures selected text via `cursorPositionService` and opens the appropriate add-word UI based on the configured mode.

- [ ] **Step 3: Integrate into transcription flow**

In `stopRecordingAndTranscribe()`, add two integration points:
1. Before calling `transcriptionService.transcribe()`: get `dictionaryManager.relevantWords(for: context)` and pass to transcription
2. After getting transcription result: call `dictionaryManager.correctTranscription(text)` before context-aware formatting
3. After insertion: call `dictionaryManager.updateUsageStats()`

- [ ] **Step 4: Modify TranscriptionService to accept dictionary words**

Add `dictionaryWords: [String] = []` parameter to the `transcribe` method. When non-empty, prepend to `initialPrompt`.

- [ ] **Step 5: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Hotkey/HotkeyNames.swift OpenWhisper/AppState.swift OpenWhisper/Transcription/TranscriptionService.swift
git commit -m "feat: integrate dictionary into transcription flow with hotkey, prompt injection, and post-processing"
```

---

## Task 8: Dictionary Tab & Entry List View

**Files:**
- Create: `OpenWhisper/Views/Dictionary/DictionaryView.swift`
- Create: `OpenWhisper/Views/Dictionary/DictionaryEntryRow.swift`
- Modify: `OpenWhisper/Views/MainWindowView.swift`

- [ ] **Step 1: Create Views/Dictionary directory**

```bash
mkdir -p "OpenWhisper/Views/Dictionary"
```

- [ ] **Step 2: Write DictionaryView.swift**

Main dictionary tab with:
- Search bar
- Tag filter chips (horizontal scroll)
- "Add Word" button and "Scan Document" button in toolbar
- Scrollable list of `DictionaryEntryRow`
- Status bar showing word counts by tier

- [ ] **Step 3: Write DictionaryEntryRow.swift**

Entry row with collapsed/expanded states:
- Collapsed: spelling, tags, usage count, tier badge
- Expanded: pronunciation audio (play/re-record), phonetic annotation, context description, context apps, tier override picker, edit/delete buttons

- [ ] **Step 4: Add Dictionary tab to MainWindowView**

Add `.dictionary` case to `AppTab` enum with "book" icon. Add case to the switch in the detail view rendering `DictionaryView(appState: appState)`.

- [ ] **Step 5: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/Dictionary/ OpenWhisper/Views/MainWindowView.swift
git commit -m "feat: add Dictionary tab with entry list, search, tag filters, and tier badges"
```

---

## Task 9: Add/Edit Entry Form

**Files:**
- Create: `OpenWhisper/Views/Dictionary/DictionaryEntryForm.swift`

- [ ] **Step 1: Write DictionaryEntryForm.swift**

Shared form for adding and editing dictionary entries. Used by:
- Full Dictionary Window mode (opens in dictionary tab)
- Quick Pop-up mode (embedded in floating panel)
- Edit mode (from expanded entry row)

Fields:
- Spelling (text field, pre-filled if adding via hotkey)
- Tags (token field with predefined suggestions + custom input)
- Context description (text editor)
- Pronunciation (record/play/re-record buttons with waveform)
- Phonetic annotation (text field, optional)
- Phonetic method picker (Regular/NATO/IPA, for how annotation was entered)
- Tier override picker (Auto/Always Active/Post-Processing Only)
- Save/Cancel buttons

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/Dictionary/DictionaryEntryForm.swift
git commit -m "feat: add DictionaryEntryForm with pronunciation recording, tags, and tier override"
```

---

## Task 10: Quick Pop-up Panel

**Files:**
- Create: `OpenWhisper/Views/Dictionary/DictionaryQuickPopup.swift`

- [ ] **Step 1: Write DictionaryQuickPopup.swift**

Small floating NSPanel (similar to RecordingOverlayPanel) for the Quick Pop-up add-word mode. Shows:
- Pre-filled word spelling
- Record/play/confirm buttons
- Dismisses on confirm or escape

Managed by a controller class that creates/shows/hides the panel.

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/Dictionary/DictionaryQuickPopup.swift
git commit -m "feat: add DictionaryQuickPopup floating panel for quick word addition"
```

---

## Task 11: Document Scanner View

**Files:**
- Create: `OpenWhisper/Views/Dictionary/DocumentScannerView.swift`

- [ ] **Step 1: Write DocumentScannerView.swift**

Two-phase view:
1. **Triage phase**: Shows scanned unknown words with checkboxes, context sentences, confidence scores. Select/deselect all. "Add Selected" button.
2. **Guided recording phase**: Steps through selected words one at a time. Shows word + context, record pronunciation, play back, confirm/skip. Batch tagging option before starting.

Triggered from the "Scan Document" button in DictionaryView which opens an NSOpenPanel first.

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/Dictionary/DocumentScannerView.swift
git commit -m "feat: add DocumentScannerView with triage list and guided recording wizard"
```

---

## Task 12: Verbal Spelling View

**Files:**
- Create: `OpenWhisper/Views/Dictionary/VerbalSpellingView.swift`

- [ ] **Step 1: Write VerbalSpellingView.swift**

Real-time letter assembly UI:
- Mode picker (Regular/NATO/IPA)
- Recording indicator
- Assembled word display (updates as letters are recognized)
- Undo last character button
- Clear button
- Done button (transitions to pronunciation recording)

Triggered from "Add Word" → "Spell by Voice" in DictionaryView.

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/Dictionary/VerbalSpellingView.swift
git commit -m "feat: add VerbalSpellingView with real-time letter assembly for Regular, NATO, and IPA modes"
```

---

## Task 13: Dictionary Settings

**Files:**
- Modify: `OpenWhisper/Views/SettingsView.swift` or `OpenWhisper/Views/SettingsTabView.swift`

- [ ] **Step 1: Add Dictionary section to Settings**

New section with:
- Dictionary hotkey (ShortcutRecorder, same component used for other hotkeys)
- Add-word mode picker (Quick Pop-up / Full Dictionary Window / Inline Overlay)
- Default spelling mode picker (Regular / NATO / IPA)
- Tier 1 max size stepper (default: 100)
- Prompt budget stepper (default: 200)
- Predefined tag suggestions display
- Custom tags management (add/remove)

Read the existing SettingsView/SettingsTabView to follow patterns.

- [ ] **Step 2: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
git add OpenWhisper/Views/SettingsView.swift OpenWhisper/Views/SettingsTabView.swift
git commit -m "feat: add Dictionary settings section with hotkey, add-word mode, and tier configuration"
```

---

## Task 14: Integration Verification

**Files:** None new — verification only.

- [ ] **Step 1: Full clean build**

```bash
cd "/Users/yishai/Documents/Warp Coding Projects/Open Wispr"
rm -rf .build
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
```

Expected: Clean build with no errors.

- [ ] **Step 2: Manual smoke test**

Launch the app. Verify:
1. Dictionary tab appears in sidebar
2. Can add a word manually (type spelling, save)
3. Entry appears in list with correct tier badge
4. Can expand entry to see details
5. Can delete entry
6. Dictionary settings section visible in Settings
7. AI Providers tab still works
8. Recording/transcription still works (no regression)

- [ ] **Step 3: Commit if fixes needed**

```bash
git add -A
git commit -m "fix: address integration issues from dictionary smoke testing"
```
