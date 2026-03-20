# Custom Dictionary Feature — Design Spec

> Sub-project E from the [AI Intelligence Layer Roadmap](../../ai-roadmap.md).
> Parts marked **[AI-enhanced]** activate once the AI provider infrastructure (Layers 1-2) is built. The core dictionary works standalone.

## 1. Overview

A custom dictionary that stores words, their pronunciations, phonetic annotations, and contextual descriptions. The dictionary integrates with all transcription backends (whisper.cpp, Parakeet, Granite, and future models including Claude) to ensure custom words are correctly recognized and transcribed.

Users can add words via a global hotkey (selecting text in any app), verbal spelling, manual entry, or document scanning. A tiered activation system keeps transcription fast while the full dictionary participates in post-processing correction.

## 2. Data Model

```swift
struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    var spelling: String                    // "Knuth", "שלום", "eigenvalue"
    var audioFilename: String?              // pronunciation recording
    var phoneticAnnotation: String?         // optional IPA/phonetic supplement
    var phoneticMethod: PhoneticMethod?     // .regular, .nato, .ipa
    var contextDescription: String?         // free-text: purpose, usage context
    var soundexCode: String                 // pre-computed for fast matching
    var metaphoneCode: String               // pre-computed for fast matching
    var tags: [String]                      // ["Names", "Computer Science", ...]
    var usageCount: Int                     // for tier 1 frequency ranking
    var lastUsedDate: Date?                 // for recency ranking
    var appContexts: [String]              // bundle IDs where this word is used (capped at 20 most recent)
    var createdDate: Date
    var tierOverride: TierOverride?         // user can pin to tier 1 or force tier 3
}

enum PhoneticMethod: String, Codable {
    case regular    // letter-by-letter: "K-N-U-T-H"
    case nato       // NATO alphabet: "Kilo November Uniform Tango Hotel"
    case ipa        // International Phonetic Alphabet: /knuːθ/
}

enum TierOverride: String, Codable {
    case alwaysActive       // pin to Tier 1
    case postProcessOnly    // force to Tier 3
}

enum ActivationTier {
    case tier1  // always in initial prompt (~top 100 by usage)
    case tier2  // context-activated (app + recency match)
    case tier3  // post-processing phonetic correction only
}
```

### Storage

- **Location:** `~/Library/Application Support/OpenWhisper/Dictionary/`
  - `dictionary.json` — array of `DictionaryEntry`
  - `audio/` — pronunciation recordings (CAF or M4A files)
- **Abstraction:** `DictionaryStore` protocol wrapping persistence, so a sync backend can be swapped in later.
- **Phonetic indexes:** Soundex and Metaphone codes computed on save, stored with the entry. Post-processing lookups are O(1) hash table lookups.

## 3. Architecture

```
DictionaryManager (@Observable, @MainActor)
│
├─ Storage Layer
│  ├─ DictionaryStore (protocol)
│  └─ LocalDictionaryStore (JSON + audio files)
│
├─ Activation Engine
│  ├─ relevantWords(for: AccessibilityContext) -> [String]
│  │   ├─ Tier 1: top ~100 by usage frequency (always included)
│  │   ├─ Tier 2: filtered by bundleIdentifier + recency
│  │   ├─ [AI-enhanced] context description matching
│  │   └─ Combined, capped at ~200 words
│  └─ updateUsageStats(words:, context:)
│
├─ Correction Engine
│  ├─ correctTranscription(_ text: String) -> String
│  │   ├─ Tokenize into words
│  │   ├─ Soundex/Metaphone lookup against full dictionary
│  │   ├─ Confidence threshold (both codes must match, original not in standard dict)
│  │   └─ [AI-enhanced] AI-assisted disambiguation
│  └─ phoneticIndex: [String: [DictionaryEntry]]
│
├─ Pronunciation Recorder
│  ├─ recordPronunciation() / stopRecording()
│  ├─ playPronunciation(for: DictionaryEntry)
│  └─ Own AVAudioEngine instance (separate from main recorder)
│
├─ Verbal Spelling Engine
│  ├─ Regular alphabet: transcribe → map letters → assemble word
│  ├─ NATO alphabet: hardcoded lookup table → letters → assemble word
│  └─ IPA: transcribe → validate against IPA symbol set → store as annotation
│
└─ Document Scanner
   ├─ scanDocument(url: URL) -> [UnknownWord]
   ├─ Text extraction: PDFKit (PDF), textutil (DOCX), NSAttributedString (RTF), String (Markdown)
   └─ Unknown word detection: system dict + model vocab + heuristics + confidence scoring
```

