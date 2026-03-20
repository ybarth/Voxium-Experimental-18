# Text Insertion Methods Design

## Overview

Add two alternative text insertion methods alongside the existing clipboard paste: direct key press simulation and Accessibility API insertion. When AX insertion is used with Echo Mode + Speechify, the text is selected in-place in the target app (no floating echo panel needed).

## Text Insertion Method Enum

```swift
enum TextInsertionMethod: String, CaseIterable {
    case paste         // Existing Cmd+V clipboard approach
    case keyPresses    // Simulate individual key presses via CGEvent
    case accessibility // Insert via AX API at cursor position
}
```

New `@AppStorage("textInsertionMethod")` key, default `.paste`. Picker in SettingsTabView under the "Text Insertion" section.

## Method 1: Paste (Existing)

No changes. `PasteService.paste(text:)` — clipboard + Cmd+V simulation. Echo Mode uses the floating panel flow.

## Method 2: Key Press Simulation

### KeyPressInsertionService

`@MainActor final class` in `OpenWhisper/Insertion/KeyPressInsertionService.swift`.

- Iterates through each character in the transcription text
- For each character: creates a CGEvent, uses `keyboardSetUnicodeString` to set the Unicode character, posts key down + key up at maximum speed (no artificial delay)
- Special characters: newline → `kVK_Return`, tab → `kVK_Tab`
- No keycode lookup table needed — `keyboardSetUnicodeString` handles arbitrary Unicode
- Returns synchronously after all characters are posted

Echo Mode: uses the existing floating panel flow (same as paste — we don't know the insertion range).

## Method 3: Accessibility API Insertion

### AccessibilityInsertionService

`@MainActor final class` in `OpenWhisper/Insertion/AccessibilityInsertionService.swift`. Modeled on look-ma-no-hands `TextInsertionService`.

**Insertion flow:**

1. Get system-wide AX element → `kAXFocusedApplicationAttribute` → `kAXFocusedUIElementAttribute`
2. Validate element role is a text field (`kAXTextFieldRole`, `kAXTextAreaRole`, `AXWebArea`, `AXComboBox`)
3. Read current text (`kAXValueAttribute`) and cursor position (`kAXSelectedTextRangeAttribute` → `CFRange`)
4. Build new text with transcription inserted at cursor position (handling UTF-16 offsets properly)
5. Set new value via `AXUIElementSetAttributeValue(element, kAXValueAttribute, newText)`
6. Reposition cursor to end of inserted text via `kAXSelectedTextRangeAttribute`
7. Return `InsertionResult.success(element: AXUIElement, range: CFRange)` with the insertion range

**Fallback:** If the AX element doesn't support `kAXValueAttribute` or insertion fails, fall back to `PasteService.paste(text:)` and return `InsertionResult.fallbackToPaste`.

**InsertionResult enum:**

```swift
enum InsertionResult {
    case success(element: AXUIElement, insertedRange: CFRange)
    case fallbackToPaste
}
```

**Cursor repositioning:** Retry up to 5 times with progressive backoff (10ms, 30ms, 60ms, 100ms, 150ms) — some apps need a delay after `setValue` before the cursor can be repositioned.

**UTF-16 handling:** AX API uses UTF-16 offsets (NSString convention). Convert between Swift String.Index and UTF-16 offsets via `String.Index(utf16Offset:in:)`.

## Echo Mode Integration

### Decision Flow

After transcription + text insertion in `AppState.stopRecordingAndTranscribe()`:

```
if echoModeState.isActive && ttsMode == .speechify {
    if insertionMethod == .accessibility {
        let result = accessibilityInsertionService.insert(text)
        switch result {
        case .success(let element, let range):
            // Select the inserted text range in the target app
            // Press § key — Speechify reads from the target app directly
            // No echo panel, no focus switch
        case .fallbackToPaste:
            // Paste was used — fall back to existing echo panel flow
            echoNewEntry(entry)
        }
    } else {
        // .paste or .keyPresses — use existing echo panel flow
        // (insert text via respective method first)
        echoNewEntry(entry)
    }
}
```

### AX Echo Flow (no panel)

When AX insertion succeeds and echo mode is active:

1. The text was already inserted via AX — we have the `AXUIElement` and `CFRange`
2. Set `kAXSelectedTextRangeAttribute` on the element to select the inserted text (instead of cursor-at-end)
3. Simulate § key via `SpeechifyService.triggerRead()`
4. No need to activate our app — the target app is already active with the selection
5. No floating echo panel needed

### Panel Echo Flow (existing, for paste/keyPresses/fallback)

Unchanged from current implementation:
1. Show echo panel with entry text
2. Activate app, select text in panel's NSTextView
3. Simulate § key
4. Wait 900ms, restore focus to previous app

## Settings UI

In SettingsTabView, the existing "Text Insertion" section gets the new picker:

```swift
Section("Text Insertion") {
    Picker("Insertion Method", selection: ...) {
        Text("Paste (⌘V)").tag(TextInsertionMethod.paste)
        Text("Key Presses").tag(TextInsertionMethod.keyPresses)
        Text("Accessibility API").tag(TextInsertionMethod.accessibility)
    }
    // existing context-aware formatting toggle
    // existing direct insertion toggle (remove or fold into the new picker)
}
```

The existing `useDirectInsertion` toggle becomes redundant — it's subsumed by the `.accessibility` option. Remove it.

## Architecture

### New Files

| File | Responsibility |
|------|---------------|
| `OpenWhisper/Insertion/KeyPressInsertionService.swift` | CGEvent character-by-character typing |
| `OpenWhisper/Insertion/AccessibilityInsertionService.swift` | AX API text insertion + range tracking |

### Modified Files

| File | Changes |
|------|---------|
| `OpenWhisper/TTS/TTSSettings.swift` | Add `TextInsertionMethod` enum |
| `OpenWhisper/AppState.swift` | Route to correct insertion service, integrate AX echo flow |
| `OpenWhisper/Views/SettingsTabView.swift` | Add insertion method picker, remove `useDirectInsertion` toggle |
| `OpenWhisper/Views/SettingsView.swift` | Mirror changes if needed |

### Removed

- `useDirectInsertion` @AppStorage key and toggle — replaced by `.accessibility` method
- `PasteService.paste(text:context:)` overload that tried direct insertion — logic moves to `AccessibilityInsertionService`

## Out of Scope

- Intelligent formatting based on surrounding text context (existing `ContextAwareFormatter` continues to handle this)
- Burst/chunked key press simulation
- Per-app insertion method overrides