### Integration with AppState — two touch points

**Before transcription** (in `stopRecordingAndTranscribe()`):
```
AccessibilityContext captured
    → dictionaryManager.relevantWords(for: context)
    → words passed to TranscriptionService
        → whisper.cpp: initial_prompt parameter
        → Parakeet/Granite: hot-word list via HTTP
        → Future Claude: system/user prompt context
```

**After transcription** (in `stopRecordingAndTranscribe()`):
```
Raw transcription text
    → dictionaryManager.correctTranscription(rawText)
    → corrected text continues to context-aware formatting → text insertion
    → dictionaryManager.updateUsageStats(words:, context:)
```

## 4. User Flows

### 4.1 Add Word via Global Hotkey

**Trigger:** User selects a word in any app → presses configurable dictionary hotkey.

**Three configurable modes** (user selects default in Settings):

**A) Quick Pop-up** — Small floating panel (like recording overlay). Pre-filled with selected text. Record pronunciation, play back, confirm. Minimal interruption.

**B) Full Dictionary Window** (default) — Opens dictionary tab with complete entry form: spelling (pre-filled), tags, pronunciation recording, phonetic annotation, context description. All fields editable.

**C) Inline Overlay** — Uses existing overlay style. Records pronunciation inline, saves entry immediately. Edit details later in dictionary tab.

All modes capture the selected text via the Accessibility API (already used by `CursorPositionService` for `selectedText`).

**Empty selection:** If no text is selected when the hotkey is pressed, open the add-word form with an empty spelling field (user types it manually). In Inline Overlay mode, show a brief toast "Select a word first" and dismiss.

### 4.2 Add Word via Verbal Spelling

**Entry point:** "Add Word" button in dictionary tab → "Spell by Voice" option.

**Mode selector:** Regular Alphabet / NATO / IPA

- **Regular/NATO:** System transcribes spoken letters/words, maps to characters, assembles word in real-time. Undo last character, clear, re-record supported. After spelling complete, prompts for pronunciation recording.
- **IPA:** Transcribes IPA symbols, stores as `phoneticAnnotation`. Spelling must be provided separately (typed or via Regular/NATO mode).

### 4.3 Add Word Manually

Direct entry in the dictionary tab — type spelling, optionally record pronunciation, add tags, write context description.

### 4.4 Document Scanning

1. **File picker** — macOS open panel, filtered to PDF/DOCX/RTF/Markdown
2. **Scanning** (background thread with progress bar):
   - Extract text (PDFKit / textutil / NSAttributedString / String parsing)
   - Tokenize into unique words
   - Check against: system dictionary (`/usr/share/dict/words`), model vocabulary, heuristics (capitalization, non-ASCII, camelCase, unusual patterns)
   - Score confidence — lower = more likely custom word
3. **Triage list** — Unknown words with checkboxes, sorted by confidence. Shows context sentence from document. User selects which to add.
4. **Guided recording** — Steps through selected words one at a time: show word + context, record pronunciation, playback, confirm/skip. Optional batch tagging.

### 4.5 Dictionary Management

**Dictionary tab** in main window (alongside History):
- **Toolbar:** Search, tag filter chips, "Add Word" button, "Scan Document" button
- **Entry list:** Collapsed by default (spelling, tags, usage count, tier badge). Click to expand.
- **Expanded entry:** Pronunciation audio (play/re-record waveform), phonetic annotation, context description, context apps, tier override, edit/delete
- **Status bar:** Word counts by tier, import/export

## 5. Tiered Activation System

### Tier Assignment (auto-computed, user-overridable)

- **Tier 1 (Always Active):** Top ~100 entries by `usageCount`. Always included in transcription prompt. User can pin entries here via `tierOverride`.
- **Tier 2 (Context-Activated):** Entries matching current `AccessibilityContext`:
  - `bundleIdentifier` matches an entry's `appContexts`
  - Used within last 7 days (`lastUsedDate`)
  - **[AI-enhanced]** `contextDescription` semantically matches current context
- **Tier 3 (Post-Processing Only):** Everything else. Participates only in phonetic correction after transcription. User can force entries here via `tierOverride`.

### Prompt Budget

Combined Tier 1 + Tier 2 capped at ~200 words to keep transcription fast. If overflow, Tier 2 entries sorted by recency and the least recent are dropped to Tier 3 for that transcription.

### Usage Stats Update

After every transcription, `updateUsageStats` silently:
- Increments `usageCount` for dictionary words that appear in the transcription
- Records current `bundleIdentifier` in entry's `appContexts`
- Updates `lastUsedDate`

Over time, frequently used words naturally promote to Tier 1; unused words demote.

## 6. Post-Processing Correction

### Phonetic Matching

For each word in the transcription output:
1. Compute Soundex and Metaphone codes
2. Look up in `phoneticIndex` (maps codes → dictionary entries)
3. Apply confidence threshold:
   - Both Soundex AND Metaphone must match (not just one)
   - The transcribed word must NOT be in a standard English dictionary — use `/usr/share/dict/words` (~235k words) as the baseline; consider supplementing with a more comprehensive word list if false positives arise
   - If pronunciation audio exists, optionally compare audio similarity
4. If match passes threshold, replace transcribed word with dictionary spelling

### Edge Cases

- **Homophone collisions:** "new" and "Knuth" have different phonetic codes — Soundex/Metaphone naturally separates them
- **Multi-word entries:** Support compound entries (e.g., "machine learning") — match against bigrams/trigrams
- **Case preservation:** Maintain the original capitalization pattern when possible

## 7. Settings

New "Dictionary" section in Settings:

| Setting | Type | Default |
|---------|------|---------|
| Dictionary hotkey | ShortcutRecorder | (none — user must configure) |
| Add-word mode | Picker: Quick Pop-up / Full Dictionary Window / Inline Overlay | Full Dictionary Window |
| Default spelling mode | Picker: Regular / NATO / IPA | Regular |
| Predefined tag suggestions | Non-editable list | Names, Technical, Foreign Language, Medical, Legal, Scientific, Abbreviations, Slang/Informal |
| Custom tags | User-managed list | (empty) |
| Tier 1 max size | Stepper | 100 |
| Prompt budget (Tier 1+2) | Stepper | 200 |

## 8. Hotkey Registration

New entry in `HotkeyNames.swift`:
```swift
static let addToDictionary = Self("addToDictionary")
```

No default assigned — user configures in Settings. Registered in `AppState.init()` with `KeyboardShortcuts.onKeyUp(for:)`.

## 9. Dependencies

### New Files (Dictionary/ module)
- `DictionaryManager.swift` — orchestrator
- `DictionaryStore.swift` — storage protocol + local implementation
- `DictionaryEntry.swift` — data model
- `PhoneticEngine.swift` — Soundex/Metaphone computation + matching
- `VerbalSpellingEngine.swift` — letter/NATO/IPA transcription mapping
- `DocumentScanner.swift` — text extraction + unknown word detection
- `DictionaryPronunciationRecorder.swift` — own AVAudioEngine for recording pronunciations

### New Views
- `DictionaryView.swift` — main dictionary tab (list + toolbar)
- `DictionaryEntryRow.swift` — collapsed/expanded entry row
- `DictionaryEntryForm.swift` — add/edit form (used by all three add-word modes)
- `DictionaryQuickPopup.swift` — small floating panel for Quick Pop-up mode
- `DocumentScannerView.swift` — triage list + guided recording flow
- `VerbalSpellingView.swift` — real-time letter assembly UI

### Modified Files
- `AppState.swift` — hold `DictionaryManager`, call `relevantWords` and `correctTranscription` in transcription flow
- `TranscriptionService.swift` — accept optional word list in both `transcribe` overloads
- `HotkeyNames.swift` — add `addToDictionary` shortcut name
- `SettingsView.swift` / `SettingsTabView.swift` — add Dictionary settings section
- `MainWindowView.swift` — add Dictionary tab alongside History
- `project.yml` — no new SPM dependencies expected

### No New SPM Dependencies
- Soundex/Metaphone algorithms are simple enough to implement in-house (~50 lines each)
- PDFKit and NSAttributedString are system frameworks
- `textutil` ships with macOS

## 10. AI Enhancement Points

These activate once the AI Provider Infrastructure (Layer 1-2 of the roadmap) is built:

1. **Activation intelligence** — AI analyzes `contextDescription` fields against current accessibility context to boost Tier 2 relevance
2. **Correction disambiguation** — AI resolves ambiguous phonetic matches using sentence context
3. **Document scanning** — AI assesses which flagged words are genuinely unusual vs. just uncommon standard words
4. **Council mode** — LLM Council can be used for high-confidence correction decisions on ambiguous cases
5. **Context description generation** — AI can auto-suggest context descriptions based on how/where a word is used

These are additive — the core dictionary works without them.
